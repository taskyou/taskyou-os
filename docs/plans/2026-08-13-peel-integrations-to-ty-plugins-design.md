# Peel taskyou-os server integrations into ty plugins — spec review & revised plan

**Date:** 2026-08-13
**Reviews:** the "peel taskyou-os server integrations into ty plugins (start with Slack)" spec
**Verdict:** **Ship v1 as scoped.** The core thesis is right and the gating is honest. Three
corrections and four additions below; one of them (§3.1) is a duplicate-message bug in the v1
plan as written.

Everything here is checked against the code in this repo and against the **installed `ty`
binary (0.3.21)**, not against the spec's description of ty.

---

## 1. What the review confirmed

The spec's factual claims about ty hold up. From `ty 0.3.21`:

| Spec claim | Status |
|---|---|
| `services:` capability exists | ✅ Binary contains `Started plugin services`, `plugin service started`, `plugin service stopping`, `plugin service failed to start` |
| `TY_DB_PATH` / `TY_API_URL` injected | ✅ Both present |
| Supervisor has **no log capture** | ✅ No `service.log` / `service exited` strings |
| Supervisor has **no restart/backoff** | ✅ No `backoff` / `restarting` strings |
| `ty plugins add` is unpinned clone + `git pull` | ✅ `add --help`: "Re-running add on the same plugin updates it in place with git pull". No `--ref`. |
| `setup.sh` has no min-ty-version gate | ✅ `curl -fsSL https://taskyou.dev/install.sh \| bash` (L746, L971) |
| `ty routines schedule --every 2m` exists | ✅ `--every duration` / `--cron` → launchd plist or tagged crontab line |

And in this repo:

- `setup_slack_remote` (L387–441) is 55 lines ending in **warn-and-continue** on
  `systemctl --user enable` failure (L432–433). A silently dead bridge is a supported outcome —
  as claimed.
- `setup_slack_local` (L446–474) ends at "start it with `node …` (or a launchd agent)" — local
  mode is genuinely unsupervised.
- The bridge **is restart-safe**, which the spec doesn't state but which the whole plan depends
  on: `.slack-state.json` persists `notifyOffset` and the thread↔task maps, the offset advances
  *before* posting (L655: "so a failed post never re-storms"), and a lost state file resets the
  offset to EOF rather than replaying history (L634). Moving to a supervisor that restarts more
  often is therefore safe. Good.

**So: the three v1 gates are real and correctly identified.** Nothing below undermines the plan;
it sharpens it.

---

## 2. Corrections

### 2.1 `linear-poll` is not a routine. Drop the "Periodic jobs = routines" section.

This is the one materially wrong claim in the spec.

`ty routines --help`, verbatim:

> Routines are named, unattended **agent runs**: a `prompt.md` (plus optional `env.sh` for
> secrets/fail-fast checks) in `~/.config/task/routines/<name>/`.

A routine is an LLM agent run. `linear-poll.mjs` is 347 lines of deterministic GraphQL: a
cursor (`lastChecked`), a dedup set (`processedCommentIds`), a `pendingTasks` queue, and
`execSync` calls to `ty` and the `linear` CLI. Those are not the same primitive.

The spec says converting it would be "not a rewrite." It is exactly a rewrite, and into a worse
shape:

- **Cost.** `--every 2m` = **720 agent runs per day, per GM**. Bruno runs several GMs. That is a
  real recurring bill to replace a free `node` process.
- **Determinism.** A cursor + a seen-set becomes "an agent decides which comments it already
  handled." The failure mode is duplicate Linear replies and duplicate ty tasks — silent, and
  charged for.
- **Latency/timeout.** Default 30m timeout on a job that runs every 2m.

The spec's own "What does NOT move" section already reaches the right answer ("`linear-poll` — it's
a cron job… Defer"). The routines section then contradicts it by supplying a migration path.
Delete the section. If you later want ty to own linear-poll, the honest ask is the
**`timers:`/scheduled-command capability the spec ruled out** — a scheduled *command*, not a
scheduled *agent*. That is a separate decision, and not one v1 needs.

Note the secondary irony: `ty routines schedule` explicitly **"captures your current PATH so the
agent can find ty, claude"**. Routines solved the PATH problem. Plugin services have not — see
§3.2.

### 2.2 `ty plugins remove` already exists — the v2 gate is smaller than stated

The spec gates v2 on the CLI growing "**ref pinning** and **remove/disable**." `remove` shipped:
`ty plugins remove` — "Uninstall a plugin by deleting its directory." The outstanding v2 gates are
**`--ref` pinning** and **per-plugin disable**. Doesn't change the recommendation to defer v2, but
it's one less thing to build.

### 2.3 "Deletes the worst code in setup.sh" oversells the migration

The worst behavior — warn-and-continue on a failed bridge install — is a **two-line fix you can
ship today**, independent of any of this. Don't let a multi-release migration be the vehicle for
it. Fix the failure mode now (§5, step 0); migrate for the reasons that actually require
migrating: one supervision model, local == remote, no lingering.

Ranking the stated justifications by how much weight they can actually bear:

- **Strong:** local mode gets supervision for free; one supervisor instead of systemd-user +
  lingering; no `loginctl enable-linger` dependency.
- **Medium:** best available dogfood for `services:` — you will find the supervisor's gaps, which
  is worth something on its own.
- **Weak (defer-dependent):** "makes the integration reusable & reviewable" — that's v2, which
  the spec correctly defers. It can't justify v1.

---

## 3. Additions — things v1 needs that the spec doesn't have

### 3.1 The migration must remove the old systemd unit, or existing GMs post everything twice

**This is a bug in the v1 plan as written.** Every GM already running has
`~/.config/systemd/user/ty-slack.service` enabled and a bridge at `~/scripts/slack/` with its own
`.slack-state.json`. v1 installs a *second* bridge under `~/.config/task/plugins/slack/` with a
*separate* state file. Result:

- Both tail `~/notifications.jsonl` from independent offsets → **every task notification posts to
  Slack twice.**
- Both open Socket Mode connections for the same app → Slack load-balances inbound events across
  them, so `@taskyou` commands land in whichever bridge, and the thread↔task map splits across
  two state files. Thread replies start going to the wrong place.

v1 must, before installing the plugin:

```sh
systemctl --user disable --now ty-slack 2>/dev/null || true
rm -f ~/.config/systemd/user/ty-slack.service
systemctl --user daemon-reload
```

…and should carry `~/scripts/slack/.slack-state.json` over to the plugin dir (or accept one
offset reset — which is safe, it resets to EOF, but loses the thread map). Local mode needs the
equivalent: the operator may have a hand-rolled launchd agent or a bare `node` in a tmux pane;
setup.sh can't kill that, so **print an explicit "stop your existing bridge" instruction** in
local mode.

### 3.2 `command: node ./slack-bridge.mjs` will fail to find node on the server

`setup_slack_remote` resolves node deliberately:

```sh
node_bin=$(ssh "$ssh_target" "bash -lc 'command -v node'")   # L421
```

…and bakes the absolute path into `ExecStart` (`{{NODE_BIN}}`), with the comment "so systemd's
minimal PATH still finds it." That workaround exists because it was needed.

`ty-daemon.service` sets:

```
Environment="PATH=%h/bin:%h/.local/bin:%h/.npm-global/bin:/usr/local/bin:/usr/bin:/bin"
```

That does **not** include the asdf node path that setup.sh's own `remote_with_path` relies on
(`/home/deploy/.asdf/installs/nodejs/24.13.0/bin`, L167). A plugin service spawned by the daemon
inherits the daemon's environment. So on an asdf box, `command: node ./slack-bridge.mjs` →
`plugin service failed to start` → and with today's supervisor, **no log line saying why**.
That's the exact silent-death failure v1 is supposed to eliminate, reintroduced through a
different door.

Same applies to `CLAUDE_BIN` (defaults to bare `claude`, used by the classifier) and `TY_PATH`
(the .env sets it absolute — fine).

**Cheapest fix, no ty change and `plugin.yaml` stays a static file:** `%h/bin` *is* on the
daemon's PATH, so have setup.sh symlink the resolved node into it:

```sh
ssh "$ssh_target" "mkdir -p $remote_home/bin && ln -sf '$node_bin' $remote_home/bin/node"
```

Alternatives, both worse for v1: make `plugin.yaml` a `.tmpl` rendered with `{{NODE_BIN}}` (kills
the "scp the checkout verbatim" property, and means the plugin dir can never become a real repo),
or ask ty to expand `.env` vars in `command:` (a new ty feature on the critical path).

**Add this as gate #0.** It's a setup.sh-side fix, so it doesn't block on a ty release — but v1 is
broken without it.

### 3.3 Supervision coupling is a real trade, not a pure win

Today `ty-slack.service` is a **sibling** of `ty-daemon.service` — `After=` + `Wants=`, not
`PartOf=`. The bridge survives daemon restarts and vice versa. Under `services:` the bridge becomes
a **child** of the daemon: every daemon restart drops the Socket Mode WebSocket and the
notification tail. And restart frequency goes *up*, because setup.sh re-runs restart the daemon and
`curl | bash` pulls latest ty.

You are also stacking two supervisors (systemd supervises the daemon; the daemon supervises the
bridge) where you had one battle-tested one.

This is **acceptable** — the bridge is restart-safe (§1), so the cost is seconds of downtime, not
duplicates — but it should be written down as the price rather than framed as free. One residual
gap worth a line in the code: `seenEvents` (Slack retry dedup, L455) is **in-memory only**. More
restarts ⇒ slightly higher odds that a Slack event retry straddling a restart gets handled twice
(e.g. a duplicate task created from one `@taskyou` message). Low frequency, but persisting the
last N event IDs into `.slack-state.json` is ~5 lines and removes the class.

### 3.4 Config and state live *inside* the code directory — fine for v1, disqualifying for v2

Both `.env` and `.slack-state.json` sit next to `slack-bridge.mjs` (`join(__dirname, …)`). Under
v1's scp drop-in that's fine — scp doesn't delete, so both survive re-runs.

Under **v2** (`ty plugins add` = git clone, update = `git pull`) the plugin dir is a git working
tree, and putting untracked secrets + mutable state inside it is fragile: `git pull` can conflict
if the upstream repo ever adds those paths, `git clean` wipes both, and the secret is one
`git status` away from a screenshot.

This answers Open Decision #2 cleanly: **bless `.env`-in-dir as the v1 convention (zero work,
both modules already do it), and make "config + state outside the checkout" a hard prerequisite of
v2, not a nice-to-have.** Deferring costs nothing because v1 never `git pull`s.

---

## 4. Answers to the five open decisions

**1. Supervisor hardening before v-next, or dual-path?**
**Block on the ty release. Do not build dual-path.** Dual-path means keeping
`ty-slack.service.tmpl`, the lingering dance, *and* the plugin path, plus a version probe to
choose — i.e. you carry the code you're migrating to delete, and you double the QA matrix in
`qa/run-qa.sh` forever. The gates are small and they're yours to land. Ship step 0 (§5) so the
current path stops failing silently in the meantime; that removes the urgency that would otherwise
argue for dual-path.

**2. Secrets contract: `.env` in the plugin dir, or `ty plugins config`?**
**`.env` in the dir for v1. `ty plugins config` (or any out-of-checkout store) as a v2 gate** —
see §3.4. Add `.env` and `.slack-state.json` to a `.gitignore` inside `modules/slack/` now, so the
directory is already safe to become a repo later.

**3. Is "restart the daemon" acceptable for a token change?**
**Yes for v1.** Token rotation is rare (measured in months), and the daemon restart is the same
blast radius you already accept on every `setup.sh` re-run. Executors are tracked in the DB, not in
daemon memory. Don't put `ty plugins restart <name>` on the critical path — but do put it in v1.1,
because the moment the bridge dies you'll want to bounce *it* rather than the box's brain.

**4. Min-ty-version gate in setup.sh.**
**Do both, in this order: a numeric `ty --version` fail-fast, then an outcome check.** The version
compare is the guard (fail loudly with "Slack needs ty ≥ X.Y.Z; run `curl … install.sh | bash`"),
and the outcome check is what actually proves it worked — mirroring what setup.sh does today with
`systemctl --user is-active`:

```sh
ty plugins list | grep -q 'slack.*running' || die "slack service did not start; check <log>"
```

That outcome check is precisely why **gate #3 (status in `ty plugins list`) is the most valuable of
the three gates, not the least** — it's the only one setup.sh can act on. Reorder the gates:
**status → log capture → restart/backoff.** Status unblocks setup.sh, log capture makes failures
diagnosable, restart is the smallest real-world win because a bridge that crashes at init (rotated
token) will just crash-loop anyway — what you actually need there is the log.

**5. Collection semantics: per-plugin opt-in for `services:` in v2?**
**Yes.** A hook runs on an event you already triggered; a service is a process the daemon starts on
its own, holding `TY_DB_PATH` and API access, from an unpinned default-branch HEAD. That's a
different trust bar, and "installing a collection silently started five processes" is the kind of
thing you only get to discover once. Make it explicit opt-in at install time. But note this is a
**v2 question and v1 must not wait on it** — v1 is a local directory copy, not an install from
anywhere.

---

## 5. Revised sequence

**Step 0 — ship this week, independent of everything (≈1 hour).**
Make `setup_slack_remote` fail loudly instead of warn-and-continue (L432–439). This is the actual
worst failure mode in the repo and it does not need a migration to fix. Also add
`modules/slack/.gitignore` for `.env` + `.slack-state.json` (§3.4) and persist `seenEvents` into
the state file (§3.3).

**Step 1 — ty supervisor gates, in this order (§4.4).**
1. Status + pid in `ty plugins list` — unblocks setup.sh's outcome check.
2. stdout/stderr → `~/.config/task/plugins/<name>/service.log`.
3. Restart-on-exit with backoff.
Cut a ty release. Note its version — that's the number `setup.sh` gates on.

**Step 2 — taskyou-os v1: Slack as an in-repo drop-in plugin.**
As specced, plus the three additions:
- `modules/slack/plugin.yaml` (static, not a template).
- setup.sh: `ln -sf $node_bin ~/bin/node` **before** the daemon restart (§3.2).
- setup.sh: disable + delete `ty-slack.service`, migrate `.slack-state.json`, and print a
  stop-your-old-bridge notice in local mode (§3.1).
- setup.sh: `ty --version` fail-fast + `ty plugins list` outcome check (§4.4).
- Delete `templates/ty-slack.service.tmpl`, the lingering dance, and the local-mode
  "start it yourself" warning.
- Extend `qa/run-qa.sh` to cover: fresh install, **upgrade from a GM that already has
  `ty-slack.service`** (the §3.1 case — this is the one that can regress live GMs), and local mode.

**Step 3 — v1.1.** `ty plugins restart <name>`.

**Step 4 — v2 gates.** `ty plugins add --ref`, per-plugin `disable`, out-of-checkout config/state,
per-plugin opt-in for `services:` in collection installs. *Then* extract to `taskyou/plugins`.

**Step 5 — `notifications.jsonl` → plugin `hooks:` / SSE.** Separately. The spec's
"one variable at a time" instinct is right; hold it.

**Dropped from the sequence:** the Linear/routines migration (§2.1). `linear-poll` stays a cron
job. Revisit only if ty grows a scheduled-*command* primitive, and treat that as its own decision.

---

## 6. One-paragraph summary

The spec is sound and the gating is honest — ship it. Three corrections: `linear-poll` cannot
become a routine (routines are *agent* runs; converting a 347-line deterministic poller into a
prompt firing 720×/day per GM is a rewrite into a worse, metered shape — drop that section),
`ty plugins remove` already exists so the v2 gate is just pinning + disable, and the "deletes the
worst code" argument oversells a two-line fix you should ship this week regardless. Three
additions v1 needs: **it must disable and delete the old `ty-slack.service`, or every existing GM
runs two bridges and posts every notification to Slack twice**; `command: node ./slack-bridge.mjs`
will not find node under the daemon's minimal PATH (symlink the resolved node into `~/bin`, which
is already on that PATH); and moving the bridge from systemd sibling to daemon child is a real
coupling trade — acceptable only because the bridge is verifiably restart-safe. On the open
decisions: block on the ty release rather than building dual-path, keep `.env`-in-dir for v1 but
make out-of-checkout config a hard v2 gate, accept daemon-restart for token changes, gate on
`ty --version` *and* a `ty plugins list` outcome check, and yes — require per-plugin opt-in for
`services:` in v2 collection installs. Reorder the three ty gates to **status → logs → restart**:
status is what `setup.sh` can actually act on, and a crash-at-init bridge needs a log more than it
needs a retry.
