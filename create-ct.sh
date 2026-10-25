#!/usr/bin/env bash
# Create a Proxmox LXC for LibreChat and run the installer inside it.
# Run this ON THE PROXMOX HOST (as root).
#
# Docker inside an LXC requires the nesting + keyctl features, which this sets.
# Adjust the variables below to match your storage / bridge / template.

set -euo pipefail

# --- configuration (override via env) -------------------------------------
CTID="${CTID:-14247}"                              # container ID
HOSTNAME="${HOSTNAME:-librechat}"                  # CT hostname
STORAGE="${STORAGE:-local-lvm}"                    # rootfs storage
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"      # where CT templates live
BRIDGE="${BRIDGE:-vmbr0}"                          # network bridge
CORES="${CORES:-4}"
RAM="${RAM:-6144}"
SWAP="${SWAP:-1024}"
DISK="${DISK:-24}"                                 # GB
DEBIAN="${DEBIAN:-13}"                             # 12 or 13
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/Christopher2K/librechat-proxmox/main}"

info() { printf '\033[0;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m[ OK ]\033[0m %s\n' "$*"; }
die()  { printf '\033[0;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root on the Proxmox host."

# --- find or download the Debian template ---------------------------------
pveam update >/dev/null 2>&1 || true
TEMPLATE_FILE=""
while read -r name; do
  case "$name" in
    debian-${DEBIAN}-standard_*) TEMPLATE_FILE="$name"; break ;;
  esac
done < <(pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk '{print $1}')

if [ -z "$TEMPLATE_FILE" ]; then
  info "Downloading Debian ${DEBIAN} template..."
  pveam download "$TEMPLATE_STORAGE" "debian-${DEBIAN}-standard" || \
    die "Could not download template. Check 'pveam available' and your storage."
  TEMPLATE_FILE="$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk -v d="debian-${DEBIAN}-standard" '$0 ~ d {print $1; exit}')"
fi
[ -n "$TEMPLATE_FILE" ] || die "No Debian ${DEBIAN} template available in '$TEMPLATE_STORAGE'."

TEMPLATE_PATH="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_FILE}"
info "Using template: $TEMPLATE_PATH"

# --- create the container -------------------------------------------------
if pct status "$CTID" >/dev/null 2>&1; then
  warn "CT $CTID already exists — skipping creation."
else
  info "Creating LXC $CTID ($HOSTNAME)..."
  pct create "$CTID" "$TEMPLATE_PATH" \
    --hostname "$HOSTNAME" \
    --cores "$CORES" \
    --memory "$RAM" \
    --swap "$SWAP" \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp,firewall=1" \
    --features nesting=1,keyctl=1 \
    --unprivileged 1 \
    --onboot 1
  ok "Created LXC $CTID."
fi

info "Starting LXC $CTID..."
pct start "$CTID" || true

info "Waiting for boot..."
for _ in $(seq 1 30); do
  if pct exec "$CTID" -- bash -c 'command -v apt-get >/dev/null 2>&1' >/dev/null 2>&1; then
    break
  fi
  sleep 3
done

# --- run the installer inside the CT --------------------------------------
info "Running the LibreChat installer inside the CT (this downloads Docker + images)..."
pct exec "$CTID" -- bash -c "curl -fsSL '${REPO_RAW}/install.sh' | bash"

ok "Done. See the printed URLs for LibreChat (3080) and the Admin Panel (3000)."
