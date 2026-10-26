# PR Template Reference

Canonical example: [PR #1 — feat: add RHOAI installation Helm charts](https://github.com/davidseve/agentops-showcase/pull/1)

## Full body (PR #1)

```markdown
## Summary

- Add modular Helm charts for RHOAI 3.4 minimal installation: `operators`, `platform`, `database`, `mlflow`, and `evalhub`
- Include a `Makefile` with `deploy-all` / `undeploy-all` targets for one-command deployment and teardown
- Add `cluster-bootstrap` and `cluster-cleanup` skills validated against a live OCP cluster

## Details

Extracts and adapts the RHOAI installation from `rhoai-platform-ops`, keeping only the components defined as MUST HAVE in `AGENTS.md`:

| Chart | Purpose |
|-------|---------|
| `operators` | RHOAI 3.4 operator subscription, namespace, OperatorGroup |
| `platform` | DataScienceCluster (MLflow, TrustyAI, KServe) + Dashboard config |
| `database` | Shared PostgreSQL 16 with init scripts for `mlflow` and `evalhub` databases |
| `mlflow` | MLflow CR, Route, DB secret, DNS fix workaround |
| `evalhub` | EvalHub CR, DB secret, model-auth Job (prepared, optional) |

Key findings during testing:
- TrustyAI requires `kserve: Managed` in the DSC (`InferenceServices` CRD). Early PR testing suggested `modelsAsService: Managed` was also required; later validation (2026-08-14) confirmed `TrustyAIReady` with `modelsAsService: Removed` — see ADR-0008
- `OdhDashboardConfig` needs conditional rendering (`.Capabilities.APIVersions.Has`) due to CRD timing
- `mlflow` field in Dashboard config is deprecated and must not be set

## Test plan

- [x] Deployed full stack on OCP 4.20 cluster (demo.redhat.com)
- [x] Verified all DSC components reach Ready state
- [x] Verified MLflow instance running with PostgreSQL backend
- [x] Verified cleanup removes all resources cleanly
- [x] `make lint` and `make template` pass for all charts
```

## Assignee

No default assignee. Add `--assignee <user>` only when explicitly requested.
