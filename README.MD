# ai-sandbox-vscode

Run VS Code with a Dev Container to **sandbox AI agent development** by restricting:

- **Filesystem access** to a single workspace folder
- **Network access** to deny local/LAN resources while allowing Internet and DNS

This setup is designed to reduce the blast radius of AI coding agents (e.g. Claude / Codex) by ensuring they:

- can only see the files you intentionally open
- cannot scan or interact with your local network
- still have outbound Internet access for APIs and package downloads

All enforcement happens on the **host**, not inside the container.

---

## Core idea (why this exists)

When developing or running AI-assisted coding tools, especially autonomous agents, there are two major risks:

1. **Filesystem overreach**  
   Agents may crawl outside the intended project directory if the editor or tooling exposes more of the host filesystem.

2. **Local network exposure**  
   Agents may probe local services, metadata endpoints, or internal infrastructure reachable via LAN.

This project addresses both by combining:

- **VS Code Dev Containers** → filesystem scope limited to the workspace folder
- **Host-side firewall rules** → local network access denied at the kernel level

Result:  
AI agents operate inside a constrained workspace with no visibility into your local environment.

---

## What this project does

- Generates `.devcontainer/devcontainer.json` automatically
- Opens VS Code detached for a given workspace
- Labels the devcontainer with `ai-sandbox=true`
- Watches Docker container lifecycle events
- Applies/removes iptables rules in the host’s `DOCKER-USER` chain
- Blocks RFC1918 networks while explicitly allowing DNS to a single resolver
- Cleans up rules when the container stops or the script exits

---

## Requirements

- Linux host
- Docker
- iptables (IPv4)
- VS Code (`code` CLI in PATH)
- VS Code extension: **Dev Containers** (Microsoft)
- Ability to run the script with `sudo`

---

## Usage

```
chmod +x start-sandbox.sh
chmod +x watch-dev-container.sh
./start-sandbox.sh /path/to/workspace
```

What happens:

1. `.devcontainer/devcontainer.json` is created or updated in the workspace.
2. VS Code opens **detached** as your normal user.
3. Docker events are monitored and firewall rules are applied automatically.

### Optional
Use [devcontainer CLI](https://code.visualstudio.com/docs/devcontainers/devcontainer-cli)

```
chmod +x init.sh
sudo ./init.sh
```
Installs *local* devcontainer-cli.
This allows to create dev container automatically - whithout VS Code

---

## How filesystem access is restricted

- The devcontainer mounts only the selected workspace directory.
- VS Code’s remote server runs **inside the container**.
- Tools and AI agents executed in the container can only read/write within:

  `/workspaces/<workspace-name>`

- No access to other host directories unless you explicitly mount them.

This provides a **hard boundary** for AI tooling, not just an editor-level convention.

---

## How network access is restricted

### Blocked

- Localhost: `127.0.0.0/8`
- Local network (RFC1918), default:
  - `10.0.0.0/8`
  - `172.16.0.0/12`
  - `192.168.0.0/16`

### Allowed

- DNS (UDP + TCP) to **one explicitly configured resolver**
- Public Internet access

All enforcement is done via **host iptables rules**, so containers cannot bypass it.

---

## Configuration

All configuration lives at the **top of `start-sandbox.sh`**.

### Networks to block

```
NETS=( "192.168.0.0/16" "127.0.0.0/8" )
```

---

### DNS configuration

```
DNS_RESOLVER_IP="192.168.0.1"
DNS_PORT=53
```

- Only this IP is allowed for DNS
- Can be a LAN resolver or a public resolver (e.g. `1.1.1.1`)
- Prevents DNS failure while still denying all other LAN access

---

### Lifecycle control

```
STARTUP_GRACE=120
IDLE_TIMEOUT=60
CHECK_INTERVAL=5
```

- `STARTUP_GRACE` prevents premature exit during container build/start
- `IDLE_TIMEOUT` stops the watcher after the sandbox container has been gone for this long
- `CHECK_INTERVAL` controls polling frequency

---

## How the sandbox container is identified

The script relies on a **Docker label**, not naming conventions:

```
LABEL_FILTER='label=ai-sandbox=true'
```

The generated `devcontainer.json` includes:

```
"--label=ai-sandbox=true"
```

Only containers with this label:

- receive firewall rules
- are cleaned up on stop
- are considered part of the sandbox

This avoids accidentally affecting unrelated Docker containers.

---

## IPv4-only limitation

⚠️ **IPv6 is not handled.**

- Firewall rules use iptables
- IPv6 traffic may still bypass restrictions if enabled

### Mitigations

- Disable IPv6 in Docker, or
- Add equivalent ip6tables rules (out of scope for this repo)

---

## Why this is safer for AI agents

Compared to running AI tools directly on the host:

| Risk | Typical setup | This sandbox |
|----|----|----|
| Filesystem reach | Full user home | Workspace only |
| LAN access | Allowed | Denied |
| Host services | Reachable | Blocked |
| Cleanup | Manual | Automatic |
| Policy enforcement | Soft | Kernel-level |

This makes it suitable for:

- experimenting with new AI coding agents
- running autonomous refactoring tools
- evaluating untrusted or evolving AI integrations

---

## Troubleshooting

### DNS does not work

Check rule ordering:

```
sudo iptables -L DOCKER-USER -n --line-numbers
```

DNS ACCEPT rules must appear **before** REJECT rules.

---

### Script exits immediately

Run from an **interactive terminal**. Ctrl+D handling depends on `/dev/tty`.

---

## License

This project is under an [MIT license](LICENSE.txt).