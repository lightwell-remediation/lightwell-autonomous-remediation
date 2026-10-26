# Agentic Harness Selection Specification

## Purpose

Criteria a harness and model pairing MUST meet to drive remediation through Red
Hat MaaS. Written against measurements, not assumptions: every requirement here
corresponds to a candidate that looked viable on the catalog page and was not.

The Milestone 1 choice is [ADR-0002](../../docs/adr/0002-claude-code-maas-harness.md).
Apply this spec again before adding a second harness or model in Milestone 2 —
the dual-agent engine needs a second pairing, and availability is not the test.

How the chosen harness must then behave is
[`agent-runtime.spec.md`](../platform/agent-runtime.spec.md); this spec stops at
the choice.

## Requirements

### Requirement: Gateway-Compatible Inference API

The harness SHALL reach the model through the gateway's own API surface, with no
adapter in the path, and SHALL NOT depend on a direct frontier-provider session.
Credentials SHALL come from the environment, never from source.

#### Scenario: Candidate Reaches The Gateway

- GIVEN the gateway base URL and a key
- WHEN the harness runs a session
- THEN the requests arrive at the configured endpoint, verified by observing
  them at the gateway rather than by trusting the harness's own report

### Requirement: Tool Calling Survives The Gateway

The model SHALL return well-formed tool calls through the gateway. A coding
agent is mostly tool use, so a pairing that chats but cannot call tools is
unusable regardless of its other properties.

#### Scenario: Tool Call Round-Trips

- GIVEN a request declaring one tool
- WHEN it is sent to the gateway for the candidate model
- THEN the response has `stop_reason: tool_use` with the tool name and
  arguments intact

### Requirement: Output Fits The Gateway Request Window

A gateway bounds how long one request may run, which bounds output per reply to
`throughput × window`. The candidate SHALL be able to emit the largest single
artifact the agent produces — a test file, a patch — inside that bound.

Throughput, not price, decides this. A cheaper model that cannot finish a reply
in the window costs more, because it fails after consuming the whole window.

#### Scenario: Candidate Sustains A Realistic Reply

- GIVEN the largest single artifact the task requires
- WHEN the candidate is asked for an output of that size in one request
- THEN the gateway returns it rather than dropping the connection
- AND the measured throughput leaves margin inside the window

### Requirement: Context Window Verified, Not Read

The model SHALL hold the harness system prompt plus the files under remediation.
This SHALL be measured, because the harness reports the context window it
assumes for an unrecognised model rather than the one the backend serves, and a
session sized to the wrong number fails at the gateway instead of compacting.

#### Scenario: Reported Window Disagrees With The Catalog

- GIVEN a model the harness does not recognise
- WHEN a session reports the context window it believes it has
- THEN that figure is checked against the catalog before it is relied on

### Requirement: Every Model Slot Resolves

Harnesses that reason in model tiers resolve more than the configured model —
background work may use a small/fast slot. Every slot the harness can resolve
SHALL map to a model the catalog serves.

#### Scenario: Catalog Has No Small Model

- GIVEN a catalog with no small/fast entry
- WHEN a session performs background work
- THEN no request fails with an unknown-model error

### Requirement: Code Remediation Capabilities

The harness SHALL read and edit a local repository, run build and test commands,
and produce a diff suitable for a pull request.

#### Scenario: Edit And Verify Cycle

- GIVEN a cloned application repository
- WHEN the harness is tasked with remediating a documented CVE
- THEN it modifies source and dependency manifests
- AND it invokes the project's test command and observes pass or fail

### Requirement: Non-Interactive Execution With A Trustworthy Completion Signal

The harness SHALL start without interactive prompts, and SHALL expose enough
detail to tell a completed session from a blocked one. A process exit code is
not sufficient on its own.

#### Scenario: Blocked Session Is Distinguishable

- GIVEN a session in which the agent's actions were refused by policy
- WHEN it ends
- THEN the result carries enough information to classify it as a failure,
  whatever the process exit code was

## Design Decisions

- Harness and model choice: [ADR-0002](../../docs/adr/0002-claude-code-maas-harness.md)
- Packaging and credentials: [ADR-0003](../../docs/adr/0003-agent-runtime-packaging-and-credentials.md)
- Measured gateway limits: [agent-runtime.md](../../docs/agent-runtime.md) — Known limitations
- Orchestration strategy: pending [orchestration-strategy.spec.md](orchestration-strategy.spec.md)
