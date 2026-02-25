# dev-sandbox-vscode

Run VS Code with a Dev Container to **sandbox AI agent development** by restricting:

- **Filesystem access** to a single workspace folder
- **Network access** to deny local/LAN resources while allowing Internet and DNS

Designed to reduce the blast radius of AI coding agents (e.g. Claude Code, Codex) by ensuring they:

- can only see the files in the opened workspace
- cannot scan or interact with your local network
- still have outbound Internet access for APIs and package downloads

All enforcement happens on the **host**, not inside the container.

---

## Core idea (why this exists)

When running AI-assisted coding tools, especially autonomous agents, there are two major risks:

1. **Filesystem overreach**
   Agents may crawl outside the intended project directory if the editor exposes more of the host filesystem.

2. **Local network exposure**
   Agents may probe local services, metadata endpoints, or internal infrastructure reachable via LAN.

This project addresses both by combining:

- **VS Code Dev Containers** → filesystem scope limited to one workspace folder
- **`devcontainer-firewall`** → host-side iptables rules applied per container, managed by a systemd service

Result: AI agents operate inside a constrained workspace with no visibility into your local environment.

---

## File layout

```
start-sandbox.sh                         ← entry point: create config, open VS Code
init.sh                                  ← installs devcontainer CLI locally (optional)
devcontainer-firewall/                   ← host firewall service
    install.sh
    uninstall.sh
    usr/local/bin/devcontainer-monitor   ← systemd daemon
    etc/systemd/system/devcontainer-firewall.service
    etc/devcontainer-firewall/containers/
        default.conf                     ← fallback firewall rules
        myproject.conf                   ← example per-workspace rules
```

---

## Requirements

- Linux host
- Docker
- iptables (IPv4)
- VS Code (`code` CLI in PATH)
- VS Code extension: **Dev Containers** (Microsoft)
- `sudo` access (for firewall service install and per-workspace config creation)

---

## Setup

### 1. Install the firewall service

```bash
cd devcontainer-firewall
sudo ./install.sh
```

This installs `devcontainer-monitor` as a systemd service that watches Docker events and applies iptables rules in the `DOCKER-USER` chain automatically.

### 2. (Optional) Install devcontainer CLI locally

```bash
chmod +x init.sh
./init.sh
```

Installs the devcontainer CLI into `./node_modules/.bin/devcontainer`. When present,
`start-sandbox.sh` uses it to start the container automatically without requiring VS Code to be open first.

---

## Usage

```bash
chmod +x start-sandbox.sh
./start-sandbox.sh /path/to/workspace
```

What happens on each run:

1. **`devcontainer.json`** is written to `<workspace>/.devcontainer/` (skipped if already present).
2. **Firewall config** is written to `/etc/devcontainer-firewall/containers/<workspace-name>.conf` via `sudo` (skipped if already present).
3. **Dev container** is started via devcontainer CLI if available.
4. **VS Code** opens detached, attached to the running container.

---

## Configuration

All configurable values are at the **top of `start-sandbox.sh`**:

```bash
DNS_RESOLVER_IP="192.168.0.1"   # always whitelisted; used for --dns too
WHITELIST_EXTRA=""               # additional entries, comma-separated
                                 # supports port specs — see below
BLACKLIST_CIDRS="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,127.0.0.0/8,169.254.0.0/16"
FIREWALL_CONF_DIR="/etc/devcontainer-firewall/containers"
```

- `DNS_RESOLVER_IP` — used both as the Docker `--dns` flag and as the base `WHITELIST` entry in the generated config. Can be a LAN resolver or a public one (e.g. `1.1.1.1`).
- `WHITELIST_EXTRA` — additional CIDRs or port-restricted entries appended to the whitelist.
- `BLACKLIST_CIDRS` — ranges blocked at the kernel level.
- `FIREWALL_CONF_DIR` — where per-workspace `.conf` files are stored.

### Port-restricted entries

Both `WHITELIST_EXTRA` and `BLACKLIST_CIDRS` (and the `.conf` files directly) support an optional port specifier:

| Format | Matches |
|---|---|
| `1.1.1.1/32` | all protocols, all ports |
| `1.1.1.1/32@443` | TCP **and** UDP, port 443 |
| `1.1.1.1/32@tcp:443` | TCP only, port 443 |
| `1.1.1.1/32@udp:53` | UDP only, port 53 |

Example — allow a corporate proxy on TCP 443, block SSH into a subnet:

```bash
WHITELIST_EXTRA="10.10.0.5/32@tcp:443"
BLACKLIST_CIDRS="10.0.0.0/8@tcp:22,172.16.0.0/12,192.168.0.0/16,127.0.0.0/8,169.254.0.0/16"
```

To customise rules for a specific workspace, edit its generated `.conf` file directly. The script will not overwrite an existing file.

---

## How filesystem access is restricted

- The devcontainer mounts only the selected workspace directory.
- VS Code's remote server runs **inside the container**.
- Tools and AI agents can only read/write within:

  `/home/vscode/<workspace-name>`

- No access to other host directories unless explicitly mounted.

---

## How network access is restricted

### Blocked (by default)

| Range | Description |
|---|---|
| `10.0.0.0/8` | RFC1918 private |
| `172.16.0.0/12` | RFC1918 private |
| `192.168.0.0/16` | RFC1918 private |
| `127.0.0.0/8` | Loopback |
| `169.254.0.0/16` | Link-local / APIPA |

### Allowed

- DNS to the configured `DNS_RESOLVER_IP`
- All other public Internet traffic

All enforcement is via **host iptables rules** in the `DOCKER-USER` chain — containers cannot bypass it.

---

## How containers are identified

The generated `devcontainer.json` sets two Docker labels:

```jsonc
"--label=dev-sandbox=true",               // marks container for firewall monitoring
"--label=dev-sandbox-config=<workspace-name>"  // selects the matching .conf file
```

The firewall daemon only acts on containers with `dev-sandbox=true`, so unrelated Docker containers are never affected.

The config label maps to `/etc/devcontainer-firewall/containers/<workspace-name>.conf`.
See [`devcontainer-firewall/README.md`](devcontainer-firewall/README.md) for full config resolution details.

---

## AI tools installed in the container

The `postCreateCommand` installs both agents globally via npm:

- [`@anthropic-ai/claude-code`](https://www.npmjs.com/package/@anthropic-ai/claude-code)
- [`@openai/codex`](https://www.npmjs.com/package/@openai/codex)

Both are also installed as VS Code extensions via `customizations.vscode.extensions`.

---

## IPv4-only limitation

**IPv6 is not handled.** Firewall rules use iptables only.

IPv6 traffic may still bypass restrictions if enabled on the host.

Mitigations:
- Disable IPv6 in Docker daemon config, or
- Add equivalent ip6tables rules (out of scope for this repo)

---

## Why this is safer for AI agents

| Risk | Typical setup | This sandbox |
|---|---|---|
| Filesystem reach | Full user home | Workspace only |
| LAN access | Allowed | Denied |
| Host services | Reachable | Blocked |
| Per-project rules | None | Per-workspace `.conf` |
| Policy enforcement | Soft | Kernel-level |
| Cleanup | Manual | Automatic (systemd service) |

Suitable for:
- Experimenting with new AI coding agents
- Running autonomous refactoring tools
- Evaluating untrusted or evolving AI integrations

---

## Troubleshooting

### DNS does not work

Check rule ordering — ACCEPT rules must appear before REJECT:

```bash
sudo iptables -L DOCKER-USER -n --line-numbers | grep devcontainer
```

See also: [`devcontainer-firewall/README.md` → Rule tracking](devcontainer-firewall/README.md)

### Firewall rules are not applied

Verify the service is running:

```bash
systemctl status devcontainer-firewall
journalctl -fu devcontainer-firewall
```

### Script exits immediately

Run from an **interactive terminal**. Ctrl+D handling depends on `/dev/tty`.

---

## License

This project is under an [MIT license](LICENSE).
