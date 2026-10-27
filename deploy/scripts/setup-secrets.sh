#!/usr/bin/env bash
# setup-secrets.sh - create the in-cluster credentials from secrets/secrets.env.
#
# Credentials are the one thing that never goes through git or through an ArgoCD
# Application, so they are applied from the same file the local runtime reads,
# with the same variable names (ADR-0007). Idempotent, and it prints no values.
#
# Usage:
#   deploy/scripts/setup-secrets.sh [--namespace lightwell-agents]
#
# Exit status:
#   0  secrets applied
#   1  cluster or namespace problem
#   2  configuration problem (missing file, placeholder left in place)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

NAMESPACE="${NAMESPACE:-lightwell-agents}"
SECRETS_FILE="${SECRETS_FILE:-$REPO_ROOT/secrets/secrets.env}"
ARGO_NS="${ARGO_NS:-openshift-gitops}"
# Discovered from the checkout, which is the repository ArgoCD is pointed at.
REPO_URL="${REPO_URL:-$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="${2:?--namespace needs a value}"; shift 2 ;;
    --file)      SECRETS_FILE="${2:?--file needs a value}";    shift 2 ;;
    --repo-url)  REPO_URL="${2:?--repo-url needs a value}";    shift 2 ;;
    -h|--help)   sed -n '2,14p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)           log_error "unknown argument: $1"; exit 2 ;;
  esac
done

require_cluster

[[ -r "$SECRETS_FILE" ]] || {
  log_error "no $SECRETS_FILE"
  log_error "cp secrets/secrets.template.env secrets/secrets.env && chmod 600 secrets/secrets.env"
  exit 2
}

set -a
# shellcheck disable=SC1090  # path is a parameter, by design
source "$SECRETS_FILE"
set +a

for required in MAAS_BASE_URL MAAS_API_KEY MAAS_MODEL; do
  [[ -n "${!required:-}" && "${!required}" != "CHANGE_ME" ]] \
    || { log_error "$required is not set in $SECRETS_FILE"; exit 2; }
done

# The harness appends the API path itself, so a base URL carrying /v1 produces
# requests to /v1/v1/messages. Easy to paste wrong, hard to debug later.
case "${MAAS_BASE_URL%/}" in
  */v1) log_error "MAAS_BASE_URL must not end in /v1 (the harness appends it)"; exit 2 ;;
esac

oc get namespace "$NAMESPACE" >/dev/null 2>&1 || {
  log_info "creating namespace $NAMESPACE (normally done by the agents-workspace Application)"
  oc create namespace "$NAMESPACE" >/dev/null
}

apply_secret() {
  local name="$1"; shift
  oc create secret generic "$name" -n "$NAMESPACE" "$@" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  log_ok "$name"
}

log_step "Applying secrets to $NAMESPACE"

apply_secret lightwell-maas \
  --from-literal="MAAS_BASE_URL=${MAAS_BASE_URL%/}" \
  --from-literal="MAAS_API_KEY=$MAAS_API_KEY" \
  --from-literal="MAAS_MODEL=$MAAS_MODEL" \
  --from-literal="MAAS_SMALL_MODEL=${MAAS_SMALL_MODEL:-}"

if [[ -n "${GITHUB_TOKEN:-}" && "${GITHUB_TOKEN}" != "CHANGE_ME" ]]; then
  apply_secret lightwell-github \
    --from-literal="GITHUB_TOKEN=$GITHUB_TOKEN" \
    --from-literal="APP_REPO=${APP_REPO:-}" \
    --from-literal="GIT_AUTHOR_NAME=${GIT_AUTHOR_NAME:-lightwell-agent}" \
    --from-literal="GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL:-lightwell-agent@users.noreply.github.com}"

  # A git source secret has to be basic-auth with username and password keys,
  # which an env style Secret is not. Same PAT, different shape, used by the
  # image build to clone this repository while it is private.
  oc create secret generic lightwell-git-source -n "$NAMESPACE" \
    --type=kubernetes.io/basic-auth \
    --from-literal=username=x-access-token \
    --from-literal="password=$GITHUB_TOKEN" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  log_ok "lightwell-git-source (basic-auth, for the image build)"

  # ArgoCD reconciles from this repository, so while the repository is private
  # it needs its own credential too, in its own namespace and in the shape it
  # recognises. Without it every Application fails with "Repository not found",
  # which reads like a wrong path and is not.
  if [[ -n "$REPO_URL" ]] && oc get namespace "$ARGO_NS" >/dev/null 2>&1; then
    oc create secret generic lightwell-repo -n "$ARGO_NS" \
      --from-literal=type=git \
      --from-literal="url=${REPO_URL%.git}" \
      --from-literal=username=x-access-token \
      --from-literal="password=$GITHUB_TOKEN" \
      --dry-run=client -o yaml \
      | oc label --local -f - -o yaml \
          argocd.argoproj.io/secret-type=repository \
      | oc apply -f - >/dev/null
    log_ok "lightwell-repo in $ARGO_NS (ArgoCD read access to ${REPO_URL%.git})"
  else
    log_skip "no ArgoCD namespace or no git remote, skipping the ArgoCD repository credential"
  fi
else
  log_skip "no GITHUB_TOKEN, skipping lightwell-github and lightwell-git-source"
  log_skip "the runtime image build cannot clone a private repository without it"
fi

if [[ -n "${LW_USERNAME:-}" && -n "${LW_PASSWORD:-}" && -n "${LW_MAVEN_REPO_URL:-}" ]]; then
  apply_secret lightwell-lightwell \
    --from-literal="LW_USERNAME=$LW_USERNAME" \
    --from-literal="LW_PASSWORD=$LW_PASSWORD" \
    --from-literal="LW_MAVEN_REPO_URL=$LW_MAVEN_REPO_URL" \
    ${LW_OSV_BASE_URL:+--from-literal="LW_OSV_BASE_URL=$LW_OSV_BASE_URL"}
else
  log_skip "no Lightwell credentials, skipping lightwell-lightwell (fine on path B)"
fi

echo
log_info "done. Nothing was printed and nothing was written to git"
