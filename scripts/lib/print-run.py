#!/usr/bin/env python3
"""print-run.py — one line of progress for the most recent campaign run.

A file rather than an inline heredoc: the shell's `${...}` swallows the
f-string braces, and feeding python a heredoc leaves no stdin for the data.

Usage: print-run.py <results.jsonl>
"""

import json
import sys


def main():
    last = None
    with open(sys.argv[1], encoding="utf-8") as handle:
        for line in handle:
            if line.strip():
                last = line
    if last is None:
        print("  (no run recorded)")
        return 0

    d = json.loads(last)
    # Delivered is not enough: a run that only moved the version leaves the
    # application vulnerable, so it does not count as a pass here.
    mark = "ok  " if d["delivered"] and d["source_change"] else "FAIL"
    print(f"  {mark} {d['status']:9s} {d['seconds']:5d}s  {d['attempts']} attempt(s)  "
          f"source_change={d['source_change']}  ${d['cost_usd']}")
    for phase, state in d["phases"].items():
        if state not in ("Succeeded", "None"):
            print(f"        {phase}: {state}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
