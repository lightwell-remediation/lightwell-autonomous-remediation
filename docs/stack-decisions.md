# Stack Decisions — Executive Summary

One-line summaries of Accepted ADRs. Full rationale lives in [`docs/adr/`](adr/).

## Cross-cutting

- **ADR process** — [ADR-0001](adr/0001-adopt-adr-process.md): Architecture decisions are recorded as binding ADRs.

## Agent

- **Milestone 1 harness** — [ADR-0002](adr/0002-claude-code-maas-harness.md): Claude Code with inference via Red Hat MaaS (`claude-sonnet-4-6`, Anthropic `/v1/messages`).
- **Determinism boundary** — [ADR-0005](adr/0005-determinism-boundary.md): whatever a script can produce, a script produces before the session starts; the agent is left the judgement. Measured: moving the dependency tree and the bill of materials out of the session took a run from repeated failure to green in ~3 minutes, and reduced the agent's permissions to reading plus one output file.
- **Orchestration** — [ADR-0009](adr/0009-tekton-pipeline-orchestration.md): a Tekton Pipeline, one Task per phase, gated by `when` expressions on the previous phase's terminal state; the bounded retry is `retries: 1` on a combined patch-and-verify Task. Not a coordinating agent — the sequencing contains no judgement, and a model deciding what runs next could not be replayed against recorded documents in seconds. RHOAI AI Pipelines was examined and set aside: KFP v2 has no loop or recursion either, and it is the product for ML workflows.

## Platform

- **Agent runtime** — [ADR-0003](adr/0003-agent-runtime-packaging-and-credentials.md): built on the Red Hat `agentic-starter-kits` Claude Code image with our toolchain, MaaS routing and exit-status layer on top; runs non-root under an arbitrary UID, with a repository-scoped fine-grained GitHub PAT and version-controlled agent permissions.
- **Cluster bootstrap** — [ADR-0006](adr/0006-cluster-bootstrap-topology.md): GitOps app-of-apps with a Helm chart per component in `deploy/`, mirroring the workshop layout without its per-user fan-out; only the GitOps operator, the credentials and one-shot PipelineRuns stay imperative, and operator-created singletons keep their owner.
- **Credential delivery** — [ADR-0007](adr/0007-in-cluster-credential-delivery.md): Secrets applied from `secrets/secrets.env` with the same variable names as the local runtime, split per consumer, never in git nor in an ArgoCD Application spec.
- **Runtime image delivery** — [ADR-0008](adr/0008-agent-runtime-image-delivery.md): two chained BuildConfigs build the image in the cluster from pinned sources into the internal registry, so there is no external registry and no pull credential to own.
