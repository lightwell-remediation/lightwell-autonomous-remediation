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

- **Date**: 2026-11-27 (applied in the `tpa` chart, verified on a cluster)
- **Affected version**: Red Hat Trusted Profile Analyzer 3.1.1 and 3.1.2
- **Bug/Issue**: [TC-7588](https://redhat.atlassian.net/browse/TC-7588)
- **Expected resolution**: not announced

### Problem

The importer logs `file credential source is disabled; set
IMPORTER_CREDENTIAL_PATHS to allow one or more paths` and never reads the
Lightwell repositories.

### Workaround

Set `IMPORTER_CREDENTIAL_PATHS` on the `importer` Deployment to the directory
the `rhtpa-rhlw-creds` Secret is mounted at. The operator's chart has no value
for it: `modules.importer.credentialPaths` and `extraEnv` are accepted by the CR
and ignored (checked on 3.1.2), so a PostSync Job
(`templates/importer-credential-paths.yaml`) runs `oc set env` once the
operator has created the Deployment. Found in
[rmarting/rhtpa-openshift-demo](https://github.com/rmarting/rhtpa-openshift-demo#unable-to-authenticate-to-lightwell-network-repositories).

### How to verify the fix

Remove the Job and check that the importer logs no `file credential source is
disabled` error. Then delete this entry.

## TPA 3.1.1 rejects the Lightwell Maven ecosystem

- **Date**: 2026-11-27 (workaround applied and run on a cluster)
- **Affected version**: Red Hat Trusted Profile Analyzer 3.1.1 and **3.1.2**
  (`stable-v3` resolves to 3.1.2; the importer still logs the error there)
- **Bug/Issue**: [TC-7303](https://redhat.atlassian.net/browse/TC-7303)
- **Expected resolution**: the issue says 3.1.2, which did not fix it. Unknown.

### Problem

The importer rejects every record whose ecosystem is `Red Hat Lightwell:Maven`
(`unknown variant ... expected Ecosystem`), so the Java remediation records
never reach the instance.

### Workaround

Load the records through the API with the ecosystem rewritten from
`Red Hat Lightwell:Maven` to `Maven`: `scripts/tpa-load-lightwell.sh`. TPA
accepts them that way (HTTP 201; 303 of 303 records loaded on 2026-11-27) and
matches on the purl, the affected range and the fixed version, which are
untouched. The cost is that a record no longer says it came from Lightwell.
Run it after `make secrets` and before the first run; rerun it to pick up new
records. The Roman's reference deployment
([rmarting/rhtpa-openshift-demo](https://github.com/rmarting/rhtpa-openshift-demo))
has no workaround, only the note that 3.1.2 would fix it, which it did not.

### How to verify the fix

The importer log shows no `Red Hat Lightwell:Maven` error. Then delete this
entry and `scripts/tpa-load-lightwell.sh`. Still to check: a CVE fixed by a
Lightwell rebuild shows as fixed in the pull request's TPA section.
