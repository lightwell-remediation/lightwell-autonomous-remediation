---
name: runtime-image-version
description: >-
  Bump the agent runtime image version (lightwell-agent-runtime:<version>)
  whenever what goes into the image changes, and keep every copy of the
  version in step. Use after changing anything under agent-runtime/ (other
  than tests and docs), the agent-runtime-image chart, or a runtime image pin
  in bootstrap-infra (claudeCodeVersion, ghVersion, upstreamRef); when
  scripts/check-image-version.sh fails; or when the user says "bump the image",
  "sube la versión de la imagen", runtime-image-version.
---

# Runtime image version

The agent runtime is published as `lightwell-agent-runtime:<version>`. The
cluster's own build produces that tag, and the remediation chart pulls it with
`pullPolicy: IfNotPresent`. A version therefore names **one** image forever: if
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
- [ ] 2. Set it in all three places
- [ ] 3. scripts/check-image-version.sh passes
- [ ] 4. Note the bump in the commit message
- [ ] 5. After merge, roll it out to running clusters
```

### 2. The three copies

| File | Key |
|---|---|
| `deploy/gitops/bootstrap-infra/values.yaml` | `agents.runtimeImage.version` — what the build publishes |
| `deploy/gitops/deployments/agents/agent-runtime-image/values.yaml` | `runtimeVersion` — the chart default, kept equal |
| `deploy/gitops/deployments/agents/remediation-pipeline/values.yaml` | the tag at the end of `image.agent` — what the pipeline pulls |

### 3. Check

```bash
scripts/check-image-version.sh            # against origin/main
```

It fails when a copy disagrees, when the version is not `MAJOR.MINOR.PATCH`,
or when the image changed without a higher version. Do not open the pull
request until it passes.

### 4. Commit

Same commit as the runtime change, or a `chore(agent-runtime): bump image to
X.Y.Z` right after it on the same branch. Say why in the body, in one line.

### 5. Roll out

On a fresh cluster nothing is needed: the build publishes the new tag on its
own. On a cluster that already ran the previous version, the BuildConfig's
output tag changes when ArgoCD syncs the merge, but an image change trigger
does not fire on a config change, so start the build and reinstall the chart:

```bash
scripts/build-runtime-image.sh            # builds <version> if it is missing
helm upgrade --install remediation-pipeline \
  deploy/gitops/deployments/agents/remediation-pipeline \
  --namespace lightwell-agents --wait
```

## Do not

- Rebuild an existing version with different contents (`--rebuild` is for a
  build that failed, not for shipping a change)
- Commit a `wip-` tag in `image.agent`; those come from
  `scripts/build-runtime-image.sh --from-dir` and exist only to try a change
- Reuse or lower a version, even after a revert — move forward
