# Pull Request Creation Specification

## Purpose

How a verified remediation is delivered: as a pull request a reviewer can act
on. This is where the work becomes visible to someone who was not watching it
happen, and the only artefact of the whole sequence that a human is expected
to read.

This spec describes a **capability**, not a process boundary. Whether it runs
as a Tekton task, a dedicated agent, or a phase of a single session is decided
by `orchestration-strategy.spec.md`.

## Requirements

### Requirement: Deliver Only What Was Verified

A pull request SHALL be opened only where verification reached `verified`.

The candidate delivered need not be one this process produced. Milestone 2
runs the sequence more than once and has a judge choose between the results,
at which point delivery consumes a candidate chosen elsewhere — the condition
above still holds, and nothing else about this capability changes
([orchestration-strategy.spec.md](orchestration-strategy.spec.md) —
Producing a Candidate Is Separable From Delivering It).

Delivery is the point at which a machine's work starts asking for a human's
attention, and a pull request is a claim that something is ready to merge. A
remediation that regressed behaviour, or whose evidence could not be
established, has not earned that claim — it has earned a report, and the
run's non-zero exit is that report.

#### Scenario: Verification Did Not Pass

- GIVEN a verification whose terminal state is not `verified`
- WHEN delivery is considered
- THEN no pull request is opened
- AND the run's failure carries the evidence

### Requirement: The Narrative Comes From the Evidence

The pull request body SHALL be written from the analysis, patch and
verification documents, and SHALL NOT restate anything those documents do not
establish.

Every claim a reviewer needs is already recorded by the time delivery runs:
which component and which advisory, whether the vulnerable code was reachable
and on what evidence, which version was applied and why that one, what changed
in the source and what required it, and what the testing did and did not show.
Re-deriving any of it from the diff loses the reasoning — a diff shows a
version number moving, not why a backport was chosen over an upstream release.

#### Scenario: Body Reconstructed From the Documents

- GIVEN completed analysis, patch and verification documents
- WHEN the pull request is written
- THEN each claim in the body traces to a field of one of them
- AND no claim is derived from reading the diff alone

### Requirement: State What the Evidence Does Not Show

The body SHALL carry verification's account of what was not established, in
terms a reviewer can act on.

This is the requirement most easily dropped and the one that decides whether
the pull request can be trusted. A remediation verified by non-regression
alone is not the same as one demonstrated by a test that failed before the
change and passes after it, and a reviewer who cannot tell them apart will
treat the weaker as the stronger. An automated pull request that overstates
its evidence once is an automated pull request nobody reads carefully again.

#### Scenario: No Exploit Test Existed

- GIVEN a verification stating the defect itself was never exercised
- WHEN the pull request is written
- THEN the body says so plainly
- AND does not describe the vulnerability as proven fixed

#### Scenario: The Component Was Not Reachable

- GIVEN an analysis whose reachability verdict was `not-reachable`
- WHEN the pull request is written
- THEN the body states that the dependency was affected but its vulnerable
  code was not reached from this application
- AND presents the upgrade as sound rather than as urgent

#### Scenario: A Limit Is Not Presented as Outstanding Work

- GIVEN a remediation whose evidence stops at some boundary
- WHEN the pull request is written
- THEN the limit is stated as a fact about what the evidence reaches
- AND it is not written as an unfinished task a reviewer could complete

A limit is permanent; a task is a chore. The first delivered pull request
listed both in one checklist, so "concurrent replay was not exercised"
appeared as an unticked box and the request read as four of six tasks done.
Nobody was going to exercise distributed replay before merging — but the box
invited a reviewer to tick it and clear the count, which would have asserted
exactly the thing this requirement exists to stop being asserted.

### Requirement: Reviewable in One Commit

The change SHALL be delivered on a branch of its own, as a single commit whose
message explains the remediation, and SHALL NOT include anything the
remediation did not require.

A reviewer deciding whether to trust an automated dependency change reads the
diff. Intermediate commits from a retry, a reformatted file, an unrelated
upgrade — each one costs attention and buys nothing, and a diff where the fix
has to be found among incidental churn gets approved without being read.

A regenerated bill of materials is not churn, and it is the one thing here
that looks like it. It is hundreds of kilobytes of generated JSON and it
will dominate the diff, but the remediation did require it: without it the
inventory still names the vulnerable version and the alert fires again. It
belongs in the commit, and the body says it is there so nobody reads the
line count as a mistake.

#### Scenario: A Retry Happened

- GIVEN a remediation that took two patching attempts
- WHEN the branch is delivered
- THEN it carries one commit, not the history of the attempts

### Requirement: Attributable to the Agent

Commits and the pull request SHALL be authored by the configured agent
identity, never by a person.

Whoever reviews this has to know a machine wrote it, and whoever audits the
repository later has to be able to tell which changes were automated. A
commit carrying a developer's name is a false attribution that survives in
the history.

#### Scenario: Authorship Is the Agent

- GIVEN a delivered pull request
- WHEN its commit and authorship are inspected
- THEN both name the configured agent identity

### Requirement: Explicit Terminal State

Delivery SHALL end in exactly one of two states, and the run's exit status
SHALL reflect it:

| State | Meaning | Outcome |
|---|---|---|
| `delivered` | A pull request is open, carrying the change and its evidence | Success, with the URL recorded |
| `cannot-deliver` | The branch, the push or the pull request failed | Failure, with the reason |

A branch pushed without a pull request opened is `cannot-deliver`, not
`delivered`: the work exists but nobody has been asked to look at it.

#### Scenario: The Push Is Rejected

- GIVEN a credential without permission to push
- WHEN delivery attempts it
- THEN the terminal state is `cannot-deliver` naming the failure
- AND the run exits non-zero

### Requirement: Output Recording the Delivery

Delivery SHALL produce: the terminal state, the branch name, the pull request
URL, and the commit it carries.

The pipeline that ran this, and the alert that triggered it, both need
somewhere to point. A run that opened a pull request and did not record where
leaves the trigger unable to close the loop.

#### Scenario: Delivery Is Traceable

- GIVEN a delivered remediation
- WHEN the run completes
- THEN its output names the branch, the pull request URL and the commit

## Non-Goals

Delivery does not patch, does not verify, and does not merge. It does not
decide whether a remediation is good — verification did that, and this
capability refuses to deliver when it said no.

It does not regenerate the bill of materials. That used to say the inventory
came from a build of the merged result, which left every pull request
carrying one that still named the vulnerable version — the alert's own
evidence, contradicting the change it accompanied. The inventory is now
produced before delivery, by a task of its own
([`pipeline.spec.md`](../devsecops/pipeline.spec.md) — The Inventory Is
Regenerated From the Remediated Build). Delivery commits what it finds in
the working tree and does not build anything.

## Design Decisions

- What delivery consumes: [vulnerability-analysis.spec.md](vulnerability-analysis.spec.md),
  [code-patching.spec.md](code-patching.spec.md),
  [fix-verification.spec.md](fix-verification.spec.md)
- Repository credentials and the agent identity:
  [agent-runtime.spec.md](../platform/agent-runtime.spec.md) — Repository
  Access, [ADR-0003](../../docs/adr/0003-agent-runtime-packaging-and-credentials.md)
- What is computed versus reasoned about:
  [ADR-0005](../../docs/adr/0005-determinism-boundary.md). Branching, committing
  and opening the request are commands; the body is not, and it is the only
  part of this capability a model is needed for.
- Orchestration strategy: pending
  [orchestration-strategy.spec.md](orchestration-strategy.spec.md)
