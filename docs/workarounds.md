# Workarounds

Active workarounds applied in this project. Each entry documents a known issue and its temporary fix.

## Trusted Profile Analyzer runs on a separate cluster

- **Date**: 2026-10-23
- **Affected version**: Red Hat Trusted Profile Analyzer 3.1 (Trustify 3.1.0), Milestone 1
- **Bug/Issue**: no upstream issue — a project scoping decision. Tracked in
  [ROADMAP — Phase 3](ROADMAP.md#phase-3-inventory-validation-tpa)
- **Expected resolution**: Milestone 2 (RH One 2027) — TPA on the pipeline's
  own cluster
- **Status (2026-11-26)**: the in-cluster install is written
  ([ADR-0013](adr/0013-trusted-profile-analyzer-in-cluster.md),
  `deploy/gitops/deployments/platform/tpa/`, `platform.tpa`) and not yet
  validated on a cluster. Delete this entry when it is.

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
- **A fresh copy of a template cannot be onboarded on a shared instance.**
  TPA deduplicates an inventory it already holds: uploading the copy's
  `sbom.json`, identical to the original's, returns the existing SBOM with the
  original application's labels, and no baseline is ever found under the
  copy's name. Found replicating on 2026-10-27: `tpa-onboard.sh` reported
  success and the pull request said no baseline was registered. This is why
  TPA was taken out of the replication guide.
- **Onboard before the run.** The `sbom` task looks the baseline up while the
  run is in progress; registering it afterwards leaves that run without one.

### How to verify the fix

When TPA runs on the pipeline's cluster with the Lightwell OSV records
loaded: point the four `TPA_*` values in `secrets/secrets.env` at it, run
`scripts/push-secrets.sh tpa` and `scripts/tpa-onboard.sh`, and do a real run.
The pull request's *Inventory validated in Trusted Profile Analyzer* section
should show the vulnerability affected in the baseline and gone on the branch.
Then delete this entry. No code changes — the instance is configuration.

## TPA 3.1.1 refuses Lightwell credentials mounted from a Secret

- **Date**: 2026-11-26 (applied in the `tpa` chart, not yet run on a cluster)
- **Affected version**: Red Hat Trusted Profile Analyzer 3.1.1
- **Bug/Issue**: [TC-7588](https://redhat.atlassian.net/browse/TC-7588)
- **Expected resolution**: not announced

### Problem

The importer logs `file credential source is disabled; set
IMPORTER_CREDENTIAL_PATHS to allow one or more paths` and never reads the
Lightwell repositories.

### Workaround

The instance sets `modules.importer.credentialPaths` to the directory the
`rhtpa-rhlw-creds` Secret is mounted at. Found in
[rmarting/rhtpa-openshift-demo](https://github.com/rmarting/rhtpa-openshift-demo#unable-to-authenticate-to-lightwell-network-repositories).

### How to verify the fix

Remove `credentialPaths` from `templates/trustedprofileanalyzer.yaml` and check
that the importer logs no credential error. Then delete this entry.

## TPA 3.1.1 rejects the Lightwell Maven ecosystem

- **Date**: 2026-11-26 (to confirm on the cluster: depends on the version `stable-v3` resolves to)
- **Affected version**: Red Hat Trusted Profile Analyzer 3.1.1
- **Bug/Issue**: [TC-7303](https://redhat.atlassian.net/browse/TC-7303)
- **Expected resolution**: TPA 3.1.2

### Problem

The importer rejects every record whose ecosystem is `Red Hat Lightwell:Maven`
(`unknown variant ... expected Ecosystem`), so the Java remediation records
never reach the instance.

### Workaround

None applied in the chart. If `stable-v3` still resolves to 3.1.1, upload the
run's own OSV record to TPA through the API before the `sbom` step, or wait for
3.1.2. Decide on the cluster: check `oc get csv -n trusted-profile-analyzer`.

### How to verify the fix

`make validate` reports no Lightwell importer errors and a CVE fixed by a
Lightwell rebuild shows as fixed in the pull request's TPA section. Then delete
this entry.
