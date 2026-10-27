{{/*
Repo path of a deployment chart, honouring bootstrap.pathPrefix so this tree can
be moved (deploy/gitops here, automation/gitops in the workshop repo) without
touching every Application.
Usage: {{ include "bootstrap.path" (dict "ctx" . "chart" "platform/mlflow") }}
*/}}
{{- define "bootstrap.path" -}}
{{- $prefix := trimSuffix "/" .ctx.Values.bootstrap.pathPrefix -}}
{{- if $prefix -}}{{ $prefix }}/deployments/{{ .chart }}{{- else -}}deployments/{{ .chart }}{{- end -}}
{{- end -}}

{{/*
Internal registry pull spec for the agent runtime, at its version.
Usage: {{ include "bootstrap.imageRef" (dict "ctx" . "name" "lightwell-agent-runtime") }}
*/}}
{{- define "bootstrap.imageRef" -}}
{{- printf "image-registry.openshift-image-registry.svc:5000/%s/%s:%s" .ctx.Values.agents.namespace .name .ctx.Values.agents.runtimeImage.version -}}
{{- end -}}
