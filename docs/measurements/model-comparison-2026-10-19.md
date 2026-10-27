# Which model runs the remediation — 2026-10-19

Supersedes the first half of `model-campaign-2026-10-19.md`, which measured
`claude-haiku-4-5` and `minimax-m2` before two harness defects were found.
Both defects are fixed; the conclusion did not change.

**Decision for Milestone 1: `claude-sonnet-4-6`.** The rest is revisited
after the submission.

| Model | Delivered | Of those, changed source | Cost/run |
|---|---|---|---|
| `claude-sonnet-4-6` | **6/7** | **6/6** | $0.73–0.98 |
| `claude-opus-4-6` | 2/4 | **1/2** | $1.36–1.58 |
| `claude-haiku-4-5` | 0/5 | — | $0.13–0.23 |
| `minimax-m2` | 0/5 | — | $0.23–1.90 |

Opus costs roughly twice what Sonnet does, delivers less often, and produced
the single worst artefact of the day. There is no case for it at Milestone 1.

## Two harness defects the comparison found

Neither was visible with Sonnet alone, which is the argument for running
other models even when none of them wins.

**The turn budget never reached the cluster.** `secrets.env` sets
`MAX_TURNS=40`; nothing carried it, so every in-cluster session ran on
`run-agent.sh`'s fallback of 25. Sonnet fits in 25 and never revealed it. A
weaker model died with "turn budget exhausted after 26 turns" and looked
like a model that could not converge. Fixed in the chart.

**A denied action failed the whole run.** One exploratory command the agent
immediately worked around — `find … ; ls …` from Opus, an allowed `mvn`
piped through `tail` from Sonnet — discarded everything the session had
done. The policy is the guardrail and still blocks the action; failing the
run on top was a second, blunter rule. The verdict now belongs to the role's
output gate, which reads the document and knows whether the work got done.
Pinned by `agent-runtime/test/check-result.test.sh`, which replays the exact
`result.json` shapes those runs emitted — no model, no cluster.

After the second fix Opus stopped dying at the permission wall and started
being judged on its work, which is where the next finding came from.

## The finding that matters: "failed before, passes after" is not enough

Opus delivered PR #17 (private demo repository)
with every gate green and the application still vulnerable. Its test:

```java
void secondRedemptionReturnsPreviouslyAuditedGrantNotFreshOne() {
    assertThat(second).isSameAs(first);
}
```

It asserts that redeeming a code twice returns the same grant — which **is**
the defect. The mechanics fit perfectly:

- against the vulnerable library, the second call returns a fresh grant, so
  the assertion fails → *failed before*
- after the version bump, the library returns null, the application's
  fallback serves the audited copy, and the assertion holds → *passes after*

So the evidence chain reported a demonstrated defect, a verified remediation
and a deliverable pull request, for a change that moved a version number and
left the fallback in place. A test asserting the defect also forbids ever
fixing it: a real remediation would turn it red.

`exploit.md` already says *"State the contract, not the bug. Assert what the
application is supposed to do."* Opus ignored it and nothing downstream
could tell.

**This is not fixable with another deterministic gate.** Whether an
assertion expresses a security guarantee or its negation is a judgement.
"Failed before, passes after" proves behaviour changed, not that it changed
in the right direction — and that gap is exactly what the Milestone 2
LLM-as-a-Judge is for. It is now evidence rather than architecture.

Sonnet asserts the contract (`secondRedemptionReturnsNull`,
`authorizationCodeCannotBeRedeemedMoreThanOnce`) in every run examined. That
is a difference in judgement, not in plumbing, and it is the reason for the
decision above.

## Why haiku and minimax fail

Unchanged by either fix: **neither creates a file with `Write`.** They shell
out — `cat > … << EOF`, `touch`, `echo >`, `python3 -c … >` — or try `Edit`
on a file that does not exist, although `Write(//**/src/test/**)` is allowed
and the prompt says to use it. minimax says so itself: *"cannot create
files. Bash blocked, Edit requires existing file."* It is wrong.

An attempt to fix it by naming the tool more emphatically in the prompts was
reverted: it bought nothing for either model and coincided with a Sonnet
run failing, which is too high a price for an experiment that was not
working.

## One change that helped everyone

The exploit role could only `test-compile`, never run the test it wrote, and
the runtime judged it after the session had ended. It was asked for a test
that fails for a named reason and given no way to check. It can now run its
own named test, and the prompt requires it to. The runtime still executes
the test independently afterwards — generation did not become its own judge.
