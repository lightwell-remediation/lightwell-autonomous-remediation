#!/usr/bin/env node
// check-patch.js — turn a patch document into an exit status.
//
// Usage: check-patch.js <patch.json>
// Exit:  0 the remediation was applied and the project compiles
//        1 it was not applied, or the document does not establish that it was
//
// Contract: specs/agents/code-patching.spec.md — Explicit Terminal State

"use strict";

const fs = require("fs");

const SUCCESS_STATES = new Set(["patched"]);
const FAILURE_STATES = new Set(["cannot-patch"]);

const path = process.argv[2];
if (!path) {
  console.error("check-patch: usage: check-patch.js <patch.json>");
  process.exit(1);
}

const fail = (message) => {
  console.error(`run-agent: ${message}`);
  process.exit(1);
};

if (!fs.existsSync(path)) {
  fail(`patching produced no document at ${path}`);
}

let patch;
try {
  patch = JSON.parse(fs.readFileSync(path, "utf8"));
} catch (err) {
  fail(`cannot parse ${path}: ${err.message}`);
}

const state = patch.terminal_state;
const moved = patch.artifacts_moved || [];
const changed = patch.files_changed || [];
const field = (key, value) =>
  console.error(`run-agent:   ${key}: ${value ?? "—"}`);

console.error("run-agent: patch summary");
field("state", state);
field("strategy", patch.strategy);
field("files changed", changed.length ? changed.join(", ") : "none");
field(
  "artifacts moved",
  moved.length
    ? moved.map((a) => `${a.coordinates} ${a.from} → ${a.to}`).join("; ")
    : "none"
);
field("source changes", (patch.source_changes || []).length);
field("tests added", (patch.tests_added || []).length);

if (!SUCCESS_STATES.has(state) && !FAILURE_STATES.has(state)) {
  fail(
    `patching reported no recognised terminal state (got ${JSON.stringify(
      state
    )}) — expected one of ${[...SUCCESS_STATES, ...FAILURE_STATES].join(", ")}`
  );
}

if (FAILURE_STATES.has(state)) {
  fail(`patching cannot proceed — ${patch.reason || "no reason recorded"}`);
}

// A document can satisfy the schema and still contradict itself. These are the
// pairings a session reaches for when it has concluded before it has acted.

if (changed.length === 0) {
  fail("patching reported 'patched' without changing any file");
}

if (patch.compiles === false) {
  fail(
    "patching reported 'patched' with compiles=false — an uncompilable tree is not a finished patch"
  );
}

if (moved.length === 0) {
  fail(
    "patching reported 'patched' without moving any artifact — a remediation that changes no version remediates nothing"
  );
}

// The remediating version is the point of the exercise. A move that lands
// somewhere else means the applied version came from somewhere other than the
// analysis — most likely the record's prose, which recommends upstream
// releases rather than the backport.
const unmoved = moved.filter((a) => !a.to || a.to === a.from);
if (unmoved.length) {
  fail(
    `patching reported artifacts moved to the version they were already at: ${unmoved
      .map((a) => a.coordinates)
      .join(", ")}`
  );
}

process.exit(0);
