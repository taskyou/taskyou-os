# QA harness

Hermetic, non-destructive end-to-end tests for the GM system that `setup.sh`
generates. It runs the **real** `setup.sh` against a throwaway `$HOME` and a git
worktree of a branch, then exercises the task-event channel all the way through.

It never touches your real `~/.local/share/task`, `~/Library/Application Support/task`,
`~/.gitconfig`, your GMs, or your running daemon — everything keys off a sandbox
`$HOME`, which is removed on exit.

## Run

```bash
qa/run-qa.sh            # tests the current checkout (HEAD)
qa/run-qa.sh pr-31      # tests a specific local branch/ref
```

Requires `bun` and `python3`. `ty` is optional — when it's absent (CI), the ty
project-registration assertions are skipped; render + smoke + notification
checks still run.

## What it covers

1. **`setup.sh local`** — renders the GM + channel; asserts files, deps, alias
   flag, no unresolved `{{placeholders}}`.
2. **Channel smoke test** — MCP handshake, capabilities, and tool list
   (`templates/channel/smoke-test.ts`).
3. **`setup.sh server` (local mode)** — hooks land in the OS-correct dir
   (the macOS `~/Library/Application Support` fix), `notifications.jsonl` is
   created, and the project registers in the *sandbox* ty.
4. **Notification e2e** — fires the real `task.completed` hook and asserts the
   channel pushes a matching `notifications/claude/channel` event. Two modes:
   - `steady` — pre-existing backlog is **not** replayed, next event delivered.
   - `cold` — first event after an **empty-file** start **is** delivered
     (regression test for the cold-start fix).

CI runs this on every PR touching `setup.sh`, `templates/channel`,
`templates/hooks`, or `qa/` (see `.github/workflows/qa.yml`).
