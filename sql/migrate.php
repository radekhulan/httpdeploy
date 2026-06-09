<?php
/**
 * HTTPDeploy – database migration runner.
 *
 * Run from the command line:        php sql/migrate.php
 * Or automatically by deploy.php after a deploy (field migrate=1).
 *
 * How it works:
 *   1. Creates the database from config.php if it does not exist yet.
 *   2. Creates a `migrations` bookkeeping table if it does not exist.
 *   3. On a fresh database, applies `sql/schema.sql` once (version 0), if present.
 *   4. Applies every `sql/migrate_v<N>.sql` that has not been applied yet,
 *      in ascending order of N. Each applied file is recorded in `migrations`.
 *
 * SQL files are split on ';' and executed statement by statement. A handful of
 * "already exists" errors are tolerated so re-running is safe (idempotent):
 *   1050 table exists · 1060 duplicate column · 1061 duplicate key name
 *   1062 duplicate entry · 1091 can't DROP (does not exist)
 *
 * If no SQL files are present the runner does nothing – the database is left
 * untouched, so projects without migrations can ship without an empty schema.
 */

require_once __DIR__ . '/../config.php';

const HTTPDEPLOY_SQL_DIR = __DIR__;

function sqlStatements(string $file): array {
    $sql = file_get_contents($file);
    if ($sql === false) {
        throw new RuntimeException("Cannot read file: $file");
    }
    // strip line comments and split into individual statements
    $lines = array_filter(preg_split('/\R/', $sql), fn($l) => !preg_match('/^\s*--/', $l));
    return array_values(array_filter(array_map('trim', explode(';', implode("\n", $lines)))));
}

function runSqlFile(PDO $pdo, string $file): void {
    $ignorable = [1050, 1060, 1061, 1062, 1091];
    foreach (sqlStatements($file) as $stmt) {
        try {
            $pdo->exec($stmt);
        } catch (PDOException $e) {
            $code = isset($e->errorInfo[1]) ? (int)$e->errorInfo[1] : 0;
            if (in_array($code, $ignorable, true)) {
                continue; // change already applied, keep going
            }
            throw $e;
        }
    }
}

function markApplied(PDO $pdo, int $version, string $filename): void {
    $pdo->prepare('INSERT IGNORE INTO migrations (version, filename) VALUES (?, ?)')
        ->execute([$version, $filename]);
}

/** Create the configured database if it does not exist yet. */
function ensureDatabase(): void {
    $dsn  = sprintf('mysql:host=%s;charset=%s', DB_HOST, DB_CHARSET);
    $pdo  = new PDO($dsn, DB_USER, DB_PASS, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    $name = str_replace('`', '``', DB_NAME);
    $pdo->exec("CREATE DATABASE IF NOT EXISTS `$name` CHARACTER SET " . DB_CHARSET
             . ' COLLATE ' . DB_CHARSET . '_unicode_ci');
}

try {
    // ── Collect SQL files; nothing to do if there are none ───────────────────
    $schema    = HTTPDEPLOY_SQL_DIR . '/schema.sql';
    $versioned = [];
    foreach (glob(HTTPDEPLOY_SQL_DIR . '/migrate_v*.sql') as $f) {
        if (preg_match('/migrate_v(\d+)\.sql$/', $f, $m)) {
            $versioned[(int)$m[1]] = $f;
        }
    }
    ksort($versioned);

    if (!is_file($schema) && !$versioned) {
        echo "No SQL files found – nothing to migrate.\n";
        return;
    }

    // ── Connect & bookkeeping ────────────────────────────────────────────────
    ensureDatabase();
    $pdo = db();
    $pdo->exec(
        'CREATE TABLE IF NOT EXISTS migrations (
            version    INT UNSIGNED NOT NULL PRIMARY KEY,
            filename   VARCHAR(255) NOT NULL,
            applied_at TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4'
    );

    $applied = array_map('intval',
        $pdo->query('SELECT version FROM migrations')->fetchAll(PDO::FETCH_COLUMN));

    $ran = 0;

    // ── schema.sql = version 0 (initial schema on a fresh database) ──────────
    if (is_file($schema) && !in_array(0, $applied, true)) {
        echo "[0] schema.sql – applying initial schema...\n";
        runSqlFile($pdo, $schema);
        markApplied($pdo, 0, 'schema.sql');
        $ran++;
    }

    // ── Incremental migrations ───────────────────────────────────────────────
    foreach ($versioned as $version => $file) {
        if (in_array($version, $applied, true)) {
            continue;
        }
        echo "[$version] " . basename($file) . " – applying...\n";
        runSqlFile($pdo, $file);
        markApplied($pdo, $version, basename($file));
        $ran++;
    }

    echo $ran > 0
        ? "Done – migrations applied: $ran\n"
        : "Done – database already up to date.\n";
} catch (Throwable $e) {
    // On CLI we exit non-zero; when included by deploy.php we just print the
    // error so it shows up in the deploy response.
    if (PHP_SAPI === 'cli') {
        fwrite(STDERR, 'ERROR: ' . $e->getMessage() . "\n");
        exit(1);
    }
    echo 'ERROR: ' . $e->getMessage() . "\n";
}
