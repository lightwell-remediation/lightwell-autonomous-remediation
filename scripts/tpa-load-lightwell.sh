#!/usr/bin/env bash
# tpa-load-lightwell.sh — load the Lightwell OSV records into Trusted Profile
# Analyzer through its API, with the ecosystem rewritten.
#
# Why: TPA 3.1.1 and 3.1.2 reject every record whose ecosystem is
# "Red Hat Lightwell:Maven" (TC-7303, docs/workarounds.md), so the importer
# cannot load them. The same record is accepted once the ecosystem reads
# "Maven": the package purl, the affected range and the fixed version
# (4.1.132.Final-rhlw-00002) are untouched, and those are what TPA matches on.
# Rewriting is a loss of information (the record no longer says it came from
# Lightwell), so this is a workaround, not the design. Delete the script when
# the importer accepts the records.
#
# Records come from LW_OSV_BASE_URL with the credentials in the
# lightwell-lightwell Secret, the token from lightwell-tpa. Nothing is printed
# but counts and record names; everything downloaded is deleted on exit.
#
# Usage: tpa-load-lightwell.sh [--namespace lightwell-agents] [--only <RHLW-id>...]
#   --only  load just these records (without .json); default: every record
#
# Exit status: 0 all loaded or already present, 1 some record failed, 2 setup.
set -uo pipefail

ns="lightwell-agents"; only=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --namespace) ns="${2:?--namespace needs a value}"; shift 2 ;;
    --only) shift; while [ "$#" -gt 0 ] && [[ "$1" != --* ]]; do only+=("$1"); shift; done ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
command -v oc >/dev/null && command -v jq >/dev/null || { echo "needs oc and jq" >&2; exit 2; }

sec() { oc get secret "$1" -n "$ns" -o "jsonpath={.data.$2}" 2>/dev/null | base64 -d; }
LW_U="$(sec lightwell-lightwell LW_USERNAME)"; LW_P="$(sec lightwell-lightwell LW_PASSWORD)"
LW_B="$(sec lightwell-lightwell LW_OSV_BASE_URL)"
TPA_URL="$(sec lightwell-tpa TPA_URL)"
[ -n "$LW_U" ] && [ -n "$LW_B" ] || { echo "no lightwell-lightwell Secret in $ns" >&2; exit 2; }
[ -n "$TPA_URL" ] || { echo "no lightwell-tpa Secret in $ns" >&2; exit 2; }

TPA_ID="$(sec lightwell-tpa TPA_CLIENT_ID)"; TPA_SECRET="$(sec lightwell-tpa TPA_CLIENT_SECRET)"
TPA_TOKEN_URL="$(sec lightwell-tpa TPA_TOKEN_URL)"
# The realm's access tokens last 300 s and the load takes longer: renew early.
TOKEN=""; token_at=0
renew_token() {
  [ -n "$TOKEN" ] && [ $((SECONDS - token_at)) -lt 200 ] && return 0
  TOKEN="$(curl -sk --max-time 20 -d grant_type=client_credentials -d "client_id=$TPA_ID" \
    --data-urlencode "client_secret=$TPA_SECRET" "$TPA_TOKEN_URL" \
    | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')"
  token_at=$SECONDS
  [ -n "$TOKEN" ]
}
renew_token || { echo "no token from the TPA realm" >&2; exit 2; }

dir="$(mktemp -d)"; trap 'rm -rf "$dir"' EXIT
if [ "${#only[@]}" -gt 0 ]; then
  printf '%s.json\n' "${only[@]}" > "$dir/index"
else
  # -L: the directory answers 301 before it lists.
  curl -sfL -u "$LW_U:$LW_P" "${LW_B%/}/" | grep -o 'RHLW-[A-Za-z0-9_.-]*\.json' | sort -u > "$dir/index"
fi
total="$(wc -l < "$dir/index")"; ok=0; bad=0
while read -r f; do
  if ! curl -sfL -u "$LW_U:$LW_P" "${LW_B%/}/$f" \
       | jq '(.affected[]?.package.ecosystem) |= sub("^Red Hat Lightwell:";"")' > "$dir/rec.json"; then
    echo "download failed: $f" >&2; bad=$((bad+1)); continue
  fi
  renew_token || { echo "lost the token" >&2; exit 1; }
  code="$(curl -sk --max-time 60 -o "$dir/out" -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    --data-binary @"$dir/rec.json" "${TPA_URL%/}/api/v3/advisory")"
  if [ "$code" = 201 ] || [ "$code" = 200 ]; then ok=$((ok+1))
  else echo "rejected ($code): $f $(jq -r '.message // empty' "$dir/out" | cut -c1-120)" >&2; bad=$((bad+1)); fi
done < "$dir/index"
echo "tpa-load-lightwell: $ok of $total loaded, $bad failed"
[ "$bad" -eq 0 ]
