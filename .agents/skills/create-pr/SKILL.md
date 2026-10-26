---
name: create-pr
description: >-
  Create GitHub pull requests for lightwell-autonomous-remediation using the
  project PR template (Summary, Details, Test plan). Use when the user asks
  to open a PR, create a pull request, or merge a branch.
---

# Create Pull Request

Create PRs for **lightwell-autonomous-remediation** following the Summary/Details/Test plan structure.

Also follow the user rule workflow: `git status`, `git diff`, branch tracking, `git log`, then `gh pr create`.

## Title format

Conventional Commits prefix + concise scope:

```
feat(multi-agent): add dual-reader orchestrator
fix(pipeline): correct Tekton task ordering
docs: document Developer Hub integration
```

## Body template (required sections)

Use this structure exactly — three sections, no extras unless the change warrants a fourth (e.g. **Breaking changes**):

```markdown
## Summary

- <bullet 1: primary deliverable>
- <bullet 2: secondary deliverable or tooling>
- <bullet 3: docs/skills/validation if applicable>

## Details

<1–3 sentences: why this change exists, what problem it solves, link to AGENTS.md or roadmap if relevant.>

| <Column A> | <Column B> |
|------------|------------|
| ...        | ...        |

Key findings during testing:
- <finding 1>
- <finding 2>

## Test plan

- [ ] <verification step 1>
- [ ] <verification step 2>
```

### Section rules

**Summary** (3–5 bullets max):
- Outcome-focused, not a file list
- Mention charts, scripts, skills, or docs by name when relevant

**Details**:
- Explain *why* and architectural context
- Use a **table** when multiple components/charts/files are added
- **Key findings during testing** — only real discoveries from cluster/local validation. Omit if nothing was tested.

**Test plan**:
- Checklist with `- [ ]` (open) or `- [x]` (done before PR)
- Include cluster name/context when tested on OCP
- Reference `make` targets or scripts

## Workflow

0. **Secret scan** — run the `no-secrets` skill on all staged/unstaged/untracked changes. If anything matches the deny-list or secret patterns, **stop**; do not push or create the PR.
1. Gather changes: `git status`, `git diff`, `git log` vs base branch.
2. Draft title + body from template above.
3. Push branch: `git push -u origin HEAD`
4. Create PR:

```bash
gh pr create \
  --title "feat: ..." \
  --body "$(cat <<'EOF'
## Summary
...
EOF
)"
```

5. Return the PR URL to the user.

## Merge policy

- **1 approval** required to merge to `main`
- Squash merge preferred for feature branches

## Assignee

Do **not** set a default assignee. Only add `--assignee` when the user explicitly requests a specific person.

## Do not

- Skip **Details** or **Test plan**
- Use only a bullet list of changed files as the whole PR body
- Claim testing in Test plan without evidence from the session
- Push or create PR unless the user asked
- Include secrets, tokens, kubeconfigs, or real credentials in the PR (see `no-secrets`)
