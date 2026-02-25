#!/usr/bin/env bash
# install.sh — installs devcontainer-firewall onto the host
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$EUID" -ne 0 ]]; then
    echo "[dev-sandbox] Run as root: sudo $0"
    exit 1
fi

echo "[dev-sandbox] Installing devcontainer-monitor..."
install -Dm 755 "$REPO_ROOT/usr/local/bin/devcontainer-monitor" \
               /usr/local/bin/devcontainer-monitor

echo "[dev-sandbox] Installing systemd service..."
install -Dm 644 "$REPO_ROOT/etc/systemd/system/devcontainer-firewall.service" \
               /etc/systemd/system/devcontainer-firewall.service

echo "[dev-sandbox] Creating config directory..."
mkdir -p /etc/devcontainer-firewall/containers

echo "[dev-sandbox] Installing default config (never overwritten if already present)..."
if [[ ! -f /etc/devcontainer-firewall/containers/default.conf ]]; then
    install -Dm 644 \
        "$REPO_ROOT/etc/devcontainer-firewall/containers/default.conf" \
        /etc/devcontainer-firewall/containers/default.conf
    echo "[dev-sandbox] Installed /etc/devcontainer-firewall/containers/default.conf"
else
    echo "[dev-sandbox] Skipped default.conf (already exists)"
fi

if [[ ! -f /etc/devcontainer-firewall/containers/myproject.conf ]]; then
    install -Dm 644 \
        "$REPO_ROOT/etc/devcontainer-firewall/containers/myproject.conf" \
        /etc/devcontainer-firewall/containers/myproject.conf
    echo "[dev-sandbox] Example config installed at /etc/devcontainer-firewall/containers/myproject.conf"
fi

echo "[dev-sandbox] Reloading systemd and enabling service..."
systemctl daemon-reload
systemctl enable --now devcontainer-firewall.service

echo ""
echo "[dev-sandbox] Done. Service status:"
systemctl status devcontainer-firewall.service --no-pager || true

echo ""
echo "[dev-sandbox] Next steps:"
echo "[dev-sandbox]   1. Create a config per container in /etc/devcontainer-firewall/containers/<name>.conf"
echo "[dev-sandbox]   2. Label your devcontainer with:"
echo '[dev-sandbox]        "dev-sandbox": "true"'
echo '[dev-sandbox]        "dev-sandbox-config": "<name>"   # optional, falls back to container name'
echo "[dev-sandbox]   3. Check logs: journalctl -fu devcontainer-firewall"
