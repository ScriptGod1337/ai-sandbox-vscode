#!/usr/bin/env bash
set -euo pipefail

# ---- Configurable network policy (passed to sudo watcher) ----
NETS=( "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" )

# NOTE: If you want to allow LAN DNS, set this to your router IP.
# If you want to avoid LAN entirely, set to public DNS like 1.1.1.1 or 9.9.9.9.
DNS_RESOLVER_IP="192.168.0.1"
DNS_PORT=53
# -------------------------------------------------------------

usage() {
  echo "Usage: $0 <workspace-folder>"
  exit 1
}

[[ $# -eq 1 ]] || usage
WORKSPACE="$(realpath "$1")"
[[ -d "$WORKSPACE" ]] || { echo "Error: workspace folder does not exist: $WORKSPACE"; exit 1; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Devcontainer settings must be created/owned by the current user
DEVCONTAINER_DIR="$WORKSPACE/.devcontainer"
DEVCONTAINER_JSON="$DEVCONTAINER_DIR/devcontainer.json"
mkdir -p "$DEVCONTAINER_DIR"

# If you want literally identical content, paste your existing devcontainer.json heredoc here.
cat > "$DEVCONTAINER_JSON" <<EOF
{
  "name": "dev-sandbox",
  "image": "mcr.microsoft.com/devcontainers/base:ubuntu",
  "workspaceFolder": "/workspaces/\${localWorkspaceFolderBasename}",
  "remoteUser": "vscode",
  "shutdownAction": "stopContainer",
  "runArgs": [
    "--network=bridge",
    "--cap-drop=ALL",
    "--security-opt=no-new-privileges:true",
    "--dns=${DNS_RESOLVER_IP}",
    "--label=ai-sandbox=true"
  ],
  "features": {
    "ghcr.io/devcontainers/features/common-utils:2": {},
    "ghcr.io/devcontainers/features/git:1": {},
    "ghcr.io/devcontainers/features/java:1": {},
    "ghcr.io/devcontainers/features/python:1": {},
    "ghcr.io/devcontainers/features/kubectl-helm-minikube:1": { "minikube": "none" },
    "ghcr.io/devcontainers/features/terraform:1": {},
    "ghcr.io/devcontainers/features/aws-cli:1": {}
  },
  "customizations": {
    "vscode": {
      "extensions": [
        "anthropic.claude-code",
        "openai.chatgpt"
      ],
      "settings": {
        "remote.extensionKind": {
          "anthropic.claude-code": [ "workspace" ],
          "openai.chatgpt": [ "workspace" ]
        }
      }
    }
  }
}
EOF
# Stop-flag in workspace so the non-root user can signal stop without needing sudo
STOP_FLAG="/tmp/ai-sandbox-stop.$$.$RANDOM"
rm -f "$STOP_FLAG" 2>/dev/null || true

# 1) Start the root watcher (iptables + docker wait logic)
WATCH_ARGS=(
  --stop-flag "$STOP_FLAG"
  --dns-ip "$DNS_RESOLVER_IP"
  --dns-port "$DNS_PORT"
)
for net in "${NETS[@]}"; do
  WATCH_ARGS+=( --net "$net" )
done

echo "[ai-sandbox] Starting dev container watch detached..."
sudo -v
sudo "$SCRIPT_DIR/watch-dev-container.sh" "${WATCH_ARGS[@]}" &
WATCHER_PID=$!

# 2) Open VS Code detached as the current user
echo "[ai-sandbox] Opening VS Code: $WORKSPACE"
code --new-window "$WORKSPACE" >/dev/null 2>&1 || true

# 3) Ctrl+D watcher from the real terminal (touch stop flag)
# Ctrl+D -> touch stop flag (read from the controlling TTY, not stdin)
if [[ -r /dev/tty ]]; then
  (
    cat </dev/tty >/dev/null
    : > "$STOP_FLAG"
    echo "[ai-sandbox] Ctrl+D received"
  ) &
else
  echo "[ai-sandbox] No /dev/tty available; Ctrl+D stop disabled."
fi


# 4) Wait for the root watcher to exit
wait "$WATCHER_PID" || true
echo "[ai-sandbox] Done."

