#!/usr/bin/env bash
# install-gitops.sh - install the OpenShift GitOps operator and configure ArgoCD.
#
# The one imperative platform step. GitOps cannot install its own reconciler,
# so this runs before anything else (ADR-0006). Modelled on
# rhoai-nightly/scripts/install-gitops.sh, with the manifests inlined under
# deploy/bootstrap instead of pulled from the gitops-catalog repo.
#
# Idempotent: re-running on a cluster that already has it only re-applies the
# ArgoCD patches and the cluster-admin binding.
#
# Usage: deploy/scripts/install-gitops.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cluster

log_step "Installing the OpenShift GitOps operator"
oc apply -k "$DEPLOY_DIR/bootstrap/gitops-operator/"

log_step "Waiting for the operator CSV (2 to 3 minutes on a cold catalog)"
deadline=$(( SECONDS + 600 ))
while (( SECONDS < deadline )); do
  csv="$(oc get csv -n openshift-gitops-operator -o name 2>/dev/null | grep gitops || true)"
  if [[ -n "$csv" ]]; then
    phase="$(oc get "$csv" -n openshift-gitops-operator -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" == "Succeeded" ]] && { log_info "operator installed: ${csv#*/}"; break; }
    log_info "CSV phase: ${phase:-pending}"
  else
    log_info "waiting for the CSV to appear"
  fi
  sleep 10
done
(( SECONDS < deadline )) || die "timed out waiting for the GitOps operator"

log_step "Waiting for the openshift-gitops namespace"
for _ in $(seq 1 60); do
  oc get namespace openshift-gitops >/dev/null 2>&1 && break
  sleep 5
done
oc get namespace openshift-gitops >/dev/null 2>&1 \
  || die "the operator never created the openshift-gitops namespace"

# The ArgoCD CRD lands slightly after the CSV, and the instance itself is
# created by the operator. We only patch it, so retry until both exist.
log_step "Patching the ArgoCD instance and granting cluster-admin"
deadline=$(( SECONDS + 300 ))
until oc apply -k "$DEPLOY_DIR/bootstrap/argocd-instance/" >/dev/null 2>&1; do
  (( SECONDS < deadline )) || die "the ArgoCD instance never became patchable"
  log_info "waiting for the ArgoCD instance"
  sleep 10
done
oc apply -k "$DEPLOY_DIR/bootstrap/argocd-instance/"

log_step "Waiting for the ArgoCD server"
for _ in $(seq 1 60); do
  oc get deployment/openshift-gitops-server -n openshift-gitops >/dev/null 2>&1 && break
  sleep 5
done
oc rollout status deployment/openshift-gitops-server -n openshift-gitops --timeout=300s \
  || die "the ArgoCD server did not become ready"

route="$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}' 2>/dev/null || true)"
log_info "ArgoCD ready: https://${route:-<no route yet>}"
