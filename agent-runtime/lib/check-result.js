#!/usr/bin/env node
// check-result.js — decide whether a harness session actually succeeded.
//
// Usage: check-result.js <result.json> [--gated]
// Exit:  0 session completed and acted freely
//        1 session failed, hit its turn budget, or was blocked by a denial
//
// The harness exits 0 for a session that reached a terminal state, including
// one where every meaningful action was denied and the agent merely narrated
// that it could not proceed. A pipeline trusting the exit code alone would
// report that run as green, so denials are inspected here.
//
// Whether a denial fails the run depends on what comes next:
//
//   --gated   a role output gate runs after this one and will judge the
//             document the session was contracted to produce. The denial is
//             reported and nothing more — if it stopped the work, the gate
//             will say so, and if it did not, the work is done.
//   (absent)  nothing else will look. A denial is then the only evidence
//             that the session may have narrated rather than acted, so it
//             fails the run.
//
// The policy, not this file, is the guardrail: a denied action did not
// happen. Failing the run on top of that is a second and much blunter rule,
// and it cost real runs — a model asking for `find … ; ls …`, or piping an
// already-allowed `mvn` through `tail`, lost everything it had done over one
// exploratory command it immediately worked around.
//
// TOLERATE_DENIALS=1 suppresses the failure even when ungated.
//
// Contract: specs/platform/agent-runtime.spec.md — "Honest Exit Status"

"use strict";

const fs = require("fs");

const args = process.argv.slice(2);
const gated = args.includes("--gated");
const path = args.find((a) => !a.startsWith("--"));
if (!path) {
  console.error("check-result: usage: check-result.js <result.json>");
  process.exit(1);
}

let result;
try {
  result = JSON.parse(fs.readFileSync(path, "utf8"));
} catch (err) {
  console.error(`check-result: cannot parse ${path}: ${err.message}`);
  process.exit(1);
}

const denials = result.permission_denials || [];
const tolerate = process.env.TOLERATE_DENIALS === "1";
const field = (key, value) => console.error(`run-agent:   ${key}: ${value}`);

console.error("run-agent: session summary");
field("subtype", result.subtype);
field("turns", result.num_turns);
field("cost_usd", result.total_cost_usd);
field("stopped", result.terminal_reason);

if (result.is_error) {
  // subtype stays "success" for a session that reached a terminal state and
  // then failed, so it names nothing useful on its own. terminal_reason is what
  // distinguishes an api_error from a turn budget, and result carries the
  // message the caller actually needs to act on.
  const reason =
    result.subtype === "error_max_turns"
      ? `turn budget exhausted after ${result.num_turns} turns`
      : result.terminal_reason || result.subtype;
  console.error(`run-agent: session failed — ${reason}`);
  if (result.result) {
    console.error(`run-agent:   ${result.result}`);
  }
  process.exit(1);
}

if (denials.length) {
  // Always listed. A denial is worth seeing even when it changes nothing:
  // a role repeatedly reaching for something it cannot have is a prompt or
  // a policy that needs attention, and it is invisible otherwise.
  const fatal = !gated && !tolerate;
  console.error(
    `run-agent: ${denials.length} action(s) denied by policy` +
      (fatal ? " — treating as failure" : " — the output gate decides this run")
  );
  for (const denial of denials) {
    const input = denial.tool_input || {};
    const detail = input.command || JSON.stringify(input);
    console.error(`run-agent:   denied ${denial.tool_name}: ${detail}`);
  }
  if (fatal) {
    console.error(
      "run-agent: allow it in agent-runtime/claude/settings.json, or set TOLERATE_DENIALS=1"
    );
    process.exit(1);
  }
}

process.exit(0);
