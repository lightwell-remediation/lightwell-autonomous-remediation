# Demo Narrative — DemoJam, Red Hat One 2027

> Headlines only. The prose comes later; this is the skeleton the team builds on.
> Decided on 2026-10-20: an interactive web page, not slides. Under 5 minutes.
> The page lives in the private repository `lightwell-remediation/lightwell-demo-page`
> (moved on 2026-10-26: it shows Lightwell data from real runs).

## Format

Same stack as [bank-voice-agent-shinny](https://github.com/rh-aiservices-bu/bank-voice-agent-shinny)
([live](https://rh-aiservices-bu.github.io/bank-voice-agent-shinny/)):

| Piece | Version | Why it matters to us |
|---|---|---|
| Vite | 6 | Static build, no server at demo time |
| React | 19 | — |
| TypeScript | 5.8 | — |
| Tailwind CSS | 4 | Dark mode is a class toggle, already wired there |
| Framer Motion | 12 | Stage transitions |
| GitHub Pages + Actions | `.github/workflows/deploy.yml` | Public URL for the submission |

How that repo is organised, because it decides how this document maps onto code:

- **All content is data**: `src/data/stages.ts` is an array of
  `{ id, slug, title, subtitle, story, category, description, bullets[], image, autoplaySeconds }`.
  Each act below is one or more of those entries.
- **Full-bleed image pages** are interleaved by page index (`imageSlides` in `App.tsx`) —
  that is where the two architecture diagrams go.
- **Autoplay with per-stage seconds** is what actually holds the five minutes. The
  budget column below is `autoplaySeconds`.
- `category` drives the colour. Proposal: `problem` (amber), `future` (cyan),
  `now` (emerald), `next` (slate).

## The five acts

| # | Act | Budget | Asset |
|---|---|---|---|
| 1 | The problem, and solving it at scale | 60s | — |
| 2 | Target architecture (Milestone 2 done) | 45s | [`architecture-m2.png`](../assets/architecture-m2.png) |
| 3 | The steps (Milestone 2 done) | 45s | `sequence-m2.png` **to create** |
| 4 | What runs today — the demo | 105s | Recorded run **to capture** |
| 5 | Next steps — everything above, in Milestone 2 | 45s | — |

300 seconds exactly. Act 4 is deliberately the largest: it is the only part that
shows something real.

---

### Act 1 — The problem, and solving it at scale

*Category: `problem`. The judging criterion is business impact, so this act is
not about agents.*

- An alert tells you what is broken. It does not do the work.
- Lightwell already ships the rebuilt artifact — someone still has to patch,
  test, prove it, and open the pull request.
- One CVE across N applications does not scale by hiring reviewers.
- What does scale: an agent that produces the pull request, and evidence a
  human can check in minutes instead of hours.
- Inside enterprise guardrails, on the customer's own infrastructure and models.

### Act 2 — Target architecture, with Milestone 2 done

*Category: `future`. One full-bleed diagram, narrated.*

- Lightwell alert → Developer Hub → Tekton → agents → pull request.
- Two agents, different models, producing divergent patches.
- An LLM-as-a-Judge choosing, combining, or rejecting both.
- Sandboxed execution: zero-trust at the process level (OpenShell / Agent Sandbox).
- Traced and evaluated end to end: MLflow, EvalHub, guardrails via TrustyAI.
- Models served by MaaS — the customer's models, on RHOAI.

### Act 3 — The steps, with Milestone 2 done

*Category: `future`. The same story as Act 2, but as a sequence — this is what
the audience will actually remember.*

- alert → trigger → **analyse**: is the CVE reachable in this application?
- **baseline**: the suite is green before anything is touched.
- **demonstrate**: write a test that fails *because of* the vulnerability.
- **Agent A ‖ Agent B**: two independent remediations.
- **judge**: picks one, merges, or rejects.
- **inventory**: rebuild the SBOM, validate it in Trusted Profile Analyzer.
- **deliver**: a pull request stating how far its own evidence goes.

### Act 4 — What runs today

*Category: `now`. The recorded run. **Not live**: a full run takes 7–11 minutes
against a 5-minute slot, so this is edited video ([ROADMAP](ROADMAP.md) — Out of
scope, the tool-call traces item).*

The chain of evidence is the story. Each step is one beat:

- **Reachability, not a version number.** The agent says whether the vulnerable
  code is reached, and shows why.
- **Red before green.** The exploit test fails first. This is the beat that
  matters: it is what stops a dependency bump from passing as a fix.
- **Patch, verify, one bounded retry.** Show the retry when we have a take with
  one — verification catching an incomplete remediation is the difference
  between this and a bot that edits `pom.xml`.
- **The inventory is rebuilt**, so the same alert does not fire again on the
  patched application.
- **The pull request states its own limits.** Not "fixed" — what was proven, and
  what was not.
- **Numbers on screen**: minutes and roughly a dollar per remediation, on
  `claude-sonnet-4-6` over MaaS, same outcome five runs out of five
  ([measurements](measurements/)).

### Act 5 — Next steps

*Category: `next`. Everything from Acts 2 and 3 that is not yet built.*

- Dual agent + LLM-as-a-Judge — and **the concrete reason it exists**: a test can
  assert the defect instead of the contract, and every deterministic gate still
  passes. We have a real case of this.
- Sandboxed agent execution with OpenShell / Agent Sandbox (Carlos). Worth
  saying out loud: the runtime image already extends the Red Hat agentic
  starter kit, which ships OpenShell, and it is arbitrary-UID clean — so this
  is a step we take, not a rewrite ([ADR-0003](adr/0003-agent-runtime-packaging-and-credentials.md)).
- MLflow tracing and EvalHub evaluation of patch quality.
- Developer Hub as the front door.
- Real Lightwell webhook trigger.
- Guardrails via TrustyAI.

---

## Assets to create

- [x] [`architecture-m2.png`](../assets/architecture-m2.png) — Act 2. The Milestone 2 stack as layers.
      Source in [`assets/architecture/`](../assets/architecture/)
- [ ] `sequence-m2.png` — Act 3. The Milestone 2 flow as steps. Base it on the
      ASCII sequence in [orchestration.md](orchestration.md) and add Agent B,
      the judge and TPA (Roberto)
- [ ] Recorded run for Act 4, including a take with a retry (David, Roman)
- [ ] Decide what is on screen while Act 4 narrates: the Pipelines console, the
      terminal, or the resulting pull request

## Open questions

- Where the page lives: this repository under `demo/`, or its own repo as in the
  reference. Affects the GitHub Pages URL we submit.
- This narrative is the **5-minute submission video** (D1). The 20-minute DemoJam
  slot is a different script and is not covered here.
- The web page replaces slides *in the video*. It does **not** replace **D2**, the
  organizers' slide template — that is a separate required deliverable with its
  own fields ([submission-checklist.md](submission-checklist.md)). The two
  architecture diagrams of Acts 2 and 3 serve both, so they are built once.
