#!/usr/bin/env bash
# provision-app-repo.sh — one private application repository per deployment,
# and a GitHub token that can reach that repository and nothing else.
#
# The agent clones the application, pushes a branch and opens a pull request,
# so it must never run against the template, nor against a repository that
# still holds an earlier run's remediate/* branch (a full clone would hand the
# next run the answer — docs/replicate.md step 1). This script:
#
#   1. creates <owner>/<template>-<name> as a PRIVATE copy of the template
#   2. adds that repository to the GitHub App installation
#   3. mints an installation token scoped to that repository only (valid 1 h)
#   4. writes APP_REPO and GITHUB_TOKEN into secrets/secrets.env
#   5. updates the lightwell-github Secret in the cluster
#   6. checks the token reaches the repository and nothing else
#
# GitHub cannot create fine-grained PATs through an API, so the token comes
# from a GitHub App you create once (skill provision-app-repo). Its private key
# stays outside the repository; credentials are never printed.
#
# Usage:
#   provision-app-repo.sh <name>                 create (or reuse) the repo + token
#   provision-app-repo.sh <name> --template T    another template (default
#                                                lw-apache-cxf-demo-template)
#   provision-app-repo.sh --refresh              new token for the APP_REPO in
#                                                secrets.env (the token lasts 1 h)
#   provision-app-repo.sh <name> --teardown --yes   delete the deployment's repo
#   --no-push                                    skip the cluster Secret update
#
# Environment: GH_APP_ENV overrides secrets/github-app.env.
#
# Exit status:
#   0  done and verified
#   1  verification failed
#   2  configuration or usage error

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$SCRIPT_DIR/.."
readonly APP_ENV="${GH_APP_ENV:-$REPO_ROOT/secrets/github-app.env}"
readonly SECRETS="${SECRETS:-$REPO_ROOT/secrets/secrets.env}"
readonly API="https://api.github.com"

die() { printf 'provision-app-repo: %s\n' "$*" >&2; exit 2; }
log() { printf 'provision-app-repo: %s\n' "$*" >&2; }

name=""
template_name="lw-apache-cxf-demo-template"
mode="provision"
push=1
yes=0
while [ $# -gt 0 ]; do
  case "$1" in
    --template) template_name="${2:?--template needs a value}"; shift 2 ;;
    --refresh)  mode="refresh"; shift ;;
    --teardown) mode="teardown"; shift ;;
    --no-push)  push=0; shift ;;
    --yes)      yes=1; shift ;;
    -h|--help)  sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)         die "unknown option: $1" ;;
    *)          [ -z "$name" ] || die "one name only"; name="$1"; shift ;;
  esac
done

for tool in gh curl openssl python3; do
  command -v "$tool" >/dev/null || die "$tool is not installed"
done
[ -r "$APP_ENV" ] || die "no $APP_ENV — create the GitHub App first (skill provision-app-repo, step 1)"

# Sourced like secrets.env: values may be quoted.
set -a
# shellcheck disable=SC1090
. "$APP_ENV"
set +a
for variable in GH_APP_ID GH_APP_INSTALLATION_ID GH_APP_PRIVATE_KEY_FILE GH_APP_OWNER; do
  value="${!variable:-}"
  { [ -n "$value" ] && [ "$value" != "CHANGE_ME" ]; } || die "$variable is not set in $APP_ENV"
done
[ -r "$GH_APP_PRIVATE_KEY_FILE" ] || die "private key not readable: $GH_APP_PRIVATE_KEY_FILE"
[ "$(stat -c %a "$GH_APP_PRIVATE_KEY_FILE")" = "600" ] \
  || die "private key must be mode 600: chmod 600 $GH_APP_PRIVATE_KEY_FILE"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# App JWT, RS256, valid 10 minutes at most (docs.github.com — Generating a JWT).
app_jwt() {
  local now header payload signature
  now="$(date +%s)"
  header="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
  payload="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$GH_APP_ID" | b64url)"
  signature="$(printf '%s.%s' "$header" "$payload" \
    | openssl dgst -sha256 -sign "$GH_APP_PRIVATE_KEY_FILE" | b64url)" || return 1
  printf '%s.%s.%s' "$header" "$payload" "$signature"
}

# curl with the credential on stdin (-K -), never on a command line.
api_call() { # <token> <method> <path> [json body]
  local token="$1" method="$2" path="$3" body="${4:-}"
  local -a extra=()
  [ -n "$body" ] && extra=(--data-binary "$body")
  printf 'header = "Authorization: Bearer %s"\n' "$token" \
    | curl -sS -K - -X "$method" -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' -w '\n%{http_code}' "${extra[@]}" "$API$path"
}

json_get() { python3 -I -c 'import json,sys; d=json.loads(sys.stdin.read() or "{}"); print(d.get(sys.argv[1], ""))' "$1"; }

# Rewrites KEY=value lines in secrets.env in place, mode preserved, values
# read from the environment so they never reach a command line.
set_secret_vars() { # VAR...
  [ -f "$SECRETS" ] || cp "$REPO_ROOT/secrets/secrets.template.env" "$SECRETS"
  chmod 600 "$SECRETS"
  python3 -I - "$SECRETS" "$@" <<'PY'
import os, re, sys
path, names = sys.argv[1], sys.argv[2:]
lines = open(path).read().splitlines()
for n in names:
    new = f"{n}={os.environ[n]}"
    for i, l in enumerate(lines):
        if re.match(rf"^{n}=", l):
            lines[i] = new
            break
    else:
        lines.append(new)
tmp = path + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write("\n".join(lines) + "\n")
os.replace(tmp, path)
PY
}

repo_from_secrets() {
  [ -r "$SECRETS" ] || die "no $SECRETS"
  # shellcheck disable=SC1090
  ( set -a; . "$SECRETS"; set +a; printf '%s' "${APP_REPO:-}" )
}

# ---- resolve the repository ------------------------------------------------
case "$mode" in
  refresh)
    app_repo="$(repo_from_secrets)"
    { [ -n "$app_repo" ] && [ "$app_repo" != "CHANGE_ME" ]; } || die "APP_REPO is not set in secrets.env"
    ;;
  *)
    [ -n "$name" ] || die "usage: provision-app-repo.sh <name> [--template T] | --refresh | <name> --teardown --yes"
    [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || die "name must be lowercase letters, digits and dashes"
    app_repo="$GH_APP_OWNER/${template_name%-template}-$name"
    ;;
esac
log "repository: $app_repo"

# ---- teardown --------------------------------------------------------------
if [ "$mode" = "teardown" ]; then
  [ "$yes" -eq 1 ] || die "teardown deletes $app_repo for good: add --yes"
  [ "$app_repo" != "$GH_APP_OWNER/$template_name" ] || die "refusing to delete the template"
  if gh repo delete "$app_repo" --yes >/dev/null 2>&1; then
    log "deleted $app_repo"
    exit 0
  fi
  die "could not delete $app_repo — gh needs the delete_repo scope: gh auth refresh -h github.com -s delete_repo"
fi

# ---- 1. create the private copy -------------------------------------------
if [ "$mode" = "provision" ]; then
  if gh repo view "$app_repo" >/dev/null 2>&1; then
    log "repository exists, reusing it"
  else
    gh repo create "$app_repo" --private --template "$GH_APP_OWNER/$template_name" >/dev/null \
      || die "could not create $app_repo from $GH_APP_OWNER/$template_name"
    log "created $app_repo (private, from $template_name)"
  fi
  [ "$(gh repo view "$app_repo" --json isPrivate --jq .isPrivate)" = "true" ] \
    || die "$app_repo is not private — a public copy would publish every pull request"
fi

repo_id=""
for _ in $(seq 1 15); do   # a repository created from a template appears with a delay
  repo_id="$(gh api "repos/$app_repo" --jq .id 2>/dev/null)" && [ -n "$repo_id" ] && break
  sleep 2
done
[ -n "$repo_id" ] || die "repository $app_repo is not readable"

# ---- 2. add it to the App installation ------------------------------------
if [ "$mode" = "provision" ]; then
  if gh api -X PUT "user/installations/$GH_APP_INSTALLATION_ID/repositories/$repo_id" >/dev/null 2>&1; then
    log "added to installation $GH_APP_INSTALLATION_ID"
  else
    log "could not add it to the installation with the gh login (fine when the App is installed on all repositories of $GH_APP_OWNER)"
  fi
fi

# ---- 3. installation token scoped to this repository ----------------------
jwt="$(app_jwt)" || die "could not sign the App JWT — is the private key an RSA PEM?"
response="$(api_call "$jwt" POST "/app/installations/$GH_APP_INSTALLATION_ID/access_tokens" \
  "{\"repository_ids\":[$repo_id],\"permissions\":{\"contents\":\"write\",\"pull_requests\":\"write\",\"metadata\":\"read\"}}")"
unset jwt
code="${response##*$'\n'}"
body="${response%$'\n'*}"
[ "$code" = "201" ] || die "installation token refused (HTTP $code): $(printf '%s' "$body" | json_get message)"
GITHUB_TOKEN="$(printf '%s' "$body" | json_get token)"
expires_at="$(printf '%s' "$body" | json_get expires_at)"
granted="$(printf '%s' "$body" | python3 -I -c 'import json,sys; p=json.loads(sys.stdin.read()).get("permissions",{}); print(p.get("contents",""), p.get("pull_requests",""))')"
read -r granted_contents granted_pulls <<<"$granted"
[ -n "$GITHUB_TOKEN" ] || die "no token in the response"
log "installation token minted, expires $expires_at"

# ---- 4. secrets.env --------------------------------------------------------
export GITHUB_TOKEN APP_REPO="$app_repo"
set_secret_vars GITHUB_TOKEN APP_REPO
log "secrets.env updated (APP_REPO, GITHUB_TOKEN)"

# ---- 5. cluster Secret -----------------------------------------------------
if [ "$push" -eq 1 ]; then
  if oc whoami >/dev/null 2>&1; then
    "$SCRIPT_DIR/push-secrets.sh" github || die "push-secrets.sh failed"
  else
    log "not logged in to a cluster: run scripts/push-secrets.sh github after login"
  fi
fi

# ---- 6. verify -------------------------------------------------------------
failures=0
check() { # <label> <ok|fail>
  if [ "$2" = ok ]; then printf '  ok    %s\n' "$1" >&2; else printf '  FAIL  %s\n' "$1" >&2; failures=1; fi
}

# An installation token's repository response carries no `permissions` field,
# so what it may do is read from what GitHub granted when it was minted.
response="$(api_call "$GITHUB_TOKEN" GET "/repos/$app_repo")"
code="${response##*$'\n'}"
if [ "$code" = "200" ] && [ "$granted_contents" = "write" ] && [ "$granted_pulls" = "write" ]; then
  check "token reads $app_repo and was granted contents + pull requests write" ok
else
  check "token reads $app_repo and was granted contents + pull requests write (HTTP $code, contents=$granted_contents, pulls=$granted_pulls)" fail
fi

response="$(api_call "$GITHUB_TOKEN" GET "/repos/$app_repo/branches?per_page=100")"
branches="${response%$'\n'*}"
if printf '%s' "$branches" | grep -q '"name": *"remediate/'; then
  check "no remediate/* branch left from an earlier run" fail
else
  check "no remediate/* branch left from an earlier run" ok
fi

# The scope check that matters: another private repository of the owner must
# be invisible to this token (404), not merely unwritable.
other="$(env -u GITHUB_TOKEN -u GH_TOKEN gh repo list "$GH_APP_OWNER" --visibility private --limit 50 --json nameWithOwner --jq '.[].nameWithOwner' 2>/dev/null \
  | grep -vx "$app_repo" | head -1)"
if [ -n "$other" ]; then
  response="$(api_call "$GITHUB_TOKEN" GET "/repos/$other")"
  code="${response##*$'\n'}"
  if [ "$code" = "404" ]; then check "token cannot see another private repository ($other)" ok; else check "token cannot see another private repository ($other, HTTP $code)" fail; fi
else
  log "no other private repository to check the scope against"
fi
response="$(api_call "$GITHUB_TOKEN" GET "/repos/$GH_APP_OWNER/$template_name")"
body="${response%$'\n'*}"
if printf '%s' "$body" | grep -q '"push": *true'; then check "token cannot write to the template" fail; else check "token cannot write to the template" ok; fi

unset GITHUB_TOKEN
exit "$failures"
