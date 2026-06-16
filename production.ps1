# production.ps1 — deploy your web project to the server (PowerShell client).
#
# Packs the local project and POSTs it to deploy.php on the server. Runs from
# your local machine over plain HTTPS — handy for hosting that has no SSH/Git
# and cannot reach out to GitHub, but where your own machine can reach it.
#
# Usage:
#   .\production.ps1                       # deploy the WHOLE project + run migrations
#   .\production.ps1 -NoMigrate            # do not run migrations
#   .\production.ps1 -Changed              # deploy ONLY files changed by the last commit
#                                          #   (incl. deleting files the commit removed)
#   .\production.ps1 -Changed -Since HEAD~2  # files changed over the last 2 commits
#   .\production.ps1 -Changed -Since v1.2  # files changed from any ref (tag/SHA/branch) to HEAD
#   .\production.ps1 -Changed -DryRun      # only print what would be sent/deleted
#   .\production.ps1 -Url https://staging.example.com/deploy.php
#
# Deploy URL: pass -Url, or put it in a `.deploy-url` file in the project root,
#             otherwise you are prompted.
# Token:      pass -Token, or put it in a `.deploy-token` file in the project
#             root, otherwise you are prompted. (Both files are git-ignored.)
#
# Note: -Changed sends the working-tree content (not the committed blobs), so
#       what is on disk is what gets deployed. A full deploy never deletes
#       anything on the server; only -Changed propagates deletions.

param(
    [string]$Url,
    [string]$Token,
    [switch]$NoMigrate,
    [switch]$Changed,
    [string]$Since,
    [Alias('WhatIf')]
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot

# Keep the server's UTF-8 response readable in the console
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ── Deploy URL ────────────────────────────────────────────────────────────────
if (-not $Url) {
    $uf = Join-Path $root ".deploy-url"
    if (Test-Path $uf) { $Url = (Get-Content $uf -Raw).Trim() }
}
if (-not $Url)   { $Url   = Read-Host "Deploy URL (https://example.com/deploy.php)" }
if (-not $Url)   { throw "Missing deploy URL." }

# ── Token ─────────────────────────────────────────────────────────────────────
if (-not $Token) {
    $tf = Join-Path $root ".deploy-token"
    if (Test-Path $tf) { $Token = (Get-Content $tf -Raw).Trim() }
}
if (-not $Token) { $Token = Read-Host "Deploy token" }
if (-not $Token) { throw "Missing deploy token." }

# ── Excludes — never uploaded ─────────────────────────────────────────────────
# Built-in: VCS folders + HTTPDeploy's own tooling. Add project-specific paths
# (uploads, logs, caches, …) one per line to a `.deployignore` file in the root.
$excludeRel = @(".git", ".github", ".svn", ".deploy-token", ".deploy-url",
                ".deployignore", "config.php", "config.sample.php",
                "production.ps1", "production.sh", "publish.cmd", "README.md")
$ignoreFile = Join-Path $root ".deployignore"
if (Test-Path $ignoreFile) {
    foreach ($line in Get-Content $ignoreFile) {
        $line = $line.Trim()
        if ($line -and -not $line.StartsWith('#')) {
            $excludeRel += (($line -replace '\\', '/').TrimEnd('/'))
        }
    }
}
function Test-Excluded([string]$rel) {
    $rel = ($rel -replace '\\', '/').Trim()
    foreach ($ex in $excludeRel) {
        if ($rel -eq $ex -or $rel.StartsWith($ex + '/')) { return $true }
    }
    return $false
}

# ── Temp staging + package ────────────────────────────────────────────────────
$stage   = Join-Path $env:TEMP ("httpdeploy_stage_" + [guid]::NewGuid().ToString("N"))
$pkg     = Join-Path $env:TEMP ("httpdeploy_pkg_"   + [guid]::NewGuid().ToString("N") + ".tar.gz")
$delFile = $null   # temp list of files to delete (only -Changed mode)

if ($Changed) {
    # ── Only files changed by the last commit (or from -Since to HEAD) ──────────
    # --no-renames: a rename is split into a delete of the old path (D) + an add
    # of the new (A). Without it git reports renames as R, the old path misses
    # --diff-filter=D and the orphaned original file lingers on production forever
    # (typically versioned assets style.vN.css -> style.vN+1.css).
    if ($Since) {
        $range   = "$Since..HEAD"
        $isFirst = $false
        $files   = git -C $root diff --name-only --no-renames --diff-filter=ACMT $Since HEAD
    } else {
        git -C $root rev-parse --verify -q HEAD~1 *> $null
        if ($LASTEXITCODE -eq 0) {
            $range   = "last commit (HEAD~1..HEAD)"
            $isFirst = $false
            $files   = git -C $root diff --name-only --no-renames --diff-filter=ACMT HEAD~1 HEAD
        } else {
            $range   = "first commit"
            $isFirst = $true
            $files   = git -C $root show --pretty=format: --name-only --no-renames --diff-filter=ACMT HEAD
        }
    }
    if ($LASTEXITCODE -ne 0) { throw "git diff failed (code $LASTEXITCODE)" }

    # Deleted files (none on the very first commit)
    $deleted = @()
    if (-not $isFirst) {
        if ($Since) { $deleted = git -C $root diff --name-only --no-renames --diff-filter=D $Since HEAD }
        else        { $deleted = git -C $root diff --name-only --no-renames --diff-filter=D HEAD~1 HEAD }
        if ($LASTEXITCODE -ne 0) { throw "git diff (deleted) failed (code $LASTEXITCODE)" }
    }

    $files   = $files   | Where-Object { $_ -and -not (Test-Excluded $_) } | Select-Object -Unique
    $deleted = $deleted | Where-Object { $_ -and -not (Test-Excluded $_) } | Select-Object -Unique
    if (-not $files -and -not $deleted) { throw "No deployable changes ($range)." }

    Write-Host "Changes to deploy — $range" -ForegroundColor Cyan
    Write-Host "  upload: $(@($files).Count)   delete: $(@($deleted).Count)"

    # ── DryRun: print only, copy/send nothing ───────────────────────────────────
    if ($DryRun) {
        if ($files)   { $files   | ForEach-Object { Write-Host "  + $_" -ForegroundColor Green } }
        if ($deleted) { $deleted | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red } }
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "DRY RUN — nothing uploaded or deleted." -ForegroundColor Yellow
        return
    }

    $missing = 0
    foreach ($rel in $files) {
        $src = Join-Path $root ($rel -replace '/', '\')
        if (-not (Test-Path $src -PathType Leaf)) {
            Write-Host "  ! skipped (missing on disk): $rel" -ForegroundColor Yellow
            $missing++
            continue
        }
        $dst    = Join-Path $stage ($rel -replace '/', '\')
        $dstDir = Split-Path $dst -Parent
        if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
        Copy-Item $src $dst -Force
        Write-Host "  + $rel" -ForegroundColor Green
    }
    if ($missing) { Write-Host "Skipped $missing missing files (left untouched on the server)." -ForegroundColor Yellow }

    # The delete list is passed to the server as the "delete" form field (one per line)
    if ($deleted) {
        $deleted | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
        $delFile = Join-Path $env:TEMP ("httpdeploy_del_" + [guid]::NewGuid().ToString("N") + ".txt")
        Set-Content -Path $delFile -Value ($deleted -join "`n") -Encoding UTF8 -NoNewline
    }

    # A commit may only delete files → empty staging, but deploy.php still needs
    # a "package". Drop in an empty marker so the upload is valid.
    if (-not (Get-ChildItem -Force -Path $stage -ErrorAction SilentlyContinue)) {
        Set-Content -Path (Join-Path $stage ".deploy-noop") -Value "" -Encoding ASCII
    }
} else {
    # ── Full deploy: the whole root minus excluded paths ────────────────────────
    $exDirs  = @(); $exFiles = @()
    foreach ($ex in $excludeRel) {
        $p = Join-Path $root ($ex -replace '/', '\')
        if (Test-Path $p -PathType Container) { $exDirs += $p } else { $exFiles += $p }
    }

    if ($DryRun) {
        Write-Host "DRY RUN — files that would be uploaded:" -ForegroundColor Yellow
        robocopy $root $stage /E /XD $exDirs /XF $exFiles /L /NJH /NJS /NP /NS /NC
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "DRY RUN — nothing uploaded." -ForegroundColor Yellow
        return
    }

    Write-Host "Copying files to staging..." -ForegroundColor Cyan
    robocopy $root $stage /E /XD $exDirs /XF $exFiles /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed (code $LASTEXITCODE)" }
}

Write-Host "Building archive..." -ForegroundColor Cyan
# Pack items by name (incl. dotfiles like .htaccess), NOT "." — a "." root
# would break PharData on the server. @(...) keeps it an array even for a
# single file, otherwise splatting a bare string mangles the tar arguments.
$items = @(Get-ChildItem -Force -Name -Path $stage)
if (-not $items) { throw "Staging is empty." }
tar -czf $pkg -C $stage @items
if ($LASTEXITCODE -ne 0) { throw "tar failed (code $LASTEXITCODE)" }
$sizeKb = [math]::Round((Get-Item $pkg).Length / 1KB)
Write-Host "Package: $sizeKb kB"

# ── Upload ────────────────────────────────────────────────────────────────────
$migrate = if ($NoMigrate) { "0" } else { "1" }
Write-Host "Uploading to $Url ..." -ForegroundColor Cyan
$curlArgs = @(
    '-sS', '-o', '-', '-w', "`nHTTP_CODE:%{http_code}",
    '-X', 'POST', $Url,
    '-H', "X-Deploy-Token: $Token",
    '-F', "migrate=$migrate",
    '-F', "package=@$pkg"
)
# Delete list (curl reads the field value from the file via "<")
if ($delFile) { $curlArgs += @('-F', "delete=<$delFile") }
$resp = & curl.exe @curlArgs

Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $pkg -Force -ErrorAction SilentlyContinue
if ($delFile) { Remove-Item $delFile -Force -ErrorAction SilentlyContinue }

Write-Host "----- server response -----"
Write-Host $resp
Write-Host "---------------------------"
if ($resp -match "HTTP_CODE:200") {
    Write-Host "Deploy finished successfully." -ForegroundColor Green
} else {
    throw "Deploy failed (see server response above)."
}
