---
name: gm-help
description: Quick reference of GM commands and how everything works
---

Here's a quick reference of how everything works.

First, load the project configuration:
```bash
source ./config.env
echo "Project: $PROJECT_DISPLAY_NAME"
echo "Workspaces: $PROJECTS"
echo "Server home: $SERVER_HOME"
```

## GM Commands

| Command | What it does |
|---------|-------------|
| `/gm-status` | Check what's happening — daemon, tasks, agents |
| `/gm-start` | Getting started guide with example prompts |
| `/gm-fix` | Diagnose and fix problems automatically |
| `/gm-babysit` | Check on all tracked tasks for a status update |
| `/gm-help` | This reference |

## How the GM works

You are a **manager, not a doer**. You translate ideas into tasks that AI agents execute on a remote server.

1. **You create tasks** — break down what needs doing into clear, focused tasks
2. **The daemon assigns agents** — each task gets picked up by an AI agent automatically
3. **Agents work in isolation** — each task gets its own git branch/worktree
4. **You review and deliver** — check output, push to GitHub, hand off to humans

## Quick reference

```bash
# Run any TaskYou command on the server
./bin/ty-remote <command>

# Run any other command on the server
./bin/ssh-remote <command>
```

### Common TaskYou commands

| Command | What it does |
|---------|-------------|
| `./bin/ty-remote list` | List all tasks |
| `./bin/ty-remote board` | Kanban board view |
| `./bin/ty-remote create "title" --project <name> --type <type> --body "details"` | Create a task |
| `./bin/ty-remote execute <id>` | Send task to an agent |
| `./bin/ty-remote retry <id>` | Retry a blocked/failed task |
| `./bin/ty-remote output <id>` | See what an agent produced |
| `./bin/ty-remote close <id>` | Mark task as done |
| `./bin/ty-remote sessions list` | See running agents |
| `./bin/ty-remote sessions cleanup` | Clean up stale sessions |
| `./bin/ty-remote daemon status` | Check if daemon is running |

### Projects

Available workspaces are listed in the configuration output above.

Each project is a git repo at `$SERVER_HOME/projects/<project>/` on the server (where `$SERVER_HOME` was echoed above).

### Task types

| Type | Use for |
|------|---------|
| `draft` | Polished first drafts |
| `research` | Market research, competitor analysis |
| `outreach` | Sales emails, sequences |
| `social` | Social media content |
| `writing` | General writing |
| `thinking` | Strategic analysis and planning |
