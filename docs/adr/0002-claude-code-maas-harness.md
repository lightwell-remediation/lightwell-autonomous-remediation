# ADR-0002: Use Claude Code with Red Hat MaaS as Milestone 1 Harness

## Status
Accepted

## Date
2026-10-01

## Layer
Agent

## Context

Milestone 1 needs an agentic harness that can edit code, run tests, and create
remediation PRs while using **Red Hat MaaS** for inference (DemoJam / RHDP
replicability). Carlos proposed Claude Code. We validated Claude Code against
MaaS on 2026-10-01: curl to `/v1/messages` returned HTTP 200 for
`claude-sonnet-4-6`, and Claude Code confirmed requests through the MaaS host
via a wrapper that sets `ANTHROPIC_BASE_URL` and `MAAS_API_KEY`.

Important constraint: Claude Code uses the **Anthropic Messages API**
(`/v1/messages`), not OpenAI `/v1/chat/completions`. MaaS (LiteLLM) exposes both.

Behavior requirements live in
[`specs/agents/harness-selection.spec.md`](../../specs/agents/harness-selection.spec.md).

## Options Considered

### Option 1: Claude Code + Red Hat MaaS
- **Pros:** Strong coding agent; works with MaaS via custom base URL; team proposal
  already validated; LiteLLM auto-detected
- **Cons:** Some Claude Code features may be limited behind third-party gateways
  (prompt caching, server-side tools); headless/pipeline UX still to harden
- **GA / support status:** Claude Code is Anthropic product; MaaS is RHDP-hosted
  LiteLLM gateway

### Option 2: Custom framework (LangGraph / CrewAI / similar) on MaaS
- **Pros:** Full control of agent graph and tools
- **Cons:** Higher build cost for Milestone 1; weaker out-of-the-box coding UX
- **GA / support status:** Varies by framework; none required for DemoJam M1

### Option 3: Other coding CLIs (Aider, Continue, Cursor Agent) on MaaS
- **Pros:** Alternative coding agents
- **Cons:** Not proposed by the team; MaaS Anthropic compatibility not validated
  for those tools in this project
- **GA / support status:** N/A for this decision

## Decision

Adopt **Claude Code** as the Milestone 1 agentic harness, with inference routed
through **Red Hat MaaS** using model `claude-sonnet-4-6` and the Anthropic
Messages API. Demo narrative MUST emphasize Red Hat MaaS / RHDP, not direct
frontier-provider access.

## Consequences

### Positive
- Unblocks Phase 2 agent scaffolding with a known-working coding harness
- Aligns inference with RHDP MaaS for DemoJam replicability
- Correct API shape (`/v1/messages`) is documented for the team

### Negative
- Advanced Claude Code features may not work fully through LiteLLM
- Wrapper/secrets wiring must be added for CI and Tekton
- Milestone 2 dual-agent may still introduce a second harness/model later

## Version Pinning
| Component | Pinned version | Where enforced |
|---|---|---|
| MaaS model | `claude-sonnet-4-6` | `MAAS_MODEL` in `secrets/secrets.env` and the pipeline Secret |
| LiteLLM (MaaS gateway) | RHDP-managed (observed `1.81.0` during validation) | MaaS platform |

How the harness itself is pinned and packaged is
[ADR-0003](./0003-agent-runtime-packaging-and-credentials.md).

## Demo Impact

Live demo shows remediation agents driven by Claude Code while requests go through
MaaS. Judges should see Red Hat model serving in the path, not a raw Anthropic
or Vertex developer session as the primary story.

## Validation

2026-10-01 (David Severia):

- curl `POST …/v1/messages` with `claude-sonnet-4-6` → HTTP 200; LiteLLM headers present
- Claude Code wrapper unset Vertex vars, set `ANTHROPIC_BASE_URL` + `MAAS_API_KEY`,
  launched with `--model claude-sonnet-4-6`
- Claude Code reported requests through the RHDP MaaS gateway

2026-10-09 (David Severia) — a full remediation ran end to end through MaaS:
clone, exploit test, patch, `mvn test`, push, pull request. Headless behaviour,
exit-status semantics and container execution were characterized while building
the runtime and are recorded in
[ADR-0003 → Validation](./0003-agent-runtime-packaging-and-credentials.md#validation).

Two findings bear on this decision specifically:

- **A non-Claude MaaS model works.** `qwen38-27b` answered over `/v1/messages`
  and returned correct tool calls, so the harness is not bound to Claude models.
  This was the question MiniMax-M2 access was meant to settle.
- **`claude-sonnet-4-6` is nonetheless the right pin**, for throughput rather
  than quality. The gateway caps a request at roughly 60 seconds, which bounds
  output per reply; the open models in the catalog are too slow to emit a patch
  and a test within it. See [agent-runtime.md](../agent-runtime.md) — Known
  limitations.

Remaining: streaming and thinking under MaaS, latency versus direct Vertex, and
API key ownership and rotation with the team.

## Related Decisions
- [ADR-0001: Adopt ADR Process](./0001-adopt-adr-process.md)

## References
- [Harness selection spec](../../specs/agents/harness-selection.spec.md)
- [ROADMAP Phase 2 prerequisites](../ROADMAP.md)
