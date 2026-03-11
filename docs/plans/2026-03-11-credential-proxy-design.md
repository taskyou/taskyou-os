# Credential Proxy Design: nono-Powered Credential Isolation for TaskYou-OS

**Date:** 2026-03-11
**Status:** Approved

## Problem

TaskYou-OS deploys AI agents on remote servers with `--dangerously-skip-permissions`. These agents currently have full access to all credentials stored as plain-text `.env` files on the server. An agent can read any credential at any time — whether through intentional access, accidental exposure, prompt injection, or environment compromise.

Users want to give agents broad latitude to work autonomously, but need a secure way to expose credentials without letting agents see or exfiltrate the raw keys.

## Inspiration

This design is inspired by a community pattern where an OpenClaw agent runs in a Docker container without credentials. A separate proxy container holds the real keys and injects them via `docker exec` as a different Linux user. The agent can use the credentials but never sees them.

TaskYou-OS doesn't use Docker — it provisions bare servers and runs agents in tmux sessions. We need the same isolation pattern adapted to this architecture.

## Solution: nono Integration

[nono](https://github.com/always-further/nono) is an open-source, kernel-enforced sandbox for AI agents built by Luke Hinds (founder of Sigstore). It provides:

- **Kernel-level sandboxing** via Landlock (Linux) and Seatbelt (macOS) — irreversible once applied
- **Phantom Token credential injection** — agents never see real API keys; a localhost proxy injects them into upstream requests
- **Agent-agnostic** — works with Claude Code, Codex, Gemini, OpenClaw, or any CLI process
- **Built-in Claude Code profile** — first-class support via `nono run --profile claude-code`
- **Audit trail** — cryptographic attestation via Sigstore transparency logs

nono is Apache 2.0 licensed, written in Rust, and actively maintained.

## Architecture

### Current Flow

```
ty daemon --dangerous
  -> spawns tmux session
    -> claude --dangerously-skip-permissions
       (has full access to .env files, filesystem, network)
```

### New Flow

```
ty daemon --dangerous
  -> spawns tmux session
    -> ~/bin/claude (PATH wrapper)
      -> nono run --profile taskyou-agent --allow-cwd -- /usr/local/bin/claude --dangerously-skip-permissions
         (sandboxed: credentials injected via localhost proxy, never in agent memory)
```

### How the Phantom Token Proxy Works

1. Before applying the sandbox, nono starts a localhost HTTP proxy on a dynamic port
2. Real credentials are loaded from the Linux Secret Service keystore (never touch agent filesystem)
3. A cryptographically random 256-bit session token is generated (useless outside localhost)
4. The kernel sandbox is applied (irreversible — agent can only reach localhost)
5. Agent's environment gets `ANTHROPIC_BASE_URL=http://127.0.0.1:<port>` (SDKs respect this automatically)
6. Agent sends API requests to localhost with the phantom token
7. Proxy validates token (constant-time comparison), strips it, injects real API key, forwards upstream over TLS
8. Real credentials are stored in `Zeroizing<String>` and wiped from nono's memory after exec

**Result:** Even if the agent is fully compromised, there is nothing to exfiltrate.

## What Changes in TaskYou-OS

### 1. New Config Section (`config.example.env`)

```bash
# --- Credential Proxy (nono) ---
# Enable nono-powered credential isolation for all agent executors
NONO_ENABLED=true

# Credentials to store in the secure vault (name:ENV_VAR pairs)
# These are read from your config.env during setup, stored in the Linux
# Secret Service on the server, then REMOVED from the server filesystem.
# Agents access them only through nono's phantom token proxy.
NONO_CREDENTIALS="linear:LINEAR_API_KEY,github:GITHUB_TOKEN"

# Hosts that agents can reach through the credential proxy
NONO_PROXY_HOSTS="api.linear.app,api.github.com"
```

### 2. Server Provisioning (`setup.sh`)

New function: `setup_nono()`, called during server/exe provisioning when `NONO_ENABLED=true`.

```bash
setup_nono() {
    # 1. Install nono
    ssh "$SSH_TARGET" "curl -fsSL https://nono.sh/install.sh | bash"

    # 2. Store credentials in Linux Secret Service
    for entry in $(echo "$NONO_CREDENTIALS" | tr ',' ' '); do
        name=$(echo "$entry" | cut -d: -f1)
        env_var=$(echo "$entry" | cut -d: -f2)
        value="${!env_var}"
        ssh "$SSH_TARGET" "echo '$value' | secret-tool store --label='nono: $name' service nono username $name"
    done

    # 3. Deploy nono profile
    render_file "templates/nono-profile.toml.tmpl" "$REMOTE_HOME/.config/nono/profiles/taskyou-agent.toml"

    # 4. Deploy executor wrappers
    for executor in claude codex gemini openclaw opencode pi; do
        EXECUTOR_BIN="$executor" render_file "templates/nono-wrapper.sh.tmpl" "$REMOTE_HOME/bin/$executor"
        ssh "$SSH_TARGET" "chmod +x $REMOTE_HOME/bin/$executor"
    done

    # 5. Ensure ~/bin is first in PATH
    ssh "$SSH_TARGET" "grep -q 'export PATH=\$HOME/bin:\$PATH' ~/.bashrc || echo 'export PATH=\$HOME/bin:\$PATH' >> ~/.bashrc"

    # 6. Remove plain-text .env files from server
    ssh "$SSH_TARGET" "rm -f $REMOTE_HOME/tools/linear-cli/.env $REMOTE_HOME/scripts/.env"
}
```

### 3. New Templates

#### `templates/nono-profile.toml.tmpl`

The nono profile that defines the sandbox policy for all TaskYou agents.

```toml
[meta]
name = "taskyou-agent"
extends = "claude-code"
description = "TaskYou agent sandbox with credential isolation"

[filesystem]
# Agents can read/write their project worktrees
allow = ["$HOME/projects"]

# Agents can read TaskYou config and hooks
read = [
    "$HOME/.config/task",
    "$HOME/.claude",
    "$HOME/.local/share/task"
]

# Block access to credential stores and sensitive paths
# (Landlock default-deny handles this, but explicit for clarity)

[workdir]
sharing = "readwrite"
```

#### `templates/nono-wrapper.sh.tmpl`

Generic wrapper script rendered once per executor.

```bash
#!/bin/bash
# nono credential isolation wrapper for {{EXECUTOR_BIN}}
# Generated by TaskYou-OS setup.sh — do not edit manually

REAL_BIN=$(PATH=$(echo "$PATH" | sed "s|$HOME/bin:||") which {{EXECUTOR_BIN}} 2>/dev/null)

if [ -z "$REAL_BIN" ]; then
    echo "Error: {{EXECUTOR_BIN}} not found in PATH (excluding ~/bin)" >&2
    exit 1
fi

exec nono run \
    --profile taskyou-agent \
    --allow-cwd \
    {{NONO_PROXY_FLAGS}} \
    -- "$REAL_BIN" "$@"
```

Where `{{NONO_PROXY_FLAGS}}` is rendered from the config:
```bash
--proxy-allow api.linear.app --proxy-credential linear --proxy-allow api.github.com --proxy-credential github
```

### 4. Modified Templates

#### `templates/hooks/task.started.tmpl`

No changes needed. The hook auto-accepts Claude trust for worktree paths. nono wraps the process transparently — the hook fires the same way.

#### `templates/CLAUDE.md.tmpl` (server-side agent instructions)

Add a note so agents understand they're running in a sandbox:

```markdown
## Credentials

You are running inside a nono sandbox. Credentials are injected automatically
via a localhost proxy — you do not need to read .env files or manage API keys.
If you need access to a credential that isn't available, create a blocked task
explaining what you need.
```

### 5. What Gets Removed

When `NONO_ENABLED=true`:

- **No more `.env` files on the server** — credentials stored in Linux Secret Service only
- **No more `LINEAR_API_KEY` in linear-cli/.env** — accessed via nono proxy or env credential injection
- **No more plain-text secrets anywhere on the agent filesystem**

## What Does NOT Change

- **TaskYou daemon** — no code changes, still manages tasks/worktrees/tmux normally
- **Local GM** — unchanged, still SSH's into server
- **SwiftBar / agent-monitor** — unchanged
- **Template rendering engine** — just new templates added
- **`--dangerously-skip-permissions`** — still used (nono handles the security boundary)
- **Hooks** — same hooks, same behavior

## Executor Coverage

The PATH wrapper approach covers all TaskYou executors uniformly:

| Executor | Binary | Wrapper Created |
|----------|--------|----------------|
| Claude | `claude` | `~/bin/claude` |
| Codex | `codex` | `~/bin/codex` |
| Gemini | `gemini` | `~/bin/gemini` |
| OpenClaw | `openclaw` | `~/bin/openclaw` |
| OpenCode | `opencode` | `~/bin/opencode` |
| Pi | `pi` | `~/bin/pi` |

All executors get the same sandbox policy and credential access. The nono profile is agent-agnostic.

## Opt-In Behavior

- `NONO_ENABLED=true` in config.env enables the feature
- `NONO_ENABLED=false` (or unset) skips nono entirely — current behavior preserved
- The entire feature is wrapped in `{{#NONO}} ... {{/NONO}}` conditional blocks in templates
- Existing deployments are unaffected unless they opt in

## User Experience

### Setup

```bash
# 1. Edit config.env
NONO_ENABLED=true
NONO_CREDENTIALS="linear:LINEAR_API_KEY,github:GITHUB_TOKEN,stripe:STRIPE_SECRET_KEY"
NONO_PROXY_HOSTS="api.linear.app,api.github.com,api.stripe.com"

# 2. Run setup (new deployment or re-provision)
./setup.sh server

# Done. Agents are now sandboxed with credential isolation.
```

### Verification

```bash
# SSH into server and verify nono is working
ssh myserver "nono run --dry-run --profile taskyou-agent --allow-cwd -- claude"

# Check credentials are stored
ssh myserver "secret-tool lookup service nono username linear"

# Verify no plain-text .env files remain
ssh myserver "find ~ -name '.env' -type f"
```

## Platform Requirements

- **Linux kernel 5.13+** for Landlock (required for sandbox enforcement)
- **libsecret / Secret Service** for credential storage (available on Ubuntu 20.04+)
- **nono CLI** (installed by setup.sh)

### exe.dev Compatibility

exe.dev VMs run Ubuntu with full sudo access and Docker support. Kernel version needs verification — if Landlock isn't available, nono falls back to a degraded mode (credential proxy still works, but filesystem sandboxing is not enforced). This should be validated before deploying.

## Future Enhancements (Not in v1)

### Per-Request Approval (v2)
nono's `--supervised` mode uses seccomp user notifications for interactive per-request approval. For headless agents, this would need an adapter that:
- Writes approval requests to `notifications.jsonl`
- SwiftBar or the local GM picks them up
- User approves/denies via `ty approve <id>` or SwiftBar action

### Bypass Mode (v2)
Time-limited auto-approve for when the user is actively monitoring:
- `ty bypass 30m` — auto-approve all credential requests for 30 minutes
- Reverts to normal policy after timeout

### Per-Project Credential Scoping (v2)
Different projects get different credential sets:
```bash
# In .taskyou.yml
nono:
  credentials: ["linear", "github"]
  # This project can't access stripe credentials
```

### TaskYou Native Integration (v3)
Add `executor.wrapper` config to TaskYou itself:
```yaml
executor:
  wrapper: "nono run --profile taskyou-agent --allow-cwd --"
```
Eliminates the PATH wrapper approach. Requires a small TaskYou change (~10 lines of Go).

### Audit Dashboard (v3)
Surface nono's audit trail in the TaskYou board UI — show which credentials each agent used, when, and for what.
