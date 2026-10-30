# Agent Tracing Specification

## Purpose

What has to be true about the record a remediation's agent sessions leave
behind, and about the backends that record can be sent to.

[`pipeline.spec.md`](../devsecops/pipeline.spec.md) — A Run Is Legible
Without Reading Logs asks that a finished run still explain what it
established and what it cost after its workspace is gone. The phase documents
answer *what was established*. They do not answer *what the agent did to get
there*: which files it read, which commands it ran, where the turns went. A
model session is the least self-evident artefact in the system — the same
input has produced 41 turns and 108 — and this spec is about making each one
inspectable after the fact.

It is written backend-neutral on purpose. Which backend a cluster sends traces
to is a decision, recorded in an ADR, and the requirements below have to hold
whether that backend is MLflow today, OpenTelemetry tomorrow, or nothing.

## Requirements

### Requirement: Every Session Leaves a Trace

Every agent session the runtime starts SHALL leave a trace in the run's
workspace: the session's transcript, and a small metadata record naming the
role, the attempt, the harness, the model, the turns and cost the session reported, and the
terminal state of the phase it belongs to.

This SHALL happen whether or not any backend is enabled, and whether the
session succeeded, failed, or exhausted its budget. The failing session is the
one somebody will want to read.

Capture is the part that has to be right once. Every backend reads the same
trace, so adding one later never means changing what a session produces.

#### Scenario: A Successful Session

- GIVEN tracing with no backend enabled
- WHEN the analyze role completes
- THEN the workspace holds its transcript and its metadata record
- AND no network call was made to send them anywhere

#### Scenario: A Session That Ran Out of Turns

- GIVEN a patch session that exhausts its turn budget
- WHEN the phase fails
- THEN its trace is still in the workspace, with the failure in its metadata

#### Scenario: A Role Runs Twice

- GIVEN a patch phase retried after an output-cap refusal or a regression
- WHEN both attempts have run
- THEN there are two traces, one per attempt
- AND the second did not overwrite the first

### Requirement: Traces Are Harness-Neutral

Every trace SHALL name the harness (and its version) that produced it, and the
rest of the tracing contract SHALL hold for any harness the runtime can start,
not only the current one
([`harness-selection.spec.md`](../agents/harness-selection.spec.md)).

A transcript's format belongs to its harness; one harness's session log looks
nothing like another's. Supporting a new harness SHALL mean teaching export to
read its transcript format, and SHALL NOT require changing the backends, the
grouping, or the pipeline. A trace whose format export does not understand
SHALL be kept in the workspace, reported, and skipped — never guessed at.

#### Scenario: A Second Harness Joins

- GIVEN a run in which one role is driven by a harness other than Claude Code
- WHEN the run is exported
- THEN that role's traces appear in the same grouping, under the same naming
- AND they are tagged with the harness that produced them

#### Scenario: An Unknown Transcript Format

- GIVEN a trace from a harness export has no reader for
- WHEN the run is exported
- THEN the other traces are exported
- AND the unreadable one is named in the logs and left in the workspace

### Requirement: Capturing a Trace Never Decides a Run

Producing or exporting a trace SHALL NOT change any phase's outcome or the
run's outcome. A missing transcript, an unreachable backend or a rejected
credential SHALL be reported in the logs and otherwise ignored.

Tracing is how a run is understood, not part of what makes it correct. A
remediation that would have reached a pull request does not fail because an
observability service was down.

#### Scenario: The Backend Is Down

- GIVEN a backend is enabled and unreachable
- WHEN a run that would have delivered a pull request finishes
- THEN the pull request is delivered
- AND the run's outcome is what it would have been with tracing disabled
- AND the export failure is visible in the logs

### Requirement: Export Is Optional and Pluggable

Sending traces to a backend SHALL be opt-in per deployment, and SHALL be off by
default. With no backend enabled the system SHALL need no additional identity,
permission, network path or service.

Backends SHALL be selectable by configuration, one at a time. MLflow is the
first; an OpenTelemetry backend MAY be added later, and adding it SHALL NOT
require changing how sessions are captured or how the pipeline is sequenced.

#### Scenario: A Fresh Cluster Without MLflow

- GIVEN a deployment that enables no backend
- WHEN a run is started
- THEN it behaves as it did before tracing existed, apart from the traces left in the workspace
- AND nothing was created to hold backend credentials

#### Scenario: A Second Backend Arrives

- GIVEN a new backend is implemented
- WHEN a deployment selects it
- THEN the same captured traces are what it exports
- AND no role, prompt or phase had to change

### Requirement: Traces Are Grouped by Run and by Role

When a backend is enabled, every trace from one PipelineRun SHALL land in one
grouping named after that run, and within it, every trace from one role SHALL
belong to one session named after the run and the role.

The run is what someone arrives with ("what happened in `remediate-8ksnt`?"),
and the role is the next question ("why did patch take three attempts?"). A
retry is another trace inside its role's session, not a session of its own,
so a role's attempts read in order in one place.

Where one run produces more than one candidate for the same role — Milestone
2's two agents, each patching independently
([`orchestration-strategy.spec.md`](../agents/orchestration-strategy.spec.md)
— Producing a Candidate Is Separable From Delivering It) — each candidate
SHALL have its own session (`<run>-<role>-<candidate>`), so two agents'
attempts are never interleaved in one session. With a single candidate the
suffix is omitted.

Each trace SHALL also carry the run, application, role, attempt, candidate,
harness and model as searchable attributes, so runs can be compared across
groupings.

In MLflow terms the grouping is an **experiment** (`lightwell/<run>`) and the
session is an MLflow **session** (`<run>-<role>`). A backend without those
concepts SHALL map them onto its nearest equivalent and say how.

#### Scenario: A Full Run in MLflow

- GIVEN MLflow is the enabled backend
- WHEN run `remediate-8ksnt` finishes after analyze, exploit, patch, verify and deliver
- THEN experiment `lightwell/remediate-8ksnt` exists
- AND it holds sessions `remediate-8ksnt-analyze`, `-exploit`, `-patch`, `-verify` and `-deliver`
- AND each trace shows the session's model calls and tool calls with their token usage

#### Scenario: A Retried Patch in MLflow

- GIVEN the patch phase ran twice in that run
- WHEN its session is opened
- THEN it holds two traces, tagged attempt 1 and attempt 2

### Requirement: Failed and Cancelled Runs Are Traced

Export SHALL happen once the run's phases have stopped, whatever stopped them:
success, a failed gate, a refused precondition, or a timeout. A run that never
reached its last phase SHALL export the traces of the phases it did run.

A run that stopped early is the one most likely to be investigated.

#### Scenario: A Run Refused After Analysis

- GIVEN a run whose analysis concludes there is nothing to remediate
- WHEN the run ends
- THEN its grouping holds the analyze session only

### Requirement: No Session Holds Backend Credentials

No agent session SHALL be able to read the credential used to export traces,
and the identity the agent phases run as SHALL NOT gain any permission because
tracing is enabled.

The session runs commands chosen by a model against code it did not write.
Whatever it can read, a prompt injection in that code can read. Export is
done by something that is not a session, with an identity scoped to the
backend alone.

#### Scenario: Tracing Enabled

- GIVEN MLflow is the enabled backend
- WHEN an agent phase runs
- THEN its environment carries no backend credential or endpoint
- AND its service account's permissions are unchanged from a deployment without tracing

### Requirement: Replays Trace Nothing and Do Not Fail

A replayed run starts no session, so it SHALL produce no traces, and export
SHALL treat an empty set as success.

#### Scenario: A Replay With a Backend Enabled

- GIVEN MLflow is the enabled backend
- WHEN a replay scenario runs
- THEN export reports there was nothing to send
- AND the run's outcome is the replay's expected outcome

## Where Milestone 1 stands

As of 2026-10-30:

| Requirement | State |
|---|---|
| Traces Are Harness-Neutral | **No.** Only Claude Code exists, and nothing records which harness produced a log. |
| Every Session Leaves a Trace | **Partly.** `run-agent.sh` writes `out/session.jsonl`, but each role overwrites the previous one and the native transcript is never kept. |
| Capturing a Trace Never Decides a Run | Not applicable yet — nothing is exported. |
| Export Is Optional and Pluggable | **No.** No backend exists. |
| Traces Are Grouped by Run and by Role | **No.** |
| Failed and Cancelled Runs Are Traced | **No.** |
| No Session Holds Backend Credentials | Vacuously. |
| Replays Trace Nothing and Do Not Fail | Vacuously. |

## Backends

| Backend | Product | State |
|---|---|---|
| MLflow | **MLflow** on RHOAI (`MLflow` CR, `lightwell-agents` workspace) | Server deployed, not written to |
| OpenTelemetry | **Red Hat build of OpenTelemetry** → **Red Hat build of Tempo** (and/or MLflow's OTLP endpoint) | Future |

## Design Decisions

- Capture in the session's pod, export after the run with a separate identity, MLflow first, OpenTelemetry later: see [ADR-0010](../../docs/adr/0010-agent-tracing.md)
- Why the agent's identity holds no Role: see [ADR-0009](../../docs/adr/0009-tekton-pipeline-orchestration.md)
- Why the session runs isolated (`claude --bare`: no CLAUDE.md, hooks, plugins or MCP from the cloned repository), which rules out the starter kit's hook-based tracing: today only a comment in `agent-runtime/run-agent.sh`; [ADR-0010](../../docs/adr/0010-agent-tracing.md) records the consequence for tracing
