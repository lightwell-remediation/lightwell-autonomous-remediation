{{/*
Environment for any step that runs the agent runtime.

The Secrets' keys are already named after the variables the runtime reads, so
envFrom carries them without a mapping. The Lightwell one is optional on
purpose: the replay scenarios start no session and need no credentials, and a
missing optional Secret leaves the variables unset rather than failing to
schedule the pod.
*/}}
{{- define "remediation.agentEnv" -}}
envFrom:
  - secretRef:
      name: {{ .Values.secrets.maas }}
  - secretRef:
      name: {{ .Values.secrets.github }}
  - secretRef:
      name: {{ .Values.secrets.lightwell }}
      optional: true
env:
  - name: WORKSPACE
    value: $(workspaces.source.path)
  # The image prepares /home/claude-agent/.m2 group-writable for an arbitrary
  # UID, and the cache workspace is mounted there (see the workspace
  # declaration). Under the restricted-v2 SCC the UID has no passwd entry, so
  # HOME has to be stated or Maven writes its repository somewhere else and
  # the cache is never hit.
  - name: HOME
    value: /home/claude-agent
  - name: MAX_TURNS
    value: {{ .Values.agent.maxTurns | quote }}
{{- end -}}

{{/*
The dependency cache, as a plain volume rather than a Tekton workspace.

Not a stylistic choice. With the affinity assistant in `coschedule: workspaces`
mode — this cluster's setting and the Tekton default — a TaskRun may bind only
one PVC-backed *workspace*, and these tasks need the run's workspace as well
as the cache. Tekton's documented fix is `coschedule: pipelineruns`, but that
is a cluster-wide setting owned by the operator and shared with every other
pipeline here, so it is not ours to change for one chart's convenience.

The restriction exists because an RWO claim can only attach to one node. This
claim is RWX, so there is no node affinity to preserve and nothing the
assistant would have protected.

What it costs: the cache is bound by claim name rather than per run, so a run
against a scratch cache sets the parameter instead of rebinding a workspace.
*/}}
{{- define "remediation.cacheVolume" -}}
- name: maven-cache
  persistentVolumeClaim:
    claimName: $(params.cache-claim)
{{- end -}}

{{- define "remediation.cacheMount" -}}
volumeMounts:
  - name: maven-cache
    mountPath: /home/claude-agent/.m2
{{- end -}}

{{- define "remediation.cacheParam" -}}
- name: cache-claim
  type: string
  description: >-
    The dependency cache claim. Outlives every run; see Two Lifetimes, Two
    Volumes in the orchestration spec.
  default: {{ .Values.cache.claimName | quote }}
{{- end -}}

{{- define "remediation.agentResources" -}}
computeResources:
{{ toYaml .Values.resources.agent | indent 2 }}
{{- end -}}

{{- define "remediation.cliResources" -}}
computeResources:
{{ toYaml .Values.resources.cli | indent 2 }}
{{- end -}}

{{/*
Shared shell prologue for every phase step.

`state_of` reads the terminal state out of a phase document. It is the single
place that knows the field name, and it is deliberately tolerant: a missing or
malformed document yields an empty string, which the caller turns into a
terminal state of "none" rather than into a crash that hides what happened.
*/}}
{{- define "remediation.prologue" -}}
set -uo pipefail

OUT="$(workspaces.source.path)/out"
mkdir -p "$OUT"

state_of() {
  node -e '
    try {
      const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      process.stdout.write(String(d.terminal_state || ""));
    } catch { process.stdout.write(""); }
  ' "$1" 2>/dev/null
}

# when expressions compare the result verbatim, so a trailing newline here
# would make every comparison fail.
emit() { printf '%s' "${1:-none}"; }
{{- end -}}
