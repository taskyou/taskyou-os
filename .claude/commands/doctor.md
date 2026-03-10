---
name: doctor
description: Check the health of your TaskYou-OS installation — plugin version, TaskYou version, daemon status, and executor health. Diagnoses and fixes issues automatically.
---

You are a diagnostic assistant. Run health checks on the user's TaskYou-OS installation and fix any issues you find. Be thorough but concise.

User arguments (if any): $ARGUMENTS

**Tone:** Direct and clear. Use checkmarks for passing checks, warnings for issues, and X marks for failures. Fix what you can automatically — only ask the user when you genuinely need their input.

**Output style:**
- Show a clear header for each check section
- Use these status indicators: PASS, WARN, FAIL
- After all checks, show a summary with any recommended actions
- If you fix something, say what you did

---

## How to run the checks

Run ALL checks below in order. For each check, report the result and take action if needed.

**First, detect the environment.** Find the server host from any existing GM config:
```bash
CONFIG=$(ls ~/Projects/gms/*/config.env 2>/dev/null | head -1)
if [ -n "$CONFIG" ]; then
  source "$CONFIG"
  echo "GM_PROJECT=$PROJECT_NAME"
  echo "SERVER=$SERVER_HOST"
  echo "IS_EXE_DEV=$(echo $SERVER_HOST | grep -c '.exe.xyz')"
fi
```

If there are multiple GMs, list them and let the user pick, or check all of them.

---

### Check 1: TaskYou-OS Plugin Version

Update the taskyou-os plugin to the latest version from the marketplace.

**Steps:**

1. Pull latest from the marketplace repo:
```bash
git -C ~/.claude/plugins/marketplaces/taskyou-os pull --quiet 2>/dev/null
```

2. Check if the installed cache is stale by comparing commit SHAs:
```bash
INSTALLED_SHA=$(cat ~/.claude/plugins/installed_plugins.json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); entries=d.get('plugins',{}).get('taskyou-os@taskyou-os',[]); print(entries[0]['gitCommitSha'] if entries else 'NONE')" 2>/dev/null)
LATEST_SHA=$(git -C ~/.claude/plugins/marketplaces/taskyou-os rev-parse HEAD 2>/dev/null)
echo "Installed: $INSTALLED_SHA"
echo "Latest:    $LATEST_SHA"
```

3. If they differ, update the plugin cache and installed_plugins.json:
```bash
# Copy latest marketplace content to cache
CACHE_DIR=~/.claude/plugins/cache/taskyou-os/taskyou-os
LATEST_VERSION=$(python3 -c "import json; print(json.load(open('$HOME/.claude/plugins/marketplaces/taskyou-os/.claude-plugin/plugin.json'))['version'])" 2>/dev/null)
rm -rf "$CACHE_DIR"
mkdir -p "$CACHE_DIR/$LATEST_VERSION"
cp -R ~/.claude/plugins/marketplaces/taskyou-os/. "$CACHE_DIR/$LATEST_VERSION/"

# Update installed_plugins.json with new SHA, version, and path
python3 -c "
import json, datetime
f = '$HOME/.claude/plugins/installed_plugins.json'
d = json.load(open(f))
for entry in d.get('plugins', {}).get('taskyou-os@taskyou-os', []):
    entry['gitCommitSha'] = '$LATEST_SHA'
    entry['version'] = '$LATEST_VERSION'
    entry['installPath'] = '$CACHE_DIR/$LATEST_VERSION'
    entry['lastUpdated'] = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%S.000Z')
json.dump(d, open(f, 'w'), indent=2)
"
```

Report PASS if already up to date, or WARN with "Updated plugin — restart Claude Code to use the new version."

**If the plugin isn't installed at all:** Report FAIL.

---

### Check 2: TaskYou Binary Version

Check if `ty` is installed and whether it can be upgraded.

**Steps:**

1. Check locally:
```bash
which ty && ty --version 2>/dev/null || echo "NOT_INSTALLED"
```

2. Check on the remote server (if detected):
```bash
ssh -o ConnectTimeout=5 "$SERVER_HOST" 'export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH" && which ty && ty --version 2>/dev/null || echo "NOT_INSTALLED"' 2>/dev/null
```

3. Check latest available version:
```bash
curl -fsSL https://api.github.com/repos/bborn/taskyou/releases/latest 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('tag_name','unknown'))" 2>/dev/null
```

4. Compare versions. If outdated, run the upgrade:
```bash
ty upgrade 2>/dev/null
```
And remotely:
```bash
ssh "$SERVER_HOST" 'export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH" && ty upgrade 2>/dev/null'
```

**If not installed:** Report FAIL and provide: `curl -fsSL taskyou.dev/install.sh | bash`

**If upgraded:** Report WARN with the old/new versions.

**If up to date:** Report PASS.

---

### Check 3: TaskYou Daemon Running

Check if the TaskYou daemon is running.

**Steps:**

1. Check locally:
```bash
ty daemon status 2>/dev/null
pgrep -af "ty daemon" 2>/dev/null || echo "NO_DAEMON_PROCESS"
```

2. Check on the remote server:
```bash
ssh -o ConnectTimeout=5 "$SERVER_HOST" 'pgrep -af "ty daemon" 2>/dev/null || echo "NO_DAEMON_PROCESS"' 2>/dev/null
ssh -o ConnectTimeout=5 "$SERVER_HOST" 'export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH" && ty daemon status 2>/dev/null' 2>/dev/null
```

**If not running and there's a remote server:** Start it automatically (in dangerous mode if exe.dev):
```bash
ssh "$SERVER_HOST" 'export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH" && nohup ty daemon --dangerous > /tmp/ty-daemon.log 2>&1 &'
```

**If not running locally:** Report WARN and note the daemon isn't running. Offer to start it.

**If running:** Report PASS and proceed.

---

### Check 4: Dangerous vs Safe Mode

Check whether the remote daemon is running in dangerous mode.

**Steps:**

1. Check the daemon process flags on the remote server:
```bash
ssh -o ConnectTimeout=5 "$SERVER_HOST" 'pgrep -af "ty daemon"' 2>/dev/null
```

2. Look for `--dangerous` in the process args.

**If on an exe.dev server and NOT in dangerous mode:** Report WARN. Explain: "Your agents run on an isolated exe.dev server, so dangerous mode is safe and recommended — without it, agents get stuck on permission prompts." Fix it automatically:
```bash
ssh "$SERVER_HOST" 'pkill -f "ty daemon"; sleep 2; export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH" && nohup ty daemon --dangerous > /tmp/ty-daemon.log 2>&1 &'
```
Wait a moment, then verify the daemon restarted:
```bash
ssh "$SERVER_HOST" 'sleep 1 && pgrep -af "ty daemon"' 2>/dev/null
```

**If in dangerous mode on exe.dev:** Report PASS.

**If local only:** Skip this check or report PASS (safe mode is appropriate locally).

---

### Check 5: Active Tasks Have Executor Panes

Check that every in-progress or blocked task has a corresponding tmux executor pane.

**Steps:**

1. Get active tasks (prefer remote server if it exists, otherwise local):
```bash
# Remote
ssh -o ConnectTimeout=5 "$SERVER_HOST" 'export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH" && ty list --status processing --json 2>/dev/null && echo "---BLOCKED---" && ty list --status blocked --json 2>/dev/null' 2>/dev/null

# Local fallback
ty list --status processing --json 2>/dev/null
ty list --status blocked --json 2>/dev/null
```

2. For each active task, check if it has a tmux window. The tmux session is named `task-daemon-{PID}` and windows are named `task-{ID}`:
```bash
# Remote
ssh "$SERVER_HOST" 'for sess in $(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep task-daemon); do tmux list-windows -t "$sess" -F "#{window_name}" 2>/dev/null; done'

# Local
for sess in $(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep task-daemon); do tmux list-windows -t "$sess" -F "#{window_name}" 2>/dev/null; done
```

3. Also check executor sessions:
```bash
ssh "$SERVER_HOST" 'export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH" && ty sessions list 2>/dev/null'
```

4. Cross-reference: every processing/blocked task ID should have a matching `task-{ID}` tmux window.

5. For any task missing its executor pane, try to recover it:
```bash
ssh "$SERVER_HOST" "export PATH=\$HOME/.local/bin:\$HOME/.npm-global/bin:\$PATH && ty execute <task-id>"
```
or locally:
```bash
ty execute <task-id>
```

6. If recovery fails, report the orphaned task IDs and suggest:
```bash
ty retry <id> --feedback "Restarting — executor pane was lost"
```

7. Also check for orphaned executor processes (tmux panes with no matching active task):
```bash
ssh "$SERVER_HOST" 'export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH" && ty sessions cleanup 2>/dev/null'
```

**If no active tasks:** Report PASS with "No active tasks to check."
**If all tasks have executors:** Report PASS.
**If orphaned tasks found and recovered:** Report WARN with what was fixed.
**If orphaned tasks that couldn't be recovered:** Report FAIL with the task IDs and suggested commands.

---

## Summary

After all checks, present a summary table:

```
TaskYou-OS Doctor
─────────────────────────────────
  Plugin version     PASS/WARN/FAIL
  TaskYou binary     PASS/WARN/FAIL
  Daemon running     PASS/WARN/FAIL
  Daemon mode        PASS/WARN/FAIL
  Executor health    PASS/WARN/FAIL
─────────────────────────────────
```

If you fixed anything, note what you did below the table.
If any issues remain that you couldn't fix, list the specific commands the user should run.
If everything passes, just say: "All systems healthy."
