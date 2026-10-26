# PipelineRuns

Deliberately **outside** `deploy/gitops/`.

A PipelineRun is a record of something that happened. Under ArgoCD, one in a
managed path is permanent drift: it completes, reconciliation notices the
live object no longer matches, and the application never reports healthy
again. Tasks and the Pipeline are GitOps-managed; runs are created
imperatively, or by a trigger when there is one.

These are templates. They use `generateName`, so each `oc create` produces a
new run.

## A real run

```bash
oc create -f deploy/pipelineruns/remediate.yaml
```

Edit `application` and `osv` first, and read `params` — the model is an
invocation parameter, not deployment configuration.

Prerequisites, both of which produce misleading errors when missing:

- The **image tag** in the chart's values must be one built from the current
  `agent-runtime/`. An older tag silently lacks roles, and `run-agent.sh`
  fails with an unrecognised role rather than with anything about the image.
- The **`lightwell-lightwell` Secret** (`LW_USERNAME`, `LW_PASSWORD`, `LW_MAVEN_REPO_URL`) must
  exist in the namespace. Without it Maven cannot resolve the Lightwell
  rebuild, and `verify` fails with a dependency resolution error that reads
  like a bad patch.

## A replay

```bash
scripts/test-pipeline.sh                 # every scenario
scripts/test-pipeline.sh delivered       # one of them
```

The script creates the scenario's ConfigMap, starts the run, and checks the
status **and** the skipped tasks. Starting one by hand is possible —
`replay.yaml` is the template — but then nothing is asserted.

A replay starts no session and needs no MaaS, GitHub or Lightwell
credentials.

## Two annotations that matter

- `tekton.dev/auto-cleanup-pvc: "true"` — without it the run's
  `volumeClaimTemplate` claim **outlives the run** under this cluster's
  affinity assistant mode, and the workspace is not per-run at all. Two
  orphans were already in the namespace before anyone looked.
- `lightwell.dev/application` as a **label** — the one-run-per-application
  claim lists on it. A run without it is invisible to the claim and to every
  later run's claim, so two concurrent remediations of one repository become
  possible again.
