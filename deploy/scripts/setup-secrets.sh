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


# ---------------------------------------------------------------------------
# Trusted Profile Analyzer (ADR-0013). Two modes, decided by secrets.env:
#   TPA_URL set    an external instance, lightwell-tpa is filled from the four
#                  TPA_* values (same result as scripts/push-secrets.sh tpa)
#   TPA_URL empty  the instance this bootstrap installs (platform.tpa): the
#                  credentials it needs are generated here, never in git
# TPA_IN_CLUSTER=false skips both.
# ---------------------------------------------------------------------------
TPA_NS="${TPA_NS:-trusted-profile-analyzer}"
KC_NS="${KC_NS:-keycloak}"

# Created once. Rotating a generated value here would desynchronise it from the
# realm that already imported it, so an existing Secret is left alone.
random_secret() {
  local ns="$1" name="$2"; shift 2
  if oc get secret "$name" -n "$ns" >/dev/null 2>&1; then
    log_skip "secret $name in $ns exists, left as is"
    return
  fi
  local args=() key
  for key in "$@"; do
    args+=(--from-literal="$key=$(openssl rand -base64 24 | tr -d '/+=\n')")
  done
  oc create secret generic "$name" -n "$ns" "${args[@]}" >/dev/null
  log_ok "$name in $ns (generated)"
}

ensure_namespace() {
  oc get namespace "$1" >/dev/null 2>&1 || oc create namespace "$1" >/dev/null
}

if [[ "${TPA_IN_CLUSTER:-true}" == "false" ]]; then
  log_skip "TPA_IN_CLUSTER=false, skipping the Trusted Profile Analyzer credentials"
elif [[ -n "${TPA_URL:-}" ]]; then
  apply_secret lightwell-tpa \
    --from-literal="TPA_URL=$TPA_URL" \
    --from-literal="TPA_TOKEN_URL=${TPA_TOKEN_URL:?TPA_TOKEN_URL is needed with TPA_URL}" \
    --from-literal="TPA_CLIENT_ID=${TPA_CLIENT_ID:?TPA_CLIENT_ID is needed with TPA_URL}" \
    --from-literal="TPA_CLIENT_SECRET=${TPA_CLIENT_SECRET:?TPA_CLIENT_SECRET is needed with TPA_URL}"
else
  log_step "Trusted Profile Analyzer credentials (in-cluster instance)"
  ensure_namespace "$TPA_NS"

  # The database role and password the operator jobs and the server use.
  if ! oc get secret rhtpa-db -n "$TPA_NS" >/dev/null 2>&1; then
    oc create secret generic rhtpa-db -n "$TPA_NS" \
      --from-literal=username=trustify \
      --from-literal=database=trustify \
      --from-literal="password=$(openssl rand -base64 24 | tr -d '/+=\n')" \
      --from-literal="postgres-password=$(openssl rand -base64 24 | tr -d '/+=\n')" >/dev/null
    log_ok "rhtpa-db in $TPA_NS (generated)"
  else
    log_skip "secret rhtpa-db in $TPA_NS exists, left as is"
  fi

  # Lightwell OSV importers. The keys have to be exactly these names, each one
  # becomes a file under /run/secrets/rhtpa-rhlw-creds.
  if [[ -n "${LW_USERNAME:-}" && -n "${LW_PASSWORD:-}" ]]; then
    oc create secret generic rhtpa-rhlw-creds -n "$TPA_NS" \
      --from-literal="RH_LW_USERNAME=$LW_USERNAME" \
      --from-literal="RH_LW_PASSWORD=$LW_PASSWORD" \
      --dry-run=client -o yaml | oc apply -f - >/dev/null
    log_ok "rhtpa-rhlw-creds in $TPA_NS"
  else
    # The instance mounts this Secret, so it has to exist for the pods to start.
    # Empty values start the server and make the importers fail to authenticate.
    oc get secret rhtpa-rhlw-creds -n "$TPA_NS" >/dev/null 2>&1 \
      || oc create secret generic rhtpa-rhlw-creds -n "$TPA_NS" \
           --from-literal=RH_LW_USERNAME= --from-literal=RH_LW_PASSWORD= >/dev/null
    log_skip "no LW_USERNAME/LW_PASSWORD: TPA starts without Lightwell OSV records (path A needs them)"
  fi

  # The realm import lives in the Keycloak namespace, so the client secret and
  # the console password are needed there too, with the same value.
  if oc get namespace "$KC_NS" >/dev/null 2>&1; then
    CLI_SECRET="$(oc get secret oidc-cli -n "$TPA_NS" -o jsonpath='{.data.client-secret}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    [[ -n "$CLI_SECRET" ]] || CLI_SECRET="$(oc get secret oidc-cli -n "$KC_NS" -o jsonpath='{.data.client-secret}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    [[ -n "$CLI_SECRET" ]] || CLI_SECRET="$(openssl rand -base64 24 | tr -d '/+=\n')"
    for ns in "$TPA_NS" "$KC_NS"; do
      oc create secret generic oidc-cli -n "$ns" \
        --from-literal="client-secret=$CLI_SECRET" \
        --dry-run=client -o yaml | oc apply -f - >/dev/null
      log_ok "oidc-cli in $ns"
    done
    random_secret "$KC_NS" rhtpa-users admin-password

    # Sign in with the cluster's OpenShift users (platform.tpa.openshiftLogin).
    # Three things, all outside git: the client secret, the OAuthClient that
    # holds it (a cluster object, its secret is a plain field), and the CA of
    # the API in the Keycloak's truststore so Keycloak can read the discovery
    # document. The last one restarts the Keycloak, which is not ours.
    if [[ "${TPA_OPENSHIFT_LOGIN:-true}" != "false" ]]; then
      random_secret "$KC_NS" oidc-openshift client-secret
      OC_SECRET="$(oc get secret oidc-openshift -n "$KC_NS" -o jsonpath='{.data.client-secret}' | base64 -d)"
      KC_PUBLIC="${TPA_KEYCLOAK_HOST:-$(oc get keycloak -n "$KC_NS" -o jsonpath='{.items[0].spec.hostname.hostname}' 2>/dev/null || true)}"
      if [[ -n "$KC_PUBLIC" ]]; then
        oc apply -f - >/dev/null <<EOF_OAUTH
apiVersion: oauth.openshift.io/v1
kind: OAuthClient
metadata:
  name: tpa-keycloak
grantMethod: auto
secret: "$OC_SECRET"
redirectURIs:
  - https://$KC_PUBLIC/realms/trustify/broker/openshift/endpoint
EOF_OAUTH
        log_ok "OAuthClient tpa-keycloak"
      else
        log_skip "no Keycloak host, OAuthClient tpa-keycloak not created"
      fi

      KC_NAME="$(oc get keycloak -n "$KC_NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
      API_CA="$(oc get configmap kube-apiserver-server-ca -n openshift-config-managed \
                  -o jsonpath='{.data.ca-bundle\.crt}' 2>/dev/null || true)"
      if [[ -n "$KC_NAME" && -n "$API_CA" ]]; then
        oc create secret generic openshift-api-ca -n "$KC_NS" --from-literal="openshift-api-ca.crt=$API_CA" \
          --dry-run=client -o yaml | oc apply -f - >/dev/null
        if [[ "$(oc get keycloak "$KC_NAME" -n "$KC_NS" -o jsonpath='{.spec.truststores.openshift-api.secret.name}' 2>/dev/null)" == "openshift-api-ca" ]]; then
          log_skip "Keycloak $KC_NAME already trusts the OpenShift API CA"
        else
          oc patch keycloak "$KC_NAME" -n "$KC_NS" --type merge \
            -p '{"spec":{"truststores":{"openshift-api":{"secret":{"name":"openshift-api-ca"}}}}}' >/dev/null
          log_ok "Keycloak $KC_NAME trusts the OpenShift API CA (it restarts)"
        fi
      else
        log_skip "no Keycloak CR or no API CA bundle: OpenShift login will not work"
      fi
    else
      log_skip "TPA_OPENSHIFT_LOGIN=false, skipping the OpenShift login for TPA"
    fi

    # What the pipeline reads. The route host is fixed by the operator
    # (server<appDomain>), the token endpoint is the Keycloak's own host.
    DOMAIN="$(oc get ingresscontroller.operator.openshift.io default -n openshift-ingress-operator \
                -o jsonpath='{.status.domain}' 2>/dev/null || true)"
    KC_HOST="${TPA_KEYCLOAK_HOST:-$(oc get keycloak -n "$KC_NS" -o jsonpath='{.items[0].spec.hostname.hostname}' 2>/dev/null || true)}"
    if [[ -n "$DOMAIN" && -n "$KC_HOST" ]]; then
      apply_secret lightwell-tpa \
        --from-literal="TPA_URL=https://server-trusted-profile-analyzer.$DOMAIN" \
        --from-literal="TPA_TOKEN_URL=https://$KC_HOST/realms/trustify/protocol/openid-connect/token" \
        --from-literal="TPA_CLIENT_ID=cli" \
        --from-literal="TPA_CLIENT_SECRET=$CLI_SECRET"
    else
      log_skip "could not find the ingress domain or the Keycloak host: set TPA_KEYCLOAK_HOST and run again to create lightwell-tpa"
    fi
  else
    log_skip "no namespace $KC_NS (the cluster Keycloak): oidc-cli and lightwell-tpa not created, set KC_NS or install Keycloak (ADR-0013)"
  fi
fi
echo
log_info "done. Nothing was printed and nothing was written to git"
