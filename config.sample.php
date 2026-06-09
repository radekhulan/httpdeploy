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

// ─── Allowed client IPs ───────────────────────────────────────────────────────
// Only these IPs / CIDR ranges may deploy. Leave the array empty to allow any
// IP (the token alone then guards the endpoint).
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
