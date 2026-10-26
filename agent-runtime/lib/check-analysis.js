#!/usr/bin/env node
// check-analysis.js — turn an analysis document into an exit status.
//
// Usage: check-analysis.js <analysis.json>
// Exit:  0 the analysis concluded: either there is something to remediate, or
//          there is demonstrably nothing to do
//        1 the analysis could not conclude, or produced no usable document
//
// Separate from check-result.js on purpose. That one answers "did the session
// act freely"; this one answers "did the session conclude anything". A run can
// pass the first and fail this: the agent is never denied, narrates a thorough
// analysis, and writes nothing a later stage can read.
//
// Contract: specs/agents/vulnerability-analysis.spec.md — "Explicit Terminal
// State" and "Output Consumable by Later Stages"

"use strict";

const fs = require("fs");

// Finding nothing to do is a successful outcome. Being unable to tell whether
// there is anything to do is not, and the spec is explicit that the two must
// not collapse into one another.
const SUCCESS_STATES = new Set(["remediable", "no-action-needed"]);
const FAILURE_STATES = new Set(["cannot-remediate"]);

const path = process.argv[2];
if (!path) {
  console.error("check-analysis: usage: check-analysis.js <analysis.json>");
  process.exit(1);
}

const fail = (message) => {
  console.error(`run-agent: ${message}`);
  process.exit(1);
};

if (!fs.existsSync(path)) {
  // The contract is that the analysis concludes in writing. A session that ends
  // without this document has not met it, however well it explained itself.
  fail(`analysis produced no document at ${path}`);
}

let analysis;
try {
  analysis = JSON.parse(fs.readFileSync(path, "utf8"));
} catch (err) {
  fail(`cannot parse ${path}: ${err.message}`);
}

const state = analysis.terminal_state;
const field = (key, value) =>
  console.error(`run-agent:   ${key}: ${value ?? "—"}`);

console.error("run-agent: analysis summary");
field("state", state);
field("vulnerability", analysis.vulnerability && analysis.vulnerability.id);
field(
  "component",
  analysis.component &&
    [analysis.component.group, analysis.component.artifact]
      .filter(Boolean)
      .join(":")
);
field("presence", analysis.component && analysis.component.presence);
field("reachability", analysis.reachability && analysis.reachability.verdict);
field("remediating_version", analysis.remediating_version);

if (!SUCCESS_STATES.has(state) && !FAILURE_STATES.has(state)) {
  fail(
    `analysis reported no recognised terminal state (got ${JSON.stringify(
      state
    )}) — expected one of ${[...SUCCESS_STATES, ...FAILURE_STATES].join(", ")}`
  );
}

if (FAILURE_STATES.has(state)) {
  fail(`analysis cannot remediate — ${analysis.reason || "no reason recorded"}`);
}

// A document can satisfy the schema and still contradict itself. This pairing is
// the one a language model produces most readily: it concludes there is a fix to
// apply and leaves the version it would apply empty. Letting that through sends
// the next stage a patch instruction with nothing to patch to.
if (state === "remediable" && !analysis.remediating_version) {
  fail(
    "analysis reported 'remediable' without a remediating version — the two cannot both be true"
  );
}

process.exit(0);
