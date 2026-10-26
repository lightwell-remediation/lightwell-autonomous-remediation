#!/usr/bin/env node
// tpa-verdict.js — say what Trusted Profile Analyzer thinks of the vulnerability
// a run started from, in the remediated inventory and in the one it replaced.
//
// The comparison lives here rather than in the shell so it can be pinned down
// with recorded responses and no instance (test/tpa-verdict.test.sh).
//
// Usage: tpa-verdict.js <vulnerability-id> <tpa-url>
//                       <remediated-sbom-id> <remediated-advisories.json>
//                       [<baseline-sbom-id> <baseline-advisories.json>]
// Prints the verdict document on stdout.
// Exit:  0 the verdict was written, whatever it says
//        1 the arguments or a response could not be read
//
// The response is GET /api/v3/sbom/{id}/advisory: advisories, each with the
// vulnerabilities it reports for this SBOM and a status for each (Trustify
// 3.1.0 schemas SbomAdvisory and SbomStatus).
//
// Contract: specs/devsecops/pipeline.spec.md — Validated Before Merge

"use strict";

const fs = require("fs");

const [, , vulnerability, tpaUrl, remediatedId, remediatedFile, baselineId, baselineFile] = process.argv;
if (!vulnerability || !tpaUrl || !remediatedId || !remediatedFile) {
  console.error("tpa-verdict: usage: tpa-verdict.js <vuln-id> <tpa-url> <sbom-id> <advisories.json> [<baseline-id> <baseline.json>]");
  process.exit(1);
}

// The run knows the vulnerability by Lightwell's record id —
// x_<VENDOR>-CVE-2026-68079-4.2.2 — which is the advisory's identifier in TPA.
// The vulnerability inside it is the CVE. Either names the same defect.
const names = new Set([vulnerability.toLowerCase()]);
for (const cve of vulnerability.match(/CVE-\d{4}-\d{4,}/gi) || []) names.add(cve.toLowerCase());
const named = (s) => typeof s === "string" && names.has(s.toLowerCase());

const read = (file) => {
  try {
    const d = JSON.parse(fs.readFileSync(file, "utf8"));
    if (!Array.isArray(d)) throw new Error("not an array of advisories");
    return d;
  } catch (err) {
    console.error(`tpa-verdict: cannot read ${file}: ${err.message}`);
    process.exit(1);
  }
};

const describe = (id, advisories) => {
  const states = new Set();
  const affected = new Set();
  for (const advisory of advisories) {
    const byAdvisory = named(advisory.identifier) || named(advisory.document_id);
    for (const status of advisory.status || []) {
      if (status.status === "affected") affected.add(status.identifier);
      if (byAdvisory || named(status.identifier)) states.add(status.status);
    }
  }
  // Affected anywhere wins: one advisory saying fixed does not cancel another
  // still saying affected.
  const state = states.has("affected") ? "affected"
    : states.size ? [...states].sort()[0]
    : "absent";
  return {
    sbom_id: id,
    url: `${tpaUrl.replace(/\/$/, "")}/sboms/${encodeURI(id)}?sd%3AactiveTab=vulnerabilities`,
    state,
    affected_total: affected.size,
  };
};

const remediated = describe(remediatedId, read(remediatedFile));
const baseline = baselineId && baselineFile ? describe(baselineId, read(baselineFile)) : null;

process.stdout.write(JSON.stringify({
  validated: true,
  vulnerability,
  remediated,
  baseline,
  resolved: remediated.state !== "affected",
}, null, 2) + "\n");
