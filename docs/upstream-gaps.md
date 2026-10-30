# Upstream Gaps

Things this project had to solve on top of
[`red-hat-data-services/agentic-starter-kits`](https://github.com/red-hat-data-services/agentic-starter-kits),
the Claude Code agent we build the runtime on ([ADR-0003](adr/0003-agent-runtime-packaging-and-credentials.md)).

Each entry is either worth proposing upstream or worth re-checking before we
carry our own version of it forever. **Re-validate against a newer upstream
before assuming an entry still holds** — all of them were observed at commit
`61d2ea8` (2026-10-08) and the kit is actively maintained.

| # | Gap | Ours | Status |
|---|---|---|---|
| 1 | Plaintext credential file | credential helper, token stays in the environment | to propose |
| 2 | No honest exit status | `lib/check-result.js` | to propose |
| 3 | No model slot pinning | all slots pinned in `run-agent.sh` | to propose |
| 4 | Arbitrary-UID failures only warn | — | to report |
| 5 | `SKIP_PERMISSIONS=true` in manifests | declarative allowlist | our choice, not a defect |
| 6 | MLflow tracing is a hook, so it needs hooks enabled | transcript exported after the run, `trace-export.py` | to propose as an option |

---

### 1. The PAT is written to disk in plaintext

`deployment/entrypoint.sh` does this when `GITHUB_PAT` is set:

```bash
git config --global credential.helper store
echo "https://x-access-token:${GITHUB_PAT}@github.com" > "${HOME}/.git-credentials"
```

`$HOME/.claude` is symlinked onto the workspace volume, so on OpenShift the
token lands on the PVC, and the agent can read it. Upstream knows: their README
calls it out under *Credential Isolation* as "a known limitation of the approach
described in this guide" — so this is not a surprise bug, it is a design they
have already reasoned about.

**Propose:** a credential helper that reads the token from the environment, as
`run-agent.sh` does. Nothing reaches disk, and the repository-scoped PAT still
authenticates clone and push.

**Why it does not bite us:** we pass `GITHUB_TOKEN`, not `GITHUB_PAT`, so their
block never runs, and `.git-credentials` is in our permission denylist.

### 2. The entrypoint never inspects the session result

A Claude Code session whose every action was denied exits **0** with
`subtype: success` and a populated `permission_denials`. Their entrypoint execs
the CLI and returns its status, so a pipeline cannot tell a completed run from a
blocked one. Reasonable for their execution model — a long-lived pod a human
enters — but it makes the kit unusable as a Tekton task without a wrapper.

**Propose:** an opt-in result check, or at minimum a documented note that the
CLI exit code is not a success signal for automation.

### 3. Model slots are not pinned for gateway-served catalogs

The entrypoint passes `--model` and nothing else. Claude Code also resolves
`haiku`, `sonnet` and `opus` slots internally and uses the small slot for
background work, so against a gateway whose catalog has no such alias those
calls fail with an unknown-model error that reads like a gateway fault.

**Propose:** set every `ANTHROPIC_DEFAULT_*_MODEL` from the configured model
when a custom base URL is in play.

### 4. Arbitrary-UID failures degrade silently

Under an arbitrary UID with GID 0 — the OpenShift `restricted` SCC — the
entrypoint logs `Failed to create /workspace/projects with correct permissions`
and continues, and the later `cd /workspace/projects` failure is also only a
warning. The agent can end up working in an unexpected directory with nothing
failing.

**Report:** these two should be fatal, or the chmod should not be attempted on a
path the process does not own.

### 5. Deployment manifests disable permissions

Every manifest sets `SKIP_PERMISSIONS=true`, which passes
`--dangerously-skip-permissions`. Their README argues the case for an isolated
container, and it is a defensible default for interactive use.

This is a **disagreement, not a defect**: a demo whose claim is enterprise
guardrails cannot start by turning them off, so we deploy without it. Worth
raising only as feedback on the default.

### 6. MLflow tracing only works where hooks run

`setup_mlflow` in the entrypoint runs `mlflow autolog claude`, which writes a
Claude Code `Stop` hook. A headless runtime that isolates its sessions with
`claude --bare` skips hooks, so tracing silently never happens. Setting
`MLFLOW_TRACKING_URI` still makes the entrypoint write the service account
token into the Claude settings for that hook.

Ours: the transcript is kept per session and handed after the run to the
same function the hook calls, `mlflow.claude_code.tracing.process_transcript`
([ADR-0010](adr/0010-agent-tracing.md)), and no `MLFLOW_*` variable is set on
agent steps. Worth proposing upstream as a documented post-session mode for
`--bare` and batch use. Like the other entries, this is the right default for
the kit's interactive workstation; it is a gap only for headless use.

---

## Also worth feeding back

Not kit defects, but things the next person using it against a gateway will hit,
and which their documentation could save them: the request cap that bounds
output per reply, and the fact that the kit pins a Claude Code version older
than some of the CLI flags automation needs. Both are recorded in
[agent-runtime.md](agent-runtime.md) — Known limitations.
