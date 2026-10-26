# ADR-0007: In-cluster Credential Delivery

## Status
Accepted

## Date
2026-10-15

## Layer
Platform

## Context

The runtime reads its configuration from environment variables, which locally
come from `secrets/secrets.env` ([ADR-0003](./0003-agent-runtime-packaging-and-credentials.md)).
In the cluster the same variables have to arrive as a Secret, with the same
names, or `run-agent.sh` stops being the same script in both places and the
"debug it on a laptop, run it in the pipeline" property is lost.

Five credentials are in play: the MaaS API key and model configuration, the
repository scoped GitHub PAT, a git credential for the image build to clone this
repository while it is private, a read credential for the reconciler itself for
the same reason, and the Lightwell user and password that Phase 3 will need.

The workshop tree injects its MaaS token into the ArgoCD Application through
`spec.source.helm.valuesObject`. Nothing lands in git, which was the goal there.
It does mean the token sits in an Application spec, readable by anyone who can
read Applications or open the ArgoCD UI, and it ends up in the ArgoCD redis cache
and in the reconciler logs on a bad day. `agent-runtime.spec.md` requires
credential isolation, so that trade is worth revisiting rather than copying.

## Options Considered

### Option 1: Values injected into ArgoCD Applications

- **Pros:** One command, nothing in git, already proven in the workshop tree
- **Cons:** The credential is readable in the Application spec and in the
  reconciler's cache. Rotation means a Helm upgrade of the parent release. A
  reviewer cannot tell from the repository which credentials exist
- **GA / support status:** GA

### Option 2: Imperative Secrets from the local env file

- **Pros:** Credentials never reach git nor the reconciler. Same variable names
  as the local contract, so the runtime does not change. Rotation is one command
  that touches nothing else. Charts reference Secrets by name, so the dependency
  is visible in a review
- **Cons:** A bootstrap step that GitOps does not reconcile. Delete the Secret
  and nothing restores it, the next run just fails
- **GA / support status:** GA

### Option 3: Sealed Secrets or External Secrets Operator

- **Pros:** Encrypted material can live in git, and reconciliation covers
  credentials too. Where this project ends up for Milestone 2
- **Cons:** Another operator and a key or a secret store to own. For a four
  person team with one cluster, the setup cost lands before any benefit
- **GA / support status:** External Secrets is GA, Sealed Secrets is community

### Option 4: One Secret for everything

- **Pros:** One object, one mount, simplest to wire
- **Cons:** Every step that needs the model name also gets the PAT and the
  Lightwell password. The Phase 3 open question of whether the pipeline or the
  agent holds the Lightwell credentials becomes impossible to answer with a mount
- **GA / support status:** N/A

## Decision

Create the credentials **imperatively from `secrets/secrets.env`** with
`deploy/scripts/setup-secrets.sh`, driven by `make secrets`. The script is
idempotent (render and apply, not create), prints no values, and refuses to run
while a required variable still holds its template placeholder.

The variable names in the cluster are **identical** to the local ones, so
`run-agent.sh` reads a mounted Secret the same way it reads the file.

**Credentials are split by consumer**, not bundled:

| Secret | Keys | Consumer |
|---|---|---|
| `lightwell-maas` | `MAAS_BASE_URL`, `MAAS_API_KEY`, `MAAS_MODEL`, `MAAS_SMALL_MODEL` | the agent session |
| `lightwell-github` | `GITHUB_TOKEN`, `APP_REPO`, `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL` | the agent session, for clone, push and the pull request |
| `lightwell-git-source` | `username`, `password`, type `kubernetes.io/basic-auth` | the image build, to clone this repository while it is private |
| `lightwell-repo` | `type`, `url`, `username`, `password`, in `openshift-gitops` | ArgoCD, to read this repository while it is private |
| `lightwell-lightwell` | `LW_USERNAME`, `LW_PASSWORD`, `LW_MAVEN_REPO_URL` | nobody yet, Phase 3 trigger. Created only when the values are set |

The split is what keeps the Phase 3 question open as a mount decision: a trigger
task can read `lightwell-lightwell` without the agent step ever seeing it, and
the agent step gets `lightwell-maas` without the trigger holding the model key.

`lightwell-git-source` is separate and typed, because a git source secret has to
be basic-auth with `username` and `password` keys, which an env-file Secret is
not. It carries the same PAT as `lightwell-github`.

`lightwell-repo` is the one that is easy to forget. The reconciler reconciles
*this* repository, so while the repository is private it needs a credential of
its own, in its own namespace and in the shape ArgoCD recognises. Without it
every Application fails with "Repository not found", which reads like a wrong
path and is not. Both it and `lightwell-git-source` disappear when the
repository is made public in Phase 4.

The repository URL is read from the checkout's `origin` remote rather than
configured, so the credential cannot be written for a repository other than the
one being deployed.

Milestone 2 moves to External Secrets, when there is a secret store to point at
and more than one cluster to keep in step. The variable names do not change when
that happens, which is the point of fixing them now.

## Consequences

### Positive

- No credential in git, in a chart, in a values file or in an Application spec
- A laptop run and a pod run resolve the same configuration from the same names
- Rotating the MaaS key is `make secrets`, and nothing else moves
- Each Phase 3 step can be given the minimum it needs, since the Secrets are
  already split along those lines
- `make validate` can assert the Secrets exist, so a missing credential fails at
  bootstrap time instead of inside a pipeline twenty minutes later

### Negative

- Credentials are outside GitOps, so a cluster rebuilt from git alone is not
  ready until `make secrets` is run. It is in `make deploy-all`, and validate
  fails loudly when it was skipped
- The PAT exists three times in the cluster: `lightwell-github`,
  `lightwell-git-source` and `lightwell-repo`. Rotation has to update all of
  them, which the script does in one pass
- `secrets/secrets.env` stays the source of truth on somebody's laptop, with the
  ownership and expiry problem ADR-0003 already recorded

### Neutral

- The agent container still has the PAT in its environment. ADR-0003 keeps it
  out of the agent's prompt and context, not out of the process environment

## Version Pinning

Not applicable. The contract is the variable names in
`secrets/secrets.template.env`, and the Secret names above.

## Demo Impact

Nothing to show, which is the intent. What is showable is the shape: credentials
split per consumer and a declarative permission file, which is a concrete answer
when someone asks what "enterprise guardrails" means before NeMo Guardrails
exists.

## Validation

**2026-10-15**, on an RHDP OpenShift cluster:

- `make secrets` created the four Secrets with the keys above, and re-running it
  changed nothing else. The Lightwell one is skipped while those values are empty
- A placeholder left in a required variable stops the script, and no Secret is
  written
- `git status` stays clean, and the repository scan finds no credential
- The MaaS key and model were verified against the gateway before being written,
  with `/v1/models` and a `/v1/messages` call returning the pinned model

## Related Decisions

- [ADR-0003: Agent Runtime Packaging and Credential Model](./0003-agent-runtime-packaging-and-credentials.md)
- [ADR-0006: Cluster Bootstrap Topology](./0006-cluster-bootstrap-topology.md)

## References

- [`secrets/secrets.template.env`](../../secrets/secrets.template.env)
- [Agent runtime spec, Credential Isolation](../../specs/platform/agent-runtime.spec.md)
- [OpenShift builds, source secrets](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/builds_using_buildconfig/creating-build-inputs)
