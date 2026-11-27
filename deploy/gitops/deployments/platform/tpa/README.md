# tpa

Red Hat Trusted Profile Analyzer next to the pipeline
([ADR-0013](../../../../../docs/adr/0013-trusted-profile-analyzer-in-cluster.md)).
Status: written, **not yet run on a cluster**.

## What it installs

| Wave | Resource | Notes |
|---|---|---|
| 0-2 | Namespace, OperatorGroup, `rhtpa-operator` Subscription | channel `stable-v3` |
| 3 | PostgreSQL StatefulSet, `ObjectBucketClaim` (or a PVC) | the operator does not deploy a database |
| 4 | `KeycloakRealmImport` `trustify` | lands in the **Keycloak's** namespace |
| 5 | `TrustedProfileAnalyzer` `rhtpa` | importers for the Lightwell Java and Python remediated repositories |

## Prerequisites

- A Keycloak (RHBK) custom resource on the cluster. Check
  `oc get keycloak -A` and set `platform.tpa.keycloak.{namespace,crName,host}`
  in `deploy/values/local.yaml`. Without one set `platform.tpa.enabled: false`.
- ODF with NooBaa for the bucket, or `platform.tpa.storage.type: filesystem`.
- `make secrets` before the Application syncs: it generates `rhtpa-db`,
  `oidc-cli`, `rhtpa-users`, builds `rhtpa-rhlw-creds` from `LW_USERNAME` and
  `LW_PASSWORD`, and fills `lightwell-tpa` for the pipeline. No credential is in
  this chart.

## Deploy and test

```bash
make -C deploy preflight          # Keycloak, NooBaa, existing rhtpa Subscription
make -C deploy secrets deploy
make -C deploy validate           # CSV, deployments, token, API call, importer log
scripts/tpa-onboard.sh            # baseline of the application, once
```

Iterate with `helm upgrade --install` on this chart before trusting ArgoCD.
`helm lint` needs `ci/lint-values.yaml`.

## Known issues

TC-7588 (credential paths, applied here) and TC-7303 (Lightwell Maven
ecosystem, TPA 3.1.1): see [workarounds](../../../../../docs/workarounds.md).
