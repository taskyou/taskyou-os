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

Check if the TaskYou daemon is running, preferring the systemd user service.

**Steps:**

1. Check if the systemd user service exists on the remote server:
```bash
ssh -o ConnectTimeout=5 "$SERVER_HOST" 'systemctl --user status ty-daemon 2>/dev/null' 2>/dev/null
```

2. If the service exists, check its status:
   - **active (running):** Report PASS with "Daemon running via systemd service"
   - **inactive/failed:** Try to start it:
     ```bash
     ssh "$SERVER_HOST" 'systemctl --user start ty-daemon'
     ```
     Then verify. Report WARN if started, FAIL if it won't start (show `systemctl --user status ty-daemon` output).

3. If no systemd service exists, fall back to checking for an ad-hoc process:
```bash
ssh -o ConnectTimeout=5 "$SERVER_HOST" 'pgrep -af "ty daemon" 2>/dev/null || echo "NO_DAEMON_PROCESS"' 2>/dev/null
```
   - If an ad-hoc process is running, report WARN: "Daemon is running but not managed by systemd. Re-run setup to install the systemd service for auto-start on boot and crash recovery."
   - If nothing is running, report FAIL and offer to start it.

4. Check locally:
```bash
ty daemon status 2>/dev/null
pgrep -af "ty daemon" 2>/dev/null || echo "NO_DAEMON_PROCESS"
```

5. Verify lingering is enabled (required for boot-time start without login):
```bash
ssh "$SERVER_HOST" 'ls /var/lib/systemd/linger/$(whoami) 2>/dev/null && echo "LINGER_ENABLED" || echo "LINGER_DISABLED"'
```
   - If disabled, report WARN and fix: `ssh "$SERVER_HOST" 'sudo loginctl enable-linger $(whoami)'`

**If not running locally:** Report WARN and note the daemon isn't running. Offer to start it.

**If running:** Report PASS and proceed.

---

### Check 4: Dangerous vs Safe Mode

Check whether the remote daemon is running in dangerous mode.

**Steps:**

1. Check via systemd service (preferred):
```bash
ssh -o ConnectTimeout=5 "$SERVER_HOST" 'systemctl --user cat ty-daemon 2>/dev/null | grep ExecStart' 2>/dev/null
```

2. Fall back to checking process flags if no systemd service:
```bash
ssh -o ConnectTimeout=5 "$SERVER_HOST" 'pgrep -af "ty daemon"' 2>/dev/null
```

3. Look for `--dangerous` in the ExecStart line or process args.

**If on an exe.dev server and NOT in dangerous mode:** Report WARN. Explain: "Your agents run on an isolated exe.dev server, so dangerous mode is safe and recommended — without it, agents get stuck on permission prompts." Fix it automatically:
```bash
ssh "$SERVER_HOST" 'systemctl --user restart ty-daemon'
```
Wait a moment, then verify the daemon restarted:
```bash
ssh "$SERVER_HOST" 'systemctl --user is-active ty-daemon' 2>/dev/null
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

### Check 6: GM Command Migration

GM commands (`/gm-status`, `/gm-fix`, `/gm-start`, `/gm-help`, `/gm-babysit`) are now delivered by the TaskYou-OS plugin directly. Old locally-rendered copies in the GM's `.claude/commands/` directory shadow the plugin versions and must be removed.

**Steps:**

1. Check for old local gm-* command files in the GM directory:
```bash
ls "$LOCAL_PROJECT_DIR/.claude/commands/gm-"*.md 2>/dev/null
```

2. If any `gm-*.md` files exist in `$LOCAL_PROJECT_DIR/.claude/commands/`:
   - These are old rendered copies from before commands moved to the plugin
   - They shadow the plugin commands, preventing automatic updates from reaching the user
   - List them and explain: "These commands are now delivered by the TaskYou-OS plugin and update automatically. The local copies need to be removed so the plugin versions take effect."
   - Remove them:
   ```bash
   rm "$LOCAL_PROJECT_DIR/.claude/commands/gm-"*.md
   ```
   - If the `.claude/commands/` directory is now empty, remove it:
   ```bash
   rmdir "$LOCAL_PROJECT_DIR/.claude/commands" 2>/dev/null
   ```

3. Verify `config.env` exists in the GM project root (plugin commands need it at runtime):
```bash
test -f "$LOCAL_PROJECT_DIR/config.env" && echo "config.env found" || echo "config.env MISSING"
```

If `config.env` is missing, report FAIL — the plugin commands won't work without it.

4. **For CLAUDE.md** — check if the plugin's template has new sections the GM is missing:
   - Find the plugin directory:
   ```bash
   PLUGIN_DIR=$(python3 -c "import json; d=json.load(open('$HOME/.claude/plugins/installed_plugins.json')); entries=d.get('plugins',{}).get('taskyou-os@taskyou-os',[]); print(entries[0]['installPath'] if entries else '')" 2>/dev/null)
   ```
   - Read the plugin's `$PLUGIN_DIR/templates/CLAUDE.md.tmpl`
   - Read the GM's `$LOCAL_PROJECT_DIR/CLAUDE.md`
   - Compare section headers (`## ` lines) between the template and the GM's file
   - For each section in the template that does NOT exist in the GM's CLAUDE.md:
     - Render that section (substitute `{{VARIABLE}}` placeholders using config.env values)
     - **Show the user** the new section content and where it would logically go
     - **Ask the user** if they want to add it
     - If yes, insert it at the appropriate location in the GM's CLAUDE.md
   - Do NOT touch or overwrite existing sections — only offer to add new ones

**If no local gm-* commands found and config.env exists:** Report PASS with "Commands delivered by plugin — no migration needed."
**If local commands were removed:** Report WARN with "Migrated: removed N local command(s) that were shadowing plugin commands. Plugin commands will take effect on next Claude Code restart."
**If config.env missing:** Report FAIL with "config.env not found — plugin commands need it. Re-run setup or restore from backup."
**If new CLAUDE.md sections were added:** Report WARN with summary of what was added.

---

### Check 7: Security Audit

Run the server-side security audit script to check credentials, permissions, and exposed services.

**Steps:**

1. Check if the audit script exists on the server:
```bash
ssh -o ConnectTimeout=5 "$SERVER_HOST" 'test -x $HOME/.local/bin/audit.sh && echo "INSTALLED" || echo "NOT_INSTALLED"' 2>/dev/null
```

2. **If installed**, run it:
```bash
ssh -o ConnectTimeout=5 "$SERVER_HOST" '$HOME/.local/bin/audit.sh' 2>/dev/null
```

3. Present the output to the user. The script is designed to never output raw secret values — only metadata (variable names, char counts, file permissions, timestamps). It is safe to display the full output.

4. After showing the report, highlight any `[WARN]` findings and summarize them.

**If not installed:** Report WARN with: "Security audit script not found on the server. Re-run setup.sh to deploy it, or update the plugin and run /doctor again."

**If the script runs and finds no warnings:** Report PASS.

**If the script finds warnings (permission issues, unexpected files, etc.):** Report WARN with a summary of findings.

**If SSH connection fails:** Report FAIL with "Could not connect to server."

---

## Check 8: Credential Isolation (nono)

This check verifies if nono is set up, and if not, strongly recommends it. Always run this check regardless of whether credentials are currently configured.

1. **Check if nono is set up on the server:**
   - nono binary installed: `ssh "$SSH_TARGET" 'command -v nono'`
   - Profile deployed: `ssh "$SSH_TARGET" 'test -f ~/.config/nono/profiles/taskyou-agent.toml'`
   - Wrapper scripts exist: `ssh "$SSH_TARGET" 'test -x ~/bin/claude'`

2. **If nono IS set up**, verify health:
   - Check nono version: `ssh "$SSH_TARGET" 'nono --version'`
   - Verify profile exists
   - Verify at least one wrapper script exists in `~/bin/`
   - Check kernel supports Landlock: `ssh "$SSH_TARGET" 'uname -r'` (needs >= 5.13)
   - Report PASS with nono version and number of wrapped executors

3. **If nono is NOT set up**, strongly recommend it:
   - Report WARN
   - Explain clearly:
     ```
     ⚠ nono credential isolation is not configured.

     nono is strongly recommended for all TaskYou deployments. It provides
     kernel-enforced sandboxing so agents can USE credentials via a secure
     proxy but can never SEE or extract the raw keys — even if compromised
     via prompt injection.

     To enable:
     1. Add these to your config.env:
        NONO_ENABLED="true"
        NONO_CREDENTIALS="linear:LINEAR_API_KEY,github:GITHUB_TOKEN"
        NONO_PROXY_HOSTS="api.linear.app,api.github.com"
     2. Re-run: ./setup.sh server <your-project-dir>

     Learn more: https://github.com/always-further/nono
     ```
   - Ask: "Would you like me to help you configure nono now?"
   - If yes:
     - Read the user's config.env
     - Detect which credential variables are set (LINEAR_API_KEY, GITHUB_TOKEN, etc.)
     - Propose the appropriate NONO_CREDENTIALS and NONO_PROXY_HOSTS values
     - Ask for confirmation before modifying config.env
     - If confirmed, add the nono variables to config.env
     - Tell the user to re-run `./setup.sh server` to apply

**Important:** Never print or display actual credential values. Only check for their existence.

---

## Summary

After all checks, present a summary table:

```
TaskYou-OS Doctor
─────────────────────────────────
  Plugin version        PASS/WARN/FAIL
  TaskYou binary        PASS/WARN/FAIL
  Daemon running        PASS/WARN/FAIL
  Daemon mode           PASS/WARN/FAIL
  Executor health       PASS/WARN/FAIL
  GM templates          PASS/WARN/FAIL
  Security audit        PASS/WARN/FAIL
  Credential isolation  PASS/WARN
─────────────────────────────────
```

If you fixed anything, note what you did below the table.
If any issues remain that you couldn't fix, list the specific commands the user should run.
If everything passes, just say: "All systems healthy."
