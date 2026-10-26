# ADR-0003: Agent Runtime Packaging and Credential Model

## Status
Accepted

## Date
2026-10-09

## Layer
Platform

## Context

[ADR-0002](./0002-claude-code-maas-harness.md) selected Claude Code with Red Hat
MaaS as the Milestone 1 harness, but validated it only through `curl` and one
interactive session from a laptop. Wrapper and secrets wiring still had to be
added before CI and Tekton could use it.

Three packaging questions must be answered before Phase 2 can scaffold agents:
what the container image is built on, how the agent authenticates to GitHub, and
how the agent's tool permissions are expressed. Milestone 2 will move execution
into Agent Sandbox and OpenShell, so choices made now should not have to be
reversed then.

The first question changed shape once Red Hat Data Services published
[`agentic-starter-kits`](https://github.com/red-hat-data-services/agentic-starter-kits)
(Apache-2.0, actively maintained), which includes a Claude Code agent for
OpenShift: image, entrypoint, deployment manifests, MLflow tracing and an
OpenShell variant — the last two being Milestone 2 roadmap items. For a Red Hat
DemoJam, building a parallel runtime beside the official kit is both more work
and a weaker story. The kit is built for a different execution model, though: a
long-lived Deployment entered with `oc exec`, not a one-shot process a Tekton
task runs and judges by exit code.

Behavior requirements live in
[`specs/platform/agent-runtime.spec.md`](../../specs/platform/agent-runtime.spec.md).

## Options Considered

### Option 1: Our own base image

- **Pros:** Full control; no external coupling; smallest result (955 MB)
- **Cons:** We maintain the base, the Claude Code install and every OpenShift
  manifest; MLflow and OpenShell would be built from scratch for Milestone 2; no
  Red Hat provenance in the demo narrative
- **GA / support status:** N/A — our artifact

A UBI9 Node.js base was the only serious candidate here: `node:22-slim` is not a
Red Hat supported base and adds Docker Hub rate limits to RHDP replicability,
and Anthropic's devcontainer feature targets developer workstations, assuming a
fixed user and writable home that conflict with arbitrary-UID execution.

### Option 2: The starter kit as-is

- **Pros:** Official, maintained, batteries included
- **Cons:** The image has no `gh`, Java or Maven, so it cannot run the
  remediation loop at all; the entrypoint never inspects the session result, so a
  Tekton task could not tell success from failure; no model slot pinning and no
  provider isolation, both of which MaaS routing depends on; the deployment
  manifests set `SKIP_PERMISSIONS=true`, the opposite of this project's
  guardrails narrative
- **GA / support status:** Apache-2.0, Red Hat Data Services

### Option 3: Extend the starter kit, keep our pipeline layer

- **Pros:** Inherits base, entrypoint, MLflow, OpenShell and manifests; keeps the
  three pieces upstream has no equivalent for; the only gap is the language
  toolchain, which upstream documents how to add
- **Cons:** Image grows to 2.22 GB; two build stages; coupled to upstream's
  `CLAUDE_CODE_VERSION` build argument
- **GA / support status:** As Option 2

### Option 4: Fine-grained PAT scoped to one repository

- **Pros:** Minimal blast radius — the agent cannot write outside the application
  repository; no token exchange step in the pipeline
- **Cons:** Tied to an individual's GitHub account; manual rotation; expiry must
  be tracked
- **GA / support status:** GA

### Option 5: GitHub App

- **Pros:** Ephemeral installation tokens; per-repository installation; pull
  requests attributed to a bot identity rather than a person
- **Cons:** More initial setup, plus a token-exchange step in every pipeline run
- **GA / support status:** GA

### Option 6: Version-controlled permission file vs. inline flags

- **Pros (file):** Permission changes appear as a reviewable diff in a pull
  request; the file is the direct ancestor of Agent Sandbox and NeMo Guardrails
  policy
- **Cons (file):** One more artifact to keep aligned with the application's
  build toolchain
- **GA / support status:** N/A — harness configuration

## Decision

Build the agent image **on top of** the upstream Claude Code image rather than
maintaining our own base, and keep our runtime as a thin layer over their
entrypoint:

| Component | Source |
|---|---|
| Base image, Claude Code install, MLflow, OpenShell | Upstream |
| `entrypoint.sh` — onboarding, git credentials, MCP, skills | Upstream |
| OpenShift manifests | Upstream, **without** `SKIP_PERMISSIONS=true` |
| Language toolchain (`gh`, `java-21`, `maven`) | Ours, via upstream's documented extension path |
| `run-agent.sh` — MaaS routing, model slot pinning, provider isolation | Ours |
| `claude/settings.json` — declarative permissions | Ours, mounted as a ConfigMap |
| `lib/check-result.js` — honest exit status | Ours |

Extend by **layering** (`FROM` the upstream image) rather than by forking their
Containerfile, so upstream changes arrive without merge conflicts. In OpenShift
this is two chained BuildConfigs. The image runs non-root under an arbitrary UID
with GID 0, driven by a single wrapper script used identically on a laptop and
in a container.

Authenticate to GitHub with a **fine-grained personal access token scoped to the
application repository only** (`Contents: Read and write`, `Pull requests: Read
and write`, `Metadata: Read`). Migrate to a GitHub App in Milestone 2, when
pipeline-driven token exchange is already required.

Express agent tool permissions in a **version-controlled settings file**.
Bypassing the permission system wholesale is prohibited: it would discard the
control surface that Agent Sandbox and NeMo Guardrails later build on.

The runtime is **orchestration-agnostic** by construction — the agent role is an
invocation parameter and state passes between phases through files — so
`orchestration-strategy.spec.md` can be decided later with empirical data rather
than up front.

What upstream lacks that is not specific to us, and what we would propose back,
is tracked in [upstream-gaps.md](../upstream-gaps.md).

## Consequences

### Positive

- Unblocks ROADMAP Phase 2 ("Scaffold agents with the chosen harness")
- The demo stands on the official Red Hat agentic kit rather than beside it, and
  MLflow tracing and OpenShell arrive with the base instead of being Milestone 2
  work
- Same wrapper runs locally and in a container, so a prompt debugged on a laptop
  behaves identically in the pipeline
- Arbitrary-UID compatibility means the image is already Agent Sandbox ready
- The permission file makes the agent's blast radius reviewable in a pull request
- Model configuration is fully externalized, so Milestone 2 can run two agents on
  different MaaS models from one image

### Negative

- The image roughly doubles, to 2.22 GB, mostly JDK and Maven
- Upstream forbids redistributing built images, because they contain Anthropic's
  proprietary binary. Each environment builds its own, which shapes how RHDP
  replicability is presented
- The fine-grained PAT is tied to an individual's account and needs an owner and
  a rotation date
- Harness features that depend on vendor feature-flag fetching are unavailable
  once non-essential traffic is disabled
- The permission allowlist must be revisited once the Phase 1 application fixes
  the build toolchain

### Neutral

- Session configuration persists on the workspace PVC through upstream's
  `~/.claude` symlink rather than in `$HOME`

## Version Pinning

| Component | Pinned version | Where enforced |
|---|---|---|
| Base image | upstream `agentic-starter-kits` Claude Code image | `agent-runtime/Containerfile` |
| Claude Code CLI | `CLAUDE_CODE_VERSION` build arg — must be set explicitly, see [agent-runtime.md](../agent-runtime.md) | upstream Containerfile |
| `gh` CLI | pinned via `GH_VERSION` build arg | `agent-runtime/Containerfile` |
| MaaS model | `MAAS_MODEL` | `secrets/secrets.env`, pipeline Secret |

## Demo Impact

The containerized runtime is what makes the demo replicable on RHDP. Without it
the story is a session on one laptop, which neither the judges nor another team
can reproduce. Building on the official Red Hat kit strengthens that further.
The permission file is a concrete artifact to show when claiming "enterprise
guardrails" before NeMo Guardrails exists.

## Validation

**2026-10-06** — harness v2.1.291, podman on Fedora 44:

- **Session result semantics.** A `-p` run shows no workspace trust dialog.
  Exhausting `--max-turns` exits 1 with `subtype: error_max_turns`. A session
  whose actions were all denied exits **0** with `subtype: success`,
  `is_error: false`, and a populated `permission_denials` array — the silent
  failure the runtime guards against.
- **Exit-status logic**, 6 cases against captured harness output. **Configuration
  errors** exit 2 naming the missing variable. `shellcheck` clean.
- **Non-root execution.** Under a UID that owns nothing in the image and has
  GID 0, the harness started and wrote its configuration into
  `CLAUDE_CONFIG_DIR`, and `/workspace` was writable.

**2026-10-09** — upstream commit `61d2ea8`, against the real MaaS gateway:

- **The MaaS path works.** Catalog, `/v1/messages` and tool calling all
  verified. Model slots resolve: only the pinned model appears in `modelUsage`.
- **A non-Claude MaaS model works** (`qwen38-27b`), which answers ADR-0002's
  open question without MiniMax-M2 access.
- **Upstream image** builds, runs under an arbitrary UID, and honours
  `ANTHROPIC_BASE_URL` — traffic confirmed reaching the configured endpoint
  rather than the vendor, by logging the requests it made.
- **Extended image** carries OpenJDK 21, Maven 3.9.9, `gh` 2.63.2 and Node, and
  Maven writes to `~/.m2` under an arbitrary UID.
- **A full remediation ran end to end on it**: clone, exploit test, patch,
  `mvn test`, commit, push, pull request. The resulting tests were verified
  independently in a clean container rather than taken from the agent's report.

Still not verified:

- **Truly absent `/etc/passwd` entry**: the test host resolves unknown UIDs
  through systemd-userdb, so an entry was always present. OpenShift nodes may
  not.
- **Telemetry independence**: whether OpenTelemetry export to an own collector
  survives with vendor-bound telemetry disabled.
- **Failure paths**: a build still failing after the patch, a vulnerability the
  agent cannot fix, multi-module repositories.

Constraints found while validating — the MaaS request cap, the minimum Claude
Code version, and permission prefix matching — are recorded in
[`docs/agent-runtime.md`](../agent-runtime.md) under Known limitations.

## Related Decisions

- [ADR-0002: Claude Code + Red Hat MaaS Harness](./0002-claude-code-maas-harness.md)

## References

- [red-hat-data-services/agentic-starter-kits](https://github.com/red-hat-data-services/agentic-starter-kits)
- [Claude Code on OpenShift](https://github.com/red-hat-data-services/agentic-starter-kits/blob/main/agents/claude-code/README.md)
- [Claude Code — LLM gateway configuration](https://code.claude.com/docs/en/llm-gateway-connect)
- [Claude Code — environment variables](https://code.claude.com/docs/en/env-vars)
- [Claude Code — headless mode](https://code.claude.com/docs/en/headless)
- [OpenShift — support arbitrary user IDs in images](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/images/creating-images#images-create-guide-openshift_create-images)
- [GitHub — fine-grained personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
