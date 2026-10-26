# Orchestration Specification

## Purpose

What has to be true of whatever runs the remediation capabilities in order:
the sequence, the conditions under which each one runs, and the state that
passes between them.

Six specs defer obligations here. They were written to hold whichever way this
resolves, which only works if the obligations are collected somewhere and
honoured. This is that somewhere.

Scope is one vulnerability record and one repository through to one pull
request. How the record arrives — webhook, event listener, Trusted Profile
Analyzer — is a separate question that depends on systems that do not exist
yet, and tying this document to it would block it on something external.

This spec says what the orchestration must do. **Which** orchestration —
pipeline tasks or a coordinating agent — is a decision with trade-offs, and it
is recorded in
[ADR-0009](../../docs/adr/0009-tekton-pipeline-orchestration.md): a Tekton
Pipeline, one Task per phase. The requirements below are written against
neither, and still hold if that is revisited.

## The sequence

```
analyse → remediable? → baseline → green? → demonstrate → patch → verify → deliver
             │ no                     │ no                  ↑        │ regression
             ↓                        ↓                     └────────┘ (once)
      stop, nothing changed    stop, nothing changed
```

`scripts/remediate.sh` implements this today and satisfies every requirement
below. It exists to be replaced — by Tekton in ROADMAP Phase 3 — and the
contract it establishes is what the replacement inherits.

## Requirements

### Requirement: State Passes as Files, Not as Session Memory

Each capability SHALL receive its inputs and leave its output as files in the
workspace's output directory, and the orchestration SHALL NOT carry state
between them in any other form.

This is what makes the arrangement replaceable. A phase that reads a document
and writes a document does not know, and must not need to know, whether the
phase before it was a pipeline task, a session in the same process, or a
recorded result from last week. It is also what keeps the capabilities
independently testable: every one of them can be run from documents on disk.

Required by [`agent-runtime.spec.md`](../platform/agent-runtime.spec.md) —
Non-Goals, which keeps the runtime orchestration-agnostic so this decision can
be made on its merits.

#### Scenario: A Phase Runs From Recorded Inputs

- GIVEN the documents an earlier phase would have produced
- WHEN a later phase is run against them directly
- THEN it behaves as it would in a full sequence
- AND it needs nothing from the process that produced them

### Requirement: The Sequence Is Reproducible

Given the same inputs and the same recorded phase outputs, the orchestration
SHALL make the same decisions: the same phases, in the same order, with the
same retries.

The capabilities are not reproducible — they are model sessions, and the same
input has produced 41 turns and 108. The orchestration is the layer where
reproducibility is still available, and it is where the guarantees below live.
Giving that up means no longer being able to say what the system does, only
what it did last time.

It also has a practical cost. Phases take minutes and cost money; the
sequencing does not need to, and should be testable in seconds against
recorded documents (ROADMAP — mocking the agent calls). An orchestration that
reasons cannot be replayed that way.

#### Scenario: Replaying Recorded Outputs Reproduces the Decisions

- GIVEN a set of recorded phase documents from a previous run
- WHEN the sequence is replayed against them with no sessions started
- THEN the same phases run in the same order with the same retries
- AND the run completes in seconds

### Requirement: Phases Run Only When Their Precondition Holds

The orchestration SHALL evaluate each phase's precondition from the previous
phase's terminal state, and SHALL NOT invoke a phase whose precondition fails.

| Phase | Runs when |
|---|---|
| baseline | the analysis reached `remediable` |
| demonstrate | the baseline is green |
| patch | the demonstration is `demonstrated` or `not-demonstrable` |
| verify | patching reached `patched` |
| deliver | verification reached `verified` |

The capabilities are written to assume their precondition rather than defend
against its absence: [`code-patching.spec.md`](code-patching.spec.md) states
plainly that reaching patching at all is a decision made upstream. That
assumption is only safe because it is enforced here.

#### Scenario: Nothing to Remediate

- GIVEN an analysis whose terminal state is `no-action-needed`
- WHEN the sequence continues
- THEN no further phase runs
- AND the run succeeds, having changed nothing

#### Scenario: Verification Did Not Pass

- GIVEN a verification whose terminal state is not `verified`
- WHEN the sequence continues
- THEN no pull request is opened
- AND the run fails carrying the evidence

### Requirement: The Baseline Is Captured Once, at the Right Moment

The orchestration SHALL capture the test baseline **after** the analysis
concludes `remediable` and **before** any phase modifies the repository, SHALL
stop the run where that baseline is not green, and SHALL carry the original
baseline into any retry rather than recapturing it.

Four obligations from
[`fix-verification.spec.md`](fix-verification.spec.md), and each fails
differently if ignored. Earlier than the analysis wastes the most expensive
deterministic step on runs with nothing to remediate. Later than the first
modification leaves no unmodified tree to measure. A red baseline makes every
later result conditional, which is the argument an agent handed an unfamiliar
repository is least equipped to make. And re-capturing on a retry lets a
regression introduced by the first attempt become the standard the second is
measured against.

#### Scenario: Retry Measured Against the Starting State

- GIVEN a regression returned to patching
- WHEN verification runs again
- THEN it compares against the baseline captured before the first attempt
- AND not against the results of the attempt that failed

#### Scenario: Red Baseline Stops the Run

- GIVEN a test suite that fails on the unmodified checkout
- WHEN the baseline is captured
- THEN the run stops with the failing tests named
- AND no phase has modified the repository

### Requirement: The Demonstration Is Added After the Baseline

The generated exploit test SHALL enter the repository after the baseline is
captured and before patching, and SHALL NOT be part of what the baseline
measures.

The two carry opposite expectations — the baseline must be green, the
demonstration must be red — and a baseline containing it is red by
construction, stopping the run before the remediation it exists to prove.
Required by
[`exploit-test-generation.spec.md`](exploit-test-generation.spec.md) —
Separate From the Baseline.

#### Scenario: Both States Hold at Once

- GIVEN a green baseline and a generated test that fails
- WHEN the sequence evaluates whether to continue
- THEN the red demonstration does not stop the run
- AND the green baseline is what the later comparison uses

### Requirement: Retries Are Bounded and Addressed at Their Cause

Where verification reports `regression`, the orchestration SHALL return it to
patching at most **once**, SHALL pass the evidence verification produced, and
SHALL fail with that evidence when the attempt is exhausted.

A remediation still breaking behaviour after one informed correction is not
converging, and further attempts trade an unbounded number of model calls for
a decreasing chance of a result a reviewer would accept. `cannot-verify` is
never retried: a retry addresses a known cause, and that state means the cause
is not known.

Measured: of five runs against a fixture needing a source change, two reached
`verified` on the first attempt and two on the second. The retry is load
bearing, and one attempt is enough.

#### Scenario: The Retry Resolves It

- GIVEN a first attempt that left the demonstration failing
- WHEN the regression is returned with the failing tests and what they assert
- THEN patching addresses the cause
- AND verification passes on the second attempt

#### Scenario: Evidence Could Not Be Established

- GIVEN a verification whose terminal state is `cannot-verify`
- WHEN the sequence continues
- THEN no retry is attempted
- AND the run fails with what could not be established

### Requirement: One Run per Application

The orchestration SHALL refuse to start a run against an application another
run is already remediating, whatever working directory it would use.

Two reasons, and they are different. Sharing a workspace hangs: the second run
resets the repository under the first, which then waits on work that no longer
exists, and it stops without an error. Separate workspaces do not hang, but
both branch from the same base and both open a pull request — a reviewer gets
two remediations of one repository that know nothing about each other, and
merging either invalidates the other's verification.

The dual-agent arrangement is not an exception. Several candidates of the same
application, produced deliberately with a judge delivering one, is **one run
with several candidates** rather than several runs; it takes this lock once
and manages its candidates underneath.

#### Scenario: A Second Run on the Same Application Is Refused

- GIVEN a run in progress against an application
- WHEN another is started against that application in a different workspace
- THEN it is refused before doing anything
- AND the run in progress is unaffected

### Requirement: Two Lifetimes, Two Volumes

A run SHALL use two separate stores, with different lifetimes:

| Store | Lifetime | Holds |
|---|---|---|
| **Workspace** | created and discarded per run | the checkout, the phase documents, the session traces |
| **Dependency cache** | outlives every run | what the build fetches from its repositories |

Putting both in one place forces a choice between two failures. A single
store discarded per run makes every run pay the cold cache: more than fifteen
minutes against roughly two warm, on a sequence that already takes seven to
eleven, and a dual-agent run pays it per candidate. A single store kept
between runs carries state nobody asked for — during development, leftover
branches, untracked files and stale test reports each produced a wrong result,
and each did so silently.

Separating them takes both costs away. The workspace starts empty every time,
so nothing survives to mislead the next run; the cache survives, so only the
first run against a set of dependencies fetches them.

The first run still pays the fetch. That is expected and paid once, and it is
worth doing before anyone is watching rather than during a demonstration.

Because the cache is shared across runs — and, where different applications
run concurrently, across applications — an implementation SHALL NOT assume
exclusive use of it. Concurrent reads of a warm cache are safe; two runs
populating the same cold entry can race on a partial download.

#### Scenario: The Workspace Starts Empty

- GIVEN a previous run that left branches, untracked files and build output
- WHEN a new run starts
- THEN none of it is present
- AND nothing from the previous run can influence the result

#### Scenario: The Cache Survives

- GIVEN a run that fetched an application's dependencies
- WHEN a later run starts, with a fresh workspace
- THEN it resolves from the existing cache
- AND does not re-fetch what the first already retrieved

### Requirement: Producing a Candidate Is Separable From Delivering It

The phases through verification SHALL produce a **candidate** — a working tree
and the documents describing it — without that production depending on how, or
whether, it is delivered. Delivery SHALL consume a candidate and SHALL NOT
require having produced it.

Milestone 2 runs this sequence more than once with different models and has a
judge pick between the results, combine them, or reject both; delivery then
belongs to the judge rather than to any one sequence. That is a change to what
decides, not to how a remediation is produced, and the separation is what
keeps it that way.

It costs nothing today. A candidate is already what the sequence leaves
behind: the analysis, the demonstration, the patch and the verification, each
naming what it established and what it did not, plus the tree they describe.
Those documents are what a judge would compare — a remediation verified by a
failing-then-passing test against one resting on non-regression is a
comparison the documents already support, because each says how far its
evidence goes.

Two consequences worth stating now, while they are cheap:

- **The model is an invocation parameter**, not deployment configuration.
  Running the same sequence twice with different models is otherwise two
  deployments.
- **Candidates do not share a workspace.** Two sequences producing into one
  tree would overwrite each other. They do share the dependency cache, which
  is what keeps a second candidate from paying the cold-cache cost again.

#### Scenario: A Candidate Is Produced Without Being Delivered

- GIVEN a sequence run through verification
- WHEN delivery is not invoked
- THEN the candidate and its documents remain complete and self-describing
- AND nothing about the earlier phases differs from a run that was delivered

#### Scenario: Delivery Consumes a Candidate It Did Not Produce

- GIVEN a candidate produced by a separate sequence
- WHEN delivery is invoked against it
- THEN it delivers that candidate
- AND requires nothing from the process that produced it

### Requirement: The Run's Outcome Is a Single Honest Status

The orchestration SHALL exit non-zero where the remediation did not complete,
and SHALL NOT report success for a run that stopped early, failed a phase, or
delivered nothing — except where the analysis established there was nothing to
remediate, which is a successful outcome.

Whatever triggered the run acts on this status. The distinction that matters
is between *nothing needed doing* and *something needed doing and did not get
done*; both leave the repository unchanged, and collapsing them is what the
honest exit status contract exists to prevent
([`agent-runtime.spec.md`](../platform/agent-runtime.spec.md) — Honest Exit
Status).

#### Scenario: Nothing Needed Doing

- GIVEN an analysis reaching `no-action-needed`
- WHEN the run completes
- THEN it exits zero
- AND records that no change was required

#### Scenario: Something Needed Doing and Did Not Happen

- GIVEN any phase that failed to reach its successful terminal state
- WHEN the run completes
- THEN it exits non-zero
- AND the phase that stopped it is identifiable from its output

## What the implementation has to face

Established against the Phase 0.5 cluster. These were written before the
implementation was chosen and were relevant whichever way it went;
[ADR-0009](../../docs/adr/0009-tekton-pipeline-orchestration.md) records how
each is handled:

- **A PipelineRun committed to git is permanent drift under GitOps.** Runs are
  created imperatively or by a trigger, never reconciled.
- **The phases share a workspace**, because the output directory is the handoff.
  Read-write-once suffices while the chain is strictly serial; read-write-many
  is available if that ever changes.
- **A `volumeClaimTemplate` is right for the workspace and wrong for the
  cache.** It creates and destroys storage with the PipelineRun, which is
  exactly what the workspace wants and exactly what the cache must not have.
  Two workspaces in the Pipeline: a template for one, a persistent claim for
  the other.
- **A `volumeClaimTemplate` does not actually discard anything by default.**
  Under the affinity assistant's `coschedule: workspaces` mode — this
  cluster's setting — the claim outlives the run unless
  `tekton.dev/auto-cleanup-pvc` is set on it. Two orphans were already in the
  namespace before anyone looked.
- **The same mode allows only one PVC-backed workspace per task**, and these
  tasks need the run's own. The two stores cannot both be Tekton workspaces
  without changing a cluster-wide setting shared with every other pipeline.
- **The first run against an application is slow and that is expected.** Worth
  warming before anything anyone is watching.
- **Container limits are 4 CPU and 8 GiB.** A build needing more is rejected by
  the LimitRange rather than the scheduler, and that error does not read as
  one about resources.
- **`pipeline` is an ambiguous short name** on a cluster with RHOAI installed:
  it resolves to Kubeflow. Fully qualified names only.
- **The agent service account holds no Role**, deliberately — the agent does
  not talk to the Kubernetes API. Anything that creates runs needs its own
  identity and its own permission to do so.

## Non-Goals

How a vulnerability record reaches the orchestration — webhook, event
listener, Trusted Profile Analyzer — is out of scope. So is what happens to
the pull request afterwards.

This spec does not name an implementation. That is
[ADR-0009](../../docs/adr/0009-tekton-pipeline-orchestration.md)'s job, and
nothing above depends on how it went.

## Design Decisions

- Obligations collected here are stated in
  [`vulnerability-analysis.spec.md`](vulnerability-analysis.spec.md),
  [`exploit-test-generation.spec.md`](exploit-test-generation.spec.md),
  [`code-patching.spec.md`](code-patching.spec.md),
  [`fix-verification.spec.md`](fix-verification.spec.md) and
  [`pr-creation.spec.md`](pr-creation.spec.md)
- Runtime invocation contract and the honest exit status:
  [`agent-runtime.spec.md`](../platform/agent-runtime.spec.md)
- What is computed versus reasoned about:
  [ADR-0005](../../docs/adr/0005-determinism-boundary.md). Sequencing is
  determined by its inputs, which is what the reproducibility requirement
  above turns into an obligation.
- Pipeline tasks versus a coordinating agent:
  [ADR-0009](../../docs/adr/0009-tekton-pipeline-orchestration.md), which also
  records why RHOAI AI Pipelines and Argo Workflows were set aside
