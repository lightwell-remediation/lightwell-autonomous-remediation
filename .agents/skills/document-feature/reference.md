# Document Feature — Reference

## File placement map

```
agentops-showcase/
├── docs/
│   ├── ROADMAP.md                    # check off completed tasks
│   ├── adr/                          # Architecture Decision Records (one file per decision)
│   │   ├── README.md                 # ADR index (technical)
│   │   └── NNNN-<slug>.md           # Individual ADR files
│   ├── stack-decisions.md            # ADR executive summary (by layer)
│   ├── AGENT-SANDBOX-AND-OPENSHELL.md  # sandbox topology + launch (canonical)
│   ├── demo/overall-demo-architecture.html  # interactive architecture map
│   ├── demo-script.md                # demo steps with timing (Phase 4)
│   └── <component>-installation.md   # install, deploy, verify, troubleshoot
│       OR docs/<component>/
│           ├── 01-prerequisites.md
│           ├── 02-install-openshift.md
│           └── 03-operations.md
├── deploy/
│   ├── helm/<component>/values*.yaml
│   └── Makefile                      # make deploy-<component> targets
├── scripts/
│   └── <component>-*.sh
├── tests/
│   └── health-check.sh               # add component checks
└── .agents/skills/
    └── <component>-*/SKILL.md
```

## Primary guide template

Use for `docs/<component>-installation.md` or the main file under `docs/<component>/`:

```markdown
# <Component> Installation Guide

<Brief role in AgentOps demo. Link to AGENTS.md architecture.>

**Official references**:
- <upstream doc URL>

## Overview

| Target | Use case | Section |
|---|---|---|
| ... | ... | ... |

## Prerequisites

| Requirement | Notes |
|---|---|
| ... | ... |

## Install

### <Environment A>

\`\`\`bash
# validated commands
\`\`\`

| Value | Setting | Reason |
|---|---|---|
| ... | ... | ... |

## Verify

\`\`\`bash
# health checks
\`\`\`

Expected output: ...

## Uninstall

\`\`\`bash
...
\`\`\`

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| ... | ... | ... |

## References

- <official URLs only>
```

## ROADMAP entry pattern

When validation completes:

```markdown
- [x] Validate <Component> on target cluster — see [docs/<guide>.md](<guide>.md) (chart `X.Y.Z`, ...)
```

## AGENTS.md updates

**Agent Skills** (new skill):

```markdown
| `<skill-name>` | <one-line when to use> — see [docs/...](docs/...) |
```

**References** (platform component):

```markdown
- [<Component>](<official URL>) — <short note>; validated flow in [docs/...](docs/...)
```

**Project Structure** — add new paths only when directories are created.

## README.md update

Under **Documentation**, one line:

```markdown
- [docs/<guide>.md](docs/<guide>.md) - <Component> <what it covers>
```

## Skill frontmatter pattern

```yaml
---
name: <component>-<action>
description: >-
  <What it does>. Use when the user asks to <triggers> or after
  <implementation context>.
---
```

## OpenShell example (complete artifact set)

| Step | What was done |
|---|---|
| Local install validated | `scripts/install-openshell.sh`, `scripts/uninstall-openshell.sh` |
| Guide written | `docs/openshell-installation.md` (local + OpenShift Helm sections) |
| Skills | `openshell-local-install`, `openshell-local-cleanup`, `openshell-cluster-install`, `openshell-cluster-cleanup` |
| Cluster path validated | Helm `0.0.83`, TLS + certgen hook, OpenShift SCC overrides |
| Secret bootstrap documented | Links to upstream README; troubleshooting for `openshell-jwt-keys` |
| ROADMAP | `Validate OpenShell deployment...` marked `[x]` |
| AGENTS.md / README | Cross-links and References |

## Validation checklist before marking done

- [ ] Commands in the doc were run successfully (or marked as untested)
- [ ] Pinned versions match what was tested
- [ ] Troubleshooting rows come from real failures, not speculation
- [ ] No secrets, tokens, or cluster-specific credentials in committed files
- [ ] ROADMAP and README links resolve
- [ ] Upstream docs cited for GA status and CRD fields
