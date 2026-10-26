# minimax-m2 and claude-haiku-4-5 through the pipeline — 2026-10-19

Three runs of the full sequence per model, serial, against
`lightwell-remediation/lw-apache-cxf-demo` at `feat/reachable-cve`, the
Lightwell record for CVE-2026-68079. Warm dependency cache. `claude-sonnet-4-6` is
the control, measured on 2026-10-17.

| Model | Usable | Delivered | Median | Cost/run |
|---|---|---|---|---|
| `claude-sonnet-4-6` (control) | **2/2** | 2/2 | 11m46s | $1.11 |
| `claude-haiku-4-5` | **0/3** | 0/3 | 3m20s | $0.18 |
| `minimax-m2` | **0/3** | 0/3 | 1m55s | $1.31 |

*Usable* means delivered **and** the source was changed. A run that only
moves `cxf.version` leaves the application vulnerable, so a green one that
did nothing else would not count either — but the question did not arise:
nothing reached delivery.

| Run | Stopped at | Denied Bash calls |
|---|---|---|
| haiku 1 | demonstrate | 3 |
| haiku 2 | demonstrate | 1 |
| haiku 3 | demonstrate | 1 |
| minimax 1 | demonstrate | 6 |
| minimax 2 | **analyze** | 0 |
| minimax 3 | demonstrate | 2 |

## One cause, in every run

**Neither model creates a file with the `Write` tool.** They reach for the
shell, which is denied, or for `Edit`, which needs the file to exist.

minimax's own output says it plainly, after five refused attempts:

> Technical constraint: cannot create files. Bash blocked, Edit requires
> existing file.

It is wrong, and that is the finding. `Write` was available the whole time:

```
Write(//**/src/test/**)
Write(//**/out/exploit-intent.json)
```

And the prompt names the constraint, at `exploit.md:59`:

> Use the file-writing tools, never the shell. A `cat > file << EOF` is
> refused

So this is not a permission policy that is too tight, and not a prompt that
forgot to say. The allowed path exists, the prompt points at it, and both
models walk past it — `cat > … << EOF`, then `touch`, then `echo >`, then
`python3 -c … >`, each one refused in turn.

`minimax-m2` run 2 is the clearest case, because it failed in `analyze`,
where the policy grants **no shell at all** (ADR-0005). Fifteen turns, no
denials, one `Edit`, and no document produced. With nothing to shell out to,
it tried to `Edit` a file that did not exist and stopped.

## Two further observations

**Both models ignore "Add, Do Not Alter".** haiku edited the existing
`HelloWorldResourceTest.java` five times in one run; minimax twice. That
rule exists because the baseline comparison requires every existing test to
survive unmodified, and `fix-verification.spec.md` fails a run where one did
not. Even had the file-writing problem been solved, these runs were heading
for a rejected verification.

**minimax is the expensive failure.** $1.31 per run that produced nothing,
against $1.11 for a complete sonnet run that opened a pull request. The
reason is visible from the first smoke test: it emits its reasoning as
`<think>` text in the response content, and a trivial "reply with OK" prompt
exhausted a 64-token ceiling before answering. haiku failing costs $0.18,
which at least makes it cheap to retry.

## What was not tested

**Whether tolerating denials would rescue them.** `TOLERATE_DENIALS=1` lets
a session continue past a refusal instead of failing the run, which would
give a model more chances to find `Write`. It would not have helped minimax
run 2, where there was no denial to tolerate — but it is the obvious next
experiment and costs roughly $2–4.

**Whether a prompt change would.** The instruction is present but stated
once, in prose. ADR-0005 found that a weaker model will not reach for `Glob`
even when the policy allows it, and the fix was to hand it the data rather
than expect it to discover the route. The same shape of fix may apply here:
name the tool at the point of use rather than in a rules section. Worth one
attempt before concluding these models cannot do the job — though it
competes with simply using the model that already can.

## Conclusion for Milestone 1

Neither is a substitute for `claude-sonnet-4-6` as things stand. Both fail
before producing any evidence, consistently, for the same reason.

The pipeline came out of this well. Six runs that could not do the work
produced six honest failures, each naming the phase that stopped it, and not
one opened a pull request. That is the exit-status contract and the
output-contract gates doing exactly what they are for.
