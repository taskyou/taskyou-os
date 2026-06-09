#!/usr/bin/env node

// TaskYou Slack bridge
// ────────────────────
// A two-way bridge between Slack and TaskYou. Runs on the agents server next
// to the `ty` binary and notifications.jsonl. Long-running (Slack Socket Mode
// holds a WebSocket), so it's installed as a systemd user service — not a cron
// job like the Linear poller.
//
//   Outbound:  tails notifications.jsonl  → chat.postMessage  (task blocked/done)
//   Inbound:   Slack @mention / DM        → classify intent   → ty <command>
//
// Zero npm dependencies: raw fetch to the Slack + Anthropic HTTP APIs, the
// global WebSocket (Node 22+/24), fs, and child_process. Mirrors the
// dependency-free approach of modules/linear/linear-poll.mjs.
//
// Config is read from environment or a .env file next to this script.
//   SLACK_BOT_TOKEN       xoxb- token (chat:write, app_mentions:read, im:history)
//   SLACK_APP_TOKEN       xapp- token (connections:write) — Socket Mode
//   SLACK_NOTIFY_CHANNEL  channel for task pings not tied to a Slack thread (e.g. #taskyou)
//   SLACK_ALLOWED_USERS   comma-separated Slack user IDs allowed to drive ty
//   SLACK_PROJECT_MAP     JSON map of Slack channel name/id → ty project
//   DEFAULT_PROJECT       project when no channel mapping matches
//   TY_PATH               path to the ty binary
//   NOTIFICATIONS_FILE    path to notifications.jsonl
//   ANTHROPIC_API_KEY     optional — enables LLM intent classification
//   ANTHROPIC_MODEL       classifier model (default claude-haiku-4-5-20251001)

import {
  readFileSync,
  writeFileSync,
  existsSync,
  statSync,
  openSync,
  readSync,
  closeSync,
} from "fs";
import { execFileSync } from "child_process";
import { dirname, join } from "path";
import { fileURLToPath, pathToFileURL } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));

// ── .env loading (same shape as linear-poll.mjs) ─────────────────────────────

function loadEnv(path) {
  if (!existsSync(path)) return;
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eq = trimmed.indexOf("=");
    if (eq === -1) continue;
    const key = trimmed.slice(0, eq);
    if (!process.env[key]) process.env[key] = trimmed.slice(eq + 1);
  }
}

loadEnv(join(__dirname, ".env"));

const CONFIG = {
  botToken: process.env.SLACK_BOT_TOKEN || "",
  appToken: process.env.SLACK_APP_TOKEN || "",
  notifyChannel: process.env.SLACK_NOTIFY_CHANNEL || "",
  allowedUsers: (process.env.SLACK_ALLOWED_USERS || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean),
  projectMap: parseJSON(process.env.SLACK_PROJECT_MAP, {}),
  defaultProject: process.env.DEFAULT_PROJECT || "",
  tyPath: process.env.TY_PATH || "ty",
  notificationsFile:
    process.env.NOTIFICATIONS_FILE ||
    join(process.env.HOME || ".", "notifications.jsonl"),
  // Classifier: prefer the on-box, already-authenticated `claude` CLI (claude.ai
  // login — same primitive the GM/executors use, no API key). Fall back to the
  // Anthropic API only if a key is set, then a dependency-free keyword heuristic.
  classifierMode: process.env.SLACK_CLASSIFIER || "auto", // auto | claude | api | heuristic
  claudeBin: process.env.CLAUDE_BIN || "claude",
  anthropicKey: process.env.ANTHROPIC_API_KEY || "",
  classifierModel:
    process.env.SLACK_CLASSIFIER_MODEL ||
    process.env.ANTHROPIC_MODEL ||
    "claude-haiku-4-5-20251001",
  // Runaway-cost guards (see classifyViaClaude):
  classifyBudgetUsd: process.env.SLACK_CLASSIFY_BUDGET_USD || "0.05", // hard $/call cap
  classifyTimeoutMs: parseInt(process.env.SLACK_CLASSIFY_TIMEOUT_MS || "60000", 10),
  maxConcurrentClassify: parseInt(process.env.SLACK_MAX_CONCURRENT || "3", 10),
  maxNotifsPerPoll: parseInt(process.env.SLACK_MAX_NOTIFS_PER_POLL || "25", 10),
  pollIntervalMs: parseInt(process.env.SLACK_POLL_INTERVAL_MS || "5000", 10),
};

const STATE_FILE = join(__dirname, ".slack-state.json");

function parseJSON(s, fallback) {
  if (!s) return fallback;
  try {
    return JSON.parse(s);
  } catch {
    return fallback;
  }
}

// ── State (thread ↔ task mapping + notifications cursor) ──────────────────────

function loadState() {
  if (existsSync(STATE_FILE)) {
    try {
      return JSON.parse(readFileSync(STATE_FILE, "utf8"));
    } catch {
      /* fall through to fresh state */
    }
  }
  return { notifyOffset: null, threads: {}, taskThreads: {} };
}

function saveState(state) {
  writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
}

// ═════════════════════════════════════════════════════════════════════════════
// Pure helpers (exported for tests — no I/O, no network)
// ═════════════════════════════════════════════════════════════════════════════

// Remove a leading bot mention (<@U123>) and trailing/leading whitespace.
export function stripMention(text, botUserId) {
  if (!text) return "";
  let out = text;
  if (botUserId) {
    out = out.replace(new RegExp(`<@${botUserId}>`, "g"), "");
  }
  // Strip any other leading <@...> mention too.
  out = out.replace(/^\s*<@[^>]+>\s*/g, "");
  return out.trim();
}

export function isAllowed(userId, allowedUsers) {
  if (!userId) return false;
  if (!allowedUsers || allowedUsers.length === 0) return false;
  return allowedUsers.includes(userId);
}

// Map a Slack channel (by id or name) to a ty project. Falls back to default.
export function mapChannelToProject(channelKey, projectMap, defaultProject) {
  if (channelKey && projectMap) {
    if (projectMap[channelKey]) return projectMap[channelKey];
    const bare = channelKey.replace(/^#/, "");
    if (projectMap[bare]) return projectMap[bare];
    if (projectMap[`#${bare}`]) return projectMap[`#${bare}`];
  }
  return defaultProject || "";
}

// Pull a task id out of `ty create`/`ty show` output ("#123", "id: 123", JSON).
export function extractTaskId(output) {
  if (!output) return null;
  const hash = output.match(/#(\d+)/);
  if (hash) return hash[1];
  const json = output.match(/"id"\s*:\s*"?(\d+)"?/);
  if (json) return json[1];
  const id = output.match(/\bid[:=]\s*(\d+)/i);
  if (id) return id[1];
  return null;
}

// Robustly extract the JSON object from an LLM response that may wrap it in
// prose or a ```json fence.
export function parseIntentResponse(text) {
  if (!text) return null;
  let body = text.trim();
  const fence = body.match(/```(?:json)?\s*([\s\S]*?)```/i);
  if (fence) body = fence[1].trim();
  const start = body.indexOf("{");
  const end = body.lastIndexOf("}");
  if (start === -1 || end === -1 || end < start) return null;
  try {
    return JSON.parse(body.slice(start, end + 1));
  } catch {
    return null;
  }
}

// Dependency-free fallback used when no ANTHROPIC_API_KEY is set (or the API
// call fails). Good enough to keep the bridge usable; the LLM path is better.
export function heuristicIntent(text, { threadTaskId } = {}) {
  const t = (text || "").trim();
  const lower = t.toLowerCase();
  const idMatch = t.match(/(?:#|task\s*)(\d+)/i);
  const explicitId = idMatch ? idMatch[1] : null;
  const id = explicitId || threadTaskId || null;

  if (/^(help|commands|what can you do)\b/.test(lower) || !t) {
    return { action: "help" };
  }
  // Execute an EXISTING task only when the message *starts* with a run verb
  // ("run it", "execute 5"). A longer instruction that merely ends in "...and
  // run it" is a create-and-execute, handled below. "go" is intentionally
  // excluded so "go with option 2" stays input.
  if (id && /^(run|execute|start)\b/.test(lower) && lower.length < 60) {
    return { action: "execute_task", task_id: id };
  }
  if (
    /\b(status|what'?s happening|how('?s| is) it going|update|progress)\b/.test(
      lower
    ) ||
    (id && lower.includes("?"))
  ) {
    return { action: "query_status", task_id: id };
  }
  // In a known task thread, a short freeform message is most likely input.
  if (threadTaskId && lower.length < 280 && !/^(create|new task|add task)\b/.test(lower)) {
    return { action: "provide_input", task_id: threadTaskId, input: t };
  }
  // Default: create a task from the message.
  const title =
    t.split("\n")[0].replace(/^(create|new task|add task)[:\s]*/i, "").slice(0, 120) ||
    t.slice(0, 120);
  const execute = /\b(and )?(run|execute) it\b/.test(lower);
  return { action: "create_task", title, body: t, execute };
}

// Format a notifications.jsonl event into a Slack message line.
export function formatNotification(event) {
  const id = event.task_id || "?";
  const title = event.title || "";
  const project = event.project ? ` _(${event.project})_` : "";
  switch (event.event) {
    case "completed":
      return `:white_check_mark: *Task #${id} completed*: ${title}${project}`;
    case "blocked":
      return `:warning: *Task #${id} needs input*: ${title}${project}\nReply in this thread to respond, or \`@taskyou input ${id} <your answer>\`.`;
    case "failed":
      return `:x: *Task #${id} failed*: ${title}${project}`;
    case "started":
      return `:hourglass_flowing_sand: *Task #${id} started*: ${title}${project}`;
    default:
      return `*Task #${id}* (${event.event || "update"}): ${title}${project}`;
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// Slack Web API
// ═════════════════════════════════════════════════════════════════════════════

async function slack(method, body) {
  const res = await fetch(`https://slack.com/api/${method}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${CONFIG.botToken}`,
      "Content-Type": "application/json; charset=utf-8",
    },
    body: JSON.stringify(body || {}),
  });
  const json = await res.json();
  if (!json.ok) {
    throw new Error(`slack ${method} failed: ${json.error || res.status}`);
  }
  return json;
}

async function postMessage(channel, text, threadTs) {
  if (!channel) return;
  try {
    await slack("chat.postMessage", {
      channel,
      text,
      ...(threadTs ? { thread_ts: threadTs } : {}),
      unfurl_links: false,
    });
  } catch (err) {
    log(`postMessage failed: ${err.message}`);
  }
}

// Resolve a channel id → "#name" once, cached, for project mapping.
const channelNameCache = new Map();
async function channelName(channelId) {
  if (!channelId) return "";
  if (channelNameCache.has(channelId)) return channelNameCache.get(channelId);
  try {
    const info = await slack("conversations.info", { channel: channelId });
    const name = info.channel?.name ? `#${info.channel.name}` : channelId;
    channelNameCache.set(channelId, name);
    return name;
  } catch {
    return channelId;
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// ty bridge (runs ty locally — the bridge lives on the agents server)
// ═════════════════════════════════════════════════════════════════════════════

function ty(args) {
  try {
    return execFileSync(CONFIG.tyPath, args, {
      encoding: "utf8",
      timeout: 30_000,
    }).trim();
  } catch (err) {
    const stderr = err.stderr ? err.stderr.toString().trim() : "";
    throw new Error(stderr || err.message);
  }
}

function createTask(project, title, body, execute) {
  const args = ["create", title, "--type", "draft"];
  if (project) args.push("--project", project);
  if (body) args.push("--body", body);
  if (execute) args.push("--execute");
  return ty(args);
}

// ═════════════════════════════════════════════════════════════════════════════
// Intent classification
// ═════════════════════════════════════════════════════════════════════════════

const CLASSIFIER_SYSTEM = [
  "You route Slack messages to TaskYou (a task runner driven by the `ty` CLI).",
  "Classify the message into exactly one action and reply with ONLY a JSON object:",
  '{"action":"create_task|provide_input|execute_task|query_status|help",',
  ' "title":"short task title (create_task)",',
  ' "body":"full task description (create_task)",',
  ' "execute":true|false (create_task: run immediately if the user says so),',
  ' "task_id":"id (provide_input/execute_task/query_status)",',
  ' "input":"the answer text (provide_input)",',
  ' "reply":"optional one-line human reply"}',
  "Rules: if the message is a reply within a known task thread, prefer provide_input for that task.",
  "If the user clearly asks to run/execute an existing task, use execute_task.",
  "If they ask how things are going / for status, use query_status.",
  "Otherwise create_task. Never include commentary outside the JSON.",
].join("\n");

// Pure: assemble the user-facing context block (exported for tests).
export function buildClassifierContext(text, { threadTaskId, openTasks } = {}) {
  return [
    threadTaskId ? `This message is in the thread for task #${threadTaskId}.` : "",
    openTasks && openTasks.length
      ? `Open tasks: ${openTasks
          .slice(0, 20)
          .map((t) => `#${t.id} ${t.title}`)
          .join("; ")}`
      : "",
    `Message: ${text}`,
  ]
    .filter(Boolean)
    .join("\n");
}

// Detect the on-box claude CLI once (cached).
let _claudeChecked = false;
let _claudeAvailable = false;
function hasClaudeCli() {
  if (_claudeChecked) return _claudeAvailable;
  _claudeChecked = true;
  try {
    execFileSync(CONFIG.claudeBin, ["--version"], { stdio: "ignore", timeout: 10_000 });
    _claudeAvailable = true;
  } catch {
    _claudeAvailable = false;
  }
  return _claudeAvailable;
}

// Classify via the local, already-authenticated `claude` CLI — no API key.
// Hardened so a hostile or odd Slack message can't trigger an agentic loop or
// runaway spend:
//   --strict-mcp-config --mcp-config {} → no MCP servers (no taskyou/other tools)
//   --disallowedTools ...               → no Bash/Read/Write/etc. → single turn
//   --max-budget-usd                    → hard per-call cost ceiling
//   timeout + maxBuffer, no retry       → bounded wall-clock + memory
// Any failure returns null so the caller falls back (API → heuristic).
function classifyViaClaude(prompt) {
  try {
    const out = execFileSync(
      CONFIG.claudeBin,
      [
        "-p",
        "--output-format", "json",
        "--model", CONFIG.classifierModel,
        "--strict-mcp-config",
        "--mcp-config", '{"mcpServers":{}}',
        "--disallowedTools",
        "Bash,Read,Edit,Write,WebFetch,WebSearch,Task,Glob,Grep,NotebookEdit",
        "--max-budget-usd", String(CONFIG.classifyBudgetUsd),
      ],
      {
        input: prompt,
        encoding: "utf8",
        timeout: CONFIG.classifyTimeoutMs,
        maxBuffer: 4 * 1024 * 1024,
      }
    );
    let text = out;
    try {
      const env = JSON.parse(out);
      if (env && typeof env.result === "string") text = env.result;
    } catch {
      /* not a JSON envelope — treat stdout as the raw answer */
    }
    return parseIntentResponse(text);
  } catch (err) {
    log(`claude -p classify failed (${err.message}); falling back`);
    return null;
  }
}

async function classifyViaApi(context) {
  try {
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": CONFIG.anthropicKey,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model: CONFIG.classifierModel,
        max_tokens: 512, // bounded output
        system: CLASSIFIER_SYSTEM,
        messages: [{ role: "user", content: context }],
      }),
    });
    const json = await res.json();
    const out = json.content?.map((c) => c.text || "").join("") || "";
    return parseIntentResponse(out);
  } catch (err) {
    log(`anthropic api classify failed (${err.message}); falling back`);
    return null;
  }
}

async function classifyIntent(text, { threadTaskId, openTasks } = {}) {
  const mode = CONFIG.classifierMode;
  const context = buildClassifierContext(text, { threadTaskId, openTasks });

  // 1) On-box claude CLI (default). No API key; reuses claude.ai login.
  if ((mode === "auto" || mode === "claude") && hasClaudeCli()) {
    const r = classifyViaClaude(`${CLASSIFIER_SYSTEM}\n\n${context}`);
    if (r && r.action) return r;
  }
  // 2) Anthropic API, only if a key is explicitly configured.
  if ((mode === "auto" || mode === "api") && CONFIG.anthropicKey) {
    const r = await classifyViaApi(context);
    if (r && r.action) return r;
  }
  // 3) Dependency-free keyword heuristic — no network, no spend.
  return heuristicIntent(text, { threadTaskId });
}

// ═════════════════════════════════════════════════════════════════════════════
// Inbound: Slack message → ty
// ═════════════════════════════════════════════════════════════════════════════

let BOT_USER_ID = "";
const seenEvents = new Set(); // event_id dedup (Slack retries)
let inFlight = 0; // concurrent classify/dispatch — bounds claude -p spawns + spend

async function handleMessageEvent(event, state) {
  // Self-loop guard: never react to our own posts or any bot/edited/system
  // message. Our replies carry bot_id (and subtype bot_message), so these
  // filters prevent an infinite reply→classify→reply loop even if BOT_USER_ID
  // failed to resolve at startup.
  if (event.bot_id || event.subtype) return;
  if (event.user && event.user === BOT_USER_ID) return;

  const requester = event.user;
  if (!isAllowed(requester, CONFIG.allowedUsers)) {
    log(`ignoring message from non-allowlisted user ${requester}`);
    return;
  }

  const text = stripMention(event.text || "", BOT_USER_ID);
  if (!text) return;

  const channel = event.channel;
  const threadTs = event.thread_ts || event.ts;

  // Concurrency cap: don't let a burst of messages spawn unbounded classifier
  // subprocesses (CPU + token spend). Excess requests are declined, not queued.
  if (inFlight >= CONFIG.maxConcurrentClassify) {
    log(`busy (${inFlight} in flight) — declining message from ${requester}`);
    try {
      await postMessage(channel, ":hourglass: One sec — finishing a few requests. Try again in a moment.", threadTs);
    } catch {}
    return;
  }

  inFlight++;
  try {
    const threadTaskId = state.threads[event.thread_ts] || null;

    let openTasks = [];
    try {
      openTasks = JSON.parse(ty(["list", "--all", "--json"]));
    } catch {
      /* listing is best-effort context only */
    }

    const intent = await classifyIntent(text, { threadTaskId, openTasks });
    log(`intent: ${intent.action}${intent.task_id ? ` #${intent.task_id}` : ""}`);

    try {
      await dispatchIntent(intent, { channel, threadTs, requester, text }, state);
    } catch (err) {
      await postMessage(channel, `:x: ${err.message}`, threadTs);
    }
  } finally {
    inFlight--;
  }
}

async function dispatchIntent(intent, ctx, state) {
  const { channel, threadTs } = ctx;

  switch (intent.action) {
    case "create_task": {
      const chanName = await channelName(channel);
      const project =
        intent.project ||
        mapChannelToProject(chanName, CONFIG.projectMap, CONFIG.defaultProject);
      const title = intent.title || ctx.text.slice(0, 120);
      const out = createTask(project, title, intent.body || ctx.text, !!intent.execute);
      const taskId = extractTaskId(out);
      if (taskId) {
        state.threads[threadTs] = taskId;
        state.taskThreads[taskId] = { channel, thread_ts: threadTs };
        saveState(state);
      }
      const ran = intent.execute ? " and started it" : "";
      await postMessage(
        channel,
        intent.reply ||
          `:memo: Created *task #${taskId || "?"}*${project ? ` in _${project}_` : ""}${ran}: ${title}`,
        threadTs
      );
      return;
    }

    case "provide_input": {
      const taskId = intent.task_id || state.threads[threadTs];
      if (!taskId) {
        await postMessage(channel, "Which task is this for? Mention a task number.", threadTs);
        return;
      }
      ty(["input", String(taskId), intent.input || ctx.text]);
      await postMessage(
        channel,
        intent.reply || `:incoming_envelope: Sent your input to *task #${taskId}*.`,
        threadTs
      );
      return;
    }

    case "execute_task": {
      const taskId = intent.task_id;
      if (!taskId) {
        await postMessage(channel, "Which task should I run? Mention a task number.", threadTs);
        return;
      }
      ty(["execute", String(taskId)]);
      state.taskThreads[taskId] = { channel, thread_ts: threadTs };
      saveState(state);
      await postMessage(
        channel,
        intent.reply ||
          `:rocket: Started *task #${taskId}*. I'll post back here when it finishes or needs you.`,
        threadTs
      );
      return;
    }

    case "query_status": {
      let body;
      if (intent.task_id) {
        body = ty(["show", String(intent.task_id)]);
      } else {
        body = ty(["list", "--all"]);
      }
      const trimmed = body.length > 3500 ? body.slice(0, 3500) + "\n…(truncated)" : body;
      await postMessage(channel, "```\n" + trimmed + "\n```", threadTs);
      return;
    }

    case "help":
    default:
      await postMessage(channel, HELP_TEXT, threadTs);
  }
}

const HELP_TEXT = [
  "*TaskYou Slack bridge* — mention me or DM me:",
  "• `@taskyou fix the checkout 500s and run it` — create a task (add “run it” to execute now)",
  "• reply in a task's thread — send input to that task",
  "• `@taskyou run task 312` — execute an existing task",
  "• `@taskyou status of 312` / `@taskyou what's on the board?` — get status",
].join("\n");

// ═════════════════════════════════════════════════════════════════════════════
// Outbound: notifications.jsonl → Slack
// ═════════════════════════════════════════════════════════════════════════════

export function readNewChunk(path, fromOffset) {
  // Returns { lines, baseOffset } where `lines` are COMPLETE raw lines only (up
  // to the last newline) — a half-written hook line is left for the next tick
  // instead of being parsed-then-skipped (which would lose it). On first read
  // (fromOffset === null) we skip the existing backlog. Handles truncation.
  if (!existsSync(path)) return { lines: [], baseOffset: fromOffset };
  const size = statSync(path).size;
  if (fromOffset === null) return { lines: [], baseOffset: size };
  let base = fromOffset;
  if (size < base) base = 0; // file shrank → rotated/truncated
  if (size === base) return { lines: [], baseOffset: base };

  const fd = openSync(path, "r");
  try {
    const len = size - base;
    const buf = Buffer.alloc(len);
    readSync(fd, buf, 0, len, base);
    const lastNl = buf.lastIndexOf(0x0a);
    if (lastNl === -1) return { lines: [], baseOffset: base }; // no complete line yet
    const text = buf.toString("utf8", 0, lastNl + 1);
    const lines = text.split("\n").slice(0, -1); // raw lines, keep byte parity
    return { lines, baseOffset: base };
  } finally {
    closeSync(fd);
  }
}

async function pollNotifications(state) {
  const { lines, baseOffset } = readNewChunk(CONFIG.notificationsFile, state.notifyOffset);

  // First run (no cursor yet): just record EOF, skipping the backlog. This also
  // means a lost/corrupt state file does NOT replay history into Slack.
  if (state.notifyOffset === null) {
    state.notifyOffset = baseOffset;
    saveState(state);
    return;
  }
  if (lines.length === 0) {
    if (baseOffset !== state.notifyOffset) {
      state.notifyOffset = baseOffset;
      saveState(state);
    }
    return;
  }

  // Rate cap: an abnormal flood (or a misconfigured file) can't storm Slack.
  // Excess lines aren't dropped — we advance the cursor only past what we post
  // and drain the rest on later ticks (byte-accurate so nothing is skipped).
  const take = lines.slice(0, CONFIG.maxNotifsPerPoll);
  if (take.length < lines.length) {
    log(`notifications: ${take.length}/${lines.length} this tick (cap ${CONFIG.maxNotifsPerPoll}); draining rest`);
  }
  state.notifyOffset = baseOffset + Buffer.byteLength(take.join("\n") + "\n", "utf8");
  saveState(state); // advance BEFORE posting so a failed post never re-storms

  for (const line of take) {
    if (!line.trim()) continue;
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      continue;
    }
    const msg = formatNotification(event);
    const mapping = event.task_id ? state.taskThreads[String(event.task_id)] : null;
    if (mapping) {
      // Task originated from / was run via Slack — answer in its thread.
      await postMessage(mapping.channel, msg, mapping.thread_ts);
    } else if (CONFIG.notifyChannel) {
      await postMessage(CONFIG.notifyChannel, msg);
    }
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// Socket Mode (inbound transport — no public URL needed)
// ═════════════════════════════════════════════════════════════════════════════

async function openSocket() {
  const res = await fetch("https://slack.com/api/apps.connections.open", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${CONFIG.appToken}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
  });
  const json = await res.json();
  if (!json.ok) throw new Error(`apps.connections.open failed: ${json.error}`);
  return json.url;
}

// Monotonic generation: only the newest connection's handlers stay live, so a
// reconnect race can't leave two sockets both delivering events (which would
// double-process every message and multiply classifier spend).
let socketGen = 0;

function connectSocket(state) {
  const gen = ++socketGen;
  let ws;
  openSocket()
    .then((url) => {
      if (gen !== socketGen) return; // superseded while connecting — abandon
      ws = new WebSocket(url);

      ws.addEventListener("open", () => log("Socket Mode connected"));

      ws.addEventListener("message", (ev) => {
        if (gen !== socketGen) return; // stale socket — ignore
        let frame;
        try {
          frame = JSON.parse(ev.data);
        } catch {
          return;
        }

        // Slack asks us to reconnect before it drops the socket.
        if (frame.type === "disconnect") {
          log(`Socket disconnect (${frame.reason || "?"}); reconnecting`);
          try {
            ws.close();
          } catch {}
          return;
        }

        // Ack every envelope immediately (Slack requires < 3s). Acking before we
        // process also stops Slack from retrying the event (and re-triggering
        // classification); event_id dedup below catches any that still slip.
        if (frame.envelope_id) {
          try {
            ws.send(JSON.stringify({ envelope_id: frame.envelope_id }));
          } catch {}
        }

        if (frame.type !== "events_api") return;
        const payload = frame.payload || {};
        const eventId = payload.event_id;
        if (eventId) {
          if (seenEvents.has(eventId)) return; // Slack retry
          seenEvents.add(eventId);
          if (seenEvents.size > 1000) {
            // bound memory
            seenEvents.delete(seenEvents.values().next().value);
          }
        }
        const event = payload.event;
        if (!event) return;
        if (event.type === "app_mention" || event.type === "message") {
          handleMessageEvent(event, state).catch((err) =>
            log(`handler error: ${err.message}`)
          );
        }
      });

      ws.addEventListener("close", () => {
        if (gen !== socketGen) return; // a newer socket already took over
        log("Socket closed; reconnecting in 3s");
        setTimeout(() => connectSocket(state), 3000);
      });

      ws.addEventListener("error", (err) => {
        log(`Socket error: ${err?.message || err}`);
        try {
          ws.close();
        } catch {}
      });
    })
    .catch((err) => {
      if (gen !== socketGen) return;
      log(`openSocket failed: ${err.message}; retrying in 10s`);
      setTimeout(() => connectSocket(state), 10_000);
    });
}

// ═════════════════════════════════════════════════════════════════════════════
// Main
// ═════════════════════════════════════════════════════════════════════════════

function log(msg) {
  console.log(`[${new Date().toISOString()}] ${msg}`);
}

async function main() {
  if (!CONFIG.botToken) {
    console.error("SLACK_BOT_TOKEN is required");
    process.exit(1);
  }

  const state = loadState();

  // Resolve our own bot user id (to strip mentions and ignore our own posts).
  try {
    const auth = await slack("auth.test", {});
    BOT_USER_ID = auth.user_id || "";
    log(`authenticated as ${auth.user || BOT_USER_ID} in ${auth.team || "?"}`);
  } catch (err) {
    log(`auth.test failed (outbound only until fixed): ${err.message}`);
  }

  // Outbound: poll notifications.jsonl.
  await pollNotifications(state);
  setInterval(() => {
    pollNotifications(state).catch((err) => log(`poll error: ${err.message}`));
  }, CONFIG.pollIntervalMs);

  // Inbound: Socket Mode (only if an app token is configured).
  if (CONFIG.appToken) {
    connectSocket(state);
  } else {
    log("no SLACK_APP_TOKEN — outbound notifications only (no inbound control)");
  }

  log("slack-bridge started");
}

const isMain =
  process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  main().catch((err) => {
    console.error(`fatal: ${err.message}`);
    process.exit(1);
  });
}
