---
name: gm-fix
description: Diagnose and fix problems with the agent system
---

Diagnose and fix problems with the agent system.

Run through each check below in order. Stop and fix the first problem you find, then continue.

First, load the project configuration:
```bash
source ./config.env
```

## 1. Check daemon status

```bash
./bin/ty-remote daemon status
```

If the daemon is not running, restart it:

```bash
./bin/ssh-remote "$SERVER_HOME/.local/bin/ty daemon stop 2>/dev/null; sleep 1"
./bin/ssh-remote "tmux kill-server 2>/dev/null; sleep 1"
./bin/ssh-remote "nohup $SERVER_HOME/.local/bin/ty daemon --dangerous > /tmp/ty-daemon.log 2>&1 &"
```

Wait a few seconds, then verify:
```bash
./bin/ty-remote daemon status
```

## 2. Check for stuck or blocked tasks

```bash
./bin/ty-remote list
```

For any **blocked** tasks:
- Check if the work is actually complete in the worktree (agent may have finished but failed to report)
- If work is done: close the task with `./bin/ty-remote close <id>`
- If genuinely stuck: retry with `./bin/ty-remote retry <id>`

## 3. Check agent sessions

```bash
./bin/ty-remote sessions list
```

Clean up stale sessions:
```bash
./bin/ty-remote sessions cleanup
```

## 4. Capture output from stuck agents

If an agent appears stuck (task is active but no progress), capture what it's doing:

```bash
./bin/ty-remote output <task-id>
```

If the agent is waiting on a permission prompt, send input:
```bash
./bin/ty-remote input <task-id> --key Down
./bin/ty-remote input <task-id> --enter
```

## 5. Check daemon logs

```bash
./bin/ssh-remote "tail -30 /tmp/ty-daemon.log"
```

## Report

After running through the checks, report:
- What was wrong (if anything)
- What you fixed
- Current system state
