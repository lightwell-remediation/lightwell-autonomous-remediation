#!/usr/bin/env bash
# push-secrets.sh — put the credentials the Pipeline needs into the namespace.
#
# Reads secrets/secrets.env, which is gitignored and the only place real
# values live. The key names in each Secret match the environment variables
# the runtime reads, so the Tasks consume them with envFrom and nothing maps
# names anywhere.
#
#   lightwell-maas       MAAS_BASE_URL, MAAS_API_KEY, MAAS_MODEL, MAAS_SMALL_MODEL
#   lightwell-github     APP_REPO, GITHUB_TOKEN, GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL
#   lightwell-lightwell  LW_USERNAME, LW_PASSWORD, LW_MAVEN_REPO_URL,
#                        LW_OSV_BASE_URL (optional — skipped when all are empty)
#   lightwell-tpa        TPA_URL, TPA_TOKEN_URL, TPA_CLIENT_ID, TPA_CLIENT_SECRET
#                        (optional — skipped when all four are empty)
#
# lightwell-lightwell is optional because an application on Maven Central
# alone does not need it. For one that builds against the Lightwell
# repository it is the easiest to forget and the worst to debug: without it
# Maven cannot resolve the Lightwell rebuild and `verify` fails with a
# dependency resolution error that reads like a bad patch.
#
# Values are never printed. Only which keys were set.
#
# Usage:
#   push-secrets.sh              every secret
#   push-secrets.sh lightwell    one of them, by its suffix
#
# Exit status:
#   0  the named secrets exist in the namespace with the expected keys
#   1  a value was missing from secrets.env
#   2  configuration error

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$SCRIPT_DIR/.."
readonly NAMESPACE="${NAMESPACE:-lightwell-agents}"
readonly SECRETS="${SECRETS:-$REPO_ROOT/secrets/secrets.env}"

die() { printf 'push-secrets: %s\n' "$*" >&2; exit 2; }
log() { printf 'push-secrets: %s\n' "$*" >&2; }

command -v oc >/dev/null || die "oc is not installed"
oc whoami >/dev/null 2>&1 || die "not logged in to a cluster"
[ -r "$SECRETS" ] || die "secrets file not readable: $SECRETS"

# Sourced rather than parsed: the file quotes values whose tokens contain
# shell metacharacters (docs/agent-runtime.md — Quoted secrets).
set -a
# shellcheck disable=SC1090
. "$SECRETS"
set +a

# <suffix>|<variable names>. A leading `?` marks one the runtime can do
# without — MAAS_SMALL_MODEL falls back to MAAS_MODEL — so an absent value
# does not refuse the whole secret and leave the namespace half configured.
# A leading `?` on the suffix marks a whole Secret the pipeline can do
# without: skipped when every value is empty, refused when only some are.
readonly SECRET_SETS=(
  "maas|MAAS_BASE_URL MAAS_API_KEY MAAS_MODEL ?MAAS_SMALL_MODEL"
  "github|APP_REPO GITHUB_TOKEN GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL"
  "?lightwell|LW_USERNAME LW_PASSWORD LW_MAVEN_REPO_URL ?LW_OSV_BASE_URL"
  "?tpa|TPA_URL TPA_TOKEN_URL TPA_CLIENT_ID TPA_CLIENT_SECRET"
)

wanted=("$@")
should_run() {
  [ "${#wanted[@]}" -eq 0 ] && return 0
  local w
  for w in "${wanted[@]}"; do [ "$w" = "$1" ] && return 0; done
  return 1
}

problems=0
for row in "${SECRET_SETS[@]}"; do
  suffix="${row%%|*}"
  variables="${row#*|}"
  optional_set=""
  [ "${suffix#\?}" != "$suffix" ] && { optional_set=yes; suffix="${suffix#\?}"; }
  should_run "$suffix" || continue

  name="lightwell-$suffix"
  args=()
  missing=()
  for variable in $variables; do
    optional=""
    [ "${variable#\?}" != "$variable" ] && { optional=yes; variable="${variable#\?}"; }
    value="${!variable:-}"
    if [ -z "$value" ]; then
      [ -n "$optional" ] || missing+=("$variable")
      continue
    fi
    args+=(--from-literal="$variable=$value")
  done

  if [ -n "$optional_set" ] && [ "${#args[@]}" -eq 0 ]; then
    log "$name: skipped — optional, and nothing set in secrets.env"
    continue
  fi

  if [ "${#missing[@]}" -gt 0 ]; then
    log "$name: not set — missing from secrets.env: ${missing[*]}"
    problems=1
    continue
  fi

  # Merged, not applied. `oc apply` replaces `data` wholesale, so a run
  # without a value for some key silently deletes it from a working secret —
  # which is how MAAS_SMALL_MODEL disappeared from the cluster once. A merge
  # patch sets what this file knows and leaves everything else alone.
  if oc get secret "$name" -n "$NAMESPACE" >/dev/null 2>&1; then
    # Built by python so the values are JSON-escaped correctly — tokens here
    # contain characters a hand-rolled template would mangle. Passed on
    # stdin, never on a command line, so nothing lands in a process list.
    patch="$(printf '%s\n' "${args[@]}" | python3 -I -c '
import json, sys
data = {}
for line in sys.stdin.read().splitlines():
    pair = line.split("=", 2)[1:]
    if len(pair) == 2:
        data[pair[0]] = pair[1]
print(json.dumps({"stringData": data}))
')"
    oc patch secret "$name" -n "$NAMESPACE" --type=merge --patch-file=/dev/stdin \
      <<<"$patch" >/dev/null 2>&1
    applied=$?
  else
    oc create secret generic "$name" -n "$NAMESPACE" "${args[@]}" >/dev/null 2>&1
    applied=$?
  fi

  if [ "$applied" -eq 0 ]; then
    keys="$(oc get secret "$name" -n "$NAMESPACE" \
      -o go-template='{{range $k, $v := .data}}{{$k}} {{end}}' 2>/dev/null)"
    printf '  ok    %s — %s\n' "$name" "$keys" >&2
  else
    printf '  FAIL  %s could not be applied\n' "$name" >&2
    problems=1
  fi
done

[ "$problems" -eq 0 ]
