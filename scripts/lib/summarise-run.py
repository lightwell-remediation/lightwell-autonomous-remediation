#!/usr/bin/env python3
"""summarise-run.py — reduce one PipelineRun to a line of JSON.

Written for the model campaign, where the interesting comparison is not
"did it go green" but how it got there: how many patching attempts, whether
it touched application source, what it cost.

Usage:
  summarise-run.py <pipelinerun.json> <taskruns.json>
                   <model> <attempt> <pr-url> <source-changes> <cost>
"""

import json
import sys
from datetime import datetime


def load(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def seconds_between(start, end):
    if not start or not end:
        return 0
    fmt = "%Y-%m-%dT%H:%M:%SZ"
    try:
        return int((datetime.strptime(end, fmt) - datetime.strptime(start, fmt)).total_seconds())
    except ValueError:
        return 0


def main():
    run_path, taskruns_path = sys.argv[1], sys.argv[2]
    model, attempt, pr, source_changes, cost = sys.argv[3:8]

    run = load(run_path) or {}
    taskruns = load(taskruns_path) or {"items": []}
    status = run.get("status", {})

    condition = next(
        (c for c in status.get("conditions", []) if c.get("type") == "Succeeded"), {}
    )
    state = {"True": "Succeeded", "False": "Failed"}.get(condition.get("status", ""), "Unknown")

    # Per pipeline task: what happened. A skipped task is "None", which is
    # not a failure — it is the precondition having said no.
    phases = {t["name"]: "Skipped" for t in status.get("skippedTasks", [])}
    patch_attempts = 0
    for item in taskruns.get("items", []):
        labels = item.get("metadata", {}).get("labels", {})
        name = labels.get("tekton.dev/pipelineTask", "?")
        reason = next(
            (c.get("reason") for c in item.get("status", {}).get("conditions", [])
             if c.get("type") == "Succeeded"), "Unknown"
        )
        phases[name] = reason
        if name == "patch-and-verify":
            patch_attempts = 1 + len(item.get("status", {}).get("retriesStatus", []))

    delivered = phases.get("deliver") == "Succeeded"

    json.dump({
        "model": model,
        "run": int(attempt),
        "name": run.get("metadata", {}).get("name", ""),
        "status": state,
        "delivered": delivered,
        "seconds": seconds_between(status.get("startTime"), status.get("completionTime")),
        "attempts": patch_attempts,
        # The signal that separates a real remediation from a version bump
        # on an application that is still vulnerable.
        "source_change": int(source_changes or 0) > 0,
        "cost_usd": float(cost or 0),
        "pull_request": pr,
        "phases": phases,
    }, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
