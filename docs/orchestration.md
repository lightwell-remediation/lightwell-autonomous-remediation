# Orchestration — the Tekton Pipeline

How the remediation phases are sequenced in the cluster: deploying the
Pipeline, running it, and testing it without spending anything.

- Behaviour contract: [`orchestration-strategy.spec.md`](../specs/agents/orchestration-strategy.spec.md)
- Decision and trade-offs: [ADR-0009](adr/0009-tekton-pipeline-orchestration.md)
- The runtime each phase invokes: [`agent-runtime.md`](agent-runtime.md)

## The sequence

```
claim → analyse → remediable? → baseline → green? → demonstrate → patch+verify → sbom → deliver
                      │ no                    │ no                     ↺ once                 │
                      ↓                       ↓                                               ↓
              nothing to do, run       red baseline, run                    pull request, run
              succeeds unchanged       fails unchanged                      succeeds
```

Each phase is a Task; each gate is a `when` expression on the previous
phase's terminal state. Patching and verification are one Task with
`retries: 1`, because they retry together.

`sbom` rebuilds the application's bill of materials from the remediated
tree. After verification so it describes a tree that passed, and before
delivery because delivery commits the working tree in one go — a pull
request whose inventory still names the version just fixed brings the alert
straight back. It is a plain command, so it is a Task rather than a session
([ADR-0005](adr/0005-determinism-boundary.md)), and it is skipped for an
application that publishes no inventory.

Only `claim` and `outcome` run on the `cli` image. Everything else uses the
agent image, including `baseline` and `sbom`, which run no session at all:
the baseline and the post-change suite are compared against each other, and
Syft scans the jar that verification built, so all three have to come from
one toolchain.

## Deploying

The chart is applied with Helm directly. It is **not** under ArgoCD yet —
putting it there while it still changes means a commit per iteration.

```bash
helm upgrade --install remediation-pipeline \
  deploy/gitops/deployments/agents/remediation-pipeline \
  --namespace lightwell-agents --wait
```

It creates five Tasks, the Pipeline, the dependency cache claim, and a
service account with `get`/`list` on `pipelineruns` for the claim task alone.
The cache claim carries `helm.sh/resource-policy: keep`, so a `helm uninstall`
does not throw away a warm cache.

## Testing it for nothing

Every phase is a document in and a document out, so the whole sequence
replays from recorded documents with no session started.

```bash
scripts/test-pipeline.sh            # six scenarios on the cluster
scripts/test-pipeline.sh delivered  # one of them
scripts/test-claim.sh               # one run per application, across pods
```

`test-pipeline.sh` asserts the run's status, **which tasks were skipped**, and
how many attempts patching took. The skip list is the half that matters: a run
that succeeds having skipped the work looks identical from the status alone.

The same scenarios go through the local sequencer, which needs no cluster and
no container:

```bash
scripts/remediate.sh --replay agent-runtime/test/fixtures/scenarios/delivered
```

Scenarios and what each covers:
[`agent-runtime/test/fixtures/scenarios/README.md`](../agent-runtime/test/fixtures/scenarios/README.md).

## Setting the namespace up

Two prerequisites, both of which fail in misleading ways if skipped:

| Missing | What it looks like |
|---|---|
| The `lightwell-lightwell` Secret (`LW_USERNAME`, `LW_PASSWORD`, `LW_MAVEN_REPO_URL`) | `verify` fails with a Maven resolution error that reads like a bad patch |
| An image built from the current `agent-runtime/` | `run-agent.sh` rejects a role, or a gate module is "not found" |

```bash
scripts/push-secrets.sh               # all three Secrets, from secrets.env
scripts/build-runtime-image.sh main   # build and tag <ref>-<sha>
scripts/build-runtime-image.sh --from-dir   # or the working tree, unpushed
```

`build-runtime-image.sh` prints the `--set image.agent=…` line that points
the chart at what it just built. The tag it creates is never reused; the
BuildConfig's own output tag is overwritten on every build and must not be
referenced from the chart.

## A real run

```bash
scripts/run-remediation.sh .fixtures/osv/CVE-2026-68079.json            # path A
scripts/run-remediation.sh deploy/pipelineruns/osv/GHSA-hfrx-6qgj-fp6c.json  # path B
```

It mounts the record as a ConfigMap, starts the run, waits, and prints each
task's status. `--osv` also takes a URL, which the runtime fetches — with the
Lightwell credentials when they are set, without them for a public source
such as osv.dev; mounting it means the run does not depend on the record's
source being reachable from the cluster and the same record replays later.
The two paths, and which application each runs against:
[replicate.md](replicate.md).

**`--branch` picks the base**, and so the branch the pull request is opened
against. The default branch is the right one for both templates: the CXF demo
is published with its vulnerable path reachable (all four advisories live in
the authorization server, and a tree that never reaches it ends honestly in
`not-reachable`).

`deploy/pipelineruns/remediate.yaml` is the same thing as a manifest, for
when something needs to be edited by hand.

## Things that cost time to find

**`helm upgrade` keeps the last `--set`.** Overrides are stored on the
release, so an upgrade that passes none still serves the previous one and
reports `STATUS: deployed` while disagreeing with git. It bit us testing a
`wip-` image: the chart said `main-2cc0d31`, the cluster ran the old tag,
and nothing said so. `helm get values remediation-pipeline -n
lightwell-agents` shows what is remembered, and `--reset-values` puts the
chart back in charge. Worth doing on any upgrade meant to restore the
committed state.

**The BuildConfig's output tag is not immutable.** It is overwritten on every
build, so with the default `IfNotPresent` a node keeps serving the layer it
cached first and a rebuild changes nothing — the symptom was a module the
image demonstrably contained. The chart references a tag naming the commit
instead, which `build-runtime-image.sh` creates and never reuses.

**`oc start-build --from-dir` ignores `.dockerignore`.** It tars the whole
directory, so it trips over `.workspace/` — owned by the container's mapped
UID after any local run — and fails with a permission error that looks like a
cluster problem. The script builds a context holding only what the
Containerfile copies.

**`oc apply` on a Secret replaces its data wholesale.** Applying a Secret
without a value for some key deletes that key from a working one.
`push-secrets.sh` merges instead.

**Steps bypass the image's ENTRYPOINT.** Tekton injects its own, so a step
calling `run-agent.sh` directly skips the starter kit's `entrypoint.sh` —
git credentials, MCP, tracing — and the agent reaches delivery unable to
push. Every agent step goes through `entrypoint.sh` explicitly.

**One PVC-backed workspace per task.** With the affinity assistant in
`coschedule: workspaces` (the default, and this cluster's setting) a TaskRun
binds at most one, and the run's own workspace is it. The dependency cache is
a plain Task volume for that reason; it is RWX, so nothing the assistant
protects applies to it.

**A `volumeClaimTemplate` is not discarded by default** in that same mode. The
PipelineRun needs `tekton.dev/auto-cleanup-pvc: "true"` or the claims
accumulate.

**`lightwell.dev/application` must be a label on the PipelineRun**, not only a
param. The claim lists on it; a run without it is invisible to every claim,
including the next one's.

**`pipeline` is an ambiguous short name** with RHOAI installed — it resolves
to Kubeflow. Use `pipelines.tekton.dev`.

## What is not here yet

- **The trigger.** How a vulnerability record arrives is out of the spec's
  scope and depends on systems that do not exist.
- **ArgoCD.** Deliberate, until the chart stops changing.
- **CI on the generated pull request**, and moving the build off GitHub
  Actions. Both dropped from Milestone 1 on 2026-10-20 — the run already
  builds and tests the remediated tree before it delivers, and the workflow
  that would have gone red is not published to the demo repository
  (ROADMAP — Out of scope for Milestone 1).
- **TPA on this cluster.** The `sbom` task's `validate` step uploads the
  regenerated inventory to a TPA on a separate cluster for Milestone 1
  ([workarounds](workarounds.md)); the application's baseline is registered
  once with `scripts/tpa-onboard.sh`.
