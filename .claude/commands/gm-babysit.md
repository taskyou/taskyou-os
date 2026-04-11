---
name: gm-babysit
description: Check on all tracked tasks for an immediate status update
---

Check on all tasks you're currently tracking. Use this for an immediate status update.

Note: Task events normally arrive automatically via the taskyou channel. This command is for a manual spot-check when you want an immediate snapshot.

First, load the project configuration:
```bash
source ./config.env
```

## Steps

1. **Check for recent events** from the server notification stream:
```bash
./bin/ssh-remote "tail -20 $SERVER_HOME/notifications.jsonl" 2>/dev/null
```

2. **Get current task statuses:**
```bash
./bin/ty-remote list
```

3. **Compare against your todos** — identify any status changes since last check.

4. **For each tracked task, report:**
   - **Completed**: Mark todo done. Offer to show output (`./bin/ty-remote output <id>`).
   - **Blocked**: Explain what's blocking it. Suggest next steps (retry, send input, review output).
   - **Still processing**: Note it's still running — no action needed unless it's been unusually long.

5. **If all tracked tasks are done**, let the user know there's nothing left to monitor.

Keep updates brief — one line per task.
