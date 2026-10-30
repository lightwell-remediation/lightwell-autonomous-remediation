# ADR-0010: Capture Agent Traces in the Session, Export Them After the Run

## Status

Accepted

## Date

2026-10-30

## Layer

Observability

## Context

[`agent-tracing.spec.md`](../../specs/observability/agent-tracing.spec.md)
asks that every agent session leave an inspectable trace and that a backend
such as MLflow receive them, grouped as one experiment per PipelineRun and one
session per role. The backend has to be optional, an OpenTelemetry one has to
be addable later, and the contract has to hold for a harness other than
Claude Code. The spec names no mechanism. This ADR picks one.

Facts that shape the choice, all checked on the pinned stack
(`agentic-starter-kits@61d2ea8`: Claude Code 2.1.295, MLflow 3.12.0 client;
MLflow server on RHOAI as the `mlflow` CR):

**The starter kit's tracing is a hook, and our sessions run without hooks.**
Upstream enables tracing with `mlflow autolog claude`, which writes a Claude
Code `Stop` hook into the settings (`entrypoint.sh`, `setup_mlflow`).
`run-agent.sh` starts every session with `claude --bare`, which per
`claude --help` skips "hooks (those defined in settings and by installed
plugins)", along with CLAUDE.md, plugins and MCP. That isolation is
deliberate — it keeps a cloned repository's CLAUDE.md, hooks and MCP servers
out of the session — and it is recorded only in a comment in `run-agent.sh`.
This ADR is where it starts having a consequence worth writing down: the
upstream path never fires, and turning `--bare` off to make it fire would
give up the isolation for observability.

**`--bare` still writes the native transcript.** Each session leaves
`$CLAUDE_CONFIG_DIR/projects/<escaped-cwd>/<sessionId>.jsonl`, the same file
the hook would have read.

**The hook's work is one public function.** It calls
`mlflow.claude_code.tracing.process_transcript(transcript_path, session_id)`,
which builds the AGENT / LLM / TOOL span tree with token usage and previews
and sets `mlflow.trace.session`. Called directly, after the session, it gives
the same trace without a hook, with a session id of our choosing.

**Claude Code has no MLflow integration of its own, and its OpenTelemetry
traces are beta.** Traces need `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1`, prompt
and tool content each need a further opt-in, and the documentation does not
say whether `DISABLE_TELEMETRY` or `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`
— both set by `run-agent.sh` — suppress a custom exporter
([monitoring-usage](https://code.claude.com/docs/en/monitoring-usage)).
MLflow's OTLP endpoint needs the experiment *id* in an
`x-mlflow-experiment-id` header, so the per-run experiment must exist before
the session starts, and nothing documented maps Claude Code's `session.id`
attribute onto `mlflow.trace.session`
([MLflow OTLP ingest](https://mlflow.org/docs/latest/genai/tracing/opentelemetry/ingest-shared)).

**MLflow on RHOAI authenticates through Kubernetes RBAC.** The client sends a
service account token. The server checks it against pseudo-resources in
`mlflow.kubeflow.org`, which the operator's ClusterRole
`mlflow-operator-mlflow-integration` grants (experiments get/list/create/update).
In-pod access uses the service URL with the service CA
([upstream: MLflow on OpenShift, auth and TLS](https://github.com/red-hat-data-services/agentic-starter-kits/blob/main/docs/mlflow-openshift-auth-and-tls.md)).
The agent's service account holds no Role, by
[ADR-0009](0009-tekton-pipeline-orchestration.md).

## Options

### A. The starter kit's hook

Drop `--bare`, or replicate its isolation by hand, and let `mlflow autolog
claude` install the `Stop` hook.

- **Pros:** zero code of ours; traces arrive live, session by session; it is
  exactly what upstream ships.
- **Cons:** the deciding one is functional: under `--bare` the hook never runs.
  `--bare` exists so nothing from the cloned repository shapes the session.
  Rebuilding that isolation flag by flag to let one hook back in is fragile,
  and nothing reports it when it breaks. The second con is a moderate risk,
  not a severe one. The hook runs in the session's pod under the agent's
  identity, so `lightwell-agent` would need the MLflow role. The session can
  already read that account's token (it is automounted). What keeps that
  harmless today is that the account holds no Role. With the role, a prompt
  injection in the code under remediation could create or overwrite traces
  and experiments: no cluster access, but it could forge the record meant to
  audit the agent. Claude Code only; a second harness needs a second
  mechanism.
- **Why upstream chose it anyway:** the starter kit's Deployment is an
  interactive workstation (`sleep infinity`, then `oc exec -it`). A trusted
  person drives the session on their own code, the namespace and MLflow are
  theirs, and hooks are enabled. In that threat model the hook is the right
  call. Ours differs: a headless session running model-chosen commands over
  third-party code.

### B. Claude Code's native OpenTelemetry export, in the session

`CLAUDE_CODE_ENABLE_TELEMETRY=1` plus the beta traces flag, exporting to
MLflow's `/v1/traces` or to a Red Hat build of OpenTelemetry collector.

- **Pros:** live; vendor-supported spans; the natural route to Tempo, and
  Red Hat-first for the OTel half.
- **Cons:** beta, and its interaction with the vendor-traffic switches we set
  is undocumented. The credential (bearer token) and endpoint end up in the
  session's environment. The experiment has to be created before the session.
  No documented mapping to MLflow sessions, so the grouping the spec asks for
  would need a collector processor of our own. Claude Code only.

### C. Capture in the session's pod, export after the run

`run-agent.sh` keeps each session's transcript and a metadata record in the
run's workspace. A `finally` task in the Pipeline, under its own service
account, reads them and hands them to the selected backend.

- **Pros:** the session never sees a backend credential and the agent's
  identity gains nothing. Failed and cancelled runs are exported because
  `finally` runs regardless. Capture is identical for every backend, so an
  OTel backend is a new exporter, not a change to the runtime. A new harness
  is a new transcript reader. Backend off means nothing extra is deployed.
  Reuses MLflow's own span builder, so no span code of ours.
- **Cons:** traces appear when the run ends, not as it runs. One more Task and
  one more service account. We depend on `process_transcript`, an MLflow
  function documented as part of its Claude Code integration rather than as a
  stable API, so it is pinned with the client version.

## Decision

**Option C.**

- **Capture is always on and backend-agnostic.** Each session's native
  transcript is copied to `out/traces/<NN>-<role>.jsonl` with a sidecar
  `<NN>-<role>.meta.json` (role, attempt, candidate, harness and version,
  model, turns, cost, terminal state). `NN` increases per session so retries
  never overwrite. Capture is best effort and never fails a phase.
- **Export is a `finally` task, `trace`**, beside `outcome`. It is off by
  default (`tracing.exporter: none` in the pipeline chart). It runs on the
  agent image, which already carries Python and the MLflow client. It holds no
  Secret.
- **Exporters are a dispatch on `tracing.exporter`**: `mlflow` now, `otel`
  later. Each exporter reads traces through a **reader per harness**, keyed by
  the `harness` field in the metadata: `claude-code` now. A trace with no
  reader is logged, left in the workspace and skipped. Any export error is
  logged and the task exits 0.
- **MLflow mapping**: experiment `lightwell/<pipelinerun>` tagged with the
  application, record and model. Session `<pipelinerun>-<role>`, with a
  `-<candidate>` suffix only when a run has more than one candidate for a role.
  Trace tags carry role, attempt, candidate, harness, model, turns and cost.
  The `claude-code` reader is `process_transcript` with our session id.
- **Identity**: service account `lightwell-tracer`, rendered only when an
  exporter that needs it is selected, with a RoleBinding to
  `mlflow-operator-mlflow-integration` in the agent namespace. It is bound to
  the `trace` task with `taskRunSpecs`, as `claim-application` is. Auth is
  `MLFLOW_TRACKING_AUTH=kubernetes-namespaced`, endpoint
  `https://mlflow.redhat-ods-applications.svc:8443/mlflow`, verified against
  the service CA.
- **No `MLFLOW_*` variable is set on agent steps.** `MLFLOW_TRACKING_URI`
  would make the starter kit's entrypoint run `mlflow autolog claude` and write
  the service account token into the workspace's Claude settings, for a hook
  that never runs.

### The OpenTelemetry path, when it comes

An `otel` exporter converts the same traces into OTLP spans and sends them to
a Red Hat build of OpenTelemetry collector, which can fan out to Red Hat build
of Tempo and to MLflow's `/v1/traces`. It runs in the same `finally` task with
its own identity, so nothing in this decision changes. Live, in-session export
(option B) can be revisited once Claude Code's traces leave beta. The test is
whether it can be done without a credential in the session's environment,
for example through a node-local collector.

## Consequences

### Positive

- The spec's requirements are met without weakening the session's isolation
  or the agent's identity.
- MLflow is genuinely optional: with `exporter: none` the chart renders no
  service account, no RoleBinding and no network path.
- Adding OpenTelemetry, or a second harness, is additive: one exporter or one
  reader.
- The workspace keeps per-session transcripts. Before this decision each role
  overwrote `out/session.jsonl`, so only the last session of a run survived.

### Negative

- No live view: a run's traces appear when it ends. The Pipelines console
  remains the live view ([`pipeline.spec.md`](../../specs/devsecops/pipeline.spec.md)
  — A Run Is Watched).
- A second non-agent identity in the namespace, beside the claim's. Its scope
  is the MLflow pseudo-resources only. It cannot touch Kubernetes objects.
- One experiment per run produces many experiments. Comparing runs means
  searching by tag rather than browsing one experiment.
- `process_transcript` moves with the MLflow client. A base-image bump that
  changes the client re-runs the tracing check.

### Neutral

- The runtime image changes (capture and the exporter script), so its version
  is bumped by the `runtime-image-version` procedure.
- ADR-0009's statement that the agent's service account holds no Role stays
  true. This ADR adds a second identity beside the claim's, by the same
  reasoning.

## Validation

To be completed when implemented: capture test without inference, a replay
run with export enabled (nothing to send, exit 0), and one real run whose
experiment shows a session per role.

## References

- [`agent-tracing.spec.md`](../../specs/observability/agent-tracing.spec.md)
- [ADR-0009](0009-tekton-pipeline-orchestration.md) — identities in the Pipeline, `finally` tasks
- [ADR-0003](0003-agent-runtime-packaging-and-credentials.md) — runtime layered on the starter kit
- [ADR-0005](0005-determinism-boundary.md) — runtime does what is computable, not the session
- MLflow, Claude Code tracing: https://mlflow.org/docs/latest/genai/tracing/integrations/listing/claude_code
- MLflow, OTLP ingest: https://mlflow.org/docs/latest/genai/tracing/opentelemetry/ingest-shared
- Claude Code, monitoring: https://code.claude.com/docs/en/monitoring-usage
- Red Hat OpenShift AI documentation: https://docs.redhat.com/en/documentation/red_hat_openshift_ai/
