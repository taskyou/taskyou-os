#!/usr/bin/env bash
# TaskYouOS QA harness — hermetic, sandboxed, non-destructive.
#
# Runs the real setup.sh against a throwaway $HOME and a git worktree of a PR
# branch, then exercises the channel end to end. It NEVER touches your real
# ~/.local/share/task, ~/Library/Application Support/task, ~/.gitconfig, your
# GMs, or your running daemon — everything keys off a sandbox HOME.
#
# Usage:
#   qa/run-qa.sh [git-ref]      # default: HEAD (CI); pass pr-31 etc. locally
#
# Requires: bun, python3. ty is optional — its assertions are skipped when it's
# absent (CI mode), so the render + smoke + notification chain still gets tested.

set -uo pipefail

REF="${1:-HEAD}"   # default: the current checkout (CI passes nothing)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/taskyou-qa.XXXXXX")"
SBX_HOME="$SANDBOX/home"
GM_DIR="$SANDBOX/gm"
SRC="$SANDBOX/src"

PASS=0; FAIL=0
pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
hr()   { echo "────────────────────────────────────────────────────────"; }

cleanup() {
  git -C "$REPO_ROOT" worktree remove --force "$SRC" >/dev/null 2>&1 || true
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

echo "TaskYouOS QA harness"
hr
echo "  ref:      $REF"
echo "  sandbox:  $SANDBOX"
echo "  HOME →    $SBX_HOME   (real HOME untouched)"
echo "  ty:       $(command -v ty)  ($(ty --version 2>/dev/null | head -1))"
hr

# ── Worktree of the PR (keeps your real checkout on its current branch) ───────
git -C "$REPO_ROOT" worktree add --detach "$SRC" "$REF" >/dev/null 2>&1 \
  && pass "worktree of $REF created" \
  || { fail "could not create worktree of $REF"; exit 1; }

# ── Sandbox HOME + test config ───────────────────────────────────────────────
mkdir -p "$SBX_HOME" "$GM_DIR"
export HOME="$SBX_HOME"          # the isolation boundary
export CLAUDE_CONFIG_DIR="$SBX_HOME/.claude"

cat > "$GM_DIR/config.env" <<EOF
PROJECT_NAME="qatest"
PROJECT_DISPLAY_NAME="QA Test"
PROJECT_DESCRIPTION="QA harness sandbox"
OWNER_NAME="QA"
GM_ALIAS="qagm"
SERVER_HOST="local"
SERVER_USER="qa"
SERVER_HOME="$SBX_HOME"
LOCAL_PROJECT_DIR="$GM_DIR"
CLAUDE_CONFIG_DIR="$SBX_HOME/.claude"
PROJECTS="qa-test"
GIT_NAME="QA Bot"
GIT_EMAIL="qa@example.com"
EOF

# ── 1. Local GM render (setup_local) ─────────────────────────────────────────
echo; echo "[1] setup.sh local — render GM + channel"
( cd "$SRC" && ./setup.sh local "$GM_DIR" ) >"$SANDBOX/local.log" 2>&1 \
  && pass "setup.sh local exited 0" \
  || fail "setup.sh local failed (see $SANDBOX/local.log)"

[ -f "$GM_DIR/channel/taskyou-channel.ts" ] && pass "channel/taskyou-channel.ts rendered" || fail "channel server not rendered"
[ -f "$GM_DIR/.mcp.json" ]                  && pass ".mcp.json rendered"                 || fail ".mcp.json missing"
grep -q 'server:taskyou' "$SANDBOX/local.log" && pass "alias includes channel flag" || fail "alias missing channel flag"
[ -d "$GM_DIR/channel/node_modules" ]      && pass "channel deps installed (bun)"      || fail "channel node_modules missing"
# rendered channel must have no unresolved {{...}} placeholders
if grep -q '{{' "$GM_DIR/channel/taskyou-channel.ts"; then fail "unresolved {{placeholders}} in channel"; else pass "no unresolved placeholders"; fi
# LOCAL mode must be baked (SERVER_HOST=local)
grep -q 'IS_LOCAL' "$GM_DIR/channel/taskyou-channel.ts" && pass "local-mode branch present (PR #31)" || fail "local-mode branch absent"

# ── 2. Channel smoke test (PR #28's own test) ────────────────────────────────
echo; echo "[2] channel smoke-test (handshake + capabilities + tools)"
cp "$SRC/templates/channel/smoke-test.ts" "$GM_DIR/channel/smoke-test.ts"
if ( cd "$GM_DIR/channel" && bun run smoke-test.ts ) >"$SANDBOX/smoke.log" 2>&1; then
  pass "smoke-test PASSED"; sed 's/^/      /' "$SANDBOX/smoke.log"
else
  fail "smoke-test FAILED"; sed 's/^/      /' "$SANDBOX/smoke.log"
fi

# OS-correct hooks dir (where the macOS fix should land them)
if [[ "$(uname -s)" == "Darwin" ]]; then
  HOOKS_DIR="$SBX_HOME/Library/Application Support/task/hooks"
else
  HOOKS_DIR="$SBX_HOME/.config/task/hooks"
fi

# ── 3. Local server provisioning (setup_server_local) ────────────────────────
# Needs ty (local mode registers projects + relies on the daemon). When ty is
# absent (CI), skip provisioning and render the hook directly so step 4 — the
# notification chain, which needs no ty — can still run.
echo; echo "[3] setup.sh server — local mode (hooks + ty project, no SSH/systemd)"
if command -v ty >/dev/null 2>&1; then
  ( cd "$SRC" && ./setup.sh server "$GM_DIR" ) >"$SANDBOX/server.log" 2>&1 \
    && pass "setup.sh server (local) exited 0" \
    || fail "setup.sh server failed (see $SANDBOX/server.log)"

  [ -f "$HOOKS_DIR/task.completed" ] && pass "hooks installed to OS-correct dir: $HOOKS_DIR" || fail "hooks not in expected dir: $HOOKS_DIR"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    [ -f "$SBX_HOME/.config/task/hooks/task.completed" ] && fail "hooks wrongly in ~/.config on macOS (the bug PR#31 fixes)" || pass "hooks NOT mis-placed in ~/.config (macOS fix works)"
  fi
  [ -f "$SBX_HOME/notifications.jsonl" ] && pass "notifications.jsonl created" || fail "notifications.jsonl missing"
  HOME="$SBX_HOME" ty projects show qa-test >/dev/null 2>&1 && pass "ty project 'qa-test' registered in SANDBOX ty" || fail "ty project not registered"
  [ -f "$SBX_HOME/.local/share/task/tasks.db" ] && pass "sandbox ty db is separate from real ~/.local/share/task" || echo "  · (sandbox ty db not found — check ty data layout)"
else
  echo "  · ty not on PATH (CI mode) — skipping ty provisioning; rendering hook directly"
  mkdir -p "$HOOKS_DIR"
  sed "s#{{SERVER_HOME}}#$SBX_HOME#g" "$SRC/templates/hooks/task.completed.tmpl" > "$HOOKS_DIR/task.completed"
  chmod +x "$HOOKS_DIR/task.completed"
  touch "$SBX_HOME/notifications.jsonl"
  [ -f "$HOOKS_DIR/task.completed" ] && pass "hook rendered to OS-correct dir: $HOOKS_DIR" || fail "hook render failed"
fi

# ── 4. Notification end-to-end (hook → file → channel push) ──────────────────
# Two modes: steady-state (skip backlog, deliver next) and cold-start (deliver
# the very first event from an empty file — the regression test for the fix).
for mode in steady cold; do
  echo; echo "[4:$mode] channel notification e2e (real hook → channel push)"
  : > "$SBX_HOME/notifications.jsonl"   # reset file between modes
  MODE="$mode" \
  CHANNEL_TS="$GM_DIR/channel/taskyou-channel.ts" \
  NOTIF_FILE="$SBX_HOME/notifications.jsonl" \
  HOOK_SCRIPT="$HOOKS_DIR/task.completed" \
    bun run "$REPO_ROOT/qa/channel-notify-test.ts" >"$SANDBOX/notify-$mode.log" 2>&1 \
    && pass "notification e2e ($mode) PASSED" \
    || fail "notification e2e ($mode) FAILED"
  sed 's/^/      /' "$SANDBOX/notify-$mode.log"
done

# ── Summary ──────────────────────────────────────────────────────────────────
echo; hr
echo "  RESULT: $PASS passed, $FAIL failed"
hr
[ "$FAIL" -eq 0 ]
