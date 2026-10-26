#!/usr/bin/env bash
# tpa.sh — the few Trusted Profile Analyzer calls this project makes, in one
# place, so onboarding an application and validating a remediated inventory
# talk to TPA the same way.
#
# Written against Trustify 3.1.0's own OpenAPI document (/openapi.json on the
# instance). The v3 paths are what that version serves; an older instance
# answering only under /api/v2 is not supported.
#
# Authentication is the OIDC client-credentials grant: a client id and secret
# issued for this purpose, never a person's login. The secret is sent on
# stdin, never on a command line, so it does not land in a process list.
#
# Usage:
#   tpa.sh upload <sbom.json> [key=value ...]   prints the ingest result
#   tpa.sh advisories <sbom-id>                 prints the advisories that apply
#   tpa.sh find <key=value> [...]               prints the newest SBOM whose
#                                               labels match every pair
#
# Environment:
#   TPA_URL            https://<tpa-host>, no trailing slash
#   TPA_TOKEN_URL      the realm's openid-connect token endpoint
#   TPA_CLIENT_ID
#   TPA_CLIENT_SECRET
#
# Exit status:
#   0  the call succeeded
#   1  TPA or the identity provider refused or did not answer
#   2  configuration error
#   3  find: nothing carries those labels

set -uo pipefail

readonly EXIT_CONFIG=2

die() { printf 'tpa: %s\n' "$*" >&2; exit "$EXIT_CONFIG"; }
fail() { printf 'tpa: %s\n' "$*" >&2; exit 1; }

for v in TPA_URL TPA_TOKEN_URL TPA_CLIENT_ID TPA_CLIENT_SECRET; do
  [ -n "${!v:-}" ] || die "$v is not set"
done
command -v curl >/dev/null || die "curl is not installed"
command -v node >/dev/null || die "node is not installed"

readonly BASE="${TPA_URL%/}"

urlencode() {
  node -e 'process.stdout.write(encodeURIComponent(process.argv[1]))' "$1"
}

# The application is named owner/repo by people and owner-repo by the
# cluster, where it is a label value (lightwell.dev/application, and the
# Pipeline's application param — scripts/run-remediation.sh). The `app`
# label is always stored and matched in the cluster's form, so an inventory
# onboarded by hand and one uploaded by a run meet on the same key: the first
# real run missed its baseline over exactly this.
normalize() {
  local key="${1%%=*}" value="${1#*=}"
  if [ "$key" = app ]; then
    value="$(printf '%s' "$value" | tr 'A-Z/' 'a-z-' | cut -c1-63)"
  fi
  printf '%s=%s' "$key" "$value"
}

token() {
  local response
  response="$(printf 'grant_type=client_credentials&client_id=%s&client_secret=%s' \
                "$(urlencode "$TPA_CLIENT_ID")" "$(urlencode "$TPA_CLIENT_SECRET")" \
              | curl -sS --max-time 30 -X POST "$TPA_TOKEN_URL" \
                  -H 'Content-Type: application/x-www-form-urlencoded' \
                  --data-binary @-)" \
    || fail "the identity provider did not answer at $TPA_TOKEN_URL"
  node -e '
    try {
      const t = JSON.parse(process.argv[1]).access_token;
      if (!t) process.exit(1);
      process.stdout.write(t);
    } catch { process.exit(1); }
  ' "$response" || fail "no access token — ${response:0:200}"
}

# The header goes through a file descriptor for the same reason the secret
# goes through stdin.
api() {
  local tok
  tok="$(token)" || exit 1
  curl -sS --fail-with-body -H @<(printf 'Authorization: Bearer %s\n' "$tok") "$@"
}

cmd="${1:-}"
shift || true

case "$cmd" in
  upload)
    file="${1:-}"
    shift || true
    [ -r "$file" ] || die "upload: no readable file at '${file}'"
    # cache=wait returns only once the document is in the analysis graph, so
    # the advisory query that follows describes this inventory and not an
    # empty one still being ingested. Capitalised: Trustify 3.1.0's own
    # openapi.json lists the values as skip/queue/wait, but the server rejects
    # those with 400 "unknown variant `wait`, expected one of `Skip`, `Queue`,
    # `Wait`" (observed 2026-10-23).
    query="cache=Wait"
    for pair in "$@"; do
      [ "${pair#*=}" != "$pair" ] || die "upload: label '$pair' is not key=value"
      pair="$(normalize "$pair")"
      query+="&labels.$(urlencode "${pair%%=*}")=$(urlencode "${pair#*=}")"
    done
    api --max-time 300 -X POST "$BASE/api/v3/sbom?$query" \
        -H 'Content-Type: application/json' --data-binary "@$file" \
      || fail "the upload was refused"
    ;;

  advisories)
    id="${1:-}"
    [ -n "$id" ] || die "advisories: no SBOM id"
    api --max-time 60 "$BASE/api/v3/sbom/$(urlencode "$id")/advisory" \
      || fail "no advisories for $id"
    ;;

  find)
    [ "$#" -gt 0 ] || die "find: no labels to match"
    wanted=()
    for pair in "$@"; do wanted+=("$(normalize "$pair")"); done
    # Filtered and ordered here rather than by the server: q and sort address
    # table columns, and the document does not say whether labels or the
    # ingestion time are among them. Matching locally depends on nothing
    # unverified. One page is enough while an instance holds dozens of
    # inventories, not thousands.
    page="$(api --max-time 60 "$BASE/api/v3/sbom?limit=1000")" \
      || fail "cannot list SBOMs"
    node -e '
      const page = JSON.parse(process.argv[1]);
      const want = process.argv.slice(2).map(p => [p.slice(0, p.indexOf("=")), p.slice(p.indexOf("=") + 1)]);
      // Stored with or without the prefix the upload used, depending on the
      // version; accept either.
      const label = (l, k) => l[k] ?? l["labels." + k];
      const hit = (page.items || [])
        .filter(s => want.every(([k, v]) => label(s.labels || {}, k) === v))
        .sort((a, b) => String(b.ingested).localeCompare(String(a.ingested)))[0];
      if (!hit) process.exit(3);
      process.stdout.write(JSON.stringify({ id: hit.id, name: hit.name, labels: hit.labels }) + "\n");
    ' "$page" "${wanted[@]}"
    ;;

  *)
    die "usage: tpa.sh upload|advisories|find ..."
    ;;
esac
