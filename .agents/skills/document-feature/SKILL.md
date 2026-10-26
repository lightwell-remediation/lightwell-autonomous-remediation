---
name: document-feature
description: >-
  Document new or modified project functionality: guides, scripts, skills,
  ROADMAP, AGENTS.md, and README cross-links. Use when adding, modifying, or
  validating a component (e.g. OpenShell, MLflow, NeMo), integration, deploy
  path, version pin, installer script, Helm chart, or agent skill — or when
  the user asks to document a feature. Mandatory when the
  technology-usage-docs rule applies.
---

# Document Feature

After implementing, modifying, or validating functionality, **update project documentation in the same session**. Do not wait for the user to ask unless they explicitly said not to document.

> **Note**: When the `technology-usage-docs` rule fires (any stack technology added or modified), running this skill is **mandatory**, not optional.

## When to run

| Trigger | Example |
|---|---|
| New platform component validated on cluster | OpenShell Helm chart on OpenShift |
| Existing component version or config changed | Chart version bump, new Helm values, operator CSV update |
| Prerequisites or deploy path modified | New Makefile target, values file restructure, new dependency |
| Verify or troubleshoot steps updated | New health check, validated error workaround |
| New script or installer added | `scripts/install-openshell.sh` |
| New agent skill added | `openshell-local-install`, `openshell-cluster-install`, etc. |
| Deploy manifests or Helm values added | `deploy/helm/openshell/` |
| Architecture or integration decision made | TrustyAI, MaaS wiring |

## Workflow

Copy this checklist and complete every applicable item:

```
Documentation progress:
- [ ] 0. Check Accepted ADRs in docs/stack-decisions.md — ensure the feature aligns (see adr-alignment rule)
- [ ] 1. Identify feature type and target doc location
- [ ] 2. Write or extend the primary guide in docs/
- [ ] 3. Cross-link README.md, AGENTS.md, ROADMAP.md
- [ ] 4. Update existing skills or add new ones for repeatable workflows
- [ ] 5. Cite upstream official docs (verify, do not guess)
- [ ] 6. Record validated versions and constraints
- [ ] 7. Update ADR Validation section (or create ADR via adr skill if architectural)
```

### Step 1 — Choose where to document

| Feature kind | Primary location | Also update |
|---|---|---|
| Install / deploy procedure | `docs/<component>-installation.md` or `docs/<component>/` | `scripts/`, `deploy/` |
| Agent Sandbox + OpenShell architecture / launch flow | `docs/AGENT-SANDBOX-AND-OPENSHELL.md` (use `sync-agent-sandbox-doc` skill) | `openshell-installation.md`, relevant ADRs |
| Architecture decision | `docs/adr/NNNN-slug.md` (use `adr` skill) | `docs/adr/README.md`, `docs/stack-decisions.md`; topology in `AGENT-SANDBOX-AND-OPENSHELL.md` |
| Repo layout / index docs | `sync-repo-docs` skill | `README.md`, `AGENTS.md` § Project Structure, `docs/ROADMAP.md` links |
| Demo narrative step | `docs/demo-script.md` | — |
| Agent-operable workflow | `.agents/skills/<name>/SKILL.md` | `AGENTS.md` § Agent Skills |
| Version manifest | `docs/` or `deploy/` values | `AGENTS.md` § Version Pinning |

Use [reference.md](reference.md) for templates and the OpenShell example.

### Step 2 — Primary guide content

Every component guide must include:

1. **Overview** — role in the AgentOps stack (link to `AGENTS.md` architecture)
2. **Prerequisites** — cluster, tools, upstream dependencies
3. **Install / deploy** — copy-paste commands that were **validated**
4. **Verify** — health checks, expected output
5. **Troubleshooting** — real errors encountered (symptom → cause → fix)
6. **References** — upstream docs URLs (Red Hat / NVIDIA first per project rules)

**Language**: all committed `.md` files in English.

**Version pinning**: record exact chart, operator CSV, or image tags tested.

### Step 3 — Cross-links (required)

| File | What to add |
|---|---|
| `README.md` | One line under Documentation |
| `AGENTS.md` | Agent Skills table (if skill); References (if platform component); Project Structure if new paths |
| `docs/ROADMAP.md` | Mark completed validation tasks `[x]` with link to the guide |

Keep `AGENTS.md` and `README.md` **short** — link to `docs/`, do not duplicate procedures.

### Step 4 — Skills (create or update)

**Update existing skills** that describe the changed workflow. Search `.agents/skills/` for skills whose commands, versions, chart values, or Makefile targets changed in this session. Update them to match the new process.

**Create a new skill** when the workflow is:

- Repeated by users or agents (install, cleanup, bootstrap, health-check)
- Multi-step with project-specific conventions

Skill location: `.agents/skills/<name>/SKILL.md`

Register in `AGENTS.md` § Agent Skills.

### Step 5 — Official sources

Per `.cursor/rules/documentation-sources.mdc`:

1. Verify against Red Hat or upstream docs (`WebFetch`, KB)
2. Cite the source in the guide References section
3. Document **deltas** for OpenShift/RHOAI only — do not copy entire upstream manuals

### Step 6 — Constraints from AGENTS.md

- No secrets in repo
- GitOps: manifests in `deploy/`, not manual cluster-only steps without documenting them
- Idempotent: document uninstall/teardown when install is documented

## Do not

- Create standalone docs the user did not need (no drive-by markdown)
- Leave ROADMAP tasks unchecked after validation
- Document from training data without verifying versions and CRD fields
- Put long install procedures only in chat — they belong in `docs/`
- Leave existing skills referencing deprecated commands, removed scripts, or old versions

## Example: OpenShell (reference implementation)

| Artifact | Path |
|---|---|
| Primary guide (local + OpenShift Helm) | `docs/openshell-installation.md` |
| Local installer | `scripts/install-openshell.sh` |
| Agent skills | `.agents/skills/openshell-local-*`, `openshell-cluster-*` |
| ROADMAP | Phase 1 cluster validation marked done |
| Upstream | [Helm README](https://github.com/NVIDIA/OpenShell/blob/main/deploy/helm/openshell/README.md), [OpenShift guide](https://docs.nvidia.com/openshell/latest/kubernetes/openshift) |

Full mapping: [reference.md](reference.md)

## Additional resources

- Templates and file map: [reference.md](reference.md)
- ADR-style decisions: use the `adr` skill — creates `docs/adr/NNNN-slug.md` and updates both indexes (`docs/adr/README.md` + `docs/stack-decisions.md`)
- OpenShift operations during validation: `openshift-mcp` skill
