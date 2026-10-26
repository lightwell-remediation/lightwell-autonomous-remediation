---
name: openshift-mcp
description: >-
  Interact with OpenShift and Kubernetes clusters via the user-kubernetes MCP
  server instead of shell oc/kubectl. Use when the user mentions OpenShift,
  OCP, RHOAI, cluster, namespace, project, pods, deployments, routes, operators,
  Helm releases, cluster debugging, or any task requiring live cluster state.
---

# OpenShift MCP

Use the **user-kubernetes** MCP server for all cluster operations. It speaks the Kubernetes/OpenShift API and is preferred over running `oc` or `kubectl` in the shell.

## When to use

| User intent | Use MCP |
|---|---|
| Check pod/deployment status | `pods_list`, `pods_get`, `resources_list` |
| Read logs or debug failures | `pods_log`, `events_list`, `pods_exec` |
| Inspect OpenShift projects | `projects_list` |
| Manage Helm releases | `helm_list`, `helm_install`, `helm_uninstall` |
| Apply YAML manifests | `resources_create_or_update` |
| Scale workloads | `resources_scale` |
| Check node health | `nodes_top`, `nodes_stats_summary`, `nodes_log` |
| Switch or verify cluster | `configuration_contexts_list`, `configuration_view` |

**Do not** fall back to `oc`/`kubectl` unless the MCP server is unavailable or the operation is not supported by any MCP tool.

## Invocation workflow

1. **Discover schema** — call `GetMcpTools` with `{"server": "user-kubernetes"}` or `{"server": "user-kubernetes", "toolName": "<name>"}` before the first use of each tool.
2. **Authenticate if needed** — if the server status is `needsAuth` or calls fail with auth errors, call `mcp_auth` on `user-kubernetes`, then retry.
3. **Verify context** — call `configuration_contexts_list` to see available clusters; pass `context` explicitly when the user names a specific cluster.
4. **Execute** — call `CallMcpTool` with `server: "user-kubernetes"`, the tool name, and arguments matching the schema.
5. **Report results** — summarize findings clearly; include namespace, resource name, and status.

## Standard debugging flow

```
1. configuration_contexts_list          → confirm target cluster
2. projects_list / namespaces_list      → find namespace/project
3. pods_list_in_namespace               → check pod phases
4. events_list (namespace filter)       → find warnings/errors
5. pods_log                             → read container logs
6. resources_get                        → inspect Deployment/Route/Subscription
```

For CrashLoopBackOff: list pods first, then get logs with `previous: true` if the container restarted.

## Safety rules

- **Read before write** — always inspect current state with `resources_get` or `pods_get` before modifying.
- **Confirm destructive ops** — ask the user before `resources_delete`, `pods_delete`, `helm_uninstall`, or scaling to zero.
- **Namespace scope** — always pass `namespace` explicitly; never assume the default namespace.
- **No secrets in output** — redact tokens, passwords, and kubeconfig credentials when reporting to the user.

## OpenShift-specific notes

- **Projects = namespaces** — use `projects_list` for OpenShift projects; `namespaces_list` works too.
- **Routes** — use `resources_list/get` with `apiVersion: route.openshift.io/v1`, `kind: Route`.
- **Operators** — Subscriptions and CSVs use `operators.coreos.com/v1alpha1`. See [reference.md](reference.md).
- **RHOAI** — common namespaces: `redhat-ods-operator`, `redhat-ods-applications`, `opendatahub`. See [reference.md](reference.md) for CRDs.

## Helm via MCP

```json
{
  "server": "user-kubernetes",
  "toolName": "helm_install",
  "arguments": {
    "chart": "oci://registry/chart",
    "name": "release-name",
    "namespace": "target-ns",
    "values": {}
  }
}
```

List releases with `helm_list`; uninstall with `helm_uninstall` (confirm with user first).

## Apply manifests via MCP

Read the local YAML file, then pass its content as the `resource` string to `resources_create_or_update`. For multiple resources, apply one at a time (split on `---`).

## Fallback to shell

Only use `oc`/`kubectl` when:
- MCP server status is `error` or `needsAuth` and auth fails
- The operation requires a subcommand not exposed by MCP (e.g., `oc debug`, port-forward)

When falling back, mention why MCP was not used.

## Additional resources

- OpenShift/RHOAI resource cheat sheet: [reference.md](reference.md)
