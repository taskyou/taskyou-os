# Slack module — manage TaskYou from Slack

> Status: design / recommendation (not yet implemented)
> Origin: TaskYou task #3723 — "Explore taskyou MCP sidecar extension for Slack"
> TL;DR: Add a **`modules/slack/`** integration that mirrors `modules/linear/` —
> watch a Slack channel/DM/@mention, classify intent, drive `ty`, post replies,
> and push `task.blocked`/`task.completed` notifications back. We've already
> built this exact pattern twice (the Linear poller here, and `ty-email` in the
> workflow repo), so this is mostly copy-adapt-configure.

---

## 1. What prompted this

A Slack thread in `#product`: Bruno asks the cloud "Claude in Slack" integration
whether it can reach the TaskYou agents server. It can't —

> "that's a separate integration running in your Slack workspace — not something
> I can access from this remote execution environment."

So from Slack there's no way to see, create, or unblock TaskYou tasks. This doc
asks whether TaskYou-OS should close that gap, and how.

## 2. Prior art — we've built this twice already

| What exists | Where | Relevance |
|---|---|---|
| **Linear poller** (`linear-poll.mjs`) | `modules/linear/` (this repo) | **The template.** Polls Linear for `@agent` comments → `ty create/execute` → routes to projects by issue label → **posts diffs/results back** as Linear comments. State in `.linear-poll-state.json`, `LINEAR_TOKEN` auth, `.auth-failed` graceful degradation. A Slack module is a near-exact analog. |
| **`notifications.jsonl`** + hooks (`templates/hooks/task.{blocked,completed,started}.tmpl`) | this repo | The push substrate. Each hook appends a JSON event the GM already tails. A Slack module tails the same file → `chat.postMessage`. |
| **`ty-email` sidecar** (PR #371/#385) | `bborn/taskyou → extensions/ty-email` | The standalone-Go version of the same idea: email → LLM classify intent → `ty` CLI → reply/notify. A clean alternative template (adapter + classifier + bridge + state). |
| Module convention | `config.env` flags (`LINEAR_ENABLED`, `R2_ENABLED`, `GITHUB_REPOS`, `NONO_ENABLED`) | Modules ship in-repo and toggle via env. A Slack module follows suit with `SLACK_ENABLED`. |

There is **no** existing Slack control surface. The only "Slack" in the workflow
repo is marketing copy (PR #433 / task #1172), not an integration. So this is
low-risk: the architecture is proven, only the adapter is new.

## 3. Two readings of "Slack integration"

The screenshot depicts the *harder* one; we should ship the easier, higher-value
one first.

### Pattern A — chat → TaskYou control bridge — RECOMMENDED

DM or @-mention a bot; it classifies intent, drives `ty`, replies in-thread, and
pings you when a task needs input or finishes. The literal analog of both the
Linear poller and `ty-email`.

```
Slack user ──@mention/DM──▶ Slack (Socket Mode / Events API)
                                   │
                                   ▼
                            ┌──────────────┐
                            │ modules/slack│──▶ LLM classify intent
                            │  (poll/socket)──▶ ty CLI (or ty serve API)
                            │              │──▶ chat.postMessage (reply)
                            └──────────────┘
                                   ▲
              notifications.jsonl (task.blocked / completed) ──┘  push
```

### Pattern B — hosted/remote MCP endpoint (what the screenshot literally shows)

The cloud "Claude in Slack" wants to call `taskyou_*` MCP tools directly, but
TaskYou's MCP server (`internal/mcp/server.go` in the workflow repo) is
**stdio-only** — spawned per-task by Claude Code via `.mcp.json`
(`ty mcp-server --task-id`), not network-reachable. Letting a remote Claude use
it needs a **network-exposed, authenticated MCP server** (HTTP/SSE) wrapping the
`ty serve` REST API. This overlaps directly with the **credential-proxy design**
(`docs/plans/2026-03-11-credential-proxy-design.md`) and the Cloudflare Code Mode
MCP review (workflow PR #402). Defer — it's an infra/security project, not a
module.

## 4. Why Pattern A is cheap: every piece exists

1. **A working channel-bridge template** — `modules/linear/linear-poll.mjs` already
   does detect → `ty create` → route by label → `ty execute` → post results back.
   Swap "Linear comment" for "Slack message" and the Linear CLI for
   `chat.postMessage`.
2. **Intent classification** is solved in `ty-email/internal/classifier` (direct
   Claude API call, no permission prompts). Reuse the approach.
3. **Action surface** — the `ty` CLI (what both precedents use) or the `ty serve`
   HTTP API (`/api/tasks`, `/tasks/{id}/input`, `/execute`, `/logs`, `/stream`
   SSE, `/board`) if the module runs off-box from the daemon.
4. **Push is already aggregated** — `notifications.jsonl` is a single tail-able
   stream of "needs attention" events. Tail it → `chat.postMessage`. "Ping me in
   Slack when a task blocks/finishes" comes almost free, and the GM keeps using
   the same file.

Genuinely new code: a Slack **adapter** (Socket Mode or Events API +
`chat.postMessage`), thread↔task state (mirror `.linear-poll-state.json`), and a
config block.

## 5. Proposed shape

```
modules/slack/
  slack-poll.mjs            # mirrors linear-poll.mjs: ingest → ty → reply/notify
  AGENTS.md                 # how agents should talk to Slack (like linear-cli/AGENTS.md)
  .slack-poll-state.json    # thread_ts ↔ task_id, processed ids, pending tasks
```

`config.env` additions (mirroring the Linear block):

```bash
# === Optional: Slack integration ===
# Set SLACK_ENABLED=true to manage TaskYou from Slack
# SLACK_ENABLED="true"
# SLACK_MODE="socket"                 # socket (no public URL) | events (needs HTTPS)
# SLACK_BOT_TOKEN="xoxb-..."          # chat:write, app_mentions:read, im:history
# SLACK_APP_TOKEN="xapp-..."          # socket mode
# SLACK_SIGNING_SECRET="..."          # events mode
# SLACK_NOTIFY_CHANNEL="#taskyou"     # where blocked/completed pings go
# SLACK_ALLOWED_USERS="U012ABC,U034DEF"   # only these Slack user IDs may drive ty
# SLACK_PROJECT_MAP='{"#eng":"workflow","#content":"content"}'  # channel → project
```

### Interaction examples

- `@taskyou fix the checkout 500s and run it` → creates + executes a task, replies
  in-thread with the task id and a board link.
- Task blocks → module reads `task.blocked` from `notifications.jsonl` → posts
  *"Task #312 needs input: which migration strategy?"* to the channel. Reply
  in-thread → routed to `ty input 312 …`.
- `@taskyou what's happening with 312?` → posts recent `ty output 312`.

## 6. Security (same model as the Linear module)

- **Allowlist by Slack user ID** (`SLACK_ALLOWED_USERS`) — channel membership is
  not enough to create/execute tasks.
- **Verify authenticity** — Slack signing-secret check (Events API) or Socket
  Mode's authenticated socket; never act on unverified payloads.
- **No code execution from chat** — the LLM only *classifies*; the module only
  calls `ty` subcommands. Pair with `nono` (`NONO_ENABLED`) for executor
  credential isolation.
- **Local secrets** — bot/app tokens in `config.env` (like `LINEAR_TOKEN`), never
  sent to the LLM. `.auth-failed`-style degradation keeps polling alive when
  tokens lapse, as the Linear module already does.

## 7. Recommendation

1. **Build Pattern A as `modules/slack/slack-poll.mjs`**, closely modeled on
   `modules/linear/linear-poll.mjs`, enabled via `SLACK_ENABLED=true`, tailing
   `notifications.jsonl` for push.
2. **Defer Pattern B** (network-exposed MCP for cloud Claude-in-Slack) to a
   separate spike built on the credential-proxy design + workflow PR #402.
3. The **"ping me in Slack"** half can ship immediately: extend the
   `task.blocked`/`task.completed` hook templates (or a tiny tail of
   `notifications.jsonl`) to POST to a Slack incoming webhook — independent of the
   full bridge.

## 8. Open questions for Bruno

- **Shared bot vs per-user:** one workspace bot (multi-user routing + per-user
  allowlists become the main design work) vs. a personal bot per operator like
  `ty-email`?
- **Socket Mode vs Events API:** Socket Mode needs no public URL (simplest on the
  exe.dev VM / agent server); Events API suits an always-on shared bot but needs
  an HTTPS endpoint.
- **Also pursue Pattern B?** Do we want the *existing* cloud Claude-in-Slack to
  call `taskyou_*` tools directly (remote MCP), or is a dedicated TaskYou bot
  enough?
