#!/usr/bin/env bash
# check-result.test.sh — what a session result means, decided without a model.
#
# A denied action used to fail the run outright, and it cost real ones: a
# model asked for `find … ; ls …`, or piped an already-allowed `mvn` through
# `tail`, and lost everything it had done over one exploratory command it
# immediately worked around. The rule now depends on whether a role gate
# follows, and this is where that is pinned down.
#
# Emulating the failure needs no agent and no cluster. A denial is a field in
# result.json, so the exact shape the harness emits is written here and fed
# to the gate directly. Every case below is a session that really happened,
# or the inverse of one.
#
# Usage: agent-runtime/test/check-result.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly GATE="$SCRIPT_DIR/../lib/check-result.js"
readonly TMP="$(mktemp -d)"
trap 'rm -r "$TMP"' EXIT

pass=0
fail=0

# expect <expected-exit> <name> <document> [args...]
expect() {
  local expected="$1" name="$2" document="$3"; shift 3
  local file="$TMP/${name//[^a-zA-Z0-9]/_}.json"
  printf '%s' "$document" >"$file"

  node "$GATE" "$file" "$@" >/dev/null 2>&1
  local actual=$?

  if [[ "$actual" == "$expected" ]]; then
    printf '  ok    %s\n' "$name"; (( pass++ ))
  else
    printf '  FAIL  %s — expected exit %s, got %s\n' "$name" "$expected" "$actual"; (( fail++ ))
  fi
}

readonly CLEAN='{"subtype":"success","num_turns":9,"total_cost_usd":0.09,
  "terminal_reason":"completed","is_error":false}'

# The shape the harness emits. Taken from a real run: opus asked for a
# compound command in the exploit role and the whole run was discarded.
readonly COMPOUND_DENIAL='{"subtype":"success","num_turns":16,"total_cost_usd":0.29,
  "terminal_reason":"completed","is_error":false,
  "permission_denials":[{"tool_name":"Bash","tool_input":{
    "command":"find /workspace/source/out -name '"'"'api-signatures*'"'"' 2>/dev/null; ls /workspace/source/out/"}}]}'

# Also real: an allowed mvn invocation that was piped, which the policy reads
# as a different command.
readonly PIPED_DENIAL='{"subtype":"success","num_turns":26,"total_cost_usd":0.46,
  "terminal_reason":"completed","is_error":false,
  "permission_denials":[{"tool_name":"Bash","tool_input":{
    "command":"mvn -s settings.xml -B test-compile 2>&1 | tail -5"}}]}'

printf 'a session with nothing wrong\n'
expect 0 "clean session" "$CLEAN"
expect 0 "clean session, gated" "$CLEAN" --gated

printf '\nsession health still fails, gate or no gate\n'
# These are not policy questions. A session that ran out of turns did not
# finish its work, and no document it left behind can change that.
expect 1 "turn budget exhausted" \
  '{"subtype":"error_max_turns","num_turns":41,"is_error":true,"terminal_reason":"max_turns"}'
expect 1 "turn budget exhausted, gated" \
  '{"subtype":"error_max_turns","num_turns":41,"is_error":true,"terminal_reason":"max_turns"}' --gated
expect 1 "api error" \
  '{"subtype":"success","num_turns":3,"is_error":true,"terminal_reason":"api_error","result":"upstream 502"}'
expect 1 "api error, gated" \
  '{"subtype":"success","num_turns":3,"is_error":true,"terminal_reason":"api_error"}' --gated
expect 1 "malformed result" 'not json'
expect 1 "result absent" ''

printf '\na denial, with a role gate to judge the work\n'
# The policy already stopped the action. Whether the session still produced
# what it was contracted to produce is the document's question, and the role
# gate is what asks it.
expect 0 "compound command, gated" "$COMPOUND_DENIAL" --gated
expect 0 "piped allowed command, gated" "$PIPED_DENIAL" --gated
expect 0 "several denials, gated" \
  '{"subtype":"success","num_turns":30,"is_error":false,"permission_denials":[
     {"tool_name":"Bash","tool_input":{"command":"touch /workspace/source/repo/src/test/X.java"}},
     {"tool_name":"Bash","tool_input":{"command":"echo x > /tmp/y"}},
     {"tool_name":"Bash","tool_input":{"command":"cat > /tmp/z << EOF"}}]}' --gated

printf '\na denial with nothing downstream to judge it\n'
# The default role has no contracted document, so the denial is the only
# evidence that the session may have narrated rather than acted.
expect 1 "compound command, ungated" "$COMPOUND_DENIAL"
expect 1 "piped allowed command, ungated" "$PIPED_DENIAL"

printf '\nTOLERATE_DENIALS overrides even when ungated\n'
TOLERATE_DENIALS=1 expect 0 "tolerated, ungated" "$COMPOUND_DENIAL"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
