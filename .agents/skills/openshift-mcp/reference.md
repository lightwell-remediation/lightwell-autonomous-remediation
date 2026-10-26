# OpenShift MCP — Resource Reference

MCP server: `user-kubernetes`

## Tool catalog

### Configuration

| Tool | Purpose |
|---|---|
| `configuration_contexts_list` | List kubeconfig contexts (clusters) |
| `configuration_view` | View current kubeconfig (use `minified: true` by default) |

### Discovery

| Tool | Purpose |
|---|---|
| `projects_list` | List OpenShift projects |
| `namespaces_list` | List all namespaces |
| `events_list` | Cluster events (warnings, errors) |

### Pods

| Tool | Purpose |
|---|---|
| `pods_list` | All pods (all namespaces) |
| `pods_list_in_namespace` | Pods in one namespace |
| `pods_get` | Pod details |
| `pods_log` | Container logs (`tail`, `previous`, `container`) |
| `pods_exec` | Run command in pod (`command` as string array) |
| `pods_run` | Ephemeral debug pod |
| `pods_delete` | Delete pod |
| `pods_top` | CPU/memory usage |

### Generic resources

| Tool | Purpose |
|---|---|
| `resources_list` | List by apiVersion + kind |
| `resources_get` | Get one resource |
| `resources_create_or_update` | Apply YAML/JSON |
| `resources_delete` | Delete resource |
| `resources_scale` | Get/set replica count |

### Nodes

| Tool | Purpose |
|---|---|
| `nodes_top` | Node CPU/memory |
| `nodes_stats_summary` | Detailed kubelet stats |
| `nodes_log` | Kubelet/proxy logs |

### Helm

| Tool | Purpose |
|---|---|
| `helm_list` | List releases |
| `helm_install` | Install chart |
| `helm_uninstall` | Remove release |

All tools accept optional `context` to target a specific cluster.

---

## Common OpenShift resources

### Routes

```yaml
apiVersion: route.openshift.io/v1
kind: Route
```

```json
{
  "toolName": "resources_list",
  "arguments": {
    "apiVersion": "route.openshift.io/v1",
    "kind": "Route",
    "namespace": "my-project"
  }
}
```

### Deployments

```json
{
  "toolName": "resources_list",
  "arguments": {
    "apiVersion": "apps/v1",
    "kind": "Deployment",
    "namespace": "my-project",
    "labelSelector": "app=my-agent"
  }
}
```

### Services

```json
{
  "toolName": "resources_get",
  "arguments": {
    "apiVersion": "v1",
    "kind": "Service",
    "name": "my-service",
    "namespace": "my-project"
  }
}
```

### Ingress (if used instead of Routes)

```json
{
  "toolName": "resources_list",
  "arguments": {
    "apiVersion": "networking.k8s.io/v1",
    "kind": "Ingress",
    "namespace": "my-project"
  }
}
```

---

## Operator Lifecycle Manager (OLM)

| Resource | apiVersion | kind |
|---|---|---|
| Subscription | `operators.coreos.com/v1alpha1` | `Subscription` |
| ClusterServiceVersion | `operators.coreos.com/v1alpha1` | `ClusterServiceVersion` |
| OperatorGroup | `operators.coreos.com/v1` | `OperatorGroup` |
| InstallPlan | `operators.coreos.com/v1alpha1` | `InstallPlan` |

Example — list RHOAI operator CSVs:

```json
{
  "toolName": "resources_list",
  "arguments": {
    "apiVersion": "operators.coreos.com/v1alpha1",
    "kind": "ClusterServiceVersion",
    "namespace": "redhat-ods-operator",
    "labelSelector": "operators.coreos.com/cluster-monitoring=true"
  }
}
```

---

## RHOAI / Open Data Hub CRDs

| Resource | apiVersion | kind | Typical namespace |
|---|---|---|---|
| DSCInitialization | `dscinitialization.opendatahub.io/v1` | `DSCInitialization` | `redhat-ods-operator` |
| DataScienceCluster | `datasciencecluster.opendatahub.io/v1` | `DataScienceCluster` | `redhat-ods-operator` |
| DataSciencePipelineApplication | `datasciencepipelinesapplications.opendatahub.io/v1` | `DataSciencePipelinesApplication` | `redhat-ods-applications` |

Common RHOAI namespaces:

| Namespace | Contents |
|---|---|
| `openshift-operators` | Global operator subscriptions |
| `redhat-ods-operator` | RHOAI operator, DSC init |
| `redhat-ods-applications` | RHOAI components (Workbench, MLflow, etc.) |
| `opendatahub` | Legacy/alternate component namespace |

---

## Label and field selectors

**Label selector** (pods, deployments, resources_list):

```
app=my-agent,component=mlflow
app in (agent,worker)
```

**Field selector** (pods, events):

```
status.phase=Running
status.phase=Failed
involvedObject.name=my-pod-abc123
type=Warning
```

Note: `CrashLoopBackOff` is a container state, not a pod phase. List pods with `status.phase=Running` or no filter, then inspect individually.

---

## Example workflows

### Check if RHOAI is healthy

1. `projects_list` or `namespaces_list` — confirm `redhat-ods-applications` exists
2. `pods_list_in_namespace` with `namespace: redhat-ods-applications`
3. `events_list` with `namespace: redhat-ods-applications`, `fieldSelector: type=Warning`
4. `resources_get` DSCInitialization in `redhat-ods-operator`

### Debug a failing agent pod

1. `pods_list_in_namespace` with label selector
2. `pods_get` for the failing pod
3. `pods_log` with `tail: 200`
4. If restarted: `pods_log` with `previous: true`
5. `events_list` filtered to pod name

### Deploy from repo manifest

1. Read local YAML from `deploy/`
2. `resources_create_or_update` with full manifest string
3. `resources_get` to verify status
4. For Routes: `resources_list` apiVersion `route.openshift.io/v1`
