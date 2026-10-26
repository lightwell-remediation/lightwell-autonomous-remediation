---
name: helm-create
description: >-
  Create or modify Helm charts following OCP best practices. Includes reference
  patterns for ServiceAccount, SCC, Routes, ArgoCD sync. Use when creating a
  chart, editing Chart.yaml/values.yaml/templates, or the user says helm-create.
user_invocable: true
---

# Helm Create

Create or modify Helm charts following best practices for OpenShift Container Platform.

## Invocation

- `/helm-create <component-name>` to create a new chart
- Also activates automatically when working with Helm chart files

## Process for New Charts

### 1. Create Chart Structure

```
modules/<name>/charts/<chart-name>/
  Chart.yaml
  values.yaml
  templates/
    _helpers.tpl
    NOTES.txt
```

### 2. Apply Conventions

See `reference.md` for detailed patterns. Key rules:

- Use `_helpers.tpl` for all reusable template logic
- All values have sensible defaults for dev/local testing
- No hardcoded cluster-specific values (use `CHANGE_ME` placeholders)
- Use `{{ .Release.Namespace }}` instead of hardcoding namespaces
- 2-space YAML indentation
- Comments for non-obvious values in `values.yaml`

### 3. OCP-Specific Patterns

- Use Routes instead of Ingress (unless there's a reason for Ingress)
- Include SecurityContextConstraints when needed
- Use `{{ .Values.global.namespace }}` for cross-chart namespace references
- Gate optional resources with `{{- if .Values.<feature>.enabled }}`

### 4. ArgoCD Integration

When adding to ArgoCD:
- Create Application template in `argocd/apps/templates/`
- Use module enable guard: `{{- if .Values.modules.<name>.enabled }}`
- Set appropriate sync-wave (0: operators, 1: platform, 2: workloads)
- Standard sync policy: automated prune, selfHeal, ServerSideApply

### 5. Validate

```bash
helm template modules/<name>/charts/<chart>
helm lint modules/<name>/charts/<chart>
```

### 6. Update Documentation

- Add chart to `docs/versions.md` if present
- Update `AGENTS.md` (and `CLAUDE.md` if the repo has one) when new make targets are added
