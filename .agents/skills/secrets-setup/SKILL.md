---
name: secrets-setup
description: >-
  Create and validate secrets/secrets.env from secrets.template.env for the
  Lightwell Autonomous Remediation project. Use when setting up the cluster,
  before running the agent runtime, when the user asks to configure secrets
  or credentials, or when run-agent.sh exits 2 on a missing variable.
---

# Secrets Setup

Bootstrap the credentials the agent runtime reads at launch.
**Never commit** `secrets/secrets.env` — `.gitignore` covers it with `*.env`.

**Template:** `secrets/secrets.template.env`
**Consumer:** `agent-runtime/run-agent.sh` (contract: `specs/platform/agent-runtime.spec.md`)

## When to use

| Trigger | Action |
|---|---|
| First local run or first cluster deploy | Copy template → fill required keys |
| `run-agent: <VAR> is not set` (exit 2) | Fill the missing key |
| User asks "configure secrets" / "credenciales" | Run this workflow |

## Workflow

```
Secrets setup:
- [ ] 1. Copy template to secrets.env (if missing)
- [ ] 2. Fill required keys
- [ ] 3. Validate (no values printed)
- [ ] 4. Confirm the file is untracked
```

### 1. Copy template

```bash
cp secrets/secrets.template.env secrets/secrets.env
chmod 600 secrets/secrets.env
```

### 2. Keys

Required — `run-agent.sh` exits 2 if any is unset or still `CHANGE_ME`:

| Variable | Purpose |
|---|---|
| `MAAS_BASE_URL` | MaaS gateway base URL, no trailing `/v1` |
| `MAAS_API_KEY` | MaaS API key, sent as `x-api-key` |
| `MAAS_MODEL` | Primary model alias from the MaaS catalog |

Required for repository delivery — without them the runtime finds no checkout
and exits 2 rather than running green against an empty directory:

| Variable | Purpose |
|---|---|
| `GITHUB_TOKEN` | Fine-grained PAT scoped to `APP_REPO`: Contents RW, Pull requests RW, Metadata R |
| `APP_REPO` | Application repository to remediate, as `owner/repo` |

Not consumed yet — Lightwell credentials, for the Phase 3 trigger. Kept empty in
the template so the placeholder check below stays meaningful; nothing fails
without them today, and nothing works once the trigger exists and they are missing:

| Variable | Purpose |
|---|---|
| `LW_USERNAME` | Lightwell account used to read the vulnerability alert |
| `LW_PASSWORD` | Password for that account |
| `LW_MAVEN_REPO_URL` | Lightwell remediated Maven repository, read by the application's `settings.xml` |

Optional — the runtime has a default for each:

| Variable | Default |
|---|---|
| `MAAS_SMALL_MODEL` | falls back to `MAAS_MODEL` |
| `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` | `lightwell-agent` identity |
| `MAX_TURNS` | 25 in the script, 40 in the template |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | 2048 — see `docs/agent-runtime.md`, Known limitations |

### 3. Validate (no secret values in output)

No placeholder left behind:

```bash
grep -c '^[A-Z_]*=CHANGE_ME$' secrets/secrets.env   # must print 0
```

The pinned model still exists in the catalog — a stale alias surfaces at
runtime as an unknown-model error that reads like a gateway failure:

```bash
set -a; source secrets/secrets.env; set +a
curl -s -H "Authorization: Bearer $MAAS_API_KEY" "$MAAS_BASE_URL/v1/models" \
  | grep -o "\"id\":\"$MAAS_MODEL\""                 # must print a match
```

The PAT reaches the repository with the scopes the agent needs:

```bash
GH_TOKEN="$GITHUB_TOKEN" gh repo view "$APP_REPO" --json viewerPermission
```

### 4. Pre-commit gate

```bash
git status --porcelain secrets/secrets.env           # must print nothing
```

Before any commit touching env files, run the `no-secrets` skill.

## In-cluster

The same variables are mounted as a Kubernetes Secret rather than a file —
`run-agent.sh` skips `secrets.env` when it is absent and reads the environment.
Keys and names are identical, so a local run and a pipeline run resolve the
same configuration. Provisioning that Secret is a Phase 0.5 task; see
`docs/ROADMAP.md` and the `cluster-bootstrap` skill.

## Expected result

- `secrets/secrets.env` exists locally, mode 600, no `CHANGE_ME` left
- `git status` does not show it
- `agent-runtime/run-agent.sh --task "..."` gets past configuration checks

## Troubleshooting

| Symptom | Fix |
|---|---|
| `run-agent: MAAS_BASE_URL is not set` | Key missing or still `CHANGE_ME` in `secrets/secrets.env` |
| `no GITHUB_TOKEN configured` | PAT missing — repository delivery is disabled |
| `no git checkout in .workspace/repo` | `APP_REPO` unset, or `--no-clone` with an empty workspace |
| Unknown-model error at runtime | `MAAS_MODEL` no longer in the catalog — re-run the step 3 check |

## Related skills

- Scan before commit: `no-secrets`
- Deploy platform: `cluster-bootstrap`
