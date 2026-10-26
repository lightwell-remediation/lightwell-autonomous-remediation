# Code Patching Specification

## Purpose

How the remediation the analysis identified is applied to the application: what
the change is allowed to touch, what has to be established before touching it,
and when applying it is the wrong answer. Its output is a working tree a build
can be run against and a reviewer can read.

This spec describes a **capability**, not a process boundary. Whether it runs as
a Tekton task, a dedicated agent, or a phase of a single session is decided by
`orchestration-strategy.spec.md`.

## Requirements

### Requirement: Act on the Analysis, Do Not Repeat It

Patching SHALL take the affected component, its resolved version, how that
version is governed, and the remediating version from the analysis document, and
SHALL NOT re-derive them.

It SHALL also receive the OSV record, which carries what the analysis document
does not: the class and method at fault, and the guarantee the flaw breaks.
That is what makes a compilation failure after the change interpretable, and
what lets the pull request explain itself in terms of the defect rather than of
a version number.

The remediating version SHALL continue to come from the analysis, never from
the record's prose. A vulnerability record describes the upstream remedy — this
one says *"Users are recommended to upgrade to versions 4.2.3 or 4.1.8 or
3.6.12"* — while the remediation being applied is a vendor backport of the
affected release. Both are correct and they are not interchangeable: taking the
version from the text would discard the backport in favour of a major upgrade
nobody asked for.

It assumes an analysis that reached `remediable`. Reaching patching at all is a
decision made upstream — a `no-action-needed` analysis has nothing to apply and
a `cannot-remediate` one has nothing to apply it to, and neither case should
arrive here. That guarantee belongs to whatever sequences the capabilities, and
is specified in `orchestration-strategy.spec.md`.

#### Scenario: Patching Consumes the Analysis

- GIVEN an analysis document with terminal state `remediable`
- WHEN patching runs
- THEN it reads the component, the governing declaration and the remediating
  version from that document
- AND does not resolve the dependency tree again

#### Scenario: Record Recommends a Different Version From the Remediation

- GIVEN an OSV record whose text recommends upstream releases
- AND an analysis whose remediating version is a backport of the affected
  release
- WHEN patching applies the change
- THEN the version applied is the one the analysis established
- AND the upstream releases named in the record are not substituted for it

### Requirement: Establish What the Change Moves

Before editing, patching SHALL determine every artifact whose resolved version
changes as a result, and SHALL confirm that each is published at the remediating
version. Where any is not, the change SHALL NOT be applied in that form.

A manifest property is frequently shared. In the demo application a single
`cxf.version` governs both the affected component and a second Apache CXF
artifact; editing it moves both. Had the vendor rebuilt only the affected one,
the obvious one-line patch would have left the build unable to resolve its
sibling — and the failure would have surfaced as a broken build, reading like a
bad patch rather than like a patch that was never applicable.

Enumerating what a declaration governs, and checking whether each resulting
coordinate exists, is lookup rather than judgement. Per
[ADR-0005](../../docs/adr/0005-determinism-boundary.md) it is computed, and the
result is given to the session.

#### Scenario: Shared Property Governs Several Artifacts

- GIVEN the remediating version is applied through a property
- AND that property governs more than one dependency
- WHEN patching establishes what the change moves
- THEN every governed artifact is listed
- AND each is confirmed published at the remediating version before the edit

#### Scenario: A Governed Artifact Has No Remediated Build

- GIVEN a governed artifact that is not published at the remediating version
- WHEN patching establishes what the change moves
- THEN the property is not edited
- AND patching either narrows the change to the affected component alone, or
  reports that it cannot be applied — it does not apply a change it has
  established will not resolve

### Requirement: Strategy Follows Presence

The shape of the change SHALL follow how the component enters the build, as the
analysis classified it:

| Presence | Change |
|---|---|
| `direct` | the declaration governing its version |
| `transitive` | a managed version, or an exclusion plus a direct declaration |

A transitive dependency has no version to edit: it is not in the manifest. A
patch that adds a direct declaration where a managed version would do, or the
reverse, changes the project's dependency structure beyond the remediation.

#### Scenario: Direct Dependency

- GIVEN the analysis classified the component as `direct`
- WHEN the change is applied
- THEN only the declaration governing its version changes

#### Scenario: Transitive Dependency

- GIVEN the analysis classified the component as `transitive`
- WHEN the change is applied
- THEN the remediating version is imposed without declaring the component as a
  new direct dependency of the application, unless an exclusion makes that
  unavoidable
- AND the reason for the chosen form is recorded

### Requirement: Smallest Change That Remediates

The change SHALL be confined to what the remediation requires. Patching SHALL
NOT reformat files, reorder declarations, upgrade unrelated dependencies, or
modify source the remediation does not force it to modify.

A remediation pull request is read by someone deciding whether to trust an
automated change to a dependency they rely on. Every unrelated edit costs that
reader attention and buys nothing, and a diff where the security fix has to be
picked out of incidental churn will be approved without being read — which
defeats the point of opening it.

#### Scenario: Only the Remediation Appears in the Diff

- GIVEN a patched working tree
- WHEN the diff is taken against the starting state
- THEN every changed line is required by the remediation
- AND no file is modified only by formatting

### Requirement: Source Changes the Remediation Forces

Where moving to the remediating version requires the application's own code to
change, making those changes is part of patching. The manifest edit is the
beginning of the remediation, not the whole of it.

Two kinds arise, and they are not equivalent:

- **Compilation forced.** The new version removed, renamed or re-typed
  something the application calls. The code will not build until the call sites
  are adapted, and what to adapt them to is readable from the new version's API.
- **Behaviour forced.** The new version fixes the flaw only when used
  differently — a call that must now be made, a default that must be set. The
  OSV record names the defect and the guarantee it breaks, which is what makes
  this recognisable at all; a version bump alone would leave the application
  still exposed while every build and test passes.

Patching SHALL apply changes of the first kind. For the second, it SHALL apply
them where the record states the required usage, and SHALL report
`cannot-patch` where the correct behaviour cannot be established from the record
and the code rather than inferring it. A guessed security fix that compiles is
worse than an admitted gap, because nothing downstream can tell them apart.

Every source change SHALL be attributable to the remediation. The licence to
touch code here is not a licence to improve it.

Patching SHALL NOT modify, weaken, rename or remove a test in order to make a
suite pass. Where a test asserts behaviour the remediation deliberately
changes, that is reported for a reviewer to decide. A test is the record of
what the application is supposed to do, and editing it to match what the code
now does destroys the only evidence that anything was checked.

### Requirement: Source Changes Arrive With Their Coverage

Where patching modifies application source, it SHALL add tests covering the
modified behaviour.

A dependency bump that compiles is its own evidence; rewritten code is not.
Adapted call sites are the part of a remediation most likely to be subtly
wrong, and they are reviewed by someone who did not write them and cannot run
the vulnerability. Without a test, the pull request asks that reader to take
the rewrite on trust.

Adding a test is not in tension with the prohibition above: the direction is
what distinguishes them. Removing or weakening an existing assertion destroys
evidence; adding one creates it. Verification treats the two separately, and a
test added here is never counted as evidence about the baseline set
([fix-verification.spec.md](fix-verification.spec.md) — Every Baseline Test
Survives, Unmodified).

Tests arrive with the change rather than with the measurement of it, because
verification modifies nothing — including tests.

#### Scenario: Adapted Call Site Is Covered

- GIVEN a remediation that required a source modification
- WHEN patching completes
- THEN a test exercising the modified behaviour is present
- AND it did not exist in the baseline

#### Scenario: Manifest-Only Change

- GIVEN a remediation applied entirely through the manifest
- WHEN patching completes
- THEN no test is added
- AND the existing suite is the evidence

### Requirement: A Returned Regression Is Addressed at Its Cause

Where verification returns a regression, patching SHALL use the evidence it
provides — the failing tests, what each asserts, their baseline results — to
address the cause, and SHALL NOT work around the symptom.

The whole sequence is attempted at most twice. A second attempt is for a cause
the first one missed, not for a different way of turning the suite green, and
it SHALL report `cannot-patch` where the cause cannot be established rather
than try something speculative with the remaining attempt.

#### Scenario: Test Asserts the Behaviour the Remediation Changes

- GIVEN a regression in a test that asserts the pre-remediation behaviour
- WHEN patching evaluates it
- THEN it reports what the test asserts and why the remediation changes it
- AND the test is left as it is, for a reviewer to decide

#### Scenario: Cause of the Regression Cannot Be Established

- GIVEN a returned regression whose cause patching cannot identify
- WHEN the attempt completes
- THEN the terminal state is `cannot-patch` with the evidence recorded
- AND no speculative change is left in the working tree

#### Scenario: Behaviour Change Cannot Be Established

- GIVEN a remediation that requires the application to call the component
  differently
- AND a record that does not state what the correct usage is
- WHEN patching cannot establish it from the code either
- THEN the terminal state is `cannot-patch` with what is missing recorded
- AND no speculative change is committed to the working tree

### Requirement: The Build Stands After the Change

Patching is complete only when the project builds.

Compiling is the boundary between this capability and verification: patching
answers "is the change finished", verification answers "does the application
still behave". A change that does not compile is not finished, and handing it on
would make verification report a failure whose cause is upstream of it.

#### Scenario: Backport Requires No Source Change

- GIVEN a remediating version that is a rebuild of the same release
- WHEN the manifest is changed and the project is built
- THEN it compiles with no source modification

#### Scenario: Remediating Version Breaks Compilation

- GIVEN a remediating version whose API differs from the affected one
- WHEN the project no longer compiles after the change
- THEN patching adapts the affected call sites, or reports `cannot-patch` with
  the compilation failure recorded
- AND does not hand on a tree that does not build

### Requirement: Explicit Terminal State

Patching SHALL end in exactly one of two states, and the run's exit status SHALL
reflect it:

| State | Meaning | Outcome |
|---|---|---|
| `patched` | The change is applied and the project builds | Proceed to verification |
| `cannot-patch` | The change cannot be applied, or cannot be made to build within the remediation's scope | Failure, reported with its reason |

An unapplied patch SHALL NOT be reported as success, and a tree left in a
partially modified state SHALL be reported as `cannot-patch` rather than handed
on.

#### Scenario: Patch Cannot Be Applied

- GIVEN a remediation that cannot be expressed without changes beyond its scope
- WHEN patching completes
- THEN the terminal state is `cannot-patch` with the reason recorded
- AND the run exits non-zero

### Requirement: Output Consumable by Later Stages

Patching SHALL produce: the terminal state, the files it changed, every artifact
whose resolved version moved and from what to what, the strategy used, and any
source change it had to make with the reason. That output SHALL be available to
verification and pull request creation without re-deriving it.

The pull request has to explain the change to a reviewer. What moved and why is
established here, and reconstructing it afterwards from a diff loses the reason.

#### Scenario: Source Change Was Required

- GIVEN a remediation that forced a source modification
- WHEN patching completes
- THEN its output names the modified call sites and why the version required it
- AND that reason is available to pull request creation

## Non-Goals

Patching does not run the test suite, does not commit, does not push, and does
not open a pull request. It also does not regenerate the bill of materials: that
is produced from a build of the merged result, not from a working tree, and is
tracked in [ROADMAP](../../docs/ROADMAP.md) Phase 3.

## Design Decisions

- What is computed versus what is reasoned about:
  [ADR-0005](../../docs/adr/0005-determinism-boundary.md)
- What patching consumes:
  [vulnerability-analysis.spec.md](vulnerability-analysis.spec.md)
- Runtime, credentials and permissions:
  [agent-runtime.spec.md](../platform/agent-runtime.spec.md),
  [ADR-0003](../../docs/adr/0003-agent-runtime-packaging-and-credentials.md)
- Orchestration strategy: pending
  [orchestration-strategy.spec.md](orchestration-strategy.spec.md)
- Whether the remediated application rebuilds its SBOM in CI or in the cluster:
  open, tracked in [ROADMAP](../../docs/ROADMAP.md) Phase 3
