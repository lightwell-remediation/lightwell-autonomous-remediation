# Workarounds

Active workarounds applied in this project. Each entry documents a known issue and its temporary fix.

## Trusted Profile Analyzer runs on a separate cluster

- **Date**: 2026-10-23
- **Affected version**: Red Hat Trusted Profile Analyzer 3.1 (Trustify 3.1.0), Milestone 1
- **Bug/Issue**: no upstream issue — a project scoping decision. Tracked in
  [ROADMAP — Phase 3](ROADMAP.md#phase-3-inventory-validation-tpa)
- **Expected resolution**: Milestone 2 (RH One 2027) — TPA on the pipeline's
  own cluster

### Problem

The pipeline's cluster has the `rh-tpa` operator (3.1.1) installed and no
instance. Standing one up is not just an operand: to say that
the Lightwell rebuild fixes the CVE, TPA needs the Lightwell integration and the
Lightwell OSV records loaded. A TPA on another RHDP cluster (Roman's) already
has both, plus the demo application's 1.0.0 and 1.0.1 inventories.

### Workaround

The `sbom` task's `validate` step talks to that instance over its public
route. Nothing in the pipeline knows it is remote: the URL, the Keycloak
token endpoint and an OIDC client (client-credentials grant) live in the
optional `lightwell-tpa` Secret, filled from `secrets/secrets.env` by
`scripts/push-secrets.sh tpa`. The application's baseline inventory is
registered once with `scripts/tpa-onboard.sh`.

What this costs:

- **The RHDP cluster expires.** The Act 4 recording has to happen while it
  exists.
- **A replicator has no TPA.** The Secret is optional: without it the step
  records that there was nothing to validate against and the pull request
  carries no TPA section. Everything else runs unchanged.
- **Egress** from `lightwell-agents` to a public route on another cluster.

### How to verify the fix

When TPA runs on the pipeline's cluster with the Lightwell OSV records
loaded: point the four `TPA_*` values in `secrets/secrets.env` at it, run
`scripts/push-secrets.sh tpa` and `scripts/tpa-onboard.sh`, and do a real run.
The pull request's *Inventory validated in Trusted Profile Analyzer* section
should show the vulnerability affected in the baseline and gone on the branch.
Then delete this entry. No code changes — the instance is configuration.
