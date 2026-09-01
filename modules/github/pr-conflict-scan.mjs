#!/usr/bin/env node

// PR conflict scan, scoped to PRs a TaskYou task actually owns.
//
// The old shape of this check (still live on some boxes inside agent-poll.mjs)
// listed every open PR *including* `mergeable`, filtered to CONFLICTING, and
// only then asked whether a TaskYou task mapped to each one — throwing away
// ~95% of the work it had just paid GitHub for.
//
// This inverts it:
//   1. Read the branches of active TaskYou tasks — LOCAL state, zero API.
//   2. One cheap list of open PRs (no `mergeable` field).
//   3. Intersect in memory, cap the survivors, and pay for mergeability only
//      on those.
//
// Usage:
//   node pr-conflict-scan.mjs [--force] [--json] [--project NAME]
//
// Config (env or .env next to this script):
//   GITHUB_REPOS      proj:owner/repo,proj2:owner/repo2   (required)
//   TY_PATH           path to the ty binary (default: ty on PATH)
//   SCAN_INTERVAL_MS  backstop gate between attempts (default: 15 min)
//   MERGEABILITY_CAP  max single-PR mergeability calls per scan (default: 25)
//   CONFLICT_HOOK     optional command run per conflicting PR. Placeholders:
//                     {task} {pr} {branch} {repo} {url}

import { readFileSync, writeFileSync, existsSync } from 'fs';
import { execFileSync } from 'child_process';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

import {
  scanConflictsForTaskBranches,
  shouldScan,
  recordScanAttempt,
  DEFAULT_MERGEABILITY_CAP,
  DEFAULT_SCAN_INTERVAL_MS,
} from './gh-api.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));

function loadEnv(path) {
  if (!existsSync(path)) return;
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq === -1) continue;
    const key = trimmed.slice(0, eq);
    if (!process.env[key]) process.env[key] = trimmed.slice(eq + 1);
  }
}

loadEnv(join(__dirname, '.env'));

const STATE_FILE = join(__dirname, '.pr-conflict-scan-state.json');
const TY_PATH = process.env.TY_PATH || 'ty';
const SCAN_INTERVAL_MS = Number(process.env.SCAN_INTERVAL_MS) || DEFAULT_SCAN_INTERVAL_MS;
const MERGEABILITY_CAP = Number(process.env.MERGEABILITY_CAP) || DEFAULT_MERGEABILITY_CAP;

/** "proj:owner/repo,other:owner/other" → { proj: "owner/repo", … } */
export function parseRepoMap(raw) {
  const map = {};
  for (const entry of String(raw || '').split(',')) {
    const trimmed = entry.trim();
    if (!trimmed) continue;
    const colon = trimmed.indexOf(':');
    if (colon === -1) continue;
    map[trimmed.slice(0, colon).trim()] = trimmed.slice(colon + 1).trim();
  }
  return map;
}

/** Tasks that could plausibly own an open PR. */
const ACTIVE_STATUSES = ['processing', 'blocked'];

/**
 * Branches of active TaskYou tasks, grouped by project.
 * Pure local reads — `ty list`/`ty show` never touch the GitHub API.
 */
export function taskBranchesByProject({ ty = tyJson, project = null } = {}) {
  const byProject = {};
  for (const status of ACTIVE_STATUSES) {
    const args = ['list', '--json', '--status', status, '--limit', '200'];
    if (project) args.push('--project', project);
    const tasks = ty(args) || [];
    for (const task of tasks) {
      const detail = ty(['show', String(task.id), '--json']);
      const branch = detail?.branch;
      if (!branch) continue;
      const proj = detail.project || task.project;
      (byProject[proj] ||= []).push({ id: task.id, branch, title: task.title });
    }
  }
  return byProject;
}

function tyJson(args) {
  try {
    return JSON.parse(execFileSync(TY_PATH, args, { encoding: 'utf8', timeout: 30000 }));
  } catch {
    return null;
  }
}

function loadState() {
  if (!existsSync(STATE_FILE)) return {};
  try {
    return JSON.parse(readFileSync(STATE_FILE, 'utf8'));
  } catch {
    return {};
  }
}

function saveState(state) {
  writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
}

/** Substitute {placeholders} in a hook command. */
export function renderHook(template, vars) {
  return template.replace(/\{(\w+)\}/g, (_, key) =>
    Object.prototype.hasOwnProperty.call(vars, key) ? String(vars[key]) : `{${key}}`
  );
}

function main() {
  const args = process.argv.slice(2);
  const force = args.includes('--force');
  const asJson = args.includes('--json');
  const projectIdx = args.indexOf('--project');
  const project = projectIdx !== -1 ? args[projectIdx + 1] : null;

  const log = asJson ? () => {} : (msg) => console.log(msg);

  const repoMap = parseRepoMap(process.env.GITHUB_REPOS);
  if (Object.keys(repoMap).length === 0) {
    console.error('GITHUB_REPOS is not set (expected "proj:owner/repo,…") — nothing to scan');
    process.exit(1);
  }

  const state = loadState();
  if (!force && !shouldScan(state, { intervalMs: SCAN_INTERVAL_MS })) {
    log(`Skipping: last attempt was ${state.lastConflictScanAttempt} (gate: ${SCAN_INTERVAL_MS}ms)`);
    if (asJson) console.log(JSON.stringify({ skipped: true, lastAttempt: state.lastConflictScanAttempt }));
    return;
  }

  // Stamp the ATTEMPT before spending any API budget: if the scan below throws,
  // the gate still holds and we do not retry on every cycle.
  recordScanAttempt(state);
  saveState(state);

  const byProject = taskBranchesByProject({ project });
  const results = [];

  for (const [proj, tasks] of Object.entries(byProject)) {
    const repo = repoMap[proj];
    if (!repo) {
      log(`No repo mapped for project "${proj}" — skipping`);
      continue;
    }

    const branches = tasks.map((t) => t.branch);
    const { conflicting, checked, candidates, skipped } =
      scanConflictsForTaskBranches(branches, { repo, cap: MERGEABILITY_CAP, log });

    log(`${repo}: ${tasks.length} task branch(es), ${candidates} with an open PR, ` +
        `${checked} mergeability check(s), ${conflicting.length} conflicting` +
        (skipped ? `, ${skipped} deferred by cap` : ''));

    for (const pr of conflicting) {
      const task = tasks.find((t) => t.branch === pr.branch);
      const entry = { project: proj, repo, task: task?.id ?? null, pr: pr.number, branch: pr.branch, url: pr.url };
      results.push(entry);
      log(`  CONFLICTING: PR #${pr.number} (${pr.branch})${task ? ` → task #${task.id}` : ''}`);

      if (process.env.CONFLICT_HOOK) {
        const cmd = renderHook(process.env.CONFLICT_HOOK, {
          task: task?.id ?? '', pr: pr.number, branch: pr.branch, repo, url: pr.url ?? '',
        });
        try {
          execFileSync('/bin/sh', ['-c', cmd], { encoding: 'utf8', timeout: 60000 });
        } catch (err) {
          console.error(`  CONFLICT_HOOK failed for PR #${pr.number}: ${err.message}`);
        }
      }
    }
  }

  if (asJson) console.log(JSON.stringify({ skipped: false, conflicts: results }, null, 2));
}

// Only run when invoked directly, so the helpers above stay importable/testable.
if (process.argv[1] && process.argv[1].endsWith('pr-conflict-scan.mjs')) {
  try {
    main();
  } catch (err) {
    console.error(`[${new Date().toISOString()}] pr-conflict-scan failed: ${err.message}`);
    process.exit(1);
  }
}
