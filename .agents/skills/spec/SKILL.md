---
name: spec
description: >
  Create or modify a behavior spec following the project's spec-driven development
  convention. Use when the user wants to write a new spec, add requirements or
  scenarios to an existing spec, define desired system behavior, or says "spec",
  "write a spec", "create a spec", "define the behavior", "new spec for",
  "update the spec", "que debe hacer", "contrato de comportamiento".
---

# Write or Modify a Spec

Help the user create or change a spec that describes desired system behavior.

## User Input

```text
$ARGUMENTS
```

## What is a Spec (vs an ADR)

| Artifact | Purpose | Lives in | Evolves? |
|----------|---------|----------|----------|
| **Spec** | Desired system behavior as a living contract | `specs/` | Yes -- amended, replaced, or deleted as the system changes |
| **ADR** | Point-in-time decision and its rationale | `docs/adr/` | No -- superseded by a new ADR, never edited |

A spec says *"the system SHALL..."*. An ADR says *"we chose X because..."*.
They reference each other: specs link to ADRs for decision rationale, ADRs link to
specs for the behavior they enable. **Never duplicate content between them.**

## Steps

### Phase 1 -- Frame

1. Ask what the system **should do**, not what is broken.
2. Identify scope: which domain (`platform`, `agents`, `standards`) and which components.
3. Check for existing specs in `specs/` that overlap. Read them to avoid duplication.
4. Check for existing ADRs in `docs/adr/` that constrain this behavior.

### Phase 2 -- Ground in the Codebase

Read actual code and existing specs in the affected areas:

1. Read existing specs in the target domain (`specs/<domain>/`)
2. Grep the components identified in Phase 1 (if code exists yet)
3. Summarize back in 3-5 sentences
4. Ask only where the codebase does not give a clear answer

For this project in early phases, much code may not exist yet. That is fine --
specs define desired state *before* code. Note what is implemented vs planned.

### Phase 3 -- Draft the Spec

Follow this format exactly:

```markdown
# <Domain or Feature> Specification

## Purpose

One paragraph describing what this spec covers and why it exists.

## Requirements

### Requirement: <Descriptive Name>

The system SHALL <observable behavior>.

Use RFC 2119 keywords:
- **SHALL / MUST** -- absolute requirement
- **SHALL NOT / MUST NOT** -- absolute prohibition
- **SHOULD** -- recommended, can be deviated with justification
- **MAY** -- truly optional

#### Scenario: <Descriptive Name>

- GIVEN <precondition>
- WHEN <action>
- THEN <expected outcome>
- AND <additional outcome>

## Design Decisions

Links to ADRs that constrain this spec. Format:
- <Decision topic>: see [ADR-NNNN](../../docs/adr/NNNN-slug.md)
- <Pending decision>: pending ADR (tracked in ROADMAP)
```

### Phase 4 -- Critic Pass

Before writing the file, check for:

- Ambiguity: can two developers interpret a requirement differently?
- Testability: can each scenario be verified (manually or automated)?
- Consistency with existing specs and Accepted ADRs
- Missing error/failure scenarios (what happens when things break?)
- Security implications (reference `standards/security.spec.md` if relevant)

### Phase 5 -- Write and Register

1. Write the file to `specs/<domain>/<name>.spec.md`
2. Update `specs/index.spec.md` -- add a row to the Spec Registry table
3. If the spec references a pending ADR, confirm the ADR is tracked in `docs/ROADMAP.md`

## Spec Domains

| Domain | Directory | Covers |
|--------|-----------|--------|
| `platform` | `specs/platform/` | Infrastructure, deployment, sandbox isolation, NeMo Guardrails, inference routing (MaaS), RHDP replicability |
| `agents` | `specs/agents/` | Multi-agent engine, consensus protocol, reader/judge roles |
| `devsecops` | `specs/devsecops/` | Tekton pipeline stages, Lightwell trigger, Developer Hub, PR creation |
| `observability` | `specs/observability/` | MLflow tracing, agent execution traces, pipeline run logging |
| `evaluation` | `specs/evaluation/` | EvalHub metrics, patch quality criteria, confidence thresholds, test gates |
| `standards` | `specs/standards/` | Security, testing, conventions -- cross-cutting constraints |

## Principles

1. **Desired state, not issue tracking.** Specs describe what the system does, not what is broken.
2. **Living documents.** Amended, replaced, or deleted -- never archived.
3. **Behavior contracts, not implementation plans.** Say WHAT, not HOW (implementation goes in code).
4. **Named descriptively.** `<topic>.spec.md` -- not numbered.
5. **Scenarios are testable.** Each Given/When/Then can become an automated test.
6. **Open questions are explicit.** If behavior is not yet decided, say so and link to the pending ADR.

## Constraints

- Never duplicate ADR content -- link to it
- Every spec MUST have at least one Scenario
- Every spec MUST be registered in `specs/index.spec.md`
- Use English for all spec content
- Keep specs proportional to project complexity -- do not over-specify early
