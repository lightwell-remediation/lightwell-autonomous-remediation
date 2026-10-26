---
name: cluster-bootstrap
description: >-
  Bootstrap or validate the OpenShift cluster that hosts the remediation agents:
  OpenShift GitOps, OpenShift Pipelines, a minimal RHOAI with MLflow, the agent
  namespace and the runtime image. Use when the user asks to deploy or check the
  platform, when a cluster is fresh or expired, or says cluster-bootstrap,
  "deploy the platform", "bootstrap the cluster", "montar el cluster".
---

# Cluster Bootstrap

Everything lives in `deploy/`. Read [`deploy/README.md`](../../../deploy/README.md)
before changing anything there.

- Contract: [`specs/platform/cluster-bootstrap.spec.md`](../../../specs/platform/cluster-bootstrap.spec.md)
- Decisions: [ADR-0006](../../../docs/adr/0006-cluster-bootstrap-topology.md),
  [ADR-0007](../../../docs/adr/0007-in-cluster-credential-delivery.md),
  [ADR-0008](../../../docs/adr/0008-agent-runtime-image-delivery.md)

## When to use

| Trigger | Action |
|---|---|
| Fresh or replaced cluster | The full run below |
| "Is the cluster ready?" | `cd deploy && make validate` |
| A sync looks wrong | `make status`, then `make argocd` for the UI |
| Harness version bumped | `make build-image FORCE=1`, then `make validate` |

## Prerequisites

`oc` logged in as cluster admin, `helm` 3, and `secrets/secrets.env` filled in.
Run the `secrets-setup` skill first if that file does not exist. Never create or
edit Secrets by hand, `make secrets` is the only path (ADR-0007).

## Run

```bash
cd deploy
make preflight      # read only, names anything missing and the preset to use
make deploy-all     # preflight + gitops + secrets + deploy, then waits
make build-image    # usually only follows the build that already started
make validate
```

Use the preset preflight suggests. `cluster-plain.yaml` installs the platform,
`cluster-rhoai-existing.yaml` adopts an RHOAI that other automation owns:

```bash
make deploy PRESET=values/cluster-rhoai-existing.yaml
```

ArgoCD reads from git, so while a change is on a branch, set
`bootstrap.targetRevision` in `deploy/values/local.yaml` (gitignored) and push
the branch. A commit that only exists on the laptop does not exist for ArgoCD.

## Expected result

`make validate` green, which means: 7 Applications Synced and Healthy, three
operator CSVs Succeeded, the DataScienceCluster Ready with `DashboardReady` and
`MLflowOperatorReady`, MLflow Available, the Secrets present, the runtime image
built, and **two agent shaped Tekton tasks succeeding in parallel** plus the
MaaS credential check.

Expect 15 to 20 minutes on a fresh cluster, most of it the RHOAI operator and
the upstream image build.

## Token-efficient execution

Follow the global `long-running-scripts` skill. `make deploy-all` already waits
for what the next step needs, so do not poll ArgoCD or the operators in a loop.
Run `make validate` once at the end and read its output.

## Troubleshooting

Only after `make deploy-all` or `make validate` has failed. The troubleshooting
table in [`deploy/README.md`](../../../deploy/README.md) covers the usual ones:
a private repo with no ArgoCD credential, a `targetRevision` that was never
pushed, MLflow `Missing` while the DSC is still reconciling, and a runtime build
failing to clone.

Two rules when fixing:

- Do not edit cluster objects that an operator created and defaults, such as the
  `DSCInitialization`, the `TektonConfig` or the `ArgoCD` CR. Patch them
  deliberately through `deploy/bootstrap/argocd-instance/` instead (ADR-0006).
- Do not `oc apply` a workload by hand. It will be reverted by self-heal and the
  next person will not know why. Change the chart and push.

## Related skills

- `secrets-setup` before the first deploy
- `openshift-mcp` for live cluster inspection
- `helm-create` when adding a chart under `deploy/gitops/deployments/`
