#!/usr/bin/env bash
# check-gates.test.sh — exercise the patch and verification gates, no agent.
#
# These decide whether a run passes, so a defect here is a defect in every
# verdict the pipeline reports. The cases that matter most are the
# self-contradictions: a document can satisfy its schema and still claim
# something its own fields deny.
#
# Usage: agent-runtime/test/check-gates.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LIB="$SCRIPT_DIR/../lib"
readonly TMP="$(mktemp -d)"
trap 'rm -r "$TMP"' EXIT

pass=0
fail=0

# expect <gate> <expected-exit> <name> <document-or-MISSING>
expect() {
  local gate="$1" expected="$2" name="$3" document="$4"
  local file="$TMP/${name//[^a-zA-Z0-9]/_}.json"

  if [[ "$document" == "MISSING" ]]; then
    file="$TMP/does-not-exist.json"
  else
    printf '%s' "$document" >"$file"
  fi

  node "$LIB/$gate" "$file" >/dev/null 2>&1
  local actual=$?

  if [[ "$actual" == "$expected" ]]; then
    printf '  ok    %s\n' "$name"; (( pass++ ))
  else
    printf '  FAIL  %s — expected exit %s, got %s\n' "$name" "$expected" "$actual"; (( fail++ ))
  fi
}

# A document that should pass, used as the base the contradictions deviate from.
readonly GOOD_PATCH='{
  "terminal_state":"patched","strategy":"declaration",
  "files_changed":["pom.xml"],
  "artifacts_moved":[{"coordinates":"g:a","from":"1.0.0","to":"1.0.0-rebuild"}],
  "compiles":true}'

readonly GOOD_VERIFY='{
  "terminal_state":"verified","resolved_version":"1.0.0-rebuild",
  "affected_version_absent":true,"baseline_tests":3,
  "regressions":[],"missing_or_altered":[],"tests_added":[]}'

printf 'check-patch gate\n'

expect check-patch.js 0 "patched with a real change" "$GOOD_PATCH"
expect check-patch.js 1 "cannot-patch" '{"terminal_state":"cannot-patch","reason":"sibling has no rebuild"}'
expect check-patch.js 1 "unrecognised state" '{"terminal_state":"done"}'
expect check-patch.js 1 "state absent" '{"files_changed":["pom.xml"]}'
expect check-patch.js 1 "malformed json" 'terminal_state: patched'
expect check-patch.js 1 "document absent" MISSING

# Claiming the work is done while the evidence says nothing happened.
expect check-patch.js 1 "patched, no file changed" \
  '{"terminal_state":"patched","files_changed":[],"artifacts_moved":[{"coordinates":"g:a","from":"1","to":"2"}],"compiles":true}'
expect check-patch.js 1 "patched, does not compile" \
  '{"terminal_state":"patched","files_changed":["pom.xml"],"artifacts_moved":[{"coordinates":"g:a","from":"1","to":"2"}],"compiles":false}'
expect check-patch.js 1 "patched, no artifact moved" \
  '{"terminal_state":"patched","files_changed":["pom.xml"],"artifacts_moved":[],"compiles":true}'
expect check-patch.js 1 "patched, version unchanged" \
  '{"terminal_state":"patched","files_changed":["pom.xml"],"artifacts_moved":[{"coordinates":"g:a","from":"1.0.0","to":"1.0.0"}],"compiles":true}'

printf '\ncheck-verification gate\n'

expect check-verification.js 0 "verified" "$GOOD_VERIFY"
expect check-verification.js 0 "verified with tests added" \
  '{"terminal_state":"verified","resolved_version":"1.0.0-rebuild","affected_version_absent":true,"baseline_tests":3,"regressions":[],"missing_or_altered":[],"tests_added":["C#newOne"]}'
expect check-verification.js 1 "regression" '{"terminal_state":"regression","reason":"C#t broke"}'
expect check-verification.js 1 "cannot-verify" '{"terminal_state":"cannot-verify","reason":"no baseline"}'
expect check-verification.js 1 "unrecognised state" '{"terminal_state":"green"}'
expect check-verification.js 1 "malformed json" 'nope'
expect check-verification.js 1 "document absent" MISSING

# The vulnerable artifact still resolves, but the document says verified. This
# is the failure the second half of the resolved-version check exists for.
expect check-verification.js 1 "verified, affected version still present" \
  '{"terminal_state":"verified","resolved_version":"1.0.0-rebuild","affected_version_absent":false,"reintroduced_by":"x:y","baseline_tests":3,"regressions":[],"missing_or_altered":[]}'
# A suite made green by removing the test that failed.
expect check-verification.js 1 "verified, baseline test missing" \
  '{"terminal_state":"verified","resolved_version":"r","affected_version_absent":true,"baseline_tests":3,"regressions":[],"missing_or_altered":["C#gone"]}'
expect check-verification.js 1 "verified, listing a regression" \
  '{"terminal_state":"verified","resolved_version":"r","affected_version_absent":true,"baseline_tests":3,"regressions":[{"test":"C#t","attribution":"regression"}],"missing_or_altered":[]}'
expect check-verification.js 1 "verified, difference unattributable" \
  '{"terminal_state":"verified","resolved_version":"r","affected_version_absent":true,"baseline_tests":3,"regressions":[{"test":"C#t","attribution":"unattributable"}],"missing_or_altered":[]}'
expect check-verification.js 1 "verified against no tests" \
  '{"terminal_state":"verified","resolved_version":"r","affected_version_absent":true,"baseline_tests":0,"regressions":[],"missing_or_altered":[]}'
expect check-verification.js 1 "verified without a resolved version" \
  '{"terminal_state":"verified","affected_version_absent":true,"baseline_tests":3,"regressions":[],"missing_or_altered":[]}'

# The case the whole exploit-test capability exists to catch: dependency
# moved, existing tests green, defect still there.
expect check-verification.js 1 "verified while the exploit test still fails" \
  '{"terminal_state":"verified","resolved_version":"r","affected_version_absent":true,"baseline_tests":3,"regressions":[],"missing_or_altered":[],"exploit_test":{"available":true,"failed_before":true,"passed_after":false}}'
expect check-verification.js 1 "verified citing a test that never failed" \
  '{"terminal_state":"verified","resolved_version":"r","affected_version_absent":true,"baseline_tests":3,"regressions":[],"missing_or_altered":[],"exploit_test":{"available":true,"failed_before":false,"passed_after":true}}'
expect check-verification.js 0 "verified with a real demonstration" \
  '{"terminal_state":"verified","resolved_version":"r","affected_version_absent":true,"baseline_tests":3,"regressions":[],"missing_or_altered":[],"exploit_test":{"available":true,"failed_before":true,"passed_after":true}}'

printf '\ncheck-delivery gate\n'

readonly GOOD_DELIVERY='{
  "terminal_state":"delivered","branch":"remediate/x-1",
  "pull_request":"https://github.com/o/r/pull/7","commit":"abc123def456"}'

expect check-delivery.js 0 "delivered" "$GOOD_DELIVERY"
expect check-delivery.js 1 "cannot-deliver" '{"terminal_state":"cannot-deliver","reason":"push rejected"}'
expect check-delivery.js 1 "unrecognised state" '{"terminal_state":"pushed"}'
expect check-delivery.js 1 "malformed json" 'nope'
expect check-delivery.js 1 "document absent" MISSING

# A branch pushed with no request opened is work nobody was asked to look at.
expect check-delivery.js 1 "delivered without a URL" \
  '{"terminal_state":"delivered","branch":"remediate/x-1","commit":"abc123"}'
expect check-delivery.js 1 "URL that is not a URL" \
  '{"terminal_state":"delivered","branch":"b","pull_request":"opened it","commit":"abc123"}'
expect check-delivery.js 1 "delivered without branch or commit" \
  '{"terminal_state":"delivered","pull_request":"https://github.com/o/r/pull/7"}'

printf '\ncheck-exploit gate\n'

expect check-exploit.js 0 "demonstrated" \
  '{"terminal_state":"demonstrated","test":"C#m","asserts":"codes are single use","observed_failure":"fail","baseline_intact":true}'
# An unreachable defect is a fact about the application, not a failed run.
expect check-exploit.js 0 "not-demonstrable" \
  '{"terminal_state":"not-demonstrable","reason":"vulnerable code is not reached"}'
expect check-exploit.js 1 "cannot-generate" \
  '{"terminal_state":"cannot-generate","reason":"the test passed against vulnerable code"}'
expect check-exploit.js 1 "unrecognised state" '{"terminal_state":"red"}'
expect check-exploit.js 1 "malformed json" 'nope'
expect check-exploit.js 1 "document absent" MISSING

# A demonstration that demonstrates nothing.
expect check-exploit.js 1 "demonstrated but the test passed" \
  '{"terminal_state":"demonstrated","test":"C#m","observed_failure":"pass","baseline_intact":true}'
expect check-exploit.js 1 "demonstrated without naming the test" \
  '{"terminal_state":"demonstrated","observed_failure":"fail","baseline_intact":true}'
expect check-exploit.js 1 "demonstrated on a broken baseline" \
  '{"terminal_state":"demonstrated","test":"C#m","observed_failure":"fail","baseline_intact":false}'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
