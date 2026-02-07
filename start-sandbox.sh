#!/usr/bin/env bash
set -euo pipefail

LABEL_FILTER='label=ai-sandbox=true'
NETS=( "192.168.0.0/16" "127.0.0.0/8" )
DNS_RESOLVER_IP="192.168.0.1" # can be LAN or public (e.g. 1.1.1.1)
DNS_PORTS=(53)

STATE_DIR="/run/sandbox-net-watch"
STOP_FLAG="/run/sandbox-stop.flag"
CHECK_INTERVAL=5
IDLE_TIMEOUT=30
STARTUP_GRACE=60 # seconds to wait before idle logic can stop us

usage() { echo "Usage: sudo $0 <workspace-folder>"; exit 1; }
[[ $# -eq 1 ]] || usage

WORKSPACE="$(realpath "$1")"
[[ -d "$WORKSPACE" ]] || { echo "Error: workspace folder does not exist: $WORKSPACE"; exit 1; }

# 1) ensure root rights
if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo $0 \"$WORKSPACE\""
  exit 1
fi

REAL_USER="${SUDO_USER:-}"
[[ -n "$REAL_USER" ]] || { echo "Error: SUDO_USER empty (run via sudo from a normal user)."; exit 1; }

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
rm -f "$STOP_FLAG" 2>/dev/null || true

# Write devcontainer.json into workspace (VS Code stops container on close)
DEVCONTAINER_DIR="$WORKSPACE/.devcontainer"
DEVCONTAINER_JSON="$DEVCONTAINER_DIR/devcontainer.json"
mkdir -p "$DEVCONTAINER_DIR"

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
        "password-store": "basic",
        "remote.extensionKind": {
          "anthropic.claude-code": [ "workspace" ],
          "openai.chatgpt": [ "workspace" ]
        }
      }
    }
  }
}
EOF

ip_of() {
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1" 2>/dev/null || true
}
state_path() { echo "$STATE_DIR/$1.ip"; }

apply_rules() {
  local cid="$1" cip
  cip="$(ip_of "$cid")"
  [[ -n "${cip:-}" ]] || return 0

  echo "$cip" > "$(state_path "$cid")"

  # 1) allow DNS explicitly
  allow_dns "$cip"

  # 2) block LAN + localhost
  for net in "${NETS[@]}"; do
    iptables -C DOCKER-USER -s "$cip" -d "$net" -j REJECT 2>/dev/null || \
      iptables -I DOCKER-USER -s "$cip" -d "$net" -j REJECT
  done

  echo "[sandbox] Applied rules for $cid ($cip)"
}

allow_dns() {
  local cip="$1"

  for proto in udp tcp; do
    iptables -C DOCKER-USER -s "$cip" -d "$DNS_RESOLVER_IP" -p "$proto" --dport 53 -j ACCEPT 2>/dev/null || \
      iptables -I DOCKER-USER 1 -s "$cip" -d "$DNS_RESOLVER_IP" -p "$proto" --dport 53 -j ACCEPT
  done
}

remove_rules_by_ip() {
  local cip="$1"
  [[ -n "${cip:-}" ]] || return 0

  remove_dns "$cip"

  for net in "${NETS[@]}"; do
    iptables -D DOCKER-USER -s "$cip" -d "$net" -j REJECT 2>/dev/null || true
  done
}

remove_dns() {
  local cip="$1"

  for proto in udp tcp; do
    iptables -D DOCKER-USER -s "$cip" -d "$DNS_RESOLVER_IP" -p "$proto" --dport 53 -j ACCEPT 2>/dev/null || true
  done
}

remove_rules() {
  local cid="$1" cip=""
  if [[ -f "$(state_path "$cid")" ]]; then
    cip="$(cat "$(state_path "$cid")" 2>/dev/null || true)"
    rm -f "$(state_path "$cid")" 2>/dev/null || true
  fi
  [[ -n "${cip:-}" ]] || cip="$(ip_of "$cid")"
  [[ -n "${cip:-}" ]] || return 0
  remove_rules_by_ip "$cip"
  echo "[sandbox] Removed rules for $cid ($cip)"
}

cleanup_all_rules() {
  echo "[sandbox] Cleaning up rules..."
  shopt -s nullglob
  for f in "$STATE_DIR"/*.ip; do
    cip="$(cat "$f" 2>/dev/null || true)"
    remove_rules_by_ip "$cip"
    rm -f "$f" 2>/dev/null || true
  done
  shopt -u nullglob
}

sandbox_running() {
  docker ps --filter "$LABEL_FILTER" -q | grep -q .
}

# 2) run vscode detached as user (avoid keyring prompt)
echo "[sandbox] Opening VS Code (detached): $WORKSPACE"
sudo -u "$REAL_USER" setsid -f code --password-store=basic --new-window "$WORKSPACE" >/dev/null 2>&1 || true

# Ctrl+D watcher from the real terminal (prevents immediate EOF under sudo)
if [[ -t 0 ]] && [[ -e /dev/tty ]]; then
  ( cat </dev/tty >/dev/null; touch "$STOP_FLAG" ) &
else
  echo "[sandbox] Warning: no TTY; Ctrl+D stop disabled."
fi

# 3) docker events watcher
echo "[sandbox] Watching Docker events (label ai-sandbox=true). Ctrl+D or ${IDLE_TIMEOUT} no container to stop."
docker events \
  --filter "$LABEL_FILTER" \
  --filter event=start \
  --filter event=stop \
  --filter event=die \
  --filter event=destroy \
  --format '{{.Status}} {{.ID}}' | while read -r status cid; do
    case "$status" in
      start) apply_rules "$cid" ;;
      stop|die|destroy) remove_rules "$cid" ;;
    esac
  done &
EVENTS_PID=$!

# Apply rules for already-running sandbox containers (if any)
for cid in $(docker ps --filter "$LABEL_FILTER" -q); do
  apply_rules "$cid"
done

START_TS="$(date +%s)"
SEEN_ONCE=0
NONE_SINCE=0

# 4) stop on Ctrl+D OR if no sandbox container exists for >60s (after we’ve seen one, and after grace)
while true; do
  [[ -f "$STOP_FLAG" ]] && echo "[sandbox] Ctrl+D received." && break

  now="$(date +%s)"
  if sandbox_running; then
    SEEN_ONCE=1
    NONE_SINCE=0
  else
    # don’t auto-exit too early while the container is still being built/started
    if (( now - START_TS < STARTUP_GRACE )); then
      :
    elif (( SEEN_ONCE == 1 )); then
      if [[ "$NONE_SINCE" -eq 0 ]]; then
        NONE_SINCE="$now"
      elif (( now - NONE_SINCE >= IDLE_TIMEOUT )); then
        echo "[sandbox] No sandbox container for ${IDLE_TIMEOUT}s -> stopping."
        break
      fi
    fi
  fi

  sleep "$CHECK_INTERVAL"
done

cleanup_all_rules
kill "$EVENTS_PID" 2>/dev/null || true
rm -f "$STOP_FLAG" 2>/dev/null || true
echo "[sandbox] Done."

