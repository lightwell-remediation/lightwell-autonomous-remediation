# Roadmap — Lightwell Autonomous Remediation

> DemoJam | Red Hat One 2027

This roadmap is organized around two milestones. Development is **spec-driven**:
each phase defines its specs (`specs/<domain>/<name>.spec.md`) before writing code.
Use the `spec` skill to create specs and register them in `specs/index.spec.md`.

---

## Milestone 1: Submission (deadline Oct 30, 2026)

Deliver a working prototype (hardcoding OK) plus 5-min video, slides, and public
repo to pass the screening of 22 evaluators.

### Phase 0: Foundations (done)

- [x] Initialize repository and skeleton structure
- [x] Set up Cursor skills and rules (reused from agentops-example)
- [x] Define Git workflow (main + feat branches, Conventional Commits)
- [x] ADR-0001: Adopt ADR process

### Phase 0.5: Cluster Bootstrap (done)

> Blocks the in-cluster runs of Phase 2 and the TPA work of Phase 3. Start it early:
> RHDP cluster lifetimes are short, so the bootstrap must be repeatable, not manual.

Spec:
- [x] [`specs/platform/cluster-bootstrap.spec.md`](../specs/platform/cluster-bootstrap.spec.md) — Target cluster shape, required
  operators, namespaces, credentials, and the validation that proves the cluster
  is ready to host an agent run.

The minimum platform needed to deploy everything else, plus RHOAI. RHOAI is not
required by any Milestone 1 feature today, but it is the prerequisite for MLflow
(Phase 4.5) and for all of Phase 5 — installing it now costs one operator and
removes the risk of discovering a broken install days before the deadline.
Everything is declarative (Helm + GitOps), so a fresh cluster is reproducible
in one command. Decisions in [ADR-0006](adr/0006-cluster-bootstrap-topology.md),
[ADR-0007](adr/0007-in-cluster-credential-delivery.md) and
[ADR-0008](adr/0008-agent-runtime-image-delivery.md); usage in
[deploy/README.md](../deploy/README.md).

Tasks:
- [x] Define the target cluster (OpenShift version, capabilities, sizing) and
      document it, including the capacity for two parallel agents
      ([deploy/README.md](../deploy/README.md)) (Roberto)
- [x] Create `deploy/` with the Helm charts and the `make deploy-all` entry point
      expected by the `cluster-bootstrap` skill (Roberto)
- [x] Install OpenShift GitOps (ArgoCD) as the deployment mechanism, with
      cluster-admin for the application controller (Roberto)
- [x] Install OpenShift Pipelines (Tekton) — prerequisite for Phase 3 (Roberto)
- [x] Create namespaces, ServiceAccount and RBAC for agent runs. The agent needs
      no Kubernetes API access, so the only RBAC is what Tekton and the internal
      registry already provide (Roberto)
- [x] Provision credentials as cluster Secrets (MaaS key, GitHub PAT, ArgoCD and
      build git credentials) via `make secrets`; nothing committed to the
      repository. Lightwell `LW_USERNAME` / `LW_PASSWORD` are wired but empty
      until the Phase 3 trigger exists (Roberto)
- [x] Publish the `agent-runtime` image to a registry reachable from the cluster:
      two chained BuildConfigs into the internal registry, so there is no pull
      secret to wire ([ADR-0008](adr/0008-agent-runtime-image-delivery.md)) (Roberto)
- [x] Install RHOAI 3.5 (operator + DataScienceCluster), even though no
      Milestone 1 feature depends on it yet. A component is Managed unless it
      cannot work on the cluster: `kueue` (no longer accepts `Managed` in 3.5),
      `trainer` (needs a JobSet operator absent from the catalog) and
      `aigateway` (needs the MaaS platform, we use an external MaaS) are off
      with the reason recorded (Roberto)
- [x] Set the dashboard feature flags and a CPU hardware profile. The operator
      creates `OdhDashboardConfig` nearly empty, so the console hides features
      whose component is Managed, and RHOAI 3.x starts nothing without a
      hardware profile (Roberto)
- [x] Verify a default StorageClass exists (MLflow and RHOAI components need
      PVCs). Checked by `make preflight`, together with the image registry and
      the `Build` capability the image build needs (Roberto)
- [x] `make validate`: Applications Synced, operators Succeeded, DSC conditions,
      MLflow Available, Secrets present, the image built, and **two agent shaped
      PipelineRun tasks green in parallel** on a fresh cluster. A hello-world
      would only prove Tekton is alive (Roberto)
- [x] Document the bootstrap for replicability ([deploy/README.md](../deploy/README.md)) (Roberto)
- [ ] **Enable the Pipelines and GitOps console plugins in the bootstrap.**
      `pipelines-console-plugin` and `gitops-plugin` exist on the cluster with
      their pods running, but neither was in `console.operator.openshift.io/cluster`
      `spec.plugins`, so no Pipelines or GitOps menu appeared and Tekton looked
      absent while it was running fine. Enabled by hand on 2026-10-17; it is a
      cluster-scoped object so it belongs in the bootstrap chart, or it goes
      missing again on the next cluster (Roberto, David)
- [x] Rewrite the `cluster-bootstrap` skill against the `deploy/` that this phase
      actually builds — it was inherited from agentops-example and still described
      charts (MLflow, EvalHub, TrustyAI) and a `make deploy-all` that did not exist
      here, and omitted OpenShift Pipelines (Roberto)
- [x] Deploy MLflow. It landed here rather than in Phase 4.5 because the RHOAI
      install is what made it a one-chart addition. Nothing writes to it yet (Roberto)

Validated on 2026-10-15: OCP 4.21.36, single node, 32 CPU / 126 GiB, ODF
storage, from a plain cluster to `make validate` green.

### Phase 1: Vulnerable Application

> First or in parallel with Phase 2.

Spec:
- [x] [`specs/standards/vulnerable-app.spec.md`](../specs/standards/vulnerable-app.spec.md)

Identify at least one real CVE with a known public exploit; find an existing
affected application or create a minimal test app that includes the vulnerability.

1. Research CVEs with public exploits (e.g. Python/Java/Node library with PoC)
2. Select at least one CVE viable for the demo
3. Find an open-source app using the vulnerable library, OR create a minimal app
4. Document: CVE ID, affected library, vulnerable version, patched version, exploit PoC

Tasks:
- [x] Research candidate CVEs with public exploits (Roman)
- [x] Select CVE(s) for the demo (Roman)
- [x] Obtain or create the vulnerable application (Roman)
- [x] Verify the exploit works against the app (Roman)
- [x] Document CVE + app in the repo (Roman)

### Phase 2: Core Remediation Agent

> In parallel with Phase 1 or immediately after.

Prerequisites:
- [x] `specs/agents/harness-selection.spec.md` — Requirements and criteria for the
  agentic harness (capabilities, MaaS/RHDP constraints, pipeline integration).
  Choice recorded in [ADR-0002](adr/0002-claude-code-maas-harness.md) (Claude Code + MaaS). 
- [x] [`specs/platform/agent-runtime.spec.md`](../specs/platform/agent-runtime.spec.md) — How the
  harness is packaged, configured, and launched (credentials, permissions, container
  execution). Decisions in [ADR-0003](adr/0003-agent-runtime-packaging-and-credentials.md);
  usage in [docs/agent-runtime.md](agent-runtime.md). Built orchestration-agnostic on
  purpose, so the prerequisite below can be decided with real data.
- [x] [`specs/agents/orchestration-strategy.spec.md`](../specs/agents/orchestration-strategy.spec.md)
  — the obligations the six other specs defer to it, collected and made
  checkable: state passes as files, the sequence is reproducible, preconditions
  gate each phase, the baseline is captured once at a specific moment, the
  demonstration comes after it, retries are bounded to one, one run per
  workspace, and the exit status distinguishes *nothing needed doing* from
  *something did and did not happen*. `scripts/remediate.sh` satisfies all of
  them today and exists to be replaced.
- [x] **ADR: pipeline tasks or a coordinating agent.** Decided in
  [ADR-0009](adr/0009-tekton-pipeline-orchestration.md): a Tekton Pipeline,
  one Task per phase, with the bounded retry as `retries: 1` on a combined
  patch-and-verify Task. The sequencing contains no judgement, so ADR-0005
  argues for computing it; a reasoning orchestrator could recover from
  surprises but cannot be replayed against recorded documents, which is how
  the sequencing is meant to be tested in seconds rather than minutes. RHOAI
  AI Pipelines was examined and set aside — KFP v2 has no loop or recursion
  either, no DSPA is instantiated, and Tekton is what Triggers and Developer
  Hub plug into. Argo Workflows has real loops but is only present as RHOAI's
  internals, which is not a supported dependency.
- [x] **Be able to run the orchestration with the agent calls mocked.** Six
  scenarios in `agent-runtime/test/fixtures/scenarios/`, replayed through the
  Pipeline by `scripts/test-pipeline.sh` and through the local sequencer by
  `scripts/remediate.sh --replay`. Both green, both free. The cluster harness
  asserts the run's status, which tasks were skipped, and how many attempts
  patching took — the skip list is the half that matters. The failure shapes
  (`regression`, `cannot-verify`, red baseline) are still hand-written and
  worth replacing with real captures. Original reasoning: A phase is a prompt in and a document out, so a run can
  be replayed by handing back a recorded document instead of starting a
  session. That makes the sequencing testable in seconds and for nothing,
  which matters because the parts that go wrong there are ordering, retry
  bounds and what is carried between phases — none of which need a model to
  exercise, and all of which currently cost two to five minutes and a model
  call per attempt to try out.

  The recorded documents are the mocks, so **every good run's output gets
  kept**. `agent-runtime/test/fixtures/` already holds one `analysis.json`;
  the same applies to `patch.json` and `verification.json`, and to the
  failing shapes as well — `cannot-patch`, `regression`, `cannot-verify` —
  since those are the branches the sequencer has least cover on. Capture them
  as they occur rather than manufacturing them later, because a hand-written
  document drifts from what the agent actually emits.

The work is divided across at least 3 specialized agents:

**Analysis Agent** — understands the vulnerability and creates the evidence test:
- [x] [`specs/agents/vulnerability-analysis.spec.md`](../specs/agents/vulnerability-analysis.spec.md)
- [x] [`specs/agents/exploit-test-generation.spec.md`](../specs/agents/exploit-test-generation.spec.md)
      and the `exploit` role. The measurement that forced it, and what it
      fixed, below.
- [x] **`specs/agents/exploit-test-generation.spec.md` — no longer optional.**
  Measured against the reachable-CVE fixture, the agent removed the
  application's defective override in **three runs out of five**. Same input,
  same prompt, same model. When it does not, the remediation is a version bump
  on an application that stays vulnerable, verification reports `verified`
  because the three existing tests pass, and a pull request is opened titled
  "remediate CVE-...". The body does say the defect was never exercised and
  that no source changed — that part of the design holds — but correctness
  then rests on the reviewer reading the last unticked line.
  The cause is structural rather than a prompt to tune: with no failing test,
  nothing signals that the bump is insufficient. An exploit test written
  *before* patching makes patch face a red test it cannot bump away, lets
  verify catch an incomplete remediation, and turns the pull request's
  "not exercised" into "failed before, passes after".
  **Resolved.** Observed end to end: the generated test fails, patching bumps
  the version and stops, verification reports `regression` because the test is
  still red, the sequencer returns it once, and the second attempt makes the
  source change. Six phases, $0.98.
      application reaches the vulnerable classes; until then there is no exploit
      to specify (Roman, with Exploit Intelligence)

**Remediation Agent** — fixes the code and verifies the fix:
- [x] [`specs/agents/code-patching.spec.md`](../specs/agents/code-patching.spec.md)
- [x] [`specs/agents/fix-verification.spec.md`](../specs/agents/fix-verification.spec.md)

**Delivery Agent** — opens the pull request with the evidence behind it:
- [x] [`specs/agents/pr-creation.spec.md`](../specs/agents/pr-creation.spec.md)

Given (vulnerability_info, app_repo), the orchestration executes the 3 agents in
sequence: **Analysis Agent** → **Remediation Agent** → **Delivery Agent**. The
orchestration mechanism (pipeline vs orchestrator agent) is decided by the
`orchestration-strategy.spec.md` prerequisite.

**Nothing judges the patch in Milestone 1.** The gate is deterministic — a green
baseline, an exploit test that fails before the change and passes after, and no
regression — and what it cannot tell is whether a passing test asserts the
contract or the defect (see the task below). The reviewer is the one who decides that,
and the pull request body is written so they can: it states how far the evidence
goes rather than claiming the remediation is correct. The LLM-as-a-Judge moves
whole to Phase 6, where it also takes on comparing two Remediation Agents' PRs.
Dropped from the submission scope on 2026-10-20 — the deadline is 30 October and
a judge is a spec, a model choice and a verdict contract we would be writing
blind.

Tasks:
- [x] Rebase `agent-runtime/Containerfile` onto the upstream starter-kit image
      per [ADR-0003](adr/0003-agent-runtime-packaging-and-credentials.md)
- [x] Scaffold agents with the chosen harness (Carlos, Seve)
- [x] Implement the vulnerability-analysis capability: `analyze` role with its own
      prompt, read-only policy and output contract
      ([agent-runtime.md](agent-runtime.md) — Roles). **Run green against the demo
      repository** on 2026-10-15: correct `not-reachable` verdict with evidence,
      ~3 min, $0.37, no denials. Deterministic inputs are prepared by the runtime
      per [ADR-0005](adr/0005-determinism-boundary.md)
- [x] Make `analyze` terminate reliably. Was failing one run in four at 41–108
      turns; the trace showed it navigating the file tree blind — 45 `Read` calls,
      four of them useful. Handing it `git ls-files` output settled it at 9–10
      turns, 45–55s, five green runs out of five with identical findings
- [x] Emit the session trace (`out/session.jsonl`) and a tool-call summary on
      every run. The result document records what a session spent, never what it
      spent it on; every diagnosis made without the trace was wrong
- [x] Implement the exploit-test-generation capability: `exploit` role, with its verdict observed by the runtime rather than claimed by the session
- [x] Implement the code-patching and fix-verification capabilities: `patch` and
      `verify` roles, each with its own prompt, policy and output contract, plus
      `scripts/remediate.sh` sequencing analyse → baseline → patch → verify with
      the green-baseline gate and one bounded retry. **Run green end to end
      against the demo repository** on 2026-10-16: patched, verified, 2m10s
- [x] Repeat the end-to-end run five times. Identical outcome every time —
      `patched`/`declaration`, two artifacts moved, `verified`, no regression —
      in 133–143s, with analyse 10–12 turns, patch 9, verify 8–9. The three
      phases together now cost fewer turns than `analyze` alone did before it
      was handed a file inventory
- [x] Fixtures for the branches the demo application does not take
      (`agent-runtime/test/fixtures.test.sh`, 5/5). They found two defects
      unreachable on the happy path: `set -e` killing the run before
      verification whenever the post-change suite was red, and a gutted test
      passing the baseline comparison unnoticed
- [x] Implement the Delivery Agent: `pr-creation` only, no judge — the
      `deliver` phase ([`prompts/deliver.md`](../agent-runtime/prompts/deliver.md),
      gated by `lib/check-delivery.js`) opens the pull request on the
      application repository
- [x] Implement orchestration — the Tekton Pipeline in
  `deploy/gitops/deployments/agents/remediation-pipeline/`, per
  [ADR-0009](adr/0009-tekton-pipeline-orchestration.md). Five Tasks, `when`
  expressions on each phase's terminal state, `retries: 1` on a combined
  patch-and-verify Task, and a `finally` task rendering the run's single
  honest status. Deployed with Helm directly; **not** under ArgoCD until it
  stops changing. Usage in [docs/orchestration.md](orchestration.md)
- [x] **Try the other MaaS models.** `claude-haiku-4-5` and `minimax-m2`,
      three full runs each on 2026-10-19:
      [measurements](measurements/model-campaign-2026-10-19.md). **0 of 6
      usable**, against 2 of 2 for `claude-sonnet-4-6`. One cause in every
      run — neither model creates a file with `Write`. They shell out
      (`cat > … << EOF`, `touch`, `echo >`, `python3 -c … >`, each refused)
      or try `Edit` on a file that does not exist, even though
      `Write(//**/src/test/**)` is allowed and `exploit.md:59` says to use
      it. minimax also costs more to fail ($1.31) than sonnet costs to
      succeed ($1.11), because it emits its reasoning as `<think>` text in
      the content. Not a substitute for Milestone 1
- [x] **Decide which model runs the remediation for the submission:
      `claude-sonnet-4-6`.** Revisited after 30 October, not before.
      [Comparison](measurements/model-comparison-2026-10-19.md): sonnet 6/7
      delivered and 6 of 6 with a source change; opus 2/4 delivered, 1 of 2
      with a source change, at twice the cost; haiku and minimax 0/5 each.
      The prompt experiment was tried and reverted — it bought nothing and
      coincided with a sonnet failure
- [ ] **A test can assert the defect instead of the contract, and every
      gate will pass.** Opus delivered a pull request whose test asserted
      that redeeming a code twice returns the same grant — the vulnerability
      — which failed before the change and passed after a version bump
      alone, leaving the application exposed with the evidence chain green.
      "Failed before, passes after" proves behaviour changed, not that it
      changed in the right direction, and no deterministic gate can tell an
      assertion from its negation. This is the concrete case for the
      Milestone 2 LLM-as-a-Judge, and it should be the judge's first job.
      **Accepted as a Milestone 1 limitation**, since the judge is out of
      submission scope: the pull request body names the test it rests on, so
      the reviewer can read the assertion, and the demo narrative says so
      rather than claiming the chain is self-sufficient (David)
- [x] Validate end-to-end flow with the Phase 1 app — in cluster on
      2026-10-17, delivered as PR #9 and PR #10 on `lw-apache-cxf-demo`
      ([measurements](measurements/pipeline-runs-2026-10-17.md))

**Running it in the cluster.** Conditions for a run to work and for the demo to
fit its slot. They sat in Phase 3 until the DevSecOps scope was cut on
2026-10-20; none of them is pipeline work, and the pipeline they apply to is the
one Phase 2 already built.

- [x] **Version the runtime image** (2026-10-27). The tag used to name a
      commit (`main-<sha>`), which cost a second commit per change, a tag that
      only `scripts/build-runtime-image.sh` created, a chart default that
      existed in no fresh cluster (`ImagePullBackOff` without `--set`), and
      the same commit built twice. The runtime now has its own semantic
      version (`agents.runtimeImage.version`); the cluster's build publishes
      `lightwell-agent-runtime:<version>` and the remediation Pipeline, now an
      ArgoCD Application, is handed the same tag, so a fresh cluster needs no
      script and no `--set`. A version is never reused, which keeps
      `IfNotPresent` honest: the `runtime-image-version` skill bumps it and
      `scripts/check-image-version.sh` fails when a chart carries a copy or the
      image changed without a bump ([ADR-0008](adr/0008-agent-runtime-image-delivery.md)
      amendment) (David)
- [x] **Put the BuildConfig's branch in the chart.** The runtime ref is
      `agents.runtimeImage.appRepoRef: "main"` in
      `deploy/gitops/bootstrap-infra/values.yaml` since PR #4, so ArgoCD no
      longer resets it to the bootstrap branch (David, Roberto)
- [x] **Move the chart under ArgoCD** (2026-10-27): the
      `agents-remediation-pipeline` Application, so the runtime's version lives
      in one place (`agents.runtimeImage.version`). It was applied with Helm
      directly until then — reconciling it while it was still
      being iterated would have meant a commit per change (David)
- [ ] **Warm the cache before the demo.** Measured in cluster on
      2026-10-17: 48m08s cold against 11m46s warm, and 37 of those 48
      minutes were `dependency:tree`. Not bandwidth or storage — every
      artifact is tried against the three Lightwell repositories before
      Central answers. Paid once per set of
      dependencies ([measurements](measurements/pipeline-runs-2026-10-17.md))
- [x] **Revisit the repository order in the application's `settings.xml`.**
      Central first for everything the Lightwell repositories do not govern
      would remove most of the cold-cache round trips. It is Roman's
      repository, so it needs agreeing rather than changing (David, Roman)
- [ ] **Two minutes of a run are pod scheduling and image pulls** across
      seven tasks, not work. Relevant to anyone sizing the demo slot; a
      single-Task arrangement would not pay it, and would lose the per-phase
      visibility that motivated ADR-0009
- [ ] Allow egress from the agent pod to the Lightwell Maven repositories. Maven resolves the
      Lightwell repositories at build time, so under a restrictive NetworkPolicy
      `verify-fix` fails with a dependency resolution error that reads like a bad
      patch rather than a blocked network. Nothing shows up locally (David)
- [x] **Where the vulnerability record comes from, for Milestone 1: a
      ConfigMap.** Mounted per run, reproducible and needing no network; the
      runtime can also fetch a URL with the Lightwell credentials. Deciding
      what a *real alert* produces was the trigger's question, and the
      trigger is Milestone 2 (Phase 7), so nothing is pending here before
      the submission (David)

### Phase 3: Inventory Validation (TPA)

Spec:
- [x] [`specs/devsecops/pipeline.spec.md`](../specs/devsecops/pipeline.spec.md) —
      what has to be true at the two ends of a remediation. Its trigger
      section describes Milestone 2; what Milestone 1 answers to is
      **The Inventory Is Regenerated From the Remediated Build** and
      **Validated Before Merge**.

**The DevSecOps scope was cut to this on 2026-10-20.** What is left is closing
the loop the alert came from: an alert is raised against an inventory, so a
remediation is not finished until the inventory says so. The pipeline already
rebuilds the bill of materials from the remediated tree and commits it to the
pull request branch; what is missing is somewhere to send it. Dropped with the
cut, and listed under *Out of scope for Milestone 1*: the webhook trigger (runs
start as a `PipelineRun`), CI on the generated pull request branch, and moving
the application build into the cluster.

Tasks:
- [x] **No second SBOM producer on the demo repository.**
      `.github/workflows/sbom.yml` regenerates the inventory on a `pom.xml`
      push. In the sample that is correct; downstream it is wrong twice —
      it builds with no `-s settings.xml`, so it cannot resolve the vendor
      rebuild a remediation introduces and goes red on exactly the pull
      requests this project exists to produce, and the pipeline now writes
      that file itself. `scripts/sync-demo.sh` drops it on publication
      rather than deleting it upstream, so the sample keeps a working
      workflow and the demo has one producer (David)
- [x] **The bill of materials is regenerated in the pipeline, before
      delivery.** A deterministic `sbom` task between verification and
      delivery, Syft 1.54.1 pinned in the image, the workflow's own flags so
      the document keeps its shape. Verified on PR #21: the inventory names
      the Lightwell rebuild, nothing is left at the vulnerable `4.2.2`, and the
      diff is +123/-123 — versions moving, not a rewrite. Validation in TPA
      still needs an instance (David)
- [x] **A TPA instance — Roman's, on a separate RHDP cluster.** Decided on
      2026-10-23: it already has the Lightwell integration and the Lightwell
      OSV records, which an empty instance here would not, and it serves the
      same API (Trustify 3.1.0). A workaround, not the architecture
      ([workarounds](workarounds.md)) (Roman, David)
- [x] **Upload the regenerated inventory to TPA.** A `validate` step in the
      `sbom` task, after `regenerate`: same pod, reading the file just
      written. It uploads the branch's inventory, asks TPA for its
      advisories and for the baseline's, and leaves `out/tpa.json`; the
      runtime appends the comparison to the pull request body. Optional
      Secret, never fatal on TPA's account. Tested against recorded
      responses (`agent-runtime/test/tpa.test.sh`) (David)
- [x] **Register the demo application's baseline.** `scripts/tpa-onboard.sh`
      uploads `sbom.json` from the default branch once, labelled
      `role=baseline`. By hand for now; the first piece of onboarding an
      application. Registered 2026-10-23: TPA lists CVE-2026-68079 as
      affected in it (David)
- [x] **Only the remediated CVEs are critical in the demo's inventory.**
      Spring Boot 4.0.6 brought in Tomcat, Spring Framework and Jackson
      versions with 8 critical advisories of their own, which buried the one
      the demo is about. The sample's `chore/spring-boot-4.0.9` branch
      (`feat/david/reachable-cve` plus the parent bump) moves them to fixed
      versions; the demo is now published from it. Measured in TPA: the
      only critical advisories left are CVE-2026-68079 and CVE-2026-63687,
      both fixed by the Lightwell rebuild; tests still green (David)
- [x] **OIDC client for the pipeline.** The instance's own `tpa-cli`
      (client-credentials). Validated against the real instance with PR #21's
      inventory: the CVE affected in the baseline, absent on the branch
      (David)
- [x] **CVE-2024-32007 still affected on the Lightwell rebuild of
      `cxf-rt-rs-security-jose`** in TPA — a false positive, not something the
      sample can fix. Upstream fixed it in 4.0.5 (GHSA-6pff-fmh2-4mmf, which
      TPA correctly does not match). The hit comes from Red Hat's VEX for the
      CVE: `affected`, `version: "*"`, scoped to
      `cpe:/a:redhat:jboss_fuse:7`, which TPA applies to any inventory
      carrying the purl. It shows on the baseline (`4.2.2`) as much as on the
      branch, so the verdict's delta is clean. No version bump clears a
      wildcard, and excluding `jose` would break the OAuth2 data providers
      that need it. For the recording: leave it, and filter the tab by the
      demo's CVE or say it belongs to another product's VEX. Checked against
      the instance on 2026-10-26 (Roman, David)
- [x] Validate end-to-end: run → PR carrying a regenerated inventory → TPA
      shows the vulnerability gone. Before Roman's RHDP cluster expires —
      this is the Act 4 recording (Roman, David)

### Phase 4: Demo Deliverables

Tasks:
- [ ] 5-minute demo overview video, following
      [demo-narrative.md](demo-narrative.md) — five acts, 300 seconds. Act 4
      is a recorded run, not live: a full run takes 7–11 minutes
- [x] **An interactive web page instead of slides.** Decided on 2026-10-20:
      the same stack as
      [bank-voice-agent-shinny](https://github.com/rh-aiservices-bu/bank-voice-agent-shinny)
      (Vite + React + Tailwind + Framer Motion, published to GitHub Pages),
      with the content as a `stages.ts` array and autoplay holding the five
      minutes. Skeleton first, content into it after (Roberto)
      Done; moved on 2026-10-26 to the private repository
      `lightwell-remediation/lightwell-demo-page`, because it shows Lightwell
      data from real runs and this repository is going public. No Pages
      site: the video is recorded from `make dev`
- [ ] Architecture and sequence diagrams for Milestone 2 — the two full-bleed
      pages of Acts 2 and 3 (Roberto, Carlos). Architecture done
      ([`architecture-m2.png`](../assets/architecture-m2.png)); sequence pending
- [x] Detailed README for replicability — [README](../README.md) for the
      judges, step-by-step guide in [replicate.md](replicate.md)
- [x] Architecture diagram(s) in `assets/`
- [ ] Make repo public, run secrets scan (`no-secrets` skill)
- [ ] Submit via official form

### Phase 4.5: Nice-to-have (if time permits before submission)

Specs (only if implemented):
- [x] [`specs/observability/agent-tracing.spec.md`](../specs/observability/agent-tracing.spec.md)
- [x] [ADR-0010](adr/0010-agent-tracing.md): agent tracing — capture in the session,
      export after the run, MLflow optional, OpenTelemetry later

Tasks:
- [ ] Basic observability (structured agent logs)
- [x] MLflow tracing ([ADR-0010](adr/0010-agent-tracing.md)), on
      `feat/david/agent-tracing`: per-session capture in `out/traces`, a
      `trace` finally task, optional MLflow exporter, runtime image 1.2.1
      ([agent-runtime.md](agent-runtime.md) — Observability). Validated
      2026-10-30 with real run `remediate-mtfzc`: one experiment, a session
      per role
- [ ] OpenTelemetry exporter for the same traces (Red Hat build of
      OpenTelemetry → Tempo / MLflow OTLP), ADR-0010 — The OpenTelemetry path

### Out of scope for Milestone 1

- OpenShell / Agent Sandbox
- EvalHub
- Developer Hub integration
- NeMo Guardrails / TrustyAI
- Multi-agent with dual-reader
- **LLM-as-a-Judge.** Cut on 2026-10-20 — Phase 6. What it would have caught
  is written down where it bites (Phase 2, the test that asserts the defect);
  until then the gate is deterministic and the reviewer is the judge.
- **The DevSecOps pipeline beyond the inventory.** Cut on 2026-10-20, leaving
  the TPA integration of Phase 3. Three pieces go with it, and each has a
  stand-in for the submission:
  - *The trigger* (webhook, Tekton Triggers `EventListener`). A run starts as
    a `PipelineRun` with the vulnerability record mounted as a ConfigMap —
    reproducible on stage, and it is what the demo shows. Phase 7.
  - *CI on the generated pull request branch.* The run already builds and
    tests the remediated tree before it opens the pull request: a green
    baseline, the exploit test failing then passing, and no regression. A
    second build on the branch would re-prove what `verify` proved, and
    report it in a place the pull request body already states.
  - *Moving the application build into the cluster.* Wanted because
    `sbom.yml` would go red on the demo's own pull requests. Solved instead
    by not publishing that workflow to the demo repository, which costs
    nothing and leaves one producer of the inventory.
- **Read the tool-call traces of `patch` and `exploit`.** The full sequence
  takes 7–11 minutes against a 5-minute demo video, and roughly 90% of that is
  agent sessions, which are a strict data chain and cannot be parallelised —
  overlapping the deterministic steps would save 30–60 seconds of 439 and
  complicate the sequencer where its guarantees live. The time is in turns:
  `patch` spends 16 and `exploit` 14 in the fastest run, both more than
  `analyze`, which does the most reasoning.
  Twice already a phase that looked expensive turned out to be hunting for a
  fact it could have been handed — `analyze` went from 108 turns to 9 with a
  file inventory, `exploit` was spending 28 of 30 calls looking for a jar
  before it got the API signatures. The traces are recorded in
  [docs/measurements/tool-breakdown-2026-10-17.txt](measurements/tool-breakdown-2026-10-17.txt)
  and `trace-summary.js` prints the breakdown on every run, so this costs
  reading rather than measuring. The retry is also worth attacking: runs that
  needed one went from 439s to 649s.
  Not blocking the submission — an edited video covers it, and the retry is
  worth showing rather than hiding, since verification catching an incomplete
  remediation is what separates this from a dependency bump bot.

- **More facts computed instead of deduced.** Five places where a session works
  something out that a command could state. None blocks the demo — the sample
  exercises none of them — and building them now would be code nothing tests,
  which is the lesson of the transitive fixture. Found by reading a session
  trace and asking of each step: *did it deduce this, or could we have told
  it?* Worth repeating on each new trace; these took ten minutes to find.
  1. **The test-result diff.** `verify` is handed the baseline and the
     post-change list and compares them itself. Three tests is free; five
     hundred is two large files in context and a mis-comparison nobody can
     see. Differencing sorted lists is `comm`, and the anti-cheat guarantee —
     a baseline test deleted — should not rest on a model comparing well.
     What is judgement is what a difference *means*, and that stays.
  2. **The patch diff.** `verify` cannot see what changed: it reads files and
     infers what `patch` touched. `git diff` is the central fact for
     attributing a difference to the change, and it is one command.
  3. **Parent-managed versions.** `spring-boot-starter-web` declares no
     version — the Spring Boot BOM sets it. A CVE in such a dependency leaves
     `governed-artifacts.js` reporting `managed` and the agent with nowhere to
     edit, when the right strategy is `dependencyManagement`. Resolvable with
     `mvn help:effective-pom`. This is the normal case in a Spring project.
  4. **Multi-module projects.** One `pom.xml` at the root is assumed
     throughout. A real application has several, and the component can enter
     through one of them.
  5. **The affected dependency's scope.** Present in the tree (`:compile`,
     `:test`) but never pointed at. A vulnerable dependency in test scope is
     not deployed, which changes the urgency and can change the verdict.

  Deliberately excluded: comparing the old and new APIs with `javap` to
  predict breakage. Deterministic, but the compiler already answers it.

- **Transitive-dependency coverage.** The demo application declares its affected
  component directly, so the demo never needs the other path and this is not
  worth building now. Recorded because it is an untested branch rather than a
  missing feature: `vulnerability-analysis.spec.md` requires the analysis to
  tell a transitive dependency from an absent one, every run so far has taken
  the direct path, and nothing has exercised the distinction. If it is broken —
  a misread prompt, the agent reporting `absent` for something merely
  undeclared — the run still ends green with a reassuring and wrong answer.
  Cheap to close when it matters: a `pom.xml` that pulls the component in
  through another dependency, a `git init`, and
  `run-agent.sh --no-clone --workspace`. Worth doing before any real
  application, where most vulnerabilities arrive this way — the case we have
  verified is the minority one.
- RHOAI 3.x **features**. The operator is installed in Phase 0.5 so MLflow stays
  reachable as a nice-to-have, but no Milestone 1 deliverable may depend on an
  RHOAI capability: MaaS alone must be sufficient for the demo to work.

---

## Milestone 2: Post-selection (only if selected)

Full production-quality implementation for the 20-minute live demo at RH One 2027.

### Phase 5: Platform Infrastructure

Specs:
- [ ] `specs/platform/infrastructure.spec.md`
- [ ] `specs/platform/sandbox.spec.md`

Tasks:
- [ ] **Address the deferred review of the Phase 0.5 bootstrap.** PR #4 was merged
      for Milestone 1 with its review comments open
      ([review](https://github.com/lightwell-remediation/lightwell-autonomous-remediation/pull/4#pullrequestreview-5559949861),
      [merge notes](https://github.com/lightwell-remediation/lightwell-autonomous-remediation/pull/4)).
      Main points: `make undeploy` uninstalls RHOAI, Pipelines and MLflow
      through the Application finalizers; sync waves are inert in the documented
      install path; `make smoke` runs twice; `validate.sh` and `wait-platform.sh`
      timeouts do not match what they promise; `setup-secrets.sh` builds an
      unmatchable repo credential from an SSH clone and does not validate
      `APP_REPO`; the `lightwell-lightwell` Secret (`LW_USERNAME` / `LW_PASSWORD`)
      is not created by `make secrets`; the GitOps console plugin is not enabled
      by the chart (the Pipelines one is since 2026-10-27, a PostSync Job in
      `platform/openshift-pipelines`); smaller doc and value drift
      (Application count in the skill, "four Secrets", dead `serviceAccount`
      value, preflight CPU off-by-one) (Roberto)
- [ ] Extend the Phase 0.5 RHOAI 3.x install with the components Milestone 2 needs.
      Most are already Managed, including `trustyai`, which carries the EvalHub
      and NeMo Guardrails CRDs, so what is left is the CRs on top
- [x] Deploy MLflow for tracing and metrics (done in Phase 0.5, sqlite backed;
      Milestone 2 decides whether it needs Postgres and object storage)
- [ ] Version task prompts: move them into the repository and load them from the
      MLflow prompt registry, so each run records which prompt version produced it
      ([agent-runtime.md](agent-runtime.md) — Known limitations)
- [ ] Deploy Agent Sandbox + OpenShell (enterprise isolation). Re-check the Phase 2
      egress allowance to the Lightwell repositories: the sandbox adds its own isolation
      layer on top of the NetworkPolicy, and the Maven build still has to reach the
      Lightwell repositories from inside it
- [ ] Deploy EvalHub for automated evaluation
- [ ] NeMo Guardrails via TrustyAI (optional)
- [ ] **Install TPA in the pipeline's cluster**, as part of the GitOps
      bootstrap, with the Lightwell integration and OSV records loaded,
      replacing the Milestone 1 instance on a separate cluster. Then repoint
      the `TPA_*` values and register the baseline again
      ([workarounds](workarounds.md)). A Milestone 1 limitation stated in
      [replicate.md](replicate.md#limitations-of-milestone-1)

### Phase 6: Multi-Agent Engine (dual-agent + LLM-as-a-Judge)

Specs:
- [ ] `specs/agents/dual-agent.spec.md`
- [ ] `specs/agents/judge.spec.md` — the seams it needs already exist: the
      model is an invocation parameter (`--model`), candidates do not share a
      workspace, and producing one is separated from delivering it, so the
      judge replaces what decides rather than how a remediation is made. What
      it would compare is also already written: each document states how far
      its evidence goes, so a remediation proven by a failing-then-passing
      test is distinguishable from one resting on non-regression. Written here
      in full: it was never in the Milestone 1 scope.
- [ ] `specs/agents/orchestrator.spec.md`
- [ ] `specs/evaluation/patch-quality.spec.md`

Evolution from a single agent to two independent agents plus a judge:
- **Agent A** and **Agent B**: potentially different harnesses and/or models, each
  generating its own PR with a proposed fix.
- **LLM-as-a-Judge**: evaluates both PRs and decides to select the best, request a
  combination/merge of both proposals, or reject both if quality is insufficient.

Tasks:
- [ ] Implement Agent B with a different harness/model than Agent A
- [ ] Configure MaaS providers for both agents (different models)
- [ ] Implement LLM-as-a-Judge receiving both PRs and issuing a verdict
- [ ] Implement merge/combination logic when the judge requests it
- [ ] Implement Orchestrator: trigger → (Agent A ‖ Agent B) → Judge → final PR
- [ ] Validate that divergent agents produce better results than a single one

### Phase 7: Developer Hub + Full Pipeline

Specs:
- [ ] `specs/devsecops/pipeline.spec.md` (extend)
- [ ] `specs/devsecops/developer-hub.spec.md`

Tasks:
- [ ] Integrate with Red Hat Developer Hub (catalog entry, workflow visibility)
- [ ] Full Tekton pipeline: scan → remediate → test → PR
- [ ] Real trigger from Lightwell webhook — Tekton Triggers `EventListener`,
      turning an alert into the vulnerability record and the repository a run
      needs ([pipeline.spec.md](../specs/devsecops/pipeline.spec.md) — the
      trigger requirements). Cut from Milestone 1 on 2026-10-20
- [ ] CI on the generated pull request branch, built where the Lightwell
      credentials already are ([pipeline.spec.md](../specs/devsecops/pipeline.spec.md)
      — The Pull Request Is Built Where the Credentials Already Are). Cut from
      Milestone 1 on 2026-10-20

### Phase 8: Demo Preparation (20 min)

Tasks:
- [ ] Write demo script and narrative
- [ ] Automate demo reset and warmup
- [ ] Record fallback video for critical paths
- [ ] Deploy to RHDP for replicability

---

## Spec Map

| Spec | Domain | Milestone | Phase |
|------|--------|-----------|-------|
| [`cluster-bootstrap.spec.md`](../specs/platform/cluster-bootstrap.spec.md) | platform | M1 | 0.5 |
| `vulnerable-app.spec.md` | standards | M1 | 1 |
| `harness-selection.spec.md` | agents | M1 | 2 (prereq) |
| `agent-runtime.spec.md` | platform | M1 | 2 (prereq) |
| `orchestration-strategy.spec.md` | agents | M1 | 2 (prereq) |
| `vulnerability-analysis.spec.md` | agents | M1 | 2 (Analysis Agent) |
| `exploit-test-generation.spec.md` | agents | M1 | 2 (Analysis Agent) |
| `code-patching.spec.md` | agents | M1 | 2 (Remediation Agent) |
| `fix-verification.spec.md` | agents | M1 | 2 (Remediation Agent) |
| `pr-creation.spec.md` | agents | M1 | 2 (Delivery Agent) |
| `pipeline.spec.md` | devsecops | M1 / M2 | 3, 7 |
| `agent-tracing.spec.md` | observability | M1 (nice-to-have) | 4.5 |
| `infrastructure.spec.md` | platform | M2 | 5 |
| `sandbox.spec.md` | platform | M2 | 5 |
| `dual-agent.spec.md` | agents | M2 | 6 |
| `judge.spec.md` | agents | M2 | 6 |
| `orchestrator.spec.md` | agents | M2 | 6 |
| `patch-quality.spec.md` | evaluation | M2 | 6 |
| `developer-hub.spec.md` | devsecops | M2 | 7 |

## Open Questions

- ~~Which CVE and vulnerable library to use for the demo?~~ → four CVEs in
  `org.apache.cxf:cxf-rt-rs-security-oauth2:4.2.2`, remediated by a Lightwell
  rebuild (the private sample app's README).
  Still open is **reachability**: all four sit in the CXF authorization server
  (`JCacheCodeDataProvider`, `JwtRequestCodeFilter`, `DefaultEncryptingCodeDataProvider`,
  `DefaultEncryptingOAuthDataProvider`), and the sample is a pure resource server —
  an `OAuthRequestFilter` with a string-comparing token validator. None of those
  classes is instantiated, so no exploit test can be written against the app as it
  stands. Roman is working with Exploit Intelligence to add code that does reach
  them. Until that lands, `generate-exploit-test` has no target and the agent can
  only prove non-regression.
- Does the demo show **discovery** of the remediated version, or only its
  **application**? The agent cannot discover it today: the Lightwell OSV records
  need the Lightwell credentials (the same as the Maven repositories), and `claude/settings.json` denies `Bash(curl:*)`, `WebFetch`
  and `WebSearch`. Its only source is the sample README, which already spells out
  the remediated version. Showing discovery means allowing a narrow egress to the OSV
  endpoint and handing the agent the Lightwell credentials — which conflicts with
  the precedent that it never sees a credential. Decide before Phase 4.
- ~~Agentic harness selection~~ → [ADR-0002](adr/0002-claude-code-maas-harness.md) (Claude Code + MaaS)
- Exact Lightwell API/webhook format for triggering remediation. Auth is
  user/password (`LW_USERNAME` / `LW_PASSWORD`, already in
  `secrets/secrets.template.env`); no separate endpoint URL is expected to be
  needed. Still open: whether those credentials are consumed by the Tekton
  trigger task or handed to the agent. That decides where the Secret is mounted
  and whether the agent ever sees them — the PAT precedent argues for the
  pipeline task, since `run-agent.sh` wires the token into git and gh before the
  session starts so it never reaches the agent's context. Decided with the
  trigger, which is Milestone 2 (Phase 7). For the submission the credentials
  are consumed by the runtime, not the agent: the first phase fetches the
  record from Lightwell before its session starts, or the record is mounted as
  a ConfigMap ([ADR-0009](adr/0009-tekton-pipeline-orchestration.md), 2026-10-27).
  Settled in part already: they stay inside the cluster. Putting them in GitHub
  secrets so Actions can build is ruled out, and no longer needed — the
  workflow that would have wanted them is not published to the demo repository
  (Phase 3).
- Should the runtime clone the application repository, or should a prior
  pipeline task hand it a checkout? Moving the clone out would let the agent's
  PAT drop `Contents: Read`, but that is most of the benefit: it still needs
  write access to push a branch and open the pull request. Whatever we decide,
  the agent keeps writing the commit messages and the PR body — that narrative
  is where the remediation documents itself, and a pipeline step cannot produce
  it. The Pipeline now exists (Phase 2), so the two shapes can be compared on
  something real whenever the question is picked up.
- MaaS model availability and rate limits
- ~~Does Claude Code drive a non-Claude MaaS model over `/v1/messages`?~~ → yes,
  proven on 2026-10-09 with `qwen38-27b`: catalog, `/v1/messages` and tool calling
  all work. But the ~60s MaaS request cap limits that model to ~1,300 output
  tokens per reply, which is not enough to write a patch and a test, so the
  end-to-end run needed `claude-sonnet-4-6`.
  See [agent-runtime.md](agent-runtime.md) — Known limitations.
  **MiniMax-M2 was predicted to hit the same wall. It does not, and it still
  fails** — 0 of 5 full runs on 2026-10-19, because it never calls `Write` to
  create a file, shelling out or trying `Edit` on something that does not
  exist. Raising the route timeout would change nothing, which is the trap
  this note nearly set
  ([comparison](measurements/model-comparison-2026-10-19.md)).
- Are vendor telemetry and own OpenTelemetry export independent? Determines whether
  the Phase 4.5 MLflow tracing design works with vendor traffic disabled.
- Whether any Milestone 1 feature actually uses RHOAI 3.x, or only MaaS. The
  operator is installed in Phase 0.5 either way; the open part is whether MLflow
  (Phase 4.5) lands before the deadline and makes that install load-bearing.
- ~~Which registry hosts the `agent-runtime` image for in-cluster runs (internal
  OpenShift registry vs Quay), and who owns the credentials.~~ →
  [ADR-0008](adr/0008-agent-runtime-image-delivery.md): the cluster's own
  registry, built in place by two chained BuildConfigs, so nobody owns registry
  credentials. The two git credentials it does need disappear when the
  repository becomes public in Phase 4.
