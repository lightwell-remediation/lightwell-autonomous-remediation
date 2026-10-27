# AGENTS.md — Lightwell Autonomous Remediation

> Single source of truth for AI-assisted development on this project.
> Any AI coding agent (Claude Code, Codex, Cursor, etc.) working on this repo should read this file first.

## Project Overview

**Name**: Lightwell Autonomous Remediation — Multi-Agent AI on Red Hat AI & Red Hat Advanced Developer Suite
**Target Platform**: Red Hat OpenShift AI (RHOAI) 3.x
**Language**: English
**Demo**: DemoJam | Red Hat One 2027 (20 min)

This project demonstrates an end-to-end autonomous DevSecOps solution: Lightwell vulnerability alerts trigger a multi-agent engine that analyzes, patches, tests, and submits production-ready PRs — all within enterprise guardrails on Red Hat AI.

**Proposal**: [DemoJam PDF](docs/DemoJam%20_%20Red%20Hat%20One%202027.pdf)

## Architecture

The project has two milestones with different architecture scopes.

### Milestone 1: Submission (Oct 30, 2026)

Single remediation agent + Tekton pipeline. Hardcoding and prototyping OK.
No LLM-as-a-Judge, no webhook trigger and no CI on the generated branch — all
three were cut on 2026-10-20 and live in Milestone 2
([ROADMAP](docs/ROADMAP.md) — Out of scope for Milestone 1).

```
┌─────────────────────────────────────────────────────────────────────┐
│  TRIGGER                                                             │
│  PipelineRun with the vulnerability record (ConfigMap)               │
├─────────────────────────────────────────────────────────────────────┤
│  REMEDIATION PIPELINE (Tekton)                                       │
│  analyze → baseline → demonstrate → patch-and-verify → sbom →       │
│  deliver → outcome                                                   │
├─────────────────────────────────────────────────────────────────────┤
│  SINGLE REMEDIATION AGENT                                            │
│  analyze → generate-exploit-test → patch → verify-fix → create-PR   │
├─────────────────────────────────────────────────────────────────────┤
│  INVENTORY VALIDATION                                                │
│  Regenerated SBOM → Trusted Profile Analyzer                         │
├─────────────────────────────────────────────────────────────────────┤
│  INFERENCE LAYER                                                     │
│  MaaS (model serving)                                                │
├─────────────────────────────────────────────────────────────────────┤
│  INFRASTRUCTURE                                                      │
│  OpenShift (RHDP for replicability)                                  │
└─────────────────────────────────────────────────────────────────────┘
```

### Milestone 2: Post-selection (RH One 2027)

Full production architecture with dual-agent, LLM-as-a-Judge, enterprise guardrails,
and Developer Hub integration.

```
┌─────────────────────────────────────────────────────────────────────┐
│  LIGHTWELL TRIGGER                                                   │
│  Vulnerability alert → Webhook → Developer Hub workflow              │
├─────────────────────────────────────────────────────────────────────┤
│  RED HAT DEVELOPER HUB                                               │
│  Catalog entry → Pipeline trigger → Status tracking                  │
├─────────────────────────────────────────────────────────────────────┤
│  DEVSECOPS PIPELINE (Tekton)                                         │
│  scan → remediation-agents → test → evaluate → create-PR             │
├─────────────────────────────────────────────────────────────────────┤
│  DUAL-AGENT ENGINE + LLM-AS-A-JUDGE                                  │
│  Agent-A (harness/model X) + Agent-B (harness/model Y) → Judge       │
│  Judge selects best PR, combines both, or rejects                    │
├─────────────────────────────────────────────────────────────────────┤
│  PLATFORM LAYER                                                      │
│  MLflow (tracing + metrics) │ EvalHub │ NeMo Guardrails              │
├─────────────────────────────────────────────────────────────────────┤
│  SANDBOX (Agent Sandbox / OpenShell)                                 │
│  Agent execution isolation, zero-trust sandboxing                    │
├─────────────────────────────────────────────────────────────────────┤
│  INFERENCE LAYER                                                     │
│  MaaS (model serving) via multiple providers                         │
├─────────────────────────────────────────────────────────────────────┤
│  INFRASTRUCTURE                                                      │
│  OpenShift + RHOAI 3.x (RHDP for replicability)                     │
└─────────────────────────────────────────────────────────────────────┘
```

## Tech Stack

### Milestone 1 (Submission)

| Component | Product/Technology | Purpose |
|---|---|---|
| Infrastructure | OpenShift (RHDP) | Container platform |
| Cluster bootstrap | OpenShift GitOps (ArgoCD) + Helm ([ADR-0006](docs/adr/0006-cluster-bootstrap-topology.md)) | Reproducible platform install in `deploy/` |
| Model Serving | External MaaS | LLM inference |
| Remediation Agent | Claude Code + Red Hat MaaS ([ADR-0002](docs/adr/0002-claude-code-maas-harness.md)) | Vulnerability analysis, patching, PR creation |
| Pipeline | Tekton (OpenShift Pipelines) ([ADR-0009](docs/adr/0009-tekton-pipeline-orchestration.md)) | One Task per phase, from the vulnerability record to the pull request |
| Inventory | Syft (in the pipeline) + Red Hat Trusted Profile Analyzer | Regenerate the SBOM from the remediated build and validate it before merge |
| Vulnerability Detection | Lightwell | Vulnerability scanning and the remediated artifacts |

### Milestone 2 (Post-selection — additions)

| Component | Product/Technology | Purpose |
|---|---|---|
| AI Platform | RHOAI 3.x | ML/AI platform on OpenShift |
| Dual-Agent Engine | Agent A + Agent B (different harnesses/models) | Divergent vulnerability patching |
| LLM-as-a-Judge | Separate model evaluating both PRs | Select best, combine, or reject |
| Guardrails | NeMo Guardrails via TrustyAI | Prompt safety and policy enforcement |
| Sandbox | Agent Sandbox + OpenShell | Agent execution isolation, zero-trust sandboxing |
| Observability | MLflow (tracing + evaluation metrics) | Full agent execution tracing |
| Evaluation | EvalHub | Automated evaluation of patch quality |
| Developer Portal | Red Hat Developer Hub | Workflow catalog, status tracking |

## Team

| Member | Role |
|--------|------|
| Roman | Developer |
| Roberto | Developer |
| Carlos | Developer |
| David | Developer |

## Git Workflow

- **Single permanent branch:** `main` (1 approval for merge)
- **Feature branches:** `feat/<owner>/<short-description>`
- **Conventional Commits:** `feat:`, `fix:`, `docs:`, `chore:`, `test:`
- No `develop`, `release/*`, `hotfix/*` branches for now
- No CODEOWNERS — all members can review any PR

## Agent Skills

Project-level skills live in `.agents/skills/` (read natively by Codex and Cursor; `.claude/skills` is a symlink for Claude Code). Use them when the task matches their description:

| Skill | When to use |
|---|---|
| `cluster-bootstrap` | Deploy the platform on OpenShift (`deploy/`) |
| `secrets-setup` | Create/validate `secrets/secrets.env` before deploy |
| `openshift-mcp` | Any OpenShift/Kubernetes cluster operation — prefer MCP over `oc`/`kubectl` |
| `no-secrets` | Scan for credentials before commit or PR |
| `adr` | Create or update an Architecture Decision Record |
| `create-pr` | Create pull requests with Summary/Details/Test plan |
| `document-feature` | After adding or validating a component — document in `docs/` |
| `sync-repo-docs` | Audit/sync README, AGENTS.md, ROADMAP with actual repo layout |
| `helm-create` | Create or modify Helm charts following OCP best practices |
| `spec` | Create or modify behavior specs (`specs/`) -- desired system state as living contracts |
| `runtime-image-version` | Bump the agent runtime image version after changing `agent-runtime/` or an image pin |

## Project Structure

```
lightwell-autonomous-remediation/
├── .github/
│   ├── pull_request_template.md
│   └── workflows/
├── .cursor/
│   └── rules/               # (always-on rules now live in AGENTS.md)
├── .agents/
│   └── skills/              # Project-level agent skills (all agents)
├── AGENTS.md                # This file
├── README.md                # Project overview
├── agent-runtime/           # Harness launcher, permission policy, Containerfile
│   ├── Containerfile        # Layered on the Red Hat starter-kit image
│   ├── build-image.sh       # Builds both images at pinned versions
│   ├── run-agent.sh         # Same entrypoint locally and in-cluster
│   ├── claude/              # Permission policy per role
│   ├── prompts/             # Role prompts, free of any application specifics
│   ├── lib/                 # Exit-status gates (session freedom, output contract)
│   └── test/                # Gate tests that need no inference
├── assets/                  # Diagrams
├── deploy/                  # Cluster bootstrap (GitOps app-of-apps + Makefile)
│   ├── Makefile             # make preflight / deploy-all / build-image / validate
│   ├── bootstrap/           # Pre-GitOps: operator Subscription, ArgoCD patches
│   ├── gitops/              # bootstrap-infra parent + deployments/{platform,agents}
│   │                        # platform: RHOAI operator, DSC, dashboard flags,
│   │                        # hardware profile, Pipelines, MLflow, Developer Hub
│   ├── scripts/             # preflight, install-gitops, secrets, build-image, validate
│   └── values/              # cluster-plain, cluster-rhoai-existing, local.example
├── secrets/                 # secrets.template.env (real values gitignored)
├── docs/
│   ├── ROADMAP.md           # Phased task list (two milestones)
│   ├── agent-runtime.md     # How to configure and run the harness
│   ├── replicate.md         # End-to-end replication guide (RH1 submission)
│   ├── target-app.md        # Lightwell-free public target application
│   ├── stack-decisions.md   # One-line summary of Accepted ADRs
│   ├── upstream-gaps.md     # What we carry on top of the Red Hat starter kit
│   ├── submission-checklist.md
│   ├── DemoJam _ Red Hat One 2027.pdf
│   └── adr/                 # Architecture Decision Records
└── specs/                   # Behavior specs (spec-driven development)
    ├── index.spec.md        # Spec registry
    ├── agents/              # Agent behavior specs
    ├── devsecops/           # Pipeline and trigger specs
    ├── evaluation/          # Patch quality and evaluation specs
    ├── observability/       # Tracing and logging specs
    ├── platform/            # Infrastructure and sandbox specs
    └── standards/           # Cross-cutting constraints
```

> Early skeleton — components (agents, pipelines, tests, sample-app, config) will be added as feature branches.

## Constraints and Rules

- **Spec-driven development**: Define behavior specs in `specs/` before writing code. Use the `spec` skill.
- **No secrets in repo**: Use environment variables or sealed secrets. Enforced by the no-secrets rule (§ Always-on rules) and the `no-secrets` skill.
- **English**: All code, comments, docs, and commit messages in English.
- **Conventional Commits**: Required format for all commits.
- **ADR alignment**: Consult ADRs before architectural or deploy changes.
- **Document new functionality**: After adding or modifying a stack technology, run the `document-feature` skill in the same session.
- **Pull requests**: Use the `create-pr` skill — body must follow the Summary/Details/Test plan structure.

## References

- [DemoJam Proposal PDF](docs/DemoJam%20_%20Red%20Hat%20One%202027.pdf)
- [ROADMAP](docs/ROADMAP.md)
- [Architecture Decision Records](docs/adr/README.md)
- [Red Hat AI Agentic Strategy 2026](https://www.redhat.com/en/blog/operationalizing-bring-your-own-agent-red-hat-ai-openclaw-edition)
- [RHOAI Documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai/)
- [Reference repo: acs-ai-overwatch](https://github.com/RedCupofJoe/acs-ai-overwatch)

## Always-on rules

> Folded from tool-specific rule files so every agent applies them.

### adr-alignment (formerly `.cursor/rules/adr-alignment.mdc`)

### ADR Alignment

Accepted Architecture Decision Records (ADRs) are the **binding source of truth** for this project. Do not contradict them without updating the ADR first.

#### Before You Act

1. Read [docs/adr/README.md](docs/adr/README.md) for the ADR index.
2. For the affected layer, open the linked ADR(s) in [docs/adr/](docs/adr).

#### Status Rules

| Status | Agent behavior |
|---|---|
| **Accepted** | Follow strictly. If the task conflicts, stop and propose an ADR update (use the `adr` skill) — do not silently override. |
| **Proposed** | Treat as direction, not locked. Flag conflicts with Accepted ADRs. |
| **Deprecated / Superseded** | Ignore; follow the superseding ADR instead. |

#### When to Create or Update an ADR

Use the `adr` skill when the task would:

- Add, remove, or swap a platform component
- Change deployment topology or version pinning policy
- Reverse an Accepted decision

Implementation-only work (bug fixes, docs typos) does **not** require a new ADR.

#### After Architectural Changes

- Update the ADR **Validation** section (or create an ADR if missing)
- Run the `document-feature` skill for guides and cross-links
- Cite the ADR number in commit/PR descriptions

### conventional-commits (formerly `.cursor/rules/conventional-commits.mdc`)

### Conventional Commits

All commit messages in this project MUST follow the [Conventional Commits](https://www.conventionalcommits.org/) specification.

#### Format

```
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

#### Allowed types

| Type | When to use |
|---|---|
| `feat` | New feature or capability |
| `fix` | Bug fix |
| `docs` | Documentation only changes |
| `chore` | Maintenance, dependencies, CI config |
| `test` | Adding or correcting tests |
| `refactor` | Code change that neither fixes a bug nor adds a feature |
| `style` | Formatting, whitespace (no logic change) |
| `ci` | CI/CD pipeline changes |

#### Optional scope

Use component name in parentheses: `feat(multi-agent):`, `fix(pipeline):`, `docs(adr):`.

#### Examples

```
feat: add Lightwell webhook trigger
fix(pipeline): correct Tekton task ordering
docs(adr): record multi-agent consensus architecture
chore: update Helm chart dependencies
```

#### Rules

- Subject line: imperative mood, lowercase, no period at end
- Max 72 characters for subject line
- Body (if present): explain *what* and *why*, not *how*
- Breaking changes: add `BREAKING CHANGE:` footer or `!` after type

### docs-repo-alignment (formerly `.cursor/rules/docs-repo-alignment.mdc`)

### Documentation-Repository Alignment

Project index docs (`README.md`, `AGENTS.md`, `docs/ROADMAP.md`) must reflect
**what exists in the repo today**, not planned or retired paths.

#### When this rule fires

Run the **`sync-repo-docs`** skill in the **same session** when you:

| Trigger | Examples |
|---|---|
| User asks to audit or align documentation | "revisa la documentacion", "align docs with repo" |
| Add, remove, or rename top-level paths | New directory, removed directory |
| Add or remove an agent skill | New `.agents/skills/<name>/` |

#### Required checks

1. **Paths** — Every path in `AGENTS.md` / `README.md` trees exists; no retired paths.
2. **Skills** — Every folder under `.agents/skills/` appears in `AGENTS.md` § Agent Skills.
3. **ROADMAP links** — Completed `[x]` items link to real files.
4. **Cross-links** — `README.md` § Documentation lists primary guides; broken relative links are fixed.

#### Do not

- List planned paths as if they already exist
- Duplicate long procedures in `README.md` / `AGENTS.md` — link to `docs/`

### no-secrets (formerly `.cursor/rules/no-secrets.mdc`)

### No Secrets in Repository

Never write, stage, commit, or push real secrets or credentials.

#### Hard stops (do not proceed)

Refuse and warn the user if any of the following would enter git:

| Category | Examples |
|---|---|
| Env / token files | `.env`, `*.env` (except `*.env.example`/`*.template.env`), `token.env` |
| Key / cert material | `*.key`, `*.pem`, `*.p12`, `*.pfx`, `id_rsa`, kubeconfig files |
| Credential dumps | `credentials.json`, `service-account.json`, `*-sa.json` |
| Inline secrets | API keys, passwords, bearer tokens, private keys, JWTs in source/YAML/docs |

Token formats in play on this project, so you recognise them in a diff:

| Credential | Format |
|---|---|
| MaaS API key (`MAAS_API_KEY`) | `sk-` plus base64url, so it contains `_` and `-` |
| GitHub fine-grained PAT (`GITHUB_TOKEN`) | `github_pat_...` |
| GitHub CLI token, if someone reuses theirs | `gho_...` |

All three live in `secrets/secrets.env`, which is gitignored. They reach the
cluster only through `make secrets`, never through a chart, a values file or an
ArgoCD Application spec (ADR-0007).

#### Allowed

- Placeholders: `CHANGE_ME`, `<token>`, `REPLACE_WITH_…`
- Examples only: `.env.example`, `*.template.env` with fake values
- Docs that describe *how* to create secrets (no real values)

#### Required behavior

1. Before `git add`, `git commit`, `git push`, or opening a PR → run the `no-secrets` skill scan.
2. If a secret is found: **stop**, list the files/paths, do **not** stage them.
3. Never paste real tokens into chat responses, commit messages, or PR bodies.
