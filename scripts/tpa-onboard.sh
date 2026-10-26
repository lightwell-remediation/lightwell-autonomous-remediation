#!/usr/bin/env bash
# tpa-onboard.sh — register an application's current inventory in Trusted
# Profile Analyzer, so a remediation has something to be compared against.
#
# Once per application, not once per run. The inventory on the default branch
# describes the application, not a remediation; uploading it on every run
# would fill TPA with identical copies. This is the first step of what
# onboarding an application would be, done by hand until there is one.
#
# The pipeline finds what this registers by its labels
# (agent-runtime/validate-sbom.sh): app=<owner/repo>, role=baseline, ref=<ref>.
#
# Usage:
#   tpa-onboard.sh [--app owner/repo] [--ref <branch>] [--file <sbom.json>] [--force]
#
#   --app    default: APP_REPO from secrets.env
#   --ref    default: the repository's default branch
#   --file   upload this file instead of fetching sbom.json from GitHub
#   --force  register again even if a baseline for app+ref already exists
#
# Reads secrets/secrets.env for TPA_* and GITHUB_TOKEN. Values are never printed.
#
# Exit status:
#   0  a baseline is registered (now or already)
#   1  TPA or GitHub refused
#   2  configuration error

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$SCRIPT_DIR/.."
readonly SECRETS="${SECRETS:-$REPO_ROOT/secrets/secrets.env}"
readonly TPA="$REPO_ROOT/agent-runtime/tpa.sh"

die() { printf 'tpa-onboard: %s\n' "$*" >&2; exit 2; }
log() { printf 'tpa-onboard: %s\n' "$*" >&2; }

[ -r "$SECRETS" ] || die "secrets file not readable: $SECRETS"
# Sourced rather than parsed: see docs/agent-runtime.md — Quoted secrets.
set -a
# shellcheck disable=SC1090
. "$SECRETS"
set +a

app="${APP_REPO:-}"
ref=""
file=""
force=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --app)   app="${2:-}"; shift 2 ;;
    --ref)   ref="${2:-}"; shift 2 ;;
    --file)  file="${2:-}"; shift 2 ;;
    --force) force=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$app" ] || die "no application — pass --app or set APP_REPO"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

github() {
  curl -sS --fail-with-body --max-time 60 \
    -H @<(printf 'Authorization: Bearer %s\n' "${GITHUB_TOKEN:?GITHUB_TOKEN is not set}") \
    -H 'X-GitHub-Api-Version: 2022-11-28' "$@"
}

if [ -z "$ref" ]; then
  ref="$(github "https://api.github.com/repos/$app" \
         | node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>process.stdout.write(JSON.parse(s).default_branch||""))')" \
    || { log "cannot read $app from GitHub"; exit 1; }
  [ -n "$ref" ] || { log "cannot tell $app's default branch"; exit 1; }
fi

if [ "$force" -eq 0 ] && existing="$("$TPA" find "app=$app" "role=baseline" "ref=$ref")"; then
  log "already registered: $existing"
  log "pass --force to register the current inventory again"
  exit 0
fi

if [ -z "$file" ]; then
  file="$tmp/sbom.json"
  log "fetching sbom.json from $app@$ref"
  github -H 'Accept: application/vnd.github.raw+json' \
    "https://api.github.com/repos/$app/contents/sbom.json?ref=$ref" >"$file" \
    || { log "$app has no sbom.json on $ref — nothing to register"; exit 1; }
fi
[ -r "$file" ] || die "no readable file at $file"

log "uploading as app=$app role=baseline ref=$ref"
"$TPA" upload "$file" "app=$app" "role=baseline" "ref=$ref" >"$tmp/ingest.json" || exit 1
id="$(node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).id))' "$tmp/ingest.json")"
log "registered $id — ${TPA_URL%/}/sboms/$id?sd%3AactiveTab=vulnerabilities"

# What TPA reports for it, so whoever onboards sees the vulnerability the demo
# remediates listed as affected before any run starts.
if "$TPA" advisories "$id" >"$tmp/advisories.json"; then
  node -e '
    const a = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const rows = new Set();
    for (const adv of a) for (const s of adv.status || [])
      if (s.status === "affected") rows.add(`  ${s.identifier}  (${adv.identifier})`);
    console.error(`tpa-onboard: ${rows.size} vulnerabilit${rows.size === 1 ? "y" : "ies"} affecting it`);
    for (const r of [...rows].sort()) console.error(r);
  ' "$tmp/advisories.json"
fi
