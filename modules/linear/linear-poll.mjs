#!/usr/bin/env node

// Linear @agent Comment Poller
// Polls Linear for comments containing @agent, creates TaskYou revision tasks,
// and replies on the Linear issue confirming the revision is underway.
//
// Configuration is read from environment variables or .env file at SCRIPT_DIR/.env
// Required env vars:
//   LINEAR_TOKEN       — API token for reading comments
//   LINEAR_CLI         — Path to the linear CLI binary
//   TY_PATH            — Path to the ty binary
//   LABEL_PROJECT_MAP  — JSON mapping of label names to project names
//                        e.g. '{"marketing":"marketing","content":"content"}'
//   DEFAULT_PROJECT    — Default project if no label matches (default: "marketing")

import { readFileSync, writeFileSync, existsSync, unlinkSync } from 'fs';
import { execSync } from 'child_process';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));

// Load .env if present
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

const LINEAR_API = 'https://api.linear.app/graphql';
const LINEAR_TOKEN = process.env.LINEAR_TOKEN;
const STATE_FILE = join(__dirname, '.linear-poll-state.json');
const TY_PATH = process.env.TY_PATH || '/usr/local/bin/ty';
const LINEAR_CLI = process.env.LINEAR_CLI || '/usr/local/bin/linear';

// Label-to-project mapping
let LABEL_PROJECT_MAP = { marketing: 'marketing' };
try {
  if (process.env.LABEL_PROJECT_MAP) {
    LABEL_PROJECT_MAP = JSON.parse(process.env.LABEL_PROJECT_MAP);
  }
} catch {}

const DEFAULT_PROJECT = process.env.DEFAULT_PROJECT || 'marketing';

function loadState() {
  if (existsSync(STATE_FILE)) {
    return JSON.parse(readFileSync(STATE_FILE, 'utf8'));
  }
  const fiveMinAgo = new Date(Date.now() - 5 * 60 * 1000).toISOString();
  return { lastChecked: fiveMinAgo, processedCommentIds: [], pendingTasks: [] };
}

function saveState(state) {
  writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
}

async function linearQuery(query, variables = {}) {
  const res = await fetch(LINEAR_API, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': LINEAR_TOKEN,
    },
    body: JSON.stringify({ query, variables }),
  });

  if (!res.ok) {
    throw new Error(`Linear API error: ${res.status} ${await res.text()}`);
  }

  const json = await res.json();
  if (json.errors) {
    throw new Error(`Linear GraphQL error: ${JSON.stringify(json.errors)}`);
  }
  return json.data;
}

async function pollForAgentComments(since) {
  const query = `
    query($since: DateTimeOrDuration!) {
      comments(filter: {
        createdAt: { gte: $since }
        body: { containsIgnoreCase: "@agent" }
      }) {
        nodes {
          id
          body
          createdAt
          issue {
            id
            identifier
            title
            description
            labels {
              nodes {
                name
              }
            }
          }
          user {
            name
          }
        }
      }
    }
  `;

  const data = await linearQuery(query, { since });
  return data.comments.nodes;
}

function replyToIssue(issueIdentifier, body) {
  const tmpFile = `/tmp/linear-reply-${Date.now()}.md`;
  try {
    writeFileSync(tmpFile, body);
    execSync(
      `${LINEAR_CLI} comment add ${issueIdentifier} --body-file ${tmpFile}`,
      { encoding: 'utf8', timeout: 30000 }
    );
  } catch (err) {
    console.error(`Failed to reply to ${issueIdentifier}: ${err.message}`);
  } finally {
    try { unlinkSync(tmpFile); } catch {}
  }
}

function mapLabelsToProject(labels) {
  for (const label of labels) {
    const name = label.name.toLowerCase();
    for (const [key, project] of Object.entries(LABEL_PROJECT_MAP)) {
      if (name.includes(key)) return project;
    }
  }
  return DEFAULT_PROJECT;
}

function extractRevisionInstructions(commentBody) {
  return commentBody.replace(/@agent/gi, '').trim();
}

function createTaskYouTask(project, title, body) {
  const cmd = `${TY_PATH} create ${JSON.stringify(title)} --project ${project} --type draft --body ${JSON.stringify(body)}`;
  try {
    const output = execSync(cmd, { encoding: 'utf8', timeout: 30000 });
    console.log(`TaskYou task created: ${output.trim()}`);
    return output.trim();
  } catch (err) {
    console.error(`Failed to create TaskYou task: ${err.message}`);
    return null;
  }
}

function extractTaskId(taskOutput) {
  const match = taskOutput.match(/#(\d+)/);
  return match ? match[1] : null;
}

function executeTask(taskId) {
  try {
    execSync(`${TY_PATH} execute ${taskId}`, { encoding: 'utf8', timeout: 15000 });
    console.log(`Task #${taskId} sent for execution`);
  } catch (err) {
    console.error(`Failed to execute task #${taskId}: ${err.message}`);
  }
}

function getTaskStatus(taskId) {
  try {
    const output = execSync(`${TY_PATH} show ${taskId}`, { encoding: 'utf8', timeout: 15000 });
    const statusMatch = output.match(/Status:\s+(\S+)/);
    const worktreeMatch = output.match(/Worktree:\s+(.+)/);
    return {
      status: statusMatch ? statusMatch[1] : 'unknown',
      worktree: worktreeMatch ? worktreeMatch[1].trim() : null,
    };
  } catch (err) {
    console.error(`Failed to get status for task #${taskId}: ${err.message}`);
    return { status: 'unknown', worktree: null };
  }
}

function getWorktreeOutput(worktree) {
  try {
    const diff = execSync(
      `cd ${worktree} && git diff main..HEAD -- . ':!.claude'`,
      { encoding: 'utf8', timeout: 15000 }
    );
    if (!diff.trim()) return null;

    const files = execSync(
      `cd ${worktree} && git diff --name-only main..HEAD -- . ':!.claude'`,
      { encoding: 'utf8', timeout: 15000 }
    ).trim().split('\n').filter(Boolean);

    const contents = [];
    for (const file of files.slice(0, 5)) {
      try {
        const content = execSync(
          `cd ${worktree} && cat ${JSON.stringify(file)}`,
          { encoding: 'utf8', timeout: 5000 }
        );
        contents.push(`**${file}:**\n\`\`\`\n${content.trim()}\n\`\`\``);
      } catch { /* skip unreadable files */ }
    }
    return contents.length > 0 ? contents.join('\n\n') : null;
  } catch (err) {
    console.error(`Failed to read worktree output: ${err.message}`);
    return null;
  }
}

async function checkPendingTasks(state) {
  if (!state.pendingTasks || state.pendingTasks.length === 0) return;

  console.log(`Checking ${state.pendingTasks.length} pending task(s)`);

  const stillPending = [];

  for (const pending of state.pendingTasks) {
    const { status, worktree } = getTaskStatus(pending.taskId);
    console.log(`  Task #${pending.taskId}: ${status}`);

    if (status === 'done') {
      let replyBody = 'Revision complete.';

      if (worktree) {
        const output = getWorktreeOutput(worktree);
        if (output) {
          replyBody = `Revision complete. Here's the updated content:\n\n${output}`;
        }
      }

      replyToIssue(pending.issueIdentifier, replyBody);
      console.log(`  Posted results to ${pending.issueIdentifier}`);
    } else if (status === 'blocked' || status === 'failed') {
      replyToIssue(
        pending.issueIdentifier,
        `The revision task encountered an issue (status: ${status}). The GM has been notified.`
      );
      console.log(`  Task #${pending.taskId} is ${status}, notified on ${pending.issueIdentifier}`);
    } else {
      stillPending.push(pending);
    }
  }

  state.pendingTasks = stillPending;
}

const AUTH_FAILED_FLAG = join(__dirname, '.auth-failed');

async function main() {
  const state = loadState();
  console.log(`[${new Date().toISOString()}] Polling since ${state.lastChecked}`);

  const authFailed = existsSync(AUTH_FAILED_FLAG);
  if (authFailed) {
    console.warn(`WARNING: Claude auth is unhealthy. Will poll and create tasks but skip execution.`);
  }

  await checkPendingTasks(state);

  const comments = await pollForAgentComments(state.lastChecked);
  console.log(`Found ${comments.length} @agent comment(s)`);

  const newComments = comments.filter(c => !state.processedCommentIds.includes(c.id));

  if (newComments.length === 0) {
    console.log('No new comments to process');
    state.lastChecked = new Date().toISOString();
    saveState(state);
    return;
  }

  for (const comment of newComments) {
    const issue = comment.issue;
    const requester = comment.user?.name || 'Someone';
    const instructions = extractRevisionInstructions(comment.body);
    const labels = issue.labels?.nodes || [];
    const project = mapLabelsToProject(labels);

    console.log(`Processing: ${issue.identifier} "${issue.title}" — requested by ${requester}`);
    console.log(`  Instructions: ${instructions}`);
    console.log(`  Project: ${project}`);

    const taskTitle = `Revision: ${issue.title}`;
    const taskBody = [
      `## Revision Request`,
      ``,
      `**Original issue:** ${issue.identifier} — ${issue.title}`,
      `**Requested by:** ${requester}`,
      ``,
      `### Revision instructions`,
      instructions,
      ``,
      `### Original description`,
      issue.description || '(no description)',
    ].join('\n');

    const taskResult = createTaskYouTask(project, taskTitle, taskBody);

    if (taskResult) {
      const taskId = extractTaskId(taskResult);

      if (taskId && !authFailed) {
        executeTask(taskId);

        if (!state.pendingTasks) state.pendingTasks = [];
        state.pendingTasks.push({
          taskId,
          issueId: issue.id,
          issueIdentifier: issue.identifier,
          createdAt: new Date().toISOString(),
        });
      }

      replyToIssue(
        issue.identifier,
        `Revision task created. An agent is working on this and will update the issue when done.`
      );
      console.log(`Replied to ${issue.identifier}`);
    }

    state.processedCommentIds.push(comment.id);
  }

  if (state.processedCommentIds.length > 200) {
    state.processedCommentIds = state.processedCommentIds.slice(-200);
  }

  state.lastChecked = new Date().toISOString();
  saveState(state);
  console.log('Done');
}

main().catch(err => {
  console.error(`[${new Date().toISOString()}] Error: ${err.message}`);
  process.exit(1);
});
