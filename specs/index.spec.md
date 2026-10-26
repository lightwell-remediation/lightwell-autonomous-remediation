# Specs

Desired state of the system. Code is the actual state. Development work reconciles the two.

Specs define **observable behavior** using RFC 2119 keywords (SHALL, MUST, SHOULD, MAY).
ADRs in `docs/adr/` record **decisions** (why X over Y). They reference each other
but never duplicate content. See the `spec` skill for the full convention.

## Domains

### [Platform](platform/)

Infrastructure, deployment, sandbox isolation, NeMo Guardrails, inference routing (MaaS), and RHDP replicability.

### [Agents](agents/)

Multi-agent engine behavior, consensus protocol, reader/judge roles.

### [DevSecOps](devsecops/)

Tekton pipeline stages, Lightwell trigger, Developer Hub integration, PR creation.

### [Observability](observability/)

MLflow tracing, agent execution traces, pipeline run logging.

### [Evaluation](evaluation/)

EvalHub metrics, patch quality criteria, confidence thresholds, test pass gates.

### [Standards](standards/)

Cross-cutting engineering constraints: security, testing, conventions.

## Spec Registry

| Path | Domain | Primary Entities | Components | Depends On |
|------|--------|-----------------|------------|------------|
| [`vulnerable-app.spec.md`](standards/vulnerable-app.spec.md) | standards | Vulnerable App, CVE, Exploit, Test Suite | sample-app, pipeline | harness-selection, orchestration-strategy |
| [`harness-selection.spec.md`](agents/harness-selection.spec.md) | agents | Harness, MaaS, Claude Code | remediation agents | ADR-0002 |
| [`agent-runtime.spec.md`](platform/agent-runtime.spec.md) | platform | Runtime, Container Image, Credentials, Workspace | agent-runtime, pipeline | harness-selection, ADR-0002, ADR-0003 |
| [`vulnerability-analysis.spec.md`](agents/vulnerability-analysis.spec.md) | agents | CVE, Component, Reachability Verdict, Remediating Version | remediation agents | harness-selection, agent-runtime, orchestration-strategy |
| [`code-patching.spec.md`](agents/code-patching.spec.md) | agents | Patch Strategy, Governed Artifacts, Manifest Change | remediation agents | vulnerability-analysis, agent-runtime, ADR-0005 |
| [`fix-verification.spec.md`](agents/fix-verification.spec.md) | agents | Baseline, Regression, Resolved Version, Evidence | remediation agents | code-patching, exploit-test-generation, ADR-0005 |
| [`orchestration-strategy.spec.md`](agents/orchestration-strategy.spec.md) | agents | Sequence, Preconditions, Retry, Workspace | pipeline, remediation agents | every agent spec, agent-runtime, ADR-0005 |
| [`exploit-test-generation.spec.md`](agents/exploit-test-generation.spec.md) | agents | Exploit Test, Demonstration, Reachability | remediation agents | vulnerability-analysis, fix-verification, ADR-0005 |
| [`pr-creation.spec.md`](agents/pr-creation.spec.md) | agents | Pull Request, Narrative, Delivery | remediation agents | fix-verification, agent-runtime, ADR-0003 |
| [`pipeline.spec.md`](devsecops/pipeline.spec.md) | devsecops | Trigger, Alert, CI, Bill of Materials, Run Visibility | pipeline, deploy | orchestration-strategy, pr-creation, ADR-0009 |
| [`cluster-bootstrap.spec.md`](platform/cluster-bootstrap.spec.md) | platform | Cluster, Operators, Namespace, Secrets, Runtime Image | deploy/ | agent-runtime, ADR-0006, ADR-0007, ADR-0008 |
