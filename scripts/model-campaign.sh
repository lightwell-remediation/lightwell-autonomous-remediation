#!/usr/bin/env bash
# model-campaign.sh — run the whole sequence several times per model, and
# report whether each model gets to a result a reviewer would accept.
#
# One run tells you a model can do it once. The question is whether it does
# it every time: measured on claude-sonnet-4-6, the same input produced 41
# turns and 108, and two runs in five reached `verified` only on the second
# patching attempt. A model is only usable here if it converges reliably.
#
# What it records per run, beyond pass or fail:
#
#   attempts       the retry is load bearing; a model that always needs two
#                  costs twice as much as one that needs one
#   source change  the point of the fixture. A remediation that only moves
#                  cxf.version leaves the application vulnerable, and the
#                  exploit test is what catches it. "Did it touch the source"
#                  is the quality signal, not "did it go green"
#   cost, duration what it costs to prefer this model
#
# Runs are serial on purpose. The orchestration refuses two runs against one
# application, which is the behaviour under test as much as anything else.
#
# Usage:
#   model-campaign.sh [--runs N] [--osv <file>] [--branch <name>] <model>...
#
# Example:
#   model-campaign.sh --runs 3 minimax-m2 claude-haiku-4-5
#
# Exit status: 0 if every run of every model was delivered, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$SCRIPT_DIR/.."
readonly NAMESPACE="${NAMESPACE:-lightwell-agents}"
readonly STATUS_DIR="$REPO_ROOT/.agent-status"
readonly RESULTS="$STATUS_DIR/model-campaign.jsonl"

die() { printf 'model-campaign: %s\n' "$*" >&2; exit 2; }
log() { printf 'model-campaign: %s\n' "$*" >&2; }

RUNS=3
OSV="$REPO_ROOT/.fixtures/osv/CVE-2026-68079.json"
BRANCH="feat/reachable-cve"
MODELS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --runs)   RUNS="${2:?--runs needs a value}"; shift 2 ;;
    --osv)    OSV="${2:?--osv needs a value}"; shift 2 ;;
    --branch) BRANCH="${2:?--branch needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    -*)       die "unknown argument: $1" ;;
    *)        MODELS+=("$1"); shift ;;
  esac
done
[ "${#MODELS[@]}" -gt 0 ] || die "at least one model is required"
[ -r "$OSV" ] || die "vulnerability record not readable: $OSV"
command -v oc >/dev/null || die "oc is not installed"
oc whoami >/dev/null 2>&1 || die "not logged in to a cluster"

mkdir -p "$STATUS_DIR"
: >"$RESULTS"

# Whether the remediation touched application source, not just the version
# declaration. Read from the patch document the run left behind rather than
# from the diff, because the document says *why*.
source_change_of() {
  local run="$1" pod
  for pod in "$run-patch-and-verify-pod-retry1" "$run-patch-and-verify-pod"; do
    oc logs -n "$NAMESPACE" "$pod" --all-containers 2>/dev/null \
      | grep -oE 'source changes: [0-9]+' | tail -1 | grep -oE '[0-9]+' && return 0
  done
  printf '0'
}

cost_of() {
  local run="$1"
  oc logs -n "$NAMESPACE" -l "tekton.dev/pipelineRun=$run" --all-containers --tail=-1 2>/dev/null \
    | grep -oE 'cost_usd: [0-9.]+' | grep -oE '[0-9.]+' \
    | python3 -I -c "
import sys
print(round(sum(float(x) for x in sys.stdin if x.strip()), 4))" 2>/dev/null
}

total_failures=0

for model in "${MODELS[@]}"; do
  for attempt in $(seq 1 "$RUNS"); do
    log "── $model, run $attempt of $RUNS ──"

    run="$("$SCRIPT_DIR/run-remediation.sh" "$OSV" --branch "$BRANCH" \
            --model "$model" --no-follow 2>/dev/null | tail -1)"
    if [ -z "$run" ]; then
      log "$model run $attempt: could not be started"
      total_failures=$(( total_failures + 1 ))
      continue
    fi
    log "  $run"

    waited=0
    while [ "$waited" -lt 5400 ]; do
      [ -n "$(oc get pipelinerun "$run" -n "$NAMESPACE" \
        -o jsonpath='{.status.completionTime}' 2>/dev/null)" ] && break
      sleep 20
      waited=$(( waited + 20 ))
    done

    oc get pipelinerun "$run" -n "$NAMESPACE" -o json >"$STATUS_DIR/$run.json" 2>/dev/null
    oc get taskruns -n "$NAMESPACE" -l "tekton.dev/pipelineRun=$run" -o json \
      >"$STATUS_DIR/$run.taskruns.json" 2>/dev/null

    pr="$(oc logs -n "$NAMESPACE" "$run-deliver-pod" --all-containers 2>/dev/null \
          | grep -oE 'https://github.com/[^ ]+/pull/[0-9]+' | tail -1)"
    changed="$(source_change_of "$run")"
    cost="$(cost_of "$run")"

    python3 -I "$SCRIPT_DIR/lib/summarise-run.py" \
      "$STATUS_DIR/$run.json" "$STATUS_DIR/$run.taskruns.json" \
      "$model" "$attempt" "${pr:-}" "${changed:-0}" "${cost:-0}" >>"$RESULTS"

    python3 -I "$SCRIPT_DIR/lib/print-run.py" "$RESULTS"
    grep -q '"delivered": true' <<<"$(tail -1 "$RESULTS")" || total_failures=$(( total_failures + 1 ))
  done
done

printf '\n'
python3 -I "$SCRIPT_DIR/lib/campaign-report.py" "$RESULTS"

[ "$total_failures" -eq 0 ]
