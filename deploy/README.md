# Cluster bootstrap

Takes a plain OpenShift cluster to one that can run remediation agents. GitOps
reconciles the platform, the Makefile does the three things GitOps cannot own.

- What the cluster has to provide: [`cluster-bootstrap.spec.md`](../specs/platform/cluster-bootstrap.spec.md)
- Why it is built like this: [ADR-0006](../docs/adr/0006-cluster-bootstrap-topology.md),
  [ADR-0007](../docs/adr/0007-in-cluster-credential-delivery.md),
  [ADR-0008](../docs/adr/0008-agent-runtime-image-delivery.md)

## What gets installed

| Component | Why |
|---|---|
| OpenShift GitOps | Reconciles everything below from this repo |
| OpenShift Pipelines | Phase 3 needs it, and the smoke pipeline proves the cluster works |
| RHOAI 3.5 | Dashboard, MLflow, workbenches, pipelines, KServe, TrustyAI, model registry, OGX, Ray, training operator, Feast. A component is on unless it cannot work here |
| RHOAI dashboard flags | `OdhDashboardConfig` with 29 features on and 31 sections visible. The operator creates that singleton nearly empty, so most of the console stays hidden without this |
| CPU hardware profile | RHOAI 3.x will not start a workbench or a model server without one |
| MLflow | sqlite plus a 20Gi PVC. Not wired yet, it is the Phase 4.5 target |
| `lightwell-agents` namespace | ServiceAccount, container budget, credentials, builds and runs |
| Agent runtime image | Two chained BuildConfigs into the internal registry |
| Smoke pipeline | Two agent shaped tasks in parallel, plus a MaaS credential check |

Developer Hub is scaffolded and off. See
[its README](gitops/deployments/platform/developer-hub/README.md).

Three RHOAI components stay off, each for a reason written next to it in
[`openshift-ai/values.yaml`](gitops/deployments/platform/openshift-ai/values.yaml):

| Off | Why |
|---|---|
| `kueue` | `Managed` is no longer accepted in 3.5, the webhook denies the whole DSC. Kueue moved to the standalone Red Hat build of Kueue and the DSC only integrates with it, so it wants `Unmanaged` plus `kueue-operator`. Nothing here queues batch work. The dashboard hides the tile to match |
| `trainer` | Kubeflow Trainer v2 needs the JobSet operator, which is not in this cluster catalog. `trainingoperator`, the v1 it replaces, is on |
| `aigateway` | Serves the `maas.opendatahub.io` CRs, and the platform under them (Kuadrant, Authorino, `maas-api`) is installed by the MaaS guide, not by the DSC. We consume an external MaaS instead |

With KServe on, the DSC also reports `KserveLLMInferenceServiceDependencies` as
`PreConditionFailed`, "Red Hat Connectivity Link not installed". KServe itself is
Ready and it does not count against `ComponentsReady`. Install `rhcl-operator`
if anyone wants llm-d style serving here.

## Prerequisites

- OpenShift 4.19 or newer, cluster admin, `oc` and `helm` 3
- A default StorageClass, the image registry Managed with real storage, and the
  `Build` and `ImageRegistry` capabilities enabled
- Egress from build pods to GitHub, npm and the Red Hat registries
- `secrets/secrets.env` filled in, see the `secrets-setup` skill

`make preflight` checks all of it and names what is missing, including whether
the operator channels exist in the cluster catalog.

## Install

```bash
cd deploy
make preflight      # read only, tells you which preset matches this cluster
make deploy-all     # preflight + gitops + secrets + deploy, then waits
make build-image    # usually has nothing to start, the chain fires itself
make validate
```

`make deploy-all` is re-runnable. If it stops halfway, run it again.

ArgoCD reconciles from git, not from your laptop, so a change that is not pushed
does not exist for the cluster. While a branch is in review, point at it:

```yaml
# deploy/values/local.yaml, gitignored
bootstrap:
  targetRevision: feat/roberto/cluster-bootstrap
cluster:
  domain: apps.cluster-xxxxx.dyn.redhatworkshops.io
```

### Cluster presets

| Preset | When |
|---|---|
| `values/cluster-plain.yaml` | Default. We install the platform |
| `values/cluster-rhoai-existing.yaml` | RHOAI is already there and owned by other automation, we only add what is missing |

```bash
make deploy PRESET=values/cluster-rhoai-existing.yaml
```

## What is not GitOps, and why

| Step | Reason |
|---|---|
| `make gitops` | It installs the reconciler. It cannot reconcile itself into existence |
| `make secrets` | Nothing secret goes in git or into an Application spec |
| the smoke PipelineRun | One shot and immutable, so under GitOps it is permanent drift |

Everything else is reconciled. Delete a Deployment and it comes back.

## Credentials

`make secrets` reads `../secrets/secrets.env` and applies four Secrets. Same
variable names as the local runtime, so `run-agent.sh` behaves the same on a
laptop and in a pod. It prints no values and writes nothing to git.

| Secret | Namespace | Used by |
|---|---|---|
| `lightwell-maas` | `lightwell-agents` | the agent session |
| `lightwell-github` | `lightwell-agents` | clone, push and the pull request |
| `lightwell-git-source` | `lightwell-agents` | the image build, while this repo is private |
| `lightwell-repo` | `openshift-gitops` | ArgoCD read access, while this repo is private |
| `lightwell-lightwell` | `lightwell-agents` | nothing yet, Phase 3 trigger |

The two `git-source` and `repo` Secrets go away when the repository becomes
public in Phase 4.

## Validation

`make validate` is the gate, not the ArgoCD UI. ArgoCD calls a Subscription
healthy before the operator works, and a DataScienceCluster healthy the moment
the object exists.

It checks the Applications, the operator CSVs, the DSC conditions this project
depends on, MLflow, the namespace, the Secrets and the image, then runs the
smoke pipeline. A hello-world would only prove Tekton is alive. What actually
breaks later is the image, the scheduling, the storage and the credentials, so
the smoke pipeline runs the real image under a random UID, with a per run PVC,
and checks the gateway answers with the pinned model.

## Capacity

No GPU. Measured on the validation cluster, which went from 10.9 CPU and 37.8
GiB of requests to 18.1 CPU and 48.4 GiB after the bootstrap:

| Workload | CPU requests | Memory requests |
|---|---|---|
| OpenShift GitOps | 1.0 | 2.5 GiB |
| OpenShift Pipelines | 0.8 | 1.5 GiB |
| RHOAI operator plus the DSC above | 4.0 | 8 GiB |
| MLflow | 0.5 | 1 GiB, plus a 20Gi PVC |
| Agent session, times two in parallel | 2 x 0.5 (limit 2) | 2 x 1 GiB (limit 4) |
| Image build, while it runs | 1 | 2 GiB |
| Developer Hub, if enabled | 1.5 | 5 GiB, plus a 10Gi PVC |

Measured end to end on the validation cluster: 10.9 CPU and 37.8 GiB of
requests before, 20.5 CPU and 51.7 GiB after, so the whole bootstrap costs about
9.6 CPU and 14 GiB. Turning the RHOAI components on is roughly 2.4 CPU of that.

16 CPU and 48 GiB of allocatable capacity is the floor, 32 and 128 is
comfortable. The validation cluster is a single node with 32 and 124.

Storage: a default StorageClass, and an image registry that is Managed with
storage behind it. The dependency cache asks for ReadWriteMany on
`ocs-external-storagecluster-cephfs`, the CephFS class of an RHDP cluster; the
default RBD class cannot do RWX. `make preflight` checks all three. Elsewhere
point the remediation chart at your RWX class
(`--set cache.storageClass=<class>`). `--set cache.accessMode=ReadWriteOnce`
also works on a single node, where every pod shares the node the volume is
attached to; on several nodes, a run scheduled on another node waits in
`ContainerCreating` (Multi-Attach) until the volume is free.

Two sessions at a time is a documented budget, not a hard cap. The namespace
has a LimitRange with defaults and a ceiling, and no ResourceQuota: a quota that
fails a build at the wrong moment is worse than an over-subscribed node. Change
`agents.concurrency` to move the number, it drives both the ceiling and how many
parallel tasks `make validate` runs.

## Layout

```
deploy/
├── Makefile                  # the entry points
├── bootstrap/                # pre GitOps, applied with oc apply -k
│   ├── gitops-operator/      # Subscription
│   └── argocd-instance/      # cluster-admin binding plus two patches
├── gitops/
│   ├── bootstrap-infra/      # app of apps parent, one Application per component
│   └── deployments/
│       ├── platform/         # openshift-ai-operator, openshift-ai, openshift-pipelines, mlflow, developer-hub
│       └── agents/           # agent-workspace, agent-runtime-image, smoke
├── scripts/                  # preflight, install-gitops, setup-secrets, build-image, validate
└── values/                   # the two presets plus local.example.yaml
```

Same shape as `rhai-features-workshop/automation/gitops`, minus the per user
ApplicationSets, which this project has no use for. `bootstrap.pathPrefix` means
the tree can move without touching every Application.

## Sync waves

| Wave | Component |
|---|---|
| -5 | RHOAI operator, Pipelines operator |
| -4 | DataScienceCluster |
| 0 | MLflow, agent namespace |
| 1 | Image builds |
| 2 | Smoke pipeline |
| 5 | Developer Hub (off) |

Waves order the apply, not readiness, so the first sync shows transient failures
while CRDs appear. Applications retry with backoff, `make deploy-all` waits for
what the next step needs, and `make validate` is where you look.

## Day to day

```bash
make status                 # applications and the agent namespace
make argocd                 # URL, user and password
make lint && make template  # no cluster needed, what CI runs
make build-image FORCE=1    # rebuild after bumping a pin (and the runtime version)
make clean-runs             # delete old PipelineRuns and their PVCs
make undeploy               # remove the app of apps, keep the operators
```

## Things that will bite you

| Symptom | Cause |
|---|---|
| Every Application says `Repository not found` | ArgoCD has no credential for a private repo. Run `make secrets` |
| Applications sync but the path does not exist | `targetRevision` points at a branch that is not pushed |
| `platform-mlflow` is `OutOfSync / Missing` for a few minutes | The MLflow CRD arrives with the DSC. It settles on its own |
| DataScienceCluster is `Degraded` right after install | Dashboard pods still starting. Give it two or three minutes |
| The runtime build fails on clone | No `lightwell-git-source`, so `make secrets` was skipped or `GITHUB_TOKEN` is empty |
| A model error inside a session that validate passed | The key resolves the pinned model only. Re-run `make validate`, the `maas` task checks it |
| An Application is `Synced` and `Healthy` but the cluster does not have what the chart says | With `ServerSideApply` the comparison is a server dry run, so a webhook that denies the real apply denies the dry run too and ArgoCD sees no drift. `make validate` reads the sync operation phase for exactly this. Look at `.status.operationState.syncResult.resources` |
| A fix is pushed and ArgoCD keeps failing on the old revision | A rejected apply leaves the operation `Running` and retrying, and no new sync starts until it ends. Terminate it: `oc patch app <name> -n openshift-gitops --type merge -p '{"operation":null}'` |
| `oc get pipeline` says the smoke Pipeline is missing | It is not. RHOAI's `aipipelines` component brings `pipelines.kubeflow.org`, which also serves `pipelines`, so the short name stops meaning Tekton. Use `oc get pipelines.tekton.dev` |
