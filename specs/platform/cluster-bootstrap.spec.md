# Cluster Bootstrap Specification

## Purpose

Defines the cluster a remediation run needs, and how that cluster is built and
proven. The target is a fresh OpenShift cluster turning into a cluster that can
host an agent run with one documented command, and a validation that fails when
it cannot.

[`agent-runtime.spec.md`](agent-runtime.spec.md) defines how a single agent runs.
This spec defines what has to exist around it: operators, namespaces, the
ServiceAccount, the credentials, the runtime image and the capacity for more
than one run at a time.

Demo clusters are short lived, so a manual bootstrap is a bootstrap that will be
wrong by the time it is needed. Everything here is declarative, re-runnable, and
parametrized per cluster.

## Requirements

### Requirement: Single Entry Point

The bootstrap SHALL be driven from one documented entry point that takes a fresh
cluster to a ready state without manual steps between phases.

Re-running it on an already bootstrapped cluster SHALL converge rather than fail,
so a partial or interrupted run can be repeated.

#### Scenario: Fresh Cluster

- GIVEN an OpenShift cluster with no platform components installed
- WHEN the bootstrap entry point is run with cluster admin credentials
- THEN the operators, namespaces, credentials and runtime image are created
- AND no step requires editing a tracked file

#### Scenario: Re-run After A Failure

- GIVEN a bootstrap that stopped halfway
- WHEN the same entry point is run again
- THEN the components already present are left in place
- AND the missing ones are created

### Requirement: Declarative Platform State

Platform state SHALL be reconciled from this repository by GitOps, so the
cluster can be rebuilt from git alone.

Only three things SHALL be applied imperatively, because GitOps cannot own them:
the GitOps operator itself, credentials, and one-shot run objects such as a
PipelineRun.

#### Scenario: Component Removed By Hand

- GIVEN a platform component deployed by GitOps
- WHEN someone deletes it from the cluster
- THEN the reconciler recreates it from the repository

#### Scenario: No Credential In Git

- GIVEN the bootstrap is complete
- WHEN the repository is searched for credential values
- THEN none are present, in any chart, values file or reconciler object

### Requirement: Operator Singletons Keep Their Owner

Resources that an operator creates and defaults on its own, such as the
DSCInitialization, the Tekton configuration and the GitOps instance, SHALL NOT be
owned by this repository.

Two owners of the same object fight forever, and the loser is usually the
cluster. Tuning those objects SHALL be an explicit and separate action.

#### Scenario: Operator Defaults A Field

- GIVEN an operator that defaults fields on a singleton it created
- WHEN the platform is reconciled
- THEN the reconciler does not revert those defaults

### Requirement: Preflight Before Install

The bootstrap SHALL check the cluster before changing it and SHALL fail with a
message naming what is missing.

The checks SHALL cover at least: cluster admin, a default StorageClass, an
available image registry, the ability to build images, and the operator channels
the install asks for.

#### Scenario: No Default StorageClass

- GIVEN a cluster with no default StorageClass
- WHEN the bootstrap is run
- THEN it stops before installing anything
- AND the message names the missing StorageClass

#### Scenario: Operator Channel Not In The Catalog

- GIVEN a configured operator channel that the cluster catalog does not offer
- WHEN the bootstrap is run
- THEN it stops and reports the channels the catalog does offer

### Requirement: Credential Delivery

Credentials SHALL be created in the cluster from the same file the local runtime
reads, using the same variable names, so a laptop run and an in-cluster run
resolve the same configuration.

Credential values SHALL NOT be committed, and SHALL NOT be passed through
reconciler objects where they would be readable by anyone with access to the
reconciler.

The agent namespace SHALL carry the inference credential and the repository
credential as separate Secrets, so a later pipeline can mount only what each
step needs.

#### Scenario: Secret Is Refreshed

- GIVEN a credential that has been rotated in the local file
- WHEN the credential step is run again
- THEN the in-cluster Secret holds the new value
- AND no other resource is changed

#### Scenario: Placeholder Not Replaced

- GIVEN a required variable still holding its template placeholder
- WHEN the credential step is run
- THEN it fails naming the variable
- AND no partial Secret is created

### Requirement: Agent Execution Capacity

The cluster SHALL be able to run at least two agent sessions at the same time,
each with its own writable workspace.

The namespace hosting agent runs SHALL define default and maximum container
resources, so a run that asks for nothing still gets a usable share and a single
run cannot take the node.

#### Scenario: Two Parallel Runs

- GIVEN a bootstrapped cluster
- WHEN two agent sessions are started at the same time
- THEN both are scheduled
- AND each writes to its own workspace without touching the other

#### Scenario: Run With No Resource Request

- GIVEN a run that declares no CPU or memory request
- WHEN it is scheduled
- THEN the namespace defaults apply

### Requirement: Runtime Image Availability

The runtime image SHALL be built in the cluster from pinned sources and SHALL be
pullable by the agent namespace without credentials for an external registry.

The upstream base image cannot be redistributed, so building it per environment
is the delivery mechanism, not a workaround.

#### Scenario: Image Is Built And Used

- GIVEN the bootstrap has completed
- WHEN a pod in the agent namespace references the runtime image
- THEN the image pulls without an external registry credential
- AND it carries the toolchain the agent permission allowlist grants

#### Scenario: Pinned Versions Are Honoured

- GIVEN a pinned upstream reference and harness version
- WHEN the image is built twice
- THEN both builds produce the same pinned harness version

### Requirement: Platform Features Are Enabled And Visible

The platform install SHALL enable a component unless there is a reason it cannot
work on the target cluster, and that reason SHALL be recorded next to the
component.

Where a product hides features behind its own configuration, the bootstrap SHALL
set that configuration too. An installed component whose console is hidden is
not an installed feature, and for a demo it is worth nothing.

A component that cannot work SHALL be off rather than enabled and broken, and
SHALL NOT be advertised in a console as if it worked.

Moving a component SHALL be a values change, not a chart change.

#### Scenario: Component Cannot Work On This Cluster

- GIVEN a component whose prerequisite is absent from the cluster catalog
- WHEN the platform is reconciled
- THEN the component is off
- AND the reason is recorded where the component is configured
- AND the console does not offer it

#### Scenario: Console Reflects What Is Installed

- GIVEN a component that is enabled and ready
- WHEN the product console is opened
- THEN the feature it provides is visible
- AND a feature whose component is off is not offered

#### Scenario: Enabling A Component Later

- GIVEN a component that is off
- WHEN it is turned on in a values file
- THEN no chart template is edited

### Requirement: Pre-installed Components Are Adopted

Every component SHALL be switchable, so the same repository works on a cluster
that already has the component installed by someone else.

#### Scenario: Cluster Already Has RHOAI

- GIVEN a cluster where RHOAI is installed and owned by other automation
- WHEN the bootstrap runs with that component switched off
- THEN it does not create or modify the existing install
- AND the rest of the bootstrap completes

### Requirement: Validation Proves The Cluster Is Ready

A validation entry point SHALL assert that operators installed, the platform
components are ready, the credentials exist, the runtime image exists, and that
two agent shaped workloads run to completion in parallel.

Validation SHALL NOT trust the reconciler's own report of success. A reconciler
can compare desired state against a dry run of its own apply, so an apply that
the API server rejects can leave every object reporting as in sync while nothing
reached the cluster. Validation SHALL check the result of the last apply, not
only the comparison.

It SHALL exit non-zero when any of those fail, and SHALL name the failure.

A validation that only proves the pipeline engine is alive is not enough: the
things that break later are the image, the scheduling, the storage and the
credentials.

#### Scenario: Validation On A Ready Cluster

- GIVEN a bootstrapped cluster
- WHEN the validation entry point is run
- THEN every check passes and it exits zero

#### Scenario: Missing Credential

- GIVEN a bootstrapped cluster whose inference Secret was deleted
- WHEN the validation entry point is run
- THEN it exits non-zero naming the missing Secret

#### Scenario: Apply Rejected But Everything Reports In Sync

- GIVEN a platform object whose apply is denied by an admission webhook
- AND the reconciler reports it as in sync because its dry run is denied the
  same way
- WHEN the validation entry point is run
- THEN it exits non-zero
- AND it reports the rejection message

### Requirement: Cluster Specific Values Are Parameters

Anything that changes between clusters, such as the ingress domain, operator
channels, the repository and revision to reconcile from, and the namespace for
agent runs, SHALL be a value with a default, not a literal in a template.

#### Scenario: Bootstrap On Another Cluster

- GIVEN a second cluster with a different ingress domain
- WHEN the bootstrap is run against it with its own values file
- THEN no tracked template is edited

## Non-Goals

- The remediation pipeline itself. This spec stops at a cluster that can run
  agent workloads, in parallel, with the image and credentials in place. The
  pipeline is `specs/devsecops/pipeline.spec.md` (ROADMAP Phase 3).
- Milestone 2 platform components (Agent Sandbox, OpenShell, EvalHub,
  NeMo Guardrails) and Developer Hub. Scaffolded off, decided later.
- Identity. The cluster brings its own authentication. Nothing in Milestone 1
  needs an identity provider of its own.

## Design Decisions

- Bootstrap topology, ownership and sync order: see [ADR-0006](../../docs/adr/0006-cluster-bootstrap-topology.md)
- In-cluster credential delivery: see [ADR-0007](../../docs/adr/0007-in-cluster-credential-delivery.md)
- Runtime image build and registry: see [ADR-0008](../../docs/adr/0008-agent-runtime-image-delivery.md)
- Image layering, permissions and the local credential contract: see [ADR-0003](../../docs/adr/0003-agent-runtime-packaging-and-credentials.md)
- Harness and inference routing: see [ADR-0002](../../docs/adr/0002-claude-code-maas-harness.md)
