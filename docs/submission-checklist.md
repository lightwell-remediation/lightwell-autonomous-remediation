# Task List — Lightwell Autonomous Remediation

> Living document. Phases will be added as the project progresses.

## Deadline: October 30, 2026 — DemoJam Build Submission (5:00 PM ET)

### Deliverables

| # | Deliverable | Status | Owner | Notes |
|---|---|---|---|---|
| D1 | 5-minute demo overview video | In progress | David | Primary focus for judges. Must show business impact, customer value, and replicability. Script: [demo-narrative.md](demo-narrative.md). Recorded off an interactive web page instead of slides (decided 2026-10-20). |
| D2 | DemoJam slides (from template) | In progress | | Template provided by organizers. Title, team, GitHub link, overview (font 10), technical highlights, up to 2 architecture diagrams. **Still required** — the web page replaces slides *in the video*, not this deliverable. |
| D3 | Public GitHub repository | Done | | Public since 2026-10-26 at github.com/lightwell-remediation/lightwell-autonomous-remediation. No customer/confidential info. Monorepo. |
| D4 | Source code zip file | Not started | | Backup of the repo. Upload to the submission Google folder. |
| D5 | Submission form | Not started | | Team leader submits. All links must have public access. Final team member list. |

### Tasks

#### Repository and code

- [x] Make the GitHub repo public before submission
- [x] Ensure no secrets, customer info, or confidential data in the repo (run `no-secrets` skill)
- [x] Write a detailed README explaining what the demo does, how to use it, and how to replicate it ([README](../README.md), [replicate.md](replicate.md))
- [x] Include architecture diagram(s) in `assets/` and reference from README
- [x] Ensure the repo is self-contained and another Red Hat team could replicate the demo
- [x] Prefer GitOps patterns for deployment (bonus points per judges)
- [ ] Create the source code zip file from the repo

#### Demo implementation (enough to show in the video)

- [x] Define the example application and vulnerable library to use in the demo (→ Phase 1: `vulnerable-app.spec.md`)
- [x] Implement the core remediation agent flow (analyze → test → patch → verify → PR) — at least a working prototype
- [x] Demonstrate a trigger initiating the remediation workflow — a `PipelineRun`
      that fetches the vulnerability record from Lightwell
      ([replicate.md](replicate.md#6-a-real-remediation)). The webhook was cut on
      2026-10-20 — Milestone 2
- [x] Show the agent generating a test, the test failing, code being patched, and the test passing
- [x] Show the inventory regenerated from the remediated build and validated in
      Trusted Profile Analyzer (→ Phase 3). Validated on 2026-10-23 against a TPA
      on a separate RHDP cluster ([ROADMAP — Phase 3](ROADMAP.md#phase-3-inventory-validation-tpa),
      [workarounds](workarounds.md)); TPA is not installed in the demo cluster in
      Milestone 1 ([replicate.md — Limitations](replicate.md#limitations-of-milestone-1))
- [x] Use RHDP MaaS for model serving. The model is `claude-sonnet-4-6`, the
      only one that passed the comparison
      ([model comparison](measurements/model-comparison-2026-10-19.md)); the
      video sells the platform, not the model
- [x] Ensure the demo runs on OpenShift via the demo platform (use existing catalog item as base)

#### 5-minute video (D1)

- [x] Plan the video script/storyboard — balance technical architecture with business value
- [ ] Record the demo overview video (max 5 minutes)
- [ ] Emphasize business impact: accelerated MTTR, zero-trust guardrails, unified developer experience
- [ ] Show why this matters to customers and how other teams can replicate it
- [ ] Highlight Red Hat platform value (not frontier model value)
- [ ] Review past winning videos for inspiration (linked from DemoJam source page)

#### DemoJam slides (D2)

- [x] Copy the slide template (link from organizers)
- [ ] Fill in: demo title, team member names
- [x] Write concise overview description (font size 10)
- [ ] Add GitHub repository link
- [x] Add technical highlights (platforms used, Red Hat products)
- [x] Create up to 2 architecture diagrams
- [x] Review evaluation criteria: business impact, replicability, visual appeal, team composition

#### Submission (D5)

- [x] Update final team member list (Roman, Roberto, Carlos, David + any additions)
- [x] Verify all links have public access for the evaluation committee (22 reviewers)
- [ ] Submit via the official form before October 30, 5:00 PM ET

### Key rules from the kickoff meetings

- **Business impact is the #1 evaluation criteria** — judges want to see customer value, not just tech
- **Use RHDP MaaS models** — avoid building core demo on frontier models (Claude, Sonnet, etc.)
- **Public GitHub repo under personal handles** — not under Red Hat org; no confidential info
- **Replicability matters** — other teams should be able to spin up and replicate the demo
- **GitOps preferred** for deployment management
- **No need to build a custom RHDP catalog item** — use existing base catalog item and build on top
- **Mock services OK** if certain features can't run on the demo platform — document limitations
- **Demo costs go to team cost center** — keep costs down through simplification
