#!/usr/bin/env bash
# production.sh — deploy your web project to the server (bash client).
#
# Packs the local project and POSTs it to deploy.php on the server. Runs from
# your local machine over plain HTTPS — handy for hosting that has no SSH/Git
# and cannot reach out to GitHub, but where your own machine can reach it.
#
# Usage:
#   ./production.sh                        # deploy the WHOLE project + run migrations
#   ./production.sh --no-migrate           # do not run migrations
#   ./production.sh --changed              # deploy ONLY files changed by the last commit
#                                          #   (incl. deleting files the commit removed)
#   ./production.sh --changed --since HEAD~2 # files changed over the last 2 commits
#   ./production.sh --changed --since v1.2 # files changed from any ref (tag/SHA/branch) to HEAD
#   ./production.sh --changed --dry-run    # only print what would be sent/deleted
#   ./production.sh --no-gitignore         # do NOT skip .gitignored paths
#   ./production.sh --url https://staging.example.com/deploy.php
#
# Excludes: in a git work tree everything in .gitignore is skipped automatically
#           (so secrets like config.php, logs, uploads, build output never get
#           shipped); add non-git excludes in `.deployignore`. --no-gitignore turns
#           the .gitignore handling off for projects that deploy a gitignored path.
#
# Deploy URL: pass --url, or put it in a `.deploy-url` file in the project root,
#             otherwise you are prompted.
# Token:      pass --token, or put it in a `.deploy-token` file in the project
#             root, otherwise you are prompted. (Both files are git-ignored.)
#
# Note: --changed sends the working-tree content (not the committed blobs), so
#       what is on disk is what gets deployed. A full deploy never deletes
#       anything on the server; only --changed propagates deletions.

set -euo pipefail

URL=""
TOKEN=""
NO_MIGRATE=0
CHANGED=0
SINCE=""
DRY_RUN=0
NO_GITIGNORE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --url)         URL="$2";       shift 2;;
        --token)       TOKEN="$2";     shift 2;;
        --since)       SINCE="$2";     shift 2;;
        --no-migrate)  NO_MIGRATE=1;   shift;;
        --changed)     CHANGED=1;      shift;;
        --no-gitignore) NO_GITIGNORE=1; shift;;
        --dry-run|--whatif) DRY_RUN=1; shift;;
        -h|--help)     grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
        *) echo "Unknown option: $1" >&2; exit 1;;
    esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Deploy URL ────────────────────────────────────────────────────────────────
if [[ -z "$URL" && -f "$ROOT/.deploy-url" ]]; then
    URL="$(tr -d '\r\n' < "$ROOT/.deploy-url")"
fi
if [[ -z "$URL" ]]; then read -rp "Deploy URL (https://example.com/deploy.php): " URL; fi
[[ -z "$URL" ]] && { echo "Missing deploy URL." >&2; exit 1; }

# ── Token ─────────────────────────────────────────────────────────────────────
if [[ -z "$TOKEN" && -f "$ROOT/.deploy-token" ]]; then
    TOKEN="$(tr -d '\r\n' < "$ROOT/.deploy-token")"
fi
if [[ -z "$TOKEN" ]]; then read -rp "Deploy token: " TOKEN; fi
[[ -z "$TOKEN" ]] && { echo "Missing deploy token." >&2; exit 1; }

# ── Excludes — never uploaded ─────────────────────────────────────────────────
# Built-in: VCS folders + HTTPDeploy's own tooling. Everything in .gitignore is
# added automatically (see below). Add any non-git excludes (or paths in a repo
# that has no .gitignore) one per line to a `.deployignore` file in the root.
EXCLUDES=(.git .github .svn .deploy-token .deploy-url .deployignore
          config.php config.sample.php
          production.ps1 production.sh publish.cmd README.md)
if [[ -f "$ROOT/.deployignore" ]]; then
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"   # ltrim
        line="${line%"${line##*[![:space:]]}"}"    # rtrim
        [[ -z "$line" || "$line" == \#* ]] && continue
        EXCLUDES+=("${line%/}")
    done < "$ROOT/.deployignore"
fi

# ── Also honor .gitignore ───────────────────────────────────────────────────────
# In a git work tree, every path git ignores (config.php / secrets, logs, uploads,
# caches, build output…) is excluded from the deploy too — so a gitignored file
# can never be shipped or overwrite its production counterpart. .deployignore still
# adds non-git excludes on top. Pass --no-gitignore for the rare project that
# deploys a gitignored path on purpose (e.g. a vendor/ you don't commit but upload).
# --directory collapses a fully-ignored folder to one entry rather than each file.
if [[ $NO_GITIGNORE -eq 0 ]] && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    added=0
    while IFS= read -r g; do
        g="${g%/}"
        [[ -z "$g" ]] && continue
        dup=0; for ex in "${EXCLUDES[@]}"; do [[ "$ex" == "$g" ]] && { dup=1; break; }; done
        [[ $dup -eq 0 ]] && { EXCLUDES+=("$g"); added=$((added+1)); }
    done < <(git -C "$ROOT" ls-files --others --ignored --exclude-standard --directory)
    [[ $added -gt 0 ]] && echo "Honoring .gitignore: $added path(s) excluded (use --no-gitignore to override)."
fi

is_excluded() {
    local rel="$1" ex
    for ex in "${EXCLUDES[@]}"; do
        [[ "$rel" == "$ex" || "$rel" == "$ex/"* ]] && return 0
    done
    return 1
}

# ── Temp files + cleanup ──────────────────────────────────────────────────────
TMP="${TMPDIR:-/tmp}"
STAGE="$(mktemp -d "$TMP/httpdeploy_stage_XXXXXXXX")"
PKG="$(mktemp -u "$TMP/httpdeploy_pkg_XXXXXXXX").tar.gz"
DELFILE=""
cleanup() { rm -rf "$STAGE" "$PKG"; if [[ -n "$DELFILE" ]]; then rm -f "$DELFILE"; fi; }
trap cleanup EXIT

if [[ $CHANGED -eq 1 ]]; then
    # ── Only files changed by the last commit (or from --since to HEAD) ─────────
    # --no-renames: a rename is split into a delete of the old path (D) + an add
    # of the new (A). Without it git reports renames as R, the old path misses
    # --diff-filter=D and the orphaned original file lingers on production forever
    # (typically versioned assets style.vN.css -> style.vN+1.css).
    if [[ -n "$SINCE" ]]; then
        RANGE="$SINCE..HEAD"; FIRST=0
        mapfile -t FILES   < <(git -C "$ROOT" diff --name-only --no-renames --diff-filter=ACMT "$SINCE" HEAD)
        mapfile -t DELETED < <(git -C "$ROOT" diff --name-only --no-renames --diff-filter=D    "$SINCE" HEAD)
    elif git -C "$ROOT" rev-parse --verify -q HEAD~1 >/dev/null; then
        RANGE="last commit (HEAD~1..HEAD)"; FIRST=0
        mapfile -t FILES   < <(git -C "$ROOT" diff --name-only --no-renames --diff-filter=ACMT HEAD~1 HEAD)
        mapfile -t DELETED < <(git -C "$ROOT" diff --name-only --no-renames --diff-filter=D    HEAD~1 HEAD)
    else
        RANGE="first commit"; FIRST=1
        mapfile -t FILES   < <(git -C "$ROOT" show --pretty=format: --name-only --no-renames --diff-filter=ACMT HEAD)
        DELETED=()
    fi

    # filter excludes + unique (keep order)
    filter_list() {
        local rel
        for rel in "$@"; do
            [[ -z "$rel" ]] && continue
            is_excluded "$rel" && continue
            printf '%s\n' "$rel"
        done | awk '!seen[$0]++'
    }
    RAW_COUNT=$(( ${#FILES[@]} + ${#DELETED[@]} ))
    mapfile -t FILES   < <(filter_list "${FILES[@]+"${FILES[@]}"}")
    mapfile -t DELETED < <(filter_list "${DELETED[@]+"${DELETED[@]}"}")

    if [[ ${#FILES[@]} -eq 0 && ${#DELETED[@]} -eq 0 ]]; then
        if [[ $RAW_COUNT -gt 0 ]]; then
            # There were changes, but every one is on the exclude list
            # (config, tooling like production.sh, README, .deployignore paths…).
            echo "Nothing to deploy in $RANGE." >&2
            echo "All $RAW_COUNT changed file(s) are excluded (config / tooling / .deployignore)." >&2
            echo "If the change you want is in an earlier commit, widen the range, e.g.:" >&2
            echo "    ./production.sh --changed --since HEAD~2" >&2
        else
            echo "Nothing to deploy in $RANGE — that commit changed no files." >&2
            echo "Use --since <ref> for a wider range, or run without --changed for a full deploy." >&2
        fi
        exit 0
    fi
    echo "Changes to deploy — $RANGE"
    echo "  upload: ${#FILES[@]}   delete: ${#DELETED[@]}"

    # ── DryRun: print only, copy/send nothing ──────────────────────────────────
    if [[ $DRY_RUN -eq 1 ]]; then
        for f in "${FILES[@]+"${FILES[@]}"}";   do echo "  + $f"; done
        for f in "${DELETED[@]+"${DELETED[@]}"}"; do echo "  - $f"; done
        echo "DRY RUN — nothing uploaded or deleted."
        exit 0
    fi

    MISSING=0
    for rel in "${FILES[@]+"${FILES[@]}"}"; do
        if [[ ! -f "$ROOT/$rel" ]]; then
            echo "  ! skipped (missing on disk): $rel"; MISSING=$((MISSING+1)); continue
        fi
        mkdir -p "$STAGE/$(dirname "$rel")"
        cp -p "$ROOT/$rel" "$STAGE/$rel"
        echo "  + $rel"
    done
    [[ $MISSING -gt 0 ]] && echo "Skipped $MISSING missing files (left untouched on the server)."

    # The delete list is passed to the server as the "delete" form field (one per line)
    if [[ ${#DELETED[@]} -gt 0 ]]; then
        DELFILE="$(mktemp "$TMP/httpdeploy_del_XXXXXXXX")"
        printf '%s\n' "${DELETED[@]}" > "$DELFILE"
        for f in "${DELETED[@]}"; do echo "  - $f"; done
    fi

    # Commit only deleted files → empty staging, but deploy.php needs a "package"
    if [[ -z "$(ls -A "$STAGE")" ]]; then : > "$STAGE/.deploy-noop"; fi

    echo "Building archive..."
    mapfile -t ITEMS < <(cd "$STAGE" && ls -A)
    tar -czf "$PKG" -C "$STAGE" "${ITEMS[@]}"
else
    # ── Full deploy: the whole root minus excluded paths ────────────────────────
    TAR_EXCLUDES=()
    for ex in "${EXCLUDES[@]}"; do TAR_EXCLUDES+=(--exclude="$ex"); done
    mapfile -t TOP < <(cd "$ROOT" && ls -A)

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "DRY RUN — files that would be uploaded:"
        tar -cf /dev/null -v -C "$ROOT" "${TAR_EXCLUDES[@]}" "${TOP[@]}"
        echo "DRY RUN — nothing uploaded."
        exit 0
    fi

    echo "Building archive (full deploy)..."
    tar -czf "$PKG" -C "$ROOT" "${TAR_EXCLUDES[@]}" "${TOP[@]}"
fi

SIZE_KB=$(( ( $(wc -c < "$PKG") + 1023 ) / 1024 ))
echo "Package: ${SIZE_KB} kB"

# ── Upload ────────────────────────────────────────────────────────────────────
MIGRATE=1; [[ $NO_MIGRATE -eq 1 ]] && MIGRATE=0
echo "Uploading to $URL ..."
CURL_ARGS=(-sS -o - -w $'\nHTTP_CODE:%{http_code}'
    -X POST "$URL"
    -H "X-Deploy-Token: $TOKEN"
    -F "migrate=$MIGRATE"
    -F "package=@$PKG")
# Delete list (curl reads the field value from the file via "<")
[[ -n "$DELFILE" ]] && CURL_ARGS+=(-F "delete=<$DELFILE")
RESP="$(curl "${CURL_ARGS[@]}")"

echo "----- server response -----"
echo "$RESP"
echo "---------------------------"
if [[ "$RESP" == *"HTTP_CODE:200"* ]]; then
    echo "Deploy finished successfully."
else
    echo "Deploy failed (see server response above)." >&2
    exit 1
fi
