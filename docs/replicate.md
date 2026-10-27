# Replicate the demo

From an empty OpenShift cluster to a pull request opened by the agent, with the
remediated inventory checked in Trusted Profile Analyzer. Every step is a
command in this repository; the platform itself is reconciled by OpenShift
GitOps.

There are two paths, and only steps 1, 2, 6 and 7 differ between them:

| | Path A — with Lightwell | Path B — without Lightwell |
|---|---|---|
| Who | You have a Lightwell account | Anyone |
| Application | The Apache CXF demo: the fix is a Lightwell rebuild plus a code change | [`document-intake-service`](target-app.md): the fix is an upstream release plus a code change, all from Maven Central |
| Extra credentials | Lightwell username, password and repository URL | None |

Validated end to end on 2026-10-27, following this guide on a fresh RHDP
*Field Sourced Content – OpenShift Base* cluster (CNV, single node, 32 CPU /
128 GiB, external ODF): OpenShift 4.22.18, OpenShift GitOps 1.22.2 (preinstalled
by the catalog item), OpenShift Pipelines 1.24.2, RHOAI 3.5.2. Both paths
delivered a pull request: path B with no Lightwell Secret in the namespace at
all, path A with the record fetched from Lightwell by the pipeline. Earlier
runs, 2026-10-15 to 2026-10-26: OpenShift 4.21.36, RHOAI 3.5.1, Trusted Profile
Analyzer 3.1 (Trustify 3.1.0).

| Step | What you get | Time |
|---|---|---|
| [0. Try it with nothing](#0-try-it-with-nothing) | Every pipeline branch replayed on a laptop | 1 min |
| [1. Accounts and credentials](#1-accounts-and-credentials) | `secrets/secrets.env` | 15 min |
| [2. The application to remediate](#2-the-application-to-remediate) | Your own copy of the application, which the agent can push to | 5 min |
| [3. Bootstrap the cluster](#3-bootstrap-the-cluster) | GitOps, Pipelines, RHOAI, the agent namespace and image | 15 min |
| [4. Deploy the remediation pipeline](#4-deploy-the-remediation-pipeline) | The Tekton Pipeline and its Tasks | 5 min |
| [5. Replay in the cluster](#5-replay-in-the-cluster) | The pipeline proven, no money spent | 10 min |
| [6. A real remediation](#6-a-real-remediation) | A pull request with its evidence | 15–20 min on a fresh cluster, 7–11 warm |
| [7. Validate in TPA](#7-validate-in-trusted-profile-analyzer-optional) | The vulnerability gone from the inventory | optional |

## 0. Try it with nothing

No cluster, no credentials, no model. Every phase is a document in and a
document out, so the whole sequence replays from recorded documents:

```bash
git clone https://github.com/lightwell-remediation/lightwell-autonomous-remediation
cd lightwell-autonomous-remediation
for s in agent-runtime/test/fixtures/scenarios/*/; do
  scripts/remediate.sh --replay "$s"
done
```

Needs `bash` and Node.js. Six scenarios: delivered, delivered after one retry,
regression after the retry, cannot verify, nothing to do, red baseline. What
each covers: [scenarios README](../agent-runtime/test/fixtures/scenarios/README.md).

## 1. Accounts and credentials

| You need | For | Path |
|---|---|---|
| An OpenShift 4.16+ cluster, cluster-admin | Everything | A and B. An RHDP OpenShift cluster works; sizing below |
| RHDP MaaS endpoint and API key | The agent's inference, on the hosted Red Hat Demo Platform MaaS | A and B. Validated with `claude-sonnet-4-6`; see [the model comparison](measurements/model-comparison-2026-10-19.md) for why |
| GitHub fine-grained PAT | Clone, push, open the pull request | A and B. Scoped to **your copy** of the application only (step 2): Contents and Pull requests read/write, Metadata read |
| Lightwell username, password, remediated repository URL and OSV records URL | Maven resolves the Lightwell rebuild; the pipeline fetches the vulnerability record | **A only** (`LW_USERNAME`, `LW_PASSWORD`, `LW_MAVEN_REPO_URL`, `LW_OSV_BASE_URL`). Without them on path A, `verify` fails with an error that looks like a bad patch |
| Trusted Profile Analyzer OIDC client | Step 7 | Optional |

Sizing: 16 CPU / 48 GiB allocatable is the floor, 32 / 128 is comfortable. No
GPU. Breakdown in [deploy/README.md — Capacity](../deploy/README.md#capacity).

Fill the credentials in, once. On path B leave the `LW_*` values empty:

```bash
cp secrets/secrets.template.env secrets/secrets.env
chmod 600 secrets/secrets.env
$EDITOR secrets/secrets.env
```

`secrets/secrets.env` is gitignored, and it is the only place real values
live. Every variable is explained in the template and in
[agent-runtime.md — Configure](agent-runtime.md#configure). Check the model
alias resolves before going further:

```bash
source secrets/secrets.env
curl -s -H "Authorization: Bearer $MAAS_API_KEY" "$MAAS_BASE_URL/v1/models"
```

## 2. The application to remediate

The agent clones the application, pushes a branch and opens a pull request, so
it needs **a repository you own**: create your own copy from a template. Never
run against the template itself.

| | Path A — with Lightwell | Path B — without Lightwell |
|---|---|---|
| Template | [`lw-apache-cxf-demo-template`](https://github.com/lightwell-remediation/lw-apache-cxf-demo-template) | [`document-intake-service`](https://github.com/lightwell-remediation/document-intake-service) |
| Your copy | **Must be private** | Private recommended |
| Why | Every pull request the agent opens shows Lightwell-only data: the rebuild's version in `pom.xml`, the Lightwell advisory id in the body | No Lightwell data, but a pull request or a leftover branch hands the next run the answer |

```bash
# Path A
gh repo create <you>/<app> --private --template lightwell-remediation/lw-apache-cxf-demo-template
# Path B
gh repo create <you>/<app> --private --template lightwell-remediation/document-intake-service
```

Set `APP_REPO=<you>/<app>` in `secrets/secrets.env` and scope the PAT to it.

After every run, on either path: **never merge** the agent's pull request,
close it, and **delete its `remediate/*` branch**. A full clone fetches
remote branches, so a leftover one gives the next run the answer.

Neither template contains the answer. The CXF template is published from our
private sample with the answer stripped from every commit
([ADR-0004](adr/0004-demo-repository-ground-truth-isolation.md),
`scripts/sync-demo.sh`); `document-intake-service` never had it
([target-app.md](target-app.md)).

## 3. Bootstrap the cluster

**Which cluster.** On the Red Hat Demo Platform, order **Field Sourced
Content – OpenShift Base**:

- Cloud provider **CNV**, SNO or multi-node, sized to the floor below.
- Base workloads: **none**. Leave *OpenShift AI 3* unchecked, because this
  bootstrap installs RHOAI 3.5 itself, and two owners of the
  DataScienceCluster fight. For a cluster that already has RHOAI, see the
  presets in [deploy/README.md](../deploy/README.md#cluster-presets).
- *Existing GitOps Repo*: unchecked. The steps below drive the bootstrap.
- For tracking: Activity *Brand Event*, Purpose *DemoJam 2027*.

That item comes with OpenShift GitOps already installed. `make deploy-all`
detects it and leaves the operator alone. It adds the cluster-admin lines to
the ArgoCD RBAC policy without replacing it, and `make validate` judges only
the Applications this bootstrap created.

```bash
oc login ...
cd deploy
make preflight      # read only: names what is missing and which preset fits
make deploy-all     # GitOps operator, Secrets, then the app-of-apps; waits
make validate       # the gate: Applications, operators, DSC, Secrets, image, smoke run
cd ..
```

If you forked this repository, point ArgoCD at the fork first, because it
reconciles from git and not from your laptop:

```bash
cp deploy/values/local.example.yaml deploy/values/local.yaml
# set bootstrap.repoURL, and cluster.domain from:
oc get ingresses.config cluster -o jsonpath='{.spec.domain}'
```

`make deploy-all` returns in about four minutes, while RHOAI and the runtime
image are still coming up on their own; the whole platform is ready about ten
minutes later (11.5 minutes in total on Field Sourced Content, 2026-10-27).
`make validate` before then reports what is still missing rather than a broken
install — run it again. `make deploy-all` is re-runnable. `make validate` is green when nine ArgoCD
Applications are Synced and Healthy, the DataScienceCluster is Ready, the
runtime image is built in the internal registry, and two agent-shaped tasks
run in parallel against MaaS. Details, presets for a cluster that already has
RHOAI, and what is deliberately not GitOps: [deploy/README.md](../deploy/README.md).

## 4. Deploy the remediation pipeline

```bash
scripts/push-secrets.sh                 # MaaS, GitHub (+ Lightwell and TPA if set)
helm upgrade --install remediation-pipeline \
  deploy/gitops/deployments/agents/remediation-pipeline \
  --namespace lightwell-agents --wait
```

The agent runtime image is already in the cluster: step 3 built it as
`lightwell-agent-runtime:<version>`, and the chart names that same version. A
version is never reused, so a run always knows which runtime it ran. If the
image is missing (a failed build), `scripts/build-runtime-image.sh` builds it. The chart is applied with Helm, not yet
by ArgoCD, while it is still changing. Why one Task per phase:
[ADR-0009](adr/0009-tekton-pipeline-orchestration.md); the full guide:
[orchestration.md](orchestration.md).

## 5. Replay in the cluster

The same six scenarios as step 0, now as PipelineRuns on the cluster. No
session starts and nothing is spent:

```bash
scripts/test-pipeline.sh
```

It checks each run's status and **which tasks were skipped**, because a run
that succeeds having skipped the work looks identical from the status alone.

## 6. A real remediation

The run takes the vulnerability record, in OSV format, as a file and mounts
it as a ConfigMap, so it does not depend on any record source being reachable
from the cluster.

**Path A.** The pipeline fetches the record from Lightwell itself, with the
credentials from step 1. Name it by its Lightwell id:

```bash
scripts/run-remediation.sh x_RHLW-CVE-2026-68079-4.2.2
```

The first phase downloads it into the run's workspace and every later phase
reads that copy; the agent never sees the credentials. The record Lightwell
serves is one advisory for every CVE the rebuild fixes — four here — so the
script takes the CVE from the id and the analysis is held to it. A record you
already have on disk works as on path B.

**Path B.** The record is public (osv.dev) and committed here:

```bash
scripts/run-remediation.sh deploy/pipelineruns/osv/GHSA-hfrx-6qgj-fp6c.json
```

The committed file is mounted, so the run needs no network to get it. If the
file is not on disk, or you pass only the id (`GHSA-hfrx-6qgj-fp6c`), the
script fetches it from osv.dev instead, with no credentials.

Watch it in the console under **Pipelines** in `lightwell-agents`. The
phases: claim → analyse → baseline → demonstrate → patch and verify (one
bounded retry) → regenerate the SBOM → deliver → outcome.

What success looks like:

- The run ends `delivered` and prints the pull request URL.
- The pull request contains the exploit test (red before the change, green
  after), the source change, the regenerated `sbom.json`, and a body that says
  what was proven and what was not.
- Path A moves Apache CXF to the Lightwell rebuild; path B moves
  `commons-fileupload` to the release the record names, plus the code change
  that turns its new limit on.
- Cost: about $1 per remediation on `claude-sonnet-4-6`
  ([measurements](measurements/model-comparison-2026-10-19.md)).

**The first run is the slowest.** On the 2026-10-27 validation, path B took 15
minutes against an empty cache and path A 19 minutes right after it. An
earlier cluster measured 48 minutes cold against 12 warm on path A, 37 of them
Maven resolving the dependency tree into an empty cache. The cache is a
PVC kept across runs and across `helm uninstall`, so warm it with one run
before a demo ([measurements](measurements/pipeline-runs-2026-10-17.md)).

## 7. Validate in Trusted Profile Analyzer (optional)

With the four `TPA_*` values set, the `sbom` task uploads the regenerated
inventory to TPA and the pull request gets an *Inventory validated in Trusted
Profile Analyzer* section: the CVE affected in the baseline, gone on the
branch. Without them the step records that there was nothing to validate
against and everything else runs unchanged.

TPA can only say the vulnerability is gone if it knows about it:

- **Path A:** the instance needs the Lightwell integration and the Lightwell
  OSV records loaded. Milestone 1 used a TPA on a separate RHDP cluster that
  already had them ([workarounds](workarounds.md)).
- **Path B:** out of scope for now. Leave the four `TPA_*` values empty; the
  run delivers without the TPA section.

Register the application's baseline once:

```bash
scripts/push-secrets.sh tpa
scripts/tpa-onboard.sh
```

## Limitations of Milestone 1

- **Single agent, no judge.** A test can assert the defect instead of the
  contract and every deterministic gate passes. The pull request names the
  test it rests on so a reviewer can read the assertion; an LLM-as-a-Judge is
  the Milestone 2 answer ([ROADMAP](ROADMAP.md)).
- **Runs start as a PipelineRun**, not from a Lightwell webhook, and there is
  no CI on the generated branch. Both are Milestone 2.
- **No Agent Sandbox / OpenShell yet.** The agent's isolation is the pod plus
  a per-role permission policy ([agent-runtime.md](agent-runtime.md)).
- **Developer Hub is scaffolded and off.**
- **The Lightwell rebuilds are credentialed.** Without a Lightwell account,
  take path B; the replays of steps 0 and 5 work on either path, since they
  use recorded phase outputs and no vulnerability record.

## When something goes wrong

| Symptom | Cause |
|---|---|
| `verify` fails resolving dependencies (path A) | `lightwell-lightwell` Secret missing or incomplete — `scripts/push-secrets.sh lightwell` |
| `LW_OSV_BASE_URL is not set` (path A) | Add it to `secrets/secrets.env`, then `scripts/push-secrets.sh lightwell` |
| `analyze` fails with "the run is for CVE-…" | The analysis picked a sibling CVE from the advisory; the gate refused it before anything was spent on a patch. Re-run |
| `run-agent.sh` rejects a role, or a gate is "not found" | The chart points at an image older than `agent-runtime/` — rebuild, step 4 |
| No Pipelines menu in the console | Console plugin not enabled: add `pipelines-console-plugin` to `console.operator.openshift.io/cluster` `spec.plugins` |
| ArgoCD Application stuck, cluster changes do not stick | It reconciles from git: push, or set `bootstrap.targetRevision` |

More: [deploy/README.md — Things that will bite you](../deploy/README.md#things-that-will-bite-you),
[orchestration.md — Things that cost time to find](orchestration.md#things-that-cost-time-to-find),
[agent-runtime.md — Troubleshooting](agent-runtime.md#troubleshooting).
