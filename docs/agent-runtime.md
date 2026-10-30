# Agent Runtime

How the Milestone 1 remediation harness is configured and launched, locally and
in a container.

- **What it must do**: [`specs/platform/agent-runtime.spec.md`](../specs/platform/agent-runtime.spec.md)
- **Why it is built this way**: [ADR-0003](adr/0003-agent-runtime-packaging-and-credentials.md)
- **Why Claude Code + MaaS**: [ADR-0002](adr/0002-claude-code-maas-harness.md)

## Layout

```
agent-runtime/
├── Containerfile                   # layered on the Red Hat starter-kit image
├── build-image.sh                  # builds both images at pinned versions
├── run-agent.sh                    # same entrypoint locally and in the container
├── run-suite.sh                    # the test suite, run the same way every time
├── trace-export.py                 # sends out/traces to a backend after the run
├── claude/
│   ├── settings.json               # default role
│   ├── settings.analyze.json       # read-only: concludes, changes nothing
│   ├── settings.patch.json         # the only role that may modify the app
│   └── settings.verify.json        # measures; no shell, no writes to the repo
├── prompts/
│   ├── analyze.md                  # all three are application-agnostic
│   ├── patch.md
│   └── verify.md
├── lib/
│   ├── check-result.js             # did the session act freely?
│   ├── check-{analysis,patch,verification}.js   # did it produce usable output?
│   ├── governed-artifacts.js       # what does this version declaration move?
│   ├── test-results.js             # a test run, as a comparable list
│   ├── trace-summary.js            # what did it spend its turns on?
│   └── capture-trace.js            # keep each session's transcript in out/traces
└── test/
    ├── check-analysis.test.sh      # the gates, without spending inference
    ├── check-gates.test.sh
    └── fixtures/                   # a green analysis document, for later stages
```

## Configure

```bash
cp secrets/secrets.template.env secrets/secrets.env
chmod 600 secrets/secrets.env
```

| Variable | Required | Notes |
|---|---|---|
| `MAAS_BASE_URL` | yes | Gateway base URL, no trailing `/v1` |
| `MAAS_API_KEY` | yes | Sent as `x-api-key` |
| `MAAS_MODEL` | yes | Must exist in the MaaS catalog |
| `MAAS_SMALL_MODEL` | no | Falls back to `MAAS_MODEL` when empty |
| `GITHUB_TOKEN` | for PRs | Fine-grained PAT, scoped to `APP_REPO` only |
| `APP_REPO` | for PRs | `owner/repo` of the application to remediate |
| `LW_USERNAME` / `LW_PASSWORD` | for builds | Resolve the dependency repositories, and fetch an `--osv` URL. Never reach the agent |
| `LW_MAVEN_REPO_URL` | for builds | The Lightwell remediated repository. The application's `settings.xml` reads it as `${env.LW_MAVEN_REPO_URL}`, so the URL is in no repository |
| `TPA_URL` / `TPA_TOKEN_URL` / `TPA_CLIENT_ID` / `TPA_CLIENT_SECRET` | no | Validate the regenerated inventory in Trusted Profile Analyzer (`validate-sbom.sh`, `tpa-onboard.sh`). Read only by the `sbom` task's `validate` step; never reach the agent |
| `MAX_TURNS` | no | Default 25 |
| `TOLERATE_DENIALS` | no | `1` stops denials from failing the run |

Verify the model still resolves before relying on it — gateway aliases can be
remapped without notice:

```bash
curl -s -H "Authorization: Bearer $MAAS_API_KEY" "$MAAS_BASE_URL/v1/models" | jq '.data[].id'
```

### Creating the GitHub token

Fine-grained PATs are created in the browser
([Settings → Developer settings → Personal access tokens → Fine-grained](https://github.com/settings/personal-access-tokens)).
Scope it to the application repository **only**, with:

- **Contents**: Read and write
- **Pull requests**: Read and write
- **Metadata**: Read

Record the owner and expiry date in ADR-0003. Milestone 2 replaces this with a
GitHub App, which issues ephemeral per-installation tokens instead.

## Run

```bash
# Locally, against an existing checkout
./agent-runtime/run-agent.sh --task "Describe this repository and stop." --no-clone

# Prompt from a file, so long prompts live in version control
./agent-runtime/run-agent.sh --task @path/to/prompt.md

# A role supplies its own prompt, policy and output contract
./agent-runtime/run-agent.sh --role analyze --osv path/to/record.json

# All of them in sequence, with the baseline gate and the retry
./scripts/remediate.sh --osv path/to/record.json
./agent-runtime/run-agent.sh --role analyze --osv https://example.invalid/record.json

# Container, reproducing how OpenShift starts the pod. The build is two
# chained images; build-image.sh does both and checks the toolchain.
./agent-runtime/build-image.sh

# Source the file and pass -e, rather than --env-file. See Troubleshooting:
# podman does not strip the quotes that secrets.env needs for `source`.
set -a; source secrets/secrets.env; set +a
podman run --rm --user 61000:0 \
  -e MAAS_BASE_URL -e MAAS_API_KEY -e MAAS_MODEL -e MAAS_SMALL_MODEL \
  -e GITHUB_TOKEN -e APP_REPO -e LW_USERNAME -e LW_PASSWORD -e LW_MAVEN_REPO_URL -e MAX_TURNS \
  -v "$PWD/.workspace:/workspace:Z,U" \
  lightwell-agent-runtime --task "Describe this repository and stop." --no-clone
```

Artifacts land in `$WORKSPACE/out/` (`.workspace/out/` by default):
`result.json` and `session.log`, plus whatever the role is contracted to write.

## Roles

A role bundles three things: the prompt, the permission policy, and the output
the run is judged on. `--task` overrides the prompt; `SETTINGS_FILE` overrides
the policy.

| Role | Prompt | Policy | Must produce |
|---|---|---|---|
| `default` | `--task` required | `claude/settings.json` | — |
| `analyze` | `prompts/analyze.md` | `claude/settings.analyze.json` | `out/analysis.json` |
| `exploit` | `prompts/exploit.md` | `claude/settings.exploit.json` | `out/exploit.json` |
| `patch` | `prompts/patch.md` | `claude/settings.patch.json` | `out/patch.json` |
| `verify` | `prompts/verify.md` | `claude/settings.verify.json` | `out/verification.json` |
| `deliver` | `prompts/deliver.md` | `claude/settings.deliver.json` | `out/delivery.json` |

`exploit` writes one test meant to fail, between the baseline and patching.
Its verdict is **not its own to give**: it says what it wrote, and the runtime
runs the suite and reads `git` to decide whether that test actually fails and
whether anything else was touched. A session able to write "demonstrated"
itself would eventually write it for a test that passes, and that test would
travel onward as evidence. Its policy can write under `src/test/` and nowhere
else — not source, not the manifest.

`patch` is the only role that may modify the application. It gets `Edit`,
`Write` and a compile command, because the edit-compile-correct loop belongs
inside the session. Writing `settings.xml` is denied: with Maven available and
that file writable, a session could point the build at an arbitrary host and
have it send the Lightwell credentials there — and the repository being patched
is untrusted input.

`deliver` writes the pull request narrative and nothing else. Branching,
committing, pushing and opening the request are commands, so the runtime
issues them after the session ends — the role's policy gives it no access to
the repository, so it could not deliver anything even if it tried. A pull
request is opened only where verification reached `verified`.

`verify` has no `Bash` and cannot write into the repository at all. A capability
that can edit what it measures cannot be relied on to report what it measured,
so that is enforced rather than asked for.

Phases hand off through files in `out/`, never through session state
(`agent-runtime.spec.md` — Non-Goals), which is what lets `scripts/remediate.sh`
be replaced by Tekton without any of them changing.

Measured for `analyze` against the demo application on `claude-sonnet-4-6`
(2026-10-15), five consecutive runs of identical input:

| Turns | Tool calls | Wall time | Cost | Result |
|---|---|---|---|---|
| 9–10 | 8–9 | 45–55s | ~$0.09 | green, findings identical every time |

The full sequence (`scripts/remediate.sh`), five consecutive runs of identical
input: 133–143s end to end, every one reaching `patched`/`declaration` and
`verified` with no regression. Turns per phase: analyse 10–12, patch 9,
verify 8–9.

It did not start there. Before the runtime prepared the inputs the same role ran
41 to 108 turns and failed one run in four, which looked like model variance and
was not: a trace showed 46 tool calls, 45 of them `Read`, only four useful. The
rest were reads of directories and guessed package paths. The fix was handing it
an inventory, not a larger budget. See [ADR-0005](adr/0005-determinism-boundary.md).

`analyze` implements
[`vulnerability-analysis.spec.md`](../specs/agents/vulnerability-analysis.spec.md).
It reads and concludes. Its policy is `Read`, `Glob`, `Grep` and write access to
one output file — **no `Bash` at all**, so it cannot run a build, a shell, or
anything a repository might talk it into. It requires `--osv`.

Before the session starts the runtime prepares, into `out/`:

| File | Produced by |
|---|---|
| `source-files.txt` | `git ls-files` — every tracked path, so the agent never has to go looking |
| `dependency-tree.txt` | `mvn dependency:tree`, with `-s settings.xml` when the repository has one |
| `sbom-components.txt` | the coordinates of every component in the repository's CycloneDX SBOM, one per line |
| `governed-artifacts.txt` | every artifact the affected version declaration governs, each resolved against the remediating version (`patch`) |
| `baseline-tests.txt` | the suite on the unmodified checkout, written by the sequencer before any edit |
| `post-tests.txt`, `post-tree.txt` | the suite and the resolved tree after the change (`verify`) |
| `changed-files.txt`, `patch.diff` | what the patch touched, by status and in full (`verify`) |
| `api-signatures.txt` | `javap` over the classes the defect names and their neighbours (`exploit`) |

The prompt is also told the exact build invocation to use. Left to choose, a
measured run picked `mvn -B package` — denied, and the run ended red having
done the work correctly. The runtime already knows whether a `settings.xml` is
present, so it says so instead of leaving it to be guessed.

`api-signatures.txt` exists because a test that exercises a defect has to
construct the types the flawed class works with, and those live in a jar. A
run without it spent 28 of its 30 tool calls hunting for the dependency on
disk — `find ~/.m2`, reads of `/home`, reads of directories — and wrote
nothing.

`patch.diff` closes a hole the result lists cannot. Comparing them catches a
deleted test, but not one whose assertions were rewritten while its name
stayed: same line, same outcome, no evidence left. File status is not enough
either — adding a method to a test class marks the file modified exactly as
gutting one does. The diff shows direction, and direction is the distinction
the spec draws: lines removed from an existing test weaken the evidence, lines
only added create it.

`governed-artifacts.txt` earns its place. Without it, a run concluded that the
shared property might move a sibling with no rebuild and patched defensively,
pinning the version on one dependency. With it, the same prompt and model moved
both and produced the one-line patch. The data changed the decision.

Both exist because of [ADR-0005](adr/0005-determinism-boundary.md): what a
script can produce, a script produces. Asking the agent for them cost whole turn
budgets and hit the output-token ceiling, because a 216 KB SBOM is ~54,000
tokens and a dependency tree written through a tool call has to travel through
the model's reply.

The prompt is deliberately free of anything about a particular application —
an agent handed the answer to its test case proves nothing by passing it. The
runtime substitutes `{{OSV_PATH}}`, `{{ANALYSIS_PATH}}` and `{{TREE_PATH}}`, so
the same prompt runs unchanged on a workstation and in a pod.

### Task inputs

`--osv` accepts a path or a URL. A URL is fetched **by the runtime** before the
session exists — the same arrangement as the repository clone: the launcher
authenticates, the agent only ever sees a file. This is what lets the allowlist
keep denying outbound HTTP to the session. `LW_USERNAME`/`LW_PASSWORD` are sent
only when the URL's host is the Lightwell one (`LW_OSV_BASE_URL`, or failing
that `LW_MAVEN_REPO_URL`); a public registry such as osv.dev never receives
them.

`--vulnerability <id>` names the vulnerability the run is for when the record
bundles several, as Lightwell advisories do. The analysis gate refuses an
analysis of any other.

Inputs are validated before launch. An unreadable or malformed record is exit 2,
not a session that spends turns finding out.

## Exit status, and why it is not the harness exit code

| Code | Meaning |
|---|---|
| 0 | Session completed, nothing was denied, and the role's output contract was met |
| 1 | Session failed, exhausted its turn budget, was blocked by a denial, or produced no usable output document |
| 2 | Configuration error, including a missing or malformed task input |

The harness exits 0 for any session that reaches a terminal state — including
one where the agent was denied every meaningful action and simply reported that
it could not proceed. Measured on 2026-10-06:

```
subtype = 'success'   is_error = False   exit code = 0
permission_denials = [{'tool_name': 'Bash', ... 'command': 'curl -s https://example.com'}]
```

A pipeline trusting the exit code alone would mark that run green. So
`lib/check-result.js` inspects `permission_denials` and fails the run, naming
the denied command. Exhausting `--max-turns` does already produce exit 1
(`subtype: error_max_turns`), so that case needs no special handling — it is
checked anyway for a clearer message.

That check answers "was the session free to act". It does not answer "did the
session conclude anything": an agent can be denied nothing, stay inside its turn
budget, write a thorough explanation, and leave no document behind.
`lib/check-analysis.js` holds roles with an output contract to it, and fails a
run whose document is missing, unparseable, carries no recognised terminal
state, or contradicts itself — `remediable` with no remediating version being
the contradiction a model reaches for most readily.

Both gates are unit-tested without an agent:

```bash
./agent-runtime/test/check-analysis.test.sh   # 8 cases
./agent-runtime/test/check-gates.test.sh      # 23 cases
```

The branches the demo application never takes need an agent, so they live
apart and cost a session each:

```bash
./agent-runtime/test/fixtures.test.sh [--dns <server>] [case ...]
```

A governed sibling with no rebuild, a deleted baseline test, a gutted one, a
test added beside a source change, and a genuine regression. They are real
repositories with real manipulations: the runtime regenerates the result files
by running the suite, so fabricating them would prove nothing. Both defects
found during this work — `set -e` killing the run on a red post-change suite,
and a gutted test passing the comparison unnoticed — came from here, and
neither is reachable on the happy path.

## Seeing what a session did

The session is captured as `out/session.jsonl` (`--output-format stream-json`),
and the result document is extracted from its last event — so the gates above
are unchanged, and the trace costs nothing extra.

`lib/trace-summary.js` prints a breakdown on every run, green ones included:

```
run-agent: tool calls (8 across the session)
run-agent:      7  Read
run-agent:      1  Edit
```

This exists because the result document says what a session spent and never what
it spent it on. A run exhausting its budget looks identical whether it was
blocked, looping, or paging through a large file. Every diagnosis made from that
summary alone turned out wrong; the worst offender — an agent reading directories
and guessing package paths — was found within one run of the trace existing.

Every session also leaves its harness transcript in `out/traces/`, numbered
so that no role and no retry overwrites another (`out/session.jsonl` is
rewritten by each role):

```
out/traces/01-analyze.jsonl       out/traces/01-analyze.meta.json
out/traces/02-exploit.jsonl       out/traces/02-exploit.meta.json
out/traces/03-patch.jsonl         out/traces/03-patch.meta.json   # attempt 1
out/traces/04-patch.jsonl         out/traces/04-patch.meta.json   # attempt 2
```

The metadata names the harness and its version, the transcript format, role,
attempt, model, turns, cost, exit status and the role document's terminal
state. Capture runs from an `EXIT` trap, so failed sessions are kept too, and
it never changes the exit status. See Observability for where these go.

Repeated targets are listed separately: `Read ×40` of one file is a file being
paged through, while forty different files is an agent that does not know where
to look.

To dig past the summary:

```bash
python3 -c 'import json,sys
for l in open(".workspace/out/session.jsonl"):
    e=json.loads(l)
    if e.get("type")!="assistant": continue
    for b in e["message"]["content"]:
        if b.get("type")=="tool_use": print(b["name"], b.get("input"))'
```

## Observability

### Agent traces in MLflow

Contract: [`agent-tracing.spec.md`](../specs/observability/agent-tracing.spec.md).
Decision: [ADR-0010](adr/0010-agent-tracing.md).

The traces in `out/traces/` are sent to a backend by the Pipeline's `trace`
task, which runs in `finally` (so failed runs are traced too) and always exits 0.
The backend is `tracing.exporter` in the pipeline chart: `none` by default,
`mlflow` on the platform bootstrap (`agents.tracing.exporter` in
`deploy/gitops/bootstrap-infra/values.yaml`, which requires `platform.mlflow`).

| In MLflow | Value |
|---|---|
| Workspace | the agent namespace, `lightwell-agents` |
| Experiment | `lightwell/<pipelinerun>` |
| Session | `<pipelinerun>-<role>` (`-<candidate>` when a role has several) |
| Trace | one per session attempt, with `lightwell.*` tags: role, attempt, harness, model, turns, cost, exit status, terminal state |

How it works, and why not the starter kit's way: the starter kit traces with
`mlflow autolog claude`, a Claude Code `Stop` hook, but sessions here run with
`claude --bare`, which skips hooks. `trace-export.py` calls the same function
that hook calls, `mlflow.claude_code.tracing.process_transcript`, on the kept
transcript, with our session id. Readers are keyed by transcript format, so a
second harness is one more reader, and an OpenTelemetry backend is one more
exporter.

Identity: the `trace` task runs as `lightwell-tracer`, bound to the RHOAI
ClusterRole `mlflow-operator-mlflow-integration` (MLflow pseudo-resources
only). `run-remediation.sh` and `test-pipeline.sh` bind it with
`taskRunSpecs` when the account exists. No `MLFLOW_*` variable is set on agent
steps, and the agent's account still holds no Role.

To export by hand, for example from a workstation against the route:

```bash
export MLFLOW_TRACKING_URI=https://<mlflow-route>/mlflow
export MLFLOW_TRACKING_TOKEN=$(oc create token lightwell-tracer -n lightwell-agents)
export MLFLOW_WORKSPACE=lightwell-agents
.venv/bin/python agent-runtime/trace-export.py --exporter mlflow \
  --traces .workspace/out/traces --run local-$(date +%Y%m%d%H%M)
```

The client is the one in the base image (MLflow 3.12.0). `process_transcript`
is part of MLflow's Claude Code integration rather than a stable API, so a
base image bump that moves the client re-runs `agent-runtime/test/trace-capture.test.sh`.

### Harness telemetry

Two telemetry channels, often confused:

| Channel | Destination | Controlled by | State |
|---|---|---|---|
| Vendor telemetry | Harness vendor | `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING` | Disabled |
| OpenTelemetry export | Your collector | `CLAUDE_CODE_ENABLE_TELEMETRY=1` + `OTEL_*` | Opt-in, unset |

Disabling the first is not documented to disable the second. This has **not
been verified on this project yet** — see ADR-0003 Validation. Claude Code's
OTel traces (as opposed to metrics) need `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1`
and are beta ([monitoring-usage](https://code.claude.com/docs/en/monitoring-usage)).
Metrics such as `claude_code.cost.usage` and `claude_code.token.usage` remain a
candidate for the future OpenTelemetry exporter path (Red Hat build of
OpenTelemetry → Tempo / Prometheus), ADR-0010.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `MAAS_BASE_URL is not set` | `secrets/secrets.env` missing or still has `CHANGE_ME` |
| Unknown-model errors mid-session | A model slot points outside the catalog — set `MAAS_SMALL_MODEL` or leave it empty |
| Traffic reaches the vendor, not MaaS | Provider variables leaked in; the wrapper unsets them, a direct `claude` call does not |
| Permission errors on `$HOME` in a pod | `HOME` and `CLAUDE_CONFIG_DIR` must be set and group-writable — see the Containerfile |
| Run is green but nothing changed | Check `permission_denials` in `result.json`; the allowlist is probably missing the build command |
| `setresuid: Invalid argument` with podman | Rootless podman cannot map UIDs outside `/etc/subuid`; use a UID inside the range |
| 401 from a service the same credential authenticates against from the host | `--env-file` was used. See below |
| Maven: `Unknown host` for the Lightwell repository in the container, while the host resolves it | The container's DNS. See below |
| `unknown option '--permission-prompts'` | Claude Code older than the minimum below — rebuild the image with a newer `CLAUDE_CODE_VERSION` |
| `API Error: Connection dropped (ECONNRESET)`, with `duration_ms` far above `duration_api_ms` | The MaaS request cap, below. The gap is retry backoff, not thinking |
| A `gh` or build command is denied although the allowlist covers it | The agent wrote it across several lines with `\`; see the permission limitation below |

### Quoted secrets and `--env-file`

`secrets/secrets.env` quotes `LW_USERNAME` and `LW_PASSWORD` because the
credential is a token containing shell metacharacters: without quotes, `source`
lets bash interpret part of it (`demojan: command not found`, and a truncated
value).

`podman --env-file` reads the file itself and **does not strip quotes**, so the
container receives `"ey..."` instead of `ey...`. Everything that needs no
authentication keeps working — Maven resolves from Central, the suite passes —
and only the authenticated requests fail, with a 401 from an endpoint the same
credential reaches from the host with `curl`. The two consumers of one file
want incompatible formats.

Source the file and pass `-e VAR`, which takes the value from the already
parsed environment:

```bash
set -a; source secrets/secrets.env; set +a
podman run -e LW_USERNAME -e LW_PASSWORD … 
```

`run-agent.sh` refuses to start when a credential still carries its quotes, so
the mistake fails loudly instead of as an authentication error.

### The Maven cache

`remediate.sh` keeps it at `~/.cache/lightwell/m2`, outside the workspace, so
consecutive runs and runs in different workspaces reuse it. `--maven-cache`
points somewhere else.

It is outside the workspace because a cold cache downloads the whole
dependency tree first: over fifteen minutes against roughly two warm, which is
most of a run. In-cluster this has to be a volume rather than anything tied to
the run (ROADMAP Phase 2 — Running it in the cluster).

### Container DNS

The container inherits the host's resolvers, and on a workstation those can be
a link-local address and a corporate server that are unreachable from podman's
network namespace. The symptom is Maven reporting `Unknown host` for the
Lightwell repository while the host resolves it fine, and it hides until the
Maven cache goes cold — a warm `~/.m2` needs no network at all.

```bash
podman run --dns 1.1.1.1 …
```

Local only. In-cluster, egress is a NetworkPolicy question (ROADMAP Phase 2 —
Running it in the cluster).

## Known limitations

Measured against MaaS on 2026-10-09, during the first end-to-end remediation run.

**The gateway drops any request past roughly 60 seconds**, streaming or not — it
buffers rather than streaming incrementally. Usable output per request is
therefore `throughput × 60s`:

| Model | Throughput | Usable output |
|---|---|---|
| `claude-sonnet-4-6` | ~44 tok/s | ~2,600 tokens |
| `qwen38-27b` | ~22 tok/s | ~1,300 tokens |
| `gpt-oss-120b` | cut before first token | unusable |

The runtime therefore pins `CLAUDE_CODE_MAX_OUTPUT_TOKENS`: 2048 for `analyze`,
4096 for the roles that write code (`exploit`, `patch`, `verify`, `deliver`),
because a test class does not fit in 2048 and 4096 was measured to finish
inside the window on `claude-sonnet-4-6`. A reply past the cap is refused, not
truncated: the session stops with `api_error` and the phase fails. The prompts
ask for files to be written in pieces, which the model does not always do —
one `demonstrate` failure in two path B runs on 2026-10-27. The Pipeline
therefore retries `demonstrate` once, only after that refusal and only on an
untouched checkout, and re-runs the `patch` session once on the same terms
(seen on a path A run on 2026-10-27, after the demonstrate retry existed). The
`patch` prompt also asks for existing files to be changed with Edit, a few
lines at a time, rather than rewritten ([orchestration.md](orchestration.md)). Left alone,
Claude Code asks for 32,000 and every long reply dies on the wall, surfacing as
a retry storm rather than a clear error. Raise it only after measuring the model
you pinned. Model choice is likewise a throughput decision, not a price one.

This is an infrastructure limit; raising the route timeout on the MaaS instance
removes it.

| Also known | |
|---|---|
| Minimum Claude Code version | `--permission-prompts none` does not exist before 2.1.2xx. The upstream image pins 2.1.123; the bootstrap builds it with `claudeCodeVersion` from `deploy/gitops/bootstrap-infra/values.yaml` (2.1.295) |
| Permission rules match a prefix | A command the agent wrote across several lines with `\` is denied even when the allowlist covers it. Prompts must ask for single-line commands and pass long arguments by file |
| Only the happy path is tested | Untested: a build still failing after the patch, a vulnerability the agent cannot fix, multi-module repositories, and defects with no dependency to bump |

## Not decided here

How multiple agents are coordinated — pipeline task per agent, or an
orchestrator agent. The runtime takes the role as a parameter and passes state
through files precisely so that choice stays open. Tracked as a Phase 2
prerequisite in [ROADMAP](ROADMAP.md).
