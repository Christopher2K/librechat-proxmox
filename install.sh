#!/usr/bin/env bash
# LibreChat (Docker Compose) installer for Proxmox LXC / Debian.
#
# Installs Docker + Compose and deploys the full LibreChat stack:
#   - LibreChat (api + frontend)  -> http://<IP>:3080
#   - LibreChat Admin Panel       -> http://<IP>:3000
#   - MongoDB, Meilisearch, pgvector, RAG API (internal)
#
# Usage:
#   curl -fsSL <repo>/install.sh | bash          # fresh install
#   curl -fsSL <repo>/install.sh | bash -s -- update   # update images
#
# Requires: Debian 12/13 (LXC needs nesting + keyctl), run as root.

set -euo pipefail

APP="LibreChat"
INSTALL_DIR="/opt/librechat"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
ENV_FILE="$INSTALL_DIR/.env"
PU="1000" # container user/group for bind-mounted data

# ---------------------------------------------------------------- helpers

info() { printf '\033[0;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[WARN]\033[0m %s\n' "$*"; }
die()  { printf '\033[0;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

detect_ip() {
  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
  [ -z "$ip" ] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  [ -z "$ip" ] && ip="127.0.0.1"
  echo "$ip"
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "Please run as root (e.g. sudo)."
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "Docker + Compose already installed."
    return
  fi
  info "Installing Docker Engine + Compose plugin..."
  apt-get update -y >/dev/null
  apt-get install -y curl ca-certificates gnupg openssl >/dev/null
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker >/dev/null 2>&1 || true
  docker compose version >/dev/null 2>&1 || die "Docker Compose plugin missing after install."
  ok "Docker installed."
}

write_compose() {
  # Quoted heredoc on purpose: ${VAR} placeholders must reach Docker Compose
  # literally so it interpolates them from the .env file at run time.
  cat >"$COMPOSE_FILE" <<'COMPOSE'
services:
  api:
    container_name: LibreChat
    image: registry.librechat.ai/librechat-ai/librechat-dev:latest
    ports:
      - "${PORT}:${PORT}"
    depends_on:
      - mongodb
      - rag_api
    restart: always
    user: "${UID}:${GID}"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    environment:
      - HOST=0.0.0.0
      - MONGO_URI=mongodb://mongodb:27017/LibreChat
      - MEILI_HOST=http://meilisearch:7700
      - LIBRECHAT_TEMP_CREDENTIALS_PATH=/app/data/.env.temp
      - RAG_PORT=${RAG_PORT:-8000}
      - RAG_API_URL=http://rag_api:${RAG_PORT:-8000}
    volumes:
      - ./.env:/app/.env
      - ./images:/app/client/public/images
      - ./uploads:/app/uploads
      - ./logs:/app/logs
      - ./skill:/app/skill
      - librechat-data:/app/data

  admin-panel:
    container_name: LibreChat-Admin-Panel
    image: registry.librechat.ai/librechat-ai/librechat-admin-panel:latest
    ports:
      - "${ADMIN_PANEL_PORT:-3000}:3000"
    depends_on:
      - api
    restart: always
    environment:
      - PORT=3000
      - SESSION_SECRET=${ADMIN_PANEL_SESSION_SECRET}
      - API_SERVER_URL=http://api:${PORT:-3080}
      - VITE_API_BASE_URL=${DOMAIN_CLIENT:-http://localhost:3080}
      - SESSION_COOKIE_SECURE=${ADMIN_PANEL_SESSION_COOKIE_SECURE:-false}

  mongodb:
    container_name: chat-mongodb
    image: mongo:8.0.20
    restart: always
    user: "${UID}:${GID}"
    volumes:
      - ./data-node:/data/db
    command: mongod --noauth

  meilisearch:
    container_name: chat-meilisearch
    image: getmeili/meilisearch:v1.35.1
    restart: always
    user: "${UID}:${GID}"
    environment:
      - MEILI_HOST=http://meilisearch:7700
      - MEILI_NO_ANALYTICS=true
      - MEILI_MASTER_KEY=${MEILI_MASTER_KEY}
    volumes:
      - ./meili_data:/meili_data

  vectordb:
    container_name: vectordb
    image: pgvector/pgvector:0.8.0-pg15-trixie
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    restart: always
    volumes:
      - pgdata:/var/lib/postgresql/data

  rag_api:
    container_name: rag_api
    image: registry.librechat.ai/librechat-ai/librechat-rag-api-dev-lite:latest
    environment:
      - DB_HOST=vectordb
      - RAG_PORT=${RAG_PORT:-8000}
    restart: always
    depends_on:
      - vectordb
    env_file:
      - .env
    volumes:
      - rag-uploads:/app/uploads

volumes:
  pgdata:
  librechat-data:
  rag-uploads:
COMPOSE
  ok "Wrote $COMPOSE_FILE"
}

write_env() {
  local ip="$1"
  local jwt jwt_ref creds_key creds_iv meili_key admin_secret pg_pass

  jwt=$(openssl rand -hex 32)
  jwt_ref=$(openssl rand -hex 32)
  creds_key=$(openssl rand -hex 32)
  creds_iv=$(openssl rand -hex 16)
  meili_key=$(openssl rand -hex 32)
  admin_secret=$(openssl rand -hex 32)
  pg_pass=$(openssl rand -hex 24)

  cat >"$ENV_FILE" <<EOF
# LibreChat + Admin Panel configuration (generated by install.sh)
UID=${PU}
GID=${PU}

# Server
HOST=0.0.0.0
PORT=3080
DOMAIN_CLIENT=http://${ip}:3080
DOMAIN_SERVER=http://${ip}:3080
NO_INDEX=true
TRUST_PROXY=1
SESSION_COOKIE_SECURE=false

# Admin panel
ADMIN_PANEL_PORT=3000
ADMIN_PANEL_SESSION_SECRET=${admin_secret}
ADMIN_PANEL_SESSION_COOKIE_SECURE=false
ADMIN_PANEL_URL=http://${ip}:3000

# Secrets
JWT_SECRET=${jwt}
JWT_REFRESH_SECRET=${jwt_ref}
CREDS_KEY=${creds_key}
CREDS_IV=${creds_iv}

# Auth
ALLOW_EMAIL_LOGIN=true
ALLOW_REGISTRATION=true
ALLOW_SOCIAL_LOGIN=false
ALLOW_SOCIAL_REGISTRATION=false
ALLOW_PASSWORD_RESET=false
ALLOW_UNVERIFIED_EMAIL_LOGIN=true
SESSION_EXPIRY=1000 * 60 * 15
REFRESH_TOKEN_EXPIRY=(1000 * 60 * 60 * 24) * 7

# Search (Meilisearch)
SEARCH=true
MEILI_NO_ANALYTICS=true
MEILI_MASTER_KEY=${meili_key}

# RAG API (pgvector)
RAG_PORT=8000
VECTOR_DB_TYPE=pgvector
DB_PORT=5432
POSTGRES_DB=librechat
POSTGRES_USER=librechat
POSTGRES_PASSWORD=${pg_pass}
RAG_UPLOAD_DIR=/app/uploads

# App
APP_TITLE=LibreChat
ENDPOINTS=openAI,agents,assistants,anthropic,google
OPENAI_API_KEY=user_provided
ANTHROPIC_API_KEY=user_provided
GOOGLE_KEY=user_provided

# Uncomment and set to enable file uploads / RAG embeddings via OpenAI:
# RAG_OPENAI_API_KEY=your-key-here
EOF
  chown "${PU}:${PU}" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  ok "Wrote $ENV_FILE"
}

prepare_dirs() {
  mkdir -p "$INSTALL_DIR"
  # Bind-mounted data directories, owned by the container user (UID/GID 1000).
  mkdir -p "$INSTALL_DIR"/{images,uploads,logs,skill,data-node,meili_data}
  chown -R "${PU}:${PU}" "$INSTALL_DIR"
}

start_stack() {
  cd "$INSTALL_DIR"
  info "Pulling images (this can take a few minutes)..."
  docker compose pull
  info "Starting LibreChat stack..."
  docker compose up -d --remove-orphans
}

# ---------------------------------------------------------------- actions

do_install() {
  local ip
  require_root
  info "Installing $APP (Docker Compose)..."
  install_docker
  prepare_dirs

  [ -f "$COMPOSE_FILE" ] || write_compose
  if [ -f "$ENV_FILE" ]; then
    warn "Existing .env found — keeping it (secrets preserved)."
  else
    ip=$(detect_ip)
    write_env "$ip"
  fi

  start_stack

  ip=$(detect_ip)
  ok "Completed successfully!"
  printf '\n'
  printf '  LibreChat:      http://%s:3080\n' "$ip"
  printf '  Admin panel:    http://%s:3000\n' "$ip"
  printf '\n'
  printf '  First registered user is automatically admin (single-tenant).\n'
  printf '  Register immediately, then set ALLOW_REGISTRATION=false in %s\n' "$ENV_FILE"
  printf '  and run: cd %s && docker compose up -d\n' "$INSTALL_DIR"
  printf '\n'
}

do_update() {
  require_root
  [ -d "$INSTALL_DIR" ] || die "No installation found at $INSTALL_DIR."
  cd "$INSTALL_DIR"
  info "Updating $APP images..."
  docker compose pull
  docker compose up -d --remove-orphans
  ok "Updated successfully!"
}

case "${1:-}" in
  update | --update | -u) do_update ;;
  *) do_install ;;
esac
