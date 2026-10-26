#!/usr/bin/env bash
# build-image.sh - build the agent runtime image in the cluster.
#
# Two chained builds (ADR-0008). The base BuildConfig starts itself when ArgoCD
# creates it, and the second one chains off the base ImageStreamTag, so most of
# the time this script has nothing to start and only follows what is already
# running. That is the difference between "build" and "start a second build of
# the same thing".
#
# Usage:
#   deploy/scripts/build-image.sh [--namespace lightwell-agents] [--force]
#
# Exit status:
#   0  both images present
#   1  a build failed or never finished

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

NAMESPACE="${NAMESPACE:-lightwell-agents}"
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="${2:?--namespace needs a value}"; shift 2 ;;
    --force)     FORCE=1; shift ;;
    -h|--help)   sed -n '2,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)           die "unknown argument: $1" ;;
  esac
done

require_cluster

latest_build() {
  oc get builds -n "$NAMESPACE" -l "buildconfig=$1" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null
}

build_phase() {
  oc get build "$1" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null
}

# Follows a build to its end. oc logs -f returns when the pod ends, which is
# not always when the Build object settles, so the phase is re-read after.
follow() {
  local build="$1"
  oc logs -f "build/$build" -n "$NAMESPACE" 2>/dev/null | tail -20 || true
  local deadline=$(( SECONDS + 120 )) phase
  while (( SECONDS < deadline )); do
    phase="$(build_phase "$build")"
    case "$phase" in
      Complete|Failed|Error|Cancelled) echo "$phase"; return ;;
    esac
    sleep 5
  done
  echo "${phase:-Unknown}"
}

run_build() {
  local bc="$1" build phase
  build="$(latest_build "$bc")"
  phase="${build:+$(build_phase "$build")}"

  if (( FORCE )) || [[ -z "$build" ]] || [[ "$phase" =~ ^(Failed|Error|Cancelled)$ ]]; then
    log_step "starting $bc${build:+ (last one was $phase)}"
    build="$(oc start-build "$bc" -n "$NAMESPACE" -o name 2>&1)" \
      || die "could not start $bc: $build"
    build="${build#*/}"
  elif [[ "$phase" == "Complete" ]]; then
    log_ok "$bc already built ($build), use --force to rebuild"
    return 0
  else
    log_step "$bc is already building ($build, $phase), following it"
  fi

  log_info "following $build"
  phase="$(follow "$build")"
  [[ "$phase" == "Complete" ]] || {
    log_error "$bc ended as $phase"
    log_error "logs: oc logs build/$build -n $NAMESPACE"
    return 1
  }
  log_ok "$bc: $build Complete"
}

# The upstream image is the slow one, npm plus microdnf over the network.
run_build upstream-claude-code || exit 1

# The chain. If the image change trigger already fired, this follows that build
# instead of starting a redundant one.
log_step "waiting for the chained build to appear"
deadline=$(( SECONDS + 120 ))
while (( SECONDS < deadline )); do
  [[ -n "$(latest_build lightwell-agent-runtime)" ]] && break
  sleep 10
done
run_build lightwell-agent-runtime || exit 1

echo
oc get istag -n "$NAMESPACE" 2>/dev/null
