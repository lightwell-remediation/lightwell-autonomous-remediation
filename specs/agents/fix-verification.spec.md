# Fix Verification Specification

## Purpose

What has to be true before a remediation is offered to a reviewer: that the
build now resolves the remediating version and no longer the affected one, that
the application still behaves as it did, and — once an exploit test exists —
that the defect is actually gone. Its output is the evidence the pull request
rests on.

This spec describes a **capability**, not a process boundary. Whether it runs as
a Tekton task, a dedicated agent, or a phase of a single session is decided by
`orchestration-strategy.spec.md`.

## Requirements

### Requirement: The Remediating Version Is What Resolves

Verification SHALL confirm, against the dependency tree resolved **after** the
change, that the affected component appears at the remediating version, and
that the affected version no longer appears by any path.

Both halves are necessary and the second is the one that catches real
mistakes. A component removed from one declaration can re-enter the build
through another dependency, at the version the report was about. The manifest
then reads as patched, the build is green, and the application still ships the
vulnerable artifact.

This is a lookup over a resolved tree, so per
[ADR-0005](../../docs/adr/0005-determinism-boundary.md) it is computed rather
than asked of a model. Verification SHALL NOT take the applied version from the
patch output: that records what was attempted, and this requirement exists to
establish what actually happened.

#### Scenario: Remediating Version Resolves

- GIVEN a patched working tree
- WHEN its dependency tree is resolved
- THEN the affected component appears at the remediating version
- AND no entry resolves to the affected version

#### Scenario: Affected Version Re-enters Transitively

- GIVEN a patched manifest that no longer names the affected version
- WHEN the resolved tree still contains that version under another dependency
- THEN verification fails, naming the path that reintroduces it
- AND the remediation is not reported as effective

### Requirement: A Green Baseline Is a Precondition

The baseline is a run of the application's own test suite against the checkout
as cloned, with nothing modified. It SHALL be taken **after the analysis
concludes `remediable` and before patching makes its first edit**, and at no
other point:

- *Not before the analysis.* An analysis reaching `no-action-needed` ends the
  run, and the suite would have been compiled and executed for nothing. It is
  the most expensive step in the sequence.
- *Not after patching.* By then there is no unmodified tree left to measure,
  and a baseline taken from a patched checkout is not a baseline.

**Where the baseline is not green, no remediation SHALL be applied.** The run
stops with the failing tests named, for a person to fix before anything is
patched.

Remediating on top of a broken suite makes every later result conditional:
each failure afterwards has to be argued as pre-existing or newly caused, and
that argument is exactly what an agent handed an unfamiliar repository is least
equipped to make. Stopping removes the whole question — after a green baseline,
any failure is the remediation's.

Verification SHALL compare the post-change results against that baseline, and
SHALL report `cannot-verify` where no baseline exists rather than treat the
post-change results as self-evident.

#### Scenario: Baseline Is Not Green

- GIVEN a test suite that fails on the unmodified checkout
- WHEN the baseline is taken
- THEN the run stops with the failing tests named
- AND no change is applied to the application

#### Scenario: Baseline Is Missing

- GIVEN post-change test results and no baseline
- WHEN verification runs
- THEN the terminal state is `cannot-verify`
- AND the results are not attributed to the remediation either way

#### Scenario: Suite Was Green Before and Is Green After

- GIVEN a green baseline
- WHEN the suite passes after the change
- THEN verification records no regression

#### Scenario: A Test Fails That Passed Before

- GIVEN a green baseline
- WHEN a test fails after the change
- THEN verification reports a regression, naming the test
- AND the remediation is not reported as verified

### Requirement: Interpret Failures, Do Not Only Count Them

Running the suite and diffing the results is mechanical. Deciding what a
difference means is not, and that is the part this capability contributes.

Where results differ, verification SHALL establish whether the difference is a
genuine regression, a test that encoded behaviour the remediation deliberately
changed, or an unstable test whose result varies independently of the change.
Where it cannot tell, it SHALL say so rather than choose the convenient reading.

A test asserting the old behaviour is the interesting case: the suite is red,
the remediation is correct, and the honest answer is that the test needs
updating — which is a change a reviewer must approve, not one to make quietly
to turn a build green.

#### Scenario: Test Encodes the Behaviour the Fix Changed

- GIVEN a test that asserts behaviour the remediation deliberately alters
- WHEN it fails after the change
- THEN verification reports what the test asserts and why the remediation
  changes it
- AND does not modify the test to make the suite pass

#### Scenario: Failure Cannot Be Attributed

- GIVEN a failure that cannot be traced to the remediation or to the starting
  state
- WHEN verification completes
- THEN the terminal state is `cannot-verify` with what is unresolved recorded

### Requirement: Prove the Defect Is Gone Where It Can Be Proven

Where an exploit test exists, verification SHALL run it against both the
unmodified and the patched tree, and SHALL require it to fail before the change
and pass after it. A test that passes in both states proves nothing about the
remediation.

Where no exploit test exists, verification SHALL record that the remediation is
established by non-regression and resolved-version evidence alone, and SHALL
NOT describe the defect as proven absent.

No exploit test exists today: the demo application depends on the affected
component but never instantiates the vulnerable class, so there is no reachable
defect to exercise. The distinction is kept explicit so that a remediation
verified the weaker way is not read as the stronger one.

#### Scenario: Exploit Test Demonstrates the Fix

- GIVEN an exploit test for the reported defect
- WHEN it is run against the unmodified tree → THEN it fails
- AND when run against the patched tree → THEN it passes

#### Scenario: Exploit Test Passes Before the Change

- GIVEN an exploit test that passes against the unmodified tree
- WHEN verification evaluates it
- THEN the test is reported as not demonstrating the defect
- AND it is not counted as evidence that the remediation worked

#### Scenario: No Exploit Test Is Available

- GIVEN a reachability verdict that made an exploit test impossible
- WHEN verification completes
- THEN its output states that the evidence is non-regression and the resolved
  version, and that the defect itself was not exercised

### Requirement: Every Baseline Test Survives, Unmodified

Verification SHALL confirm that every test the baseline ran is still present
and unmodified after the change, and SHALL report `cannot-verify` where one is
missing or altered, naming it.

Comparing against a baseline only means something while both sides run the same
tests. A patched tree whose suite is green because a failing test was deleted,
weakened or renamed produces exactly the same green result as one that was
actually fixed, and nothing downstream can tell the two apart. This matters
most on a retry: a capability asked to make a red suite green has a cheap way
to succeed and an expensive one, and the cheap one is to edit the test. The
check is a comparison of two lists, so it is computed rather than asked of a
model, and it holds whether or not anyone intended to cheat.

**Added tests are permitted**, and SHALL be reported separately from the
baseline set. Where patching changes source, covering that change is part of
the change — and a rule that forbade any difference in the test set would
forbid the coverage along with the cheating. The distinction is direction:
removing or weakening an existing assertion destroys evidence, adding one
creates it. An added test SHALL NOT be counted as evidence that anything in the
baseline set now passes.

#### Scenario: A Baseline Test Disappeared

- GIVEN a baseline that ran a given test
- WHEN that test is absent from the post-change run
- THEN the terminal state is `cannot-verify`, naming the missing test
- AND the suite is not reported as green

#### Scenario: A Test Was Modified Between Baseline and Retry

- GIVEN a retry after a reported regression
- WHEN a test's assertions differ from those the baseline ran
- THEN the terminal state is `cannot-verify`, naming the modified test
- AND the remediation is not reported as verified

#### Scenario: Patching Added Coverage for a Source Change

- GIVEN a change that modified application source
- AND tests added alongside it that the baseline did not run
- WHEN verification compares the suites
- THEN every baseline test is still present and unmodified
- AND the added tests are reported as additions, not as baseline results

### Requirement: A Regression Is Returned for One Bounded Retry

Where verification reports `regression`, the finding SHALL be returned to
patching so the cause can be addressed, and the sequence SHALL be attempted at
most **twice** in total.

The evidence returned SHALL name the failing tests, what each asserts, and the
baseline result for each. A retry given only "the suite is red" has to
rediscover what verification already established, and will spend its budget
doing it.

Two attempts, not more. A remediation that is still breaking behaviour after
one informed correction is not converging, and further attempts trade an
unbounded number of model calls for a decreasing chance of a result a reviewer
would accept. On exhaustion the run fails with the last evidence recorded.

A retry SHALL be evaluated against the original baseline, never against the
results of the failed attempt. Re-baselining on a broken tree would let each
attempt redefine what "unchanged behaviour" means, and a regression introduced
in the first attempt would become the standard the second is measured against.

#### Scenario: Retry Resolves the Regression

- GIVEN a first attempt that broke a test which passed in the baseline
- WHEN patching addresses the cause and verification runs again
- THEN the comparison is made against the original baseline
- AND the terminal state is `verified` if no regression remains

#### Scenario: Retry Does Not Resolve It

- GIVEN a regression that persists after the second attempt
- WHEN verification completes
- THEN the run fails with the terminal state `regression`
- AND the evidence from the final attempt is recorded for a reviewer

### Requirement: Explicit Terminal State

Verification SHALL end in exactly one of three states, and the run's exit status
SHALL reflect it:

| State | Meaning | Outcome |
|---|---|---|
| `verified` | The remediating version resolves, and behaviour is unchanged except where the remediation requires it | Proceed to pull request creation |
| `regression` | The change broke behaviour that worked before | Return to patching if an attempt remains; otherwise failure, with the affected tests named |
| `cannot-verify` | The evidence could not be established — no baseline, the suite could not be run, the suite changed, or a difference could not be attributed | Failure, with what is missing recorded |

`cannot-verify` is never retried. A retry addresses a known cause; this state
means the cause is not known, and repeating the attempt would produce another
unattributable result rather than a better one.

`cannot-verify` SHALL NOT be reported as `verified`. A remediation nobody could
check is the case this capability exists to surface, and collapsing it into
success is the failure the honest exit status contract was written against.

#### Scenario: Suite Cannot Be Run

- GIVEN a patched tree whose test suite does not execute
- WHEN verification attempts it
- THEN the terminal state is `cannot-verify` with the execution failure recorded
- AND the run exits non-zero

### Requirement: Output Consumable by Pull Request Creation

Verification SHALL produce: the terminal state, the resolved version of the
affected component after the change, the baseline and post-change test results
with any difference and its attribution, whether an exploit test ran and what
it showed, and what the evidence does **not** establish.

The pull request has to tell a reviewer what was checked and what was not. That
last part is the one a diff cannot supply and the one most easily lost.

#### Scenario: Evidence Reaches the Pull Request

- GIVEN a completed verification
- WHEN the pull request is written
- THEN it states the resolved version, the test outcome against the baseline,
  and whether the defect itself was exercised
- AND those claims are not re-derived from the working tree

## Non-Goals

Verification does not modify the application: not the source, not the manifest,
not the tests. A capability that can edit what it is measuring cannot be relied
on to report what it measured. Where the remediation requires a test to change,
that is reported for a reviewer to decide, and the change belongs to patching.

It does not commit, push, or open a pull request.

## Design Decisions

- What is computed versus what is reasoned about:
  [ADR-0005](../../docs/adr/0005-determinism-boundary.md)
- What verification consumes:
  [code-patching.spec.md](code-patching.spec.md),
  [vulnerability-analysis.spec.md](vulnerability-analysis.spec.md)
- Exploit test generation: pending
  [exploit-test-generation.spec.md](exploit-test-generation.spec.md), blocked
  until the demo application reaches the vulnerable code
  ([ROADMAP](../../docs/ROADMAP.md) Phase 1)
- Runtime, credentials and permissions:
  [agent-runtime.spec.md](../platform/agent-runtime.spec.md)
- Orchestration strategy: pending
  [orchestration-strategy.spec.md](orchestration-strategy.spec.md). Four
  guarantees are owed by whatever sequences these capabilities:
  1. the baseline is captured after the analysis concludes `remediable` and
     before patching edits anything;
  2. a baseline that is not green stops the run before any change is applied;
  3. a returned regression re-enters patching at most once;
  4. the original baseline is carried into the retry rather than recaptured.
