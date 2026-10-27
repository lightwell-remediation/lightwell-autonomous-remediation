#!/usr/bin/env bash
# check-analysis.test.sh — exercise the analysis gate without running an agent.
#
# The gate decides whether a run passes, so a defect here is a defect in every
# verdict the pipeline reports. These cases cost no inference, so there is no
# reason to discover them from a model run.
#
# Usage: agent-runtime/test/check-analysis.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly GATE="$SCRIPT_DIR/../lib/check-analysis.js"
readonly TMP="$(mktemp -d)"
trap 'rm -r "$TMP"' EXIT

pass=0
fail=0

# expect <expected-exit> <name> <document-or-MISSING> [expected-vulnerability]
expect() {
  local expected="$1" name="$2" document="$3" vulnerability="${4:-}"
  local file="$TMP/${name//[^a-zA-Z0-9]/_}.json"

  if [[ "$document" == "MISSING" ]]; then
    file="$TMP/does-not-exist.json"
  else
    printf '%s' "$document" >"$file"
  fi

  EXPECTED_VULNERABILITY="$vulnerability" node "$GATE" "$file" >/dev/null 2>&1
  local actual=$?

  if [[ "$actual" == "$expected" ]]; then
    printf '  ok    %s\n' "$name"
    (( pass++ ))
  else
    printf '  FAIL  %s — expected exit %s, got %s\n' "$name" "$expected" "$actual"
    (( fail++ ))
  fi
}

printf 'check-analysis gate\n'

expect 0 "remediable with a version" \
  '{"terminal_state":"remediable","remediating_version":"1.2.3-rebuild"}'

expect 0 "no-action-needed" \
  '{"terminal_state":"no-action-needed","reason":"already at the fixed version"}'

expect 1 "cannot-remediate" \
  '{"terminal_state":"cannot-remediate","reason":"no fixed version published"}'

# The contract is that the analysis concludes. Anything that is not one of the
# three states means it did not, however confident the wording.
expect 1 "unrecognised terminal state" \
  '{"terminal_state":"done","reason":"analysed the application"}'

expect 1 "terminal state absent" \
  '{"reason":"the dependency looks fine"}'

expect 1 "malformed json" \
  'terminal_state: remediable'

expect 1 "document absent" MISSING

# A document can be well-formed and self-contradictory. This is the pairing a
# language model produces most readily: something to fix, nothing to fix it to.
expect 1 "remediable without a remediating version" \
  '{"terminal_state":"remediable","remediating_version":null}'

# A Lightwell advisory bundles several CVEs fixed by one release. The run names
# the one it is for, and an analysis of a sibling must not pass.
expect 0 "the vulnerability the run named" \
  '{"terminal_state":"remediable","remediating_version":"1.2.3-rebuild","vulnerability":{"id":"CVE-2026-68079"}}' \
  CVE-2026-68079

expect 1 "a sibling of the vulnerability the run named" \
  '{"terminal_state":"remediable","remediating_version":"1.2.3-rebuild","vulnerability":{"id":"CVE-2026-57818"}}' \
  CVE-2026-68079

expect 1 "no vulnerability, when the run named one" \
  '{"terminal_state":"remediable","remediating_version":"1.2.3-rebuild"}' \
  CVE-2026-68079

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
