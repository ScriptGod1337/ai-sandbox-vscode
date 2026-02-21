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

# ---- 1) Create dev container settings ----
echo "[ai-sandbox] Creating devcontainer.json..."

# devcontainer settings must be created/owned by the current user
DEVCONTAINER_DIR="$WORKSPACE/.devcontainer"
DEVCONTAINER_JSON="$DEVCONTAINER_DIR/devcontainer.json"
mkdir -p "$DEVCONTAINER_DIR"

# If you want literally identical content, paste your existing devcontainer.json heredoc here.
if [[ ! -f "$DEVCONTAINER_JSON" ]]; then
  cat > "$DEVCONTAINER_JSON" <<EOF
{
  "name": "dev-sandbox",
  "image": "mcr.microsoft.com/devcontainers/base:ubuntu",
  "workspaceMount": "source=\${localWorkspaceFolder},target=/home/vscode/\${localWorkspaceFolderBasename},type=bind,consistency=cached",
  "workspaceFolder": "/home/vscode/\${localWorkspaceFolderBasename}",
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
    "ghcr.io/devcontainers/features/python:1": {},
    "ghcr.io/devcontainers/features/aws-cli:1": {}
    "ghcr.io/devcontainers/features/docker-in-docker:2": {}
    "ghcr.io/devcontainers/features/node:1": {}
  },
  "postCreateCommand": "npm install -g @anthropic-ai/claude-code",
  "customizations": {
    "vscode": {
      "extensions": [
        "anthropic.claude-code",
        "openai.chatgpt",
        "streetsidesoftware.code-spell-checker"
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
else
  echo "[ai-sandbox] Using existing .devcontainer/devcontainer.json"
fi

# ---- 2) Start watching dev container ----
# Stop-flag in workspace so the non-root user can signal stop without needing sudo
STOP_FLAG="/tmp/ai-sandbox-stop.$$.$RANDOM"
rm -f "$STOP_FLAG" 2>/dev/null || true

#  Start the root watcher (iptables + docker wait logic)
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
# ----  ----

# ---- 2) Create dev container (optional) ----
DEVCONTAINER_CLI=""
CID=""

if [ -x "./node_modules/.bin/devcontainer" ]; then
  DEVCONTAINER_CLI="./node_modules/.bin/devcontainer"
elif command -v devcontainer >/dev/null 2>&1; then
  DEVCONTAINER_CLI="devcontainer"
fi

if [ -n "$DEVCONTAINER_CLI" ]; then
  echo "[ai-sandbox] Using devcontainer CLI: $DEVCONTAINER_CLI"
  "$DEVCONTAINER_CLI" up --workspace-folder $WORKSPACE || echo "[ai-sandbox] devcontainer up failed; continuing"

  CID=$(docker ps \
  --filter "label=devcontainer.local_folder=$WORKSPACE" \
  --format "{{.ID}}" | head -n1)
  echo "[ai-sandbox] Found devcontainer $CID"
else
  echo "[ai-sandbox] devcontainer CLI not found; continuing"
fi
# --- ----

# ---- 3) Open VS Code detached as the current user ----
if [ -n "$CID" ]; then
  echo "[ai-sandbox] Opening VS Code: attaching to dev container $CID"
  code --new-window  --folder-uri "vscode-remote://attached-container+$(printf "$CID" | xxd -p)/home/vscode//$(basename "$WORKSPACE")" >/dev/null 2>&1 || true
else
  echo "[ai-sandbox] Opening VS Code: $WORKSPACE"
  code --new-window "$WORKSPACE" >/dev/null 2>&1 || true
fi
# ----  ----

# --- 4) wait for VSCode close ---
echo "[ai-sandbox] Ctrl+D to stop watch or wait for exit."

# Ctrl+D handler: set flag + wait for watcher exit
# Start TTY EOF watcher (Ctrl+D) reading from the real terminal, not stdin
cat </dev/tty >/dev/null &
TTY_PID=$!

cleanup() {
  kill "$TTY_PID" 2>/dev/null || true
}
trap cleanup EXIT

# Wait until either the watcher ends (timeout/idle) OR Ctrl+D happens
wait -n "$WATCHER_PID" "$TTY_PID"
# ----  ----

# --- 5) clean up ---
if ! kill -0 "$TTY_PID" 2>/dev/null; then
  # Ctrl+D happened first
  echo "[ai-sandbox] Ctrl+D received -> stopping watcher..."
  : > "$STOP_FLAG"
  wait "$WATCHER_PID" 2>/dev/null || true
  echo "[ai-sandbox] Watcher exited."
else
  # Watcher ended first (timeout/idle)
  echo "[ai-sandbox] Watcher finished."
  kill "$TTY_PID" 2>/dev/null || true
fi

# close dev container (if stil running)
if [ -n "$CID" ]; then
  echo "[ai-sandbox] Stopping dev container $CID."
  docker stop "$CID" >/dev/null 2>&1 || echo "[ai-sandbox] dev container up failed; continuing"
fi

echo "[ai-sandbox] Done."

