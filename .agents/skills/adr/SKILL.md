---
name: adr
description: "Create a new Architecture Decision Record (ADR). Documents context, options considered, and rationale. Updates both indexes (docs/adr/README.md and docs/stack-decisions.md)."
---

# Create ADR

Create a new Architecture Decision Record in `docs/adr/`.

## Process

### 1. Determine Next ADR Number

Check `docs/adr/README.md` for the highest existing number. The next number is highest + 1, zero-padded to 4 digits.

### 2. Gather Decision Details

If the user provided a topic, use that as context. Otherwise ask:

> **What architectural decision do you need to document?**
> **What context or constraints led to this decision? What options did you consider?**

### 3. Write the ADR

Create `docs/adr/NNNN-<kebab-case-title>.md`:

```markdown
# ADR-NNNN: <Title>

## Status
<Proposed | Accepted | Deprecated | Superseded by ADR-XXXX>

## Date
YYYY-MM-DD

## Layer
<Infrastructure | Platform | Inference | Agent | Demo | Cross-cutting>

## Context
What problem or constraint motivated this decision?
Include demo constraints (20 min, demo.redhat.com/RHPDS) and links to official Red Hat/upstream docs.

## Options Considered

### Option 1: <Name>
- **Pros:** ...
- **Cons:** ...
- **GA / support status:** ... (cite Red Hat docs)

### Option 2: <Name>
- **Pros:** ...
- **Cons:** ...
- **GA / support status:** ...

## Decision
What we chose and the primary rationale (1–3 sentences).

## Consequences

### Positive
- ...

### Negative
- ...

## Version Pinning
| Component | Pinned version | Where enforced |
|---|---|---|
| ... | CSV `x.y.z` / chart `a.b.c` | `deploy/helm/...`, `Makefile`, etc. |

(Omit section if not applicable.)

## Demo Impact
How this decision affects the live demo narrative, attack scenarios, or health checks.

## Validation
What was tested on cluster/local and when. Link to install guides.

(Omit if decision is theoretical / not yet validated.)

## Related Decisions
- [ADR-XXXX: ...](./XXXX-slug.md)
- Supersedes: ADR-YYYY (if applicable)

## References
- [Red Hat / upstream doc title](URL)
```

**Required sections:** Status, Date, Layer, Context, Options Considered, Decision, Consequences, References.

**Optional sections:** Version Pinning, Demo Impact, Validation, Related Decisions.

Use `<!-- TODO: fill in -->` for incomplete sections.

All ADR content must be in **English**.

### 4. Update the Technical Index

Add a row to the table in `docs/adr/README.md`:

```markdown
| [NNNN](NNNN-slug.md) | Title | Status | Layer | Date |
```

### 5. Update the Executive Summary

Add a bullet to the appropriate layer section in `docs/stack-decisions.md`:

```markdown
- **Short title** — [ADR-NNNN](adr/NNNN-slug.md): One-sentence summary.
```

### 6. Cross-link (when applicable)

- `AGENTS.md` — if the decision affects project conventions, tech stack, or constraints.
- `docs/ROADMAP.md` — mark "Decide X" tasks as `[x]` with a link to the ADR.
- `docs/AGENT-SANDBOX-AND-OPENSHELL.md` or `docs/stack-decisions.md` — cite the ADR number when the topology is affected.

### 7. Confirm

```
Created: docs/adr/NNNN-<title>.md
Decision: <one-line summary>
Status: <status>
Layer: <layer>
Indexes updated: docs/adr/README.md, docs/stack-decisions.md
```
