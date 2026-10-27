# DevSecOps Pipeline Specification

## Purpose

What has to be true at the two ends of a remediation:
[`orchestration-strategy.spec.md`](../agents/orchestration-strategy.spec.md)
takes one vulnerability record through to one pull request and deliberately
excludes **how the record arrives** and **what happens to the pull request
afterwards**. This is both of those.

Those two ends are what makes the thing a DevSecOps pipeline rather than a
clever script. A remediation nobody asked for and nobody checks is a demo; a
remediation that starts from a real alert and ends with the alert closed is a
loop.

## A note on Red Hat products

This project is measured partly on how much of the Red Hat portfolio it uses
sensibly. That is a real constraint and it is worth stating plainly, because
it can corrupt a spec if handled badly.

A spec says what the system must do. **"Use product X" is a decision, and
decisions belong in ADRs.** A requirement written so that only one product
can satisfy it is an ADR wearing a spec's clothes, and it stops being a test
of the system and becomes a test of the procurement.

So the requirements below are written as obligations. Which Red Hat product
serves each is recorded separately, under *Red Hat products*, where the
mapping can be argued with and changed without rewriting the contract. Where
a product would be added only to raise the count, that section says so.

## Requirements

### Requirement: A Run Starts From an Alert

The pipeline SHALL be startable by a vulnerability alert without a person
acting, and a human-initiated run SHALL be the same pipeline with the same
inputs.

An agent that only runs when someone remembers to run it has not automated
anything; it has moved the work. The point of the alert path is that the
remediation begins while the person who would have started it is asleep.

Keeping the manual path identical rather than parallel is what makes the
automatic one trustworthy: the thing demonstrated by hand is the thing that
fires at 3am, not a sibling of it.

#### Scenario: An Alert Produces a Run

- GIVEN a vulnerability alert for a repository the pipeline knows
- WHEN it reaches the trigger
- THEN a run starts against that repository and that record
- AND nobody was involved

#### Scenario: A Person Starts the Same Run

- GIVEN the same record supplied by hand
- WHEN a run is started
- THEN it is the same pipeline, with the same parameters and the same result
- AND nothing about it is a special case

### Requirement: The Record Travels With the Run

The trigger SHALL supply the vulnerability record and the repository, and the
pipeline SHALL refuse to start without both.

Every phase downstream reads the record: the analysis needs the affected
component and the remediating version, generation needs what the defect does,
delivery names the advisory in the pull request. A run that starts without it
discovers the gap in its first session, having already paid to get there.

The record is **data the run carries**, not configuration the cluster holds.
One run remediates one record ([`vulnerability-analysis.spec.md`](../agents/vulnerability-analysis.spec.md)),
and a cluster that holds "the current record" cannot run two.

The run carries it one of two ways: the record itself, or the address of the
record at its source. An address is resolved once, by the run, with the
source's credentials, before any session starts — so every phase reads the
same document and no session holds the credentials. A record can bundle
several vulnerabilities fixed by one release (Lightwell advisories do); the run
then also names the one it is for, and the analysis is held to it.

#### Scenario: An Alert Without a Usable Record

- GIVEN an alert the trigger cannot turn into a record and a repository
- WHEN it arrives
- THEN no run is started
- AND the rejection says which part was missing

### Requirement: Repeated Alerts Do Not Produce Repeated Remediations

Where an alert fires again for a vulnerability already being remediated, or
already remediated and awaiting review, the pipeline SHALL NOT open a second
pull request for it.

Scanners re-run. An alert is a statement that a vulnerability is present, and
it stays present until the fix is merged — so the same alert will arrive
again while the first remediation is still open, and again after it, until
someone merges. Each one that starts a run costs money and puts another pull
request in front of a reviewer who has not finished reading the first.

The in-flight case is already covered: the orchestration refuses a second run
against an application it is already remediating
([`orchestration-strategy.spec.md`](../agents/orchestration-strategy.spec.md) —
One Run per Application). The open-pull-request case is not, and is this
requirement's share.

#### Scenario: The Alert Fires Again While the Pull Request Is Open

- GIVEN a remediation delivered and awaiting review
- WHEN the scanner reports the same vulnerability again
- THEN no second run starts
- AND the existing pull request is what the alert is pointed at

### Requirement: The Pull Request Is Built Where the Credentials Already Are

Continuous integration on the generated branch SHALL run where the build
credentials already exist, and the pipeline SHALL NOT require those
credentials to be copied to a third-party runner to make a build pass.

This is not a preference. The remediated version is a vendor rebuild
published to an authenticated repository, so any build that resolves it needs
those credentials — and a build that does not have them fails on exactly the
pull request the remediation is about, which reads as a bad patch rather than
a missing secret. Measured: the existing GitHub Actions workflow builds
without them and goes red on every remediation.

Putting them where the build runs today would mean a repository secret that
anyone with write access can read back out through a workflow. The cluster
already mounts them for the agent, so building there costs no new exposure.

#### Scenario: The Build Resolves the Remediated Version

- GIVEN a branch whose manifest names a vendor rebuild
- WHEN continuous integration builds it
- THEN the dependency resolves
- AND no credential was added to the source repository to make that true

How Milestone 1 satisfies this: by there being no build on the generated
branch at all. CI on the pull request was cut from the submission scope on
2026-10-20, the workflow that built without credentials is not published to
the demo repository, and the remediated tree is already built and tested
inside the run — a green baseline, the exploit test failing then passing, no
regression — before the pull request opens. The requirement stands for when a
branch build returns.

### Requirement: The Inventory Is Regenerated From the Remediated Build

Where the application publishes a bill of materials, the pipeline SHALL
produce an updated one from the remediated build, and SHALL do so before the
pull request is opened.

The alert came from an inventory. A remediation that changes the dependency
and leaves the inventory saying otherwise has not closed the loop: whatever
re-scans sees the vulnerability still listed, the alert fires again, and the
pull request claims a fix while carrying evidence against itself. Measured —
a delivered pull request had its manifest at the rebuilt version and its
inventory still at the vulnerable one.

Before the pull request rather than after, because that is what lets the
inventory be validated while the change can still be rejected.

#### Scenario: The Inventory Agrees With the Manifest

- GIVEN a remediation that moved a dependency
- WHEN the pull request is opened
- THEN its inventory names the remediated version
- AND the vulnerability the run started from is absent from it

#### Scenario: Validated Before Merge

- GIVEN an updated inventory on the branch
- WHEN it is validated against the vulnerability service
- THEN the result is available to the reviewer
- AND it describes the branch, not the state before the remediation

### Requirement: A Run Is Legible Without Reading Logs

The pipeline SHALL make a run's progress and outcome visible as it happens,
phase by phase, and SHALL keep what each phase established after the run ends.

Two different readers. Someone watching needs to know where a seven-to-eleven
minute run has got to without attaching to a pod. Someone arriving afterwards
needs to know what the agent did and why, and a model session is the least
self-evident artefact in the system — the same input has produced 41 turns
and 108.

The phase documents already carry the reasoning
([`orchestration-strategy.spec.md`](../agents/orchestration-strategy.spec.md)
— State Passes as Files). What this adds is that they outlive the workspace,
which is discarded per run by design.

#### Scenario: A Run Is Watched

- GIVEN a run in progress
- WHEN it is observed
- THEN the phase it is in and the phases it has finished are visible
- AND no log needs to be opened to see that

#### Scenario: A Run Is Read a Week Later

- GIVEN a completed run whose workspace is gone
- WHEN someone asks what it established and what it cost
- THEN the answer survives
- AND it is attributable to that run

### Requirement: The Alert Is Answered

When a run ends, the pipeline SHALL report its outcome back to whatever
started it, distinguishing a remediation delivered from a run that found
nothing to do from a run that failed.

Those three are different answers and a scanner acting on them does different
things: close the finding, record that the application is not exposed, raise
it to a person. Collapsing them is what the honest exit status exists to
prevent ([`orchestration-strategy.spec.md`](../agents/orchestration-strategy.spec.md)
— The Run's Outcome Is a Single Honest Status); this requirement is that the
distinction survives the last hop.

A run whose outcome nobody receives is a run somebody has to go and look for,
which is the manual step the alert path removed.

#### Scenario: Nothing Needed Doing

- GIVEN a run whose analysis found the application not exposed
- WHEN it completes
- THEN what triggered it learns that, specifically
- AND not merely that the run succeeded

#### Scenario: The Run Failed

- GIVEN a run that stopped at a phase
- WHEN it completes
- THEN what triggered it learns which phase and why
- AND a person can be reached without reading the cluster

### Requirement: What the Cluster Runs Is in Git

Every long-lived object the pipeline needs SHALL be reconciled from the
repository, and the only things created outside it SHALL be the runs
themselves.

A pipeline that works because of something somebody typed once is a pipeline
that works until the cluster is rebuilt — which, for a demo environment that
exists to be reproducible, is a question of days. Measured twice in one day:
a build was pinned to a branch by hand and reconciliation undid it within the
hour, which is the mechanism working; and two console plugins sat installed
but disabled, invisible to git, making an installed product look absent.

The exception is deliberate and narrow. A run is a record of something that
happened; reconciled from git it would be recreated forever.

#### Scenario: The Cluster Is Rebuilt

- GIVEN a new cluster and the repository
- WHEN the bootstrap is applied
- THEN the pipeline can take an alert and deliver a pull request
- AND nothing had to be remembered

## Where Milestone 1 stands

One requirement above carries a note saying how the submission satisfies it.
That is useful and it is also misleading on its own: a reader meeting a
single annotation reasonably assumes the other seven are plainly met, and
four of them are not. The whole map, as of 2026-10-20:

| Requirement | Milestone 1 |
|---|---|
| A Run Starts From an Alert | **No.** The webhook trigger is out of scope; a run is a `PipelineRun` someone creates. The manual path is the same pipeline, which is the half that holds. |
| The Record Travels With the Run | Yes. Mounted as a ConfigMap, or fetched once from Lightwell by the first phase (path A, since 2026-10-27); one record per run, and a `vulnerability` parameter where the record bundles several. |
| Repeated Alerts Do Not Produce Repeated Remediations | **Half.** A second run against an application already being remediated is refused. Nothing checks for an open pull request — and with no trigger, nothing re-fires to be refused. |
| The Pull Request Is Built Where the Credentials Already Are | Vacuously — there is no branch build. See the note on the requirement. |
| The Inventory Is Regenerated From the Remediated Build | Yes. *Validated Before Merge* against a TPA on a separate RHDP cluster ([workaround](../../docs/workarounds.md)); the result goes in the pull request body. |
| A Run Is Legible Without Reading Logs | **Half.** The Pipelines console shows the phase a run is in. Nothing survives it: the workspace is deleted per run and takes the phase documents with it. MLflow is deployed and unused. |
| The Alert Is Answered | **No.** There is no trigger to answer to. |
| What the Cluster Runs Is in Git | Nearly. Two exceptions, both recorded: the chart is a direct Helm release rather than reconciled, and the BuildConfig's branch lives only in an unmerged pull request. |

Unmet is the normal state of a spec that is ahead of its implementation —
that is what makes it useful. The table exists so nobody has to work out
which half they are standing on.

## Red Hat products

Which product serves each requirement, on the cluster as it stands. This is
the mapping, not the contract — an entry can change without the requirement
changing.

| Requirement | Product | State |
|---|---|---|
| A run starts from an alert | **OpenShift Pipelines** — Tekton Triggers (`EventListener`) | CRDs present, nothing deployed |
| The pull request is built where the credentials are | **OpenShift Pipelines**, and the **internal registry** with `BuildConfig` | In use for the agent image |
| The inventory is regenerated and validated | **Red Hat Trusted Profile Analyzer** | Instance on a separate RHDP cluster (Milestone 1 workaround); operator 3.1.1 installed here, no instance |
| A run is legible | **OpenShift Pipelines** console; **MLflow** (RHOAI) for session traces | Pipelines in use; MLflow `Managed`, unused |
| What the cluster runs is in git | **OpenShift GitOps** | In use, 9 Applications |
| Storage for the two workspaces | **OpenShift Data Foundation** | In use — ceph-rbd and cephfs |
| Inference | **MaaS**, served through **KServe** (RHOAI) | In use |

Adjacent, serving the agent rather than the pipeline, and already decided
elsewhere: **NeMo Guardrails via TrustyAI** for prompt safety, and
**EvalHub** (`evalhubs.trustyai.opendatahub.io`, installed) for scoring patch
quality — both Milestone 2, both in the architecture already.

**Red Hat Developer Hub** is in the Milestone 2 architecture as the place a
run is requested and watched. It is not installed, and it is the one product
here that would serve *A Run Is Legible* better than what we have rather than
merely additionally.

### What would be product bingo

Said explicitly so nobody adds it later thinking it was an oversight.

- **Red Hat Advanced Cluster Security** would be a second scanner next to
  Lightwell. Two scanners disagreeing about whether an application is exposed
  is a problem to debug on stage, not a capability to show.
- **Red Hat Build of Keycloak** is installed and tempting for the webhook's
  authentication. A trigger that validates a shared secret is a few lines; an
  identity provider in front of it is a demo of Keycloak, not of remediation.
- **Quay** would replace an internal registry that already works, and the
  image never leaves the cluster.

The count is not the goal. A product that carries a requirement earns its
place; one that carries a slide does not.

## Non-Goals

This spec does not describe the remediation itself — the sequence, its
preconditions, its retry and its exit status are
[`orchestration-strategy.spec.md`](../agents/orchestration-strategy.spec.md).

It does not decide **which** trigger mechanism, scanner integration or
tracing backend is used. Those are decisions, and each needs an ADR when it
is made; this says what they have to achieve.

It does not cover merging. A pull request is where the machine stops and a
person starts, and nothing here proposes to move that line.

## Design Decisions

- The two ends this spec covers, and why they were excluded there:
  [`orchestration-strategy.spec.md`](../agents/orchestration-strategy.spec.md)
  — Non-Goals
- Orchestrating with Tekton, and the cluster facts that constrain anything
  built on it: [ADR-0009](../../docs/adr/0009-tekton-pipeline-orchestration.md)
- Why the demo repository carries no `sbom.yml` of its own, and why the build
  was not moved into the cluster after all:
  [ROADMAP](../../docs/ROADMAP.md) Phase 3 and *Out of scope for Milestone 1*
- What delivery puts in the pull request, which the reviewer in these
  scenarios is reading: [`pr-creation.spec.md`](../agents/pr-creation.spec.md)
- What is computed versus reasoned about:
  [ADR-0005](../../docs/adr/0005-determinism-boundary.md). Every obligation
  here is deterministic; none of it needs a model.
