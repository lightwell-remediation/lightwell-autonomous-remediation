#!/usr/bin/env bash
# test-pipeline.sh — run the Tekton orchestration against recorded documents.
#
# Every phase is a document in and a document out, so the whole sequence
# replays with no session started: the when expressions, the skip
# propagation, the bounded retry, the sentinel that stops a non-regression
# from being retried, and the two workspaces. In seconds, for nothing, and
# with no MaaS, GitHub or Lightwell credentials involved.
#
# It asserts the run's status **and** which tasks were skipped. The status
# alone is not enough: a run that succeeds having skipped the wrong half of
# the sequence looks identical to one that did the work.
#
# Usage:
#   test-pipeline.sh                 every scenario
#   test-pipeline.sh delivered ...   the named ones
#
# Exit status:
#   0  every scenario behaved as its expectations say
#   1  at least one did not
#   2  configuration error

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$SCRIPT_DIR/.."
readonly SCENARIOS="$REPO_ROOT/agent-runtime/test/fixtures/scenarios"
readonly NAMESPACE="${NAMESPACE:-lightwell-agents}"
readonly CACHE_CLAIM="${CACHE_CLAIM:-lightwell-maven-cache}"
readonly SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-lightwell-agent}"
readonly CLAIM_ACCOUNT="${CLAIM_ACCOUNT:-lightwell-run-claim}"
readonly STATUS_DIR="$REPO_ROOT/.agent-status"
readonly TIMEOUT="${TIMEOUT:-600}"
readonly EXIT_CONFIG=2

die() { printf 'test-pipeline: %s\n' "$*" >&2; exit "$EXIT_CONFIG"; }
log() { printf 'test-pipeline: %s\n' "$*" >&2; }

command -v oc >/dev/null || die "oc is not installed"
oc whoami >/dev/null 2>&1 || die "not logged in to a cluster"
[ -d "$SCENARIOS" ] || die "scenario directory not found: $SCENARIOS"

# What each scenario must do. The skipped list is the load-bearing half:
# "succeeded" says a run finished, not that it did the right thing.
#
# The attempt counts differ from the same scenarios through
# `remediate.sh --replay`, and only for cannot-verify: the local sequencer
# decides not to re-enter patching and stops at one, while Tekton's retries
# field cannot discriminate between failures, so a second attempt starts and
# the patch step exits on the sentinel having started no session. Two
# attempts, no patching, nothing spent. The substance of "never retried"
# holds; the count does not, and pretending otherwise here would hide it.
#
#   <scenario>|<expected status>|<comma-separated tasks that must be skipped>|<attempts of patch-and-verify>
readonly EXPECTATIONS=(
  "delivered|Succeeded||1"
  "no-action-needed|Succeeded|baseline,demonstrate,patch-and-verify,sbom,deliver|0"
  "red-baseline|Failed|demonstrate,patch-and-verify,sbom,deliver|0"
  "retry-then-verified|Succeeded||2"
  "retry-then-regression|Failed|sbom,deliver|2"
  "cannot-verify|Failed|sbom,deliver|2"
)

wanted=("$@")
mkdir -p "$STATUS_DIR"

expectation_for() {
  local name="$1" row
  for row in "${EXPECTATIONS[@]}"; do
    [ "${row%%|*}" = "$name" ] && { printf '%s' "$row"; return 0; }
  done
  return 1
}

run_scenario() {
  local name="$1"
  local dir="$SCENARIOS/$name"
  local row expected_status expected_skips expected_attempts
  row="$(expectation_for "$name")" || { log "no expectations recorded for $name"; return 1; }
  IFS='|' read -r _ expected_status expected_skips expected_attempts <<<"$row"

  [ -d "$dir" ] || { log "$name: scenario directory missing"; return 1; }

  local cm="replay-$name"
  # Each scenario claims a distinct application, so scenarios can be run
  # concurrently without the one-run-per-application claim refusing them —
  # which would be the claim working, not a problem to configure around.
  oc delete configmap "$cm" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
  oc create configmap "$cm" -n "$NAMESPACE" --from-file="$dir" >/dev/null \
    || { log "$name: could not create the fixtures ConfigMap"; return 1; }

  local run
  run="$(oc create -n "$NAMESPACE" -o name -f - <<YAML | cut -d/ -f2
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: replay-$name-
  labels:
    app.kubernetes.io/part-of: lightwell-remediation
    lightwell.dev/scenario: $name
    lightwell.dev/application: $cm
  annotations:
    tekton.dev/auto-cleanup-pvc: "true"
spec:
  pipelineRef:
    name: remediate
  taskRunTemplate:
    serviceAccountName: $SERVICE_ACCOUNT
  # Only the claim talks to the Kubernetes API, and only it gets an identity
  # that can. The agent's service account holds no Role, deliberately.
  taskRunSpecs:
    - pipelineTaskName: claim-application
      serviceAccountName: $CLAIM_ACCOUNT
  timeouts:
    pipeline: 0h15m0s
  params:
    - name: application
      value: $cm
    - name: replay
      value: "true"
    - name: cache-claim
      value: $CACHE_CLAIM
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
        name: $cm
YAML
  )"
  [ -n "$run" ] || { log "$name: could not create the PipelineRun"; return 1; }
  log "$name: started $run"

  local waited=0
  while [ "$waited" -lt "$TIMEOUT" ]; do
    local completion
    completion="$(oc get pipelinerun "$run" -n "$NAMESPACE" \
      -o jsonpath='{.status.completionTime}' 2>/dev/null)"
    [ -n "$completion" ] && break
    sleep 5
    waited=$(( waited + 5 ))
  done

  oc get pipelinerun "$run" -n "$NAMESPACE" -o json 2>/dev/null >"$STATUS_DIR/$name.json" \
    || { log "$name: could not read the run back"; return 1; }
  # The TaskRuns carry retriesStatus, which is where the bounded retry shows
  # up: one entry means a second attempt happened.
  oc get taskruns -n "$NAMESPACE" -l "tekton.dev/pipelineRun=$run" -o json \
    2>/dev/null >"$STATUS_DIR/$name.taskruns.json" || true

  python3 -I "$SCRIPT_DIR/lib/assert-run.py" \
    "$STATUS_DIR/$name.json" "$STATUS_DIR/$name.taskruns.json" \
    "$name" "$expected_status" "$expected_skips" "$expected_attempts"
}

scenarios=()
if [ "${#wanted[@]}" -gt 0 ]; then
  scenarios=("${wanted[@]}")
else
  for row in "${EXPECTATIONS[@]}"; do scenarios+=("${row%%|*}"); done
fi

pass=0
fail=0
failed_names=()
for name in "${scenarios[@]}"; do
  printf '\n'
  if run_scenario "$name"; then
    pass=$(( pass + 1 ))
  else
    fail=$(( fail + 1 )); failed_names+=("$name")
  fi
done

printf '\ntest-pipeline: %d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ] || printf 'test-pipeline: failed: %s\n' "${failed_names[*]}" >&2

python3 -I - "$STATUS_DIR/test-pipeline.json" "$pass" "$fail" "${failed_names[*]:-}" <<'PY'
import json, sys, time
path, passed, failed, names = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
json.dump({
    "script": "test-pipeline",
    "finished": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    "passed": passed,
    "failed": failed,
    "failed_scenarios": names.split() if names else [],
    "exit": 0 if failed == 0 else 1,
}, open(path, "w"), indent=2)
PY

[ "$fail" -eq 0 ]
