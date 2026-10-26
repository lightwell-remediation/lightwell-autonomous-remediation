#!/usr/bin/env bash
# tpa.test.sh — what the pipeline concludes from Trusted Profile Analyzer's
# answers, decided without an instance.
#
# The responses below follow Trustify 3.1.0's SbomAdvisory/SbomStatus schemas
# (GET /api/v3/sbom/{id}/advisory). validate-sbom.sh runs against a stand-in
# for tpa.sh, so the upload, the baseline lookup and every way of not
# validating are exercised with no network.
#
# Usage: agent-runtime/test/tpa.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly RUNTIME="$SCRIPT_DIR/.."
readonly VERDICT="$RUNTIME/lib/tpa-verdict.js"
readonly SECTION="$RUNTIME/lib/tpa-section.js"
readonly TMP="$(mktemp -d)"
trap 'rm -r "$TMP"' EXIT

pass=0
fail=0
ok()  { printf '  ok    %s\n' "$1"; (( pass++ )); }
bad() { printf '  FAIL  %s — %s\n' "$1" "$2"; (( fail++ )); }

# check <name> <file> <node expression over d>
check() {
  if node -e "const d = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')); process.exit(($3) ? 0 : 1)" "$2" 2>/dev/null; then
    ok "$1"
  else
    bad "$1" "$(tr -d '\n' <"$2" | cut -c1-200)"
  fi
}

readonly VULN="x_VENDOR-CVE-2026-68079-4.2.2"

# The baseline as TPA reports it: the advisory Lightwell published, its CVE
# affecting the inventory, and an unrelated one alongside.
cat >"$TMP/baseline.json" <<'EOF'
[
  {"uuid":"u1","identifier":"x_VENDOR-CVE-2026-68079-4.2.2","document_id":"x_VENDOR-CVE-2026-68079-4.2.2",
   "issuer":null,"published":null,"withdrawn":null,"title":"Apache CXF","labels":{},
   "status":[{"identifier":"CVE-2026-68079","status":"affected","packages":[],"scores":[]}]},
  {"uuid":"u2","identifier":"GHSA-other","document_id":"GHSA-other",
   "issuer":null,"published":null,"withdrawn":null,"title":"other","labels":{},
   "status":[{"identifier":"CVE-2025-00001","status":"affected","packages":[],"scores":[]}]}
]
EOF
# After the remediation: the advisory says fixed, the unrelated one remains.
cat >"$TMP/fixed.json" <<'EOF'
[
  {"uuid":"u1","identifier":"x_VENDOR-CVE-2026-68079-4.2.2","document_id":"x_VENDOR-CVE-2026-68079-4.2.2",
   "issuer":null,"published":null,"withdrawn":null,"title":"Apache CXF","labels":{},
   "status":[{"identifier":"CVE-2026-68079","status":"fixed","packages":[],"scores":[]}]},
  {"uuid":"u2","identifier":"GHSA-other","document_id":"GHSA-other",
   "issuer":null,"published":null,"withdrawn":null,"title":"other","labels":{},
   "status":[{"identifier":"CVE-2025-00001","status":"affected","packages":[],"scores":[]}]}
]
EOF
# Reported under another advisory, found by the CVE alone.
cat >"$TMP/by-cve.json" <<'EOF'
[{"uuid":"u3","identifier":"GHSA-xxxx","document_id":"GHSA-xxxx","issuer":null,"published":null,
  "withdrawn":null,"title":"t","labels":{},
  "status":[{"identifier":"CVE-2026-68079","status":"affected","packages":[],"scores":[]}]}]
EOF
echo '[]' >"$TMP/empty.json"

echo "tpa-verdict.js"
node "$VERDICT" "$VULN" https://tpa.example/ sha256:new "$TMP/fixed.json" urn:uuid:base "$TMP/baseline.json" >"$TMP/v1.json"
check "affected before, fixed after → resolved" "$TMP/v1.json" \
  'd.resolved && d.baseline.state === "affected" && d.remediated.state === "fixed"'
check "an unrelated vulnerability is counted, not confused with ours" "$TMP/v1.json" \
  'd.remediated.affected_total === 1 && d.baseline.affected_total === 2'
check "links open the SBOM on its vulnerabilities tab" "$TMP/v1.json" \
  'd.remediated.url === "https://tpa.example/sboms/sha256:new?sd%3AactiveTab=vulnerabilities"'

node "$VERDICT" "$VULN" https://tpa.example sha256:new "$TMP/by-cve.json" >"$TMP/v2.json"
check "found by CVE under another advisory, still affected → not resolved" "$TMP/v2.json" \
  '!d.resolved && d.remediated.state === "affected" && d.baseline === null'

node "$VERDICT" "$VULN" https://tpa.example sha256:new "$TMP/empty.json" >"$TMP/v3.json"
check "not reported at all → absent, resolved" "$TMP/v3.json" \
  'd.resolved && d.remediated.state === "absent"'

if node "$VERDICT" "$VULN" https://tpa.example sha256:new "$TMP/missing.json" >/dev/null 2>&1; then
  bad "an unreadable response is an error" "exit 0"
else
  ok "an unreadable response is an error"
fi

echo "tpa-section.js"
node "$SECTION" "$TMP/v1.json" >"$TMP/s1.md"
grep -q '| Before (baseline) |' "$TMP/s1.md" && ! grep -q WARNING "$TMP/s1.md" \
  && ok "resolved: a before/after table, no warning" || bad "resolved section" "$(cat "$TMP/s1.md")"
node "$SECTION" "$TMP/v2.json" >"$TMP/s2.md"
grep -q 'WARNING' "$TMP/s2.md" && grep -q 'No baseline\|still reports' "$TMP/s2.md" \
  && ok "still affected: the reviewer is warned" || bad "warning section" "$(cat "$TMP/s2.md")"
echo '{"validated":false,"reason":"TPA refused the upload — 401"}' >"$TMP/v4.json"
node "$SECTION" "$TMP/v4.json" | grep -q 'Not validated: TPA refused the upload' \
  && ok "not validated: says so, and why" || bad "not-validated section" "missing reason"
[ -z "$(node "$SECTION" "$TMP/nothing.json")" ] \
  && ok "no document: nothing appended" || bad "no document" "printed something"

echo "validate-sbom.sh"
# A stand-in for tpa.sh. FAKE_TPA picks the behaviour; every call is logged.
cat >"$TMP/fake-tpa.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_DIR/calls"
case "$1" in
  upload)
    [ "${FAKE_TPA:-}" = refuse ] && { echo "HTTP 401" >&2; exit 1; }
    echo '{"id":"urn:uuid:new","document_id":"x"}' ;;
  advisories)
    case "$2" in
      urn:uuid:new)  cat "$FAKE_DIR/fixed.json" ;;
      urn:uuid:base) cat "$FAKE_DIR/baseline.json" ;;
    esac ;;
  find)
    [ "${FAKE_TPA:-}" = no-baseline ] && exit 3
    echo '{"id":"urn:uuid:base","name":"app","labels":{"app":"o/r","role":"baseline"}}' ;;
esac
EOF
chmod +x "$TMP/fake-tpa.sh"

# run <name> [VAR=value ...] — a workspace with an inventory and an analysis
run() {
  local name="$1"; shift
  local ws="$TMP/ws-$name"
  mkdir -p "$ws/repo" "$ws/out"
  echo '{"components":[]}' >"$ws/repo/sbom.json"
  cp "$SCRIPT_DIR/fixtures/analysis.remediable-reachable.json" "$ws/out/analysis.json"
  : >"$TMP/calls"
  env WORKSPACE="$ws" TPA="$TMP/fake-tpa.sh" FAKE_DIR="$TMP" \
      TPA_URL=https://tpa.example TPA_TOKEN_URL=x TPA_CLIENT_ID=x TPA_CLIENT_SECRET=x \
      APPLICATION=o/r RUN_NAME=remediate-abc "$@" \
      "$RUNTIME/validate-sbom.sh" >/dev/null 2>"$TMP/stderr-$name"
  echo $? >"$ws/exit"
}

run resolved
check "uploads, compares with the baseline, resolved" "$TMP/ws-resolved/out/tpa.json" \
  'd.resolved && d.baseline.sbom_id === "urn:uuid:base" && d.remediated.sbom_id === "urn:uuid:new"'
grep -q 'upload .*app=o/r role=remediated run=remediate-abc' "$TMP/calls" \
  && ok "the upload is labelled with the application and the run" || bad "upload labels" "$(cat "$TMP/calls")"

run refused FAKE_TPA=refuse
check "a refused upload is recorded, not fatal" "$TMP/ws-refused/out/tpa.json" \
  '!d.validated && /401/.test(d.reason)'
[ "$(cat "$TMP/ws-refused/exit")" = 0 ] && ok "…and the step still exits 0" || bad "refused exit" "$(cat "$TMP/ws-refused/exit")"

run nobase FAKE_TPA=no-baseline
check "no baseline: the branch alone is validated" "$TMP/ws-nobase/out/tpa.json" \
  'd.validated && d.baseline === null && d.remediated.state === "fixed"'

run unconfigured TPA_URL=
[ ! -e "$TMP/ws-unconfigured/out/tpa.json" ] && [ "$(cat "$TMP/ws-unconfigured/exit")" = 0 ] \
  && ok "no TPA configured: no document, exit 0" || bad "unconfigured" "wrote a document or failed"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
