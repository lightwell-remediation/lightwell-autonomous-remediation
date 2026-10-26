# Developer Hub (scaffold)

Off by default. Milestone 2 Phase 7 decides if this lands, see
[ROADMAP](../../../../../docs/ROADMAP.md).

This chart installs the operator only. Turn it on with:

```yaml
platform:
  developerHub:
    enabled: true
```

## What is still missing

A `Backstage` CR, which needs three things this project has not decided yet:

| Open | Why it is not guessed here |
|---|---|
| Identity provider | The cluster already has a Keycloak in the `keycloak` namespace. Reusing it or running our own is a Phase 7 call |
| GitHub integration | Needs its own token and the catalog entries to expose |
| Catalog content | `catalog-info.yaml` for this repository does not exist yet |

## Capacity

Around 1.5 CPU and 5 GiB of requests, plus a 10 GiB PVC for the Postgres the
operator brings. Budget for it before enabling on a small cluster.
