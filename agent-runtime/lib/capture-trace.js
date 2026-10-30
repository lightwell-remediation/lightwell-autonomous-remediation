#!/usr/bin/env node
// capture-trace.js — keep what a session did, for whoever reads the run later.
//
// Usage: capture-trace.js <session-stream.jsonl> <traces-dir> <role> <exit> [<document>]
// Env:   CLAUDE_CONFIG_DIR (or HOME) — where the harness keeps its transcripts
//        MAAS_MODEL, TRACE_CANDIDATE — recorded as they are
// Exit:  0 always. Capture is best effort; it never decides a run.
//
// Every role writes the same out/session.jsonl, so before this only the last
// session of a run survived. Each session now leaves <NN>-<role>.jsonl, the
// harness's own transcript, and <NN>-<role>.meta.json, which says what the
// transcript is and how the session ended. NN only grows, so a retry never
// overwrites the attempt it retries.
//
// Exporters read these files and nothing else (ADR-0010). The metadata names
// the harness and the transcript format because a transcript belongs to its
// harness: an exporter that has no reader for a format skips it instead of
// guessing.
//
// Contract: specs/observability/agent-tracing.spec.md — Every Session Leaves a Trace

"use strict";

const fs = require("fs");
const path = require("path");

const [streamFile, tracesDir, role, exitArg, documentFile] = process.argv.slice(2);

function warn(message) {
  console.error(`run-agent: trace not captured — ${message}`);
}

function readJsonl(file) {
  try {
    return fs
      .readFileSync(file, "utf8")
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
  } catch {
    return [];
  }
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

// The harness files transcripts under projects/<escaped cwd>/<session>.jsonl.
// The escaping is the harness's business, so the session id is looked up in
// every project directory rather than the path being rebuilt here.
function findTranscript(sessionId) {
  const configDir =
    process.env.CLAUDE_CONFIG_DIR ||
    path.join(process.env.HOME || "", ".claude");
  const projects = path.join(configDir, "projects");
  let dirs;
  try {
    dirs = fs.readdirSync(projects);
  } catch {
    return null;
  }
  for (const dir of dirs) {
    const candidate = path.join(projects, dir, `${sessionId}.jsonl`);
    if (fs.existsSync(candidate)) return candidate;
  }
  return null;
}

try {
  if (!streamFile || !tracesDir || !role) {
    warn("usage: capture-trace.js <stream> <traces-dir> <role> <exit> [<document>]");
    process.exit(0);
  }

  const events = readJsonl(streamFile);
  const sessionId = (events.find((e) => e.session_id) || {}).session_id;
  if (!sessionId) {
    warn("the session stream names no session");
    process.exit(0);
  }
  const result = [...events].reverse().find((e) => e.type === "result") || {};

  fs.mkdirSync(tracesDir, { recursive: true });
  const existing = fs.readdirSync(tracesDir).filter((f) => f.endsWith(".meta.json"));
  const seq = String(existing.length + 1).padStart(2, "0");
  const attempt = existing.filter((f) => f.endsWith(`-${role}.meta.json`)).length + 1;
  const base = `${seq}-${role}`;

  // The native transcript is what MLflow's Claude Code integration reads. If
  // it is missing, the stream is kept instead under its own format name, so
  // nothing is lost and no exporter mistakes it for a transcript.
  const transcript = findTranscript(sessionId);
  let format = "claude-code-transcript";
  let source = transcript;
  if (!transcript) {
    warn(`no transcript for session ${sessionId}; keeping the stream instead`);
    format = "claude-code-stream-json";
    source = streamFile;
  }
  fs.copyFileSync(source, path.join(tracesDir, `${base}.jsonl`));

  const version =
    (readJsonl(source).find((e) => e.version) || {}).version || null;
  const document = documentFile ? readJson(documentFile) : null;

  const meta = {
    harness: "claude-code",
    harness_version: version,
    transcript: `${base}.jsonl`,
    transcript_format: format,
    session_id: sessionId,
    role,
    attempt,
    candidate: process.env.TRACE_CANDIDATE || "",
    model: process.env.MAAS_MODEL || "",
    num_turns: result.num_turns ?? null,
    total_cost_usd: result.total_cost_usd ?? null,
    subtype: result.subtype ?? null,
    exit_status: Number.isNaN(Number(exitArg)) ? null : Number(exitArg),
    terminal_state: (document && document.terminal_state) || null,
  };
  fs.writeFileSync(
    path.join(tracesDir, `${base}.meta.json`),
    JSON.stringify(meta, null, 2) + "\n"
  );
  console.error(`run-agent: trace kept as ${path.join(tracesDir, base)}.jsonl`);
} catch (err) {
  warn(err.message);
}
process.exit(0);
