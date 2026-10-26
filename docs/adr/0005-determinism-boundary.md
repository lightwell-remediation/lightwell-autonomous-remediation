# ADR-0005: Compute What Is Computable, Leave the Agent the Judgement

## Status

Accepted

## Date

2026-10-15

## Layer

Agents

## Context

The first implementation of the `analyze` role asked the agent to do everything the
capability needed: resolve the dependency tree, read the bill of materials, find the
component, judge reachability, and write its findings. Seven runs against the same input
measured what that costs.

| Run | Model | Outcome |
|---|---|---|
| 1 | `qwen38-27b` | 13m34s, 26 turns exhausted, **17 permission denials** |
| 2 | `claude-sonnet-4-6` | 2m25s, failed: **reply exceeded the 2048 output-token ceiling** |
| 3–5 | `claude-sonnet-4-6` | 41 turns exhausted, no document written |
| 6–8 | `claude-sonnet-4-6` | green at 59 turns once the data moved out of the session |

Three distinct failures, one cause.

**The dependency tree.** The agent was told to resolve it and write it to a file. The
natural invocation redirects output, which the permission model treats as a compound
command and denies. When the agent worked around that by writing the file through a tool,
the six kilobytes of tree had to travel through the model's reply — and the gateway's
~60-second request window caps replies at 2048 output tokens. The run died emitting data
it had just read.

**The bill of materials.** A CycloneDX document for this application is 216 KB, roughly
54,000 tokens. The prompt told the agent to consult it. Claude Code pages a file that size
in chunks, and the agent spent an entire 40-turn budget reading JSON to reach the single
line that mattered. Cache reads hit 455,788 tokens for 7,985 tokens of output.

**A dangling reference.** The prompt opened with `Behaviour contract:
specs/agents/vulnerability-analysis.spec.md` — a file in *this* repository, not in the
application the agent is checked out into. The agent went looking for it
(`find /workspace -maxdepth 3 -name "*.spec.md"`), as any reader of that instruction
would.

**No way to see what exists.** This one was only found after the runtime learned to emit
the session trace, and it was the largest. A green run showed 46 tool calls, 45 of them
`Read`, of which four were useful. The rest were `Read` of directories — which does not
work — and guessed Java package paths: `com/lightwell/lwapachecxfsample`, then
`lw_apache_cxf_sample`, then `sample`. Removing `Bash` had taken away the agent's usual
way of listing files, and it does not reach for `Glob` even when the policy allows it. It
was navigating the tree blind.

Handing it `git ls-files` output took the role from 9–10 tool calls instead of 46, and
from one failure in four to none in five. Listing files is a command, not a deduction.

None of these is a reasoning failure. In every run where it got far enough, the agent
reached the correct verdict, including the one that matters: that the vulnerable class is
never instantiated, so the application is affected at the SBOM level and not at the
execution level.

## Options

**Give the agent more budget and broader permissions.** Raising turns and widening the
allowlist makes the symptoms recede. It does not make a 54,000-token file cheaper to read,
and every permission added to let a model do a deterministic job is a permission available
for something else.

**Split the capability across several agents, or front it with an orchestrator.** This was
the natural reading of "the task is too big for one session". But the measurements say the
task is not too big: the reasoning fits comfortably. What did not fit was the data we were
routing through the model. Splitting would have distributed that cost, not removed it, and
would have decided the orchestration question that `orchestration-strategy.spec.md` exists
to decide on its own merits.

**Draw a boundary: compute what is computable, leave the agent the judgement.** The runtime
resolves the tree, projects the bill of materials down to coordinates, and places both in
the workspace. The agent reads files and reasons.

## Decision

The third. Anything whose result is determined by its inputs is produced by the runtime
before the session starts. The session is left with what a function cannot do.

The boundary is drawn by whether the model **transforms** the data or **reasons about** it,
not by size alone:

- The bill of materials moved out. The agent was transcribing a lookup — pure parsing.
- The dependency tree **stayed in**, at ~1,800 tokens. The agent reasons over it, and its
  verdict cited the tree for a second, independent line of evidence: no JCache provider
  appears anywhere in the resolved dependencies. Removing it would have been cheaper and
  worse.

This generalises past this role. Every later capability — patching, verification, pull
request creation — faces the same question, and the default answer is now established:
if a script can produce it, a script produces it.

## Consequences

**The permission surface collapses.** The `analyze` policy is `Read`, `Glob`, `Grep`, and
`Write`/`Edit` restricted to one output path. No `Bash` at all. An agent with no shell
cannot be talked into one by anything it reads in the repository it is analysing.

**Runs get cheaper and faster.** 13m34s to roughly 3 minutes, and $0.37 per run. The tree
costs 0.85 seconds to resolve outside the session; the same work inside it cost tens of
turns and sometimes the whole run.

**Determinism moves to where it can be tested.** Tree resolution and SBOM projection are
now shell and a few lines of Node, verifiable without spending inference. What remains in
the session is the part that genuinely varies.

**The variance disappeared.** It had looked like an inherent property of the model: 41 to
108 turns on identical input, one run in four exhausting its budget. It was not. Once the
agent stopped having to discover what it could be handed, five consecutive runs took 9 or
10 turns each, 45–55 seconds, $0.09, with identical findings. `MAX_TURNS` went back to 40,
which is four times what the role needs.

**Visibility had to come first.** Each of these causes was invisible in the result
document, which records what a session spent but never what it spent it on. Every
diagnosis made from that summary alone was wrong, and the biggest cause — blind tree
navigation — was found within one run of the trace existing. `lib/trace-summary.js` now
prints the tool breakdown on every run, green ones included.

**The runtime takes on build knowledge.** It now knows that a `pom.xml` means Maven and
that a sibling `settings.xml` should be passed. That is ecosystem coupling in a component
that had none, and a second ecosystem will need it generalised.

## References

- Behaviour: [`vulnerability-analysis.spec.md`](../../specs/agents/vulnerability-analysis.spec.md),
  [`agent-runtime.spec.md`](../../specs/platform/agent-runtime.spec.md) — Task Input Delivery
- Packaging and credential model: [ADR-0003](0003-agent-runtime-packaging-and-credentials.md)
- Why the application repository must not contain the answer: [ADR-0004](0004-demo-repository-ground-truth-isolation.md)
- Gateway request window and output ceiling: [agent-runtime.md](../agent-runtime.md) — Known limitations
