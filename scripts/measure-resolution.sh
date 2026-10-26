#!/usr/bin/env bash
# measure-resolution.sh — how long a cold dependency resolve takes, and how
# many requests it makes to each repository.
#
# The first run against an application spent 37 of its 48 minutes in
# `mvn dependency:tree`. Storage and bandwidth were measured and are not the
# cause: the repositories in settings.xml are queried before Central for
# every artifact, and most artifacts are in Central.
#
# This times a cold resolve and counts the requests per repository, so a
# proposed change to settings.xml can be argued from numbers rather than
# from the shape of the configuration.
#
# Usage:
#   measure-resolution.sh <label> [<settings.xml>]
#
# Writes .agent-status/resolution-<label>.json and leaves the full Maven log
# in .logs/resolution-<label>.log.
#
# Exit status: 0 if the resolve succeeded, 1 if it did not, 2 on bad input.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$SCRIPT_DIR/.."
readonly IMAGE="${IMAGE:-localhost/lightwell-agent-runtime:latest}"
readonly SECRETS="${SECRETS:-$REPO_ROOT/secrets/secrets.env}"
readonly BRANCH="${BRANCH:-feat/reachable-cve}"
readonly DNS="${DNS:-1.1.1.1}"

die() { printf 'measure-resolution: %s\n' "$*" >&2; exit 2; }
log() { printf 'measure-resolution: %s\n' "$*" >&2; }

LABEL="${1:-}"
SETTINGS_OVERRIDE="${2:-}"
[ -n "$LABEL" ] || die "a label is required"
[ -r "$SECRETS" ] || die "secrets file not readable: $SECRETS"
command -v podman >/dev/null || die "podman is not installed"

set -a
# shellcheck disable=SC1090
. "$SECRETS"
set +a
[ -n "${GITHUB_TOKEN:-}" ] && [ -n "${APP_REPO:-}" ] || die "GITHUB_TOKEN and APP_REPO must be set"
[ -n "${LW_USERNAME:-}" ] && [ -n "${LW_PASSWORD:-}" ] || die "Lightwell credentials must be set"

work="$REPO_ROOT/.measure/$LABEL"
# Scoped to this measurement's own directory. Chowning the whole .measure
# tree pulls the cache out from under any other measurement running at the
# same time, and Maven then dies with a permission error that reads like a
# repository problem — which cost a wrong conclusion once.
reclaim() { podman unshare chown -R 0:0 "$work" 2>/dev/null || true; }
[ -d "$work" ] && reclaim
rm -rf "$work"
mkdir -p "$work/cache" "$REPO_ROOT/.logs" "$REPO_ROOT/.agent-status"

# shellcheck disable=SC2016
readonly HELPER='!f() { echo username=x-access-token; echo "password=${GITHUB_TOKEN}"; }; f'
git -c credential.helper= -c credential.helper="$HELPER" \
    clone --quiet --branch "$BRANCH" "https://github.com/$APP_REPO" "$work/repo" \
  || die "cannot clone $APP_REPO at $BRANCH"

if [ -n "$SETTINGS_OVERRIDE" ]; then
  [ -r "$SETTINGS_OVERRIDE" ] || die "settings file not readable: $SETTINGS_OVERRIDE"
  cp "$SETTINGS_OVERRIDE" "$work/repo/settings.xml"
  log "using $SETTINGS_OVERRIDE"
else
  log "using the repository's own settings.xml"
fi

readonly LOG="$REPO_ROOT/.logs/resolution-$LABEL.log"
log "cold resolve starting — this is the slow one, by design"
started="$(date +%s)"

# The cache is empty and local to this measurement, so nothing from an
# earlier run can make this one look faster than it is.
podman run --rm --user 61000:0 \
  -e LW_USERNAME -e LW_PASSWORD -e LW_MAVEN_REPO_URL \
  --dns "$DNS" \
  -v "$work/repo:/project:Z,U" \
  -v "$work/cache:/home/claude-agent/.m2:Z,U" \
  --entrypoint mvn \
  "$IMAGE" -f /project/pom.xml -s /project/settings.xml -B dependency:tree \
  >"$LOG" 2>&1
status=$?
finished="$(date +%s)"
reclaim

elapsed=$(( finished - started ))
log "finished in ${elapsed}s (exit $status)"

python3 -I - "$LOG" "$LABEL" "$elapsed" "$status" \
  "$REPO_ROOT/.agent-status/resolution-$LABEL.json" <<'PY'
import collections, json, re, sys

log_path, label, elapsed, status, out_path = sys.argv[1:6]
text = open(log_path, encoding="utf-8", errors="replace").read()

# "Downloading from <repo>: <url>" is one request. "Downloaded from <repo>"
# is one that returned something, so the difference is the lookups that
# found nothing — the cost this measurement exists to expose.
asked = collections.Counter(re.findall(r"Downloading from ([\w.-]+):", text))
got = collections.Counter(re.findall(r"Downloaded from ([\w.-]+):", text))

repos = sorted(set(asked) | set(got))
per_repo = {
    r: {"requests": asked.get(r, 0), "hits": got.get(r, 0),
        "misses": asked.get(r, 0) - got.get(r, 0)}
    for r in repos
}
summary = {
    "label": label,
    "seconds": int(elapsed),
    "exit": int(status),
    "total_requests": sum(asked.values()),
    "total_hits": sum(got.values()),
    "total_misses": sum(asked.values()) - sum(got.values()),
    "per_repository": per_repo,
}
json.dump(summary, open(out_path, "w"), indent=2)

print(f"\n  {label}: {elapsed}s, {summary['total_requests']} requests, "
      f"{summary['total_misses']} of them found nothing")
for r in repos:
    d = per_repo[r]
    print(f"    {r:28s} {d['requests']:5d} requests  {d['hits']:5d} hits  {d['misses']:5d} misses")
PY

[ "$status" -eq 0 ]
