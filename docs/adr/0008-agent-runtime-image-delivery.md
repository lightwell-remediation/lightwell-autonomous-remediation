# ADR-0008: Agent Runtime Image Delivery

## Status
Accepted

## Date
2026-10-15

## Layer
Platform

## Context

ROADMAP Phase 0.5 asks for the runtime image to be "published to a registry
reachable from the cluster", and the ROADMAP open questions ask which registry
that is and who owns the credentials.

The constraint comes from [ADR-0003](./0003-agent-runtime-packaging-and-credentials.md):
our image layers on the Red Hat `agentic-starter-kits` Claude Code image, and
upstream forbids redistributing built images because they contain Anthropic's
proprietary binary. So the base image cannot be pulled from anywhere, it has to
be built. `build-image.sh` already does that locally as two chained podman
builds, and ADR-0003 anticipated the cluster shape: "In OpenShift this is two
chained BuildConfigs".

A laptop build does not help a pipeline. The image is 2.2 GB, and pushing it from
a laptop to an external registry on conference wifi is not a plan.

## Options Considered

### Option 1: Build locally, push to Quay

- **Pros:** Any cluster can pull it, including a cluster with no build capability
- **Cons:** Somebody's laptop is in the critical path, and 2.2 GB goes up and
  then down again. Needs a Quay account, a robot token and a pull secret per
  namespace. Hosting a derived image of a non-redistributable base in a registry
  is exactly the thing upstream asked us not to do, even in a private repository
- **GA / support status:** GA

### Option 2: Chained BuildConfigs into the internal registry

- **Pros:** The image is built where it runs, so no external registry, no pull
  secret and no credential owner. Chaining is declarative through
  `dockerStrategy.from` plus an image change trigger. Versions stay pinned in
  git. Matches what ADR-0003 already assumed
- **Cons:** Needs the `Build` and `ImageRegistry` cluster capabilities and a
  registry with real storage. Build pods need egress to GitHub, npm and the Red
  Hat registries. `BuildConfig` is the older build API
- **GA / support status:** GA

### Option 3: Tekton pipeline with buildah

- **Pros:** One build mechanism for the whole project, since Pipelines is being
  installed anyway. Works where the Build capability is disabled
- **Cons:** Chaining two builds becomes pipeline plumbing we would own, and a
  `PipelineRun` is a one-shot object that GitOps cannot hold, so the build stops
  being declarative state and becomes a command to remember
- **GA / support status:** GA

### Option 4: Build once, mirror to the cluster with `oc image mirror`

- **Pros:** No build capability needed in the cluster
- **Cons:** Same laptop in the critical path as Option 1, plus a mirror step
- **GA / support status:** GA

## Decision

Build the image **in the cluster with two chained BuildConfigs**, output to the
**internal registry** in the agent namespace:

| Build | Source | Output |
|---|---|---|
| `upstream-claude-code` | upstream `agentic-starter-kits` at a pinned ref, context `agents/claude-code/deployment` | `upstream-claude-code:<claude-code-version>` |
| `lightwell-agent-runtime` | this repository, `agent-runtime/Containerfile` | `lightwell-agent-runtime:<runtime-version>` (see below) |

The second build sets `dockerStrategy.from` to the first build's ImageStreamTag
and declares an image change trigger, so bumping the harness version rebuilds
both in order without a script. `BASE_IMAGE` is also passed as a build argument,
which keeps the Containerfile identical for podman and for the cluster.

The tag is the **harness version, not `latest`**, so a pod references a specific
build and a version bump is visible in git rather than in whatever `latest`
happens to point at.

This answers the ROADMAP open question: the registry is the cluster's own, and
**nobody owns registry credentials**, because there are none. Pods in the agent
namespace can pull namespace ImageStreams by default.

Preflight checks the two capabilities and the registry storage before anything
is applied, since the whole decision rests on them. If a future cluster has the
`Build` capability disabled, Option 3 is the fallback, and the Containerfile does
not change when that happens.

`build-image.sh` stays as it is for local work. The chained shape is the same in
both places, which is why the Containerfile needs no cluster specific variant.

## Consequences

### Positive

- No external registry, no pull secret, no credential to rotate or to leak
- Upstream's redistribution constraint is respected, because each environment
  builds its own
- A harness version bump is one value in git, and both images rebuild in order
- The build is declarative state, so a cluster rebuilt from git rebuilds the
  image, and `make validate` can assert the ImageStreamTag exists
- 2.2 GB never crosses the internet twice

### Negative

- Two cluster capabilities become hard requirements, and some trimmed clusters
  do not have them
- The first build is slow, around ten minutes for both, and it needs egress to
  GitHub, npm and the Red Hat registries. A disconnected cluster cannot do this
  at all
- While this repository is private the build needs a git source secret, which is
  one more credential in the cluster ([ADR-0007](./0007-in-cluster-credential-delivery.md)).
  It goes away when the repository is made public in Phase 4
- `BuildConfig` is not where OpenShift builds are heading. The fallback exists
  for when that matters

### Neutral

- The internal registry needs storage. On the validation cluster it is a PVC, on
  cloud clusters it is usually object storage, and preflight reports which

## Version Pinning

| Component | Pinned version | Where enforced |
|---|---|---|
| Upstream starter kit | `agents.runtimeImage.upstreamRef` | `deploy/gitops/bootstrap-infra/values.yaml` |
| Claude Code CLI | `agents.runtimeImage.claudeCodeVersion`, also the base image tag | same |
| Agent runtime | `agents.runtimeImage.version`, the runtime image tag | same, and the remediation chart's `image.agent` |
| `gh` CLI | `agents.runtimeImage.ghVersion` | same |

The same three versions are pinned in `agent-runtime/build-image.sh` for local
builds. They have to be bumped in both places, and ADR-0003's validation should
be re-run when they are.

## Amendment 2026-10-27: the runtime has its own version

The runtime image was tagged with the harness version, which does not change
when our layer does, so the pipeline could not name it: it referenced a
`<ref>-<sha>` tag that only `scripts/build-runtime-image.sh` created. On a fresh
cluster the chart's default named a tag that existed nowhere, and the same
commit was built twice.

The runtime now carries a semantic version, `agents.runtimeImage.version`, and
the second build publishes `lightwell-agent-runtime:<version>`. The remediation
chart names the same tag, so a fresh cluster runs the image its own build
produced with no `--set`. A version is never rebuilt with different contents —
that is what keeps `pullPolicy: IfNotPresent` honest — and two things enforce
it: the `runtime-image-version` skill bumps every copy when the image changes,
and `scripts/check-image-version.sh` fails when the copies disagree or the
image changed without a higher version.

Cost: a version bump on a cluster that already ran the previous one does not
build by itself, because an image change trigger does not fire on a config
change; `scripts/build-runtime-image.sh` starts it. A ConfigChange trigger
would, but it fires before the base exists on a fresh cluster (see the
BuildConfig comment).

## Demo Impact

"The agent image is built by the cluster from pinned sources, and the cluster
pulls it from its own registry" is a better answer to a judge asking where the
agent comes from than "we built it on a laptop". It also removes a failure mode
on demo day, since nothing has to be pushed from outside.

## Validation

**2026-10-15**, on an RHDP OpenShift cluster, internal registry on a PVC:

- Both builds complete from the pinned upstream ref and produce
  `lightwell-agent-runtime:<version>` in the agent namespace
- The image change trigger fires the second build when the base tag updates
- A pod in the namespace pulls the image with no pull secret, under an arbitrary
  UID with GID 0, and `claude`, `git`, `gh`, `java`, `mvn` and `node` all resolve
- Two such pods run in parallel, which is the Phase 0.5 capacity target

Still not verified:

- A build behind a proxy or on a cluster with a custom CA
- Whether the pinned commit ref works on every OpenShift builder version, it was
  only exercised on 4.21

## Related Decisions

- [ADR-0003: Agent Runtime Packaging and Credential Model](./0003-agent-runtime-packaging-and-credentials.md)
- [ADR-0006: Cluster Bootstrap Topology](./0006-cluster-bootstrap-topology.md)
- [ADR-0007: In-cluster Credential Delivery](./0007-in-cluster-credential-delivery.md)

## References

- [red-hat-data-services/agentic-starter-kits](https://github.com/red-hat-data-services/agentic-starter-kits)
- [OpenShift builds, Docker strategy](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/builds_using_buildconfig/build-strategies)
- [OpenShift cluster capabilities](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/postinstallation_configuration/enabling-cluster-capabilities)
