#!/usr/bin/env bash
# patch-cap-retry.test.sh — the patch step's one re-run after an output-cap
# refusal, exercised without a cluster or a model.
#
# The step's script is taken from the rendered chart, so this tests what the
# cluster would run, and the session is a stub that fails or succeeds on cue.
# A real refusal cannot be provoked on demand, which is the point of testing
# the rule here rather than waiting for the model to hit it.
#
# Usage: agent-runtime/test/patch-cap-retry.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CHART="$SCRIPT_DIR/../../deploy/gitops/deployments/agents/remediation-pipeline"
TMP="$(mktemp -d)"
readonly TMP
trap 'rm -r "$TMP"' EXIT

command -v helm >/dev/null || { echo "patch-cap-retry: helm is not installed" >&2; exit 2; }

# The patch step's script: the block under `script: |` that follows
# `- name: patch`, dedented, with the Tekton substitutions a real run fills in.
helm template t "$CHART" --show-only templates/task-patch-and-verify.yaml \
  | awk '
      /^ *- name: patch$/ { in_step = 1; next }
      in_step && /^ *script: \|$/ { match($0, /^ */); base = RLENGTH; grab = 1; next }
      grab {
        if ($0 ~ /^ *$/) { print ""; next }
        match($0, /^ */); if (RLENGTH <= base) exit
        print substr($0, base + 3)
      }' \
  | sed -e "s#\$(workspaces.source.path)#$TMP/ws#g" \
        -e 's#\$(params.replay)#false#g' -e 's#\$(params.model)##g' \
        -e 's#\$(params.osv)#/osv/record.json#g' -e 's#\$(params.fixture-patch)#patch.json#g' \
  >"$TMP/patch.sh"
grep -q 'entrypoint.sh /usr/local/bin/run-agent.sh' "$TMP/patch.sh" \
  || { echo "patch-cap-retry: could not extract the patch step from the chart" >&2; exit 2; }

# A stub session. Each call is counted; $SCENARIO says what call N does.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/entrypoint.sh" <<'STUB'
#!/usr/bin/env bash
n=$(( $(cat "$TMP/calls" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$TMP/calls"
out="$TMP/ws/out"
cap='{"result":"API Error: Claude'"'"'s response exceeded the 4096 output token maximum."}'
case "$SCENARIO:$n" in
  cap-then-ok:1|cap-twice:*) echo "$cap" >"$out/result.json"; exit 1 ;;
  cap-left-change:1) echo "$cap" >"$out/result.json"; echo edit >>"$TMP/ws/repo/App.java"; exit 1 ;;
  other-failure:1) echo '{"result":"turn budget exhausted"}' >"$out/result.json"; exit 1 ;;
  *) echo '{"terminal_state":"patched"}' >"$out/patch.json"; echo '{}' >"$out/result.json"; exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/entrypoint.sh"

pass=0
fail=0

# expect <scenario> <exit> <sessions> <no-retry sentinel: yes|no>
expect() {
  local scenario="$1" want_exit="$2" want_sessions="$3" want_sentinel="$4"
  rm -rf "$TMP/ws" "$TMP/calls"
  mkdir -p "$TMP/ws/out" "$TMP/ws/repo"
  git -C "$TMP/ws/repo" init -q 2>/dev/null
  echo app >"$TMP/ws/repo/App.java"
  git -C "$TMP/ws/repo" add . && git -C "$TMP/ws/repo" -c user.email=t@t -c user.name=t commit -qm init
  # What the demonstration leaves: the tree is never clean when patch starts.
  echo test >"$TMP/ws/repo/ExploitTest.java"

  ( export TMP SCENARIO="$scenario" PATH="$TMP/bin:$PATH"; bash "$TMP/patch.sh" ) >/dev/null 2>&1
  local got_exit=$? got_sessions got_sentinel=no
  got_sessions="$(cat "$TMP/calls" 2>/dev/null || echo 0)"
  [ -f "$TMP/ws/out/.no-retry" ] && got_sentinel=yes

  if [[ "$got_exit" == "$want_exit" && "$got_sessions" == "$want_sessions" && "$got_sentinel" == "$want_sentinel" ]]; then
    printf '  ok    %s — exit %s, %s session(s), sentinel %s\n' "$scenario" "$got_exit" "$got_sessions" "$got_sentinel"
    (( pass++ ))
  else
    printf '  FAIL  %s — exit %s/%s, sessions %s/%s, sentinel %s/%s (got/want)\n' "$scenario" \
      "$got_exit" "$want_exit" "$got_sessions" "$want_sessions" "$got_sentinel" "$want_sentinel"
    (( fail++ ))
  fi
}

printf 'patch step: one re-run after an output-cap refusal\n'

expect succeeds-first      0 1 no
# The refusal on an untouched tree is re-run once, inside the step.
expect cap-then-ok         0 2 no
# A refusal that left a change behind is not: the tree is no longer the one
# the session was given.
expect cap-left-change     1 1 yes
# Nothing but the refusal is re-run.
expect other-failure       1 1 yes
# Once, not until it works.
expect cap-twice           1 2 yes

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
