#!/usr/bin/env bash
# taskyou-os SessionStart hook (shipped by the plugin, so it reaches GMs that
# already exist once they update the plugin).
#
# Nudges a GM that predates the task-event channel to run /gm-doctor. It is:
#   - SCOPED: only acts inside a rendered taskyou-os GM directory.
#   - SELF-DISABLING: silent once the channel is deployed.
# Output: an `additionalContext` JSON object (exit 0) ONLY when the nudge
# applies; otherwise no output. The GM reads the note and surfaces it to the
# user conversationally.

set -uo pipefail

# SessionStart delivers JSON on stdin including `cwd`; prefer it, fall back to $PWD.
input="$(cat 2>/dev/null || true)"
cwd="$PWD"
if [ -n "$input" ] && command -v python3 >/dev/null 2>&1; then
  parsed="$(printf '%s' "$input" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("cwd",""))
except Exception: print("")' 2>/dev/null)"
  [ -n "$parsed" ] && cwd="$parsed"
fi

# Only act in a taskyou-os GM directory (rendered config + wrapper present).
[ -f "$cwd/config.env" ] || exit 0
grep -q '^GM_ALIAS=' "$cwd/config.env" 2>/dev/null || exit 0
[ -f "$cwd/bin/ty-remote" ] || exit 0

# Channel already deployed? Stay silent.
if [ -f "$cwd/channel/taskyou-channel.ts" ] && [ -f "$cwd/.mcp.json" ]; then
  exit 0
fi

note='This taskyou-os GM does not have the task-event channel installed yet. Push notifications — task completed/blocked events that arrive automatically in this session instead of via a polling agent — are available in this plugin version. Briefly let the user know, once, that they can enable it by running /gm-doctor (it deploys the channel and updates the launch alias; the GM must then be restarted). If the user declines, do not bring it up again this session.'

if command -v python3 >/dev/null 2>&1; then
  printf '%s' "$note" | python3 -c 'import sys,json; print(json.dumps({"additionalContext": sys.stdin.read()}))'
else
  printf '%s\n' "$note"
fi
exit 0
