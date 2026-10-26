#!/usr/bin/env bash
# deliver-candidate.sh — run delivery alone, against a candidate it did not
# produce.
#
# Delivery is the only phase whose output a human reads, so it is the one
# worth iterating on — and re-running the whole sequence to look at a pull
# request body costs twelve minutes and a dollar. This assembles a candidate
# from a change that is already on GitHub plus recorded phase documents, and
# runs the deliver role against it: about a minute and a tenth of that.
#
# It is the arrangement pr-creation.spec.md already promises — "Delivery
# Consumes a Candidate It Did Not Produce" — so exercising it this way is
# also a test of that claim.
#
# It opens a real pull request on the application repository.
#
# Usage:
#   deliver-candidate.sh --from-pr <n> [--branch <base>] [--documents <dir>]
#
# Example:
#   deliver-candidate.sh --from-pr 10 --branch feat/reachable-cve
#
# Exit status:
#   0  a pull request was opened
#   1  delivery failed
#   2  configuration error

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$SCRIPT_DIR/.."
readonly SECRETS="${SECRETS:-$REPO_ROOT/secrets/secrets.env}"
readonly IMAGE="${IMAGE:-localhost/lightwell-agent-runtime:latest}"
readonly WORKSPACE="$REPO_ROOT/.deliver-candidate"

die() { printf 'deliver-candidate: %s\n' "$*" >&2; exit 2; }
log() { printf 'deliver-candidate: %s\n' "$*" >&2; }

FROM_PR=""
BASE="feat/reachable-cve"
DOCUMENTS="$REPO_ROOT/.workspace/out"
OSV="$REPO_ROOT/.fixtures/osv/CVE-2026-68079.json"
DNS="${DNS:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --from-pr)   FROM_PR="${2:?--from-pr needs a value}"; shift 2 ;;
    --branch)    BASE="${2:?--branch needs a value}"; shift 2 ;;
    --documents) DOCUMENTS="${2:?--documents needs a value}"; shift 2 ;;
    --osv)       OSV="${2:?--osv needs a value}"; shift 2 ;;
    --dns)       DNS="${2:?--dns needs a value}"; shift 2 ;;
    -h|--help)   sed -n '2,24p' "$0"; exit 0 ;;
    *)           die "unknown argument: $1" ;;
  esac
done

[ -n "$FROM_PR" ] || die "--from-pr <n> is required"
[ -r "$SECRETS" ] || die "secrets file not readable: $SECRETS"
# deliver takes the record as well as the documents: the pull request names
# the advisory, and that comes from the record rather than from the analysis.
[ -r "$OSV" ] || die "vulnerability record not readable: $OSV"
command -v podman >/dev/null || die "podman is not installed"

set -a
# shellcheck disable=SC1090
. "$SECRETS"
set +a
[ -n "${GITHUB_TOKEN:-}" ] && [ -n "${APP_REPO:-}" ] \
  || die "GITHUB_TOKEN and APP_REPO must be set"

for document in analysis.json patch.json verification.json; do
  [ -r "$DOCUMENTS/$document" ] || die "no $document in $DOCUMENTS"
done

# Ownership flips to the container's mapped UID on a :U mount, so the
# previous run's workspace is not ours to delete until it is reclaimed.
reclaim() { podman unshare chown -R 0:0 "$WORKSPACE" 2>/dev/null || true; }
[ -d "$WORKSPACE" ] && reclaim
rm -rf "$WORKSPACE" || die "cannot clear $WORKSPACE"
mkdir -p "$WORKSPACE/out"

# The token goes through a credential helper reading the environment, never
# into the URL: a URL lands in .git/config, in the process list, and in any
# log that echoes the command.
# shellcheck disable=SC2016
readonly HELPER='!f() { echo username=x-access-token; echo "password=${GITHUB_TOKEN}"; }; f'

log "cloning $APP_REPO at $BASE"
git -c credential.helper= -c credential.helper="$HELPER" \
    clone --quiet --branch "$BASE" "https://github.com/$APP_REPO" "$WORKSPACE/repo" \
  || die "cannot clone $APP_REPO at $BASE"

log "taking the change from pull request #$FROM_PR as the candidate"
curl -fsS -H "Authorization: Bearer $GITHUB_TOKEN" \
     -H "Accept: application/vnd.github.v3.diff" \
     "https://api.github.com/repos/$APP_REPO/pulls/$FROM_PR" \
     -o "$WORKSPACE/candidate.diff" \
  || die "cannot fetch the diff of #$FROM_PR"

git -C "$WORKSPACE/repo" apply "$WORKSPACE/candidate.diff" \
  || die "the change from #$FROM_PR does not apply to $BASE"

changed="$(git -C "$WORKSPACE/repo" status --porcelain | wc -l)"
[ "$changed" -gt 0 ] || die "applying #$FROM_PR left nothing changed"
log "candidate: $changed file(s) changed"

cp "$DOCUMENTS"/analysis.json "$DOCUMENTS"/patch.json \
   "$DOCUMENTS"/verification.json "$WORKSPACE/out/" || die "cannot stage the documents"
# Optional, all of them: a run against an unreachable defect has no
# demonstration, a project that publishes no inventory has no sbom summary,
# and a run with no TPA configured has no verdict. Copying only what exists
# keeps the replay honest about which.
for optional in exploit.json sbom.json tpa.json; do
  [ -r "$DOCUMENTS/$optional" ] && cp "$DOCUMENTS/$optional" "$WORKSPACE/out/"
done
log "documents: $(cd "$WORKSPACE/out" && echo *)"

dns_args=()
[ -n "$DNS" ] && dns_args=(--dns "$DNS")

env_args=()
for name in MAAS_BASE_URL MAAS_API_KEY MAAS_MODEL MAAS_SMALL_MODEL \
            GITHUB_TOKEN APP_REPO GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL \
            LW_USERNAME LW_PASSWORD LW_MAVEN_REPO_URL MAX_TURNS; do
  [ -n "${!name:-}" ] && env_args+=(-e "$name")
done

# The prompts come from the working tree, not from the image, so a change to
# deliver.md can be tried without rebuilding anything.
log "running deliver (prompts from the working tree)"
podman run --rm --user 61000:0 \
  "${env_args[@]}" "${dns_args[@]}" \
  -e PROMPTS_DIR=/prompts \
  -v "$WORKSPACE:/workspace:Z,U" \
  -v "$REPO_ROOT/agent-runtime/prompts:/prompts:ro,Z" \
  -v "$(cd "$(dirname "$OSV")" && pwd):/osv:ro,Z" \
  "$IMAGE" --role deliver --no-clone --osv "/osv/$(basename "$OSV")"
status=$?
reclaim

if [ "$status" -ne 0 ]; then
  log "delivery failed"
  exit 1
fi

url="$(python3 -I -c "
import json
print(json.load(open('$WORKSPACE/out/delivery.json')).get('pull_request',''))
" 2>/dev/null)"
printf '\n%s\n' "${url:-no pull request recorded}"
