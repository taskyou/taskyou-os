# Slack module — manage TaskYou from Slack

> Status: **implemented** in this PR — see `modules/slack/` (`slack-bridge.mjs`,
> `README.md`, tests), `templates/ty-slack.service.tmpl`, and the `SLACK_*`
> wiring in `setup.sh` + `config.example.env`. This doc is the design rationale.
>
> Two refinements landed during build:
> 1. The bridge runs **on the agents server** (next to `ty` + `notifications.jsonl`),
>    so it reads the file and runs `ty` **directly** — no `runRemote()`/SSH. It's a
>    zero-dependency Node `.mjs` (matching the Linear poller) rather than bun/TS,
>    because the server has Node (bun is a GM-machine prereq).
> 2. Intent classification defaults to the **on-box `claude` CLI** (`claude -p`,
>    claude.ai login — no API key, the same primitive the GM/executors use), with
>    the Anthropic API as an optional fallback and a keyword heuristic last. The
>    CLI call is hardened against runaway spend: no MCP/tools (single turn),
>    `--max-budget-usd` cap, timeout; plus a concurrency cap, self-loop guards,
>    and an outbound rate cap. See "Runaway / cost protection" in
>    `modules/slack/README.md`. Outbound + inbound both shipped.
> Origin: TaskYou task #3723 — "Explore taskyou MCP sidecar extension for Slack"
> TL;DR: Add a **`modules/slack/`** integration. Now that the channels work
> (#28) and local/macOS support (#31) are **merged**, this is small: a Slack
> module is the merged `templates/channel/taskyou-channel.ts` with its two ends
> re-pointed — poll `notifications.jsonl` → `chat.postMessage` (out), and Slack
> message → classify → `runRemote("ty …")` (in). Net-new code = a Slack adapter
> + an LLM classifier. Ship outbound notifications first (a hook → Slack
> webhook), inbound control second. See §7.

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
  slack-bridge.ts           # poll notifications.jsonl + runRemote() (from the
                            #   channel, §8) + Slack adapter: ingest → ty → reply/notify
  AGENTS.md                 # how agents should talk to Slack (like linear-cli/AGENTS.md)
  .slack-state.json         # thread_ts ↔ task_id, processed ids, pending tasks
```

> Earlier framing was `slack-poll.mjs` mirroring `linear-poll.mjs`; §8 revises the
> template to the bun/TS channel so the two share `pollNotifications` +
> `runRemote`. A `.mjs` Linear-style poller remains a viable fallback.

`config.env` additions (mirroring the Linear block):

```bash
# === Optional: Slack integration ===
# Set SLACK_ENABLED=true to manage TaskYou from Slack
# SLACK_ENABLED="true"
# SLACK_BOT_TOKEN="xoxb-..."          # chat:write, app_mentions:read, im:history
# SLACK_APP_TOKEN="xapp-..."          # Socket Mode (recommended — no public URL)
# SLACK_NOTIFY_CHANNEL="#taskyou"     # where blocked/completed pings go
# SLACK_ALLOWED_USERS="U012ABC,U034DEF"   # only these Slack user IDs may drive ty
# SLACK_PROJECT_MAP='{"#eng":"workflow","#content":"content"}'  # Slack channel → ty project
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

The channels work (#28) and local/macOS support (#31) are now **merged to
`main`**, so this is no longer speculative — `templates/channel/taskyou-channel.ts`
is real code to copy, and a Slack module is **that channel with its two ends
re-pointed at Slack.**

1. **Build `modules/slack/slack-bridge.ts`** (bun/TS) by lifting two functions
   straight from the merged channel: `pollNotifications()` (cursor via
   `lastLineCount` + `tail -n +N` over `notifications.jsonl`) and `runRemote()`
   (the `IS_LOCAL` `bash -lc` vs SSH branch from #31). Then:
   - **Outbound:** in `pollNotifications`, replace "emit into the GM session"
     (`mcp.notification`) with `chat.postMessage` to Slack.
   - **Inbound:** Slack message → LLM classify intent → `runRemote("ty …")`
     (the same call `ty_command` already makes).
   The only genuinely new code is the **Slack adapter** (Socket Mode in/out) and
   the **LLM classifier** (lift from `ty-email/internal/classifier`).
2. **Defer Pattern B** (network-exposed MCP for cloud Claude-in-Slack) to a
   separate spike built on the credential-proxy design + workflow PR #402.

### Ship it in two phases

- **Phase 1 — outbound only (hours).** Extend the merged `task.blocked` /
  `task.completed` hook templates to `curl` a Slack incoming webhook. Delivers
  "ping me in Slack when a task blocks/finishes" with no new daemon.
- **Phase 2 — inbound control.** Add the Socket Mode bot + classifier so you can
  create / unblock / query tasks from Slack. Two-way bridge.

## 8. What the merged channel work (#28, #31) settles

Both are merged to `main`; the substrate is fixed code now, not a moving branch.

- **#28 — Claude Code channel for push events** (merged). `templates/channel/
  taskyou-channel.ts` polls `notifications.jsonl` (`pollNotifications()`,
  `lastLineCount` + `tail -n +N`) and exposes `ty_command` / `ssh_command` via
  `runRemote()`, replacing the old "background agent `tail -f`" approach.
  - *For Slack:* `notifications.jsonl` is the settled source of truth, and the
    **template to copy is `taskyou-channel.ts`** — reuse `pollNotifications()` +
    `runRemote()` verbatim. There's also a `smoke-test.ts` to model tests on.
  - *Terminology:* "channel" = *push into a Claude Code GM session*. Slack is a
    **chat surface for a human** — a different layer. Slack stays a **module**
    (a sibling consumer of `notifications.jsonl`), **not** a Claude Code channel,
    so it runs as its own daemon and **sidesteps #28's research-preview
    constraints** (`--dangerously-load-development-channels`, CC v2.1.80+,
    claude.ai-login-only).
- **#31 — local mode + macOS** (merged). `runRemote()` now has the `IS_LOCAL`
  (`bash -lc`) vs SSH branch, hooks install to the OS-correct dir
  (`~/Library/Application Support/task/hooks` on macOS), and `setup_server_local()`
  creates `notifications.jsonl`.
  - *For Slack:* reuse `runRemote()` as-is — the bridge runs identically whether
    the daemon is on the same Mac or a remote Linux box. Rely on setup having
    created `notifications.jsonl`; don't hardcode paths.

*(Per-GM scoping / `assigned_gm` is out of scope: a single bot for a single
operator, like `ty-email`. Routing by GM is not needed here.)*

## 9. Open questions for Bruno

- **Socket Mode vs Events API:** recommend **Socket Mode** — no public URL, works
  identically on the exe.dev VM or a local Mac (#31). Events API only if we later
  want an always-on shared bot with an HTTPS endpoint.
- **Also pursue Pattern B?** Do we want the *existing* cloud Claude-in-Slack to
  call `taskyou_*` tools directly (remote MCP), or is a dedicated TaskYou bot
  enough? (I'd say bot first, Pattern B later.)
