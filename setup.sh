#!/usr/bin/env bash
set -euo pipefail

# TaskYouOS Setup Script
# Usage: ./setup.sh <mode> <project-dir>
#   mode: local | server | all
#   project-dir: path containing config.env

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/templates"
MODULES_DIR="$SCRIPT_DIR/modules"

# ── Helpers ──────────────────────────────────────────────────────────────────

usage() {
  echo "Usage: $0 <mode> <project-dir>"
  echo ""
  echo "Modes:"
  echo "  local   — Generate local GM files only"
  echo "  server  — Provision the remote server only"
  echo "  exe     — Deploy GM to an exe.dev VM"
  echo "  all     — Both local and server"
  echo "  slack   — Guided Slack setup wizard for an existing GM"
  echo ""
  echo "The project-dir must contain a config.env file."
  echo "See config.example.env for all available variables."
  exit 1
}

log() { echo "==> $1"; }
warn() { echo "  ! $1"; }
ok() { echo "  ✓ $1"; }

# Render a template file → output file using Python for reliable processing
# Handles {{VARIABLE}} substitution and {{#FEATURE}}...{{/FEATURE}} conditionals
render_file() {
  local template="$1"
  local output="$2"

  mkdir -p "$(dirname "$output")"

  python3 - "$template" "$output" <<'PYEOF'
import sys, os, re

template_path = sys.argv[1]
output_path = sys.argv[2]

with open(template_path, 'r') as f:
    content = f.read()

# Collect all env vars
env = dict(os.environ)

# Process conditional blocks: {{#FEATURE}}...{{/FEATURE}}
# Nested blocks are handled by processing innermost first
changed = True
while changed:
    changed = False
    for m in re.finditer(r'\{\{#([A-Z0-9_]+)\}\}', content):
        feature = m.group(1)
        open_tag = '{{#' + feature + '}}'
        close_tag = '{{/' + feature + '}}'

        open_pos = content.find(open_tag)
        close_pos = content.find(close_tag, open_pos)
        if open_pos == -1 or close_pos == -1:
            continue

        # Check for nested opens between this open and close
        inner = content[open_pos + len(open_tag):close_pos]
        if '{{#' + feature + '}}' in inner:
            # There's a nested block of the same type - skip, process inner first
            continue

        enabled_var = feature + '_ENABLED'
        enabled = env.get(enabled_var, '')
        if not enabled:
            enabled = env.get(feature, '')

        block_content = content[open_pos + len(open_tag):close_pos]

        if enabled == 'true' or (enabled and enabled != 'false'):
            # Keep content, remove markers (and their surrounding newlines)
            before = content[:open_pos]
            after = content[close_pos + len(close_tag):]
            # Strip the newline after open tag and before close tag
            if block_content.startswith('\n'):
                block_content = block_content[1:]
            if after.startswith('\n'):
                after = after[1:]
            if before.endswith('\n'):
                before = before[:-1]
                block_content = '\n' + block_content
            content = before + block_content + after
        else:
            # Remove entire block
            before = content[:open_pos]
            after = content[close_pos + len(close_tag):]
            # Clean up surrounding blank lines
            if before.endswith('\n') and after.startswith('\n'):
                after = after[1:]
            content = before + after

        changed = True
        break  # Restart after each replacement

# Replace {{VARIABLE}} placeholders
def replace_var(m):
    var = m.group(1)
    return env.get(var, '')

content = re.sub(r'\{\{([A-Z0-9_]+)\}\}', replace_var, content)

with open(output_path, 'w') as f:
    f.write(content)
PYEOF
}

# Render a template string (for inline use, not file-based)
render() {
  local content="$1"
  echo "$content" | python3 -c "
import sys, os, re
content = sys.stdin.read()
def replace_var(m):
    return os.environ.get(m.group(1), '')
print(re.sub(r'\{\{([A-Z0-9_]+)\}\}', replace_var, content), end='')
"
}

# Generate the projects table for CLAUDE.md
generate_projects_table() {
  local table="| Project      | Purpose                                              |
|-------------|------------------------------------------------------|"

  IFS=',' read -ra projs <<< "$PROJECTS"
  for p in "${projs[@]}"; do
    p=$(echo "$p" | xargs)  # trim whitespace
    table+=$'\n'"| $p | |"
  done
  echo "$table"
}

# Generate the GitHub repos table for CLAUDE.md
generate_github_repos_table() {
  local table="| Project     | Repo                          |
|------------|-------------------------------|"

  if [[ -n "${GITHUB_REPOS:-}" ]]; then
    IFS=',' read -ra mappings <<< "$GITHUB_REPOS"
    for mapping in "${mappings[@]}"; do
      local proj="${mapping%%:*}"
      local repo="${mapping#*:}"
      table+=$'\n'"| $proj | \`$repo\` |"
    done
  fi
  echo "$table"
}

# Run a command on the server via SSH
remote() {
  ssh -o ConnectTimeout=10 "$SERVER_HOST" "$@"
}

# Run a command on the server with PATH set
remote_with_path() {
  remote "export PATH=$SERVER_HOME/bin:$SERVER_HOME/.npm-global/bin:$SERVER_HOME/.local/bin:/home/deploy/.asdf/installs/nodejs/24.13.0/bin:\$PATH && $*"
}

# Resolve the TaskYou hooks directory for a host's OS.
# ty's hooks.DefaultHooksDir() follows Go's os.UserConfigDir():
#   Linux  -> $HOME/.config/task/hooks
#   macOS  -> $HOME/Library/Application Support/task/hooks
# $1 = a command runner (e.g. "remote" or "exe_remote") that runs a shell
#      command on the target host; $2 = that host's home directory.
# Echoes the absolute hooks dir. Falls back to ~/.config on unknown OSes.
resolve_hooks_dir() {
  local runner="$1"
  local home_dir="$2"
  local os_name
  os_name=$("$runner" "uname -s" 2>/dev/null | tr -d '\r' | xargs || echo "")
  if [[ "$os_name" == "Darwin" ]]; then
    echo "$home_dir/Library/Application Support/task/hooks"
  else
    echo "$home_dir/.config/task/hooks"
  fi
}

# ── Parse args ───────────────────────────────────────────────────────────────

if [[ $# -lt 2 ]]; then
  usage
fi

MODE="$1"
PROJECT_DIR="$(cd "$2" && pwd 2>/dev/null || echo "$2")"
CONFIG_FILE="$PROJECT_DIR/config.env"

if [[ "$MODE" != "local" && "$MODE" != "server" && "$MODE" != "exe" && "$MODE" != "all" && "$MODE" != "slack" ]]; then
  echo "Error: mode must be local, server, exe, all, or slack"
  usage
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Error: $CONFIG_FILE not found"
  echo "Copy config.example.env to $PROJECT_DIR/config.env and fill in the values."
  exit 1
fi

# ── Load config ──────────────────────────────────────────────────────────────

# shellcheck disable=SC1090
source "$CONFIG_FILE"

# Validate required vars
REQUIRED_VARS="PROJECT_NAME PROJECT_DISPLAY_NAME GM_ALIAS PROJECTS GIT_NAME GIT_EMAIL"
if [[ "$MODE" == "exe" ]]; then
  REQUIRED_VARS="$REQUIRED_VARS EXE_DEV_VM_NAME"
else
  REQUIRED_VARS="$REQUIRED_VARS SERVER_HOST SERVER_USER SERVER_HOME LOCAL_PROJECT_DIR CLAUDE_CONFIG_DIR"
fi
for var in $REQUIRED_VARS; do
  if [[ -z "${!var:-}" ]]; then
    echo "Error: $var is required in config.env"
    exit 1
  fi
done

# Derived variables
PROJECT_NAME_UPPER=$(echo "$PROJECT_NAME" | tr '[:lower:]' '[:upper:]')
export PROJECT_NAME PROJECT_DISPLAY_NAME GM_ALIAS GIT_NAME GIT_EMAIL PROJECTS
export SERVER_HOST="${SERVER_HOST:-}" SERVER_USER="${SERVER_USER:-}" SERVER_HOME="${SERVER_HOME:-}"
# Local-vs-remote flags for template conditionals ({{#SERVER_IS_LOCAL}} …).
# Inlined (not the is_local_server function, which is defined later in the file).
if [[ "$SERVER_HOST" == "local" || "$SERVER_HOST" == "localhost" || -z "$SERVER_HOST" ]]; then
  export SERVER_IS_LOCAL="true" SERVER_IS_REMOTE="false"
else
  export SERVER_IS_LOCAL="false" SERVER_IS_REMOTE="true"
fi
export LOCAL_PROJECT_DIR="${LOCAL_PROJECT_DIR:-}" CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-}"
export PROJECT_NAME_UPPER
export PROJECT_DESCRIPTION="${PROJECT_DESCRIPTION:-}"
export OWNER_NAME="${OWNER_NAME:-the owner}"
export LINEAR_ENABLED="${LINEAR_ENABLED:-false}"
export LINEAR_API_KEY="${LINEAR_API_KEY:-}"
export LINEAR_TEAM_ID="${LINEAR_TEAM_ID:-}"
export LINEAR_TEAM_KEY="${LINEAR_TEAM_KEY:-}"
export LINEAR_LABEL_ID="${LINEAR_LABEL_ID:-}"
export LINEAR_STATE_ID="${LINEAR_STATE_ID:-}"
export LINEAR_WORKSPACE_URL="${LINEAR_WORKSPACE_URL:-}"
export R2_ENABLED="${R2_ENABLED:-false}"
export R2_BUCKET="${R2_BUCKET:-}"
export R2_PUBLIC_URL="${R2_PUBLIC_URL:-}"
export GITHUB_REPOS="${GITHUB_REPOS:-}"
export EXE_DEV_ENABLED="${EXE_DEV_ENABLED:-false}"
export EXE_DEV_VM_NAME="${EXE_DEV_VM_NAME:-}"
export SLACK_ENABLED="${SLACK_ENABLED:-false}"
export SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-}"
export SLACK_APP_TOKEN="${SLACK_APP_TOKEN:-}"
export SLACK_NOTIFY_CHANNEL="${SLACK_NOTIFY_CHANNEL:-}"
export SLACK_ALLOWED_USERS="${SLACK_ALLOWED_USERS:-}"
export SLACK_PROJECT_MAP="${SLACK_PROJECT_MAP:-}"
export SLACK_ANTHROPIC_API_KEY="${SLACK_ANTHROPIC_API_KEY:-}"
export SLACK_CLASSIFIER_MODEL="${SLACK_CLASSIFIER_MODEL:-claude-haiku-4-5-20251001}"

# Generate dynamic table content
export PROJECTS_TABLE
PROJECTS_TABLE=$(generate_projects_table)
export GITHUB_REPOS_TABLE
GITHUB_REPOS_TABLE=$(generate_github_repos_table)

log "TaskYouOS setup for $PROJECT_DISPLAY_NAME"
echo "  Mode: $MODE"
echo "  Project dir: $LOCAL_PROJECT_DIR"
echo "  Server: $SERVER_HOST"
echo ""

# ── Local setup ──────────────────────────────────────────────────────────────

setup_local() {
  log "Setting up local GM directory: $LOCAL_PROJECT_DIR"

  mkdir -p "$LOCAL_PROJECT_DIR"/{bin,log,.claude}

  # CLAUDE.md
  log "Generating CLAUDE.md"
  render_file "$TEMPLATES_DIR/CLAUDE.md.tmpl" "$LOCAL_PROJECT_DIR/CLAUDE.md"
  ok "CLAUDE.md"

  # .claude/settings.json
  log "Generating Claude settings"
  render_file "$TEMPLATES_DIR/settings.json.tmpl" "$LOCAL_PROJECT_DIR/.claude/settings.json"
  ok ".claude/settings.json"

  # bin/ scripts
  log "Generating bin/ scripts"

  render_file "$TEMPLATES_DIR/ty-remote.tmpl" "$LOCAL_PROJECT_DIR/bin/ty-remote"
  chmod +x "$LOCAL_PROJECT_DIR/bin/ty-remote"
  ok "bin/ty-remote"

  render_file "$TEMPLATES_DIR/ssh-remote.tmpl" "$LOCAL_PROJECT_DIR/bin/ssh-remote"
  chmod +x "$LOCAL_PROJECT_DIR/bin/ssh-remote"
  ok "bin/ssh-remote"

  render_file "$TEMPLATES_DIR/gm-action.tmpl" "$LOCAL_PROJECT_DIR/bin/${PROJECT_NAME}-action"
  chmod +x "$LOCAL_PROJECT_DIR/bin/${PROJECT_NAME}-action"
  ok "bin/${PROJECT_NAME}-action"

  render_file "$TEMPLATES_DIR/retry-task.tmpl" "$LOCAL_PROJECT_DIR/bin/${PROJECT_NAME}-retry-task"
  chmod +x "$LOCAL_PROJECT_DIR/bin/${PROJECT_NAME}-retry-task"
  ok "bin/${PROJECT_NAME}-retry-task"

  render_file "$TEMPLATES_DIR/open-board.tmpl" "$LOCAL_PROJECT_DIR/bin/${PROJECT_NAME}-open-board"
  chmod +x "$LOCAL_PROJECT_DIR/bin/${PROJECT_NAME}-open-board"
  ok "bin/${PROJECT_NAME}-open-board"

  # Channel (push-based task event notifications)
  log "Setting up task event channel"
  mkdir -p "$LOCAL_PROJECT_DIR/channel"
  render_file "$TEMPLATES_DIR/channel/taskyou-channel.ts.tmpl" "$LOCAL_PROJECT_DIR/channel/taskyou-channel.ts"
  ok "channel/taskyou-channel.ts"
  render_file "$TEMPLATES_DIR/channel/package.json.tmpl" "$LOCAL_PROJECT_DIR/channel/package.json"
  ok "channel/package.json"
  # Ship the smoke test alongside the channel so /gm-doctor can self-check it
  cp "$TEMPLATES_DIR/channel/smoke-test.ts" "$LOCAL_PROJECT_DIR/channel/smoke-test.ts"
  ok "channel/smoke-test.ts"
  # Install channel dependencies
  (cd "$LOCAL_PROJECT_DIR/channel" && bun install --silent 2>/dev/null) || warn "bun install failed — run 'cd $LOCAL_PROJECT_DIR/channel && bun install' manually"

  # .mcp.json (registers channel with Claude Code)
  render_file "$TEMPLATES_DIR/mcp.json.tmpl" "$LOCAL_PROJECT_DIR/.mcp.json"
  ok ".mcp.json"

  # R2 wrangler.toml
  if [[ "$R2_ENABLED" == "true" ]]; then
    log "Setting up R2"
    mkdir -p "$LOCAL_PROJECT_DIR/tmp"
    render_file "$MODULES_DIR/r2/wrangler.toml.tmpl" "$LOCAL_PROJECT_DIR/tmp/wrangler.toml"
    ok "tmp/wrangler.toml"
  fi

  # Shell alias
  log "Shell alias"
  local alias_line="alias ${GM_ALIAS}='cd ${LOCAL_PROJECT_DIR} && CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR} claude --dangerously-load-development-channels server:taskyou'"
  echo "  Add this to your shell profile (~/.zshrc or ~/.bashrc):"
  echo ""
  echo "    $alias_line"
  echo ""

  # git init if not already a repo
  if [[ ! -d "$LOCAL_PROJECT_DIR/.git" ]]; then
    (cd "$LOCAL_PROJECT_DIR" && git init -q)
    ok "git init"
  fi

  log "Local setup complete"
  echo ""

}

# ── PATH setup ───────────────────────────────────────────────────────────────

# Ensure ~/bin and ~/.local/bin are in PATH for ty and other user tools.
# tmux/daemon sessions may not source the full login profile.
setup_path() {
  local ssh_target="$1"
  local remote_home="$2"

  log "Ensuring ~/bin and ~/.local/bin are in PATH"
  ssh "$ssh_target" "mkdir -p $remote_home/bin $remote_home/.local/bin"
  if ! ssh "$ssh_target" "grep -q 'export PATH=\$HOME/bin:\$HOME/.local/bin:\$PATH' $remote_home/.bashrc" 2>/dev/null; then
    # Remove any older partial PATH line we may have added before
    ssh "$ssh_target" "sed -i '/^export PATH=\\\$HOME\/bin:\\\$PATH$/d' $remote_home/.bashrc" 2>/dev/null || true
    ssh "$ssh_target" "echo 'export PATH=\$HOME/bin:\$HOME/.local/bin:\$PATH' >> $remote_home/.bashrc"
    ok "PATH: ~/bin and ~/.local/bin prepended in .bashrc"
  else
    ok "PATH: ~/bin and ~/.local/bin already in .bashrc"
  fi
}

# ── Slack module ──────────────────────────────────────────────────────────────

# Install the Slack bridge on a remote host as the ty-slack systemd user
# service. Long-running (Socket Mode holds a WebSocket), so unlike the Linear
# poller it's a service, not a cron job. $1 = ssh target, $2 = remote home.
setup_slack_remote() {
  local ssh_target="$1"
  local remote_home="$2"

  log "Setting up Slack integration"

  local scripts_dir="$remote_home/scripts/slack"
  ssh "$ssh_target" "mkdir -p $scripts_dir $remote_home/log $remote_home/.config/systemd/user"
  scp -q "$MODULES_DIR/slack/slack-bridge.mjs" "$ssh_target:$scripts_dir/slack-bridge.mjs"
  ssh "$ssh_target" "chmod +x $scripts_dir/slack-bridge.mjs"

  # .env (chmod 600 — holds bot/app tokens). Written via stdin to keep tokens
  # out of the process list.
  local project_map_json="$SLACK_PROJECT_MAP"
  [[ -z "$project_map_json" ]] && project_map_json="{}"
  local default_project
  default_project=$(echo "$PROJECTS" | cut -d',' -f1 | xargs)
  ssh "$ssh_target" "cat > $scripts_dir/.env && chmod 600 $scripts_dir/.env" <<EOF
SLACK_BOT_TOKEN=$SLACK_BOT_TOKEN
SLACK_APP_TOKEN=$SLACK_APP_TOKEN
SLACK_NOTIFY_CHANNEL=$SLACK_NOTIFY_CHANNEL
SLACK_ALLOWED_USERS=$SLACK_ALLOWED_USERS
SLACK_PROJECT_MAP=$project_map_json
DEFAULT_PROJECT=$default_project
TY_PATH=$remote_home/.local/bin/ty
NOTIFICATIONS_FILE=$remote_home/notifications.jsonl
ANTHROPIC_API_KEY=$SLACK_ANTHROPIC_API_KEY
ANTHROPIC_MODEL=$SLACK_CLASSIFIER_MODEL
EOF
  ok "slack-bridge installed"

  # Resolve node on the target (login shell picks up asdf/nvm shims) and bake
  # the absolute path into the service so systemd's minimal PATH still finds it.
  local node_bin
  node_bin=$(ssh "$ssh_target" "bash -lc 'command -v node'" 2>/dev/null | tr -d '\r' | tail -1)
  if [[ -z "$node_bin" ]]; then
    warn "node not found on $ssh_target — install Node 22+ so the bridge can run"
    node_bin="node"
  fi
  export NODE_BIN="$node_bin"

  render_file "$TEMPLATES_DIR/ty-slack.service.tmpl" "/tmp/ty-slack.service"
  scp -q "/tmp/ty-slack.service" "$ssh_target:$remote_home/.config/systemd/user/ty-slack.service"
  rm -f "/tmp/ty-slack.service"

  ssh "$ssh_target" "systemctl --user daemon-reload && systemctl --user enable ty-slack && systemctl --user restart ty-slack" 2>/dev/null \
    || warn "could not enable ty-slack service (needs lingering — see ty-daemon setup)"
  sleep 2
  if ssh "$ssh_target" "systemctl --user is-active ty-slack" 2>/dev/null | grep -q "active"; then
    ok "ty-slack running (systemd user service)"
    ok "Logs: $remote_home/log/ty-slack.log"
  else
    warn "ty-slack may not have started. Debug: ssh $ssh_target 'systemctl --user status ty-slack'"
  fi
}

# Install the Slack bridge when the daemon is on THIS machine (local/macOS):
# render the script + .env; no systemd (operator starts it or adds a launchd
# agent). $1 = home dir.
setup_slack_local() {
  local home_dir="$1"

  log "Setting up Slack integration (local)"
  local slack_dir="$home_dir/scripts/slack"
  mkdir -p "$slack_dir"
  cp "$MODULES_DIR/slack/slack-bridge.mjs" "$slack_dir/slack-bridge.mjs"
  chmod +x "$slack_dir/slack-bridge.mjs"

  local project_map_json="$SLACK_PROJECT_MAP"
  [[ -z "$project_map_json" ]] && project_map_json="{}"
  local default_project
  default_project=$(echo "$PROJECTS" | cut -d',' -f1 | xargs)
  cat > "$slack_dir/.env" <<EOF
SLACK_BOT_TOKEN=$SLACK_BOT_TOKEN
SLACK_APP_TOKEN=$SLACK_APP_TOKEN
SLACK_NOTIFY_CHANNEL=$SLACK_NOTIFY_CHANNEL
SLACK_ALLOWED_USERS=$SLACK_ALLOWED_USERS
SLACK_PROJECT_MAP=$project_map_json
DEFAULT_PROJECT=$default_project
TY_PATH=$(command -v ty)
NOTIFICATIONS_FILE=$home_dir/notifications.jsonl
ANTHROPIC_API_KEY=$SLACK_ANTHROPIC_API_KEY
ANTHROPIC_MODEL=$SLACK_CLASSIFIER_MODEL
EOF
  chmod 600 "$slack_dir/.env"
  ok "slack-bridge installed: $slack_dir"
  warn "Local mode: start it with 'node $slack_dir/slack-bridge.mjs' (or a launchd agent)."
}

# ── Slack setup wizard (./setup.sh slack <project-dir>) ───────────────────────

# Prompt for a value. Default shown is the current value (from config on a
# re-run) so pressing enter keeps it and typing a new value updates it. A
# WIZ_<VAR> env var pre-answers non-interactively (for tests/scripts) without
# colliding with the sourced config; a closed stdin keeps the current/default.
ask() {
  local __var="$1" __prompt="$2"
  local __override="WIZ_${__var}"
  if [[ -n "${!__override:-}" ]]; then printf -v "$__var" '%s' "${!__override}"; return; fi
  local __default="${!__var:-${3:-}}" __val
  if [[ -t 0 ]]; then
    read -r -p "  $__prompt${__default:+ [$__default]}: " __val || true
    printf -v "$__var" '%s' "${__val:-$__default}"
  else
    printf -v "$__var" '%s' "$__default"
  fi
}

# Resolve a Slack email → user id via the bot token; pass through a bare U… id.
resolve_slack_user() {
  local token="$1" who="$2"
  [[ -z "$who" ]] && { echo ""; return; }
  if [[ "$who" != *@* ]]; then echo "$who"; return; fi
  local resp
  resp=$(curl -sS -G --data-urlencode "email=$who" \
    -H "Authorization: Bearer $token" \
    "https://slack.com/api/users.lookupByEmail" 2>/dev/null || true)
  echo "$resp" | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); print(d.get("user",{}).get("id","") if d.get("ok") else "")
except Exception:
  print("")' 2>/dev/null || echo ""
}

# Rewrite the SLACK_* block in the GM's config.env (idempotent).
write_slack_config() {
  local tmp="$CONFIG_FILE.slacktmp"
  # Strip any prior managed block (vars + our comment marker) so re-runs replace
  # rather than accumulate.
  grep -vE '^(export )?SLACK_(ENABLED|BOT_TOKEN|APP_TOKEN|NOTIFY_CHANNEL|ALLOWED_USERS|PROJECT_MAP)=|^# === Slack integration \(managed by' "$CONFIG_FILE" > "$tmp" || true
  {
    echo ""
    echo "# === Slack integration (managed by 'setup.sh slack') ==="
    echo "SLACK_ENABLED=\"true\""
    echo "SLACK_BOT_TOKEN=\"$SLACK_BOT_TOKEN\""
    echo "SLACK_APP_TOKEN=\"$SLACK_APP_TOKEN\""
    echo "SLACK_NOTIFY_CHANNEL=\"$SLACK_NOTIFY_CHANNEL\""
    echo "SLACK_ALLOWED_USERS=\"$SLACK_ALLOWED_USERS\""
    echo "SLACK_PROJECT_MAP='$SLACK_PROJECT_MAP'"
  } >> "$tmp"
  mv "$tmp" "$CONFIG_FILE"
  ok "wrote Slack config to $CONFIG_FILE"
}

setup_slack_wizard() {
  echo ""
  log "Slack setup wizard for $PROJECT_DISPLAY_NAME"
  echo "  1. Create the app: https://api.slack.com/apps → Create New App →"
  echo "     From an app manifest → paste modules/slack/manifest.yaml → Create."
  echo "  2. Basic Information → App-Level Tokens → Generate (scope connections:write)"
  echo "     → copy the xapp-… token. Then OAuth & Permissions → Install to Workspace"
  echo "     → copy the Bot User OAuth Token xoxb-…."
  echo "  (Leave the app token blank for outbound-only — pings, no inbound control.)"
  echo ""

  ask SLACK_BOT_TOKEN "Bot User OAuth Token (xoxb-…)"
  ask SLACK_APP_TOKEN "App-Level Token (xapp-…, blank = outbound-only)"
  ask SLACK_NOTIFY_CHANNEL "Channel for task pings" "#taskyou"
  ask SLACK_OWNER "Your Slack email or member ID (to allow-list)"
  ask SLACK_PROJECT_MAP "Channel→project map JSON (optional)" "{}"

  if [[ -z "$SLACK_BOT_TOKEN" ]]; then
    echo "Error: a bot token is required."
    exit 1
  fi

  # Verify the bot token and resolve the allow-listed user.
  local auth
  auth=$(curl -sS -X POST -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    "https://slack.com/api/auth.test" 2>/dev/null || true)
  if echo "$auth" | grep -q '"ok":true'; then
    local team botname
    team=$(echo "$auth" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("team",""))' 2>/dev/null || echo "")
    botname=$(echo "$auth" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("user",""))' 2>/dev/null || echo "")
    ok "bot @$botname authenticated in ${team:-workspace}"
  else
    warn "couldn't verify the bot token (auth.test). Continuing — fix it in $CONFIG_FILE if Slack errors."
  fi

  SLACK_ALLOWED_USERS=$(resolve_slack_user "$SLACK_BOT_TOKEN" "$SLACK_OWNER")
  if [[ -z "$SLACK_ALLOWED_USERS" ]]; then
    warn "couldn't resolve '$SLACK_OWNER' to a Slack user id — set SLACK_ALLOWED_USERS in $CONFIG_FILE before anyone can drive ty."
  else
    ok "allow-listed: $SLACK_ALLOWED_USERS"
  fi

  write_slack_config
  export SLACK_ENABLED="true" SLACK_BOT_TOKEN SLACK_APP_TOKEN SLACK_NOTIFY_CHANNEL \
    SLACK_ALLOWED_USERS SLACK_PROJECT_MAP

  # Install on whichever target this GM uses.
  if is_local_server; then
    export SERVER_HOME="${SERVER_HOME:-$HOME}"
    setup_slack_local "$SERVER_HOME"
  elif [[ "$EXE_DEV_ENABLED" == "true" && -n "$EXE_DEV_VM_NAME" ]]; then
    setup_slack_remote "exedev@${EXE_DEV_VM_NAME}.exe.xyz" "/home/exedev"
  else
    setup_slack_remote "$SERVER_HOST" "$SERVER_HOME"
  fi

  echo ""
  ok "Slack wired up. Final step: invite the bot in Slack →  /invite @<botname>  in $SLACK_NOTIFY_CHANNEL"
  echo "  Then try:  @<botname> what's on the board?"
}

# ── Daemon systemd service ────────────────────────────────────────────────────

install_daemon_service() {
  local ssh_target="$1"
  local remote_home="$2"

  log "Installing TaskYou daemon service"

  # Stop any existing ad-hoc daemon process (from old nohup-based setup)
  ssh "$ssh_target" 'pkill -f "ty daemon" 2>/dev/null; sleep 1' || true

  # Create log directory
  ssh "$ssh_target" "mkdir -p $remote_home/log"

  # Deploy systemd user service
  ssh "$ssh_target" "mkdir -p $remote_home/.config/systemd/user"
  scp -q "$TEMPLATES_DIR/ty-daemon.service.tmpl" "$ssh_target:$remote_home/.config/systemd/user/ty-daemon.service"

  # Enable lingering so the service starts at boot without a login session
  ssh "$ssh_target" "sudo loginctl enable-linger \$(whoami) 2>/dev/null" || {
    warn "Could not enable linger — daemon won't auto-start on boot without a login session"
  }

  # Reload, enable, and start
  ssh "$ssh_target" "systemctl --user daemon-reload && systemctl --user enable ty-daemon"
  ssh "$ssh_target" "systemctl --user start ty-daemon"
  sleep 2

  if ssh "$ssh_target" "systemctl --user is-active ty-daemon" 2>/dev/null | grep -q "active"; then
    ok "Daemon running (systemd user service)"
    ok "Logs: $remote_home/log/ty-daemon.log"
  else
    warn "Daemon service may not have started. Debug with: ssh $ssh_target 'systemctl --user status ty-daemon'"
  fi
}

# Install the Claude auth expiry monitor + its cron entry.
# $1 = ssh target, $2 = that host's home directory.
#
# Claude Code logins on agent servers expire about every 30 days, and until this
# existed nothing noticed: tasks simply stopped working. `claude auth status`
# cannot be used as the check — it reads cached config and never contacts
# Anthropic, so it keeps reporting {"loggedIn": true, ...} with exit 0 on
# credentials that have been dead for months. The monitor does a free offline
# read of the refresh-token expiry and then one real ~40-token model request,
# which is the only truthful signal. See templates/claude-auth-monitor.tmpl.
install_auth_monitor() {
  local ssh_target="$1"
  local remote_home="$2"

  log "Installing Claude auth monitor"

  # Render against THIS host's home (exe and server modes pass different homes).
  local rendered="/tmp/taskyou-claude-auth-monitor.$$"
  ( export SERVER_HOME="$remote_home"
    render_file "$TEMPLATES_DIR/claude-auth-monitor.tmpl" "$rendered" )

  ssh "$ssh_target" "mkdir -p $remote_home/.local/bin $remote_home/scripts"
  scp -q "$rendered" "$ssh_target:$remote_home/.local/bin/claude-auth-monitor.sh"
  scp -q "$MODULES_DIR/common/rotate-log.sh" "$ssh_target:$remote_home/.local/bin/rotate-log.sh"
  ssh "$ssh_target" "chmod +x $remote_home/.local/bin/claude-auth-monitor.sh $remote_home/.local/bin/rotate-log.sh"
  rm -f "$rendered"
  ok "claude-auth-monitor.sh"

  # Cron every 30 minutes. Every path the script writes (flag, state, log) lives
  # under this user's own $HOME — several GMs can share one box, and a log or
  # flag in a shared /tmp owned by another user is exactly how a daemon start
  # got broken in production.
  # rotate-log.sh runs first: nothing else prunes these logs, and a monitor
  # stuck in an error loop is exactly how a box ended up with 487MB of them.
  local cron_line="*/30 * * * * export PATH=$remote_home/.local/bin:$remote_home/bin:$remote_home/.npm-global/bin:\$PATH; $remote_home/.local/bin/rotate-log.sh $remote_home/scripts/claude-auth-monitor.log; $remote_home/.local/bin/claude-auth-monitor.sh >> $remote_home/scripts/claude-auth-monitor.log 2>&1"
  if ssh "$ssh_target" "crontab -l 2>/dev/null" | grep -qF "$cron_line"; then
    ok "Auth monitor cron job already up to date"
  else
    ssh "$ssh_target" "(crontab -l 2>/dev/null | grep -v 'claude-auth-monitor.sh'; echo '$cron_line') | crontab -"
    ok "Auth monitor cron job installed (every 30 minutes)"
  fi
}

# ── Local-server setup (server = this machine) ───────────────────────────────

# True when the "server" is the same box the GM runs on (no SSH, no systemd).
# Detected from SERVER_HOST being local/localhost/empty — mirrors the channel's
# IS_LOCAL detection so a single config drives both.
is_local_server() {
  [[ "$SERVER_HOST" == "local" || "$SERVER_HOST" == "localhost" || -z "$SERVER_HOST" ]]
}

# Provision when the daemon runs on this same machine: install hooks + the
# notifications file locally, skipping SSH provisioning and the systemd service
# (the GM and daemon share the box). TaskYou itself is assumed already installed
# locally (this is the machine the GM launches from). Cross-platform hooks dir.
setup_server_local() {
  log "Setting up local server (this machine — no SSH, no systemd)"

  # Preflight: local mode assumes ty is installed and its daemon runs on THIS
  # box (we register projects + install hooks locally). Without these, setup
  # would "succeed" but no task events would ever fire — fail loudly instead.
  if ! command -v ty >/dev/null 2>&1; then
    echo "Error: 'ty' is not on PATH, but SERVER_HOST is local."
    echo "Install TaskYou first (the daemon must run on this machine), then re-run."
    exit 1
  fi
  if ty daemon status >/dev/null 2>&1 || pgrep -f 'ty daemon' >/dev/null 2>&1; then
    ok "ty daemon detected"
  else
    warn "ty daemon does not appear to be running on this machine."
    warn "Start it (e.g. 'ty daemon') so task hooks fire and the channel sees events."
  fi

  local home_dir="${SERVER_HOME:-$HOME}"
  # Ensure templates that reference {{SERVER_HOME}} (e.g. the hooks' notifications
  # path) render against the resolved local home even if SERVER_HOME was blank.
  export SERVER_HOME="$home_dir"

  # Git identity
  log "Configuring git identity"
  git config --global user.name "$GIT_NAME" && git config --global user.email "$GIT_EMAIL"
  ok "git: $GIT_NAME <$GIT_EMAIL>"

  # Create project repos and register them with TaskYou
  log "Creating project repositories"
  IFS=',' read -ra projs <<< "$PROJECTS"
  for proj in "${projs[@]}"; do
    proj=$(echo "$proj" | xargs)
    local repo_path="$home_dir/projects/$proj"
    if [[ -d "$repo_path/.git" ]]; then
      ok "$proj (already exists)"
    else
      mkdir -p "$repo_path" && (cd "$repo_path" && git init -q)
      ok "$proj"
    fi

    if ty projects show "$proj" >/dev/null 2>&1; then
      ok "  ty project $proj (already registered)"
    else
      ty projects create "$proj" --path "$repo_path"
      ok "  ty project $proj registered"
    fi
  done

  # Install TaskYou hooks (OS-detected dir; matches ty's os.UserConfigDir()).
  log "Installing TaskYou hooks"
  local hooks_dir
  if [[ "$(uname -s)" == "Darwin" ]]; then
    hooks_dir="$home_dir/Library/Application Support/task/hooks"
  else
    hooks_dir="$home_dir/.config/task/hooks"
  fi
  mkdir -p "$hooks_dir"
  ok "hooks dir: $hooks_dir"

  for hook_tmpl in "$TEMPLATES_DIR"/hooks/*.tmpl; do
    local hook_name
    hook_name=$(basename "$hook_tmpl" .tmpl)
    render_file "$hook_tmpl" "$hooks_dir/$hook_name"
    chmod +x "$hooks_dir/$hook_name"
    ok "hook: $hook_name"
  done

  # Notifications file
  touch "$home_dir/notifications.jsonl"
  ok "notifications.jsonl"

  # Slack module (local mode: render files + .env; no systemd on macOS, so the
  # operator starts it — directly or via a launchd agent).
  if [[ "$SLACK_ENABLED" == "true" ]]; then
    setup_slack_local "$home_dir"
  fi

  log "Local server setup complete (daemon assumed running on this machine)"
}

# ── Server setup ─────────────────────────────────────────────────────────────

setup_server() {
  # Local-server mode: skip all SSH/systemd provisioning.
  if is_local_server; then
    setup_server_local
    return
  fi

  log "Setting up server: $SERVER_HOST"

  # Test SSH connection
  if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$SERVER_HOST" "echo ok" >/dev/null 2>&1; then
    echo "Error: Cannot SSH to $SERVER_HOST"
    echo "Make sure you have SSH access configured (key-based auth recommended)."
    exit 1
  fi
  ok "SSH connection"

  # Check if TaskYou is installed
  if remote "test -f $SERVER_HOME/.local/bin/ty" 2>/dev/null; then
    ok "TaskYou already installed"
  else
    log "Installing TaskYou"
    remote "curl -fsSL https://taskyou.dev/install.sh | bash" || {
      warn "TaskYou auto-install failed. Install it manually on the server."
      warn "See https://taskyou.dev for instructions."
    }
  fi

  # Git identity
  log "Configuring git identity"
  remote "git config --global user.name '$GIT_NAME' && git config --global user.email '$GIT_EMAIL'"
  ok "git: $GIT_NAME <$GIT_EMAIL>"

  # Skip Claude Code first-run onboarding (theme picker, keybinding prompt).
  # Without this, the daemon's interactive Claude sessions get stuck on setup screens.
  log "Pre-configuring Claude Code"
  ssh "$SERVER_HOST" 'test -f ~/.claude.json || echo "{\"hasCompletedOnboarding\":true,\"theme\":\"dark\",\"shiftEnterKeyBindingInstalled\":true}" > ~/.claude.json'
  # Also skip the dangerous-mode confirmation dialog
  ssh "$SERVER_HOST" 'mkdir -p ~/.claude && test -f ~/.claude/settings.json || echo "{\"skipDangerousModePermissionPrompt\":true}" > ~/.claude/settings.json'
  ok "Claude Code onboarding pre-configured"

  # Create project repos
  log "Creating project repositories"
  IFS=',' read -ra projs <<< "$PROJECTS"
  for proj in "${projs[@]}"; do
    proj=$(echo "$proj" | xargs)
    local repo_path="$SERVER_HOME/projects/$proj"
    if remote "test -d $repo_path/.git" 2>/dev/null; then
      ok "$proj (already exists)"
    else
      remote "mkdir -p $repo_path && cd $repo_path && git init -q"
      ok "$proj"
    fi

    # Write base CLAUDE.md into each project repo
    local rendered
    rendered=$(render "$(<"$TEMPLATES_DIR/project-claude-md.tmpl")")
    # Use heredoc via SSH to avoid quoting issues
    ssh "$SERVER_HOST" "cat > $repo_path/CLAUDE.md" <<< "$rendered"
    remote "cd $repo_path && git add CLAUDE.md && git diff --cached --quiet || git commit -q -m 'Add base CLAUDE.md'" 2>/dev/null || true

    # Pre-accept Claude trust for this project root.
    # The task.started hook handles worktree paths dynamically.
    ssh "$SERVER_HOST" "python3 -c \"
import json
cf = '$SERVER_HOME/.claude.json'
with open(cf) as f: data = json.load(f)
p = data.setdefault('projects', {}).setdefault('$repo_path', {})
p['hasTrustDialogAccepted'] = True
p['hasCompletedProjectOnboarding'] = True
with open(cf, 'w') as f: json.dump(data, f, indent=2)
\""
    ok "  Claude pre-authorized for $proj"

    # Register project with TaskYou
    if remote_with_path "ty projects show $proj" >/dev/null 2>&1; then
      ok "  ty project $proj (already registered)"
    else
      remote_with_path "ty projects create $proj --path $repo_path"
      ok "  ty project $proj registered"
    fi
  done

  # Install TaskYou hooks
  log "Installing TaskYou hooks"
  # OS-detect the hooks dir: Linux uses ~/.config, macOS uses
  # ~/Library/Application Support (matches ty's os.UserConfigDir()).
  local hooks_dir
  hooks_dir=$(resolve_hooks_dir remote "$SERVER_HOME")
  remote "mkdir -p \"$hooks_dir\""
  ok "hooks dir: $hooks_dir"

  for hook_tmpl in "$TEMPLATES_DIR"/hooks/*.tmpl; do
    local hook_name
    hook_name=$(basename "$hook_tmpl" .tmpl)
    local rendered
    rendered=$(render "$(<"$hook_tmpl")")
    ssh "$SERVER_HOST" "cat > \"$hooks_dir/$hook_name\" && chmod +x \"$hooks_dir/$hook_name\"" <<< "$rendered"
    ok "hook: $hook_name"
  done

  # Create notifications file
  remote "touch $SERVER_HOME/notifications.jsonl"
  ok "notifications.jsonl"

  # Ensure ty and other user tools are on PATH
  setup_path "$SERVER_HOST" "$SERVER_HOME"

  # Linear module
  if [[ "$LINEAR_ENABLED" == "true" ]]; then
    log "Setting up Linear integration"

    # Linear CLI
    local cli_dir="$SERVER_HOME/tools/linear-cli"
    remote "mkdir -p $cli_dir"
    scp -q "$MODULES_DIR/linear/linear-cli/linear.mjs" "$SERVER_HOST:$cli_dir/linear.mjs"
    remote "chmod +x $cli_dir/linear.mjs"

    # Create .env for Linear CLI
    local linear_labels_json="{\"agent handoff\":\"$LINEAR_LABEL_ID\"}"
    local linear_states_json="{\"todo\":\"$LINEAR_STATE_ID\"}"
    ssh "$SERVER_HOST" "cat > $cli_dir/.env" <<EOF
LINEAR_TOKEN=$LINEAR_API_KEY
LINEAR_TOKEN_AGENTS=$LINEAR_API_KEY
LINEAR_TEAM_ID=$LINEAR_TEAM_ID
LINEAR_TEAM_KEY=$LINEAR_TEAM_KEY
LINEAR_LABELS=$linear_labels_json
LINEAR_STATES=$linear_states_json
EOF
    ok "Linear CLI installed"

    # Symlink linear to ~/bin
    remote "mkdir -p $SERVER_HOME/bin && ln -sf $cli_dir/linear.mjs $SERVER_HOME/bin/linear"
    ok "linear → ~/bin/linear"

    # Linear poll script
    local scripts_dir="$SERVER_HOME/scripts"
    remote "mkdir -p $scripts_dir"
    scp -q "$MODULES_DIR/linear/linear-poll.mjs" "$SERVER_HOST:$scripts_dir/linear-poll.mjs"
    scp -q "$MODULES_DIR/common/rotate-log.sh" "$SERVER_HOST:$scripts_dir/rotate-log.sh"
    remote "chmod +x $scripts_dir/linear-poll.mjs $scripts_dir/rotate-log.sh"

    # Create .env for poll script
    local label_map_json="{"
    IFS=',' read -ra projs <<< "$PROJECTS"
    local first=true
    for proj in "${projs[@]}"; do
      proj=$(echo "$proj" | xargs)
      if $first; then first=false; else label_map_json+=","; fi
      label_map_json+="\"$proj\":\"$proj\""
    done
    label_map_json+="}"

    ssh "$SERVER_HOST" "cat > $scripts_dir/.env" <<EOF
LINEAR_TOKEN=$LINEAR_API_KEY
LINEAR_CLI=$SERVER_HOME/bin/linear
TY_PATH=$SERVER_HOME/.local/bin/ty
LABEL_PROJECT_MAP=$label_map_json
DEFAULT_PROJECT=$(echo "$PROJECTS" | cut -d',' -f1 | xargs)
EOF
    ok "Linear poll script installed"

    # Set up cron job
    # */10 is the floor for pollers: anything tighter multiplies API spend
    # across every box that shares the same GitHub/Linear user. rotate-log.sh
    # runs first so an error-looping poller cannot grow a 178MB log.
    local cron_line="*/10 * * * * export PATH=$SERVER_HOME/.npm-global/bin:$SERVER_HOME/.local/bin:/home/deploy/.asdf/installs/nodejs/24.13.0/bin:\$PATH; $scripts_dir/rotate-log.sh $scripts_dir/linear-poll.log; node $scripts_dir/linear-poll.mjs >> $scripts_dir/linear-poll.log 2>&1"
    # Rewrite rather than skip: boxes provisioned before the */10 floor still
    # carry a */2 line, and leaving it in place is how the budget got burned.
    if remote "crontab -l 2>/dev/null" | grep -qF "$cron_line"; then
      ok "Cron job already up to date"
    else
      remote "(crontab -l 2>/dev/null | grep -v 'linear-poll.mjs'; echo '$cron_line') | crontab -"
      ok "Cron job installed (every 10 minutes)"
    fi
  fi

  # Slack module
  if [[ "$SLACK_ENABLED" == "true" ]]; then
    setup_slack_remote "$SERVER_HOST" "$SERVER_HOME"
  fi

  # Security audit script
  log "Installing security audit script"
  render_file "$TEMPLATES_DIR/audit.sh.tmpl" "/tmp/taskyou-audit.sh"
  scp -q "/tmp/taskyou-audit.sh" "$SERVER_HOST:$SERVER_HOME/.local/bin/audit.sh"
  remote "chmod +x $SERVER_HOME/.local/bin/audit.sh"
  rm -f "/tmp/taskyou-audit.sh"
  ok "audit.sh"

  # Install daemon as a systemd user service (auto-starts on boot, restarts on crash)
  install_daemon_service "$SERVER_HOST" "$SERVER_HOME"

  # Claude auth expiry monitor (detects the ~30-day login lapse before it
  # silently stops every agent).
  install_auth_monitor "$SERVER_HOST" "$SERVER_HOME"

  log "Server setup complete"
}

# ── exe.dev deployment ────────────────────────────────────────────────────────

setup_exe_dev() {
  if [[ -z "$EXE_DEV_VM_NAME" ]]; then
    echo "Error: EXE_DEV_VM_NAME is required for exe.dev deployment"
    echo "Set it in config.env"
    exit 1
  fi

  local EXE_HOST="exedev@${EXE_DEV_VM_NAME}.exe.xyz"
  local EXE_HOME="/home/exedev"

  log "Deploying GM to exe.dev VM: $EXE_DEV_VM_NAME"

  # Check SSH access to exe.dev management
  if ! ssh -o ConnectTimeout=5 -o BatchMode=yes exe.dev </dev/null >/dev/null 2>&1; then
    echo "Error: Cannot SSH to exe.dev"
    echo "Make sure your SSH key is registered with exe.dev."
    echo "Visit https://exe.dev to set up your account and SSH key."
    exit 1
  fi
  ok "exe.dev SSH access"

  # Create or verify VM exists
  if ssh -o ConnectTimeout=5 -o BatchMode=yes "$EXE_HOST" "echo ok" >/dev/null 2>&1; then
    ok "VM $EXE_DEV_VM_NAME already exists"
  else
    log "Creating exe.dev VM: $EXE_DEV_VM_NAME"
    ssh exe.dev "vm create $EXE_DEV_VM_NAME" || {
      echo "Error: Failed to create VM. Create it manually at https://exe.dev"
      exit 1
    }
    # Wait for VM to become available
    echo "  Waiting for VM to be ready..."
    for i in $(seq 1 30); do
      if ssh -o ConnectTimeout=5 -o BatchMode=yes "$EXE_HOST" "echo ok" >/dev/null 2>&1; then
        break
      fi
      sleep 2
    done
    ok "VM created"
  fi

  # Helper to run commands on the exe.dev VM
  exe_remote() {
    ssh "$EXE_HOST" "$@"
  }

  exe_remote_with_path() {
    ssh "$EXE_HOST" "export PATH=$EXE_HOME/bin:$EXE_HOME/.local/bin:\$PATH && $*"
  }

  # Install TaskYou
  if exe_remote "test -f $EXE_HOME/.local/bin/ty" 2>/dev/null; then
    ok "TaskYou already installed"
  else
    log "Installing TaskYou"
    exe_remote "curl -fsSL https://taskyou.dev/install.sh | bash" || {
      warn "TaskYou auto-install failed. Install it manually on the VM."
      exit 1
    }
    ok "TaskYou installed"
  fi

  # Git identity
  log "Configuring git identity"
  exe_remote "git config --global user.name '$GIT_NAME' && git config --global user.email '$GIT_EMAIL'"
  ok "git: $GIT_NAME <$GIT_EMAIL>"

  # Pre-configure Claude Code (skip onboarding)
  log "Pre-configuring Claude Code"
  exe_remote 'test -f ~/.claude.json || echo "{\"hasCompletedOnboarding\":true,\"theme\":\"dark\",\"shiftEnterKeyBindingInstalled\":true}" > ~/.claude.json'
  exe_remote 'mkdir -p ~/.claude && test -f ~/.claude/settings.json || echo "{\"skipDangerousModePermissionPrompt\":true}" > ~/.claude/settings.json'
  ok "Claude Code onboarding pre-configured"

  # Create project repos
  log "Creating project repositories"
  IFS=',' read -ra projs <<< "$PROJECTS"
  for proj in "${projs[@]}"; do
    proj=$(echo "$proj" | xargs)
    local repo_path="$EXE_HOME/projects/$proj"
    if exe_remote "test -d $repo_path/.git" 2>/dev/null; then
      ok "$proj (already exists)"
    else
      exe_remote "mkdir -p $repo_path && cd $repo_path && git init -q"
      ok "$proj"
    fi

    # Write base CLAUDE.md into each project repo
    local rendered
    rendered=$(render "$(<"$TEMPLATES_DIR/project-claude-md.tmpl")")
    ssh "$EXE_HOST" "cat > $repo_path/CLAUDE.md" <<< "$rendered"
    exe_remote "cd $repo_path && git add CLAUDE.md && git diff --cached --quiet || git commit -q -m 'Add base CLAUDE.md'" 2>/dev/null || true

    # Pre-accept Claude trust
    ssh "$EXE_HOST" "python3 -c \"
import json
cf = '$EXE_HOME/.claude.json'
with open(cf) as f: data = json.load(f)
p = data.setdefault('projects', {}).setdefault('$repo_path', {})
p['hasTrustDialogAccepted'] = True
p['hasCompletedProjectOnboarding'] = True
with open(cf, 'w') as f: json.dump(data, f, indent=2)
\""
    ok "  Claude pre-authorized for $proj"

    # Register project with TaskYou
    if exe_remote_with_path "ty projects show $proj" >/dev/null 2>&1; then
      ok "  ty project $proj (already registered)"
    else
      exe_remote_with_path "ty projects create $proj --path $repo_path"
      ok "  ty project $proj registered"
    fi
  done

  # GM project directory
  log "Setting up GM project directory"
  exe_remote "mkdir -p $EXE_HOME/projects/gm/.claude"

  # Generate server-local CLAUDE.md
  render_file "$TEMPLATES_DIR/exe-dev/CLAUDE.md.tmpl" "/tmp/taskyou-exe-dev-claude-md"
  scp -q "/tmp/taskyou-exe-dev-claude-md" "$EXE_HOST:$EXE_HOME/projects/gm/CLAUDE.md"
  rm -f "/tmp/taskyou-exe-dev-claude-md"
  ok "GM CLAUDE.md (server-local)"

  # GM .claude/settings.json
  render_file "$TEMPLATES_DIR/settings.json.tmpl" "/tmp/taskyou-exe-dev-settings"
  scp -q "/tmp/taskyou-exe-dev-settings" "$EXE_HOST:$EXE_HOME/projects/gm/.claude/settings.json"
  rm -f "/tmp/taskyou-exe-dev-settings"
  ok "GM .claude/settings.json"

  # Pre-accept Claude trust for GM directory
  ssh "$EXE_HOST" "python3 -c \"
import json
cf = '$EXE_HOME/.claude.json'
with open(cf) as f: data = json.load(f)
p = data.setdefault('projects', {}).setdefault('$EXE_HOME/projects/gm', {})
p['hasTrustDialogAccepted'] = True
p['hasCompletedProjectOnboarding'] = True
with open(cf, 'w') as f: json.dump(data, f, indent=2)
\""
  ok "Claude pre-authorized for GM"

  # Init git in GM dir if needed
  exe_remote "cd $EXE_HOME/projects/gm && test -d .git || git init -q"
  ok "GM git repo"

  # Install TaskYou hooks
  log "Installing TaskYou hooks"
  # OS-detect the hooks dir (exe.dev VMs are Linux -> ~/.config, but resolve
  # dynamically so a macOS target would get ~/Library/Application Support).
  local hooks_dir
  hooks_dir=$(resolve_hooks_dir exe_remote "$EXE_HOME")
  exe_remote "mkdir -p \"$hooks_dir\""
  ok "hooks dir: $hooks_dir"

  for hook_tmpl in "$TEMPLATES_DIR"/hooks/*.tmpl; do
    local hook_name
    hook_name=$(basename "$hook_tmpl" .tmpl)
    local rendered
    rendered=$(render "$(<"$hook_tmpl")")
    ssh "$EXE_HOST" "cat > \"$hooks_dir/$hook_name\" && chmod +x \"$hooks_dir/$hook_name\"" <<< "$rendered"
    ok "hook: $hook_name"
  done

  # Create notifications file
  exe_remote "touch $EXE_HOME/notifications.jsonl"
  ok "notifications.jsonl"

  # Ensure ty and other user tools are on PATH
  setup_path "$EXE_HOST" "$EXE_HOME"

  # GM launcher script
  log "Setting up GM launcher"
  exe_remote "mkdir -p $EXE_HOME/bin"
  render_file "$TEMPLATES_DIR/exe-dev/gm-launcher.tmpl" "/tmp/taskyou-exe-dev-gm-launcher"
  scp -q "/tmp/taskyou-exe-dev-gm-launcher" "$EXE_HOST:$EXE_HOME/bin/gm"
  exe_remote "chmod +x $EXE_HOME/bin/gm"
  rm -f "/tmp/taskyou-exe-dev-gm-launcher"
  ok "bin/gm launcher"

  # Bashrc auto-launch hook (idempotent)
  log "Setting up bashrc auto-launch hook"
  local bashrc_marker="# Auto-launch GM for xterm sessions"
  if exe_remote "grep -q '$bashrc_marker' $EXE_HOME/.bashrc 2>/dev/null"; then
    ok "bashrc hook (already installed)"
  else
    ssh "$EXE_HOST" "cat >> $EXE_HOME/.bashrc" <<'BASHRC_EOF'

# Auto-launch GM for xterm sessions named gm or gm-*
_parent_cmd=$(cat /proc/$PPID/cmdline 2>/dev/null | tr '\0' ' ')
if [[ "$_parent_cmd" == *xterm-exe.dev-gm* ]]; then
  exec gm
fi
unset _parent_cmd
BASHRC_EOF
    ok "bashrc hook installed"
  fi

  # Install ty-web extension
  log "Installing ty-web"
  if exe_remote "test -f $EXE_HOME/.local/bin/ty-web" 2>/dev/null; then
    ok "ty-web already installed"
  else
    # Build from source if Go is available, otherwise download release
    if exe_remote "command -v go" >/dev/null 2>&1; then
      exe_remote "GOBIN=$EXE_HOME/.local/bin go install github.com/bborn/workflow/extensions/ty-web/cmd@latest && mv $EXE_HOME/.local/bin/cmd $EXE_HOME/.local/bin/ty-web"
      ok "ty-web installed (go install)"
    else
      exe_remote "curl -fsSL https://taskyou.dev/install-ty-web.sh | bash" || {
        warn "ty-web install failed. Install it manually."
        warn "Requires Go: go install github.com/bborn/workflow/extensions/ty-web/cmd@latest"
      }
      ok "ty-web installed"
    fi
  fi

  # Stop and clean up old board infrastructure (nginx, board-refresh, cron entries)
  exe_remote "pkill -f board-refresh 2>/dev/null" || true
  exe_remote "crontab -l 2>/dev/null | grep -v 'board-refresh\|ty serve\|ty-web' | crontab -" 2>/dev/null || true
  exe_remote "sudo systemctl stop nginx 2>/dev/null; sudo systemctl disable nginx 2>/dev/null" || true
  exe_remote "rm -f $EXE_HOME/bin/board-refresh" 2>/dev/null || true

  # Deploy ty-serve and ty-web as systemd user services
  log "Installing ty-serve and ty-web services"
  exe_remote "mkdir -p $EXE_HOME/.config/systemd/user $EXE_HOME/log"

  scp -q "$TEMPLATES_DIR/ty-serve.service.tmpl" "$EXE_HOST:$EXE_HOME/.config/systemd/user/ty-serve.service"
  scp -q "$TEMPLATES_DIR/ty-web.service.tmpl" "$EXE_HOST:$EXE_HOME/.config/systemd/user/ty-web.service"

  exe_remote "systemctl --user daemon-reload"
  exe_remote "systemctl --user enable ty-serve ty-web"
  exe_remote "systemctl --user restart ty-serve ty-web"
  sleep 2

  if exe_remote "systemctl --user is-active ty-web" 2>/dev/null | grep -q "active"; then
    ok "ty-serve + ty-web running (systemd user services)"
    ok "Board: http://localhost:8000 (proxied via exe.dev)"
  else
    warn "ty-web may not have started. Debug with: ssh $EXE_HOST 'systemctl --user status ty-web'"
  fi

  # Set exe.dev proxy to point at port 8000
  ssh exe.dev "share port $EXE_DEV_VM_NAME 8000" 2>/dev/null || warn "Could not set proxy port. Run: ssh exe.dev share port $EXE_DEV_VM_NAME 8000"
  ok "exe.dev proxy → port 8000"

  # Set VM to private by default
  ssh exe.dev "share set-private $EXE_DEV_VM_NAME" 2>/dev/null || true
  ok "VM access set to private"

  # Linear module (same as server setup)
  if [[ "$LINEAR_ENABLED" == "true" ]]; then
    log "Setting up Linear integration"

    local cli_dir="$EXE_HOME/tools/linear-cli"
    exe_remote "mkdir -p $cli_dir"
    scp -q "$MODULES_DIR/linear/linear-cli/linear.mjs" "$EXE_HOST:$cli_dir/linear.mjs"
    exe_remote "chmod +x $cli_dir/linear.mjs"

    local linear_labels_json="{\"agent handoff\":\"$LINEAR_LABEL_ID\"}"
    local linear_states_json="{\"todo\":\"$LINEAR_STATE_ID\"}"
    ssh "$EXE_HOST" "cat > $cli_dir/.env" <<EOF
LINEAR_TOKEN=$LINEAR_API_KEY
LINEAR_TOKEN_AGENTS=$LINEAR_API_KEY
LINEAR_TEAM_ID=$LINEAR_TEAM_ID
LINEAR_TEAM_KEY=$LINEAR_TEAM_KEY
LINEAR_LABELS=$linear_labels_json
LINEAR_STATES=$linear_states_json
EOF
    ok "Linear CLI installed"

    exe_remote "ln -sf $cli_dir/linear.mjs $EXE_HOME/bin/linear"
    ok "linear → ~/bin/linear"

    local scripts_dir="$EXE_HOME/scripts"
    exe_remote "mkdir -p $scripts_dir"
    scp -q "$MODULES_DIR/linear/linear-poll.mjs" "$EXE_HOST:$scripts_dir/linear-poll.mjs"
    scp -q "$MODULES_DIR/common/rotate-log.sh" "$EXE_HOST:$scripts_dir/rotate-log.sh"
    exe_remote "chmod +x $scripts_dir/linear-poll.mjs $scripts_dir/rotate-log.sh"

    local label_map_json="{"
    IFS=',' read -ra projs <<< "$PROJECTS"
    local first=true
    for proj in "${projs[@]}"; do
      proj=$(echo "$proj" | xargs)
      if $first; then first=false; else label_map_json+=","; fi
      label_map_json+="\"$proj\":\"$proj\""
    done
    label_map_json+="}"

    ssh "$EXE_HOST" "cat > $scripts_dir/.env" <<EOF
LINEAR_TOKEN=$LINEAR_API_KEY
LINEAR_CLI=$EXE_HOME/bin/linear
TY_PATH=$EXE_HOME/.local/bin/ty
LABEL_PROJECT_MAP=$label_map_json
DEFAULT_PROJECT=$(echo "$PROJECTS" | cut -d',' -f1 | xargs)
EOF
    ok "Linear poll script installed"

    # See the note on the server cron line: */10 floor + rotate before each run.
    local cron_line_linear="*/10 * * * * export PATH=$EXE_HOME/.local/bin:$EXE_HOME/bin:\$PATH; $scripts_dir/rotate-log.sh $scripts_dir/linear-poll.log; node $scripts_dir/linear-poll.mjs >> $scripts_dir/linear-poll.log 2>&1"
    if exe_remote "crontab -l 2>/dev/null" | grep -qF "$cron_line_linear"; then
      ok "Linear cron job already up to date"
    else
      exe_remote "(crontab -l 2>/dev/null | grep -v 'linear-poll.mjs'; echo '$cron_line_linear') | crontab -"
      ok "Linear cron job installed (every 10 minutes)"
    fi
  fi

  # Slack module
  if [[ "$SLACK_ENABLED" == "true" ]]; then
    setup_slack_remote "$EXE_HOST" "$EXE_HOME"
  fi

  # Security audit script
  log "Installing security audit script"
  render_file "$TEMPLATES_DIR/audit.sh.tmpl" "/tmp/taskyou-audit.sh"
  scp -q "/tmp/taskyou-audit.sh" "$EXE_HOST:$EXE_HOME/.local/bin/audit.sh"
  exe_remote "chmod +x $EXE_HOME/.local/bin/audit.sh"
  rm -f "/tmp/taskyou-audit.sh"
  ok "audit.sh"

  # Install daemon as a systemd user service (auto-starts on boot, restarts on crash)
  install_daemon_service "$EXE_HOST" "$EXE_HOME"

  # Claude auth expiry monitor (detects the ~30-day login lapse before it
  # silently stops every agent).
  install_auth_monitor "$EXE_HOST" "$EXE_HOME"

  log "exe.dev deployment complete!"
  echo ""
  echo "  Task board:    https://${EXE_DEV_VM_NAME}.exe.xyz"
  echo "  API server:    https://${EXE_DEV_VM_NAME}.exe.xyz/api/status (proxied)"
  echo "  GM terminal:   https://${EXE_DEV_VM_NAME}.xterm.exe.xyz/?name=gm"
  echo "  Shell:         https://${EXE_DEV_VM_NAME}.xterm.exe.xyz/"
  echo ""
  echo "  Share access:  ssh exe.dev share add $EXE_DEV_VM_NAME user@example.com"
  echo ""
}

# ── Manual steps checklist ───────────────────────────────────────────────────

print_checklist() {
  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo " Setup complete! Manual steps remaining:"
  echo "════════════════════════════════════════════════════════════"
  echo ""
  echo " 1. Add the shell alias to ~/.zshrc:"
  echo "    alias ${GM_ALIAS}='cd ${LOCAL_PROJECT_DIR} && CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR} claude --dangerously-load-development-channels server:taskyou'"
  echo ""

  if is_local_server; then
    # Local mode: GM + daemon share this machine — no SSH, no server login.
    echo " 2. Make sure the TaskYou daemon is running on this machine:"
    echo "    ty daemon status      # start it with: ty daemon"
    echo ""
    echo " 3. You're already logged into Claude + GitHub here — nothing to do on a server."
    echo ""

    if [[ -n "${GITHUB_REPOS:-}" ]]; then
      echo " 4. Add GitHub remotes to project repos:"
      IFS=',' read -ra mappings <<< "$GITHUB_REPOS"
      for mapping in "${mappings[@]}"; do
        local proj="${mapping%%:*}"
        local repo="${mapping#*:}"
        echo "    (cd $SERVER_HOME/projects/$proj && git remote add origin git@github.com:$repo.git)"
      done
      echo ""
    fi
  else
    echo " 2. Log into Claude on the server:"
    echo "    ssh $SERVER_HOST"
    echo "    claude login"
    echo ""
    echo " 3. Authenticate GitHub on the server:"
    echo "    ssh $SERVER_HOST"
    echo "    gh auth login"
    echo ""

    if [[ -n "${GITHUB_REPOS:-}" ]]; then
      echo " 4. Add GitHub remotes to project repos:"
      IFS=',' read -ra mappings <<< "$GITHUB_REPOS"
      for mapping in "${mappings[@]}"; do
        local proj="${mapping%%:*}"
        local repo="${mapping#*:}"
        echo "    ssh $SERVER_HOST 'cd $SERVER_HOME/projects/$proj && git remote add origin git@github.com:$repo.git'"
      done
      echo ""
    fi
  fi

  echo " 5. Start the GM:"
  echo "    ${GM_ALIAS}"
  echo ""
}

# ── Run ──────────────────────────────────────────────────────────────────────

case "$MODE" in
  local)
    setup_local
    print_checklist
    ;;
  server)
    setup_server
    print_checklist
    ;;
  exe)
    setup_exe_dev
    ;;
  all)
    setup_local
    setup_server
    print_checklist
    ;;
  slack)
    setup_slack_wizard
    ;;
esac
