#!/usr/bin/env node
// Unit tests for the pure helpers in slack-bridge.mjs.
// Run: node --test  (from modules/slack/)
//
// These cover the logic that can be tested without Slack/Anthropic/ty:
// intent parsing + fallback, allow-listing, channel→project mapping,
// task-id extraction, and notification formatting.

import { test } from "node:test";
import assert from "node:assert/strict";
import { writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";

import {
  stripMention,
  isAllowed,
  mapChannelToProject,
  extractTaskId,
  parseIntentResponse,
  heuristicIntent,
  formatNotification,
  buildClassifierContext,
  readNewChunk,
} from "./slack-bridge.mjs";

test("stripMention removes the bot mention and trims", () => {
  assert.equal(stripMention("<@U123> fix the bug", "U123"), "fix the bug");
  assert.equal(stripMention("<@U999> hello", "U123"), "hello"); // any leading mention
  assert.equal(stripMention("no mention here", "U123"), "no mention here");
  assert.equal(stripMention("", "U123"), "");
});

test("isAllowed enforces the allowlist", () => {
  assert.equal(isAllowed("U1", ["U1", "U2"]), true);
  assert.equal(isAllowed("U3", ["U1", "U2"]), false);
  assert.equal(isAllowed("U1", []), false); // empty allowlist denies all
  assert.equal(isAllowed("", ["U1"]), false);
});

test("mapChannelToProject matches by name, #name, or id, else default", () => {
  const map = { "#eng": "workflow", content: "content" };
  assert.equal(mapChannelToProject("#eng", map, "default"), "workflow");
  assert.equal(mapChannelToProject("eng", map, "default"), "workflow"); // bare name
  assert.equal(mapChannelToProject("#content", map, "default"), "content"); // add #
  assert.equal(mapChannelToProject("#random", map, "default"), "default");
  assert.equal(mapChannelToProject("C123", {}, "default"), "default");
});

test("extractTaskId handles #N, JSON, and id: forms", () => {
  assert.equal(extractTaskId("Created task #312"), "312");
  assert.equal(extractTaskId('{"id":"45","title":"x"}'), "45");
  assert.equal(extractTaskId('{"id": 99}'), "99");
  assert.equal(extractTaskId("id: 7"), "7");
  assert.equal(extractTaskId("nothing here"), null);
});

test("parseIntentResponse extracts JSON from fences and prose", () => {
  assert.deepEqual(parseIntentResponse('{"action":"help"}'), { action: "help" });
  assert.deepEqual(
    parseIntentResponse('```json\n{"action":"create_task","title":"x"}\n```'),
    { action: "create_task", title: "x" }
  );
  assert.deepEqual(
    parseIntentResponse('Sure! {"action":"execute_task","task_id":"5"} done'),
    { action: "execute_task", task_id: "5" }
  );
  assert.equal(parseIntentResponse("not json"), null);
  assert.equal(parseIntentResponse(""), null);
});

test("heuristicIntent: execute when a thread/task id + run verb", () => {
  const r = heuristicIntent("run it", { threadTaskId: "10" });
  assert.equal(r.action, "execute_task");
  assert.equal(r.task_id, "10");
});

test("heuristicIntent: status questions", () => {
  assert.equal(heuristicIntent("what's the status of #5?").action, "query_status");
  assert.equal(heuristicIntent("how's it going?", { threadTaskId: "5" }).action, "query_status");
});

test("heuristicIntent: reply in a task thread becomes input", () => {
  const r = heuristicIntent("go with option 2", { threadTaskId: "8" });
  assert.equal(r.action, "provide_input");
  assert.equal(r.task_id, "8");
  assert.equal(r.input, "go with option 2");
});

test("heuristicIntent: default is create, detects 'run it'", () => {
  const a = heuristicIntent("Fix the checkout 500s");
  assert.equal(a.action, "create_task");
  assert.equal(a.execute, false);

  const b = heuristicIntent("Fix the checkout and run it");
  assert.equal(b.action, "create_task");
  assert.equal(b.execute, true);
  assert.ok(b.title.length > 0);
});

test("heuristicIntent: empty/help", () => {
  assert.equal(heuristicIntent("").action, "help");
  assert.equal(heuristicIntent("help").action, "help");
});

test("formatNotification renders each event type", () => {
  assert.match(
    formatNotification({ event: "completed", task_id: "1", title: "Ship it", project: "web" }),
    /completed.*Ship it.*web/s
  );
  assert.match(
    formatNotification({ event: "blocked", task_id: "2", title: "Need answer" }),
    /needs input.*Need answer/s
  );
  assert.match(formatNotification({ event: "failed", task_id: "3", title: "Oops" }), /failed.*Oops/);
  assert.match(formatNotification({ event: "weird", task_id: "4", title: "Huh" }), /Task #4/);
});

test("formatNotification renders Claude auth events without a task_id", () => {
  // These come from claude-auth-monitor.sh, which has no task to reference.
  // The old default branch would have rendered them as "Task #? (auth_failed)".
  const failed = formatNotification({
    event: "auth_failed",
    title: "Claude login on agents-1 has expired — run 'claude /login' as exedev.",
    project: "engineering",
  });
  assert.match(failed, /Claude login expired/);
  assert.match(failed, /claude \/login/);
  assert.doesNotMatch(failed, /Task #/);

  const expiring = formatNotification({
    event: "auth_expiring",
    title: "Claude login on agents-1 expires in 3 day(s).",
    days_remaining: 3,
    project: "engineering",
  });
  assert.match(expiring, /expires soon/);
  assert.match(expiring, /3 days left/);
  assert.doesNotMatch(expiring, /Task #/);

  // Singular day, and a missing day count must not print "NaN".
  assert.match(
    formatNotification({ event: "auth_expiring", title: "x", days_remaining: 1 }),
    /1 day left/
  );
  assert.doesNotMatch(
    formatNotification({ event: "auth_expiring", title: "x" }),
    /NaN|undefined/
  );
});

test("buildClassifierContext includes thread + open tasks + message", () => {
  const ctx = buildClassifierContext("do the thing", {
    threadTaskId: "12",
    openTasks: [{ id: 1, title: "A" }, { id: 2, title: "B" }],
  });
  assert.match(ctx, /thread for task #12/);
  assert.match(ctx, /#1 A; #2 B/);
  assert.match(ctx, /Message: do the thing/);
  // minimal case: just the message
  assert.equal(buildClassifierContext("hi", {}), "Message: hi");
});

test("readNewChunk: only complete lines; partial last line is held back", () => {
  const f = join(import.meta.dirname, ".test-notif.tmp");
  try {
    // three complete lines, then a half-written one (no trailing newline)
    writeFileSync(f, 'a\nb\nc\n{"half":');
    const r = readNewChunk(f, 0);
    assert.deepEqual(r.lines, ["a", "b", "c"]); // partial line excluded
    assert.equal(r.baseOffset, 0);

    // cursor at EOF of the complete portion → nothing new
    const consumed = Buffer.byteLength("a\nb\nc\n", "utf8");
    assert.deepEqual(readNewChunk(f, consumed).lines, []);

    // first run (null) skips the backlog entirely
    assert.deepEqual(readNewChunk(f, null).lines, []);

    // truncation/rotation: offset past EOF resets to start
    assert.deepEqual(readNewChunk(f, 9999).lines, ["a", "b", "c"]);
  } finally {
    rmSync(f, { force: true });
  }
});
