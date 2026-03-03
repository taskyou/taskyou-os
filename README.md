# TaskYouOS

Generate a fully working AI agent management system from a single config file. Creates a local "General Manager" Claude session backed by remote TaskYou agents, with SwiftBar menu bar monitoring, auto-resolution of blocked tasks, and optional Linear/R2 integrations.

## Quick Start

Install the plugin (one-time):

```
/plugin marketplace add taskyou/taskyou-os
/plugin install taskyou-os
```

Then run:

```
/taskyou-os-launch
```

That's it. The command walks you through everything interactively — it'll ask about your project, spin up a server on [exe.dev](https://exe.dev) (or your own server), install dependencies, write your config, and get your AI agent team running. No manual config editing, no copying commands. It handles the technical details so you don't have to.

Don't have an exe.dev account yet? No problem — the setup will check for SSH keys (and create one if needed), then walk you through signing up. The whole thing takes a couple of minutes.

You can also resume an interrupted setup or fix issues by running it again — it detects what's already done and picks up where it left off.

## Manual Setup

If you prefer to do it yourself:

```bash
# 1. Create your project directory and config
mkdir -p ~/Projects/gms/myproject
cp config.example.env ~/Projects/gms/myproject/config.env

# 2. Edit the config
vim ~/Projects/gms/myproject/config.env

# 3. Run setup (local + server)
./setup.sh all ~/Projects/gms/myproject

# 4. Follow the printed checklist for manual steps
```

## What Gets Generated

**Local (your Mac):**
- `CLAUDE.md` — GM instructions with your project's config baked in
- `.claude/settings.json` — Claude Code permissions
- `bin/` — SwiftBar plugin, action router, monitor, retry/board scripts
- `tmp/wrangler.toml` — R2 upload config (if enabled)
- LaunchAgent plist for background monitoring

**Server:**
- Project git repos at `~/projects/<name>/`
- TaskYou hooks for completed/blocked notifications
- Linear CLI and @agent polling (if enabled)
- TaskYou daemon running in `--dangerous` mode

## Setup Modes

```bash
./setup.sh local ~/Projects/gms/myproject   # Local files only
./setup.sh server ~/Projects/gms/myproject  # Server provisioning only
./setup.sh all ~/Projects/gms/myproject     # Both
```

## Config Reference

See `config.example.env` for all variables with documentation.

**Required:** `PROJECT_NAME`, `PROJECT_DISPLAY_NAME`, `GM_ALIAS`, `SERVER_HOST`, `SERVER_USER`, `SERVER_HOME`, `PROJECTS`, `LOCAL_PROJECT_DIR`, `CLAUDE_CONFIG_DIR`, `GIT_NAME`, `GIT_EMAIL`

**Optional modules:**
- **Linear** (`LINEAR_ENABLED=true`) — Issue handoff, @agent revisions, CLI
- **R2** (`R2_ENABLED=true`) — Asset hosting via Cloudflare R2

## Architecture

```
Your Mac                          Server
┌──────────────┐                  ┌──────────────────┐
│ Claude Code  │ ──── SSH ─────→  │ TaskYou daemon   │
│ (GM session) │                  │ ┌──────────────┐ │
│              │                  │ │ Agent 1      │ │
│ SwiftBar     │ ←── poll ─────── │ │ Agent 2      │ │
│ (menu bar)   │                  │ │ ...          │ │
│              │                  │ └──────────────┘ │
│ launchd      │                  │                  │
│ (monitor)    │                  │ notifications    │
└──────────────┘                  │ .jsonl           │
                                  └──────────────────┘
```

The GM session translates your instructions into TaskYou tasks. Agents execute them on the server. The SwiftBar plugin monitors status and auto-resolves common blockers (permission prompts, dead sessions). Tasks that need human attention get escalated to Linear.

## Prerequisites

- macOS with iTerm2
- SSH key-based access to the server
- Claude Code CLI installed locally and on the server
- SwiftBar (optional, for menu bar monitoring)
- Node.js on the server (for TaskYou and Linear integration)
