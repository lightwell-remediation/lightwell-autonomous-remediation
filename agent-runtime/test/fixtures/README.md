# Test fixtures

Inputs and expected outputs that let a stage be tested without running an agent.

| File | What it is |
|---|---|
| `analysis.remediable-not-reachable.json` | An `analysis.json` from a green `analyze` run: affected component present as a direct dependency, a remediating version published, vulnerable code **not** reachable — the demo application as it stands. |
| `analysis.remediable-reachable.json` | The same, against a fixture where the application does call the flawed class: verdict **reachable**. |
| `patch.patched-with-source-change.json` | A `patch.json` where the remediation needed more than a version bump: one source change and three tests added. |
| `exploit.demonstrated.json` | An `exploit.json` for a test that failed against the unmodified application — the verdict the runtime observed, not the session's claim. |
| `verification.verified-with-demonstration.json` | A `verification.json` where the defect was exercised: the exploit test failed before the change and passes after. |
| `delivery.delivered.json`, `pr-narrative.example.json`, `pr-body.example.md` | What delivery produced: the record of the pull request, its title and commit message, and the markdown body as it appeared. |

It is built from CVE-2026-68079 rather than any of the other three affecting the
same artefact. All four produce an equivalent analysis — same component, same
remediating version, all four vulnerable classes living in the authorization
server the demo application does not use — so the choice does not matter here.
It matters for the stage after this one: 68079 is an authorization code replay,
provable by redeeming the same code twice and asserting the second attempt
fails. CVE-2026-57818 covers the same ground through a race condition, and a
test that depends on scheduling can pass against a vulnerable build. Keeping the
fixture on the CVE the demo will actually use avoids building the later stages
against a scenario we then abandon.

`analysis.remediable-not-reachable.json` is the handoff document the stages after
analysis consume. Use it to develop and test patching, verification and pull
request creation without spending a model call — a single `analyze` run costs
roughly three minutes and takes a variable number of turns, which is not
something to put in a test loop.

Regenerate it from a run whose exit status was zero:

```bash
cp .workspace/out/analysis.json \
   agent-runtime/test/fixtures/analysis.remediable-not-reachable.json
node agent-runtime/lib/check-analysis.js \
   agent-runtime/test/fixtures/analysis.remediable-not-reachable.json
```

These are also the mocks the orchestration work will replay. A phase is a
prompt in and a document out, so the sequencing can be exercised by handing
back a recorded document instead of starting a session — seconds and nothing,
rather than minutes and a model call per attempt. Keep the output of every
good run, and of the failing shapes too (`cannot-patch`, `regression`,
`cannot-verify`): those are the branches the sequencer has least cover on, and
a hand-written document drifts from what the agent actually emits.

OSV records are deliberately **not** kept here. They are served from a
credentialed endpoint, and once the pipeline exists it retrieves them itself;
locally they go in the gitignored `.fixtures/` directory.
