#!/usr/bin/env bash
# End-to-end self-test for HTTPDeploy — bash client (production.sh).
#
# Mirror of test/deploy-test.ps1: starts a throwaway PHP server hosting a copy
# of deploy.php + sql/migrate.php, deploys a sample project onto it with
# production.sh, and asserts the result.
#
# Requires php, git, tar, curl and a local MariaDB/MySQL. Override defaults via
# environment variables:
#   PHP=php  PORT=8100  DBHOST=localhost  DBUSER=root  DBPASS=
#
# Usage:  PHP=php DBPASS=secret ./test/deploy-test.sh

set -uo pipefail

PHP="${PHP:-php}"
PORT="${PORT:-8100}"
DBHOST="${DBHOST:-localhost}"
DBUSER="${DBUSER:-root}"
DBPASS="${DBPASS:-}"
DB="hdtest_deploy_sh"

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="$(mktemp -d "${TMPDIR:-/tmp}/hdtest_sh_XXXXXXXX")"
SERVER="$BASE/server"
LOCAL="$BASE/local"
TOKEN="test-token-$$-$RANDOM"
fails=0

check() { # name  cond(0/1 exit)
    if [[ "$2" -eq 0 ]]; then echo "  PASS  $1"; else echo "  FAIL  $1"; fails=$((fails+1)); fi
}

mkdir -p "$SERVER/sql" "$LOCAL/lib" "$LOCAL/sql"

# ── Server web root ───────────────────────────────────────────────────────────
cp "$SRC/deploy.php"       "$SERVER/"
cp "$SRC/sql/migrate.php"  "$SERVER/sql/"
cat > "$SERVER/config.php" <<PHP
<?php
define('DEPLOY_TOKEN', '$TOKEN');
define('DEPLOY_ALLOW_HTTP', true);   // test server runs plain HTTP on localhost
define('DEPLOY_ALLOWED_IPS', []);
define('DEPLOY_PROTECTED', ['uploads']);
define('DB_HOST', '$DBHOST');
define('DB_NAME', '$DB');
define('DB_USER', '$DBUSER');
define('DB_PASS', '$DBPASS');
define('DB_CHARSET', 'utf8mb4');
function db(): PDO {
    static \$pdo = null;
    if (\$pdo === null) {
        \$dsn = sprintf('mysql:host=%s;dbname=%s;charset=%s', DB_HOST, DB_NAME, DB_CHARSET);
        \$pdo = new PDO(\$dsn, DB_USER, DB_PASS, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    }
    return \$pdo;
}
PHP
CFG_HASH_BEFORE="$("$PHP" -r "echo md5_file('$SERVER/config.php');")"
mkdir -p "$SERVER/uploads"
printf 'KEEP ME' > "$SERVER/uploads/data.txt"

# ── Symlink-escape guard (Linux) ──────────────────────────────────────────────
# Pre-existing symlinks in the web root pointing OUTSIDE it must never be followed
# when the matching archive entry is written: a leaf file symlink must be replaced
# by a regular file (its target left intact), and a dir symlink must not be written
# through. Set up the bait targets and the symlinks here.
mkdir -p "$BASE/outside/sub"
printf 'UNTOUCHED'     > "$BASE/outside/secret.txt"
printf 'UNTOUCHED-DIR' > "$BASE/outside/sub/deep.txt"
ln -s "$BASE/outside/secret.txt" "$SERVER/hijack.php"   # leaf file symlink → outside
ln -s "$BASE/outside/sub"        "$SERVER/hijackdir"    # dir symlink → outside

# ── Local project (git repo) ──────────────────────────────────────────────────
printf "<?php echo 'app v1';" > "$LOCAL/index.php"
printf '<?php // util v1'      > "$LOCAL/lib/util.php"
printf 'Options -Indexes'      > "$LOCAL/.htaccess"
cp "$SRC/sql/migrate.php" "$LOCAL/sql/"
printf 'CREATE TABLE widgets (id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY, name VARCHAR(100) NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;' > "$LOCAL/sql/schema.sql"
cp "$SRC/production.sh" "$LOCAL/"            # client lives in the project → must be excluded
printf '%s' "$TOKEN" > "$LOCAL/.deploy-token"
printf 'http://127.0.0.1:%s/deploy.php' "$PORT" > "$LOCAL/.deploy-url"
printf '<?php // replaced' > "$LOCAL/hijack.php"        # archive entry vs. the leaf symlink
mkdir -p "$LOCAL/hijackdir"
printf '<?php // replaced' > "$LOCAL/hijackdir/deep.php" # archive entry vs. the dir symlink

git -C "$LOCAL" init -q
git -C "$LOCAL" add -A
git -C "$LOCAL" -c user.email=test@example.com -c user.name=test commit -q -m "v1"

# ── Start the PHP built-in server ─────────────────────────────────────────────
"$PHP" -S "127.0.0.1:$PORT" -t "$SERVER" >/dev/null 2>&1 &
SRVPID=$!
cleanup() {
    kill "$SRVPID" 2>/dev/null
    "$PHP" -r "\$p=new PDO('mysql:host=$DBHOST','$DBUSER','$DBPASS'); \$p->exec('DROP DATABASE IF EXISTS $DB');" 2>/dev/null
    rm -rf "$BASE"
}
trap cleanup EXIT

for _ in $(seq 1 30); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/deploy.php" && break
    sleep 0.2
done

echo
echo "=== FULL DEPLOY ==="
( cd "$LOCAL" && bash ./production.sh )

echo
echo "--- checks (full deploy) ---"
[[ -f "$SERVER/index.php"        ]]; check "index.php deployed" $?
[[ -f "$SERVER/lib/util.php"     ]]; check "nested lib/util.php" $?
[[ -f "$SERVER/.htaccess"        ]]; check "dotfile .htaccess packed" $?
[[ -f "$SERVER/sql/migrate.php"  ]]; check "sql/migrate.php deployed" $?
[[ ! -f "$SERVER/production.sh"  ]]; check "client production.sh EXCLUDED" $?
[[ -f "$SERVER/uploads/data.txt" && "$(cat "$SERVER/uploads/data.txt")" == "KEEP ME" ]]; check "protected uploads/data.txt kept" $?
[[ "$("$PHP" -r "echo md5_file('$SERVER/config.php');")" == "$CFG_HASH_BEFORE" ]]; check "server config.php untouched" $?
COLS="$("$PHP" -r "\$p=new PDO('mysql:host=$DBHOST;dbname=$DB;charset=utf8mb4','$DBUSER','$DBPASS'); echo implode(',', \$p->query('SHOW COLUMNS FROM widgets')->fetchAll(PDO::FETCH_COLUMN));" 2>/dev/null)"
[[ "$COLS" == *id* && "$COLS" == *name* ]]; check "migration created table widgets" $?
[[ "$(cat "$BASE/outside/secret.txt")" == "UNTOUCHED" ]]; check "leaf symlink target outside root NOT overwritten" $?
[[ -f "$SERVER/hijack.php" && ! -L "$SERVER/hijack.php" && "$(cat "$SERVER/hijack.php")" == "<?php // replaced" ]]; check "hijack.php replaced by a regular file inside root" $?
[[ "$(cat "$BASE/outside/sub/deep.txt")" == "UNTOUCHED-DIR" ]]; check "dir symlink target outside root NOT written into" $?
[[ ! -e "$BASE/outside/sub/deep.php" ]]; check "no file leaked through dir symlink" $?

echo
echo "=== CHANGED DEPLOY (add + delete) ==="
printf '<?php // new in v2' > "$LOCAL/newfile.php"
rm "$LOCAL/lib/util.php"
git -C "$LOCAL" add -A
git -C "$LOCAL" -c user.email=test@example.com -c user.name=test commit -q -m "v2: add newfile, drop util"
( cd "$LOCAL" && bash ./production.sh --changed --no-migrate )

echo
echo "--- checks (changed deploy) ---"
[[ -f "$SERVER/newfile.php"      ]]; check "newfile.php deployed" $?
[[ ! -f "$SERVER/lib/util.php"   ]]; check "lib/util.php DELETED on server" $?
[[ -f "$SERVER/uploads/data.txt" ]]; check "protected uploads still kept" $?
[[ -f "$SERVER/index.php"        ]]; check "index.php still present" $?

echo
echo "=============================="
if [[ $fails -eq 0 ]]; then echo "ALL CHECKS PASSED"; else echo "$fails CHECK(S) FAILED"; exit 1; fi
