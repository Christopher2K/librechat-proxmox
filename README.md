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
curl -fsSL https://raw.githubusercontent.com/Christopher2K/librechat-proxmox/main/create-ct.sh | bash
```

When run from a terminal, the script prompts for each setting — CT ID, hostname,
CPU cores, RAM, swap, disk size, storage pool, network bridge, and Debian
version — each pre-filled with a sensible default. Override any of them via
environment variables, or run fully unattended with `NONINTERACTIVE=1`:

```bash
# interactive (whiptail prompts)
curl -fsSL https://raw.githubusercontent.com/Christopher2K/librechat-proxmox/main/create-ct.sh | bash

# unattended, with custom values
curl -fsSL https://raw.githubusercontent.com/Christopher2K/librechat-proxmox/main/create-ct.sh | \
  CTID=200 STORAGE=zfs BRIDGE=vmbr1 NONINTERACTIVE=1 bash
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
  cd /opt/librechat && docker compose up -d --force-recreate
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
cd /opt/librechat && docker compose up -d --force-recreate
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

## Cloudflare Tunnel (HTTPS + domain)

The stack defaults to plain HTTP on a LAN IP. To reach it from the internet with
TLS and a real domain, front it with a Cloudflare Tunnel (`cloudflared`) and
point LibreChat at your public URLs.

### 1. Point LibreChat at your domain

Edit `/opt/librechat/.env` (these lines already exist — just change their values):

```
# The public URL users load (used for links, OAuth callbacks, cookies).
DOMAIN_CLIENT=https://chat.example.com
DOMAIN_SERVER=https://chat.example.com

# Secure cookies — now that you're serving HTTPS.
SESSION_COOKIE_SECURE=true

# The admin panel's public URL.
ADMIN_PANEL_URL=https://admin.example.com
ADMIN_PANEL_SESSION_COOKIE_SECURE=true

# Lock signups before exposing anything.
ALLOW_REGISTRATION=false
```

`TRUST_PROXY=1` is already set, so LibreChat honours the `X-Forwarded-*`
headers the tunnel sends. Restart (force-recreate so the new values are picked
up):

```bash
cd /opt/librechat && docker compose up -d --force-recreate
```

### 2. Run a Cloudflare Tunnel

The easiest is a quick tunnel from the LXC itself:

```bash
cloudflared tunnel --url http://localhost:3080
```

For two hostnames (chat + admin), use a named tunnel with ingress rules:

```yaml
# /etc/cloudflared/config.yml
tunnel: <TUNNEL_UUID>
credentials-file: /etc/cloudflared/<TUNNEL_UUID>.json

ingress:
  - hostname: chat.example.com
    service: http://localhost:3080
  - hostname: admin.example.com
    service: http://localhost:3000
  - service: http_status:404
```

Run `cloudflared` on the same LXC (point the services at `localhost`) or on any
host that can reach `<CT-IP>:3080` / `<CT-IP>:3000`.

### 3. Protect the admin panel

**Do not expose the admin panel to the internet unprotected** — anyone who
reaches `admin.example.com` and obtains credentials controls the whole
instance. Either:

- Put **Cloudflare Access** in front of `admin.example.com` (an email/policy
  gate that runs before traffic reaches your server), or
- Keep the admin panel **LAN-only**: only publish `chat.example.com` and leave
  `:3000` un-tunnelled.

### Cloudflare limits to be aware of

- **Uploads are capped at ~100 MB** through the Cloudflare proxy (free plans).
  Large file/RAG uploads may fail; route those around the proxy if you need more.
- **Streaming/SSE responses time out after ~100 s** on the Cloudflare proxy, so
  very long generations can appear to stall.

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
- The container console **auto-logs in as root** (like the community-script CTs)
  instead of showing a login prompt. Anyone who can open the Proxmox web console
  for the CT therefore gets a root shell, so keep your Proxmox login secure.
  You can still use `pct enter <CTID>` from the host shell as an alternative.
