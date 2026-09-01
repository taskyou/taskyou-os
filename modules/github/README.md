# GitHub module — budget-aware polling

Zero-dependency helpers for anything that talks to GitHub from a cron job.
They exist because a GM poller exhausted the shared GraphQL budget and took
three boxes down with it.

## What went wrong (and what these files prevent)

- **REST and GraphQL are separate buckets** (5,000 req/hr vs 5,000 pts/hr), and
  each bucket is **per user, not per token**. Three boxes holding three
  different tokens that all authenticate as the same GitHub user share *one*
  budget. Verified empirically: a single GraphQL query from a laptop dropped a
  server's counter from 5000 to 0.
- **`gh pr list` / `gh pr view` are GraphQL. `gh api repos/…` is REST.**
- **Asking for `mergeable` in a list query is the expensive mistake.** That
  field makes GitHub compute a merge commit for every PR in the list. Doing it
  across 40 open PRs on a `*/2` cron produced 140,719 rate-limit errors and a
  178MB log on one box.
- **`gh api rate_limit` lies about GraphQL.** It reported `graphql: 5000/5000`
  while a real query returned "API rate limit already exceeded". Only a real
  query tells the truth.

## Files

| File | What it is |
|---|---|
| `gh-api.mjs` | Library: PR listing/lookup with a REST fallback, capped single-PR mergeability, attempt-based time gating, and a truthful rate-limit check. |
| `pr-conflict-scan.mjs` | CLI: finds PRs with merge conflicts, scoped to PRs a TaskYou task actually owns. |
| `gh-api.test.mjs` | `node --test`. Fake `gh` executor; no network. |

## The inversion (`pr-conflict-scan.mjs`)

The old conflict check listed **all** open PRs *including* `mergeable`, filtered
to CONFLICTING, and only then asked whether a TaskYou task mapped to each one —
discarding ~95% of what it had just paid for.

This one goes the other way:

1. Read the branches of active TaskYou tasks — **local `ty` state, zero API**.
2. One cheap list of open PRs (never with `mergeable`).
3. Intersect in memory, cap the survivors at 25, and pay for mergeability only
   on those.

On a box with 40 open PRs and 2 task branches that is 3 API calls instead of
~40, and the feature — an agent noticing its own PR has conflicts and fixing
them — is untouched.

```
node pr-conflict-scan.mjs [--force] [--json] [--project NAME]
```

Config comes from the environment or a `.env` next to the script:

| Var | Meaning |
|---|---|
| `GITHUB_REPOS` | `proj:owner/repo,proj2:owner/repo2` (required) |
| `TY_PATH` | path to the `ty` binary (default: `ty` on `PATH`) |
| `SCAN_INTERVAL_MS` | backstop gate between **attempts** (default: 15 min) |
| `MERGEABILITY_CAP` | max single-PR mergeability calls per scan (default: 25) |
| `CONFLICT_HOOK` | optional command per conflicting PR. Placeholders: `{task} {pr} {branch} {repo} {url}` |

## Rules the library enforces

- **Never request `mergeable` in a list query.** `listOpenPRs()` doesn't, and a
  test asserts it.
- **Mergeability is single-PR and capped.** REST can only compute it on the
  single-PR endpoint, so it is inherently N+1; uncapped, it drains the REST
  budget exactly the way GraphQL was drained.
- **`unknown` / `UNKNOWN` is NOT conflicting.** GitHub is still computing.
  Move on; do not poll waiting for it.
- **Fall back to REST only on rate-limit errors.** A 404, a bad token, or DNS
  failure still throws, so real breakage stays visible instead of being
  silently papered over.
- **Gate on the attempt, not the success.** An earlier attempt at gating
  stamped the clock only after a scan *succeeded*, so a failing scan retried
  every cycle — reproducing the runaway it was meant to prevent.
  `recordScanAttempt()` is called **before** the API calls and persisted.

## Related defaults shipped with this module

- **Cron floor `*/10`** for pollers (`setup.sh`). Anything tighter multiplies
  spend across every box on the same GitHub user.
- **`modules/common/rotate-log.sh`** runs before each poll. One box had 487MB
  across four unrotated poll logs.
- **SSH git remotes** (`git@github.com:owner/repo.git`, not `https://`).
  Git over SSH costs zero API quota.
- **`/gm-doctor` Check 9** probes GraphQL with a real query instead of trusting
  the reported counter.

## Wiring into an existing poller

A box still running the old inline CI block inside `agent-poll.mjs` should
replace it with:

```js
import { scanConflictsForTaskBranches, shouldScan, recordScanAttempt } from './gh-api.mjs';

if (shouldScan(state)) {
  recordScanAttempt(state);   // BEFORE the calls
  saveState(state);
  const { conflicting } = scanConflictsForTaskBranches(taskBranches, { repo });
  for (const pr of conflicting) { /* … dispatch the fix … */ }
}
```
