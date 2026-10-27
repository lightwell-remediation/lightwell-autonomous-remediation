# ADR-0009: Orchestrate the Remediation Sequence as a Tekton Pipeline

## Status

Accepted

## Date

2026-10-17

## Layer

Agents

## Context

[`orchestration-strategy.spec.md`](../../specs/agents/orchestration-strategy.spec.md)
collects the obligations six other specs defer to whatever runs the remediation
capabilities in order. It deliberately names no implementation, because the choice
has trade-offs and the specs were written to hold either way. This ADR makes it.

What has to be orchestrated:

```
analyse → remediable? → baseline → green? → demonstrate → patch → verify → deliver
             │ no                     │ no                  ↑        │ regression
             ↓                        ↓                     └────────┘ (once)
      stop, nothing changed    stop, nothing changed
```

`scripts/remediate.sh` implements this today and satisfies every requirement. It runs
on a laptop against podman. The question is what runs it in the cluster.

Three facts shape the answer.

**The sequencing contains no judgement.** Every branch in `remediate.sh` is a string
comparison on a `terminal_state` field read out of a JSON document. There is no step
where a different reading of the same inputs would be defensible. By
[ADR-0005](0005-determinism-boundary.md) — compute what is computable — that is work
for a script, not a session.

**The phases are expensive and variable; the sequencing must not be.** A full run is
seven to eleven minutes and $0.74–$1.05, and the same input has produced 41 turns and
108. The ordering, the retry bound and what is carried between phases are exactly the
parts that go wrong, and none of them need a model to exercise. They should be
testable in seconds against recorded documents, which is only possible if the layer
doing the sequencing is deterministic.

**The retry is load bearing and bounded.** Measured over five runs against a fixture
needing a source change, two reached `verified` on the first attempt and two on the
second. One retry is worth having; a second is not, and `cannot-verify` must never be
retried at all, because a retry addresses a known cause and that state means the cause
is not known.

## Options

### A coordinating agent

A model decides what runs next, reading each document as it is produced.

It is the only option that can recover from something nobody anticipated, and it would
let the sequence adapt under time pressure — a real consideration for a demo with a
five-minute slot and a run that takes longer than that.

Against it: it cannot be replayed. The whole value of this layer is that it does the
same thing twice, and a run that cannot be replayed against recorded documents takes
the sequencing from seconds and nothing to minutes and a model call per attempt. It
also adds inference latency to a sequence already over its demo budget, and it puts a
model in the one place where a wrong decision is silent — an orchestrator that decides
not to run verification produces a green run.

### RHOAI AI Pipelines (Kubeflow Pipelines v2)

The cluster has `aipipelines` in `Managed`, so this was examined properly rather than
dismissed.

In its favour: the pipeline is Python. `dsl.If` / `dsl.Elif` / `dsl.Else` express
branching better than Tekton's `when` expressions, and a pipeline that is code is a
pipeline that can be unit tested.

Against it: KFP v2 has **no while loop and no recursion** — `dsl.ParallelFor` is a
static fan-out, and the v1 `@graph_component` recursion was removed in v2. So it does
not solve the problem that motivated looking at it. Beyond that, no
`DataSciencePipelinesApplication` is instantiated on this cluster, it requires object
storage to stand one up, its data passing is artifact-based rather than a shared
volume, and it is the product for ML workflows. Choosing it would also cost the
trigger path: Tekton Triggers and Red Hat Developer Hub are both on the Milestone 2
architecture, and neither consumes KFP.

### Argo Workflows directly

The CRDs are on the cluster — `workflows.argoproj.io` and the rest arrive with the
RHOAI pipelines operator — and Argo has what neither of the above does: recursive
templates, hence real loops.

They are present as RHOAI's internals. Using them directly is outside what Red Hat
supports, and the project's standing constraint is to prefer Red Hat products and their
documentation. Taking an unsupported dependency to get a loop we do not need is a bad
trade.

### One container running `remediate.sh`

A Job, or a single Tekton Task, running the script that already works.

Cheapest by a wide margin and it would pass every requirement in the spec. What it
gives up is visibility: no per-phase status, no per-phase resource shaping, nothing in
the dashboard that shows a remediation progressing. For a submission whose subject is
an autonomous DevSecOps pipeline, the sequence being legible is part of the artefact.

### A Tekton Pipeline, one Task per phase

The phases become Tasks. `when` expressions on the previous phase's terminal state
implement the precondition table the spec already specifies. The bounded retry is
`retries: 1`.

## Decision

A Tekton Pipeline, one Task per phase.

It keeps the sequencing deterministic and therefore replayable, it is the Red Hat
product for this job and already installed, it is what Tekton Triggers and Developer
Hub plug into, and it makes each phase visible.

Four design points are part of the decision, because the arrangement is wrong without
them.

### The retry is `retries: 1` on a combined Task, not two sets of tasks

Patching and verification are **one** Task with three steps — `patch`,
`restore-baseline`, `verify` — carrying `retries: 1`.

The first draft of this design wrote the retry out as duplicated
`patch-retry`/`verify-retry` pipeline tasks, on the reasoning that Tekton has no loop.
Tekton has no loop, but this never needed one: the spec says the retry happens *at most
once*, and `retries` re-runs the whole TaskRun on failure. The bound becomes a number
rather than a shape, and there is no second copy of the phases to keep in step.

The workspace is bound at PipelineRun level, so the second attempt mounts the same
volume and reads the evidence the first left in `out/verification.json`. That is what
makes the retry informed rather than a second guess. `restore-baseline` runs at the
start of every attempt, which turns the spec's fourth guarantee — a retry is measured
against the starting state, never against the attempt that failed — into something
structural rather than a line of script that can be moved.

**Only a regression triggers it.** `retries` cannot discriminate between failures, and
the spec forbids retrying `cannot-verify`. The verify step therefore writes a sentinel
whenever it concludes anything that is not a regression, and the patch step exits
immediately when it finds one. A second pod starts and nothing is spent in it. The
alternative — exiting zero on `cannot-verify` so no retry fires — would leave the Task
green in the dashboard for a run that failed, which is the dishonesty the exit status
contract exists to prevent.

### The run's outcome is rendered by a `finally` task

`outcome` exits zero if the analysis reached `no-action-needed`, or if `deliver`
succeeded; non-zero otherwise.

It is not redundant with the per-task failures. A run where a phase is skipped on an
unexpected state reaches the end with every task "completed" and the PipelineRun
reporting success having delivered nothing — *nothing needed doing* and *something
needed doing and did not get done* collapsed into one status, which is precisely what
the spec's last requirement forbids.

### Two stores, because they have two lifetimes

| Store | Binding | Lifetime |
|---|---|---|
| run workspace | Tekton workspace, `volumeClaimTemplate`, ceph-rbd RWO | created and destroyed with the run |
| dependency cache | plain Task volume, `persistentVolumeClaim`, cephfs **RWX** | outlives every run |

A cold cache costs over fifteen minutes against roughly two warm, on a sequence that
already runs seven to eleven. A shared store kept between runs, on the other hand,
carried leftover branches and stale reports that produced wrong results three times
during development, silently each time. Separating the two takes both costs away.

RWX for the cache is not cosmetic. Runs against *different* applications may be
concurrent — the claim below permits that deliberately — and an RWO claim would
serialise them on a volume they mostly only read.

**The cache is a volume rather than a second workspace, and that was forced.** With
the affinity assistant in `coschedule: workspaces` — Tekton's default and this
cluster's setting — a TaskRun may bind only one PVC-backed *workspace*, and these
tasks need the run's own. Tekton's documented fix is `coschedule: pipelineruns`,
which on a single-node cluster would cost nothing; it is also a cluster-wide setting
owned by the operator and shared with every other pipeline here, so it is not ours to
change for one chart's convenience. The restriction exists because an RWO claim can
only attach to one node, and this claim is RWX, so there is no node affinity it was
protecting. What it costs is that the cache is bound by claim name rather than per
run — which for a store that is deliberately a singleton is arguably the more honest
binding.

### One run per application needs an identity the agent does not have

`flock`, which the local sequencer uses, does not cross pods. A first task
`claim-application` lists PipelineRuns labelled with the application and refuses to
start where one is already running.

Listing PipelineRuns is a Kubernetes API call, and the agent service account
deliberately holds no Role — the agent does not talk to the API, and that is a property
worth keeping. So this task runs under its own service account with a Role of exactly
`get`/`list` on `pipelineruns`, on an `ose-cli` image rather than the agent image.

List-then-start is not atomic. The window is milliseconds against runs of minutes.
Stating that is better than implying a guarantee this does not give.

### The record is mounted, or fetched once by the runtime (2026-10-27)

The record reaches the run as a ConfigMap, or as a URL the first phase fetches
into the run's workspace before its session starts; every later phase reads
that copy (`remediation.record` in the chart helpers). On path A the URL is
Lightwell's, built from `LW_OSV_BASE_URL` and the record's id, and the
credentials are read from `lightwell-lightwell` by `run-agent.sh` — never by
the session, which still has no network.

A per-run fetch rather than a fetch per phase: four requests would let the
phases of one run read different documents if the source changed mid-run.
Mounting stays the default for anything already on disk, because it needs no
network and replays the same.

Lightwell now serves one advisory per rebuild, bundling every CVE the rebuild
fixes. The run therefore carries a `vulnerability` parameter, taken from the
id, and the analysis gate refuses an analysis of a sibling CVE
(`check-analysis.js`, `EXPECTED_VULNERABILITY`).

## Consequences

**The sequencing now exists twice.** `scripts/remediate.sh` stays as the local path —
it is how a phase gets debugged without a cluster — and the Pipeline is the in-cluster
one. Two implementations of one contract drift unless something holds them together.
What holds them is the spec plus a shared set of recorded scenarios replayed through
both. This is the real cost of the decision and it is worth naming rather than
discovering.

**Testing the orchestration costs nothing.** Every phase is a document in and a
document out, so a run replays from recorded documents with no session started: the
`when` expressions, the skip propagation, the retry, the sentinel and the two
workspaces are all exercised without MaaS, GitHub or Lightwell credentials. The
scenarios that matter are the branches, and the branches are free to run.

**A PipelineRun is never committed to git.** Under ArgoCD a PipelineRun in a managed
path is permanent drift — it completes, and reconciliation wants it back. Tasks and the
Pipeline are GitOps-managed; runs are created imperatively or by a trigger, and the
examples live outside the managed tree with a README saying why.

**The per-run workspace needs an explicit annotation to be per-run.** With
`coschedule: workspaces`, which is this cluster's setting, `volumeClaimTemplate` claims
are *not* deleted when the PipelineRun finishes. Without `tekton.dev/auto-cleanup-pvc`
on the run, the workspace does not have the lifetime this decision depends on, and the
orphans accumulate — two were already sitting in the namespace before anyone looked.

**Steps bypass the image's ENTRYPOINT.** Tekton injects its own, so the upstream
starter kit's `entrypoint.sh` — which sets up git credentials, MCP and tracing before
exec'ing the command — does not run unless a step invokes it explicitly. A step that
calls `run-agent.sh` directly gets an agent that cannot push.

**`pipeline` is an ambiguous short name** on a cluster with RHOAI installed: it
resolves to Kubeflow. Manifests use `tekton.dev/v1` and fully qualified references
throughout, and so does anything operating them.

**Steps pull `Always`, because the image tag is not immutable.** The BuildConfig
overwrites the same tag on every build, so pinning it only looks like pinning: with
the default `IfNotPresent` the node keeps serving the layer it cached first and a
rebuild changes nothing. That cost a debugging round whose symptom was a module the
image demonstrably contained. Referencing the image by digest is the real fix and
needs the build to publish an immutable tag; until then, `Always` is the honest
setting.

**Container limits are 4 CPU and 8 GiB.** A build needing more is rejected by the
LimitRange rather than the scheduler, and that error does not read as one about
resources.

**The dual-agent arrangement is not blocked by this.** Delivery is a separate Task
consuming a candidate, so Milestone 2 places a judge between verification and delivery
without restructuring the sequence. The model is a Pipeline parameter rather than
deployment configuration, so running the same Pipeline twice with different models is
two PipelineRuns and not two deployments.

## References

- Behaviour: [`orchestration-strategy.spec.md`](../../specs/agents/orchestration-strategy.spec.md)
- What is computed versus reasoned about: [ADR-0005](0005-determinism-boundary.md)
- Runtime invocation contract and the honest exit status:
  [`agent-runtime.spec.md`](../../specs/platform/agent-runtime.spec.md),
  [ADR-0003](0003-agent-runtime-packaging-and-credentials.md)
- Tekton `retries` on a PipelineTask, `when` expression scoping, and PVC cleanup under
  the affinity assistant:
  [Tekton Pipelines documentation](https://tekton.dev/docs/pipelines/pipelines/)
- OpenShift Pipelines 1.24:
  [Red Hat OpenShift Pipelines documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_pipelines/)
- Kubeflow Pipelines v2 control flow (no loop, no recursion):
  [KFP control flow](https://www.kubeflow.org/docs/components/pipelines/user-guides/core-functions/control-flow/)
