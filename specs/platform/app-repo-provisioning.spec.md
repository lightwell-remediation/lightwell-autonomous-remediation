# Application Repository Provisioning Specification

## Purpose

Defines how a deployment gets the repository the agent remediates and the
credential that reaches it. The agent clones the application, pushes a branch
and opens a pull request, so what it clones and what its token can touch are
part of the safety of every run.

[`cluster-bootstrap.spec.md`](cluster-bootstrap.spec.md) delivers the
credential to the cluster; [`agent-runtime.spec.md`](agent-runtime.spec.md)
defines how the runtime uses it. This spec defines where both come from.

## Requirements

### Requirement: One Private Repository Per Deployment

Each deployment SHALL remediate its own repository, created from the template.
The repository SHALL be private, and provisioning SHALL refuse a repository that
is not.

The template itself SHALL NOT be the target of a run.

#### Scenario: New Deployment

- GIVEN a deployment name and the template
- WHEN provisioning runs
- THEN a private repository named after the template and the deployment exists
- AND `APP_REPO` in `secrets/secrets.env` names it

#### Scenario: Re-run

- GIVEN the repository for that deployment already exists
- WHEN provisioning runs again
- THEN the repository is reused, not recreated

### Requirement: Token Scoped To One Repository

The credential SHALL be a token that can write to the deployment's repository
and to no other repository, with no more permissions than the agent needs
(contents, pull requests: write; metadata: read).

#### Scenario: Scope Check

- GIVEN a token minted for a deployment's repository
- WHEN provisioning verifies it
- THEN the token can push to that repository
- AND the token cannot write to the template

### Requirement: No Answer Left Behind

A repository SHALL NOT carry `remediate/*` branches from an earlier run into the
next one, because a full clone would give the run the answer.

#### Scenario: Leftover Branch

- GIVEN a repository with a `remediate/*` branch
- WHEN provisioning verifies it
- THEN verification fails and names the problem

### Requirement: Short-lived Token, Renewable Without A Person

The token SHALL expire within one hour. A run SHALL be able to renew it with no
manual step, and starting a remediation SHALL renew it when the App is
configured.

#### Scenario: Expired Token

- GIVEN a token minted more than one hour ago
- WHEN a remediation is started
- THEN a new token is minted for the same repository and the cluster Secret is updated first

### Requirement: Credentials Stay Out Of Sight

Provisioning SHALL NOT print the token or the App private key, SHALL NOT place
them on a command line, and SHALL write the token only to the gitignored
`secrets/secrets.env` and the cluster Secret. The App private key SHALL live
outside the repository with mode 600.

#### Scenario: Loose Key

- GIVEN a private key file readable by others
- WHEN provisioning runs
- THEN it stops before calling GitHub

### Requirement: Teardown Is Explicit

Deleting a deployment's repository SHALL require an explicit confirmation and
SHALL refuse the template.

## Related

- [ADR-0012](../../docs/adr/0012-per-deployment-app-repo-and-github-app-token.md)
- [ADR-0003](../../docs/adr/0003-agent-runtime-packaging-and-credentials.md), [ADR-0007](../../docs/adr/0007-in-cluster-credential-delivery.md)
