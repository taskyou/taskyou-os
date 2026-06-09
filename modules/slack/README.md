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
  classifies intent (Anthropic API if `ANTHROPIC_API_KEY` is set, otherwise a
  built-in keyword heuristic), and runs the matching `ty` command. Replies go
  in-thread.

The bridge is **dependency-free** — raw `fetch` to the Slack and Anthropic HTTP
APIs plus the global `WebSocket` (Node 22+). No `npm install`, mirroring the
Linear poller.

## Setup

1. Create a Slack app (https://api.slack.com/apps).
   - **Socket Mode:** on. Generate an app-level token with `connections:write`
     → `SLACK_APP_TOKEN` (`xapp-…`).
   - **Bot token scopes:** `chat:write`, `app_mentions:read`, `im:history`,
     `channels:read` → install to workspace → `SLACK_BOT_TOKEN` (`xoxb-…`).
   - **Event Subscriptions:** subscribe to bot events `app_mention` and
     `message.im`.
   - Invite the bot to the channel(s) you want it to watch / post in.
2. Fill in the Slack section of `config.env` (see `config.example.env`).
3. `./setup.sh server <project-dir>` (or `exe`). This installs the bridge to
   `~/scripts/slack/`, writes `~/scripts/slack/.env`, and enables the
   `ty-slack` systemd service.

## Config

| Variable | Purpose |
|----------|---------|
| `SLACK_ENABLED` | `true` to install the module |
| `SLACK_BOT_TOKEN` | `xoxb-…` bot token |
| `SLACK_APP_TOKEN` | `xapp-…` app token (Socket Mode). Omit to run **outbound-only** |
| `SLACK_NOTIFY_CHANNEL` | channel for task pings not tied to a Slack thread (e.g. `#taskyou`) |
| `SLACK_ALLOWED_USERS` | comma-separated Slack user IDs allowed to drive `ty` |
| `SLACK_PROJECT_MAP` | JSON map of Slack channel → ty project, e.g. `{"#eng":"workflow"}` |
| `SLACK_ANTHROPIC_API_KEY` | optional — enables LLM intent classification |
| `SLACK_CLASSIFIER_MODEL` | classifier model (default `claude-haiku-4-5-20251001`) |

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
  shells out to `ty`. Pair with `nono` (`NONO_ENABLED`) for executor credential
  isolation.
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
