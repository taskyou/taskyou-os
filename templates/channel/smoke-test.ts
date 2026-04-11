#!/usr/bin/env bun
// Smoke test: spawn the channel server, do the MCP handshake, verify capabilities and tools.
// Usage: bun run smoke-test.ts
// Requires: taskyou-channel.ts in the same directory (rendered with any server values — they don't matter for this test).

import { spawn } from "child_process";

const proc = spawn("bun", ["run", "taskyou-channel.ts"], {
  cwd: import.meta.dir,
  stdio: ["pipe", "pipe", "pipe"],
});

let stdout = "";
proc.stdout.on("data", (d: Buffer) => {
  stdout += d.toString();
  const lines = stdout.split("\n");
  for (const line of lines.slice(0, -1)) {
    if (!line.trim()) continue;
    try {
      const msg = JSON.parse(line);
      if (msg.id === 1) {
        handleInitResponse(msg);
      } else if (msg.id === 2) {
        handleToolsResponse(msg);
      }
    } catch {}
  }
  stdout = lines[lines.length - 1];
});

let stderr = "";
proc.stderr.on("data", (d: Buffer) => {
  stderr += d.toString();
});

proc.on("close", (code) => {
  if (code !== 0 && code !== null) {
    console.log(`Process exited with code ${code}`);
    if (stderr) console.log("stderr:", stderr);
    process.exit(1);
  }
});

function handleInitResponse(msg: any) {
  const caps = msg.result?.capabilities?.experimental;
  const hasChannel = !!caps?.["claude/channel"];
  const hasTools = !!msg.result?.capabilities?.tools;
  const hasInstructions = msg.result?.instructions?.includes("taskyou");

  console.log(`${hasChannel ? "✓" : "✗"} claude/channel capability`);
  console.log(`${hasTools ? "✓" : "✗"} tools capability`);
  console.log(`${hasInstructions ? "✓" : "✗"} instructions`);

  if (!hasChannel || !hasTools || !hasInstructions) {
    console.log("\nFAILED — missing capabilities");
    proc.kill();
    process.exit(1);
  }

  // Request tool list
  proc.stdin.write(
    JSON.stringify({
      jsonrpc: "2.0",
      id: 2,
      method: "tools/list",
      params: {},
    }) + "\n"
  );
}

function handleToolsResponse(msg: any) {
  const tools = msg.result?.tools || [];
  const names = tools.map((t: any) => t.name);

  const hasTy = names.includes("ty_command");
  const hasSsh = names.includes("ssh_command");

  console.log(`${hasTy ? "✓" : "✗"} ty_command tool`);
  console.log(`${hasSsh ? "✓" : "✗"} ssh_command tool`);

  if (!hasTy || !hasSsh) {
    console.log("\nFAILED — missing tools");
    proc.kill();
    process.exit(1);
  }

  console.log("\nPASSED");
  proc.kill();
  process.exit(0);
}

// Send MCP initialize
proc.stdin.write(
  JSON.stringify({
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "smoke-test", version: "0.0.1" },
    },
  }) + "\n"
);

setTimeout(() => {
  console.log("FAILED — timed out");
  if (stderr) console.log("stderr:", stderr);
  proc.kill();
  process.exit(1);
}, 10_000);
