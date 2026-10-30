#!/usr/bin/env python3
"""trace-export.py — send a run's captured traces to a tracing backend.

Usage:
  trace-export.py --exporter <none|mlflow> --traces <dir> --run <name>
                  [--application <name>] [--record <id>]

Exit: 0 always. Tracing explains a run; it never decides one
(specs/observability/agent-tracing.spec.md — Capturing a Trace Never Decides
a Run). Every failure is reported and otherwise ignored.

Reads only what lib/capture-trace.js left: <NN>-<role>.jsonl plus
<NN>-<role>.meta.json. Two lookups, both tables, so neither a backend nor a
harness is special (ADR-0010):

  EXPORTERS  backend name -> function that exports one run
  READERS    (backend, transcript_format) -> function that turns one
             transcript into one trace on that backend

A trace whose format has no reader is named in the log, left in the
workspace and skipped. Adding OpenTelemetry is one entry in EXPORTERS and its
readers; adding a harness is one entry in READERS per backend.

MLflow mapping: experiment "lightwell/<run>", session "<run>-<role>" (plus
"-<candidate>" where a run has several), one trace per session attempt.
Connection settings are MLflow's own environment variables
(MLFLOW_TRACKING_URI, MLFLOW_TRACKING_AUTH, MLFLOW_TRACKING_SERVER_CERT_PATH,
MLFLOW_WORKSPACE).
"""

import argparse
import json
import os
import sys
import tempfile
from pathlib import Path


def log(message):
    print(f"trace-export: {message}", file=sys.stderr)


def load_traces(traces_dir):
    """The captured sessions in the order they ran."""
    traces = []
    for meta_file in sorted(Path(traces_dir).glob("*.meta.json")):
        try:
            meta = json.loads(meta_file.read_text())
        except (OSError, ValueError) as err:
            log(f"skipping {meta_file.name}: unreadable metadata ({err})")
            continue
        transcript = meta_file.parent / meta.get("transcript", "")
        if not transcript.is_file():
            log(f"skipping {meta_file.name}: transcript {transcript.name} is missing")
            continue
        traces.append((meta, transcript))
    return traces


# ── MLflow ───────────────────────────────────────────────────────────────


def session_name(run, meta):
    session = f"{run}-{meta['role']}"
    if meta.get("candidate"):
        session += f"-{meta['candidate']}"
    return session


def mlflow_read_claude_transcript(path, session_id):
    # The function MLflow's own Claude Code hook calls. Called here, after the
    # session, because the session runs under --bare and hooks never fire.
    from mlflow.claude_code.tracing import process_transcript

    return process_transcript(str(path), session_id)


MLFLOW_READERS = {
    "claude-code-transcript": mlflow_read_claude_transcript,
}


def export_mlflow(traces, run, application, record):
    try:
        import mlflow
        from mlflow import MlflowClient
    except ImportError as err:
        log(f"mlflow is not installed ({err}); nothing exported")
        return

    # MLflow's Claude Code integration logs to <cwd>/.claude/mlflow/. A Tekton
    # step starts in /, which an arbitrary UID cannot write, and every trace
    # then fails with "Permission denied: '/.claude'".
    os.chdir(tempfile.mkdtemp(prefix="trace-export-"))

    experiment = mlflow.set_experiment(f"lightwell/{run}")
    client = MlflowClient()
    for key, value in {
        "lightwell.pipelinerun": run,
        "lightwell.application": application,
        "lightwell.record": record,
    }.items():
        if value:
            client.set_experiment_tag(experiment.experiment_id, key, value)
    log(f"experiment lightwell/{run} ({experiment.experiment_id})")

    exported = 0
    for meta, transcript in traces:
        fmt = meta.get("transcript_format", "")
        reader = MLFLOW_READERS.get(fmt)
        if reader is None:
            log(f"skipping {transcript.name}: no MLflow reader for format '{fmt}'")
            continue

        session = session_name(run, meta)
        try:
            trace = reader(transcript, session)
        except Exception as err:  # noqa: BLE001 — one bad trace must not stop the rest
            log(f"skipping {transcript.name}: {err}")
            continue
        if trace is None:
            log(f"skipping {transcript.name}: the reader produced no trace")
            continue

        trace_id = getattr(trace.info, "trace_id", None) or trace.info.request_id
        tags = {
            "lightwell.pipelinerun": run,
            "lightwell.application": application,
            "lightwell.role": meta.get("role"),
            "lightwell.attempt": meta.get("attempt"),
            "lightwell.candidate": meta.get("candidate"),
            "lightwell.harness": meta.get("harness"),
            "lightwell.harness_version": meta.get("harness_version"),
            "lightwell.model": meta.get("model"),
            "lightwell.num_turns": meta.get("num_turns"),
            "lightwell.total_cost_usd": meta.get("total_cost_usd"),
            "lightwell.exit_status": meta.get("exit_status"),
            "lightwell.terminal_state": meta.get("terminal_state"),
        }
        for key, value in tags.items():
            if value not in (None, ""):
                try:
                    client.set_trace_tag(trace_id, key, str(value))
                except Exception as err:  # noqa: BLE001
                    log(f"{transcript.name}: tag {key} not set ({err})")
        exported += 1
        log(f"{transcript.name} -> session {session}, trace {trace_id}")

    log(f"exported {exported} of {len(traces)} trace(s)")


EXPORTERS = {
    "mlflow": export_mlflow,
}


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--exporter", required=True)
    parser.add_argument("--traces", required=True)
    parser.add_argument("--run", required=True)
    parser.add_argument("--application", default="")
    parser.add_argument("--record", default="")
    args = parser.parse_args()

    if args.exporter == "none":
        log("no exporter selected; traces stay in the workspace")
        return
    exporter = EXPORTERS.get(args.exporter)
    if exporter is None:
        log(f"unknown exporter '{args.exporter}' (known: none, {', '.join(EXPORTERS)})")
        return

    traces = load_traces(args.traces) if Path(args.traces).is_dir() else []
    if not traces:
        # A replay starts no session, so this is the expected answer there.
        log("nothing to trace")
        return
    exporter(traces, args.run, args.application, args.record)


if __name__ == "__main__":
    try:
        main()
    except Exception as err:  # noqa: BLE001 — tracing never decides a run
        log(f"export failed: {err}")
    sys.exit(0)
