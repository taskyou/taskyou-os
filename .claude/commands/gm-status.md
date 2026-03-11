---
name: gm-status
description: Check the current state of operations — daemon, tasks, and agents
---

Check the current state of operations.

## Load project configuration

```bash
source ./config.env
```

## Steps

1. **Check daemon status:**
```bash
./bin/ty-remote daemon status
```

2. **List all tasks:**
```bash
./bin/ty-remote list
```

3. **Check running agent sessions:**
```bash
./bin/ty-remote sessions list
```

## How to report

Summarize what you find in a clear status report:

- **Daemon**: running or not
- **Tasks**: count by status (active / queued / blocked / done)
- **Agents**: which agents are running and on what tasks
- **Issues**: flag anything wrong — daemon not running, stuck tasks, blocked tasks with no clear reason

Keep it short. Lead with problems if there are any.
