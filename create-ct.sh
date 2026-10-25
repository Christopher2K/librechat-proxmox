#!/usr/bin/env bash
# Create a Proxmox LXC for LibreChat and run the installer inside it.
# Run this ON THE PROXMOX HOST (as root).
#
# Docker inside an LXC requires the nesting + keyctl features, which this sets.
# Adjust the variables below to match your storage / bridge / template.

set -euo pipefail

# --- configuration (override via env) -------------------------------------
CTID="${CTID:-14247}"                              # container ID
CT_HOSTNAME="${CT_HOSTNAME:-librechat}"            # CT hostname (not HOSTNAME: bash presets that)
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

# pveam download needs the EXACT filename (e.g. debian-13-standard_13.1-2_amd64.tar.zst),
# so resolve it from the appliance index rather than guessing a family name.
extract_template() {
  # $1 = Debian major version (13, 12, 11)
  # Prefer amd64 (standard Proxmox x86_64); fall back to any architecture.
  pveam available 2>/dev/null \
    | grep -om1 -E "debian-${1}-standard[^[:space:]]*amd64\.tar\.(gz|xz|zst)" \
    || pveam available 2>/dev/null \
      | grep -om1 -E "debian-${1}-standard[^[:space:]]*\.tar\.(gz|xz|zst)"
}

TEMPLATE_FILE=""
for ver in "$DEBIAN" 12 11; do
  TEMPLATE_FILE="$(extract_template "$ver")"
  if [ -n "$TEMPLATE_FILE" ]; then
    DEBIAN="$ver"
    break
  fi
done

# Fall back to a template already present on the target storage.
if [ -z "$TEMPLATE_FILE" ]; then
  TEMPLATE_FILE="$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -om1 -E "debian-[0-9]+-standard[^[:space:]]*\.tar\.(gz|xz|zst)")"
fi

[ -n "$TEMPLATE_FILE" ] || die "No Debian 'standard' template found. Run 'pveam available' to see what is available."

if pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -qF "$TEMPLATE_FILE"; then
  info "Template already present: $TEMPLATE_FILE"
else
  info "Downloading template: $TEMPLATE_FILE"
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_FILE" || \
    die "Download failed. Check storage '$TEMPLATE_STORAGE' and 'pveam available'."
fi

TEMPLATE_PATH="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_FILE}"
info "Using template: $TEMPLATE_PATH"

# --- create the container -------------------------------------------------
if pct status "$CTID" >/dev/null 2>&1; then
  warn "CT $CTID already exists — skipping creation."
else
  info "Creating LXC $CTID ($CT_HOSTNAME)..."
  pct create "$CTID" "$TEMPLATE_PATH" \
    --hostname "$CT_HOSTNAME" \
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
# A fresh Debian template has no curl, so fetch install.sh on the host (which
# has curl) and push it into the CT rather than curling from inside it.
info "Fetching installer..."
TMP_INSTALL="$(mktemp)"
curl -fsSL "${REPO_RAW}/install.sh" -o "$TMP_INSTALL"
pct push "$CTID" "$TMP_INSTALL" /tmp/librechat-install.sh
rm -f "$TMP_INSTALL"

info "Running the LibreChat installer inside the CT (this downloads Docker + images)..."
pct exec "$CTID" -- bash /tmp/librechat-install.sh

ok "Done. See the printed URLs for LibreChat (3080) and the Admin Panel (3000)."
