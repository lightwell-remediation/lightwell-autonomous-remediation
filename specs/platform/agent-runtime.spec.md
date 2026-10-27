# Agent Runtime Specification

## Purpose

Defines how the Milestone 1 agentic harness is packaged, configured, and
launched so that a remediation session is reproducible on a laptop, in a
container, and later in a Tekton task — without a human in the loop.

[`harness-selection.spec.md`](../agents/harness-selection.spec.md) defines
*which* harness and *what* it must be capable of. This spec defines *how it
runs*: credential wiring, model configuration, permission model, workspace
layout, and container execution constraints.

This spec deliberately does not decide how multiple agents are coordinated —
see Non-Goals.

## Requirements

### Requirement: Inference Routing

The runtime SHALL route inference to Red Hat MaaS by setting the harness base
URL to the MaaS gateway, using the Anthropic Messages API (`/v1/messages`).

The runtime SHALL fail before starting a session, with an actionable error
message, when a required configuration value is absent.

#### Scenario: Required Configuration Is Missing

- GIVEN the MaaS base URL or API key is not set
- WHEN the runtime is launched
- THEN it exits non-zero before contacting any model
- AND the error names the missing variable

### Requirement: Provider Isolation

The runtime SHALL unset conflicting inference-provider configuration inherited
from the environment (Vertex AI, Bedrock, direct Anthropic) before launching a
session.

This prevents a developer workstation configured for another provider from
silently bypassing MaaS.

#### Scenario: Workstation Configured For Another Provider

- GIVEN the shell exports Vertex AI configuration
- WHEN the runtime launches a session
- THEN the inherited provider configuration is not visible to the harness
- AND inference traffic reaches the MaaS host

### Requirement: Model Slot Mapping

The runtime SHALL configure every model slot the harness resolves internally —
not only the primary model — so that no slot points at a model absent from the
MaaS catalog.

When the catalog offers no small/fast model, every slot SHALL resolve to the
primary model.

#### Scenario: Catalog Has No Small Model

- GIVEN the MaaS catalog exposes only the primary model
- WHEN a session performs background work that uses the small-model slot
- THEN the request resolves to the primary model
- AND no request fails with an unknown-model error

### Requirement: Output Budget Within Gateway Limits

The gateway bounds how long a single request may run, so the runtime SHALL cap
the harness output budget rather than leave it at the harness default. The cap
SHALL be overridable, because the usable value is the pinned model's throughput
times the gateway window.

#### Scenario: Reply Would Exceed The Gateway Window

- GIVEN a model whose throughput cannot produce the harness default output
  budget within the gateway's request window
- WHEN a session runs
- THEN the runtime has capped the output budget so replies complete in-window
- AND the session does not fail with dropped connections and retry backoff

#### Scenario: A Reply Exceeds The Cap During The Demonstration

- GIVEN the demonstration session stops because one reply exceeded the output
  cap
- AND the checkout carries no change from that session
- WHEN the phase fails
- THEN the pipeline runs the demonstration once more on the same checkout
- AND any other demonstration failure, or a cap failure that left a change
  behind, is not retried

### Requirement: Model Portability

The runtime SHALL NOT hardcode a model family. Switching to a different model
served by MaaS SHALL require only a configuration change — no edit to the
runtime scripts and no container image rebuild.

#### Scenario: Switching Model Without Rebuilding

- GIVEN a container image built for the current model
- WHEN the configured model identifier is changed to another MaaS catalog entry
- THEN the same image runs a session against the new model
- AND no runtime script is modified

### Requirement: Credential Isolation

Credentials SHALL be supplied through environment variables or a mounted
secret, never committed to the repository.

The agent SHALL NOT be able to read credential files, and credential values
SHALL NOT appear in the task prompt or in the agent's context.

#### Scenario: Agent Attempts To Read The Secrets File

- GIVEN a session is running with the project permission configuration
- WHEN the agent attempts to read the secrets file
- THEN the read is denied
- AND the session continues without the credential in context

### Requirement: Repository Access

The runtime SHALL clone a remote application repository, create a branch,
commit changes, and open a pull request using a credential whose permissions
are limited to that single repository.

The credential SHALL NOT be embedded in the git remote URL.

#### Scenario: Agent Delivers A Pull Request

- GIVEN valid repository credentials and a cloned application repository
- WHEN the agent completes a change and is asked to deliver it
- THEN a branch is pushed and a pull request is opened
- AND the pull request is authored by the configured agent identity

### Requirement: Task Input Delivery

The runtime SHALL place a task's inputs in the workspace before the session
starts, retrieving them with credentials where the source requires
authentication, so that the agent receives files rather than endpoints.

This generalises what repository access already does, and for the same reason:
an agent that fetches its own inputs needs outbound network access and a
credential in its context, which is what the permission policy and
[ADR-0003](../../docs/adr/0003-agent-runtime-packaging-and-credentials.md) exist
to prevent. It is also what makes the credential prohibitions in the agent specs
enforceable rather than advisory.

Inputs SHALL be validated before the session is launched. A malformed or missing
input is a configuration error, not a session that spends turns discovering it.

#### Scenario: Input Behind Credentials Reaches The Agent As A File

- GIVEN a task input served by an endpoint requiring authentication
- WHEN the runtime prepares the workspace
- THEN the input is retrieved and written into the workspace
- AND the session reads it as a file
- AND the session makes no authenticated request of its own

#### Scenario: Malformed Input Is Rejected Before Launch

- GIVEN a required task input that is unreadable or not well-formed
- WHEN the runtime is invoked
- THEN it exits with a configuration error
- AND no session is started

### Requirement: Role-Scoped Permissions

Where a role has its own permission policy, the runtime SHALL apply that policy
rather than the default one.

A role that only reads SHALL NOT run under a policy permitting commits, pushes,
or pull requests. Permissions a capability does not need are ways for a run to
end successfully having done something nobody asked for.

#### Scenario: Read-Only Role Cannot Deliver Changes

- GIVEN a role whose contract is to analyse and report
- WHEN the runtime launches that role
- THEN the session runs under that role's policy
- AND any attempt to modify, commit, or push is denied
- AND the run is reported as a failure, per Honest Exit Status

### Requirement: Role Output Contract

Where a role is contracted to produce a document, the runtime SHALL verify that
the document exists and is well-formed, and SHALL exit non-zero when it does
not.

A session can complete without a denial, within its turn budget, and still leave
nothing a later stage can consume. Honest Exit Status rules out a run that was
blocked from acting; this rules out a run that acted and concluded nothing.

#### Scenario: Session Describes Its Work But Produces No Document

- GIVEN a role contracted to write a result document
- WHEN the session ends normally without writing it
- THEN the runtime exits non-zero
- AND the missing document is named to the caller

### Requirement: Non-Interactive Execution

The runtime SHALL start a session that never waits for a human: any action not
covered by the permission configuration SHALL be denied rather than queued for
approval.

The runtime SHALL write a machine-readable result document for every session.

#### Scenario: Session Runs Without A Terminal

- GIVEN the runtime is launched with no TTY attached
- WHEN the agent edits files and runs commands
- THEN no confirmation prompt blocks execution
- AND the session reaches a terminal state on its own

### Requirement: Honest Exit Status

The runtime SHALL treat a session that was blocked from acting as a failure,
even when the harness reports success.

A harness session can deny a tool call, let the agent narrate that it could not
proceed, and still terminate with a success status and a zero exit code. A
pipeline that trusts the exit code alone would report such a run as green.

The runtime SHALL therefore inspect the result document for recorded permission
denials and SHALL exit non-zero when any are present, unless denials are
explicitly tolerated for that invocation.

#### Scenario: Agent Is Blocked But The Harness Reports Success

- GIVEN a task that requires a command outside the permission allowlist
- WHEN the session denies that command and then terminates normally
- THEN the result document records the denial
- AND the runtime exits non-zero
- AND the denied tool and command are reported to the caller

#### Scenario: Session Exhausts Its Turn Budget

- GIVEN a task that cannot be completed within the configured turn limit
- WHEN the session reaches the limit
- THEN the result document records the limit as the reason for stopping
- AND the runtime exits non-zero

### Requirement: Declarative Permissions

The set of tools available to the agent SHALL be defined in a version-
controlled file so it can be reviewed in a pull request.

The runtime SHALL NOT bypass the permission system wholesale.

#### Scenario: Permission Change Is Reviewable

- GIVEN a change that grants the agent a new command
- WHEN the change is proposed
- THEN the new permission appears as a diff in the pull request

### Requirement: Telemetry Separation

The runtime SHALL disable harness-vendor-bound telemetry, auto-update, and
error reporting.

The runtime SHALL leave the OpenTelemetry export path configurable as an
opt-in, so agent metrics and traces can later be delivered to a collector
without re-enabling vendor-bound traffic.

#### Scenario: Metrics Export Without Vendor Telemetry

- GIVEN vendor-bound telemetry is disabled
- WHEN OpenTelemetry export is enabled and a collector endpoint is configured
- THEN session metrics reach the configured collector
- AND no telemetry is sent to the harness vendor

### Requirement: OpenShift-Compatible Execution

The container image SHALL run as a non-root user with an arbitrary UID and
group ID 0, as assigned by the OpenShift restricted security context.

The home directory and the harness configuration directory SHALL be writable
under that identity.

#### Scenario: Container Runs With An Unknown UID

- GIVEN the container is started with a UID that has no entry in `/etc/passwd`
  and a primary group of 0
- WHEN the runtime starts a session
- THEN the harness writes its configuration without a permission error
- AND the session completes normally

### Requirement: Workspace Contract

The runtime SHALL operate inside a workspace directory containing a checkout of
the application repository and an output directory.

Session artifacts SHALL be written to the output directory so that a subsequent
step can consume them without sharing process state.

#### Scenario: Artifacts Survive The Session

- GIVEN a completed session
- WHEN the runtime process has exited
- THEN the result document and session log are present in the output directory

## Non-Goals

This spec does not decide how multiple agents are coordinated — whether each
agent is a pipeline task or an orchestrator agent invokes the others. That
decision is tracked in
[`orchestration-strategy.spec.md`](../agents/orchestration-strategy.spec.md).

To keep both options open, the invocation contract SHALL accept the agent role
as a parameter, and SHALL pass state between phases through files in the output
directory rather than through harness session state.

#### Scenario: Role Is Supplied At Invocation

- GIVEN the runtime supports more than one agent role
- WHEN a role is supplied at invocation
- THEN the session runs that role without a change to the image

## Design Decisions

- Harness choice (Claude Code + MaaS): see [ADR-0002](../../docs/adr/0002-claude-code-maas-harness.md)
- Image base, credential model, and permission model: see [ADR-0003](../../docs/adr/0003-agent-runtime-packaging-and-credentials.md)
- Orchestration strategy: pending ADR (tracked in [ROADMAP](../../docs/ROADMAP.md) Phase 2)
- Telemetry destination and tracing backend: pending [`agent-tracing.spec.md`](../observability/agent-tracing.spec.md) (ROADMAP Phase 4.5)
