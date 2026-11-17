<div align="center">

# FileDeck

**Every server you own, on one desktop, in your browser.**

A self-hosted file manager with real windows, safe transfers, a conflict-proof editor, a terminal and live monitoring.
Local folders and SFTP servers side by side, with your data's integrity first.

[Quick start](#quick-start) · [Features](#what-you-get) · [Security](#built-to-be-trusted) · [Docs](docs/operations.md) · [Develop](#develop)

![FileDeck desktop](docs/screenshots/desktop.png)

</div>

---

## Why FileDeck

You have a NAS, a few VPSs, a homelab, maybe a jump host in front of the interesting ones. Moving files between them means
juggling SFTP clients, scp one-liners and terminals, and hoping a half-finished copy did not quietly corrupt something.

FileDeck puts all of it behind one login, on a desktop you can arrange however you like, and it **verifies** what it writes.

Priorities, in this order: **data integrity, security, filesystem correctness, transfer reliability, usability.**

## What you get

### A desktop, not a page of links
Open as many windows as you want: Finder, editor, terminal, monitor. Drag files between windows to copy or move, snap and tile
windows, minimize a terminal and it stays connected. The layout is remembered. Light, dark or follow the system.

![Finder](docs/screenshots/finder.png)

* **Finder** with Icon, List, Column and Gallery views. Folders with 10,000 entries stay responsive.
* Create, rename, duplicate, copy, move and delete with conflict handling, a recoverable **Trash**, filename search and safe previews.
* **Ctrl/Cmd+K** command palette over apps, windows, folders and actions, and a Servers menu to jump straight to any server.

![Command palette](docs/screenshots/palette.png)

### Transfers you can trust
Big files, flaky Wi-Fi, a closed laptop lid: transfers resume.

![Transfers](docs/screenshots/transfers.png)

* **Resumable chunked uploads** of very large files, hashed in the browser, staged durably, then verified again at the destination.
* **Range-resumable downloads** with a checksum *Verify* step, and streamed ZIPs.
* **Copy and move between servers.** A move deletes the source only after everything is verified.
* Live progress, pause / resume / cancel / retry, a speed graph, and resume after a page reload.

### An editor that never loses someone else's work
![Editor](docs/screenshots/editor.png)

Monaco in its own windows, with tabs from different servers side by side. Every save is checked against the version you opened,
written to a temp file, read back and verified, and only then committed. On a conflict you can compare, reload, save as a copy or
overwrite (audited). A lost connection never shows a false "saved".

### Terminal and monitoring, over the SSH you already have
![Terminal](docs/screenshots/terminal.png)

* **Terminal:** a real shell on any SFTP server in its own window. Off by default per server, granted per user, credentials stay on
  the server, and each session is audited (who, where, how long) without ever recording what you typed.
* **Monitor:** live CPU, memory, disk, network and processes for any SFTP server, with nothing installed on it.
* **Host health** (opt-in): the FileDeck host's own CPU, memory and disks in the bottom bar.

![Monitor](docs/screenshots/monitor.png)

### Built for real server fleets
![Servers](docs/screenshots/servers.png)

* Add servers in the browser with **host-key confirmation and pinning**, group them in the sidebar, and give them a DNS-name label.
* **Jump hosts:** servers reachable only through another server work in the Finder, editor, terminal and monitor.
* **MFA-protected servers:** never contacted until you click Connect, with approval prompts shown right where you are.
* **Launcher** for your web apps, with shared ones published by admins. Apps open without sending any FileDeck credentials.
* A **Servers** table for admins to set groups, routes and who is enabled, all in one place.

## Built to be trusted

* **Credentials are encrypted** on the server and never sent to the browser. The one exception is the admin-only Wallet: it asks for
  your password again, locks after a minute, reveals one secret at a time and is audited.
* **Per-root permissions** (RBAC) and an **audit log** of what happened and who did it.
* Containers run as non-root with a read-only root filesystem, no capabilities and `no-new-privileges`.
* Only the web port is published. PostgreSQL is reachable only inside the Compose network.
* Terminal sessions end the moment access ends.

## Quick start

You need Docker with Compose. The image is published on GitHub Container Registry, so nothing is built locally.

```bash
# 1. Get compose-github.yaml from this repository, then in the same folder:
docker run --rm ghcr.io/phreak1979/filedeck:latest init-secrets > .env    # generates the secrets

# 2. Edit .env: set PUBLIC_URL to the exact address you will type in the browser

# 3. Start it
docker compose -f compose-github.yaml up -d
```

Open `http://127.0.0.1:8088` (or your `PUBLIC_URL`) and sign in as `admin`. The password is the `BOOTSTRAP_ADMIN_PASSWORD` line in
`.env`. FileDeck never prints it in its logs. Change it after the first login.

**Update** at any time:

```bash
docker compose -f compose-github.yaml pull && docker compose -f compose-github.yaml up -d
```

* **HTTPS:** put Nginx Proxy Manager (or any TLS proxy) in front. See [docs/operations.md](docs/operations.md).
* **Local folders** can only live under `/mnt` inside the container. The compose file mounts `FILEDECK_DATA_DIR` there.
* **Backups, key rotation, a lost admin password:** all in [docs/operations.md](docs/operations.md).
* Prefer not to use `init-secrets`? Copy `env.github.example` to `.env` and fill in the required values. It explains each one.

### Build from source instead

```bash
./scripts/init-secrets.sh            # creates ./secrets (prints the initial admin password once)
cp .env.example .env                 # set PUBLIC_URL and FILEDECK_DATA_DIR / FILEDECK_UID / FILEDECK_GID
docker compose up -d --build
scripts/smoke.sh                     # optional: build, start, log in, list files, check hardening, tear down
```

## Status

All planned phases are done: Foundation, Finder, Transfers, Editor and Launcher, plus the Terminal, Monitor, host health, server
groups, jump hosts and MFA support described above. **Next: hardening.** The full plan is in
`FileDeck_Technical_Specification.md` and `openspec/`.

## Documentation

* [docs/operations.md](docs/operations.md): running it, HTTPS, backups, transfers, editor, terminal, monitoring, upgrading
* [docs/providers.md](docs/providers.md): exactly what the LOCAL and SFTP providers guarantee, and where SFTP is weaker
* [docs/accessibility.md](docs/accessibility.md): keyboard use and accessibility
* [docs/openapi.json](docs/openapi.json): the API (also served at `/api/v1/openapi.json`)

---

## Develop

Requires Node 22+, pnpm 12, Docker.

```bash
pnpm install
docker run -d --name filedeck-dev-pg -e POSTGRES_USER=filedeck -e POSTGRES_PASSWORD=filedeck \
  -e POSTGRES_DB=filedeck -p 127.0.0.1:55440:5432 postgres:17-alpine
export DATABASE_URL=postgresql://filedeck:filedeck@127.0.0.1:55440/filedeck
pnpm db:deploy                       # apply migrations
pnpm test                            # unit + integration + security + resilience (needs Postgres; Docker for SFTP suites)
pnpm typecheck && pnpm lint
pnpm test:e2e                        # Playwright against your system Chrome: own database, fixtures, API and web server
```

Dev servers: `pnpm --filter @filedeck/api dev` and `pnpm --filter @filedeck/web dev` (the web dev server proxies `/api`;
set `PUBLIC_URL` to the exact origin you browse, e.g. `http://127.0.0.1:5183`, and `SESSION_COOKIE_SECURE=false`,
`SESSION_COOKIE_NAME=filedeck_session` for plain HTTP).

Test databases/servers: the suite uses `filedeck_test` on the same Postgres and starts a throwaway chrooted OpenSSH
container for the SFTP suites (set `FILEDECK_SKIP_SFTP=1` to skip them).

## Layout

```
apps/{web,api,worker}      React shell · Fastify API (OpenAPI 3.1 at /api/v1/openapi.json) · transfer worker
packages/shared            Zod schemas, error codes, typed config (browser-safe entry; Node config at /config)
packages/db                Prisma client            prisma/   schema + migrations
packages/filesystem-core   provider contract, path guard
packages/provider-local    LOCAL provider (fd-anchored, symlink-safe)
packages/provider-sftp     SFTP provider (host-key pinning, pooling, safe overwrite)
packages/transfer-core     transfer state machine, leases, fencing
tests/                     contract · security · resilience · integration
docs/                      providers.md (capability matrix and guarantees), operations.md, accessibility.md, openapi.json
```

See `docs/providers.md` for exactly what each provider guarantees (and where SFTP is weaker).
