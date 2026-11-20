---
name: provision-app-repo
description: >-
  Create a private application repository from the template for a new
  deployment and mint a GitHub token scoped to that repository only, then
  update secrets/secrets.env and the lightwell-github Secret. Use for every
  new cluster or deployment, when GITHUB_TOKEN expired (401, "Authentication
  failed" in analyze), when run-agent cannot clone APP_REPO, or when the user
  says provision-app-repo, "repo por despliegue", "token de GitHub".
---

# Provision the application repository

One private copy of the template per deployment, and a token that reaches that
copy and nothing else. Never run the agent against the template or against a
repository that still has an earlier run's `remediate/*` branch: a full clone
would hand the next run the answer ([replicate.md](../../../docs/replicate.md) step 1).

- Script: [`scripts/provision-app-repo.sh`](../../../scripts/provision-app-repo.sh)
- Contract: [`specs/platform/app-repo-provisioning.spec.md`](../../../specs/platform/app-repo-provisioning.spec.md)
- Decision: [ADR-0012](../../../docs/adr/0012-per-deployment-app-repo-and-github-app-token.md)

GitHub cannot create fine-grained PATs through an API, so the token comes from a
**GitHub App** created once. After that, everything below needs no one.

## 1. Once: create the GitHub App (manual, ~2 minutes)

In the `lightwell-remediation` organization: Settings → Developer settings →
GitHub Apps → New GitHub App.

| Field | Value |
|---|---|
| Webhook | Inactive |
| Repository permissions | Contents: Read and write, Pull requests: Read and write, Metadata: Read |
| Where can it be installed | Only on this account |

Then generate a private key, move it out of any repository and lock it down:

```bash
mkdir -p ~/.config/lightwell/github-app
mv ~/Downloads/<app>.*.private-key.pem ~/.config/lightwell/github-app/key.pem
chmod 600 ~/.config/lightwell/github-app/key.pem
```

Install the App on the organization with **All repositories**. Do not pick
*Only select repositories*: the script would have to add each new repository to
the installation, and GitHub answers 403 to that call from a `gh` login even for
an organization owner (validated 2026-11-18). The token it mints is still
restricted to one repository. The installation id is the last number of the
installation URL. Then:

```bash
cp secrets/github-app.template.env secrets/github-app.env
chmod 600 secrets/github-app.env
$EDITOR secrets/github-app.env      # GH_APP_ID, GH_APP_INSTALLATION_ID, GH_APP_PRIVATE_KEY_FILE
```

## 2. Per deployment

```bash
# cluster already logged in (the Secret is updated too)
scripts/provision-app-repo.sh <cluster-guid>
```

Creates `lightwell-remediation/lw-apache-cxf-demo-<guid>` (private) from
`lw-apache-cxf-demo-template`, mints the token, writes `APP_REPO` and
`GITHUB_TOKEN` to `secrets/secrets.env`, updates `lightwell-github`, and checks
that the token can push to the copy, cannot write to the template, and that no
`remediate/*` branch exists. Path B: `--template document-intake-service`.

## 3. The token lasts one hour

Installation tokens expire after 1 hour. Before a run that starts later than
that, or on `Authentication failed`:

```bash
scripts/provision-app-repo.sh --refresh
```

`scripts/run-remediation.sh` does this for you before it starts a run.

A run against another application (`run-remediation.sh --repo <owner/repo>`)
gets a token minted for that repository alone, into its own Secret
`lightwell-github-<owner>-<repo>`; secrets.env is not touched. By hand:

```bash
scripts/provision-app-repo.sh --repo <owner/repo> --secret lightwell-github-<owner>-<repo>
```

The App must be installed on that repository.

## 4. Tear down

```bash
scripts/provision-app-repo.sh <cluster-guid> --teardown --yes
```

Needs the `delete_repo` scope on the `gh` login:
`gh auth refresh -h github.com -s delete_repo`.

## Rules

- Never print, paste or commit the token or the `.pem` (`no-secrets` skill before any commit).
- A repository that is not private is refused.
- After every run: never merge the agent's pull request, close it and delete its `remediate/*` branch, or tear the repo down.

## Related skills

`secrets-setup`, `cluster-bootstrap`, `no-secrets`
