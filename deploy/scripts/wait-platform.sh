#!/usr/bin/env bash
# wait-platform.sh - wait until the platform is usable after a deploy.
#
# Sync waves order the apply, not readiness, so the first sync always shows
# transient failures while CRDs appear. This waits for the things the next step
# needs (the Tekton CRDs and the BuildConfigs) instead of asking a human to
# watch the ArgoCD UI.
#
# Usage: deploy/scripts/wait-platform.sh [--namespace lightwell-agents]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

NAMESPACE="${NAMESPACE:-lightwell-agents}"
TIMEOUT="${TIMEOUT:-900}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="${2:?--namespace needs a value}"; shift 2 ;;
    *)           die "unknown argument: $1" ;;
  esac
done

wait_for() {
  local what="$1" cmd="$2" deadline=$(( SECONDS + TIMEOUT ))
  while (( SECONDS < deadline )); do
    if eval "$cmd" >/dev/null 2>&1; then
      log_ok "$what"
      return 0
    fi
    sleep 10
  done
  log_skip "$what did not appear within ${TIMEOUT}s, check the ArgoCD applications"
  return 1
}

log_step "Waiting for the pieces the next step needs"
wait_for "Tekton CRDs"              "oc get crd pipelines.tekton.dev"
wait_for "namespace $NAMESPACE"     "oc get namespace $NAMESPACE"
wait_for "BuildConfigs"             "oc get bc upstream-claude-code lightwell-agent-runtime -n $NAMESPACE"
# pipelines.tekton.dev, not pipeline: aipipelines brings pipelines.kubeflow.org
# and the short name stops meaning Tekton once it is Managed.
wait_for "smoke Pipeline"           "oc get pipelines.tekton.dev agent-runtime-smoke -n $NAMESPACE"

# RHOAI takes the longest and nothing in Milestone 1 blocks on it, so it is
# reported, not waited on.
if oc get crd datascienceclusters.datasciencecluster.opendatahub.io >/dev/null 2>&1; then
  ready="$(oc get datasciencecluster -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
  [[ "$ready" == "True" ]] \
    && log_ok "DataScienceCluster Ready" \
    || log_skip "DataScienceCluster is still reconciling, make validate will tell you"
fi
