<?php
/**
 * HTTPDeploy – configuration.
 *
 * Copy this file to `config.php` and adjust the values below.
 * `config.php` is git-ignored and is NEVER overwritten or deleted by a deploy,
 * so each environment (local / production) keeps its own copy.
 */

// ─── Deploy token ─────────────────────────────────────────────────────────────
// Shared secret. The client sends it in the `X-Deploy-Token` header and the
// server compares it against this value. Generate a strong one:
//
//     php -r "echo bin2hex(random_bytes(32)), PHP_EOL;"
//
// You can hard-code it here, or keep it in a `.deploy-token` file next to this
// file (git-ignored) – if that file exists it takes precedence.
define('DEPLOY_TOKEN', is_file(__DIR__ . '/.deploy-token')
    ? trim(file_get_contents(__DIR__ . '/.deploy-token'))
    : 'CHANGE-ME-TO-A-LONG-RANDOM-STRING');

// ─── Require HTTPS ────────────────────────────────────────────────────────────
// The deploy token is sent in a request header; over plain HTTP anyone on the
// network path can read it. By default the endpoint refuses non-TLS requests.
// Set this to true ONLY for trusted-network / local testing setups.
// define('DEPLOY_ALLOW_HTTP', true);

// ─── Allowed client IPs ──────────────────────────────────────  ★ RECOMMENDED ─
// Only these IPs / CIDR ranges may deploy. This is your STRONGEST control and
// you should set it whenever you can: the endpoint exposes remote code execution
// to anyone who holds the token, so an empty list means the token is the ONLY
// thing standing between the internet and your web root. There is no rate limit
// or lockout — a leaked or guessable token is game over.
//
//   • Always-on server / office with a static IP → list it here.
//   • Dynamic IP → list your ISP's range, a VPN exit IP, or your CI runner's IP.
//   • Genuinely cannot pin an IP → leave it empty, but then use a long random
//     token (php -r "echo bin2hex(random_bytes(32));") and keep HTTPS on.
//
// Leaving the array empty allows ANY IP (token-only protection — least safe).
define('DEPLOY_ALLOWED_IPS', [
    // '203.0.113.10',
    // '198.51.100.0/24',
    // '2001:db8:1234::/48',
]);

// ─── Protected paths ──────────────────────────────────────────────────────────
// Relative paths (files or directory prefixes) inside the web root that a deploy
// must never overwrite or delete – runtime data, secrets, uploads, logs, …
// `config.php`, `.deploy-token` and the VCS folders are always protected.
define('DEPLOY_PROTECTED', [
    // 'uploads',
    // 'logs',
    // 'storage',
]);

// ─── Size limits ──────────────────────────────────────────────────────────────
// Caps that protect the server from an oversized or maliciously compressed
// package (a tiny "gzip bomb" that inflates to fill the disk). A package over
// the compressed limit is rejected before unpacking; decompression is aborted
// once the unpacked size passes the second limit. Raise them if your project is
// genuinely larger. Defaults (when not defined) are 100 MB / 1024 MB.
// define('DEPLOY_MAX_PACKAGE_MB',  100);   // max uploaded .tar.gz size
// define('DEPLOY_MAX_UNPACKED_MB', 1024);  // max size after decompression

// ─── Database (optional – only used by sql/migrate.php) ───────────────────────
define('DB_HOST',    'localhost');
define('DB_NAME',    'httpdeploy');
define('DB_USER',    'root');
define('DB_PASS',    '');
define('DB_CHARSET', 'utf8mb4');

/**
 * Lazy PDO singleton used by the migration runner (sql/migrate.php).
 * Safe to leave as-is even if you do not use migrations – it only connects
 * when actually called.
 */
function db(): PDO {
    static $pdo = null;
    if ($pdo === null) {
        $dsn = sprintf('mysql:host=%s;dbname=%s;charset=%s', DB_HOST, DB_NAME, DB_CHARSET);
        $pdo = new PDO($dsn, DB_USER, DB_PASS, [
            PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES   => false,
        ]);
    }
    return $pdo;
}
