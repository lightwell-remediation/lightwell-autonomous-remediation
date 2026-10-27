---
name: runtime-image-version
description: >-
  Bump the agent runtime image version (lightwell-agent-runtime:<version>)
  whenever what goes into the image changes. The version lives in one place,
  agents.runtimeImage.version in deploy/gitops/bootstrap-infra/values.yaml. Use after changing anything under agent-runtime/ (other
  than tests and docs), the agent-runtime-image chart, or a runtime image pin
  in bootstrap-infra (claudeCodeVersion, ghVersion, upstreamRef); when
  scripts/check-image-version.sh fails; or when the user says "bump the image",
  "sube la versión de la imagen", runtime-image-version.
---

# Runtime image version

The agent runtime is published as `lightwell-agent-runtime:<version>`. The
version is set in **one place**, `agents.runtimeImage.version` in
`deploy/gitops/bootstrap-infra/values.yaml`. ArgoCD hands it to the image build,
which publishes that tag, and to the remediation Pipeline, which pulls it with
`pullPolicy: IfNotPresent`. Neither chart has a version of its own. A version therefore names **one** image forever: if
the contents changed under the same tag, a node that cached the old layers would
keep running them, and nobody could say which runtime produced a pull request.

## When to bump

| Changed | Bump? |
|---|---|
| `agent-runtime/` — scripts, `lib/`, `prompts/`, `claude/`, `Containerfile` | Yes |
| `deploy/gitops/deployments/agents/agent-runtime-image/` (build args, templates) | Yes |
| `claudeCodeVersion`, `ghVersion`, `upstreamRepo`, `upstreamRef`, `appRepo`, `appRepoRef` under `agents.runtimeImage` in `deploy/gitops/bootstrap-infra/values.yaml` | Yes |
| `agent-runtime/test/`, Markdown under `agent-runtime/` | No — not copied into the image |
| Anything else (pipeline chart, docs, deploy scripts) | No |

`scripts/check-image-version.sh` applies exactly this table against
`origin/main`, so when in doubt run it.

## Which number

Semantic versioning, `MAJOR.MINOR.PATCH`, judged by what a pipeline that pulls
the image would notice:

| Change | Part | Example |
|---|---|---|
| The invocation contract or a phase document's shape changes (a `run-agent.sh` flag removed or renamed, a field a later phase or the chart reads) | MAJOR | `--osv` renamed |
| New capability, compatible with existing callers (a new flag, a new role, a prompt change that alters what the agent does) | MINOR | `--vulnerability` added |
| Fix with no new behaviour; a pin bump of the harness or a tool | PATCH | gate bug fixed, `ghVersion` bumped |

## Workflow

```
Runtime image version bump:
- [ ] 1. Decide the new version from the tables above
- [ ] 2. Set it in bootstrap-infra
- [ ] 3. scripts/check-image-version.sh passes
- [ ] 4. Note the bump in the commit message
- [ ] 5. After merge, roll it out to running clusters
```

### 2. The one place

`agents.runtimeImage.version` in `deploy/gitops/bootstrap-infra/values.yaml`.
Do not add a version to `agent-runtime-image/values.yaml` (`runtimeVersion`)
or to `remediation-pipeline/values.yaml` (`image.agent`): both are left empty
on purpose, and the check fails if either is set.

### 3. Check

```bash
scripts/check-image-version.sh            # against origin/main
```

It fails when a chart carries its own version, when the version is not
`MAJOR.MINOR.PATCH`, or when the image changed without a higher version. Do not open the pull
request until it passes.

### 4. Commit

Same commit as the runtime change, or a `chore(agent-runtime): bump image to
X.Y.Z` right after it on the same branch. Say why in the body, in one line.

### 5. Roll out

On a fresh cluster nothing is needed: the build publishes the new tag on its
own, and ArgoCD points the Pipeline at it. On a cluster that already ran the
previous version, ArgoCD moves both the BuildConfig's output tag and the
Pipeline's image when it syncs the merge, but an image change trigger does not
fire on a config change, so start the build:

```bash
scripts/build-runtime-image.sh            # builds <version> if it is missing
```

Until it completes, a run would pull a tag that does not exist yet.

## Do not

- Rebuild an existing version with different contents (`--rebuild` is for a
  build that failed, not for shipping a change)
- Put a `wip-` tag in a chart; those come from
  `scripts/build-runtime-image.sh --from-dir` and are tried on one run with
  `scripts/run-remediation.sh … --image <ref>`
- Reuse or lower a version, even after a revert — move forward
