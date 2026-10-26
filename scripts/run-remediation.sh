#!/usr/bin/env bash
# run-remediation.sh — start a real remediation run in the cluster.
#
# The counterpart to test-pipeline.sh: same Pipeline, real sessions. This one
# spends money and opens a pull request.
#
# The vulnerability record is mounted as a ConfigMap rather than fetched, so
# the run does not depend on Lightwell being reachable from the cluster and
# the same record can be replayed later. `--osv` also takes a URL, which the
# runtime fetches with the Lightwell credentials; this script does not, on
# purpose.
#
# Usage:
#   run-remediation.sh <osv-file> [--branch <name>] [--model <id>] [--no-follow]
#
# --branch picks which branch of the application to remediate, and so which
# branch the pull request is opened against. The demo fixture, where the
# vulnerable code is actually reachable, lives on a branch of its own.
#
# Example:
#   run-remediation.sh .fixtures/osv/CVE-2026-68079.json --branch feat/reachable-cve
#
# Exit status:
#   0  remediated, verified and delivered (or nothing needed doing)
#   1  the run did not complete
#   2  configuration error

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly NAMESPACE="${NAMESPACE:-lightwell-agents}"
readonly CACHE_CLAIM="${CACHE_CLAIM:-lightwell-maven-cache}"
readonly SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-lightwell-agent}"
readonly CLAIM_ACCOUNT="${CLAIM_ACCOUNT:-lightwell-run-claim}"
readonly STATUS_DIR="$SCRIPT_DIR/../.agent-status"

die() { printf 'run-remediation: %s\n' "$*" >&2; exit 2; }
log() { printf 'run-remediation: %s\n' "$*" >&2; }

OSV=""
MODEL=""
BRANCH="${APP_BRANCH:-}"
FOLLOW=1
while [ $# -gt 0 ]; do
  case "$1" in
    --model)     MODEL="${2:?--model needs a value}"; shift 2 ;;
    --branch)    BRANCH="${2:?--branch needs a value}"; shift 2 ;;
    --no-follow) FOLLOW=0; shift ;;
    -h|--help)   sed -n '2,23p' "$0"; exit 0 ;;
    -*)          die "unknown argument: $1" ;;
    *)           OSV="$1"; shift ;;
  esac
done

[ -n "$OSV" ] || die "a vulnerability record is required"
[ -r "$OSV" ] || die "vulnerability record not readable: $OSV"
command -v oc >/dev/null || die "oc is not installed"
oc whoami >/dev/null 2>&1 || die "not logged in to a cluster"

# The application comes from the Secret the agent already reads, so there is
# one place it is configured and the label cannot drift from the param.
application="$(oc get secret lightwell-github -n "$NAMESPACE" \
  -o go-template='{{index .data "APP_REPO" | base64decode}}' 2>/dev/null)"
[ -n "$application" ] || die "APP_REPO is not set in the lightwell-github Secret"

for required in lightwell-maas lightwell-github; do
  oc get secret "$required" -n "$NAMESPACE" >/dev/null 2>&1 \
    || die "missing Secret $required — run scripts/push-secrets.sh"
done
# Only an application that builds against the Lightwell repository needs it,
# and without it that build fails in a way that reads like a bad patch.
oc get secret lightwell-lightwell -n "$NAMESPACE" >/dev/null 2>&1 \
  || echo "run-remediation: no lightwell-lightwell Secret — fine for an application on Maven Central only" >&2

record="$(basename "$OSV")"
# A label value cannot contain '/' or uppercase, and the claim lists on it.
label="$(printf '%s' "$application" | tr 'A-Z/' 'a-z-' | cut -c1-63)"
cm="osv-$(printf '%s' "${record%.json}" | tr 'A-Z_.' 'a-z--' | cut -c1-55)"

oc delete configmap "$cm" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
oc create configmap "$cm" -n "$NAMESPACE" --from-file="$OSV" >/dev/null \
  || die "could not create the record ConfigMap"

mkdir -p "$STATUS_DIR"

run="$(oc create -n "$NAMESPACE" -o name -f - <<YAML | cut -d/ -f2
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: remediate-
  labels:
    app.kubernetes.io/part-of: lightwell-remediation
    lightwell.dev/application: $label
  annotations:
    tekton.dev/auto-cleanup-pvc: "true"
    lightwell.dev/record: $record
spec:
  pipelineRef:
    name: remediate
  taskRunTemplate:
    serviceAccountName: $SERVICE_ACCOUNT
  taskRunSpecs:
    - pipelineTaskName: claim-application
      serviceAccountName: $CLAIM_ACCOUNT
  timeouts:
    pipeline: 1h30m0s
  params:
    - name: application
      value: $label
    - name: osv
      value: /osv/$record
    - name: app-branch
      value: "$BRANCH"
    - name: model
      value: "$MODEL"
    - name: replay
      value: "false"
    - name: cache-claim
      value: $CACHE_CLAIM
  workspaces:
    - name: source
      volumeClaimTemplate:
        spec:
          accessModes: [ReadWriteOnce]
          resources:
            requests:
              storage: 5Gi
    - name: osv
      configMap:
        name: $cm
YAML
)"
[ -n "$run" ] || die "could not create the PipelineRun"

log "started $run"
log "  application $application"
log "  record      $record"
log "  branch      ${BRANCH:-the repository default}"
log "  model       ${MODEL:-from the MaaS Secret}"

[ "$FOLLOW" -eq 1 ] || { printf '%s\n' "$run"; exit 0; }

# A full sequence is seven to eleven minutes, and the first run against a
# cold cache adds more than fifteen. Polling rather than tailing: the logs
# are worth reading afterwards, not streamed.
waited=0
while [ "$waited" -lt 5400 ]; do
  [ -n "$(oc get pipelinerun "$run" -n "$NAMESPACE" \
    -o jsonpath='{.status.completionTime}' 2>/dev/null)" ] && break
  sleep 15
  waited=$(( waited + 15 ))
done

oc get pipelinerun "$run" -n "$NAMESPACE" -o json >"$STATUS_DIR/$run.json" 2>/dev/null

reason="$(oc get pipelinerun "$run" -n "$NAMESPACE" \
  -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null)"
message="$(oc get pipelinerun "$run" -n "$NAMESPACE" \
  -o jsonpath='{.status.conditions[0].message}' 2>/dev/null)"

printf '\n' >&2
oc get taskruns -n "$NAMESPACE" -l "tekton.dev/pipelineRun=$run" \
  -o custom-columns='TASK:.metadata.labels.tekton\.dev/pipelineTask,STATUS:.status.conditions[0].reason' >&2 2>/dev/null
printf '\n%s: %s\n' "$reason" "$message" >&2
printf 'logs:  oc logs -n %s -l tekton.dev/pipelineRun=%s --all-containers\n' "$NAMESPACE" "$run" >&2

[ "$reason" = "Succeeded" ] || [ "$reason" = "Completed" ]
