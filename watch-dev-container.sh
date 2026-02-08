#!/usr/bin/env bash
set -euo pipefail

# ---- Configurable intervals/labels ----
CHECK_INTERVAL=5
IDLE_TIMEOUT=30
STARTUP_GRACE=60
LABEL_FILTER='label=ai-sandbox=true'
# ---
STATE_DIR="/run/ai-sandbox-vscode"
# ---------------------------------------

DNS_PORT="53"
NETS=()

# ---- ----

usage() {
  cat <<EOF
Usage: sudo $0 --stop-flag <path> --dns-ip <ip> [--dns-port <port>] --net <cidr> [--net <cidr> ...]
EOF
  exit 1
}


while [[ $# -gt 0 ]]; do
  case "$1" in
    --stop-flag) STOP_FLAG="$2"; shift 2 ;;
    --dns-ip) DNS_RESOLVER_IP="$2"; shift 2 ;;
    --dns-port) DNS_PORT="$2"; shift 2 ;;
    --net) NETS+=("$2"); shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown arg: $1"; usage ;;
  esac
done

[[ -n "${STOP_FLAG:-}" && -n "${DNS_RESOLVER_IP:-}" && ${#NETS[@]} -gt 0 ]] || usage

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root."
  exit 1
fi
# ---- ----

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

state_path() { echo "$STATE_DIR/$1.ip"; }

ip_of() {
  local cid="$1"
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$cid" 2>/dev/null || true
}

apply_rules() {
  local cid="$1"
  local cip
  cip="$(ip_of "$cid")"
  [[ -n "${cip:-}" ]] || return 0

  echo "$cip" > "$(state_path "$cid")"

  allow_dns "$cip"

  for net in "${NETS[@]}"; do
    iptables -C DOCKER-USER -s "$cip" -d "$net" -j REJECT 2>/dev/null || \
      iptables -A DOCKER-USER -s "$cip" -d "$net" -j REJECT
  done

  echo "[ai-sandbox] Applied rules for $cid ($cip)"
}

allow_dns() {
  local cip="$1"
  for proto in udp tcp; do
    iptables -C DOCKER-USER -s "$cip" -d "$DNS_RESOLVER_IP" -p "$proto" --dport "$DNS_PORT" -j ACCEPT 2>/dev/null || \
      iptables -I DOCKER-USER 1 -s "$cip" -d "$DNS_RESOLVER_IP" -p "$proto" --dport "$DNS_PORT" -j ACCEPT
  done
}

remove_rules() {
  local cid="$1"
  local cip=""

  if [[ -f "$(state_path "$cid")" ]]; then
    cip="$(cat "$(state_path "$cid")" 2>/dev/null || true)"
    rm -f "$(state_path "$cid")" 2>/dev/null || true
  fi

  [[ -n "${cip:-}" ]] || cip="$(ip_of "$cid")"
  [[ -n "${cip:-}" ]] || return 0

  remove_rules_by_ip "$cip"
  echo "[ai-sandbox] Removed rules for $cid ($cip)"
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
    iptables -D DOCKER-USER -s "$cip" -d "$DNS_RESOLVER_IP" -p "$proto" --dport "$DNS_PORT" -j ACCEPT 2>/dev/null || true
  done
}

cleanup_all_rules() {
  echo "[ai-sandbox] Cleaning up rules..."
  shopt -s nullglob
  for f in "$STATE_DIR"/*.ip; do
    local cip
    cip="$(cat "$f" 2>/dev/null || true)"
    remove_rules_by_ip "$cip"
    rm -f "$f" 2>/dev/null || true
  done
  shopt -u nullglob
}

container_running() {
  docker ps --filter "$LABEL_FILTER" -q | grep -q .
}

# ---- ----
echo "[ai-sandbox] Applying rules for existing (label ai-sandbox=true)."
for cid in $(docker ps --filter "$LABEL_FILTER" -q); do
  apply_rules "$cid"
done

echo "[ai-sandbox] Watching Docker events (label ai-sandbox=true). Ctrl+D to stop watch or wait for exit."
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

# ---- ----

# wating for container or stop of no container present anymore
START_TS="$(date +%s)"
SEEN_ONCE=0
NONE_SINCE=0

LAST_LOG=0
while true; do
  if [[ -f "$STOP_FLAG" ]]; then
    echo "[ai-sandbox] Stop flag received: $STOP_FLAG"
    break
  fi

  now="$(date +%s)"
  since_start=$(( now - START_TS ))

  if container_running; then
    SEEN_ONCE=1
    NONE_SINCE=0
    LAST_LOG=0
  else
    if (( SEEN_ONCE == 0 )); then
      # No container has EVER been seen
      if (( since_start < STARTUP_GRACE )); then
        if (( now != LAST_LOG )); then
          echo "[ai-sandbox] No container yet (${since_start}s / ${STARTUP_GRACE}s grace)"
          LAST_LOG="$now"
        fi
      else
        echo "[ai-sandbox] No container started within ${STARTUP_GRACE}s grace -> stopping."
        break
      fi
    else
      # At least one container WAS seen → grace is irrelevant forever
      if (( NONE_SINCE == 0 )); then
        NONE_SINCE="$now"
      fi

      no_container_for=$(( now - NONE_SINCE ))
      remaining=$(( IDLE_TIMEOUT - no_container_for ))
      (( remaining < 0 )) && remaining=0

      if (( now != LAST_LOG )); then
        echo "[ai-sandbox] No container for ${no_container_for}s (idle-stop in ${remaining}s)"
        LAST_LOG="$now"
      fi

      if (( no_container_for >= IDLE_TIMEOUT )); then
        echo "[ai-sandbox] No sandbox container for ${IDLE_TIMEOUT}s -> stopping."
        break
      fi
    fi
  fi

  sleep "$CHECK_INTERVAL"
done
# ---- ----

# step - clean up
cleanup_all_rules
kill "$EVENTS_PID" 2>/dev/null || true
rm -f "$STOP_FLAG" 2>/dev/null || true
echo "[ai-sandbox] Watcher done."
