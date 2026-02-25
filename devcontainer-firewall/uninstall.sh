#!/usr/bin/env bash
# uninstall.sh — removes devcontainer-firewall from the host
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "Run as root: sudo $0"
    exit 1
fi

echo "==> Stopping and disabling service..."
if systemctl is-active --quiet devcontainer-firewall.service; then
    systemctl stop devcontainer-firewall.service
fi
if systemctl is-enabled --quiet devcontainer-firewall.service 2>/dev/null; then
    systemctl disable devcontainer-firewall.service
fi

echo "==> Removing systemd unit..."
rm -f /etc/systemd/system/devcontainer-firewall.service
systemctl daemon-reload

echo "==> Removing monitor script..."
rm -f /usr/local/bin/devcontainer-monitor

echo "==> Flushing any remaining devcontainer iptables rules..."
line_numbers=$(iptables -L DOCKER-USER --line-numbers -n 2>/dev/null \
    | awk '/devcontainer:/ {print $1}' \
    | sort -rn)
if [[ -n "$line_numbers" ]]; then
    for line in $line_numbers; do
        iptables -D DOCKER-USER "$line"
        echo "    Deleted DOCKER-USER line $line"
    done
else
    echo "    No rules found."
fi

echo ""
read -rp "Remove config directory /etc/devcontainer-firewall? [y/N] " confirm
if [[ "${confirm,,}" == "y" ]]; then
    rm -rf /etc/devcontainer-firewall
    echo "    Removed /etc/devcontainer-firewall"
else
    echo "    Skipped. Config preserved at /etc/devcontainer-firewall"
fi

echo ""
echo "Uninstall complete."
