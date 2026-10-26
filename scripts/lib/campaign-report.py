#!/usr/bin/env python3
"""campaign-report.py — turn the campaign's runs into a table worth reading.

The headline is deliberately not the pass rate. A run that went green by
bumping a version on an application that is still vulnerable is not a pass,
it is the failure the exploit test exists to catch — so "usable" here means
delivered **and** the source was changed.

Usage: campaign-report.py <results.jsonl>
"""

import collections
import json
import sys


def main():
    rows = []
    with open(sys.argv[1], encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                rows.append(json.loads(line))

    if not rows:
        print("no runs recorded")
        return 0

    by_model = collections.defaultdict(list)
    for r in rows:
        by_model[r["model"]].append(r)

    print(f"{'model':22s} {'usable':>8s} {'delivered':>10s} {'median':>8s} "
          f"{'attempts':>9s} {'cost/run':>9s}")
    print("-" * 72)

    for model, runs in by_model.items():
        usable = sum(1 for r in runs if r["delivered"] and r["source_change"])
        delivered = sum(1 for r in runs if r["delivered"])
        times = sorted(r["seconds"] for r in runs)
        median = times[len(times) // 2] if times else 0
        attempts = [r["attempts"] for r in runs if r["attempts"]]
        mean_attempts = sum(attempts) / len(attempts) if attempts else 0
        costs = [r["cost_usd"] for r in runs if r["cost_usd"]]
        mean_cost = sum(costs) / len(costs) if costs else 0
        print(f"{model:22s} {usable:4d}/{len(runs):<3d} {delivered:6d}/{len(runs):<3d} "
              f"{median//60:5d}m{median%60:02d}s {mean_attempts:9.1f} {mean_cost:8.2f}$")

    print("\nper run")
    for model, runs in by_model.items():
        for r in runs:
            mark = "ok" if r["delivered"] and r["source_change"] else "--"
            detail = ""
            if not r["delivered"]:
                broke = [p for p, s in r["phases"].items()
                         if s not in ("Succeeded", "Skipped", "None")]
                detail = f"  stopped at: {', '.join(broke) or 'unknown'}"
            elif not r["source_change"]:
                detail = "  delivered a version bump with no source change"
            print(f"  {mark} {model:22s} run {r['run']}  {r['status']:9s} "
                  f"{r['seconds']//60}m{r['seconds']%60:02d}s  "
                  f"{r['attempts']} attempt(s){detail}")

    print("\n'usable' means delivered AND the source was changed. A green run that")
    print("only moved the version leaves the application vulnerable.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
