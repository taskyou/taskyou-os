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

# ── Parse args ───────────────────────────────────────────────────────────────

if [[ $# -lt 2 ]]; then
  usage
fi

MODE="$1"
PROJECT_DIR="$(cd "$2" && pwd 2>/dev/null || echo "$2")"
CONFIG_FILE="$PROJECT_DIR/config.env"

if [[ "$MODE" != "local" && "$MODE" != "server" && "$MODE" != "exe" && "$MODE" != "all" ]]; then
  echo "Error: mode must be local, server, exe, or all"
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
export NONO_ENABLED="${NONO_ENABLED:-false}"
export NONO_CREDENTIALS="${NONO_CREDENTIALS:-}"
export NONO_PROXY_HOSTS="${NONO_PROXY_HOSTS:-}"

# Generate nono proxy flags for wrapper scripts
if [[ "$NONO_ENABLED" == "true" && -n "$NONO_PROXY_HOSTS" ]]; then
  NONO_PROXY_FLAGS=""
  IFS=',' read -ra hosts <<< "$NONO_PROXY_HOSTS"
  for host in "${hosts[@]}"; do
    host=$(echo "$host" | xargs)
    NONO_PROXY_FLAGS+="--proxy-allow $host "
  done
  IFS=',' read -ra creds <<< "$NONO_CREDENTIALS"
  for cred in "${creds[@]}"; do
    name=$(echo "$cred" | cut -d: -f1 | xargs)
    NONO_PROXY_FLAGS+="--proxy-credential $name "
  done
  export NONO_PROXY_FLAGS
else
  export NONO_PROXY_FLAGS=""
fi

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

  render_file "$TEMPLATES_DIR/agent-monitor.tmpl" "$LOCAL_PROJECT_DIR/bin/${PROJECT_NAME}-agent-monitor"
  chmod +x "$LOCAL_PROJECT_DIR/bin/${PROJECT_NAME}-agent-monitor"
  ok "bin/${PROJECT_NAME}-agent-monitor"

  render_file "$TEMPLATES_DIR/retry-task.tmpl" "$LOCAL_PROJECT_DIR/bin/${PROJECT_NAME}-retry-task"
  chmod +x "$LOCAL_PROJECT_DIR/bin/${PROJECT_NAME}-retry-task"
  ok "bin/${PROJECT_NAME}-retry-task"

  render_file "$TEMPLATES_DIR/open-board.tmpl" "$LOCAL_PROJECT_DIR/bin/${PROJECT_NAME}-open-board"
  chmod +x "$LOCAL_PROJECT_DIR/bin/${PROJECT_NAME}-open-board"
  ok "bin/${PROJECT_NAME}-open-board"

  # SwiftBar plugin
  render_file "$TEMPLATES_DIR/swiftbar-plugin.60s.sh.tmpl" "$LOCAL_PROJECT_DIR/bin/${PROJECT_NAME}-gm.60s.sh"
  chmod +x "$LOCAL_PROJECT_DIR/bin/${PROJECT_NAME}-gm.60s.sh"
  ok "bin/${PROJECT_NAME}-gm.60s.sh (SwiftBar plugin)"

  # launchd plist
  render_file "$TEMPLATES_DIR/launchd-plist.tmpl" "$LOCAL_PROJECT_DIR/bin/com.${PROJECT_NAME}.agent-monitor.plist"
  ok "bin/com.${PROJECT_NAME}.agent-monitor.plist"

  # R2 wrangler.toml
  if [[ "$R2_ENABLED" == "true" ]]; then
    log "Setting up R2"
    mkdir -p "$LOCAL_PROJECT_DIR/tmp"
    render_file "$MODULES_DIR/r2/wrangler.toml.tmpl" "$LOCAL_PROJECT_DIR/tmp/wrangler.toml"
    ok "tmp/wrangler.toml"
  fi

  # GM slash commands
  log "GM commands"
  mkdir -p "$LOCAL_PROJECT_DIR/.claude/commands"
  for cmd_tmpl in "$TEMPLATES_DIR"/commands/*.tmpl; do
    local cmd_name
    cmd_name=$(basename "$cmd_tmpl" .md.tmpl)
    render_file "$cmd_tmpl" "$LOCAL_PROJECT_DIR/.claude/commands/$cmd_name.md"
    ok "command: /$cmd_name"
  done

  # Shell alias
  log "Shell alias"
  local alias_line="alias ${GM_ALIAS}='cd ${LOCAL_PROJECT_DIR} && CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR} claude'"
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

  # Optional installs
  read -rp "Install SwiftBar plugin to ~/Library/Application Support/SwiftBar/? [y/N] " install_swiftbar
  if [[ "$install_swiftbar" =~ ^[Yy]$ ]]; then
    local swiftbar_dir="$HOME/Library/Application Support/SwiftBar"
    mkdir -p "$swiftbar_dir"
    cp "$LOCAL_PROJECT_DIR/bin/${PROJECT_NAME}-gm.60s.sh" "$swiftbar_dir/"
    ok "SwiftBar plugin installed"
    warn "You need a logo.png in $LOCAL_PROJECT_DIR/bin/ for the menu bar icon"
  fi

  read -rp "Install and load launchd agent for the monitor? [y/N] " install_launchd
  if [[ "$install_launchd" =~ ^[Yy]$ ]]; then
    local plist_name="com.${PROJECT_NAME}.agent-monitor.plist"
    local plist_dest="$HOME/Library/LaunchAgents/$plist_name"
    cp "$LOCAL_PROJECT_DIR/bin/$plist_name" "$plist_dest"
    launchctl unload "$plist_dest" 2>/dev/null || true
    launchctl load "$plist_dest"
    ok "launchd agent loaded: $plist_name"
  fi
}

# ── Server setup ─────────────────────────────────────────────────────────────

setup_server() {
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
cf = '$HOME/.claude.json'
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
  local hooks_dir="$SERVER_HOME/.config/task/hooks"
  remote "mkdir -p $hooks_dir"

  for hook_tmpl in "$TEMPLATES_DIR"/hooks/*.tmpl; do
    local hook_name
    hook_name=$(basename "$hook_tmpl" .tmpl)
    local rendered
    rendered=$(render "$(<"$hook_tmpl")")
    ssh "$SERVER_HOST" "cat > $hooks_dir/$hook_name && chmod +x $hooks_dir/$hook_name" <<< "$rendered"
    ok "hook: $hook_name"
  done

  # Create notifications file
  remote "touch $SERVER_HOME/notifications.jsonl"
  ok "notifications.jsonl"

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
    remote "chmod +x $scripts_dir/linear-poll.mjs"

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
    local cron_line="*/2 * * * * export PATH=$SERVER_HOME/.npm-global/bin:$SERVER_HOME/.local/bin:/home/deploy/.asdf/installs/nodejs/24.13.0/bin:\$PATH && node $scripts_dir/linear-poll.mjs >> $scripts_dir/linear-poll.log 2>&1"
    if remote "crontab -l 2>/dev/null" | grep -q "linear-poll.mjs"; then
      ok "Cron job already exists"
    else
      remote "(crontab -l 2>/dev/null; echo '$cron_line') | crontab -"
      ok "Cron job installed (every 2 minutes)"
    fi
  fi

  # Start daemon
  log "Starting TaskYou daemon"
  if remote_with_path "ty daemon status" 2>/dev/null | grep -q "running"; then
    ok "Daemon already running"
  else
    remote "nohup $SERVER_HOME/.local/bin/ty daemon --dangerous > /tmp/ty-daemon.log 2>&1 &"
    sleep 2
    if remote_with_path "ty daemon status" 2>/dev/null | grep -q "running"; then
      ok "Daemon started"
    else
      warn "Daemon may not have started. Check with: ssh $SERVER_HOST 'ty daemon status'"
    fi
  fi

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
  if ! ssh -o ConnectTimeout=5 -o BatchMode=yes exe.dev "echo ok" >/dev/null 2>&1; then
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
cf = '$HOME/.claude.json'
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
cf = '$HOME/.claude.json'
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
  local hooks_dir="$EXE_HOME/.config/task/hooks"
  exe_remote "mkdir -p $hooks_dir"

  for hook_tmpl in "$TEMPLATES_DIR"/hooks/*.tmpl; do
    local hook_name
    hook_name=$(basename "$hook_tmpl" .tmpl)
    local rendered
    rendered=$(render "$(<"$hook_tmpl")")
    ssh "$EXE_HOST" "cat > $hooks_dir/$hook_name && chmod +x $hooks_dir/$hook_name" <<< "$rendered"
    ok "hook: $hook_name"
  done

  # Create notifications file
  exe_remote "touch $EXE_HOME/notifications.jsonl"
  ok "notifications.jsonl"

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

  # Board refresh daemon
  log "Setting up board refresh daemon"
  render_file "$TEMPLATES_DIR/exe-dev/board-refresh.tmpl" "/tmp/taskyou-exe-dev-board-refresh"
  scp -q "/tmp/taskyou-exe-dev-board-refresh" "$EXE_HOST:$EXE_HOME/bin/board-refresh"
  exe_remote "chmod +x $EXE_HOME/bin/board-refresh"
  rm -f "/tmp/taskyou-exe-dev-board-refresh"
  ok "bin/board-refresh"

  # Board refresh crontab (idempotent)
  local cron_line="@reboot $EXE_HOME/bin/board-refresh"
  if exe_remote "crontab -l 2>/dev/null" | grep -q "board-refresh"; then
    ok "board-refresh cron (already installed)"
  else
    exe_remote "(crontab -l 2>/dev/null; echo '$cron_line') | crontab -"
    ok "board-refresh cron installed"
  fi

  # Start board-refresh now if not running
  if exe_remote "pgrep -f board-refresh" >/dev/null 2>&1; then
    ok "board-refresh already running"
  else
    exe_remote "nohup $EXE_HOME/bin/board-refresh > /tmp/board-refresh.log 2>&1 &"
    ok "board-refresh started"
  fi

  # Landing page
  log "Setting up landing page"
  exe_remote "sudo mkdir -p /var/www/html"
  render_file "$TEMPLATES_DIR/exe-dev/landing-page.html.tmpl" "/tmp/taskyou-exe-dev-landing"
  scp -q "/tmp/taskyou-exe-dev-landing" "$EXE_HOST:/tmp/taskyou-landing.html"
  exe_remote "sudo mv /tmp/taskyou-landing.html /var/www/html/index.html"
  rm -f "/tmp/taskyou-exe-dev-landing"
  ok "landing page"

  # Nginx
  log "Setting up nginx"
  # Ensure nginx serves on port 8000
  exe_remote "sudo tee /etc/nginx/sites-available/default > /dev/null" <<'NGINX_EOF'
server {
    listen 8000 default_server;
    root /var/www/html;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    location /board.json {
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header Access-Control-Allow-Origin "*";
    }
}
NGINX_EOF
  exe_remote "sudo systemctl start nginx && sudo systemctl enable nginx" 2>/dev/null
  exe_remote "sudo nginx -t && sudo systemctl reload nginx" 2>/dev/null
  ok "nginx configured (port 8000)"

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
    exe_remote "chmod +x $scripts_dir/linear-poll.mjs"

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

    local cron_line_linear="*/2 * * * * export PATH=$EXE_HOME/.local/bin:$EXE_HOME/bin:\$PATH && node $scripts_dir/linear-poll.mjs >> $scripts_dir/linear-poll.log 2>&1"
    if exe_remote "crontab -l 2>/dev/null" | grep -q "linear-poll.mjs"; then
      ok "Linear cron job already exists"
    else
      exe_remote "(crontab -l 2>/dev/null; echo '$cron_line_linear') | crontab -"
      ok "Linear cron job installed"
    fi
  fi

  # Start TaskYou daemon
  log "Starting TaskYou daemon"
  if exe_remote_with_path "ty daemon status" 2>/dev/null | grep -q "running"; then
    ok "Daemon already running"
  else
    exe_remote "nohup $EXE_HOME/.local/bin/ty daemon --dangerous > /tmp/ty-daemon.log 2>&1 &"
    sleep 2
    if exe_remote_with_path "ty daemon status" 2>/dev/null | grep -q "running"; then
      ok "Daemon started"
    else
      warn "Daemon may not have started. Check with: ssh $EXE_HOST 'ty daemon status'"
    fi
  fi

  log "exe.dev deployment complete!"
  echo ""
  echo "  Landing page:  https://${EXE_DEV_VM_NAME}.exe.xyz"
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
  echo "    alias ${GM_ALIAS}='cd ${LOCAL_PROJECT_DIR} && CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR} claude'"
  echo ""
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
      echo "    ssh $SERVER_HOST 'cd $SERVER_HOME/projects/$proj && git remote add origin https://github.com/$repo.git'"
    done
    echo ""
  fi

  echo " 5. Add a logo.png to $LOCAL_PROJECT_DIR/bin/ for the SwiftBar menu bar icon"
  echo ""
  echo " 6. Start the GM:"
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
esac
