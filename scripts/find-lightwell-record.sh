#!/usr/bin/env bash
# find-lightwell-record.sh — name the Lightwell OSV records that mention a CVE.
#
# Lightwell publishes records as RHLW-2026-<hash>.json, so the CVE is only
# inside the file. This downloads the index records into a temporary
# directory, greps them and deletes everything on exit.
#
# Prints record names only: no credentials, no URL. Those come from the
# lightwell-lightwell Secret (LW_USERNAME, LW_PASSWORD, LW_OSV_BASE_URL).
#
# Usage: find-lightwell-record.sh <CVE-or-text> [--namespace <ns>]
#
# A hit is one advisory per release line, so check the version in the summary
# against the one the application builds with. Pass the name, without .json,
# to run-remediation.sh with --vulnerability.
set -euo pipefail

needle="${1:?usage: $0 <CVE-or-text> [--namespace <ns>]}"
ns="lightwell-agents"
[ "${2:-}" != "--namespace" ] || ns="${3:?--namespace needs a value}"

secret() { oc get secret lightwell-lightwell -n "$ns" -o jsonpath="{.data.$1}" | base64 -d; }
export LW_U LW_P LW_B dir
LW_U="$(secret LW_USERNAME)"; LW_P="$(secret LW_PASSWORD)"; LW_B="$(secret LW_OSV_BASE_URL)"
dir="$(mktemp -d)"; trap 'rm -rf "$dir"' EXIT

# -L: the directory answers 301 before it lists.
curl -sfL -u "$LW_U:$LW_P" "${LW_B%/}/" | grep -o 'RHLW-[A-Za-z0-9_.-]*\.json' | sort -u > "$dir/index"
echo "records in the index: $(wc -l < "$dir/index")" >&2

xargs -P 8 -I{} sh -c 'curl -sfL -u "$LW_U:$LW_P" "${LW_B%/}/{}" -o "$dir/{}"' < "$dir/index"

hits="$(grep -l -- "$needle" "$dir"/RHLW-*.json 2>/dev/null | xargs -r -n1 basename || true)"
[ -n "$hits" ] || { echo "no record mentions '$needle'" >&2; exit 1; }
for f in $hits; do
  summary="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("summary",""))' "$dir/$f")"
  echo "${f%.json}  $summary"
done
