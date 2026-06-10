# HTTPDeploy

> 🇬🇧 **English** — [jump to the English version below ↓](#english)

**Minimalistický deploy přes HTTP pro omezené hostingy.**

HTTPDeploy je *nouzové* řešení nasazování pro levné nebo zamčené hostingy, které
nenabízejí **žádné SSH, žádný Git, žádné CI/CD a neumí se připojit na GitHub** —
typický sdílený hosting, kde je jediným reálným kanálem na server HTTP(S) a
případně FTP.

Princip je jednoduchý:

1. Na **lokálním stroji** spustíš `production.ps1` (Windows) nebo
   `production.sh` (Linux/macOS). Skript zabalí projekt do `tar.gz` a `POST`ne
   ho na server přes HTTPS.
2. Na **serveru** jediný soubor — `deploy.php` — balíček přijme, rozbalí ho do
   web rootu a (volitelně) spustí SQL migrace.

Žádní build agenti, žádné SSH klíče na serveru, žádná odchozí spojení ze serveru.
Lokální stroj pushuje, server rozbaluje.

> ⚠️ Je to pragmatický workaround, ne náhrada za pořádnou CI/CD pipeline. Pokud
> tvůj hosting umí SSH + Git, použij raději to.

---

## Jak to funguje

```
   ┌─────────────────────┐         HTTPS POST          ┌──────────────────────┐
   │   Lokální stroj     │   package.tar.gz  ───────▶  │        Server        │
   │                     │   X-Deploy-Token: …         │                      │
   │  production.ps1/sh  │   migrate=1                 │      deploy.php      │
   │   • git diff        │   delete=…                  │   • ověř IP+token    │
   │   • zabal tar.gz    │                             │   • rozbal do rootu  │
   │   • curl upload     │  ◀───────  textová odpověď  │   • spusť migrace    │
   └─────────────────────┘                             └──────────────────────┘
```

* Klient po serveru nikdy nechce, aby si něco stahoval — pošle mu bajty.
* Server ověří požadavek přes **IP allow-list** (volitelně) a **sdílený token**,
  pak rozbalí archiv do web rootu. K rozbalení používá `zlib` (`gzopen`) s malým
  vestavěným čtečem tar formátu a jako zálohu `Phar` — funguje tedy i na
  hostingu, kde je rozšíření `phar` vypnuté.
* **Běhová data jsou chráněná**: `config.php`, `.deploy-token`, VCS složky a
  cokoliv uvedeš v `DEPLOY_PROTECTED` se nikdy nepřepíše ani nesmaže.

---

## Soubory

| Soubor               | Kde běží      | K čemu slouží                                         |
|----------------------|---------------|-------------------------------------------------------|
| `deploy.php`         | **Server**    | Přijme balíček, rozbalí ho, spustí migrace            |
| `sql/migrate.php`    | **Server**    | Volitelný runner DB migrací (volá ho `deploy.php`)    |
| `production.ps1`     | Lokál (Win)   | Zabalí a nahraje projekt                              |
| `production.sh`      | Lokál (\*nix) | Zabalí a nahraje projekt                              |
| `config.sample.php`  | obojí         | Zkopíruj na `config.php` a vyplň                      |
| `.deployignore`      | Lokál         | Volitelně: další cesty vyloučené z uploadu            |

---

## Nastavení

### 1. Vlož nástroj do svého projektu

Zkopíruj `deploy.php`, složku `sql/`, `config.sample.php` a skripty
`production.*` do kořene svého webového projektu (do složky, která na serveru
odpovídá web rootu).

### 2. Vytvoř konfiguraci

```bash
cp config.sample.php config.php
```

Uprav `config.php`:

* **`DEPLOY_TOKEN`** — dlouhý náhodný sdílený tajný klíč. Vygeneruj ho přes:
  ```bash
  php -r "echo bin2hex(random_bytes(32)), PHP_EOL;"
  ```
  Můžeš ho nechat přímo zde, nebo dát do souboru `.deploy-token` vedle
  `config.php` (git-ignored) — pokud existuje, má přednost.
* **`DEPLOY_ALLOWED_IPS`** — volitelný seznam povolených IP / CIDR. Nech prázdné,
  pokud chceš spoléhat jen na token. Omezení na firemní/domácí IP vřele doporučeno.
* **`DEPLOY_PROTECTED`** — relativní cesty (uploady, logy, cache…), které deploy
  nikdy nesmí přepsat ani smazat.
* **`DB_*`** — potřeba jen pokud používáš migrace.

Stejný `config.php` musí existovat i **na serveru** (s vlastními DB přihlašovacími
údaji serveru). Je git-ignored a deploy ho nikdy nepřepíše, takže si každé
prostředí drží vlastní kopii.

### 3. Řekni klientovi, kam nasazovat

Předej `-Url` / `--url` při každém spuštění, nebo vytvoř v kořeni projektu soubor
`.deploy-url` s endpointem:

```
https://example.com/deploy.php
```

### 4. Zajisti, aby PHP mohlo zapisovat do web rootu

`deploy.php` zapisuje soubory přímo do své vlastní složky, takže PHP proces tam
musí mít právo zápisu. K rozbalení balíčku potřebuje **buď** `zlib` (`gzopen`,
prakticky v každém PHP buildu) **nebo** rozšíření `Phar` — stačí jedno z nich.

---

## Použití

### Plné nasazení

```powershell
# Windows
.\production.ps1
```
```bash
# Linux / macOS
./production.sh
```

Zabalí celý projekt (bez vyloučených cest), nahraje ho a spustí migrace. Plné
nasazení na serveru **nikdy nic nemaže**.

### Nasadit jen změny

```bash
./production.sh --changed              # soubory změněné posledním commitem
./production.sh --changed --since v1.2 # soubory změněné od tagu/ref v1.2
```

`--changed` (PowerShell: `-Changed`) nasadí jen soubory dotčené posledním
commitem **a smaže na serveru soubory, které ten commit odstranil**. Posílá obsah
pracovního stromu, takže se nasazuje to, co máš na disku.

### Nanečisto (dry run)

```bash
./production.sh --changed --dry-run    # vypíše, co by se poslalo/smazalo
```

### Bez migrací

```bash
./production.sh --no-migrate           # PowerShell: -NoMigrate
```

### Parametry

| PowerShell      | bash             | Význam                                            |
|-----------------|------------------|---------------------------------------------------|
| `-Url`          | `--url`          | Deploy endpoint (přebije `.deploy-url`)           |
| `-Token`        | `--token`        | Deploy token (přebije `.deploy-token`)            |
| `-Changed`      | `--changed`      | Nasadí jen soubory změněné posledním commitem     |
| `-Since <ref>`  | `--since <ref>`  | S `-Changed`: rozsah `<ref>..HEAD`                |
| `-NoMigrate`    | `--no-migrate`   | Přeskočí migrace                                  |
| `-DryRun`       | `--dry-run`      | Jen vypíše, nic nenahraje                         |

---

## Vyloučení souborů z uploadu

Klient nikdy nenahrává vlastní nástroje (`production.*`, `config.php`,
`config.sample.php`, `README.md`), VCS složky (`.git`, `.github`, `.svn`) ani
tajné soubory (`.deploy-token`, `.deploy-url`).

Pro výjimky specifické pro projekt přidej do kořene soubor **`.deployignore`** —
jedna cesta nebo prefix složky na řádek (`#` uvozuje komentář):

```
# .deployignore
node_modules
tests
storage/cache
*.map
uploads
```

> Na straně serveru je autoritativní pojistkou `DEPLOY_PROTECTED` — i kdyby se
> soubor do balíčku dostal, uvedené cesty se nikdy nepřepíšou ani nesmažou.

---

## Databázové migrace (volitelné)

Pokud na serveru existuje `sql/migrate.php`, `deploy.php` ho po rozbalení spustí
(pokud nebylo použito `--no-migrate`). Pokud neexistuje, deploy migrace prostě
přeskočí — jsou zcela volitelné.

Runner je založený na konvenci a žije ve složce `sql/`:

* **`sql/schema.sql`** — kompletní počáteční schéma. Aplikuje se **jednou** na
  čerstvou databázi jako *verze 0*.
* **`sql/migrate_v1.sql`, `sql/migrate_v2.sql`, …** — inkrementální změny,
  aplikované vzestupně podle `N`, každá zaznamenaná po úspěšném provedení.

Při prvním spuštění:

1. **Vytvoří databázi** pojmenovanou v `config.php`, pokud neexistuje.
2. Vytvoří evidenční tabulku `migrations`.
3. Aplikuje `schema.sql` (pokud existuje), pak všechny nečekané `migrate_v*.sql`.

Příkazy se dělí podle `;` a spouštějí jeden po druhém. Běžné chyby *„už existuje"*
(`1050`, `1060`, `1061`, `1062`, `1091`) se tolerují, takže opakované spuštění je
bezpečné.

Můžeš ho spustit i ručně:

```bash
php sql/migrate.php
```

Pokud `sql/` neobsahuje `schema.sql` ani žádné `migrate_v*.sql`, runner neudělá
nic a databázi nechá nedotčenou.

---

## Bezpečnost

* **Používej HTTPS.** Token putuje v hlavičce — nikdy nenasazuj přes prosté HTTP.
* **Omez podle IP**, kdykoliv to jde (`DEPLOY_ALLOWED_IPS`). Token je pojistka,
  ne jediná obranná linie.
* **Drž `deploy.php` za tokenem.** Kdokoliv, kdo umí poslat platný token, ti může
  přepsat web root. Ber token jako heslo; při úniku ho rotuj.
* `config.php` a `.deploy-token` jsou git-ignored — drž je mimo repozitář.
* Na prostředích, kam nenasazuješ, zvaž odstranění/přejmenování `deploy.php`.

---

## Požadavky

* **Server:** PHP 7.4+ se `zlib` **nebo** `Phar` (na rozbalení), `PDO`/`pdo_mysql`
  (jen pokud používáš migrace) a zapisovatelný web root.
* **Lokál:** `git`, `curl` a `tar` v `PATH`. PowerShell 5+ na Windows nebo
  Bash 4+ na Linux/macOS.

## Testování

Samostatné end-to-end testy jsou ve složce `test/` — `deploy-test.ps1` testuje
`production.ps1`, `deploy-test.sh` testuje `production.sh`. Každý spustí dočasný
PHP server hostující `deploy.php`, nasadí na něj vzorový projekt a ověří, že
soubory dorazí, chráněné cesty přežijí, migrace proběhnou a mazání v changed
režimu funguje. Potřebují PHP, git, tar, curl a lokální MariaDB/MySQL:

```powershell
# PowerShell klient
.\test\deploy-test.ps1                       # php z PATH, DB uživatel root, prázdné heslo
.\test\deploy-test.ps1 -Php c:\php\php.exe -DbUser root -DbPass secret -Port 8123
```
```bash
# bash klient (proměnné prostředí: PHP, PORT, DBHOST, DBUSER, DBPASS)
PHP=php DBUSER=root DBPASS=secret PORT=8101 ./test/deploy-test.sh
```

---

## Autor

**Radek Hulán** — [https://mywebdesign.cz/](https://mywebdesign.cz/)

---

## Licence

MIT. Použij to, uprav, nasaď.

---
---

<a name="english"></a>

# HTTPDeploy 🇬🇧 (English version)

> 🇨🇿 **Česky** — [skok na českou verzi nahoře ↑](#httpdeploy)

**A minimal HTTP-based deploy tool for restricted hosting.**

HTTPDeploy is a *last-resort* deployment solution for cheap or locked-down
hosting that offers **no SSH, no Git, no CI/CD and cannot reach out to GitHub** —
the kind of shared hosting where your only real channel to the server is HTTP(S)
and maybe FTP.

The idea is simple:

1. On your **local machine** you run `production.ps1` (Windows) or
   `production.sh` (Linux/macOS). It packs your project into a `tar.gz` and
   `POST`s it to the server over HTTPS.
2. On the **server**, a single file — `deploy.php` — receives the package,
   unpacks it into the web root, and (optionally) runs your SQL migrations.

No build agents, no SSH keys on the host, no outbound connections from the
server. Your local machine pushes; the server unpacks.

> ⚠️ This is a pragmatic workaround, not a replacement for a proper CI/CD
> pipeline. If your hosting supports SSH + Git, use that instead.

---

## How it works

```
   ┌─────────────────────┐         HTTPS POST          ┌──────────────────────┐
   │   Local machine     │   package.tar.gz  ───────▶  │       Server         │
   │                     │   X-Deploy-Token: …         │                      │
   │  production.ps1/sh  │   migrate=1                 │      deploy.php      │
   │   • git diff        │   delete=…                  │   • verify IP+token  │
   │   • pack tar.gz     │                             │   • unpack to root   │
   │   • curl upload     │  ◀───────  plain-text resp  │   • run migrations   │
   └─────────────────────┘                             └──────────────────────┘
```

* The client never trusts the server to fetch anything — it sends the bytes.
* The server authenticates the request by **IP allow-list** (optional) and a
  **shared token**, then unpacks the archive into the web root. Unpacking uses
  `zlib` (`gzopen`) with a small built-in tar reader, and falls back to `Phar`
  if `zlib` is unavailable — so it works even on hosting where the `phar`
  extension is disabled.
* **Runtime data is protected**: `config.php`, `.deploy-token`, the VCS folders
  and anything you list in `DEPLOY_PROTECTED` are never overwritten or deleted.

---

## Files

| File                 | Where it runs | Purpose                                              |
|----------------------|---------------|------------------------------------------------------|
| `deploy.php`         | **Server**    | Receives the package, unpacks it, triggers migrations |
| `sql/migrate.php`    | **Server**    | Optional DB migration runner (called by `deploy.php`) |
| `production.ps1`     | Local (Win)   | Packs and uploads the project                        |
| `production.sh`      | Local (\*nix) | Packs and uploads the project                        |
| `config.sample.php`  | both          | Copy to `config.php` and fill in                     |
| `.deployignore`      | Local         | Optional: extra paths to exclude from uploads        |

---

## Setup

### 1. Drop the tool into your project

Copy `deploy.php`, the `sql/` folder, `config.sample.php` and the
`production.*` scripts into the root of your web project (the folder that maps
to your web root on the server).

### 2. Create the config

```bash
cp config.sample.php config.php
```

Edit `config.php`:

* **`DEPLOY_TOKEN`** — a long random shared secret. Generate one with:
  ```bash
  php -r "echo bin2hex(random_bytes(32)), PHP_EOL;"
  ```
  You can keep it inline, or put it in a `.deploy-token` file next to
  `config.php` (git-ignored) — if present, that file wins.
* **`DEPLOY_ALLOWED_IPS`** — optional IP / CIDR allow-list. Leave empty to rely
  on the token alone. Restricting to your office/home IP is strongly recommended.
* **`DEPLOY_PROTECTED`** — relative paths (uploads, logs, caches…) that a deploy
  must never overwrite or delete.
* **`DB_*`** — only needed if you use migrations.

The same `config.php` must exist **on the server** too (with the server's own
DB credentials). It is git-ignored and never overwritten by a deploy, so each
environment keeps its own copy.

### 3. Tell the client where to deploy

Pass `-Url` / `--url` each time, or create a `.deploy-url` file in the project
root containing the endpoint:

```
https://example.com/deploy.php
```

### 4. Make sure PHP can write the web root

`deploy.php` writes files directly into its own directory, so the PHP process
must have write permission there. To unpack the package it needs **either**
`zlib` (`gzopen`, present on virtually every PHP build) **or** the `Phar`
extension — one of the two is enough.

---

## Usage

### Full deploy

```powershell
# Windows
.\production.ps1
```
```bash
# Linux / macOS
./production.sh
```

Packs the whole project (minus excluded paths), uploads it, and runs migrations.
A full deploy **never deletes** anything on the server.

### Deploy only what changed

```bash
./production.sh --changed              # files changed by the last commit
./production.sh --changed --since v1.2 # files changed since tag/ref v1.2
```

`--changed` (PowerShell: `-Changed`) deploys only the files touched by the last
commit, **and deletes on the server the files that commit removed**. It sends
the working-tree content, so what's on disk is what's deployed.

### Dry run

```bash
./production.sh --changed --dry-run    # print what would be sent/deleted
```

### Without migrations

```bash
./production.sh --no-migrate           # PowerShell: -NoMigrate
```

### Options

| PowerShell      | bash             | Meaning                                          |
|-----------------|------------------|--------------------------------------------------|
| `-Url`          | `--url`          | Deploy endpoint (overrides `.deploy-url`)        |
| `-Token`        | `--token`        | Deploy token (overrides `.deploy-token`)         |
| `-Changed`      | `--changed`      | Deploy only files changed by the last commit     |
| `-Since <ref>`  | `--since <ref>`  | With `-Changed`: range `<ref>..HEAD`             |
| `-NoMigrate`    | `--no-migrate`   | Skip running migrations                          |
| `-DryRun`       | `--dry-run`      | Print only, upload nothing                       |

---

## Excluding files from upload

The client never uploads its own tooling (`production.*`, `config.php`,
`config.sample.php`, `README.md`), the VCS folders (`.git`, `.github`, `.svn`)
or the secret files (`.deploy-token`, `.deploy-url`).

For project-specific exclusions, add a **`.deployignore`** file to the root —
one path or directory prefix per line (`#` starts a comment):

```
# .deployignore
node_modules
tests
storage/cache
*.map
uploads
```

> Server-side, `DEPLOY_PROTECTED` is the authoritative guard — even if a file
> slips into the package, the listed paths are never overwritten or deleted.

---

## Database migrations (optional)

If a `sql/migrate.php` exists on the server, `deploy.php` runs it after
unpacking (unless `--no-migrate` was used). If it doesn't exist, the deploy
simply skips migrations — they are entirely optional.

The runner is convention-based and lives in `sql/`:

* **`sql/schema.sql`** — the full initial schema. Applied **once** on a fresh
  database as *version 0*.
* **`sql/migrate_v1.sql`, `sql/migrate_v2.sql`, …** — incremental changes,
  applied in ascending order of `N`, each recorded once it succeeds.

On the first run it will:

1. **Create the database** named in `config.php` if it does not exist.
2. Create a `migrations` bookkeeping table.
3. Apply `schema.sql` (if present), then any pending `migrate_v*.sql`.

Statements are split on `;` and run one by one. Common *"already exists"* errors
(`1050`, `1060`, `1061`, `1062`, `1091`) are tolerated, so re-running is safe.

You can also run it by hand:

```bash
php sql/migrate.php
```

If `sql/` contains no `schema.sql` and no `migrate_v*.sql`, the runner does
nothing and leaves the database untouched.

---

## Security notes

* **Use HTTPS.** The token travels in a header — never deploy over plain HTTP.
* **Restrict by IP** whenever you can (`DEPLOY_ALLOWED_IPS`). The token is the
  fallback, not the only line of defense.
* **Keep `deploy.php` behind the token.** Anyone who can POST a valid token can
  overwrite your web root. Treat the token like a password; rotate it if leaked.
* `config.php` and `.deploy-token` are git-ignored — keep them out of your repo.
* Consider removing/renaming `deploy.php` on environments where you don't deploy.

---

## Requirements

* **Server:** PHP 7.4+ with `zlib` **or** `Phar` (to unpack), `PDO`/`pdo_mysql`
  (only if you use migrations), and a writable web root.
* **Local:** `git`, `curl` and `tar` on `PATH`. PowerShell 5+ on Windows or
  Bash 4+ on Linux/macOS.

## Testing

Self-contained end-to-end tests live in `test/` — `deploy-test.ps1` exercises
`production.ps1`, `deploy-test.sh` exercises `production.sh`. Each starts a
throwaway PHP server hosting `deploy.php`, deploys a sample project onto it, and
asserts files land, protected paths survive, migrations run and changed-mode
deletes work. They need PHP, git, tar, curl and a local MariaDB/MySQL:

```powershell
# PowerShell client
.\test\deploy-test.ps1                       # php on PATH, DB user root, empty password
.\test\deploy-test.ps1 -Php c:\php\php.exe -DbUser root -DbPass secret -Port 8123
```
```bash
# bash client (env vars: PHP, PORT, DBHOST, DBUSER, DBPASS)
PHP=php DBUSER=root DBPASS=secret PORT=8101 ./test/deploy-test.sh
```

---

## Author

**Radek Hulán** — [https://mywebdesign.cz/](https://mywebdesign.cz/)

---

## License

MIT. Use it, adapt it, ship it.
