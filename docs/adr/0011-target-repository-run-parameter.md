# ADR-0011: The Target Repository Is a Run Parameter

## Status
Accepted

## Date
2026-11-03

## Layer
Agents

## Context

One vulnerability usually reaches many applications at once. The
orchestration spec already allows runs against different applications to
proceed concurrently — the lock is per application
([One Run per Application](../../specs/agents/orchestration-strategy.spec.md))
and the dependency cache is ReadWriteMany for that reason — but the runtime
could not do it.

Every phase cloned `APP_REPO`, and `APP_REPO` came from the `lightwell-github`
Secret ([ADR-0007](./0007-in-cluster-credential-delivery.md)): one value per
namespace. `run-remediation.sh` read the same Secret to build the run's
`application` param and its lock label, so the lock and the clone agreed only
because there was nothing else to read. Two runs started together against
different applications would have needed two values of one Secret.
`docs/replicate.md` said so: one application at a time, switched by editing
the Secret between runs.

The fix has two halves, and only the first is a choice:

1. Where a run takes its repository from.
2. Making the shared dependency cache safe for concurrent writers. Maven 3.9.9
   in the runtime image ships Maven Resolver 1.9.22, whose default lock,
   `rwlock-local`, only coordinates threads within one JVM. Two pods writing
   the same cold entry are not coordinated at all. The resolver's own
   `file-lock` factory with the `file-gav` name mapper is the documented way
   to share one local repository between processes.

## Options Considered

### Option 1: The repository is a PipelineRun parameter; one token covers every target

The run carries `repository` (`owner/repo`). Every phase passes it to
`run-agent.sh --repo`, which already preferred `--repo` over the
environment. `run-remediation.sh` derives both the lock label and the
parameter from one input, `--repo`, defaulting to the Secret's `APP_REPO`
so a single-application deployment keeps working unchanged.

- **Pros:** the repository is a property of the request, like the record,
  the branch and the model already are; no new Secret, no new RBAC; the lock
  and the clone cannot disagree; local runs are unchanged.
- **Cons:** the fine-grained PAT has to be scoped to every target repository,
  so a leaked token reaches all of them rather than one.

### Option 2: One Secret per application, selected by a run parameter

`lightwell-github-<app>`, each with its own narrowly scoped PAT, chosen per
run.

- **Pros:** the blast radius of a token stays one repository.
- **Cons:** Tekton cannot select an `envFrom` Secret by a parameter, so each
  phase would need a workspace bound per run or a lookup step with API
  access the agent's account deliberately does not have (ADR-0009). One
  `make secrets` input per application, and onboarding an application becomes
  a credential operation.

### Option 3: One namespace per application

Duplicate the whole deployment per target.

- **Pros:** complete isolation, including the cache.
- **Cons:** a deployment per repository; every namespace pays its own cold
  cache, which is exactly what the shared cache exists to avoid.

## Decision

**Option 1.** The target repository is a run parameter, and one PAT scoped to
every target repository is the credential. Per-application Secrets (Option 2)
are deferred to Milestone 2, when External Secrets gives a store to select
from. `APP_REPO` in `lightwell-github` remains as the default for runs that
name no repository.

The cache is made safe in the same change: every step that runs Maven gets
`MAVEN_OPTS` selecting `file-lock` and `file-gav`. It is set in the chart,
not the image, so it applies exactly where the shared volume is mounted and
needs no image rebuild.

## Consequences

### Positive

- Runs against different applications, including several with the same
  vulnerability, can be started together and each delivers to its own
  repository.
- Onboarding another application is adding it to the token's scope; nothing
  in the cluster changes.
- The cache is safe for concurrent writers whatever the concurrency turns out
  to be, not only at the level tested.

### Negative

- The PAT's scope grows with the number of applications. Mitigated by
  fine-grained scoping (Contents and Pull requests read/write, no
  administration) and revisited by Option 2 in Milestone 2.
- `file-lock` relies on POSIX advisory locks on the cache volume. CephFS
  supports them; an RWX class that does not would serialise nothing, silently.
- Concurrency is a budget, not an enforced limit: N runs are N agent pods and
  N sessions against MaaS.

### Neutral

- ADR-0007's table still lists `APP_REPO` in `lightwell-github`; its meaning
  narrows to "the default repository".

## Demo Impact

A single advisory can be shown fanning out to several applications, each run
producing its own pull request, instead of being remediated one repository
at a time.

## Validation

<!-- TODO: fill in after the cluster run -->

## Related Decisions

- [ADR-0007: In-cluster Credential Delivery](./0007-in-cluster-credential-delivery.md) — `APP_REPO` becomes a default
- [ADR-0009: Orchestrate the Remediation Sequence as a Tekton Pipeline](./0009-tekton-pipeline-orchestration.md) — the per-application lock

## References

- [Orchestration spec — Concurrent Runs on Different Applications](../../specs/agents/orchestration-strategy.spec.md)
- [Maven Resolver 1.9.22 configuration (`aether.syncContext.named.*`)](https://maven.apache.org/resolver-archives/resolver-1.9.22/configuration.html)
- [Maven Resolver named locks (`file-lock`, `file-gav`)](https://maven.apache.org/resolver-archives/resolver-1.9.22/maven-resolver-named-locks/index.html)
- [GitHub fine-grained personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
