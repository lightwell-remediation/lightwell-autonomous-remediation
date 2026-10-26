#!/usr/bin/env node
// governed-artifacts.js — list every artifact a version declaration governs.
//
// Usage: governed-artifacts.js <pom.xml> <groupId> <artifactId>
// Output, one per line: <groupId>:<artifactId>\t<version-expression>
// Exit:  0 the affected dependency was found and its siblings listed
//        1 the affected dependency is not declared in this manifest
//
// Editing a version is rarely editing one dependency. A property is shared:
// in the demo application a single cxf.version governs both the affected
// component and another artifact from the same project, so the one-line patch
// moves both. Whether that is safe depends on all of them being published at
// the remediating version — which the caller checks, one resolution per line
// printed here.
//
// Derived from the manifest rather than from the analysis document's
// version_controlled_by, which is prose a model wrote and which varied across
// runs of the same input ("property cxf.version (pom.xml line 22)" one time,
// "property <cxf.version>4.2.2</cxf.version> in pom.xml" the next). The group
// and artifact it reports are structured, and those are what is used here.
//
// Contract: specs/agents/code-patching.spec.md — Establish What the Change Moves

"use strict";

const fs = require("fs");

const [pomPath, group, artifact] = process.argv.slice(2);
if (!pomPath || !group || !artifact) {
  console.error(
    "governed-artifacts: usage: governed-artifacts.js <pom.xml> <groupId> <artifactId>"
  );
  process.exit(1);
}

const pom = fs.readFileSync(pomPath, "utf8");

// Comments are stripped first: a commented-out dependency is not part of the
// build, and treating one as governed would send the caller resolving an
// artifact the project never asks for.
const body = pom.replace(/<!--[\s\S]*?-->/g, "");

const text = (block, tag) => {
  const m = block.match(new RegExp(`<${tag}>\\s*([^<]*?)\\s*</${tag}>`));
  return m ? m[1] : null;
};

const dependencies = [...body.matchAll(/<dependency>([\s\S]*?)<\/dependency>/g)]
  .map(([, block]) => ({
    group: text(block, "groupId"),
    artifact: text(block, "artifactId"),
    version: text(block, "version"),
  }))
  .filter((d) => d.group && d.artifact);

const affected = dependencies.find(
  (d) => d.group === group && d.artifact === artifact
);

if (!affected) {
  console.error(
    `governed-artifacts: ${group}:${artifact} is not declared in ${pomPath}`
  );
  process.exit(1);
}

// A literal version governs only itself. A property reference governs every
// dependency that spells it the same way.
const property = affected.version && affected.version.match(/^\$\{(.+)\}$/);

const governed = property
  ? dependencies.filter((d) => d.version === affected.version)
  : [affected];

for (const d of governed) {
  process.stdout.write(`${d.group}:${d.artifact}\t${d.version || "managed"}\n`);
}
