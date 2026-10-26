#!/usr/bin/env node
// trace-summary.js — say what a session spent its turns on.
//
// Usage: trace-summary.js <session.jsonl>
// Exit:  0 always. This reports; it never decides whether a run passed.
//
// The result document records how many turns a session used and what it cost,
// but not what it did. Two runs of the same input, one green at 59 turns and
// one red at 81, produce summaries that look alike. The difference is in the
// tool calls, so this counts them.
//
// Contract: specs/platform/agent-runtime.spec.md — Workspace Contract

"use strict";

const fs = require("fs");

const path = process.argv[2];
if (!path || !fs.existsSync(path)) {
  console.error("trace-summary: no trace to summarise");
  process.exit(0);
}

const events = fs
  .readFileSync(path, "utf8")
  .split("\n")
  .filter(Boolean)
  .map((line) => {
    try {
      return JSON.parse(line);
    } catch {
      return null;
    }
  })
  .filter(Boolean);

// A tool call is a content block inside an assistant message. Targets are
// collected alongside the counts because "Read ×40" and "Read of 40 different
// files" are different problems: the first is one file being paged through,
// the second is an agent that does not know where to look.
const byTool = new Map();
const repeated = new Map();

for (const event of events) {
  const content = event?.message?.content;
  if (event.type !== "assistant" || !Array.isArray(content)) continue;

  for (const block of content) {
    if (block.type !== "tool_use") continue;
    const name = block.name || "?";
    byTool.set(name, (byTool.get(name) || 0) + 1);

    const input = block.input || {};
    const target =
      input.file_path || input.pattern || input.command || input.path;
    if (target) {
      const key = `${name} ${String(target).slice(0, 70)}`;
      repeated.set(key, (repeated.get(key) || 0) + 1);
    }
  }
}

const total = [...byTool.values()].reduce((a, b) => a + b, 0);
if (total === 0) {
  console.error("run-agent: trace contains no tool calls");
  process.exit(0);
}

console.error(`run-agent: tool calls (${total} across the session)`);
for (const [name, count] of [...byTool].sort((a, b) => b[1] - a[1])) {
  console.error(`run-agent:   ${String(count).padStart(3)}  ${name}`);
}

// Only repeats are listed. A target touched once is the agent working; the
// same target touched five times is where the budget went.
const hotspots = [...repeated]
  .filter(([, n]) => n > 1)
  .sort((a, b) => b[1] - a[1])
  .slice(0, 8);

if (hotspots.length) {
  console.error("run-agent: repeated targets");
  for (const [target, count] of hotspots) {
    console.error(`run-agent:   ${String(count).padStart(3)}x ${target}`);
  }
}

process.exit(0);
