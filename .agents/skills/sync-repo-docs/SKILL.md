---
name: sync-repo-docs
description: >-
  Audit and sync README, AGENTS.md, ROADMAP, and cross-links with the actual
  repository layout, scripts, skills, and Makefile targets. Use when the user
  asks to align or review documentation, after adding/removing paths or skills,
  or when the docs-repo-alignment rule applies.
---

# Sync Repository Documentation

Keep **index docs** aligned with the repo. Component install guides are handled
by `document-feature`; this skill covers structure, skills tables, and links.

## Quick audit commands

From repo root:

```bash
# Skills vs AGENTS.md table
ls -1 .agents/skills/

# Stale path grep (should return nothing after a clean audit)
rg -n 'deploy/kustomize|agent/src|agent/prompts' --glob '*.md'
```

## Checklist

Copy and complete:

```
Repo docs sync:
- [ ] 1. Compare AGENTS.md § Project Structure with filesystem
- [ ] 2. Compare README.md § Project Structure (shorter) with filesystem
- [ ] 3. Compare AGENTS.md § Agent Skills with .agents/skills/
- [ ] 4. Fix ROADMAP.md links to non-existent paths
- [ ] 5. Verify README.md § Documentation links resolve
- [ ] 6. Run stale-path grep; fix any hits
```

## Project structure template (AGENTS.md)

Use this as the baseline when rewriting § Project Structure:

```
lightwell-autonomous-remediation/
├── .github/
│   ├── pull_request_template.md
│   └── workflows/
├── .cursor/
│   ├── rules/
│   └── skills/
├── AGENTS.md
├── README.md
├── assets/
└── docs/
    ├── ROADMAP.md
    ├── DemoJam _ Red Hat One 2027.pdf
    └── adr/
```

> Update this template as components are added (agents, deploy, pipelines, tests, etc.)

## After syncing

- Do not create new markdown files unless the user asked or `document-feature` requires it
- English for all committed `.md` files
