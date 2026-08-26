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

### Check 7: Task Event Channel

Check that the Claude Code channel for push-based task notifications is set up and working.

**Steps:**

1. Check if the channel files exist in the GM directory:
```bash
test -f "$LOCAL_PROJECT_DIR/channel/taskyou-channel.ts" && echo "CHANNEL_EXISTS" || echo "CHANNEL_MISSING"
test -f "$LOCAL_PROJECT_DIR/.mcp.json" && echo "MCP_JSON_EXISTS" || echo "MCP_JSON_MISSING"
test -d "$LOCAL_PROJECT_DIR/channel/node_modules" && echo "DEPS_INSTALLED" || echo "DEPS_MISSING"
```

2. **If channel files are missing**, deploy them from the plugin templates:

   a. Find the TaskYou-OS plugin directory (or repo checkout):
   ```bash
   TASKYOU_OS_DIR=""
   if [ -f "./templates/channel/taskyou-channel.ts.tmpl" ]; then
     TASKYOU_OS_DIR="."
   else
     PLUGIN_DIR=$(python3 -c "import json; d=json.load(open('$HOME/.claude/plugins/installed_plugins.json')); entries=d.get('plugins',{}).get('taskyou-os@taskyou-os',[]); print(entries[0]['installPath'] if entries else '')" 2>/dev/null)
     if [ -n "$PLUGIN_DIR" ] && [ -f "$PLUGIN_DIR/templates/channel/taskyou-channel.ts.tmpl" ]; then
       TASKYOU_OS_DIR="$PLUGIN_DIR"
     fi
   fi
   ```

   b. If templates are available, render and deploy them. Use `config.env` to substitute variables:
   ```bash
   source "$LOCAL_PROJECT_DIR/config.env"
   mkdir -p "$LOCAL_PROJECT_DIR/channel"
   ```
   - Read `$TASKYOU_OS_DIR/templates/channel/taskyou-channel.ts.tmpl`, substitute `{{SERVER_HOST}}` and `{{SERVER_HOME}}` with values from config.env, write to `$LOCAL_PROJECT_DIR/channel/taskyou-channel.ts`
   - Read `$TASKYOU_OS_DIR/templates/channel/package.json.tmpl`, write to `$LOCAL_PROJECT_DIR/channel/package.json`
   - Read `$TASKYOU_OS_DIR/templates/mcp.json.tmpl`, write to `$LOCAL_PROJECT_DIR/.mcp.json`

   c. Install dependencies:
   ```bash
   cd "$LOCAL_PROJECT_DIR/channel" && bun install --silent
   ```

   d. Report WARN: "Deployed task event channel. Restart Claude Code to activate."

3. **If channel files exist but deps are missing**, install them:
   ```bash
   cd "$LOCAL_PROJECT_DIR/channel" && bun install --silent
   ```
   Report WARN: "Installed missing channel dependencies."

4. **If channel exists, check for drift** — compare deployed channel against the plugin template. If the template is newer, update the deployed file and report WARN.

5. **Check the shell alias** includes `--dangerously-load-development-channels server:taskyou`. This is the one step that doesn't self-heal, so make it as close to one-click as possible:
   ```bash
   # Find which rc file defines the alias
   for rc in ~/.zshrc ~/.bashrc; do grep -q "alias $GM_ALIAS=" "$rc" 2>/dev/null && echo "$rc"; done
   ```
   - If the alias already includes the flag, report PASS.
   - If the alias exists but is missing the flag: build the corrected line (the existing alias body + ` --dangerously-load-development-channels server:taskyou` appended after `claude`), then **offer to update it in place** rather than making the user hand-edit:
     > "Your `$GM_ALIAS` alias needs the channel flag to receive push notifications. Want me to update it in `<rc file>`? (I'll back the file up first.)"

     On yes, replace just that alias line in the rc file (back up to `<rc>.bak` first), then tell the user to run `source <rc file>` and restart the GM for it to take effect. On no, show them the exact line to paste:
     ```
     alias <GM_ALIAS>='cd <LOCAL_PROJECT_DIR> && CLAUDE_CONFIG_DIR=<CONFIG_DIR> claude --dangerously-load-development-channels server:taskyou'
     ```
   - If no alias is found at all, show the full line above and point them at the README "Updating" section.

   Always end this step by reminding the user: **the channel only loads at launch, so restart the GM after any alias change.**

6. **Check the CLAUDE.md** has the channel-based monitoring section (not the old background-agent approach):
   ```bash
   grep -c "Task event channel" "$LOCAL_PROJECT_DIR/CLAUDE.md"
   grep -c "background monitoring agent" "$LOCAL_PROJECT_DIR/CLAUDE.md"
   ```
   - If it has "background monitoring agent" but not "Task event channel", the CLAUDE.md needs updating. Render the Task Tracking section from the template and show the user the diff, offering to update it.

7. **Runtime self-check** — confirm the channel actually boots and completes the MCP handshake (catches a broken render, a missing/corrupt dep, or a bad bun). The smoke test ships next to the channel:
   ```bash
   test -f "$LOCAL_PROJECT_DIR/channel/smoke-test.ts" && \
     ( cd "$LOCAL_PROJECT_DIR/channel" && timeout 30 bun run smoke-test.ts )
   ```
   - Exit 0 (ends with `PASSED`): report PASS "channel boots + handshakes."
   - Non-zero or `FAILED`: report WARN with the smoke-test output — the channel is registered but won't push events until fixed.
   - If `smoke-test.ts` is absent (GM predates this), copy it from `templates/channel/smoke-test.ts` in the plugin and re-run.

**If all channel files exist, deps installed, alias correct, and the smoke test passes:** Report PASS with "Task event channel active."
**If deployed or fixed anything:** Report WARN with summary.
**If templates not found:** Report FAIL with "Channel templates not found. Update the TaskYou-OS plugin first."

---

### Check 8: Security Audit

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

### Check 9: Claude Auth Health

The server's Claude Code login expires roughly every 30 days. When it lapses,
every agent task fails or stalls and the only symptom is that no work happens.
This check reports how long is left, proves the login actually works, and
installs the monitor that will catch the next expiry automatically.

**Do NOT use `claude auth status` (or `claude doctor`, or `claude mcp list`) as
the health check.** They read cached local config and never contact Anthropic.
On credentials that had been dead for 95 days, `claude auth status` still
returned, with exit 0:

```json
{"loggedIn": true, "authMethod": "claude.ai", "subscriptionType": "max"}
```

**Steps:**

1. **Report days remaining** — free, offline. The access token lasts ~8h and
   self-refreshes; the refresh token is the real clock (~30 days, sliding):
```bash
ssh -o ConnectTimeout=5 "$SERVER_HOST" 'python3 -c "
import json, time, os
p = os.path.expanduser(\"~/.claude/.credentials.json\")
try:
    d = json.load(open(p))
except Exception:
    print(\"NO_CREDENTIALS_FILE\"); raise SystemExit
o = d.get(\"claudeAiOauth\")
if not o:
    print(\"NO_OAUTH_BLOCK\"); raise SystemExit
e = o.get(\"refreshTokenExpiresAt\")
if e is None:
    print(\"PRE_2_1_X_FORMAT_DEAD\"); raise SystemExit
print(\"DAYS_LEFT=%d\" % int((e/1000 - time.time()) // 86400))
"' 2>/dev/null
```
   - `DAYS_LEFT=N` — report it.
   - `NO_OAUTH_BLOCK` / `NO_CREDENTIALS_FILE` is **not** proof of failure — the
     credential may live in an OS keyring or be a long-lived setup-token. Just
     note that the expiry date is unknown and let the probe in step 2 decide.
   - `PRE_2_1_X_FORMAT_DEAD` means the credential predates Claude Code 2.1.x,
     has no sliding refresh token, and is certainly dead.

2. **Run the live probe** — the only truthful check. About 40 tokens, a few
   seconds. Run it exactly once:
```bash
ssh -o ConnectTimeout=15 "$SERVER_HOST" 'export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH" && claude -p "hi" --model haiku --max-turns 1 </dev/null >/dev/null 2>&1 && echo AUTH_OK || echo AUTH_FAILED' 2>/dev/null
```

3. **Rectify existing installs.** GMs provisioned before the monitor existed have
   no expiry detection at all. Check whether it's there:
```bash
ssh -o ConnectTimeout=5 "$SERVER_HOST" 'test -x $HOME/.local/bin/claude-auth-monitor.sh && echo MONITOR_INSTALLED || echo MONITOR_MISSING; crontab -l 2>/dev/null | grep -q claude-auth-monitor.sh && echo CRON_INSTALLED || echo CRON_MISSING' 2>/dev/null
```

   **If either is missing, install it — do not just report it.**

   a. Locate the template (repo checkout first, then the installed plugin):
   ```bash
   TASKYOU_OS_DIR=""
   if [ -f "./templates/claude-auth-monitor.tmpl" ]; then
     TASKYOU_OS_DIR="."
   else
     PLUGIN_DIR=$(python3 -c "import json; d=json.load(open('$HOME/.claude/plugins/installed_plugins.json')); entries=d.get('plugins',{}).get('taskyou-os@taskyou-os',[]); print(entries[0]['installPath'] if entries else '')" 2>/dev/null)
     if [ -n "$PLUGIN_DIR" ] && [ -f "$PLUGIN_DIR/templates/claude-auth-monitor.tmpl" ]; then
       TASKYOU_OS_DIR="$PLUGIN_DIR"
     fi
   fi
   ```

   b. Read `$TASKYOU_OS_DIR/templates/claude-auth-monitor.tmpl`, substitute
      `{{SERVER_HOME}}` and `{{PROJECT_NAME}}` with the values from `config.env`,
      write it to a temp file, then deploy:
   ```bash
   scp -q /tmp/claude-auth-monitor.rendered "$SERVER_HOST:$SERVER_HOME/.local/bin/claude-auth-monitor.sh"
   ssh "$SERVER_HOST" "mkdir -p $SERVER_HOME/scripts && chmod +x $SERVER_HOME/.local/bin/claude-auth-monitor.sh"
   rm -f /tmp/claude-auth-monitor.rendered
   ```

   c. Install the cron entry (every 30 minutes). **Every path it writes — flag,
      state, log — must live under this user's own `$HOME`.** Several GMs can
      share one box; a log or flag in a shared `/tmp` owned by another user is
      exactly how a daemon start got broken in production. Never point this at
      `/tmp`:
   ```bash
   CRON_LINE="*/30 * * * * export PATH=$SERVER_HOME/.local/bin:$SERVER_HOME/bin:$SERVER_HOME/.npm-global/bin:\$PATH && $SERVER_HOME/.local/bin/claude-auth-monitor.sh >> $SERVER_HOME/scripts/claude-auth-monitor.log 2>&1"
   ssh "$SERVER_HOST" "crontab -l 2>/dev/null | grep -q claude-auth-monitor.sh || (crontab -l 2>/dev/null; echo '$CRON_LINE') | crontab -"
   ```

   d. Confirm the cron entry landed:
   ```bash
   ssh "$SERVER_HOST" 'crontab -l 2>/dev/null | grep claude-auth-monitor.sh'
   ```

4. **Clear a stale failure flag.** If `~/scripts/.auth-failed` exists but the
   probe in step 2 returned `AUTH_OK`, the login was fixed but the flag was never
   cleared — `linear-poll.mjs` is still creating tasks without executing them:
```bash
ssh "$SERVER_HOST" 'test -f $HOME/scripts/.auth-failed && rm -f $HOME/scripts/.auth-failed && echo CLEARED_STALE_FLAG'
```
   (The monitor clears this itself on its next healthy run; doing it here means
   the operator isn't blocked for up to 30 minutes.)

**Results:**

- **Probe `AUTH_OK`, monitor + cron present, more than 5 days left:** PASS —
  "Claude auth healthy, N days left; monitor checks every 30 min."
- **Probe `AUTH_OK` but 5 days or fewer remain:** WARN — tell the user to run
  `ssh <SERVER_HOST>` then `claude /login` before it lapses.
- **Monitor or cron was missing and you installed it:** WARN — "Installed the
  Claude auth monitor and its cron entry. This install had no expiry detection
  at all before now."
- **Stale `.auth-failed` cleared:** WARN — "Cleared a stale auth-failure flag
  that was stopping the Linear poller from executing tasks."
- **Probe `AUTH_FAILED`:** FAIL — the agents cannot run. Give the user the fix
  verbatim:
  ```
  ssh <SERVER_HOST>
  claude /login
  ```
  You may mention `claude setup-token`, which issues a 1-year token, as an option
  for boxes that don't need claude.ai MCP connectors or Remote Control — it
  disables both, so it is not a universal fix and must not be the default.
- **SSH connection fails:** FAIL with "Could not connect to server."

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
  Task event channel    PASS/WARN/FAIL
  Security audit        PASS/WARN/FAIL
  Claude auth health    PASS/WARN/FAIL
─────────────────────────────────
```

If you fixed anything, note what you did below the table.
If any issues remain that you couldn't fix, list the specific commands the user should run.
If everything passes, just say: "All systems healthy."
