#!/usr/bin/env node
// Unit tests for gh-api.mjs and the pure helpers in pr-conflict-scan.mjs.
// Run: node --test  (from modules/github/)
//
// Every test injects a fake `run` executor, so nothing here touches GitHub.
// The fake records the exact argv it was handed — which is the point: the bugs
// these guard against are all "which call did we actually make".

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  isRateLimitError,
  withRestFallback,
  listOpenPRs,
  findPRForBranch,
  getMergeableState,
  normalizeMergeable,
  scanConflictsForTaskBranches,
  shouldScan,
  recordScanAttempt,
  checkRateLimits,
} from './gh-api.mjs';

import { parseRepoMap, renderHook, taskBranchesByProject } from './pr-conflict-scan.mjs';

const RATE_LIMIT_MSG = 'API rate limit already exceeded for user ID 12345.';

/** A fake `gh` that dispatches on argv and records every call. */
function fakeGh(handlers) {
  const calls = [];
  const run = (args) => {
    calls.push(args);
    for (const [match, reply] of handlers) {
      if (match(args)) {
        const out = typeof reply === 'function' ? reply(args) : reply;
        if (out instanceof Error) throw out;
        return out;
      }
    }
    throw new Error(`unexpected gh call: ${args.join(' ')}`);
  };
  run.calls = calls;
  return run;
}

const isGraphqlList = (a) => a[0] === 'pr' && a[1] === 'list';
const isRestList = (a) => a[0] === 'api' && /\/pulls\?/.test(a[1]);

test('isRateLimitError matches only rate-limit failures', () => {
  assert.equal(isRateLimitError(new Error(RATE_LIMIT_MSG)), true);
  assert.equal(isRateLimitError(new Error('You have exceeded a secondary rate limit')), true);
  assert.equal(isRateLimitError(new Error('HTTP 429: Too Many Requests')), true);
  // Real failures must NOT look like rate limits, or they get papered over.
  assert.equal(isRateLimitError(new Error('HTTP 404: Not Found')), false);
  assert.equal(isRateLimitError(new Error('gh: not authenticated')), false);
  assert.equal(isRateLimitError(new Error('getaddrinfo ENOTFOUND api.github.com')), false);
});

test('withRestFallback retries on rate limit and rethrows everything else', () => {
  let fellBack = false;
  const value = withRestFallback(
    () => { throw new Error(RATE_LIMIT_MSG); },
    () => { fellBack = true; return 'rest'; }
  );
  assert.equal(value, 'rest');
  assert.equal(fellBack, true);

  assert.throws(
    () => withRestFallback(
      () => { throw new Error('HTTP 404: Not Found'); },
      () => 'rest'
    ),
    /404/
  );
});

test('listOpenPRs never asks for mergeable', () => {
  const run = fakeGh([[isGraphqlList, JSON.stringify([
    { number: 7, headRefName: 'task/7-foo', title: 'Foo', url: 'u7' },
  ])]]);
  const prs = listOpenPRs({ repo: 'o/r', run });

  assert.deepEqual(prs, [{ number: 7, branch: 'task/7-foo', title: 'Foo', url: 'u7' }]);
  const jsonFields = run.calls[0][run.calls[0].indexOf('--json') + 1];
  assert.ok(!/mergeable/.test(jsonFields), `list query requested: ${jsonFields}`);
});

test('listOpenPRs falls back to REST and reads .head.ref, not .headRefName', () => {
  const run = fakeGh([
    [isGraphqlList, new Error(RATE_LIMIT_MSG)],
    [isRestList, JSON.stringify([
      { number: 7, head: { ref: 'task/7-foo' }, title: 'Foo', html_url: 'u7' },
    ])],
  ]);
  const prs = listOpenPRs({ repo: 'o/r', run });

  assert.deepEqual(prs, [{ number: 7, branch: 'task/7-foo', title: 'Foo', url: 'u7' }]);
  assert.equal(run.calls[1][1], 'repos/o/r/pulls?state=open&per_page=100');
});

test('listOpenPRs propagates non-rate-limit errors', () => {
  const run = fakeGh([[isGraphqlList, new Error('HTTP 404: Not Found')]]);
  assert.throws(() => listOpenPRs({ repo: 'o/r', run }), /404/);
  assert.equal(run.calls.length, 1, 'must not retry over REST');
});

test('findPRForBranch falls back to the REST head=owner:branch query', () => {
  const run = fakeGh([
    [isGraphqlList, new Error(RATE_LIMIT_MSG)],
    [isRestList, JSON.stringify([
      { number: 9, head: { ref: 'task/9-bar' }, title: 'Bar', html_url: 'u9' },
    ])],
  ]);
  const pr = findPRForBranch('task/9-bar', { repo: 'acme/widgets', run });

  assert.equal(pr.number, 9);
  assert.equal(pr.branch, 'task/9-bar');
  assert.equal(run.calls[1][1], 'repos/acme/widgets/pulls?state=open&head=acme:task/9-bar');
});

test('findPRForBranch returns null when no PR exists', () => {
  const run = fakeGh([[isGraphqlList, '[]']]);
  assert.equal(findPRForBranch('nope', { repo: 'o/r', run }), null);
});

test('normalizeMergeable folds REST and GraphQL spellings', () => {
  assert.equal(normalizeMergeable('CONFLICTING'), 'CONFLICTING');
  assert.equal(normalizeMergeable('dirty'), 'CONFLICTING');       // REST's spelling
  assert.equal(normalizeMergeable('MERGEABLE'), 'MERGEABLE');
  assert.equal(normalizeMergeable('clean'), 'MERGEABLE');
  assert.equal(normalizeMergeable('behind'), 'MERGEABLE');        // out of date, not conflicted
  assert.equal(normalizeMergeable('unknown'), 'UNKNOWN');         // still computing
  assert.equal(normalizeMergeable(undefined), 'UNKNOWN');
});

test('getMergeableState uses the single-PR REST endpoint on fallback', () => {
  const run = fakeGh([
    [(a) => a[0] === 'pr' && a[1] === 'view', new Error(RATE_LIMIT_MSG)],
    [(a) => a[0] === 'api' && a[1] === 'repos/o/r/pulls/12', 'dirty\n'],
  ]);
  assert.equal(getMergeableState(12, { repo: 'o/r', run }), 'CONFLICTING');
  assert.deepEqual(run.calls[1], ['api', 'repos/o/r/pulls/12', '--jq', '.mergeable_state']);
});

test('scanConflictsForTaskBranches checks only PRs that have a task', () => {
  const open = [];
  for (let n = 1; n <= 40; n++) open.push({ number: n, headRefName: `branch-${n}`, title: `PR ${n}`, url: `u${n}` });

  const run = fakeGh([
    [isGraphqlList, JSON.stringify(open)],
    [(a) => a[0] === 'pr' && a[1] === 'view', (a) =>
      JSON.stringify({ mergeable: a[2] === '3' ? 'CONFLICTING' : 'MERGEABLE' })],
  ]);

  const result = scanConflictsForTaskBranches(['branch-3', 'branch-11'], { repo: 'o/r', run });

  assert.equal(result.candidates, 2);
  assert.equal(result.checked, 2);
  assert.deepEqual(result.conflicting.map((p) => p.number), [3]);
  // 1 list call + 2 mergeability calls — not 40.
  assert.equal(run.calls.length, 3);
});

test('scanConflictsForTaskBranches caps mergeability calls', () => {
  const open = [];
  const branches = [];
  for (let n = 1; n <= 30; n++) {
    open.push({ number: n, headRefName: `b${n}`, title: `PR ${n}`, url: `u${n}` });
    branches.push(`b${n}`);
  }
  const run = fakeGh([
    [isGraphqlList, JSON.stringify(open)],
    [(a) => a[0] === 'pr' && a[1] === 'view', JSON.stringify({ mergeable: 'MERGEABLE' })],
  ]);

  const result = scanConflictsForTaskBranches(branches, { repo: 'o/r', run, cap: 25 });

  assert.equal(result.candidates, 30);
  assert.equal(result.checked, 25);
  assert.equal(result.skipped, 5);
  assert.equal(run.calls.length, 26);
});

test('scanConflictsForTaskBranches makes zero API calls when no task has a branch', () => {
  const run = fakeGh([]);
  const result = scanConflictsForTaskBranches([], { repo: 'o/r', run });
  assert.deepEqual(result, { conflicting: [], checked: 0, candidates: 0, skipped: 0 });
  assert.equal(run.calls.length, 0);
});

test('an UNKNOWN mergeable state is not treated as conflicting', () => {
  const run = fakeGh([
    [isGraphqlList, JSON.stringify([{ number: 5, headRefName: 'b5', title: 'x', url: 'u5' }])],
    [(a) => a[0] === 'pr' && a[1] === 'view', JSON.stringify({ mergeable: 'UNKNOWN' })],
  ]);
  const result = scanConflictsForTaskBranches(['b5'], { repo: 'o/r', run });
  assert.deepEqual(result.conflicting, []);
  assert.equal(run.calls.length, 2, 'must not poll waiting for the answer');
});

test('the gate opens on elapsed ATTEMPT time, not on success', () => {
  const now = Date.parse('2026-08-26T12:00:00Z');
  const interval = 15 * 60 * 1000;

  assert.equal(shouldScan({}, { now, intervalMs: interval }), true, 'no prior attempt → scan');

  const state = recordScanAttempt({}, { now });
  assert.equal(state.lastConflictScanAttempt, new Date(now).toISOString());
  assert.equal(shouldScan(state, { now: now + 60_000, intervalMs: interval }), false);
  assert.equal(shouldScan(state, { now: now + interval, intervalMs: interval }), true);

  // A garbage timestamp must not wedge the gate shut forever.
  assert.equal(shouldScan({ lastConflictScanAttempt: 'nonsense' }, { now, intervalMs: interval }), true);
});

test('checkRateLimits believes a real GraphQL probe over the reported counter', () => {
  const reportsHealthy = JSON.stringify({
    resources: { core: { limit: 5000, remaining: 4980 }, graphql: { remaining: 5000 } },
  });
  const run = fakeGh([
    [(a) => a[1] === 'rate_limit', reportsHealthy],
    [(a) => a[1] === 'graphql', new Error(RATE_LIMIT_MSG)],
  ]);

  const status = checkRateLimits({ run });

  assert.equal(status.rest.remaining, 4980);
  assert.equal(status.rest.ok, true);
  assert.equal(status.graphql.reportedRemaining, 5000, 'what the API claims');
  assert.equal(status.graphql.ok, false, 'what a real query proves');
  assert.equal(status.graphql.rateLimited, true);
  assert.deepEqual(run.calls[1], ['api', 'graphql', '-f', 'query=query{viewer{login}}']);
});

test('parseRepoMap reads proj:owner/repo pairs', () => {
  assert.deepEqual(parseRepoMap('a:o/r, b:o/r2'), { a: 'o/r', b: 'o/r2' });
  assert.deepEqual(parseRepoMap(''), {});
  assert.deepEqual(parseRepoMap('garbage'), {});
});

test('renderHook substitutes placeholders and leaves unknown ones alone', () => {
  assert.equal(
    renderHook('ty execute {task} # PR {pr}', { task: 42, pr: 7 }),
    'ty execute 42 # PR 7'
  );
  assert.equal(renderHook('{nope}', {}), '{nope}');
});

test('taskBranchesByProject reads local ty state only, grouped by project', () => {
  const ty = (args) => {
    if (args[0] === 'list') {
      const status = args[args.indexOf('--status') + 1];
      return status === 'processing'
        ? [{ id: 1, project: 'alpha', title: 'A' }]
        : [{ id: 2, project: 'alpha', title: 'B' }, { id: 3, project: 'beta', title: 'C' }];
    }
    const id = Number(args[1]);
    // Task 3 has no branch yet — it must not produce a bogus entry.
    return { id, project: id === 3 ? 'beta' : 'alpha', branch: id === 3 ? null : `task/${id}` };
  };

  assert.deepEqual(taskBranchesByProject({ ty }), {
    alpha: [
      { id: 1, branch: 'task/1', title: 'A' },
      { id: 2, branch: 'task/2', title: 'B' },
    ],
  });
});
