# ADR-0012: One Private Repository Per Deployment, Token From a GitHub App

## Status
Proposed

## Date
2026-11-18

## Layer
Platform

## Context

The agent clones the application, pushes a branch and opens a pull request. Until
now every deployment pointed `APP_REPO` at the same demo repository, with a
fine-grained PAT created by hand ([ADR-0003](./0003-agent-runtime-packaging-and-credentials.md),
[ADR-0007](./0007-in-cluster-credential-delivery.md)).

Two things went wrong with that:

- A shared repository accumulates `remediate/*` branches and pull requests, and a
  full clone hands the next run the answer ([ADR-0004](./0004-demo-repository-ground-truth-isolation.md)).
- The PAT expires or is revoked. On 2026-11-18 it returned 401 and the first
  real run on a fresh cluster failed in `analyze` on `git clone`.

GitHub offers no API to create fine-grained PATs, so a PAT can never be created
by a script.

## Options Considered

### Option A: GitHub App installation token
A GitHub App is created once. Per deployment, a script signs a JWT with the App
key and exchanges it for an installation token restricted to one repository
(`repository_ids`) and to the permissions the agent needs.

- Pros: fully scriptable; scoped to one repository; short-lived; not tied to a person.
- Cons: the token lasts one hour; the App private key is a long-lived secret;
  one manual step to create the App.

### Option B: the `gh` login token
- Pros: no setup.
- Cons: write access to every repository the user can reach; contradicts the
  repository-scoped credential of ADR-0003; tied to a person's login.

### Option C: fine-grained PAT, semi-manual
- Pros: no new infrastructure; the documented path today.
- Cons: a person in every deployment, which is what this decision removes.

## Decision

Option A. `scripts/provision-app-repo.sh` creates a private repository from the
template per deployment, adds it to the App installation, mints a token scoped
to it and writes `APP_REPO` and `GITHUB_TOKEN` to `secrets/secrets.env` and the
`lightwell-github` Secret. `scripts/run-remediation.sh` renews the token before
a run when the App is configured. The skill `provision-app-repo` is the entry
point; the behavior is in
[`specs/platform/app-repo-provisioning.spec.md`](../../specs/platform/app-repo-provisioning.spec.md).

The Secret keeps the same keys, so the runtime is unchanged.

## Consequences

- A run that outlives the token fails in the middle. The token is read when each
  phase starts, so a run longer than one hour is exposed; cold runs have taken 48
  minutes. Measure it, and if it bites, document a workaround
  (`docs/workarounds.md`) or renew inside the pipeline.
- The App is installed on all repositories of the organization, so its private key
  could mint a token for any of them. The key is the long-lived secret that
  replaces the PAT.
- The App private key replaces the PAT as the long-lived secret. It lives outside
  the repository with mode 600.
- Each deployment leaves a repository to tear down (`--teardown`).
- Milestone 2 should move token renewal into the cluster rather than the laptop.
- A run naming another application (`run-remediation.sh --repo`) gets a token
  minted for that repository into its own Secret, `lightwell-github-<app>`
  ([ADR-0011](./0011-target-repository-run-parameter.md)), rather than reusing
  the deployment's token.

## Validation

**2026-11-18**, RHDP cluster, OpenShift 4.22, path A:

- The copy is created private from the template, and the token is minted and
  written to `secrets/secrets.env` and the `lightwell-github` Secret
- The token reads its repository with contents and pull requests write, cannot
  see another private repository of the organization (404), and cannot write to
  the template
- A run started with the renewed token reached `delivered` and opened a pull
  request
- Adding a repository to a *selected repositories* installation returns 403 from
  a `gh` login, even for an organization owner. The App is therefore installed on
  **all repositories**; the per-run token is still restricted by `repository_ids`
- Not yet measured: a run that crosses the one-hour mark

## Related Decisions

- [ADR-0003](./0003-agent-runtime-packaging-and-credentials.md), [ADR-0004](./0004-demo-repository-ground-truth-isolation.md), [ADR-0007](./0007-in-cluster-credential-delivery.md), [ADR-0011](./0011-target-repository-run-parameter.md)

## References

- [Create an installation access token](https://docs.github.com/en/rest/apps/apps#create-an-installation-access-token-for-an-app)
- [Generating a JWT for a GitHub App](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-json-web-token-jwt-for-a-github-app)
- [Add a repository to an app installation](https://docs.github.com/en/rest/apps/installations#add-a-repository-to-an-app-installation)
