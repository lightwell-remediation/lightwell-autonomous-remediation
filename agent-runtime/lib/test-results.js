#!/usr/bin/env node
// test-results.js — reduce a test run to a comparable list.
//
// Usage: test-results.js <surefire-reports-dir>
// Output, one per line, sorted: <class>#<method>\t<pass|fail|error|skipped>
// Exit:  0 results were found and printed
//        1 the directory holds no report
//
// Verification compares two runs, which only works if both sides are described
// the same way. Maven's console output is not that description: it is prose
// whose wording and ordering shift between invocations. The XML reports are
// structured, name each case, and say what happened to it.
//
// What comes out of here is also what detects a suite made green by deleting
// the failing test — the comparison is between two of these lists.
//
// Contract: specs/agents/fix-verification.spec.md — Every Baseline Test
// Survives, Unmodified

"use strict";

const fs = require("fs");
const path = require("path");

const dir = process.argv[2];
if (!dir) {
  console.error("test-results: usage: test-results.js <surefire-reports-dir>");
  process.exit(1);
}

if (!fs.existsSync(dir)) {
  console.error(`test-results: no reports at ${dir}`);
  process.exit(1);
}

const files = fs
  .readdirSync(dir)
  .filter((f) => f.startsWith("TEST-") && f.endsWith(".xml"));

const attr = (tag, name) => {
  const m = tag.match(new RegExp(`${name}="([^"]*)"`));
  return m ? m[1] : "";
};

const results = [];

for (const file of files) {
  const xml = fs.readFileSync(path.join(dir, file), "utf8");

  // Each <testcase> either self-closes, which means it passed, or wraps a
  // child naming what went wrong. Matching the open tag and then looking at
  // what follows keeps both shapes in one pass.
  for (const m of xml.matchAll(/<testcase\b([^>]*?)(\/>|>([\s\S]*?)<\/testcase>)/g)) {
    const [, attrs, close, body = ""] = m;
    const name = attr(attrs, "name");
    const cls = attr(attrs, "classname");
    if (!name) continue;

    let outcome = "pass";
    if (close !== "/>") {
      if (/<failure\b/.test(body)) outcome = "fail";
      else if (/<error\b/.test(body)) outcome = "error";
      else if (/<skipped\b/.test(body)) outcome = "skipped";
    }

    results.push(`${cls}#${name}\t${outcome}`);
  }
}

if (results.length === 0) {
  console.error(`test-results: ${dir} holds no test cases`);
  process.exit(1);
}

// Sorted so that two runs of the same suite produce byte-identical files when
// nothing changed, and a diff shows only what actually differs.
process.stdout.write(results.sort().join("\n") + "\n");
