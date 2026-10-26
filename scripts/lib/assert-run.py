#!/usr/bin/env python3
"""assert-run.py — decide whether a replayed PipelineRun behaved as specified.

Three things are checked, and the second is the one that matters:

1. The run's final status. Necessary, and on its own almost worthless.
2. Which tasks were **skipped**. A run that succeeds having skipped the half
   of the sequence that does the work looks identical, from the status alone,
   to one that remediated something.
3. How many attempts patching and verification took. The retry is bounded at
   one, and both bounds are failures: never retrying when a regression was
   reported, and retrying something the spec says must not be retried.

Usage:
  assert-run.py <pipelinerun.json> <taskruns.json> <scenario>
                <expected-status> <expected-skips> <expected-attempts>
"""

import json
import sys


def load(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def succeeded_condition(run):
    for condition in run.get("status", {}).get("conditions", []):
        if condition.get("type") == "Succeeded":
            return condition
    return {}


def main():
    if len(sys.argv) != 7:
        print(__doc__, file=sys.stderr)
        return 2

    run_path, taskruns_path, scenario = sys.argv[1], sys.argv[2], sys.argv[3]
    expected_status = sys.argv[4]
    expected_skips = {s for s in sys.argv[5].split(",") if s}
    expected_attempts = int(sys.argv[6])

    run = load(run_path)
    if run is None:
        print(f"  FAIL  {scenario}: no PipelineRun to read", file=sys.stderr)
        return 1

    problems = []

    # ── 1. Status ────────────────────────────────────────────────────────
    condition = succeeded_condition(run)
    status = condition.get("status", "")
    actual_status = {"True": "Succeeded", "False": "Failed"}.get(status, "Unknown")
    if actual_status != expected_status:
        problems.append(
            f"status {actual_status}, expected {expected_status}"
            f" — {condition.get('reason', '?')}: {condition.get('message', '')}"
        )

    # ── 2. Skipped tasks ─────────────────────────────────────────────────
    actual_skips = {
        task["name"] for task in run.get("status", {}).get("skippedTasks", [])
    }
    missing = expected_skips - actual_skips
    unexpected = actual_skips - expected_skips
    if missing:
        problems.append(
            f"these should have been skipped and ran: {', '.join(sorted(missing))}"
        )
    if unexpected:
        problems.append(
            f"these were skipped and should have run: {', '.join(sorted(unexpected))}"
        )

    # ── 3. Attempts at patching and verification ─────────────────────────
    taskruns = load(taskruns_path) or {"items": []}
    attempts = 0
    for item in taskruns.get("items", []):
        labels = item.get("metadata", {}).get("labels", {})
        if labels.get("tekton.dev/pipelineTask") != "patch-and-verify":
            continue
        # One entry in retriesStatus means the first attempt failed and a
        # second ran. No entries and the task ran once.
        attempts = 1 + len(item.get("status", {}).get("retriesStatus", []))
    if attempts != expected_attempts:
        problems.append(
            f"patch-and-verify ran {attempts} attempt(s), expected {expected_attempts}"
        )

    if problems:
        print(f"  FAIL  {scenario}", file=sys.stderr)
        for problem in problems:
            print(f"          {problem}", file=sys.stderr)
        return 1

    detail = f"{actual_status}, {attempts} attempt(s)"
    if actual_skips:
        detail += f", skipped {', '.join(sorted(actual_skips))}"
    print(f"  ok    {scenario} — {detail}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
