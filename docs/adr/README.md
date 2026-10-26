# Architecture Decision Records

This directory contains all Architecture Decision Records (ADRs) for the Lightwell Autonomous Remediation project.

## Index

| ADR | Title | Status | Layer | Date |
|-----|-------|--------|-------|------|
| [0001](0001-adopt-adr-process.md) | Adopt ADR Process | Accepted | Cross-cutting | 2026-09-24 |
| [0002](0002-claude-code-maas-harness.md) | Claude Code + Red Hat MaaS Harness | Accepted | Agent | 2026-10-01 |
| [0003](0003-agent-runtime-packaging-and-credentials.md) | Agent Runtime Packaging and Credential Model | Accepted | Platform | 2026-10-09 |
| [0004](0004-demo-repository-ground-truth-isolation.md) | Isolate the Demo Ground Truth from the Agent's Repository | Accepted | Platform | 2026-10-15 |
| [0005](0005-determinism-boundary.md) | Compute What Is Computable, Leave the Agent the Judgement | Accepted | Agents | 2026-10-15 |
| [0006](0006-cluster-bootstrap-topology.md) | Cluster Bootstrap Topology | Accepted | Platform | 2026-10-15 |
| [0007](0007-in-cluster-credential-delivery.md) | In-cluster Credential Delivery | Accepted | Platform | 2026-10-15 |
| [0008](0008-agent-runtime-image-delivery.md) | Agent Runtime Image Delivery | Accepted | Platform | 2026-10-15 |
| [0009](0009-tekton-pipeline-orchestration.md) | Orchestrate the Remediation Sequence as a Tekton Pipeline | Accepted | Agents | 2026-10-17 |

## Process

- Use the `adr` Cursor skill to create new ADRs
- All ADRs require Status, Date, Layer, Context, Options Considered, Decision, Consequences, and References
- English for all content
