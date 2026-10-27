#!/usr/bin/env bash
# preflight.sh - check the cluster before changing anything.
#
# Everything the bootstrap assumes, asserted up front with a message that names
# what is missing. Cheaper than finding out from a half installed platform.
#
# Usage: deploy/scripts/preflight.sh
#
# Exit status:
#   0  ready, warnings may be printed
#   1  something required is missing

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

FAILED=0
fail() { log_fail "$*"; FAILED=1; }

require_cluster
echo

log_step "Permissions"
if [[ "$(oc auth can-i '*' '*' --all-namespaces 2>/dev/null)" == "yes" ]]; then
  log_ok "cluster admin"
else
  fail "not cluster admin. Installing operators and creating cluster scoped resources needs it"
fi

log_step "OpenShift version"
OCP_VERSION="$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null)"
if [[ -n "$OCP_VERSION" ]]; then
  log_ok "OpenShift $OCP_VERSION"
  case "$OCP_VERSION" in
    4.1[0-5].*) log_skip "RHOAI 3.5 wants 4.16 or newer, this is $OCP_VERSION" ;;
  esac
else
  fail "cannot read the cluster version"
fi

log_step "Cluster capabilities"
CAPS="$(oc get clusterversion version -o jsonpath='{.status.capabilities.enabledCapabilities}' 2>/dev/null)"
for cap in Build ImageRegistry; do
  if [[ "$CAPS" == *"\"$cap\""* ]]; then
    log_ok "$cap enabled"
  else
    fail "$cap capability disabled. The runtime image is built in cluster (ADR-0008), this cluster cannot"
  fi
done
# Asked through the API group rather than piping api-resources into grep -q:
# under pipefail that pipe dies with SIGPIPE and reports a missing API on a
# cluster that has it.
if oc get --raw /apis/build.openshift.io/v1 >/dev/null 2>&1; then
  log_ok "BuildConfig API present"
else
  fail "no BuildConfig API, so the chained image builds cannot run"
fi

log_step "Image registry"
REG_STATE="$(oc get configs.imageregistry.operator.openshift.io cluster -o jsonpath='{.spec.managementState}' 2>/dev/null)"
REG_STORAGE="$(oc get configs.imageregistry.operator.openshift.io cluster -o jsonpath='{.spec.storage}' 2>/dev/null)"
if [[ "$REG_STATE" == "Managed" ]]; then
  log_ok "registry Managed"
else
  fail "registry managementState is '$REG_STATE', the builds have nowhere to push"
fi
case "$REG_STORAGE" in
  *emptyDir*) log_skip "registry storage is emptyDir, the 2.2 GB image is lost on a registry restart" ;;
  *pvc*)      log_ok "registry storage: PVC" ;;
  *s3*|*gcs*|*azure*|*swift*) log_ok "registry storage: object storage" ;;
  "")         fail "registry has no storage configured" ;;
  *)          log_skip "registry storage: $REG_STORAGE" ;;
esac

log_step "Storage"
DEFAULT_SC="$(oc get sc -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' 2>/dev/null | grep '=true$' | cut -d= -f1)"
if [[ -n "$DEFAULT_SC" ]]; then
  log_ok "default StorageClass: $DEFAULT_SC"
else
  fail "no default StorageClass. MLflow and the Tekton workspaces both need PVCs"
fi

log_step "Operator channels"
check_channel() {
  local pkg="$1" want="$2" label="$3"
  local channels
  channels="$(oc get packagemanifest "$pkg" -n openshift-marketplace -o jsonpath='{range .status.channels[*]}{.name}{" "}{end}' 2>/dev/null)"
  if [[ -z "$channels" ]]; then
    fail "$label: package '$pkg' not in the cluster catalog"
    return
  fi
  if [[ " $channels " == *" $want "* ]]; then
    local csv
    csv="$(oc get packagemanifest "$pkg" -n openshift-marketplace -o jsonpath="{.status.channels[?(@.name==\"$want\")].currentCSV}" 2>/dev/null)"
    log_ok "$label: channel $want -> ${csv:-unknown}"
  else
    fail "$label: channel '$want' not offered. Available: $channels"
  fi
}
check_channel openshift-gitops-operator      latest      "OpenShift GitOps"
check_channel openshift-pipelines-operator-rh latest     "OpenShift Pipelines"
check_channel rhods-operator                 stable-3.5  "OpenShift AI"

log_step "What is already installed"
PRESET="cluster-plain.yaml"
if oc get crd datascienceclusters.datasciencecluster.opendatahub.io >/dev/null 2>&1; then
  DSC="$(oc get datasciencecluster -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  log_skip "RHOAI is already installed${DSC:+ (DataScienceCluster $DSC)}"
  PRESET="cluster-rhoai-existing.yaml"
  MLFLOW_STATE="$(oc get datasciencecluster -o jsonpath='{.items[0].spec.components.mlflowoperator.managementState}' 2>/dev/null)"
  [[ "$MLFLOW_STATE" == "Managed" ]] \
    && log_ok "existing DSC has mlflowoperator Managed" \
    || log_skip "existing DSC has mlflowoperator '${MLFLOW_STATE:-unset}', the MLflow CR needs it Managed"
else
  log_ok "no RHOAI, this bootstrap installs it"
fi
oc get crd tektonconfigs.operator.tekton.dev >/dev/null 2>&1 \
  && log_skip "OpenShift Pipelines is already installed, the Subscription will adopt it" \
  || log_ok "no Tekton, this bootstrap installs it"
GITOPS_SUB="$(oc get subscriptions.operators.coreos.com -A \
  -o jsonpath='{range .items[?(@.spec.name=="openshift-gitops-operator")]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1)"
if [[ -n "$GITOPS_SUB" ]]; then
  log_skip "OpenShift GitOps is already installed ($GITOPS_SUB); make gitops leaves the operator alone and only adds to the ArgoCD instance"
elif oc get crd argocds.argoproj.io >/dev/null 2>&1; then
  log_skip "an ArgoCD CRD exists but no openshift-gitops-operator Subscription; make gitops would install a second operator, check first"
else
  log_ok "no GitOps operator, make gitops installs it"
fi

log_step "Capacity"
# Rough: the platform plus two parallel sessions plus a build needs around
# 14 CPU and 37 GiB of requests on top of what the cluster already runs.
ALLOC_CPU="$(oc get nodes -o jsonpath='{range .items[*]}{.status.allocatable.cpu}{"\n"}{end}' 2>/dev/null | sed 's/m$//' | awk '{s+=($1>1000?$1/1000:$1)} END {print int(s)}')"
ALLOC_MEM="$(oc get nodes -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null | sed 's/Ki$//' | awk '{s+=$1} END {print int(s/1024/1024)}')"
if [[ -n "$ALLOC_CPU" && "$ALLOC_CPU" -gt 0 ]]; then
  log_ok "allocatable: ${ALLOC_CPU} CPU, ${ALLOC_MEM} GiB across $(oc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ') node(s)"
  (( ALLOC_CPU >= 16 )) || log_skip "16 CPU is the floor for the platform plus two parallel agents"
  (( ALLOC_MEM >= 48 )) || log_skip "48 GiB is the floor for the platform plus two parallel agents"
else
  log_skip "cannot read node capacity"
fi

echo
if (( FAILED )); then
  log_error "preflight failed, fix the items above before running make deploy-all"
  exit 1
fi
log_info "preflight passed. Suggested preset: deploy/values/$PRESET"
