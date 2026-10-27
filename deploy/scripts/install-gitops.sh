#!/usr/bin/env bash
# install-gitops.sh - install the OpenShift GitOps operator and configure ArgoCD.
#
# The one imperative platform step. GitOps cannot install its own reconciler,
# so this runs before anything else (ADR-0006). Modelled on
# rhoai-nightly/scripts/install-gitops.sh, with the manifests inlined under
# deploy/bootstrap instead of pulled from the gitops-catalog repo.
#
# Idempotent, and safe on a cluster that came with GitOps (the RHDP Field
# Sourced Content item does): when a Subscription to the operator already
# exists, in any namespace, the operator manifests are not applied. A second
# OperatorGroup or Subscription would break the existing install, or move it
# to another channel. Only the ArgoCD patch, the RBAC lines and the
# cluster-admin binding are applied, and the RBAC lines are added, never
# replaced.
#
# Usage: deploy/scripts/install-gitops.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cluster

# namespace/name of an existing Subscription to the operator, if any.
existing_sub() {
  oc get subscriptions.operators.coreos.com -A \
    -o jsonpath='{range .items[?(@.spec.name=="openshift-gitops-operator")]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' \
    2>/dev/null | head -1
}

sub="$(existing_sub)"
if [[ -n "$sub" ]]; then
  channel="$(oc get subscriptions.operators.coreos.com "${sub#*/}" -n "${sub%%/*}" \
    -o jsonpath='{.spec.channel}' 2>/dev/null || true)"
  log_step "OpenShift GitOps is already installed ($sub, channel ${channel:-default}); leaving the operator alone"
else
  log_step "Installing the OpenShift GitOps operator"
  oc apply -k "$DEPLOY_DIR/bootstrap/gitops-operator/"
  sub="openshift-gitops-operator/openshift-gitops-operator"
fi

log_step "Waiting for the operator CSV (2 to 3 minutes on a cold catalog)"
# Read off the Subscription rather than listed: an operator installed for all
# namespaces has its CSV copied into every namespace, and the copies are not
# the install.
deadline=$(( SECONDS + 600 ))
while (( SECONDS < deadline )); do
  csv="$(oc get subscriptions.operators.coreos.com "${sub#*/}" -n "${sub%%/*}" \
    -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
  if [[ -n "$csv" ]]; then
    phase="$(oc get csv "$csv" -n "${sub%%/*}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" == "Succeeded" ]] && { log_info "operator installed: $csv"; break; }
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

# Cluster admins see every Application in the UI, which is what you want when
# debugging a sync on a shared cluster. Appended line by line, so a policy the
# cluster already had — the operator default, or a catalog item's — survives.
policy="$(oc get argocd openshift-gitops -n openshift-gitops -o jsonpath='{.spec.rbac.policy}' 2>/dev/null || true)"
updated="$policy"
for line in "g, system:cluster-admins, role:admin" "g, cluster-admins, role:admin"; do
  grep -qxF "$line" <<<"$updated" || updated="${updated:+$updated$'\n'}$line"
done
if [[ "$updated" != "$policy" ]]; then
  patch="$(python3 -I -c 'import json,sys; print(json.dumps({"spec":{"rbac":{"policy":sys.stdin.read()}}}))' <<<"$updated")"
  oc patch argocd openshift-gitops -n openshift-gitops --type=merge -p "$patch" >/dev/null \
    || die "could not add the cluster-admins lines to the ArgoCD RBAC policy"
  log_info "ArgoCD RBAC: cluster admins added to the existing policy"
else
  log_info "ArgoCD RBAC: cluster admins already have the admin role"
fi

log_step "Waiting for the ArgoCD server"
for _ in $(seq 1 60); do
  oc get deployment/openshift-gitops-server -n openshift-gitops >/dev/null 2>&1 && break
  sleep 5
done
oc rollout status deployment/openshift-gitops-server -n openshift-gitops --timeout=300s \
  || die "the ArgoCD server did not become ready"

route="$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}' 2>/dev/null || true)"
log_info "ArgoCD ready: https://${route:-<no route yet>}"
