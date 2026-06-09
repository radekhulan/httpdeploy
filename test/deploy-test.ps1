<#
.SYNOPSIS
    End-to-end self-test for HTTPDeploy.

.DESCRIPTION
    Spins up a throwaway "server" (PHP built-in server hosting a copy of
    deploy.php + sql/migrate.php) and a throwaway "local project" (a small git
    repo), then deploys the project onto the server with production.ps1 and
    asserts the result. Verifies:

      * full deploy lands files, including nested paths and dotfiles
      * the client's own tooling (production.ps1 …) is excluded from the upload
      * protected paths (uploads/, config.php) survive a deploy untouched
      * sql/migrate.php runs and creates the schema
      * -Changed mode uploads new files AND deletes removed ones

    Everything is created under %TEMP% and removed afterwards. Requires PHP on
    PATH (or pass -Php), git, tar, curl, and a local MariaDB/MySQL for the
    migration check.

.EXAMPLE
    .\test\deploy-test.ps1
    .\test\deploy-test.ps1 -DbUser root -DbPass secret -Port 8123
#>
param(
    [string]$Php    = 'php',
    [int]   $Port   = 8099,
    [string]$DbHost = 'localhost',
    [string]$DbUser = 'root',
    [string]$DbPass = ''
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$src    = Split-Path $PSScriptRoot -Parent          # project root (one up from /test)
$base   = Join-Path $env:TEMP ('hdtest_' + [guid]::NewGuid().ToString('N'))
$server = Join-Path $base 'server'
$local  = Join-Path $base 'local'
$db     = 'hdtest_deploy'
$token  = 'test-token-' + [guid]::NewGuid().ToString('N')
New-Item -ItemType Directory -Force $server, $local, (Join-Path $local 'lib'), (Join-Path $local 'sql') | Out-Null

$script:fails = 0
function Check($name, $cond) {
    if ($cond) { Write-Host "  PASS  $name" -ForegroundColor Green }
    else       { Write-Host "  FAIL  $name" -ForegroundColor Red; $script:fails++ }
}
function PdoExpr($expr) {
    & $Php -r "`$p=new PDO('mysql:host=$DbHost;dbname=$db;charset=utf8mb4','$DbUser','$DbPass'); echo $expr;"
}

# ── Build the "server web root" ───────────────────────────────────────────────
Copy-Item (Join-Path $src 'deploy.php') $server
New-Item -ItemType Directory -Force (Join-Path $server 'sql') | Out-Null
Copy-Item (Join-Path $src 'sql\migrate.php') (Join-Path $server 'sql')

@"
<?php
define('DEPLOY_TOKEN', '$token');
define('DEPLOY_ALLOWED_IPS', []);
define('DEPLOY_PROTECTED', ['uploads']);
define('DB_HOST', '$DbHost');
define('DB_NAME', '$db');
define('DB_USER', '$DbUser');
define('DB_PASS', '$DbPass');
define('DB_CHARSET', 'utf8mb4');
function db(): PDO {
    static `$pdo = null;
    if (`$pdo === null) {
        `$dsn = sprintf('mysql:host=%s;dbname=%s;charset=%s', DB_HOST, DB_NAME, DB_CHARSET);
        `$pdo = new PDO(`$dsn, DB_USER, DB_PASS, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    }
    return `$pdo;
}
"@ | Set-Content -Path (Join-Path $server 'config.php') -Encoding UTF8
$cfgHashBefore = (Get-FileHash (Join-Path $server 'config.php')).Hash

# Protected runtime data that must survive deploys
New-Item -ItemType Directory -Force (Join-Path $server 'uploads') | Out-Null
Set-Content (Join-Path $server 'uploads\data.txt') 'KEEP ME' -Encoding ASCII

# ── Build the "local project" (a git repo) ────────────────────────────────────
Set-Content (Join-Path $local 'index.php')    "<?php echo 'app v1';" -Encoding ASCII
Set-Content (Join-Path $local 'lib\util.php') "<?php // util v1" -Encoding ASCII
Set-Content (Join-Path $local '.htaccess')    "Options -Indexes" -Encoding ASCII   # dotfile must be packed
Copy-Item (Join-Path $src 'sql\migrate.php') (Join-Path $local 'sql')
Set-Content (Join-Path $local 'sql\schema.sql') "CREATE TABLE widgets (id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY, name VARCHAR(100) NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;" -Encoding ASCII
Copy-Item (Join-Path $src 'production.ps1') $local                                  # client lives in the project → must be excluded
Set-Content (Join-Path $local '.deploy-token') $token -Encoding ASCII -NoNewline
Set-Content (Join-Path $local '.deploy-url')   "http://127.0.0.1:$Port/deploy.php" -Encoding ASCII -NoNewline

git -C $local init -q
git -C $local add -A
git -C $local -c user.email=test@example.com -c user.name=test commit -q -m "v1"

# ── Start the PHP built-in server as the "host" ───────────────────────────────
$srv = Start-Process -FilePath $Php -ArgumentList @('-S', "127.0.0.1:$Port", '-t', $server) `
        -WindowStyle Hidden -PassThru
try {
    for ($i = 0; $i -lt 30; $i++) {
        try { Invoke-WebRequest "http://127.0.0.1:$Port/deploy.php" -Method Get -TimeoutSec 2 | Out-Null; break }
        catch { Start-Sleep -Milliseconds 200 }
    }

    Write-Host "`n=== FULL DEPLOY ===" -ForegroundColor Cyan
    Push-Location $local
    & (Join-Path $local 'production.ps1')
    Pop-Location

    Write-Host "`n--- checks (full deploy) ---"
    Check "index.php deployed"             (Test-Path (Join-Path $server 'index.php'))
    Check "nested lib/util.php"            (Test-Path (Join-Path $server 'lib\util.php'))
    Check "dotfile .htaccess packed"       (Test-Path (Join-Path $server '.htaccess'))
    Check "sql/migrate.php deployed"       (Test-Path (Join-Path $server 'sql\migrate.php'))
    Check "client production.ps1 EXCLUDED" (-not (Test-Path (Join-Path $server 'production.ps1')))
    Check "protected uploads/data.txt kept" ((Test-Path (Join-Path $server 'uploads\data.txt')) -and (Get-Content (Join-Path $server 'uploads\data.txt')) -eq 'KEEP ME')
    Check "server config.php untouched"    ((Get-FileHash (Join-Path $server 'config.php')).Hash -eq $cfgHashBefore)

    $cols = PdoExpr "implode(',', `$p->query('SHOW COLUMNS FROM widgets')->fetchAll(PDO::FETCH_COLUMN))"
    Check "migration created table widgets" ($cols -match 'id' -and $cols -match 'name')

    Write-Host "`n=== CHANGED DEPLOY (add + delete) ===" -ForegroundColor Cyan
    Set-Content (Join-Path $local 'newfile.php') "<?php // new in v2" -Encoding ASCII
    Remove-Item (Join-Path $local 'lib\util.php')
    git -C $local add -A
    git -C $local -c user.email=test@example.com -c user.name=test commit -q -m "v2: add newfile, drop util"
    Push-Location $local
    & (Join-Path $local 'production.ps1') -Changed -NoMigrate
    Pop-Location

    Write-Host "`n--- checks (changed deploy) ---"
    Check "newfile.php deployed"           (Test-Path (Join-Path $server 'newfile.php'))
    Check "lib/util.php DELETED on server" (-not (Test-Path (Join-Path $server 'lib\util.php')))
    Check "protected uploads still kept"   (Test-Path (Join-Path $server 'uploads\data.txt'))
    Check "index.php still present"        (Test-Path (Join-Path $server 'index.php'))
}
finally {
    if ($srv -and -not $srv.HasExited) { Stop-Process -Id $srv.Id -Force }
    & $Php -r "`$p=new PDO('mysql:host=$DbHost','$DbUser','$DbPass'); `$p->exec('DROP DATABASE IF EXISTS $db');" 2>$null
    Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n==============================" -ForegroundColor Cyan
if ($script:fails -eq 0) { Write-Host "ALL CHECKS PASSED" -ForegroundColor Green }
else { Write-Host "$script:fails CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
