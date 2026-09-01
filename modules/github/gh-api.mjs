#!/usr/bin/env node

// GitHub API helpers for agent pollers — budget-aware by construction.
//
// Why this module exists
// ─────────────────────────────────────────────────────────────────────────────
// GitHub bills REST and GraphQL from SEPARATE buckets (5,000 req/hr vs
// 5,000 pts/hr) and the bucket is PER USER, not per token: three boxes holding
// three different tokens that all authenticate as the same user share ONE
// budget. A poller that burns GraphQL on a */2 cron takes every other box down
// with it.
//
// Two rules follow, and this module enforces both:
//
//   1. NEVER ask for `mergeable` in a list query. That field makes GitHub
//      compute a merge commit for every PR in the list. Asking for it across
//      40 open PRs every 2 minutes produced 140,719 rate-limit errors and a
//      178MB log on one box. Mergeability is fetched one PR at a time, only
//      for PRs we would actually act on, and always capped.
//
//   2. When GraphQL is exhausted, retry the same question over REST rather
//      than losing the cycle — but ONLY on rate-limit errors, so real failures
//      (bad repo, no auth, network down) still surface.
//
// `gh pr list` / `gh pr view` are GraphQL. `gh api repos/…` is REST.
//
// Everything here takes an injected `run(args) -> string` command executor so
// it can be unit-tested without touching the network. `ghRun` is the default.

import { execFileSync } from 'child_process';

/** Max single-PR mergeability lookups per scan. Each one is an API call. */
export const DEFAULT_MERGEABILITY_CAP = 25;

/** Default backstop between conflict scans (ms). */
export const DEFAULT_SCAN_INTERVAL_MS = 15 * 60 * 1000;

/** Run `gh` with the given argv and return stdout. Throws on non-zero exit. */
export function ghRun(args, { timeout = 30000 } = {}) {
  try {
    return execFileSync('gh', args, { encoding: 'utf8', timeout });
  } catch (err) {
    // Surface stderr — `gh` puts "API rate limit exceeded" there, and
    // isRateLimitError() needs to see it.
    const stderr = err.stderr ? String(err.stderr) : '';
    const stdout = err.stdout ? String(err.stdout) : '';
    const detail = [err.message, stderr, stdout].filter(Boolean).join('\n');
    const wrapped = new Error(detail);
    wrapped.cause = err;
    throw wrapped;
  }
}

/**
 * Is this error GitHub telling us we are out of budget?
 *
 * Deliberately narrow: anything else must keep throwing so real failures stay
 * visible instead of being silently papered over by a REST retry.
 */
export function isRateLimitError(err) {
  const text = String(err?.message ?? err ?? '');
  return (
    /rate limit/i.test(text) ||
    /\bAPI rate limit (?:already )?exceeded\b/i.test(text) ||
    /secondary rate limit/i.test(text) ||
    /was submitted too quickly/i.test(text) ||
    /\bHTTP 429\b/.test(text)
  );
}

/**
 * Run `primary`; if it fails with a rate-limit error, run `fallback` instead.
 * Any other error propagates.
 */
export function withRestFallback(primary, fallback, { onFallback } = {}) {
  try {
    return primary();
  } catch (err) {
    if (!isRateLimitError(err)) throw err;
    if (onFallback) onFallback(err);
    return fallback(err);
  }
}

function parseJson(out, what) {
  try {
    return JSON.parse(out);
  } catch {
    throw new Error(`Could not parse ${what} as JSON: ${String(out).slice(0, 200)}`);
  }
}

function ownerOf(repo) {
  return String(repo).split('/')[0];
}

/**
 * Every open PR, as `{ number, branch, title, url }`.
 *
 * GraphQL first (`gh pr list`), REST on rate limit. NOTE the field name
 * difference: GraphQL says `headRefName`, REST says `head.ref` — getting that
 * wrong yields a list of PRs with undefined branches, which silently matches
 * nothing. `mergeable` is never requested here; see getMergeableState().
 */
export function listOpenPRs({ repo, run = ghRun, limit = 100, log = () => {} } = {}) {
  return withRestFallback(
    () => {
      const out = run([
        'pr', 'list',
        '--repo', repo,
        '--state', 'open',
        '--limit', String(limit),
        '--json', 'number,headRefName,title,url',
      ]);
      return parseJson(out, 'gh pr list output').map((pr) => ({
        number: pr.number,
        branch: pr.headRefName,
        title: pr.title,
        url: pr.url,
      }));
    },
    () => {
      const out = run([
        'api', `repos/${repo}/pulls?state=open&per_page=${limit}`,
      ]);
      return parseJson(out, 'REST pulls output').map((pr) => ({
        number: pr.number,
        branch: pr.head?.ref,
        title: pr.title,
        url: pr.html_url,
      }));
    },
    { onFallback: () => log('GraphQL rate-limited listing open PRs — falling back to REST') }
  );
}

/** The open PR for `branch`, or null. GraphQL first, REST on rate limit. */
export function findPRForBranch(branch, { repo, run = ghRun, log = () => {} } = {}) {
  return withRestFallback(
    () => {
      const out = run([
        'pr', 'list',
        '--repo', repo,
        '--head', branch,
        '--state', 'open',
        '--limit', '1',
        '--json', 'number,headRefName,title,url',
      ]);
      const [pr] = parseJson(out, 'gh pr list output');
      return pr
        ? { number: pr.number, branch: pr.headRefName, title: pr.title, url: pr.url }
        : null;
    },
    () => {
      const out = run([
        'api',
        `repos/${repo}/pulls?state=open&head=${ownerOf(repo)}:${branch}`,
      ]);
      const [pr] = parseJson(out, 'REST pulls output');
      return pr
        ? { number: pr.number, branch: pr.head?.ref, title: pr.title, url: pr.html_url }
        : null;
    },
    { onFallback: () => log(`GraphQL rate-limited finding PR for ${branch} — falling back to REST`) }
  );
}

/**
 * Mergeability of ONE PR: 'CONFLICTING' | 'MERGEABLE' | 'UNKNOWN'.
 *
 * This is the expensive call — it makes GitHub compute a merge commit — so it
 * is single-PR only and callers must cap how many they make. REST's spelling
 * of CONFLICTING is `mergeable_state: "dirty"`.
 *
 * `unknown` means GitHub is still computing. Treat it as NOT conflicting and
 * move on; do not poll waiting for it.
 */
export function getMergeableState(number, { repo, run = ghRun, log = () => {} } = {}) {
  return withRestFallback(
    () => {
      const out = run([
        'pr', 'view', String(number), '--repo', repo, '--json', 'mergeable',
      ]);
      const { mergeable } = parseJson(out, 'gh pr view output');
      return normalizeMergeable(mergeable);
    },
    () => {
      const out = run([
        'api', `repos/${repo}/pulls/${number}`, '--jq', '.mergeable_state',
      ]);
      return normalizeMergeable(out.trim());
    },
    { onFallback: () => log(`GraphQL rate-limited on PR #${number} mergeability — falling back to REST`) }
  );
}

/** Fold GraphQL and REST spellings into one vocabulary. */
export function normalizeMergeable(value) {
  const v = String(value ?? '').toLowerCase();
  if (v === 'conflicting' || v === 'dirty') return 'CONFLICTING';
  if (v === 'mergeable' || v === 'clean' || v === 'has_hooks' ||
      v === 'unstable' || v === 'blocked' || v === 'behind' || v === 'draft') {
    return 'MERGEABLE';
  }
  return 'UNKNOWN';
}

/**
 * Find PRs with merge conflicts — but ONLY among PRs that have a TaskYou task.
 *
 * The inversion that makes this affordable: the set of branches we can act on
 * is LOCAL ty state and costs zero API. So we take one cheap list call (no
 * `mergeable`), intersect it with those branches in memory, and pay for
 * mergeability on the 1-2 survivors instead of all 40 open PRs.
 *
 * @param {string[]} taskBranches branches that have a TaskYou task
 * @returns {{ conflicting: object[], checked: number, candidates: number, skipped: number }}
 */
export function scanConflictsForTaskBranches(taskBranches, {
  repo,
  run = ghRun,
  cap = DEFAULT_MERGEABILITY_CAP,
  log = () => {},
} = {}) {
  const wanted = new Set(taskBranches.filter(Boolean));
  if (wanted.size === 0) {
    return { conflicting: [], checked: 0, candidates: 0, skipped: 0 };
  }

  const open = listOpenPRs({ repo, run, log });
  const candidates = open.filter((pr) => wanted.has(pr.branch));
  const toCheck = candidates.slice(0, cap);
  const skipped = candidates.length - toCheck.length;

  if (skipped > 0) {
    log(`Capped mergeability checks at ${cap}; ${skipped} candidate PR(s) deferred to the next cycle`);
  }

  const conflicting = [];
  for (const pr of toCheck) {
    const state = getMergeableState(pr.number, { repo, run, log });
    if (state === 'CONFLICTING') conflicting.push({ ...pr, mergeable: state });
  }

  return { conflicting, checked: toCheck.length, candidates: candidates.length, skipped };
}

// ── Time gating ──────────────────────────────────────────────────────────────
// Record the ATTEMPT, not the success. An earlier version stamped the clock
// only after a scan completed, so a scan that failed retried every single
// cycle — reproducing the runaway the gate was meant to prevent.

/** Has `intervalMs` elapsed since the last ATTEMPT recorded in `state`? */
export function shouldScan(state, { now = Date.now(), intervalMs = DEFAULT_SCAN_INTERVAL_MS } = {}) {
  const last = Date.parse(state?.lastConflictScanAttempt ?? '');
  if (!Number.isFinite(last)) return true;
  return now - last >= intervalMs;
}

/** Stamp the attempt. Call this BEFORE the API calls, and persist it. */
export function recordScanAttempt(state, { now = Date.now() } = {}) {
  state.lastConflictScanAttempt = new Date(now).toISOString();
  return state;
}

// ── Health checks ────────────────────────────────────────────────────────────

/**
 * Truthful rate-limit status for both buckets.
 *
 * `gh api rate_limit` LIES about GraphQL: it reported graphql 5000/5000 while
 * a real query returned "API rate limit already exceeded". So the GraphQL
 * bucket is probed with an actual query and believed over the counter.
 */
export function checkRateLimits({ run = ghRun } = {}) {
  const result = {
    rest: { limit: null, remaining: null, ok: null },
    graphql: { reportedRemaining: null, ok: null, error: null },
  };

  try {
    const out = run(['api', 'rate_limit']);
    const data = parseJson(out, 'rate_limit output');
    const core = data?.resources?.core ?? data?.rate ?? {};
    result.rest = {
      limit: core.limit ?? null,
      remaining: core.remaining ?? null,
      ok: (core.remaining ?? 0) > 0,
    };
    result.graphql.reportedRemaining = data?.resources?.graphql?.remaining ?? null;
  } catch (err) {
    result.rest.ok = false;
    result.rest.error = String(err.message ?? err);
  }

  // The only number that does not lie: does a real query succeed?
  try {
    run(['api', 'graphql', '-f', 'query=query{viewer{login}}']);
    result.graphql.ok = true;
  } catch (err) {
    result.graphql.ok = false;
    result.graphql.error = String(err.message ?? err);
    result.graphql.rateLimited = isRateLimitError(err);
  }

  return result;
}
