#!/usr/bin/env bash
# validate.sh - prove the cluster can host an agent run.
#
# ArgoCD health is not platform health: it reports a Subscription healthy before
# the operator works, and a DataScienceCluster healthy the moment the object
# exists. So the gate is here, and it ends by running agent shaped workloads in
# parallel rather than a hello-world (ADR-0006).
#
# Usage:
#   deploy/scripts/validate.sh [--namespace lightwell-agents] [--no-pipeline]
#
# Exit status:
#   0  the cluster is ready
#   1  a check failed, the failing one is named

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

NAMESPACE="${NAMESPACE:-lightwell-agents}"
RUN_PIPELINE=1
PIPELINE_TIMEOUT="${PIPELINE_TIMEOUT:-15m}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)   NAMESPACE="${2:?--namespace needs a value}"; shift 2 ;;
    --no-pipeline) RUN_PIPELINE=0; shift ;;
    -h|--help)     sed -n '2,14p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)             die "unknown argument: $1" ;;
  esac
done

FAILED=0
fail() { log_fail "$*"; FAILED=1; }

require_cluster
echo

log_step "ArgoCD applications"
# Only the ones this bootstrap created. A cluster that came with GitOps, such
# as the RHDP Field Sourced Content item, has Applications of its own in the
# same namespace, and their state is not ours to judge.
RELEASE="${RELEASE:-lightwell-bootstrap}"
if oc get applications.argoproj.io -n openshift-gitops >/dev/null 2>&1; then
  ours=0
  while IFS='|' read -r name sync health op release; do
    [[ -z "$name" ]] && continue
    if [[ "$release" != "$RELEASE" ]]; then
      log_skip "$name is not part of $RELEASE, not judged"
      continue
    fi
    ours=$(( ours + 1 ))
    if [[ "$sync" != "Synced" || "$health" != "Healthy" ]]; then
      fail "$name is $sync / $health"
      continue
    fi
    # Synced and Healthy is not the same as "the last apply worked". With
    # ServerSideApply the comparison is a dry run, so an admission webhook that
    # denies the real apply the same way it denies the dry run leaves the
    # Application looking Synced while nothing it asked for reached the cluster.
    # Seen on this project: the DataScienceCluster v2 webhook rejecting a
    # component state, with every Application green. The operation phase is the
    # only field that tells the truth.
    case "$op" in
      Succeeded|"")
        log_ok "$name" ;;
      Running)
        # A retry loop around a rejected apply also sits in Running, so report
        # it rather than passing it.
        msg="$(oc get application "$name" -n openshift-gitops \
                 -o jsonpath='{range .status.operationState.syncResult.resources[?(@.status=="SyncFailed")]}{.kind}{"/"}{.name}{": "}{.message}{"\n"}{end}' 2>/dev/null | head -2)"
        if [[ -n "$msg" ]]; then
          fail "$name is Synced but its last apply was rejected"
          printf '        %s\n' "$msg"
        else
          log_skip "$name has a sync in flight"
        fi ;;
      *)
        fail "$name last sync operation: $op"
        oc get application "$name" -n openshift-gitops \
          -o jsonpath='{.status.operationState.message}{"\n"}' 2>/dev/null \
          | sed 's/^/        /' | head -2 ;;
    esac
  done < <(oc get applications.argoproj.io -n openshift-gitops \
             -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.sync.status}{"|"}{.status.health.status}{"|"}{.status.operationState.phase}{"|"}{.metadata.annotations.meta\.helm\.sh/release-name}{"\n"}{end}' 2>/dev/null)
  (( ours > 0 )) || fail "no Applications from release $RELEASE, run make deploy first"
else
  fail "no ArgoCD Applications, run make gitops and make deploy first"
fi

log_step "Operators"
check_csv() {
  local ns="$1" match="$2" label="$3"
  local all line
  all="$(oc get csv -n "$ns" --no-headers 2>/dev/null)"
  # grep -m1 rather than piping into head: head closing the pipe first makes
  # grep die of SIGPIPE, which pipefail then reports as a failure.
  line="$(grep -m1 -- "$match" <<<"$all")"
  if [[ -z "$line" ]]; then
    fail "$label: no CSV in $ns"
    return
  fi
  local name phase
  name="$(awk '{print $1}' <<<"$line")"
  phase="$(oc get csv "$name" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)"
  [[ "$phase" == "Succeeded" ]] && log_ok "$label: $name" || fail "$label: $name is $phase"
}
# Wherever it was installed: by make gitops, or by the catalog item.
GITOPS_NS="$(oc get subscriptions.operators.coreos.com -A \
  -o jsonpath='{range .items[?(@.spec.name=="openshift-gitops-operator")]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | head -1)"
check_csv "${GITOPS_NS:-openshift-gitops-operator}" gitops "OpenShift GitOps"
check_csv openshift-operators       pipelines "OpenShift Pipelines"
if oc get ns redhat-ods-operator >/dev/null 2>&1; then
  check_csv redhat-ods-operator rhods "OpenShift AI"
else
  log_skip "no redhat-ods-operator namespace, RHOAI is not part of this install"
fi

log_step "DataScienceCluster"
if oc get datasciencecluster >/dev/null 2>&1 && [[ -n "$(oc get datasciencecluster -o name 2>/dev/null)" ]]; then
  dsc="$(oc get datasciencecluster -o jsonpath='{.items[0].metadata.name}')"
  # Only the conditions this project depends on. Components that are Removed
  # report their condition False, which is correct and not a failure.
  for cond in Ready ComponentsReady DashboardReady MLflowOperatorReady; do
    status="$(oc get datasciencecluster "$dsc" -o jsonpath="{.status.conditions[?(@.type==\"$cond\")].status}" 2>/dev/null)"
    case "$status" in
      True) log_ok "$dsc $cond" ;;
      "")   log_skip "$dsc has no $cond condition yet" ;;
      *)    fail "$dsc $cond is $status" ;;
    esac
  done
else
  log_skip "no DataScienceCluster, RHOAI is not part of this install"
fi

log_step "MLflow"
if oc get crd mlflows.mlflow.opendatahub.io >/dev/null 2>&1; then
  mlflow_state="$(oc get mlflow mlflow -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)"
  if [[ "$mlflow_state" == "True" ]]; then
    log_ok "MLflow Available"
  else
    phase="$(oc get mlflow mlflow -o jsonpath='{.status.phase}' 2>/dev/null)"
    ready="$(oc get pods -n redhat-ods-applications -l app=mlflow --no-headers 2>/dev/null | grep -c Running)"
    if [[ "${ready:-0}" -ge 1 ]]; then
      log_ok "MLflow pods running (status.phase=${phase:-unset})"
    else
      fail "MLflow is not available (status.phase=${phase:-unset})"
    fi
  fi
else
  log_skip "no MLflow CRD, the mlflowoperator component is not Managed"
fi

log_step "Agent namespace"
if oc get namespace "$NAMESPACE" >/dev/null 2>&1; then
  log_ok "namespace $NAMESPACE"
  oc get sa lightwell-agent -n "$NAMESPACE" >/dev/null 2>&1 \
    && log_ok "ServiceAccount lightwell-agent" \
    || fail "no ServiceAccount lightwell-agent in $NAMESPACE"
  oc get limitrange lightwell-agent-budget -n "$NAMESPACE" >/dev/null 2>&1 \
    && log_ok "LimitRange lightwell-agent-budget" \
    || fail "no LimitRange in $NAMESPACE"
  [[ "$(oc get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.opendatahub\.io/dashboard}')" == "true" ]] \
    && log_ok "namespace is an MLflow workspace" \
    || log_skip "namespace is missing opendatahub.io/dashboard=true, MLflow will not discover it"
else
  fail "no namespace $NAMESPACE"
fi

log_step "Credentials"
for s in lightwell-maas lightwell-github; do
  oc get secret "$s" -n "$NAMESPACE" >/dev/null 2>&1 \
    && log_ok "secret $s" \
    || fail "no secret $s, run make secrets"
done
oc get secret lightwell-lightwell -n "$NAMESPACE" >/dev/null 2>&1 \
  && log_ok "secret lightwell-lightwell" \
  || log_skip "no secret lightwell-lightwell: fine on path B, path A needs it (docs/replicate.md)"

log_step "Runtime image"
TAG="$(oc get buildconfig lightwell-agent-runtime -n "$NAMESPACE" -o jsonpath='{.spec.output.to.name}' 2>/dev/null)"
if [[ -n "$TAG" ]]; then
  if oc get imagestreamtag "$TAG" -n "$NAMESPACE" >/dev/null 2>&1; then
    log_ok "image $TAG"
  else
    fail "no image $TAG, run make build-image"
  fi
  for bc in upstream-claude-code lightwell-agent-runtime; do
    phase="$(oc get builds -n "$NAMESPACE" -l "buildconfig=$bc" \
               --sort-by=.metadata.creationTimestamp \
               -o jsonpath='{.items[-1:].status.phase}' 2>/dev/null)"
    case "${phase:-none}" in
      Complete) log_ok "last build of $bc: Complete" ;;
      none)     fail "$bc has never run, run make build-image" ;;
      *)        fail "last build of $bc: $phase" ;;
    esac
  done
else
  fail "no BuildConfig lightwell-agent-runtime in $NAMESPACE"
fi

if (( RUN_PIPELINE )); then
  log_step "Two agent workloads in parallel"
  # Fully qualified: RHOAI's aipipelines component brings pipelines.kubeflow.org,
  # which also serves "pipelines", so the short name stops meaning Tekton and
  # this check reports a Pipeline that is sitting right there as missing.
  if ! oc get pipelines.tekton.dev agent-runtime-smoke -n "$NAMESPACE" >/dev/null 2>&1; then
    fail "no Pipeline agent-runtime-smoke in $NAMESPACE"
  elif (( FAILED )); then
    log_skip "skipped, earlier checks failed"
  else
    # The PipelineRun is built here, not in a chart: it is immutable and
    # one-shot, so under GitOps it would be permanent drift. Workspaces are
    # read from the Pipeline, so changing agents.concurrency needs no edit here.
    workspaces="$(oc get pipelines.tekton.dev agent-runtime-smoke -n "$NAMESPACE" -o jsonpath='{range .spec.workspaces[*]}{.name}{"\n"}{end}')"
    run_yaml="$(mktemp)"
    {
      echo "apiVersion: tekton.dev/v1"
      echo "kind: PipelineRun"
      echo "metadata:"
      echo "  generateName: agent-runtime-smoke-"
      echo "  namespace: $NAMESPACE"
      echo "spec:"
      echo "  pipelineRef:"
      echo "    name: agent-runtime-smoke"
      echo "  taskRunTemplate:"
      echo "    serviceAccountName: lightwell-agent"
      echo "  timeouts:"
      echo "    pipeline: $PIPELINE_TIMEOUT"
      echo "  workspaces:"
      while read -r ws; do
        [[ -z "$ws" ]] && continue
        echo "    - name: $ws"
        echo "      volumeClaimTemplate:"
        echo "        spec:"
        echo "          accessModes: [ReadWriteOnce]"
        echo "          resources:"
        echo "            requests:"
        echo "              storage: 5Gi"
      done <<<"$workspaces"
    } > "$run_yaml"

    run="$(oc create -f "$run_yaml" -o name 2>&1)" || { fail "could not create the PipelineRun: $run"; run=""; }
    rm -f "$run_yaml"

    if [[ -n "$run" ]]; then
      log_info "${run#*/} started, waiting up to $PIPELINE_TIMEOUT"
      deadline=$(( SECONDS + 1200 ))
      status=""
      while (( SECONDS < deadline )); do
        status="$(oc get "$run" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' 2>/dev/null)"
        [[ "$status" == "True" || "$status" == "False" ]] && break
        sleep 15
      done
      if [[ "$status" == "True" ]]; then
        log_ok "${run#*/} succeeded"
        oc get taskruns.tekton.dev -n "$NAMESPACE" \
          -l "tekton.dev/pipelineRun=${run#*/}" \
          -o jsonpath='{range .items[*]}  {.metadata.labels.tekton\.dev/pipelineTask}{" -> "}{.status.conditions[0].reason}{"\n"}{end}' 2>/dev/null
      else
        fail "${run#*/} did not succeed (${status:-timeout})"
        oc get "$run" -n "$NAMESPACE" -o jsonpath='{.status.conditions[0].message}{"\n"}' 2>/dev/null
        log_info "logs: oc logs -n $NAMESPACE -l tekton.dev/pipelineRun=${run#*/} --all-containers --tail=40"
      fi
    fi
  fi
fi

echo
if (( FAILED )); then
  log_error "validation failed"
  exit 1
fi
log_info "cluster is ready to host an agent run"
