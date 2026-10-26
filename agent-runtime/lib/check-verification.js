#!/usr/bin/env node
// check-verification.js — turn a verification document into an exit status.
//
// Usage: check-verification.js <verification.json>
// Exit:  0 the remediation holds: right version resolved, nothing regressed
//        1 something regressed, or the evidence was not established
//
// `regression` exits non-zero here even though the sequencer may retry. This
// decides whether one attempt stands on its own; whether another is worth
// making is the sequencer's call, and it reads the document for that.
//
// Contract: specs/agents/fix-verification.spec.md — Explicit Terminal State

"use strict";

const fs = require("fs");

const SUCCESS_STATES = new Set(["verified"]);
const FAILURE_STATES = new Set(["regression", "cannot-verify"]);

const path = process.argv[2];
if (!path) {
  console.error("check-verification: usage: check-verification.js <verification.json>");
  process.exit(1);
}

const fail = (message) => {
  console.error(`run-agent: ${message}`);
  process.exit(1);
};

if (!fs.existsSync(path)) {
  fail(`verification produced no document at ${path}`);
}

let v;
try {
  v = JSON.parse(fs.readFileSync(path, "utf8"));
} catch (err) {
  fail(`cannot parse ${path}: ${err.message}`);
}

const state = v.terminal_state;
const regressions = v.regressions || [];
const missing = v.missing_or_altered || [];
const field = (key, value) =>
  console.error(`run-agent:   ${key}: ${value ?? "—"}`);

console.error("run-agent: verification summary");
field("state", state);
field("resolved version", v.resolved_version);
field("affected version absent", v.affected_version_absent);
field("baseline tests", v.baseline_tests);
field("regressions", regressions.length);
field("missing or altered", missing.length ? missing.join(", ") : "none");
field("tests added", (v.tests_added || []).length);
field(
  "exploit test",
  v.exploit_test && v.exploit_test.available ? "ran" : "none available"
);
if (v.not_established) field("not established", v.not_established);

if (!SUCCESS_STATES.has(state) && !FAILURE_STATES.has(state)) {
  fail(
    `verification reported no recognised terminal state (got ${JSON.stringify(
      state
    )}) — expected one of ${[...SUCCESS_STATES, ...FAILURE_STATES].join(", ")}`
  );
}

if (FAILURE_STATES.has(state)) {
  fail(
    `verification did not pass (${state}) — ${v.reason || "no reason recorded"}`
  );
}

// From here the document claims `verified`, and these are the ways that claim
// can contradict its own evidence.

if (v.affected_version_absent !== true) {
  fail(
    `verification reported 'verified' while the affected version is still resolved${
      v.reintroduced_by ? ` via ${v.reintroduced_by}` : ""
    }`
  );
}

if (!v.resolved_version) {
  fail("verification reported 'verified' without recording what resolves");
}

if (missing.length) {
  fail(
    `verification reported 'verified' with baseline tests missing or altered: ${missing.join(
      ", "
    )} — the comparison does not hold`
  );
}

const real = regressions.filter((r) => r.attribution === "regression");
if (real.length) {
  fail(
    `verification reported 'verified' while listing regressions: ${real
      .map((r) => r.test)
      .join(", ")}`
  );
}

const unattributed = regressions.filter(
  (r) => r.attribution === "unattributable"
);
if (unattributed.length) {
  fail(
    `verification reported 'verified' with differences it could not attribute: ${unattributed
      .map((r) => r.test)
      .join(", ")} — that is cannot-verify`
  );
}

// A demonstration that still fails is the case this whole capability exists
// to catch: the dependency moved, the existing tests are green, and the
// defect is still there.
const exploit = v.exploit_test || {};
if (exploit.available && exploit.passed_after === false) {
  fail(
    "verification reported 'verified' while the exploit test still fails — the remediation did not achieve what it was for"
  );
}

if (exploit.available && exploit.failed_before === false) {
  fail(
    "verification reported 'verified' citing an exploit test that did not fail beforehand — it demonstrates nothing about the defect"
  );
}

// A baseline of zero tests is not a green baseline, it is no evidence at all.
if (!v.baseline_tests) {
  fail("verification reported 'verified' against a baseline of no tests");
}

process.exit(0);
