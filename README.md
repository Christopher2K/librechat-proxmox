# librechat-proxmox

A Docker Compose deployment of **[LibreChat](https://www.librechat.ai/)** for
Proxmox — including the **Admin Panel**, which the community-scripts native
install does not ship.

This deploys the *official* LibreChat stack via Docker Compose inside a Debian
LXC (or VM), giving you the full set of services wired together correctly:

| Service | URL |
|---|---|
| LibreChat (chat UI + API) | `http://<IP>:3080` |
| **Admin Panel** | `http://<IP>:3000` |
| MongoDB, Meilisearch, pgvector, RAG API | internal only |

## Why Docker Compose?

LibreChat is a multi-service app (MongoDB + Meilisearch + pgvector + RAG API +
the Node backend + the Bun/Vite admin panel). Its
[official `docker-compose.yml`](https://github.com/LibreChat-AI/LibreChat/blob/main/docker-compose.yml)
wires all of these together and bundles the admin panel. Re-implementing that
natively (as the community-scripts CT script does) is fragile and, in practice,
ships **without** the admin panel.

## Requirements

- Proxmox VE (or any host running Debian 12/13).
- An **LXC must have `nesting` and `keyctl` features enabled** (Docker needs
  them). `create-ct.sh` sets these automatically.
- ~24 GB disk, 6 GB RAM recommended.

## Quick start

### Option A — turnkey (Proxmox host)

```bash
# on the Proxmox host, edit storage/bridge at the top of the script first
curl -fsSL https://raw.githubusercontent.com/Christopher2K/librechat-proxmox/main/create-ct.sh | bash
```

### Option B — inside an existing Debian LXC/VM

```bash
curl -fsSL https://raw.githubusercontent.com/Christopher2K/librechat-proxmox/main/install.sh | bash
```

If you create the LXC manually, set **Options → Features** to enable
`nesting` and `keyctl`, then run the installer above inside it.

## First login & admin

- Open `http://<IP>:3080`, register an account. **The first registered user is
  automatically the admin** in a single-tenant deployment.
- Log in to the **Admin Panel** at `http://<IP>:3000` with that same account.
- Once you've registered, lock registration:

  ```bash
  sed -i 's/^ALLOW_REGISTRATION=true/ALLOW_REGISTRATION=false/' /opt/librechat/.env
  cd /opt/librechat && docker compose up -d
  ```

## Update

```bash
curl -fsSL https://raw.githubusercontent.com/Christopher2K/librechat-proxmox/main/install.sh | bash -s -- update
```

## Configuration

Everything lives in `/opt/librechat`:

- `.env` — secrets, domains, auth, endpoints (see [dotenv docs](https://www.librechat.ai/docs/configuration/dotenv)).
- `docker-compose.yml` — the stack definition.
- `librechat.yaml` — optional custom config (endpoints, model lists); mount it
  into the `api` service if you need it.

After editing `.env`, run:

```bash
cd /opt/librechat && docker compose up -d
```

### Enabling RAG / file uploads embeddings

The RAG API defaults to OpenAI embeddings. Add your key to `/opt/librechat/.env`
and restart:

```
RAG_OPENAI_API_KEY=sk-...
```

### Adding model API keys

Add e.g. `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GOOGLE_KEY` to
`/opt/librechat/.env` (or set them per-user in the UI), then restart.

## Files

- `install.sh` — self-contained installer (also supports `update`).
- `create-ct.sh` — Proxmox-host helper that creates the LXC and runs the installer.
- `docker-compose.yml` — the stack (reference copy; `install.sh` writes the same).
- `.env.example` — reference configuration template.

## Notes & security

- The stack is single-node and **not** hardened for internet exposure. Put it
  behind a reverse proxy with TLS if it must be reachable from outside your LAN.
- MongoDB runs with `--noauth` but is **not** published to the host — it is only
  reachable on the internal Compose network.
- `SESSION_COOKIE_SECURE=false` and `ADMIN_PANEL_SESSION_COOKIE_SECURE=false`
  are set because the default install is plain HTTP. If you front it with HTTPS,
  switch these back to `true`.
