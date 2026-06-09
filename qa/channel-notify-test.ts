#!/usr/bin/env bun
// Channel notification end-to-end test.
//
// Unlike smoke-test.ts (handshake + capabilities only), this exercises the full
// chain the feature actually depends on:
//
//   rendered hook  →  notifications.jsonl  →  channel runner (local/SSH)  →  push
//
// It spawns the *rendered* channel server, does the MCP handshake, then fires the
// real rendered task.completed hook and asserts the channel pushes a matching
// `notifications/claude/channel` event back out over stdio.
//
// Driven by env vars (set by run-qa.sh):
//   CHANNEL_TS   absolute path to the rendered taskyou-channel.ts
//   NOTIF_FILE   absolute path to notifications.jsonl (== {{SERVER_HOME}}/notifications.jsonl)
//   HOOK_SCRIPT  absolute path to the rendered task.completed hook
//   MODE         "steady" (default): start with a pre-existing line, assert the
//                  new event is delivered and the pre-existing backlog is NOT replayed.
//                "cold":   start from an EMPTY file, assert the very first event
//                  is still delivered (regression test for the cold-start fix).
//   POLL_WAIT_MS optional override for how long we wait for a poll cycle (default 14000)
//
// Exit 0 = PASS, non-zero = FAIL.

import { spawn, spawnSync } from "child_process";
import { appendFileSync, existsSync } from "fs";

const CHANNEL_TS = process.env.CHANNEL_TS!;
const NOTIF_FILE = process.env.NOTIF_FILE!;
const HOOK_SCRIPT = process.env.HOOK_SCRIPT!;
const POLL_WAIT_MS = parseInt(process.env.POLL_WAIT_MS || "14000", 10);
const MODE = process.env.MODE === "cold" ? "cold" : "steady";

const TASK_ID = "qa-9999";

function die(msg: string): never {
  console.log(`✗ ${msg}`);
  console.log("\nFAILED");
  process.exit(1);
}

for (const [k, v] of Object.entries({ CHANNEL_TS, NOTIF_FILE, HOOK_SCRIPT })) {
  if (!v || !existsSync(v)) die(`${k} missing or not found: ${v}`);
}

// 1. steady mode: seed one pre-existing line, so we can assert the channel skips
//    the startup backlog (must NOT replay it) yet still delivers the next event.
//    cold mode: leave the file empty, so we assert the very first event written
//    after startup IS delivered (the bug the `initialized` fix closes).
if (MODE === "steady") {
  appendFileSync(
    NOTIF_FILE,
    JSON.stringify({
      event: "completed",
      task_id: "qa-seed",
      title: "seed (must not be replayed)",
      project: "qa-test",
      timestamp: new Date(0).toISOString(),
    }) + "\n"
  );
}

// 2. Spawn the rendered channel server.
const proc = spawn("bun", ["run", CHANNEL_TS], {
  stdio: ["pipe", "pipe", "pipe"],
});

let pushed: any = null;
let sawSeedReplay = false;
let sawForeign = false; // an event from a project this GM doesn't own — must be filtered
let toolEcho = "";      // ssh_command({command}) result — proves the tool runs locally
let toolEchoAlt = "";   // ssh_command({args}) result — proves robust arg parsing (no "ty undefined")
let buf = "";
const FOREIGN_ID = "qa-foreign";

proc.stdout.on("data", (d: Buffer) => {
  buf += d.toString();
  const lines = buf.split("\n");
  buf = lines.pop() || "";
  for (const line of lines) {
    if (!line.trim()) continue;
    let msg: any;
    try {
      msg = JSON.parse(line);
    } catch {
      continue;
    }
    if (msg.method === "notifications/claude/channel") {
      const meta = msg.params?.meta || {};
      if (meta.task_id === "qa-seed") sawSeedReplay = true;
      if (meta.task_id === FOREIGN_ID) sawForeign = true;
      if (meta.task_id === TASK_ID) pushed = msg;
    }
    // tool-call responses (id 3 = correct param, id 4 = wrong param name)
    if (msg.id === 3) toolEcho = msg.result?.content?.[0]?.text || "";
    if (msg.id === 4) toolEchoAlt = msg.result?.content?.[0]?.text || "";
  }
});

let stderr = "";
proc.stderr.on("data", (d: Buffer) => (stderr += d.toString()));

const fail = (msg: string) => {
  console.log(`✗ ${msg}`);
  if (stderr.trim()) console.log("channel stderr:", stderr.trim());
  console.log("\nFAILED");
  proc.kill();
  process.exit(1);
};

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

(async () => {
  // 3. MCP initialize handshake.
  proc.stdin.write(
    JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: "2024-11-05",
        capabilities: {},
        clientInfo: { name: "channel-notify-test", version: "0.0.1" },
      },
    }) + "\n"
  );

  // 3b. Exercise the tools through MCP. Both must run locally (no SSH) and
  //     return output. id=4 deliberately uses the WRONG param name (`args` on
  //     ssh_command) to prove the robust parsing doesn't send `undefined`.
  proc.stdin.write(
    JSON.stringify({
      jsonrpc: "2.0", id: 3, method: "tools/call",
      params: { name: "ssh_command", arguments: { command: "echo TOOLOK" } },
    }) + "\n"
  );
  proc.stdin.write(
    JSON.stringify({
      jsonrpc: "2.0", id: 4, method: "tools/call",
      params: { name: "ssh_command", arguments: { args: "echo VIAARGS" } },
    }) + "\n"
  );

  // 4. Let the startup poll record its position (lastLineCount = 1 from the seed).
  await sleep(2500);

  // 5a. Fire a FOREIGN-project event first — the channel (rendered with
  //     PROJECTS=qa-test) must filter it out and never push it.
  spawnSync("bash", [HOOK_SCRIPT], {
    env: { ...process.env, TASK_ID: FOREIGN_ID, TASK_TITLE: "other GM's task", TASK_PROJECT: "some-other-gm" },
    encoding: "utf8",
  });

  // 5b. Fire the REAL rendered hook for THIS GM's project — appends to notifications.jsonl.
  const r = spawnSync("bash", [HOOK_SCRIPT], {
    env: {
      ...process.env,
      TASK_ID,
      TASK_TITLE: 'QA notify "end to end"', // embedded quotes test JSON escaping
      TASK_PROJECT: "qa-test",
    },
    encoding: "utf8",
  });
  if (r.status !== 0) fail(`hook exited ${r.status}: ${r.stderr}`);

  // 6. Wait for the next poll cycle to detect + push the new line.
  await sleep(POLL_WAIT_MS);

  if (MODE === "steady" && sawSeedReplay)
    fail("channel REPLAYED the pre-existing seed line on startup (should not)");
  if (!pushed)
    fail(
      MODE === "cold"
        ? `cold start: first event (${TASK_ID}) was swallowed — the initialized fix is missing`
        : `no channel push for task ${TASK_ID} within ${POLL_WAIT_MS}ms`
    );

  if (sawForeign)
    fail("channel pushed a foreign-project event — project filter not working");
  if (!toolEcho.includes("TOOLOK"))
    fail(`ssh_command({command}) did not run locally — got: ${JSON.stringify(toolEcho)}`);
  if (!toolEchoAlt.includes("VIAARGS"))
    fail(`ssh_command({args}) (wrong param) not handled robustly — got: ${JSON.stringify(toolEchoAlt)}`);

  const content = pushed.params?.content || "";
  if (!content.includes(TASK_ID)) fail("pushed event content missing task id");
  if (!content.includes("end to end")) fail("pushed event lost the hook title (JSON escaping?)");

  console.log(`✓ [${MODE}] channel pushed completed event for ${TASK_ID}`);
  if (MODE === "steady") console.log(`✓ did not replay pre-existing notifications on startup`);
  if (MODE === "cold") console.log(`✓ first event after empty-file start was delivered (cold-start fix)`);
  console.log(`✓ foreign-project event was filtered out (not pushed)`);
  console.log(`✓ ssh_command ran locally; robust to wrong param name (no "undefined")`);
  console.log(`✓ title with embedded quotes survived hook→channel`);
  console.log("\nPASSED");
  proc.kill();
  process.exit(0);
})();

setTimeout(() => fail("overall test timeout"), POLL_WAIT_MS + 12000);
