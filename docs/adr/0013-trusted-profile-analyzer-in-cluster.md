# ADR-0013: Install Trusted Profile Analyzer in the Pipeline's Cluster

## Status

Proposed

## Date

2026-11-26

## Layer

Platform

## Context

The `sbom` task validates the regenerated inventory against Red Hat Trusted
Profile Analyzer (TPA). In Milestone 1 that instance ran on a separate RHDP
cluster ([workarounds](../workarounds.md)): it already had the Lightwell
integration and the Lightwell OSV records, which an empty instance does not.
The cost was a cluster that expires, no TPA for a replicator, public egress to
another cluster, and a baseline that cannot be onboarded twice on a shared
instance (TPA deduplicates identical inventories).

The new instance has to be installed by the bootstrap, signed in against an
identity provider, and loaded with the Lightwell records. The reference for
that configuration is the Red Hat Services demo
[rmarting/rhtpa-openshift-demo](https://github.com/rmarting/rhtpa-openshift-demo)
(operator `rhtpa-operator`, channel `stable-v3`, CR `TrustedProfileAnalyzer`,
PostgreSQL, S3 storage, Keycloak realm `trustify`, HTTP importers with Pulp
discovery against `packages.redhat.com/lightwell/osv/...`).

## Options

### A. Keep the instance on another cluster

Nothing to build. Keeps every cost listed above, and a replicator cannot
validate. Rejected: it was always labelled a workaround.

### B. Install TPA in the bootstrap, against the Keycloak that already runs on the cluster

One Application (`platform-tpa`) and one chart. Costs a dependency: a Keycloak
to import the realm into.

### C. Install TPA with its own Keycloak

Self-contained, one more operator (RHBK), database and about 3 GiB of memory.
Kept as the fallback if the cluster has no usable Keycloak.

## Decision

Option B. `platform.tpa` (wave 3) installs the `rhtpa-operator` Subscription,
PostgreSQL, the document storage, the `trustify` realm in the cluster's
Keycloak and the `TrustedProfileAnalyzer` instance, from
`deploy/gitops/deployments/platform/tpa/`.

- **Lightwell integration** is the HTTP importers of the instance, enabled for
  the Java and Python remediated repositories, reading basic-auth credentials
  from the Secret `rhtpa-rhlw-creds` (keys `RH_LW_USERNAME`, `RH_LW_PASSWORD`),
  built from the `LW_*` values. Every other importer stays off.
- **Credentials** are created by `make secrets` ([ADR-0007](0007-in-cluster-credential-delivery.md)),
  generated once and never rotated by a re-run: database, the `cli` client
  secret (in the TPA and Keycloak namespaces) and the console password. None is
  in git, in a values file or in an Application spec. The reference deployment's
  lab credentials are not used.
- **The pipeline does not change.** `lightwell-tpa` is filled by `make secrets`
  with the instance's route, the realm's token endpoint and the `cli` client.
  With `TPA_URL` set in `secrets.env` the same Secret points at an external
  instance, as before.
- **Storage** is an `ObjectBucketClaim` on NooBaa; `storage.type: filesystem`
  covers a cluster without ODF.

## Consequences

### Positive

- No second cluster, a replicator gets TPA, no egress to another cluster.
- Each deployment has its own instance, so the baseline of a fresh template
  copy is found under its own name.

### Negative

- About 1.2 CPU and 5 GiB more requests, plus a database volume and a bucket.
- Depends on a Keycloak and on ODF that the bootstrap does not install.
- TPA 3.1.1 rejects the `Red Hat Lightwell:Maven` ecosystem (TC-7303, fixed in
  3.1.2) and refuses file credentials unless `credentialPaths` is set
  (TC-7588, applied in the chart). Both are recorded in
  [workarounds](../workarounds.md) until validated on the cluster.

### Neutral

- Replaces the Milestone 1 entry "TPA runs on a separate cluster".

## Validation

Pending on a real cluster: `make validate` (operator CSV, CR, deployments,
token from the `cli` client, API call, importer log) and a real run whose pull
request shows the vulnerability affected in the baseline and gone on the
branch. Update this section and set the status to Accepted when done.

## References

- [rmarting/rhtpa-openshift-demo](https://github.com/rmarting/rhtpa-openshift-demo)
- [ROADMAP — Install TPA in the pipeline's cluster](../ROADMAP.md)
- [ADR-0006](0006-cluster-bootstrap-topology.md), [ADR-0007](0007-in-cluster-credential-delivery.md)
