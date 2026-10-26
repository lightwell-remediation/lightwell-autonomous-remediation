#!/usr/bin/env bash
# verify-backport-resolves.sh — can Maven still find a Lightwell backport?
#
# The cold-resolve measurement shows that putting Central first removes most
# of the lookups, but it was run against a POM whose dependencies are all in
# Central, so it never needed Lightwell at all. It proves the speedup and
# proves nothing about the risk.
#
# The risk is this: a backport carries a version Central does not have
# (LW_REMEDIATED_VERSION in secrets.env). If Central were somehow to answer for it, the fixed
# artifact would be shadowed by whatever Central returned — which on a
# remediation pipeline is the worst possible failure, a vulnerable jar that
# looks remediated. This resolves the backport explicitly under each
# settings file and reports where it came from.
#
# Usage: verify-backport-resolves.sh [<group:artifact:version>]
#   default: org.apache.cxf:cxf-rt-rs-security-oauth2:$LW_REMEDIATED_VERSION
#
# Exit status: 0 if the backport resolves under every settings file tried.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$SCRIPT_DIR/.."
readonly IMAGE="${IMAGE:-localhost/lightwell-agent-runtime:latest}"
readonly SECRETS="${SECRETS:-$REPO_ROOT/secrets/secrets.env}"
readonly DNS="${DNS:-1.1.1.1}"

die() { printf 'verify-backport: %s\n' "$*" >&2; exit 2; }

[ -r "$SECRETS" ] || die "secrets file not readable: $SECRETS"
command -v podman >/dev/null || die "podman is not installed"
set -a
# shellcheck disable=SC1090
. "$SECRETS"
set +a

ARTIFACT="${1:-}"
if [ -z "$ARTIFACT" ]; then
  [ -n "${LW_REMEDIATED_VERSION:-}" ] || die "pass <group:artifact:version> or set LW_REMEDIATED_VERSION in $SECRETS"
  ARTIFACT="org.apache.cxf:cxf-rt-rs-security-oauth2:$LW_REMEDIATED_VERSION"
fi
readonly ARTIFACT

# Scoped per config below, not over the whole .measure tree: a broad chown
# breaks any measurement running concurrently, with an error that looks like
# a repository failure rather than a permissions one.
reclaim() { podman unshare chown -R 0:0 "$1" 2>/dev/null || true; }

problems=0
printf '\nresolving %s\n\n' "$ARTIFACT"

for config in current proposed; do
  settings="$REPO_ROOT/.measure/settings.$config.xml"
  [ -r "$settings" ] || { printf '  %-9s no settings file at %s\n' "$config" "$settings"; problems=1; continue; }

  cache="$REPO_ROOT/.measure/verify-$config"
  [ -d "$cache" ] && reclaim "$cache"
  rm -rf "$cache"; mkdir -p "$cache"

  log="$REPO_ROOT/.logs/verify-backport-$config.log"
  mkdir -p "$REPO_ROOT/.logs"

  podman run --rm --user 61000:0 \
    -e LW_USERNAME -e LW_PASSWORD -e LW_MAVEN_REPO_URL --dns "$DNS" \
    -v "$settings:/s.xml:ro,Z" \
    -v "$cache:/home/claude-agent/.m2:Z,U" \
    --entrypoint mvn "$IMAGE" \
    -s /s.xml -B dependency:get -Dartifact="$ARTIFACT" \
    >"$log" 2>&1
  status=$?
  reclaim "$cache"

  if [ "$status" -eq 0 ]; then
    # Which repository actually served it, not merely which were asked.
    from="$(grep -oE 'Downloaded from [a-z-]+' "$log" | sort -u | sed 's/Downloaded from //' | tr '\n' ' ')"
    printf '  %-9s resolves — served by: %s\n' "$config" "${from:-already present}"
  else
    printf '  %-9s DOES NOT RESOLVE (see %s)\n' "$config" "$log"
    problems=1
  fi

  asked="$(grep -cE 'Downloading from ' "$log" 2>/dev/null || echo 0)"
  printf '            %s request(s) made\n' "$asked"
done

printf '\n'
[ "$problems" -eq 0 ]
