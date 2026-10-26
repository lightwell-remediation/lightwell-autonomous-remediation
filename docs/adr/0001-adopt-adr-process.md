# ADR-0001: Adopt ADR Process

## Status
Accepted

## Date
2026-09-24

## Layer
Cross-cutting

## Context

The Lightwell Autonomous Remediation project involves multiple Red Hat products (RHOAI, Developer Hub, Agent Sandbox, NeMo Guardrails, MLflow, EvalHub), a multi-agent AI engine, and a team of 4 developers working in parallel. Architectural decisions affect the entire stack and must be documented, traceable, and binding to prevent conflicting implementations.


## Options Considered

### Option 1: Informal Documentation
- **Pros:** Low overhead, quick decisions
- **Cons:** Decisions are lost, rationale is forgotten, conflicts arise when developers make incompatible choices
- **GA / support status:** N/A

### Option 2: Architecture Decision Records (ADRs)
- **Pros:** Structured format, traceable decisions, binding commitments, familiar from agentops-example, searchable via `docs/adr/`
- **Cons:** Small overhead per decision (~15 min to write)
- **GA / support status:** Industry standard (Michael Nygard template, widely adopted)

## Decision

Adopt ADRs as the binding mechanism for all architectural decisions. Each ADR lives in `docs/adr/NNNN-<slug>.md` and follows the template from the `adr` Cursor skill.

The `adr-alignment` rule ensures agents consult existing ADRs before making changes.

## Consequences

### Positive
- All 4 developers share a single source of truth for stack decisions
- Rationale is preserved — new team members understand *why*, not just *what*
- Conflicts are caught early (agent rule blocks contradicting Accepted ADRs)

### Negative
- Small time investment per decision
- Must discipline the team to write ADRs before implementing, not after

## References

- [ADR format by Michael Nygard](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions)
- [agentops-example ADR process](https://github.com/davidseve/agentops-showcase/tree/main/docs/adr)
