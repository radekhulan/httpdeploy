<?php
/**
 * HTTPDeploy – server-side deploy endpoint.
 *
 * Receives a tar.gz package of your web project and unpacks it into the web
 * root, then optionally runs SQL migrations. It is meant for cheap/restricted
 * hosting that offers no SSH, no Git and no real deployment pipeline – you push
 * from your local machine over plain HTTPS instead.
 *
 *   POST /deploy.php
 *     header  X-Deploy-Token: <DEPLOY_TOKEN from config.php>
 *     field   package = tar.gz with the project files at the archive root
 *     field   migrate = 1  → run sql/migrate.php after unpacking (default 1)
 *     field   delete  = newline-separated list of relative paths to delete
 *                       on the server (used by production.* --changed mode)
 *
 * While the web root is being updated, a maintenance semaphore file
 * (.deploy-lock) is present in the web root. Your site can check for it and
 * serve a "be right back" page during the (usually sub-second) window. The lock
 * is removed when the deploy finishes, and also by a shutdown handler if the
 * deploy dies mid-way. See README ("Maintenance semaphore") and maintenance.html.
 *
 * Runtime data is never touched: config.php, .deploy-token and any path listed
 * in DEPLOY_PROTECTED, plus the VCS folders, are skipped on both copy and delete.
 *
 * Author: Radek Hulán – https://mywebdesign.cz/
 */

require_once __DIR__ . '/config.php';
header('Content-Type: text/plain; charset=utf-8');
@set_time_limit(120);

function fail($code, $msg) { http_response_code($code); exit($msg . "\n"); }
function rrmdir($d) {
    if (!is_dir($d)) return;
    foreach (new RecursiveIteratorIterator(
        new RecursiveDirectoryIterator($d, FilesystemIterator::SKIP_DOTS),
        RecursiveIteratorIterator::CHILD_FIRST) as $i) {
        $i->isDir() ? @rmdir($i->getPathname()) : @unlink($i->getPathname());
    }
    @rmdir($d);
}

/**
 * Decompress a .gz file to $dst. Tries zlib (gzopen, almost always available),
 * then PharData as a fallback. Returns true on success.
 */
function gunzip($src, $dst) {
    if (function_exists('gzopen')) {
        $in = @gzopen($src, 'rb');
        if ($in) {
            $out = @fopen($dst, 'wb');
            if ($out) {
                while (!gzeof($in)) { $c = gzread($in, 1 << 20); if ($c === false) break; fwrite($out, $c); }
                gzclose($in); fclose($out);
                if (is_file($dst) && filesize($dst) > 0) return true;
            } else { gzclose($in); }
        }
    }
    if (class_exists('PharData')) {
        try { (new PharData($src))->decompress(); return is_file($dst); }   // foo.tar.gz → foo.tar
        catch (Throwable $e) { /* fall through */ }
    }
    return false;
}

/**
 * Iterate the entries of an (uncompressed) tar file in pure PHP – no Phar /
 * phar:// needed. Calls $cb($relPath, $isDir, $data) for every regular file and
 * directory. With $wantData = false the file bodies are skipped (header-only
 * pass, used to detect a single wrapping folder cheaply).
 */
function tarEach($tarPath, $wantData, callable $cb) {
    $fh = @fopen($tarPath, 'rb');
    if (!$fh) return;
    $long = null;                                       // pending GNU long name
    while (!feof($fh)) {
        $h = fread($fh, 512);
        if ($h === false || strlen($h) < 512) break;
        if (rtrim($h, "\0") === '') break;              // zero block = end of archive
        $name = rtrim(substr($h, 0, 100), "\0");
        $type = substr($h, 156, 1);
        $size = (int) octdec(trim(substr($h, 124, 12)) ?: '0');
        $pre  = rtrim(substr($h, 345, 155), "\0");
        $pad  = ($size % 512) ? 512 - ($size % 512) : 0;
        if ($type === 'L') {                            // GNU long name → next entry's name
            $long = rtrim((string) stream_get_contents($fh, $size), "\0");
            if ($pad) fseek($fh, $pad, SEEK_CUR);
            continue;
        }
        if ($type === 'x' || $type === 'g') {           // pax/global headers → skip
            fseek($fh, $size + $pad, SEEK_CUR);
            continue;
        }
        if ($long !== null)     { $name = $long; $long = null; }
        elseif ($pre !== '')    { $name = $pre . '/' . $name; }
        $isDir  = ($type === '5') || substr($name, -1) === '/';
        $isFile = ($type === '0' || $type === "\0" || $type === '');
        if (!$isDir && !$isFile) { fseek($fh, $size + $pad, SEEK_CUR); continue; } // links etc.
        $data = null;
        if ($isFile && $size > 0) {
            if ($wantData) { $data = stream_get_contents($fh, $size); }
            else           { fseek($fh, $size, SEEK_CUR); }
        }
        if ($pad) fseek($fh, $pad, SEEK_CUR);
        $cb(rtrim(str_replace('\\', '/', $name), '/'), $isDir, $data);
    }
    fclose($fh);
}

// ── IP allow-list ─────────────────────────────────────────────────────────────
function ipInCidr($ip, $cidr) {
    if (strpos($cidr, '/') === false) return inet_pton($ip) === inet_pton($cidr);
    [$net, $bits] = explode('/', $cidr, 2);
    $ipBin  = @inet_pton($ip);
    $netBin = @inet_pton($net);
    if ($ipBin === false || $netBin === false || strlen($ipBin) !== strlen($netBin)) return false;
    $bits  = (int)$bits;
    $bytes = intdiv($bits, 8);
    $rem   = $bits % 8;
    if ($bytes && strncmp($ipBin, $netBin, $bytes) !== 0) return false;
    if ($rem) {
        $mask = chr(0xff << (8 - $rem) & 0xff);
        if ((ord($ipBin[$bytes]) & ord($mask)) !== (ord($netBin[$bytes]) & ord($mask))) return false;
    }
    return true;
}
$allowedIps = defined('DEPLOY_ALLOWED_IPS') ? DEPLOY_ALLOWED_IPS : [];
if ($allowedIps) {                                   // empty list = allow any IP
    $clientIp  = $_SERVER['REMOTE_ADDR'] ?? '';
    $ipAllowed = false;
    foreach ($allowedIps as $allowed) if (ipInCidr($clientIp, $allowed)) { $ipAllowed = true; break; }
    if (!$ipAllowed) fail(403, 'Deploy from this IP address is not allowed.');
}

// ── Authorization ─────────────────────────────────────────────────────────────
if (!defined('DEPLOY_TOKEN') || DEPLOY_TOKEN === '' || DEPLOY_TOKEN === 'CHANGE-ME-TO-A-LONG-RANDOM-STRING')
    fail(500, 'DEPLOY_TOKEN is not configured in config.php');
$token = $_SERVER['HTTP_X_DEPLOY_TOKEN'] ?? ($_POST['token'] ?? '');
if (!is_string($token) || !hash_equals(DEPLOY_TOKEN, $token)) fail(403, 'Invalid deploy token.');
if ($_SERVER['REQUEST_METHOD'] !== 'POST' || empty($_FILES['package']['tmp_name'])
    || $_FILES['package']['error'] !== UPLOAD_ERR_OK) fail(400, 'Missing uploaded package (field "package").');

$root = __DIR__;
$work = rtrim(sys_get_temp_dir(), '/') . '/deploy_' . bin2hex(random_bytes(5));
@mkdir($work, 0700, true);
if (!is_dir($work)) fail(500, 'Cannot create temporary folder.');

$tarGz = $work . '/package.tar.gz';
if (!move_uploaded_file($_FILES['package']['tmp_name'], $tarGz)) { rrmdir($work); fail(500, 'Cannot store package.'); }

// ── Decompress .tar.gz → .tar (zlib, or Phar as fallback) ─────────────────────
$tar = $work . '/package.tar';
if (!gunzip($tarGz, $tar)) {
    rrmdir($work);
    fail(500, 'Cannot unpack package: neither zlib (gzopen) nor Phar is available on this server.');
}

// First pass (headers only): a single wrapping folder (e.g. a GitHub API
// tarball) → descend into it.
$names = [];
tarEach($tar, false, function ($name, $isDir, $_) use (&$names) { if ($name !== '') $names[] = $name; });
if (!$names) { rrmdir($work); fail(500, 'Archive contains no data.'); }
$tops = [];
foreach ($names as $n) { $tops[explode('/', $n, 2)[0]] = true; }
$wrap = '';
if (count($tops) === 1) {
    $only = array_key_first($tops);
    foreach ($names as $n) { if (strpos($n, $only . '/') === 0) { $wrap = $only . '/'; break; } }
}

// ── Protected paths (never overwritten, never deleted) ────────────────────────
$protected = array_merge(
    ['config.php', '.deploy-token', '.deployignore', '.deploy-lock', '.git', '.github', '.svn'],
    defined('DEPLOY_PROTECTED') ? DEPLOY_PROTECTED : []
);
$isExcluded = function ($rel) use ($protected) {
    $rel = str_replace('\\', '/', $rel);
    foreach ($protected as $ex) {
        $ex = str_replace('\\', '/', trim($ex, '/'));
        if ($ex !== '' && ($rel === $ex || strpos($rel, $ex . '/') === 0)) return true;
    }
    return false;
};

// ── Maintenance semaphore: raise it just before the web root is touched ───────
// Present for the whole sync + delete + migrations window. The production site
// can check for this file and serve a maintenance page (see maintenance.html).
// The shutdown handler guarantees it is cleared even on a fatal error / timeout.
$lockFile    = $root . '/.deploy-lock';
$lockCleared = false;
$releaseLock = function () use ($lockFile, &$lockCleared) {
    if ($lockCleared) return;
    if (is_file($lockFile)) @unlink($lockFile);
    $lockCleared = true;
};
@file_put_contents($lockFile, gmdate('c') . " deploy in progress\n", LOCK_EX);
register_shutdown_function($releaseLock);

// ── Sync into the web root (second pass: extract bodies) ──────────────────────
$copied = 0;
tarEach($tar, true, function ($rel, $isDir, $data) use (&$copied, $wrap, $isExcluded, $root) {
    if ($wrap !== '' && strpos($rel, $wrap) === 0) $rel = substr($rel, strlen($wrap));
    if ($rel === '' || strpos($rel, '..') !== false || $isExcluded($rel)) return;
    $dest = $root . '/' . $rel;
    if ($isDir) { if (!is_dir($dest)) @mkdir($dest, 0755, true); return; }
    if (!is_dir(dirname($dest))) @mkdir(dirname($dest), 0755, true);
    if (@file_put_contents($dest, (string) $data) !== false) $copied++;
});

// ── Delete files removed by a commit (production.* --changed mode) ────────────
$deleted = 0; $delSkipped = 0;
$delList = trim((string)($_POST['delete'] ?? ''));
if ($delList !== '') {
    $rootReal = realpath($root);
    foreach (preg_split('/\r\n|\r|\n/', $delList) as $rel) {
        $rel = trim(str_replace('\\', '/', $rel));
        if ($rel === '' || strpos($rel, '..') !== false || $isExcluded($rel)) { $delSkipped++; continue; }
        $dest = $root . '/' . $rel;
        $real = realpath($dest);
        // must be a plain file inside the web root
        if ($real === false || $rootReal === false
            || strncmp($real, $rootReal . DIRECTORY_SEPARATOR, strlen($rootReal) + 1) !== 0
            || !is_file($real)) { $delSkipped++; continue; }
        if (@unlink($real)) {
            $deleted++;
            // clean up now-empty parent folders up towards the root
            $dir = dirname($real);
            while ($dir !== $rootReal && strncmp($dir, $rootReal . DIRECTORY_SEPARATOR, strlen($rootReal) + 1) === 0) {
                if (@rmdir($dir)) { $dir = dirname($dir); } else { break; }
            }
        } else { $delSkipped++; }
    }
}

// ── Migrations (only if a runner is present) ──────────────────────────────────
$migrateScript = $root . '/sql/migrate.php';
$migrateOut    = '';
if (($_POST['migrate'] ?? '1') !== '0' && is_file($migrateScript)) {
    ob_start();
    try { require $migrateScript; }
    catch (Throwable $e) { echo 'Migration error: ' . $e->getMessage() . "\n"; }
    $migrateOut = ob_get_clean();
}

rrmdir($work);
$releaseLock();                                      // lower the maintenance semaphore
echo "OK – files deployed: $copied\n";
if ($deleted || $delSkipped) echo "Files deleted: $deleted" . ($delSkipped ? " (skipped: $delSkipped)" : '') . "\n";
if ($migrateOut !== '') echo "\n--- migrations ---\n$migrateOut\n";
