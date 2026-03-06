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
│ SwiftBar     │ ←── poll ─────── │ │ Agent 2      │ │
│ (menu bar)   │                  │ │ ...          │ │
│              │                  │ └──────────────┘ │
│ launchd      │                  │                  │
│ (monitor)    │                  │ notifications    │
└──────────────┘                  │ .jsonl           │
                                  └──────────────────┘
```

- You talk to the **GM** (a Claude session on your Mac) in plain English
- The GM creates tasks and assigns them to **agents** on the server
- Agents work in the background — close your laptop, they keep going
- Get notified when tasks finish or need your attention
- Optional menu bar widget shows live agent status

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

## Optional Integrations

- **Linear** — Escalate tasks that need human attention to your Linear board
- **Cloudflare R2** — Host files and assets your agents generate
- **GitHub** — Push agent work to your repositories
- **SwiftBar** — Menu bar monitoring with auto-resolution of stuck agents

## Manual Setup

If you prefer to configure things yourself instead of using the interactive setup:

```bash
mkdir -p ~/Projects/gms/myproject
cp config.example.env ~/Projects/gms/myproject/config.env
# Edit config.env with your values
./setup.sh all ~/Projects/gms/myproject
```

Modes: `local` (Mac only), `server` (remote server only), `exe` (exe.dev VM), `all` (local + server).

See `config.example.env` for all available configuration options.
