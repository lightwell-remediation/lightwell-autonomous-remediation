# First real runs through the Tekton Pipeline — 2026-10-17

Two end-to-end runs in `lightwell-agents`, against
`lightwell-remediation/lw-apache-cxf-demo` at `feat/reachable-cve`, the
Lightwell record for CVE-2026-68079, model `claude-sonnet-4-6`.

| | Cold cache | Warm cache |
|---|---|---|
| Run | `remediate-6brkh` | `remediate-4v4xq` |
| Wall clock | **48m08s** | **11m46s** |
| Outcome | delivered, [PR #9](https://github.com/lightwell-remediation/lw-apache-cxf-demo/pull/9) | delivered, [PR #10](https://github.com/lightwell-remediation/lw-apache-cxf-demo/pull/10) |
| Patching attempts | 2 | 2 |

## Where the warm run's time goes

| Task | Duration |
|---|---|
| claim-application | 0m06s |
| analyze | 0m54s |
| baseline | 0m13s |
| demonstrate | 2m55s |
| patch-and-verify (2 attempts) | 4m22s |
| deliver | 1m09s |
| outcome | 0m05s |
| **sum of tasks** | 9m44s |
| **wall clock** | 11m46s |

The two-minute gap is pod scheduling and image pulls across seven tasks.
Worth knowing before anyone tries to compress this into a demo slot: it is
not work, and it is not something the agent can be asked to do faster.

Cost of the warm run, summed over six sessions: **$1.11**. Patching and
verification account for $0.65 of it across two attempts.

## The cold cache is repository ordering, not bandwidth

Thirty-seven of the cold run's forty-eight minutes were
`mvn -B dependency:tree`. It was not slow storage and not slow transfer —
measured inside the pod, 200 small files on the CephFS cache took 54ms and
Maven Central answered in 81ms at 650 kB/s.

It is that every artifact is attempted against the three Lightwell
repositories in `settings.xml` before Central answers. Three or four round
trips per artifact, for a
tree of several hundred. The resulting cache left 71 `.lastUpdated` markers,
one per metadata fetch that found nothing.

This is paid once per set of dependencies, and the warm run above is what
happens afterwards. Two things follow: **warm the cache before any
demonstration**, and the repository ordering in the application's
`settings.xml` is worth revisiting — Central first for everything the
Lightwell repositories do not govern would remove most of those round trips.

## The retry is load bearing in a real run too

Both runs needed it, and for the same reason the exploit test exists.

The first patching attempt moved `cxf.version` to the Lightwell rebuild and
stopped there. Verification re-ran the generated test — the one demonstrated
to fail against the unmodified application — and it **still failed**, so the
attempt was returned as a regression rather than delivered:

> the exploit test asserts that a second call to `removeCodeGrant` with the
> same code must return null, and it still fails at the remediated version. It is
> therefore not established that upgrading the `cxf.version` property alone
> is sufficient to close the defect.

The second attempt, carrying that evidence, changed
`AuditedCodeDataProvider.java` as well, and verification passed.

Without the generated test this would have been a version bump on an
application that stayed vulnerable, with every component reporting success —
the failure that
[`exploit-test-generation.spec.md`](../../specs/agents/exploit-test-generation.spec.md)
was written for. Four runs now have the same shape: five local runs earlier
gave two first-attempt and two second-attempt successes; both of these
needed the second.

## What was confirmed about the orchestration

- `--branch` selects the base: both runs cloned `feat/reachable-cve` and
  opened their pull requests against it.
- `retries: 1` fired exactly once in each run (`retriesStatus` holds one
  entry), and the second attempt read the first's `verification.json` from
  the shared workspace.
- The per-run workspace claim was created and destroyed both times; the
  cache claim survived. Across 29 runs in the namespace no per-run claim
  remains.
