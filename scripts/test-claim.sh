#!/usr/bin/env bash
# test-claim.sh — one run per application, enforced across pods.
#
# `flock` does not cross pods, so the Pipeline's first task lists PipelineRuns
# labelled with the application and refuses where one is already running
# (orchestration-strategy.spec.md — One Run per Application).
#
# This starts two runs against the same application and requires the second
# to be refused. It is its own script rather than a scenario in
# test-pipeline.sh because it is about two runs, not about one run's sequence.
#
# Usage: test-claim.sh
#
# Exit status:
#   0  the second run was refused and the first was unaffected
#   1  it was not
#   2  configuration error

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$SCRIPT_DIR/.."
readonly NAMESPACE="${NAMESPACE:-lightwell-agents}"
readonly APPLICATION="claim-test"
readonly SCENARIO="$REPO_ROOT/agent-runtime/test/fixtures/scenarios/delivered"

die() { printf 'test-claim: %s\n' "$*" >&2; exit 2; }
log() { printf 'test-claim: %s\n' "$*" >&2; }

command -v oc >/dev/null || die "oc is not installed"
oc whoami >/dev/null 2>&1 || die "not logged in to a cluster"

oc delete configmap "$APPLICATION" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
oc create configmap "$APPLICATION" -n "$NAMESPACE" --from-file="$SCENARIO" >/dev/null \
  || die "could not create the fixtures ConfigMap"

start_run() {
  oc create -n "$NAMESPACE" -o name -f - <<YAML | cut -d/ -f2
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: claim-test-
  labels:
    app.kubernetes.io/part-of: lightwell-remediation
    lightwell.dev/application: $APPLICATION
  annotations:
    tekton.dev/auto-cleanup-pvc: "true"
spec:
  pipelineRef:
    name: remediate
  taskRunTemplate:
    serviceAccountName: ${SERVICE_ACCOUNT:-lightwell-agent}
  taskRunSpecs:
    - pipelineTaskName: claim-application
      serviceAccountName: ${CLAIM_ACCOUNT:-lightwell-run-claim}
  timeouts:
    pipeline: 0h10m0s
  params:
    - name: application
      value: $APPLICATION
    - name: replay
      value: "true"
  workspaces:
    - name: source
      volumeClaimTemplate:
        spec:
          accessModes: [ReadWriteOnce]
          resources:
            requests:
              storage: 1Gi
    - name: fixtures
      configMap:
        name: $APPLICATION
YAML
}

wait_for() {
  local run="$1" waited=0
  while [ "$waited" -lt 300 ]; do
    [ -n "$(oc get pipelinerun "$run" -n "$NAMESPACE" \
      -o jsonpath='{.status.completionTime}' 2>/dev/null)" ] && return 0
    sleep 5
    waited=$(( waited + 5 ))
  done
  return 1
}

reason_of() {
  oc get pipelinerun "$1" -n "$NAMESPACE" -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null
}

first="$(start_run)"
[ -n "$first" ] || die "could not start the first run"
log "first:  $first"

# Long enough for the first run's claim to be recorded, short enough that it
# is still running when the second arrives.
sleep 12

second="$(start_run)"
[ -n "$second" ] || die "could not start the second run"
log "second: $second"

wait_for "$second" || { log "the second run never completed"; exit 1; }
wait_for "$first"  || { log "the first run never completed"; exit 1; }

second_reason="$(reason_of "$second")"
first_reason="$(reason_of "$first")"

log "first:  $first_reason"
log "second: $second_reason"

problems=0

if [ "$second_reason" = "Failed" ]; then
  claim_log="$(oc logs -n "$NAMESPACE" "${second}-claim-application-pod" \
    --all-containers 2>/dev/null | grep -c 'already remediating')"
  if [ "${claim_log:-0}" -gt 0 ]; then
    printf '  ok    the second run was refused by the claim\n' >&2
  else
    printf '  FAIL  the second run failed, but not at the claim\n' >&2
    problems=1
  fi
else
  printf '  FAIL  the second run was not refused (%s)\n' "$second_reason" >&2
  problems=1
fi

if [ "$first_reason" = "Succeeded" ]; then
  printf '  ok    the run in progress was unaffected\n' >&2
else
  printf '  FAIL  the run in progress did not succeed (%s)\n' "$first_reason" >&2
  problems=1
fi

[ "$problems" -eq 0 ]
