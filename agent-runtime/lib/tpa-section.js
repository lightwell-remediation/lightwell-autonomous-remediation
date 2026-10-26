#!/usr/bin/env node
// tpa-section.js — render what TPA said about the inventory as a section of
// the pull request body.
//
// Appended by the runtime, not written by the model. It reports what a
// service answered; there is nothing in it to phrase, and a model restating
// it is one more place for "fixed" to be written where TPA said otherwise
// (docs/adr/0005-determinism-boundary.md).
//
// Usage: tpa-section.js <tpa.json>
// Prints markdown, or nothing where there is no document — a run with no
// TPA configured says nothing about TPA, as a project with no inventory says
// nothing about inventories.
//
// Contract: specs/devsecops/pipeline.spec.md — Validated Before Merge

"use strict";

const fs = require("fs");

const path = process.argv[2];
let d;
try {
  d = JSON.parse(fs.readFileSync(path, "utf8"));
} catch {
  process.exit(0);
}

const out = ["", "## Inventory validated in Trusted Profile Analyzer", ""];

if (!d.validated) {
  out.push(`- Not validated: ${d.reason || "no reason recorded"}.`);
  out.push("- The regenerated inventory is on this branch; nothing has checked it against the vulnerability service.");
} else {
  const label = {
    affected: "**affected**",
    absent: "not reported",
    fixed: "fixed",
    not_affected: "not affected",
  };
  const row = (name, s) =>
    `| ${name} | [${s.sbom_id}](${s.url}) | ${label[s.state] || s.state} | ${s.affected_total} |`;

  out.push(`\`${d.vulnerability}\` in each inventory, as TPA reports it:`, "");
  out.push("| Inventory | SBOM | This vulnerability | Affected by anything |");
  out.push("|---|---|---|---|");
  if (d.baseline) out.push(row("Before (baseline)", d.baseline));
  out.push(row("This branch", d.remediated));
  out.push("");
  if (!d.resolved) {
    out.push("> [!WARNING]");
    out.push("> TPA still reports this branch's inventory as affected by the vulnerability this pull request remediates.");
  } else if (!d.baseline) {
    out.push("No baseline inventory is registered in TPA for this application, so there is nothing to compare against.");
  }
}

process.stdout.write(out.join("\n") + "\n");
