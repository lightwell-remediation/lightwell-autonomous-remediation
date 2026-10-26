---
name: no-secrets
description: >-
  Scan staged and unstaged changes for secrets and credentials before git
  add, commit, push, or PR creation. Use when committing, pushing, creating
  a PR, adding env/token files, writing kubeconfigs, or when the user asks
  to check for secrets. Blocks committing secrets to this public repo.
---

# No Secrets Scan

Mandatory gate before any git write that could publish credentials. Complements the always-on `no-secrets` rule and `.gitignore`.

## When to run

| Trigger | Action |
|---|---|
| User asks to commit, push, or open a PR | Scan first; abort if findings |
| Agent about to `git add` / `git commit` | Scan first |
| Creating `*.env`, token, or kubeconfig files | Confirm gitignore covers them |
| User asks “check for secrets” / “hay credenciales?” | Run full scan |

## Workflow

Copy and complete:

```
Secret scan:
- [ ] 1. List candidates (status + diff)
- [ ] 2. Match deny-list filenames
- [ ] 3. Grep content for secret patterns
- [ ] 4. Pass → proceed with git / Fail → stop and report
```

### 1. List candidates

```bash
git status --short
git diff --name-only
git diff --cached --name-only
```

Include untracked files that would be added.

### 2. Filename deny-list

**Block** (never stage/commit):

- `.env`, `*.env` except `*.env.example` / `.env.example`
- `token.env`, `*-token.env`, `*credentials*`, `*secret*` files with real data
- `*.key`, `*.pem`, `*.p12`, `*.pfx`, `kubeconfig`, `kubeconfig*`
- `credentials.json`, `service-account*.json`, `*-sa.json`
- `.docker/config.json`, pull-secret YAML with `.dockerconfigjson` data

**Allow**: `*.env.example`, docs describing secret *bootstrap*, Helm values with empty/placeholder strings.

### 3. Content patterns

Search staged + unstaged diffs and candidate files for:

| Pattern family | Examples |
|---|---|
| Assignments | `password=`, `api_key=`, `token=`, `client_secret=` with non-placeholder values |
| Cloud / AI keys | `AKIA…`, `sk-…`, `ghp_…`, `glpat-…`, `xox[baprs]-…` |
| Bearer / JWT | `Bearer eyJ…`, long `eyJ…` JWTs |
| Private keys | PEM/OpenSSH armor headers (`BEGIN` + optional `RSA`/`OPENSSH` + `PRIVATE KEY`) |
| Kube / Docker | `kind: Secret` with non-empty `data:` / `stringData:` real values |

Ignore obvious placeholders: `CHANGE_ME`, `REPLACE_ME`, `<token>`, `xxx`, `your-token-here`.

### 4. Outcome

**Pass** — continue with commit/PR workflow.

**Fail** — do **not** `git add` / commit / push / create PR. Report:

1. File path(s)
2. Why it looks like a secret (filename vs content)
3. Remediation:
   - Move value to env var / cluster Secret / sealed secrets
   - Add path pattern to `.gitignore` if missing
   - Commit only `*.env.example` with fake values
   - If already committed historically: rotate the credential and purge from git history (warn user; do not force-push unless they ask)

## Integration

- Before commits: run this skill (user commit rule already forbids secret files).
- Before PRs: run this skill as step 0 of `create-pr`.
- Rule: `.cursor/rules/no-secrets.mdc` (always apply).

## Do not

- Stage files matching the deny-list “just this once”
- Put real tokens in commit messages, PR bodies, or skill/docs examples
- Commit Kubernetes Secrets with live `data` / `stringData`
