# TaskYouOS

Your own AI agent team, running on a remote server and managed through Claude Code.

You describe what you need in plain English. A "General Manager" on your Mac delegates work to background agents on the server. They research, analyze, write, and build — even while your laptop is closed.

## Get Started

You need [Claude Code](https://claude.ai/claude-code). Open it and run:

```
/plugin marketplace add taskyou/taskyou-os
/plugin install taskyou-os
/taskyou-os:launch
```

That's it. The setup walks you through everything:

1. **What's your project?** — Tell it what you're working on and it designs your agent workspaces
2. **Server** — Spins up a cloud server on [exe.dev](https://exe.dev) (or uses your own). Installs everything automatically
3. **Config** — Writes your configuration file based on your answers
4. **Deploy** — Sets up the server, authorizes your agents, starts the daemon
5. **Done** — Gives you a launch command and shows you how to use your new GM

No git cloning, no manual config editing, no SSH knowledge required. The setup handles SSH keys, exe.dev signup, software installation, and authentication transfer for you.

You can re-run `/taskyou-os:launch` anytime to resume an interrupted setup or fix issues.

## How It Works

```
Your Mac                          Server
┌──────────────┐                  ┌──────────────────┐
│ Claude Code  │ ──── SSH ─────→  │ TaskYou daemon   │
│ (GM session) │                  │ ┌──────────────┐ │
│              │                  │ │ Agent 1      │ │
│              │                  │ │ Agent 2      │ │
│              │                  │ │ ...          │ │
│              │                  │ └──────────────┘ │
│              │                  │                  │
│              │                  │ notifications    │
└──────────────┘                  │ .jsonl           │
                                  └──────────────────┘
```

- You talk to the **GM** (a Claude session on your Mac) in plain English
- The GM creates tasks and assigns them to **agents** on the server
- Agents work in the background — close your laptop, they keep going
- The GM **automatically tracks running tasks** and notifies you when they complete or get blocked — no need to remember to check
- Use `/gm-babysit` for an immediate status check on all tracked tasks

## exe.dev Deployment (No Local Machine Required)

Instead of running the GM on your Mac over SSH, you can deploy it entirely onto an [exe.dev](https://exe.dev) VM. This gives you a web-accessible GM with:

- A **landing page** with a live kanban board
- A **one-click terminal** button that opens the GM in your browser
- No local machine required — access from anywhere

```
Browser                           exe.dev VM
┌──────────────┐                  ┌──────────────────┐
│ Landing page │ ──── HTTPS ───→  │ nginx (port 8000)│
│ (kanban)     │ ← board.json ──  │                  │
│              │                  │ TaskYou daemon   │
│ GM Terminal  │ ──── xterm ───→  │ ┌──────────────┐ │
│ (browser)    │                  │ │ Agent 1      │ │
│              │                  │ │ Agent 2      │ │
│              │                  │ │ ...          │ │
│              │                  │ └──────────────┘ │
└──────────────┘                  └──────────────────┘
```

To deploy:

```bash
# Set EXE_DEV_VM_NAME in your config.env, then:
./setup.sh exe ~/Projects/gms/myproject
```

This creates the VM, uploads everything, and prints the URL. Share access with teammates via `ssh exe.dev share add <vm> user@example.com`.

## GM Commands

Once your GM is running, these commands are available:

| Command | What it does |
|---------|-------------|
| `/gm-babysit` | Immediate status check on all tracked tasks |
| `/gm-status` | Daemon, tasks, and agents overview |
| `/gm-fix` | Diagnose and fix agent system problems |
| `/gm-start` | Getting started guide with project-specific examples |
| `/gm-help` | Quick reference for all commands and TaskYou CLI |

## Plugin Commands

These run from the taskyou-os plugin context (not inside a GM):

| Command | What it does |
|---------|-------------|
| `/taskyou-os:launch` | Interactive wizard to create a new GM |
| `/taskyou-os:doctor` | Health check — updates plugin, checks versions, daemon status, executor health, template drift, security audit |

Run `/doctor` periodically to keep things healthy. It also detects new commands available from the plugin and offers to add them to existing GMs.

## Built-in Modules

These are configured via flags in `config.env` during setup. They're part of the repo, not separate installs.

- **Linear** (`LINEAR_ENABLED=true`) — Agent-to-human handoff via Linear issues, plus `@agent` comments for revisions
- **Cloudflare R2** (`R2_ENABLED=true`) — Public URLs for files and assets agents generate
- **GitHub** (`GITHUB_REPOS=workspace:org/repo`) — Push agent work to your repositories

## Manual Setup

If you prefer to skip the interactive `/launch` wizard:

```bash
mkdir -p ~/Projects/gms/myproject
cp config.example.env ~/Projects/gms/myproject/config.env
# Edit config.env with your values
./setup.sh all ~/Projects/gms/myproject
```

Modes: `local` (Mac only), `server` (remote server only), `exe` (exe.dev VM), `all` (local + server).

See `config.example.env` for all available configuration options.
