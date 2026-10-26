#!/usr/bin/env node
// check-delivery.js — turn a delivery document into an exit status.
//
// Usage: check-delivery.js <delivery.json>
// Exit:  0 a pull request is open and carries the change
//        1 nothing was delivered, or the document does not show that it was
//
// Contract: specs/agents/pr-creation.spec.md — Explicit Terminal State

"use strict";

const fs = require("fs");

const SUCCESS_STATES = new Set(["delivered"]);
const FAILURE_STATES = new Set(["cannot-deliver"]);

const path = process.argv[2];
if (!path) {
  console.error("check-delivery: usage: check-delivery.js <delivery.json>");
  process.exit(1);
}

const fail = (message) => {
  console.error(`run-agent: ${message}`);
  process.exit(1);
};

if (!fs.existsSync(path)) {
  fail(`delivery produced no document at ${path}`);
}

let delivery;
try {
  delivery = JSON.parse(fs.readFileSync(path, "utf8"));
} catch (err) {
  fail(`cannot parse ${path}: ${err.message}`);
}

const state = delivery.terminal_state;
const field = (key, value) =>
  console.error(`run-agent:   ${key}: ${value ?? "—"}`);

console.error("run-agent: delivery summary");
field("state", state);
field("branch", delivery.branch);
field("pull request", delivery.pull_request);
field("commit", delivery.commit && String(delivery.commit).slice(0, 12));

if (!SUCCESS_STATES.has(state) && !FAILURE_STATES.has(state)) {
  fail(
    `delivery reported no recognised terminal state (got ${JSON.stringify(
      state
    )}) — expected one of ${[...SUCCESS_STATES, ...FAILURE_STATES].join(", ")}`
  );
}

if (FAILURE_STATES.has(state)) {
  fail(`nothing was delivered — ${delivery.reason || "no reason recorded"}`);
}

// A branch pushed without a request opened is work nobody has been asked to
// look at. The spec calls that cannot-deliver, so a document claiming
// delivery without a URL is contradicting itself.
if (!delivery.pull_request) {
  fail("delivery reported 'delivered' without a pull request URL");
}

if (!/^https?:\/\//.test(String(delivery.pull_request))) {
  fail(
    `delivery recorded something that is not a URL: ${JSON.stringify(
      delivery.pull_request
    )}`
  );
}

if (!delivery.branch || !delivery.commit) {
  fail(
    "delivery reported 'delivered' without naming the branch and commit — the trigger has nothing to point at"
  );
}

process.exit(0);
