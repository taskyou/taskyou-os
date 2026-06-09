# Slack module

Manage TaskYou from Slack. A two-way bridge: task events get pushed into Slack,
and Slack messages drive the `ty` CLI.

```
Slack @mention / DM ─▶ slack-bridge ─▶ classify intent ─▶ ty create/execute/input
notifications.jsonl ─▶ slack-bridge ─▶ chat.postMessage  (blocked / completed / failed)
```

It runs on the agents server next to `ty` and `notifications.jsonl`, installed
as the `ty-slack` systemd user service. Enable with `SLACK_ENABLED=true` in
`config.env`, then `./setup.sh server <project-dir>`.

## How it works

- **Outbound.** The bridge tails `notifications.jsonl` (the same file the
  `task.blocked` / `task.completed` hooks and the Claude Code channel use) and
  posts each event to Slack. Events for tasks that were created/run from Slack
  go back into their originating thread; everything else goes to
  `SLACK_NOTIFY_CHANNEL`.
- **Inbound.** Slack **Socket Mode** (no public URL) delivers `app_mention` and
  DM events. The bridge checks the sender against `SLACK_ALLOWED_USERS`,
  classifies intent, and runs the matching `ty` command. Replies go in-thread.

**Classifier (no API key by default).** Intent classification prefers the on-box
`claude` CLI (`claude -p`) — the same already-authenticated tool the GM and
executors use, so no separate `ANTHROPIC_API_KEY` is needed. It falls back to the
Anthropic API if `SLACK_ANTHROPIC_API_KEY` is set, then to a dependency-free
keyword heuristic. Override with `SLACK_CLASSIFIER=claude|api|heuristic`.

The bridge is **dependency-free** — raw `fetch` to the Slack (and optional
Anthropic) HTTP APIs plus the global `WebSocket` (Node 22+). No `npm install`,
mirroring the Linear poller.

## Runaway / cost protection

Because classification spends tokens, the bridge is bounded on every axis:

- **No self-loop.** The bridge ignores its own posts and any bot/edited/system
  message (`bot_id` / `subtype` / `BOT_USER_ID`), so a reply can never trigger
  another classification.
- **`claude -p` is sandboxed per call:** `--strict-mcp-config --mcp-config {}`
  (no MCP servers) + `--disallowedTools …` (no Bash/Read/Write/…) keep it to a
  **single turn** with no agentic spiral; `--max-budget-usd` (default `0.05`) is
  a hard cost ceiling; plus a wall-clock timeout and capped output buffer. One
  attempt, no retry — on any failure it falls back.
- **Concurrency cap.** At most `SLACK_MAX_CONCURRENT` (default 3) classifications
  run at once; extra messages are politely declined, not queued — so a burst
  can't fan out into unbounded subprocesses or spend.
- **Slack-retry safe.** Envelopes are acked in <3s (stops Slack re-sending) and
  deduped by `event_id`.
- **Outbound rate cap.** The notifications poller posts at most
  `SLACK_MAX_NOTIFS_PER_POLL` (default 25) per tick and drains the rest later, so
  an abnormal flood can't storm Slack. A lost/corrupt state file skips the
  backlog rather than replaying history. Only complete lines are consumed (a
  half-written hook line is held for the next tick).

## Setup

1. **Create the app from the manifest.** https://api.slack.com/apps → *Create
   New App* → *From an app manifest* → pick your workspace → paste
   [`manifest.yaml`](manifest.yaml) → *Create*. (Pre-sets Socket Mode, the bot
   scopes, and the event subscriptions — no manual toggles.)
2. **Mint two tokens** (a manifest can't):
   - *Basic Information → App-Level Tokens → Generate* with `connections:write`
     → `xapp-…` (`SLACK_APP_TOKEN`).
   - *OAuth & Permissions → Install to Workspace* → copy the **Bot User OAuth
     Token** `xoxb-…` (`SLACK_BOT_TOKEN`).
3. **Run the wizard** for your GM:
   ```bash
   ./setup.sh slack ~/Projects/gms/<gm>
   ```
   It takes the two tokens, resolves your Slack user from your email (via the
   bot token), writes the `SLACK_*` block into that GM's `config.env`, and
   installs + enables the bridge (systemd on a server/exe.dev; rendered files on
   a local Mac). Leave the app token blank for **outbound-only** (pings, no
   inbound control).
4. **Invite the bot** to your notify channel in Slack: `/invite @taskyou`.

A few minutes, no hand-editing config or hunting for member IDs.

<details>
<summary>Manual setup (without the wizard)</summary>

Do steps 1–2, then put the `SLACK_*` block (see `config.example.env`) into the
GM's `config.env` yourself and run `./setup.sh server <gm>` (or `exe`).
`SLACK_ALLOWED_USERS` takes Slack **member IDs** (profile → More → Copy member ID).
</details>

## Config

| Variable | Purpose |
|----------|---------|
| `SLACK_ENABLED` | `true` to install the module |
| `SLACK_BOT_TOKEN` | `xoxb-…` bot token |
| `SLACK_APP_TOKEN` | `xapp-…` app token (Socket Mode). Omit to run **outbound-only** |
| `SLACK_NOTIFY_CHANNEL` | channel for task pings not tied to a Slack thread (e.g. `#taskyou`) |
| `SLACK_ALLOWED_USERS` | comma-separated Slack user IDs allowed to drive `ty` |
| `SLACK_PROJECT_MAP` | JSON map of Slack channel → ty project, e.g. `{"#eng":"workflow"}` |
| `SLACK_ANTHROPIC_API_KEY` | optional — use the Anthropic API instead of the on-box `claude` CLI |
| `SLACK_CLASSIFIER_MODEL` | classifier model (default `claude-haiku-4-5-20251001`) |
| `SLACK_CLASSIFY_BUDGET_USD` | hard `$`/call cap for `claude -p` (default `0.05`) |
| `SLACK_MAX_CONCURRENT` | max in-flight classifications (default `3`) |
| `SLACK_MAX_NOTIFS_PER_POLL` | max Slack posts per poll tick (default `25`) |

## Usage

- `@taskyou fix the checkout 500s and run it` — create a task (say “run it” to
  execute immediately).
- Reply in a task's thread — routed to `ty input <id>`.
- `@taskyou run task 312` — execute an existing task.
- `@taskyou status of 312` / `@taskyou what's on the board?` — status.

## Security

- **Allowlist by user ID** (`SLACK_ALLOWED_USERS`) — channel membership alone
  can't create or run tasks.
- **Socket Mode** uses an authenticated WebSocket; there's no inbound HTTP
  endpoint to expose or verify.
- **No code execution from chat** — the LLM only *classifies*; the bridge only
  shells out to `ty`.
- **Local secrets** — tokens live in `~/scripts/slack/.env` (chmod 600), never
  sent to the LLM.

## Run / debug

```bash
systemctl --user status ty-slack
tail -f ~/log/ty-slack.log

# run the unit tests for the pure logic
cd modules/slack && node --test
```

## Scope

Single bot, single operator/team (the `ty-email` model). Per-GM routing is out
of scope. The hosted/remote-MCP path (letting cloud "Claude in Slack" call
`taskyou_*` tools directly) is a separate, larger project — see
`docs/plans/2026-06-08-slack-module-design.md`.
