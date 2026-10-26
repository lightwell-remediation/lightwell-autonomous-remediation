# ADR-0006: Cluster Bootstrap Topology

## Status
Accepted

## Date
2026-10-15

## Layer
Platform

## Context

ROADMAP Phase 0.5 blocks Phase 3 and every in-cluster run of Phase 2. The agent
runtime already works on a laptop and in a container ([ADR-0003](./0003-agent-runtime-packaging-and-credentials.md)),
but there is no cluster to run it on, and no repeatable way to get one.

Demo clusters live for days. Any bootstrap that depends on somebody remembering
the order of `oc apply` commands will be wrong the week we need it, so the
question is not "how do we install this once", it is "how do we install this
again on Thursday".

Two shapes of cluster have to work from the same repository:

- a plain OpenShift cluster, where we install everything (the Phase 0.5 target,
  validated on OCP 4.21 single node, 32 CPU / 126 GiB, ODF storage)
- a cluster that already has RHOAI, MaaS or other pieces installed by other
  automation, where touching them would break somebody else's work

There is prior art in the team: `rhai-features-workshop` uses an ArgoCD
app-of-apps Helm parent with sync waves, and `rhoai-nightly` uses scripts plus
kustomize for the pre-GitOps part. Both work. Neither fits as-is: the workshop
tree is built around per-user fan-out we do not need, and the nightly repo
installs a different product set.

Behavior requirements live in
[`specs/platform/cluster-bootstrap.spec.md`](../../specs/platform/cluster-bootstrap.spec.md).

## Options Considered

### Option 1: Shell scripts with `oc apply`

- **Pros:** No operator needed, easy to read, easy to debug, ordering is explicit
- **Cons:** Nothing reconciles. Drift is invisible, a deleted resource stays
  deleted, and the cluster state is whatever the last person ran
- **GA / support status:** N/A

### Option 2: Helm releases applied from a laptop

- **Pros:** Charts, values, one tool
- **Cons:** Same lack of reconciliation as Option 1, plus release state lives in
  the cluster of whoever ran it. Ordering between operator CRDs and the custom
  resources that need them has to be hand-held
- **GA / support status:** GA

### Option 3: GitOps app-of-apps, Helm charts per component

- **Pros:** Reconciles, ordering is expressed as sync waves, components are
  toggles, the cluster can be rebuilt from git. Same shape as
  `rhai-features-workshop`, so the team already knows how to read it, and it
  transplants into RHPDS later
- **Cons:** One operator to install first, and a chicken-and-egg problem for the
  operator itself. ArgoCD health does not mean product health
- **GA / support status:** OpenShift GitOps, GA

### Option 4: GitOps with per-tenant ApplicationSets (the workshop layout as-is)

- **Pros:** Direct copy of a tree that is known to work
- **Cons:** This project has one tenant. The fan-out machinery would be dead
  weight, and dead weight in a bootstrap is what breaks under time pressure
- **GA / support status:** As Option 3

## Decision

Bootstrap with **GitOps app-of-apps and Helm charts per component**, mirroring
the `rhai-features-workshop` layout (`bootstrap-infra/` parent,
`deployments/<group>/<chart>` children, sync waves, per-component toggles) but
without the per-user ApplicationSets. The tree lives in `deploy/gitops` and the
entry point is `deploy/Makefile`.

**Three things stay imperative**, because GitOps cannot own them:

| Imperative | Why |
|---|---|
| OpenShift GitOps operator and the ArgoCD instance patches | It is the reconciler. It cannot reconcile itself into existence |
| Secrets | Nothing secret goes in git, see [ADR-0007](./0007-in-cluster-credential-delivery.md) |
| PipelineRun objects | One-shot and immutable. Under GitOps they are permanent drift |

The GitOps install follows `rhoai-nightly/scripts/install-gitops.sh`: apply the
operator, wait for the CSV, then apply the ArgoCD instance patches and a
`cluster-admin` ClusterRoleBinding for the application controller, which it needs
to install operators and create cluster scoped resources. The manifests are
inlined in `deploy/bootstrap/` instead of pulled from the `redhat-cop`
gitops-catalog over the network, so a bootstrap does not depend on a third repo
being reachable and on whatever its `main` says today.

**Operator created singletons are not ours.** We own Subscriptions. We do not own
the `DSCInitialization`, the `TektonConfig` or the `ArgoCD` CR. The workshop tree
documents what co-ownership of the ArgoCD CR cost them: the controller was
silently downgraded and then OOMKilled while syncing. Tuning those objects is a
separate explicit action, not a reconciled manifest.

**Every component is a toggle**, and two presets are committed:
`values/cluster-plain.yaml` installs the platform, `values/cluster-rhoai-existing.yaml`
adopts an existing RHOAI and only adds what is missing. Preflight reports which
preset matches the cluster in front of you.

**Validation is a script, not the ArgoCD UI.** ArgoCD reports a
`DataScienceCluster` Healthy the moment the object exists, and a Subscription
Healthy before the operator works. `make validate` checks CSVs, component
conditions, Secrets, the image, and then runs two agent shaped workloads in
parallel.

**Sync waves** are the only ordering mechanism, so a single apply converges:

| Wave | Component |
|---|---|
| -5 | RHOAI operator, OpenShift Pipelines operator |
| -4 | DataScienceCluster |
| 0 | MLflow, agent namespace and ServiceAccount |
| 1 | Runtime image builds |
| 2 | Smoke pipeline |
| 5 | Developer Hub (off) |

## Consequences

### Positive

- A fresh cluster is `make deploy-all` plus `make validate`, which is what short
  lived clusters need
- Both cluster shapes work from one repository, with no fork and no branch
- The layout matches the workshop tree, so it can move to RHPDS with the same
  reading
- Platform drift is corrected without anyone noticing it happened
- What is imperative is a closed list of three, each with a stated reason, rather
  than whatever did not fit

### Negative

- The GitOps operator remains a manual first step, so "one command" is really
  "one command that starts by installing a reconciler"
- Granting cluster-admin to the application controller is a wide permission. It
  is what installing operators from GitOps costs, and it is the same posture as
  the nightly and workshop clusters
- Sync waves order the apply, not readiness. Applications still need retry and
  backoff while CRDs appear, and a first sync will show transient failures
- Two presets means two paths to keep working. Preflight prints which one to use,
  it does not pick for you

### Neutral

- Helm charts here render manifests only. No chart installs another chart, so
  `helm template` is a complete offline review of what will land

## Version Pinning

| Component | Pinned version | Where enforced |
|---|---|---|
| OpenShift GitOps operator | channel `latest` | `deploy/bootstrap/gitops-operator/subscription.yaml` |
| RHOAI operator | channel `stable-3.5` | `platform.openshiftAiOperator.channel` |
| OpenShift Pipelines operator | channel `latest` | `platform.openshiftPipelines.channel` |
| Developer Hub operator | channel `fast`, disabled | `platform.developerHub.channel` |

Channels are values, and preflight fails when the cluster catalog does not offer
the one configured. Pin `startingCSV` for a reproducible event.

## Demo Impact

The bootstrap is what makes the demo claim "replicable on RHDP" true. Without it
the story is one cluster that somebody set up by hand, which the judges cannot
reproduce and neither can we after it expires. It also keeps the Red Hat product
set visible: the platform arrives through OpenShift GitOps, OpenShift Pipelines
and RHOAI, not through a pile of YAML.

## Validation

**2026-10-15**, OCP 4.21.36, single node, 32 CPU / 126 GiB, ODF external storage,
no RHOAI and no Tekton at the start:

- Preflight on a plain cluster reports admin, default StorageClass, image
  registry with PVC storage, Build capability, and all three operator channels
  present in the catalog
- `make deploy-all` from zero reaches every Application Synced, and
  `make validate` passes including two parallel agent workloads
- The same tree with `cluster-rhoai-existing.yaml` renders without the RHOAI
  operator and DataScienceCluster Applications, which is what a cluster that
  already has RHOAI needs

Still not verified:

- A second full run on a different cluster shape, to confirm nothing cluster
  specific leaked into a template
- Behaviour when the cluster catalog has no `stable-3.5` channel, which will
  happen when RHOAI 3.6 ships

## Related Decisions

- [ADR-0003: Agent Runtime Packaging and Credential Model](./0003-agent-runtime-packaging-and-credentials.md)
- [ADR-0007: In-cluster Credential Delivery](./0007-in-cluster-credential-delivery.md)
- [ADR-0008: Agent Runtime Image Delivery](./0008-agent-runtime-image-delivery.md)

## References

- [rhai-features-workshop GitOps tree](https://github.com/rhpds/rhai-features-workshop/tree/main/automation/gitops)
- [OpenShift GitOps documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/)
- [ArgoCD sync waves](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/)
- [ROADMAP Phase 0.5](../ROADMAP.md)
