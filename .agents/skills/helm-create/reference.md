# Helm Patterns for OpenShift

## Sync Options for CRD-dependent Resources

Resources that depend on CRDs must include:
```yaml
annotations:
  argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
```

## Resource Policy Keep

Resources that should survive `helm uninstall` (e.g., OpenShift Groups with manual user memberships):
```yaml
annotations:
  helm.sh/resource-policy: keep
```

## Conditional Resources

Gate optional resources:
```yaml
{{- if .Values.<feature>.enabled }}
apiVersion: v1
kind: ConfigMap
...
{{- end }}
```

## Global Values Pattern

```yaml
# values.yaml
global:
  name: my-app
  namespace: my-namespace
  clusterDomain: apps.example.com
```

Reference in templates: `{{ .Values.global.clusterDomain }}`

## ServiceAccount with SCC

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "<chart>.fullname" . }}
  namespace: {{ .Release.Namespace }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: {{ include "<chart>.fullname" . }}-scc
subjects:
  - kind: ServiceAccount
    name: {{ include "<chart>.fullname" . }}
    namespace: {{ .Release.Namespace }}
roleRef:
  kind: ClusterRole
  name: system:openshift:scc:anyuid
  apiGroup: rbac.authorization.k8s.io
```

## Route (preferred over Ingress on OCP)

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: {{ include "<chart>.fullname" . }}
  namespace: {{ .Release.Namespace }}
spec:
  host: {{ include "<chart>.fullname" . }}-{{ .Release.Namespace }}.{{ .Values.global.clusterDomain }}
  to:
    kind: Service
    name: {{ include "<chart>.fullname" . }}
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
```

## ArgoCD Application Template

```yaml
{{- if .Values.modules.<name>.enabled }}
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <name>
  namespace: openshift-gitops
  annotations:
    argocd.argoproj.io/sync-wave: "<wave>"
spec:
  project: default
  source:
    repoURL: {{ .Values.repoURL }}
    targetRevision: {{ .Values.targetRevision }}
    path: modules/<name>/charts/<chart>
  destination:
    server: https://kubernetes.default.svc
    namespace: <namespace>
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
      - SkipDryRunOnMissingResource=true
{{- end }}
```

## Sync Wave Ordering

- Wave 0: Operators (subscriptions, operator groups)
- Wave 1: Platform configuration (DSC, DSCI, Gateway, monitoring)
- Wave 2: Workloads (models, services, applications)

## Values.yaml Documentation Pattern

```yaml
# -- Number of replicas for the deployment
replicaCount: 1

# -- Container image repository
image:
  # -- Image registry and name
  repository: registry.redhat.io/rhoai/odh-modelmesh-runtime
  # -- Image tag (defaults to chart appVersion)
  tag: ""

# -- Enable TLS for the service
tls:
  enabled: true
  # -- TLS termination type: edge, passthrough, reencrypt
  termination: edge
```

## _helpers.tpl Essentials

```yaml
{{- define "<chart>.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "<chart>.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "<chart>.labels" -}}
helm.sh/chart: {{ include "<chart>.name" . }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "<chart>.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
```
