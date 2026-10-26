# Replay scenarios

One directory per run the orchestration has to get right. Each holds the
documents the phases would have produced, so a run can be replayed with no
session started — in seconds, and for nothing.

This is what makes the sequencing testable at all. The phases take minutes and
cost money, and the same input has produced 41 turns and 108; the ordering,
the preconditions, the retry bound and what is carried between phases are
determined by their inputs, and none of them need a model to exercise. They
are also where the defects are.

Used by:

- `scripts/test-pipeline.sh` — turns each directory into a ConfigMap, binds it
  as the Pipeline's `fixtures` workspace, and asserts the run's status **and**
  which tasks were skipped. Asserting the skips is the point: a run that
  passes for the wrong reason looks identical otherwise.
- `scripts/remediate.sh --replay <dir>` — the same scenarios through the local
  sequencer. Two implementations of one contract drift unless something holds
  them together, and this is it.

## The scenarios

| Directory | What it exercises |
|---|---|
| `delivered` | The happy path end to end: verified on the first attempt, pull request opened. |
| `no-action-needed` | The analysis finds nothing to do. Every later phase is skipped and the run **succeeds** — *nothing needed doing* is not a failure. |
| `red-baseline` | The suite does not pass on the unmodified checkout. The run stops before anything is modified. |
| `retry-then-verified` | The first attempt regresses a baseline test; the second, carrying that evidence, passes. Measured: this is two runs in five. |
| `retry-then-regression` | Both attempts regress. The bound holds at one retry and the run fails carrying the evidence. |
| `cannot-verify` | Verification establishes nothing. **Not** retried — a retry addresses a known cause, and this state means the cause is not known. |

## File names

The phase documents keep the names the runtime writes, so a scenario is
readable as a run:

| File | Served to |
|---|---|
| `analysis.json` | analyse |
| `baseline-tests.txt` | baseline — the test list it would have captured |
| `baseline.status` | baseline — its exit status, where the scenario models a red suite. Absent means green. |
| `exploit.json` | demonstrate |
| `patch.json` | patch |
| `verification.json` | verify, first attempt |
| `verification.retry.json` | verify, second attempt. Absent where the scenario never retries. |
| `delivery.json` | deliver |

A replay still runs the real gate for each document. A document can satisfy
its schema and claim something its own fields deny, and that rejection has to
happen in a replay too — otherwise the replay tests a sequencer that is more
forgiving than the real one.

## Where these came from

`delivered` is assembled from the documents of a real run against the
`feat/reachable-cve` fixture: the analysis, the demonstration, the patch with
its source change, the verification and the delivery, unedited.

The failure shapes — `regression`, `cannot-verify`, the red baseline — are
hand-written, because no capture of them was kept when they occurred. They are
the branches with the least cover and the ones worth replacing with real
captures the next time a run produces one. A hand-written document drifts from
what the agent actually emits.
