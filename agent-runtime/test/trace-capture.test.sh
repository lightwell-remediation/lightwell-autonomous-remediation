#!/usr/bin/env bash
# trace-capture.test.sh — capture and export of agent traces, without a model.
#
# Capture (lib/capture-trace.js) is fed a recorded-shape session stream and a
# synthetic transcript. Export (trace-export.py) is run with no backend, with
# an unreachable one, and — when an MLflow client is available — against a
# throwaway sqlite store, where the experiment, sessions and tags are read
# back. Nothing here needs a cluster or a network.
#
# Contract: specs/observability/agent-tracing.spec.md
#
# Usage: agent-runtime/test/trace-capture.test.sh
#   PYTHON=<interpreter with mlflow> to choose the client (default: the
#   repository's .venv if it has mlflow, else the MLflow cases are skipped)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly RUNTIME="$SCRIPT_DIR/.."
readonly CAPTURE="$RUNTIME/lib/capture-trace.js"
readonly EXPORT="$RUNTIME/trace-export.py"
TMP="$(mktemp -d)"
readonly TMP
trap 'rm -r "$TMP"' EXIT

PYTHON="${PYTHON:-$RUNTIME/../.venv/bin/python}"
"$PYTHON" -c 'import mlflow' 2>/dev/null || PYTHON=""

pass=0
fail=0
check() {
  local name="$1"; shift
  if "$@"; then printf '  ok    %s\n' "$name"; (( pass++ ))
  else printf '  FAIL  %s\n' "$name"; (( fail++ )); fi
}
meta() { node -e 'const m=require(process.argv[1]); console.log(String(m[process.argv[2]]))' "$1" "$2"; }

# A session as the harness leaves it: the stream run-agent.sh records, and the
# transcript the harness files under projects/<escaped cwd>/<session>.jsonl.
session() {
  local id="$1" turns="$2"
  mkdir -p "$TMP/config/projects/-workspace-repo"
  cat >"$TMP/stream.jsonl" <<EOF
{"type":"system","subtype":"init","session_id":"$id","model":"test-model"}
{"type":"result","subtype":"success","session_id":"$id","num_turns":$turns,"total_cost_usd":0.12}
EOF
  cat >"$TMP/config/projects/-workspace-repo/$id.jsonl" <<EOF
{"type":"user","sessionId":"$id","version":"2.1.295","timestamp":"2026-10-30T10:00:00.000Z","uuid":"u1","message":{"role":"user","content":"Analyse the vulnerability."}}
{"type":"assistant","sessionId":"$id","version":"2.1.295","timestamp":"2026-10-30T10:00:05.000Z","uuid":"a1","message":{"id":"m1","role":"assistant","model":"test-model","content":[{"type":"text","text":"Not reachable."}],"usage":{"input_tokens":10,"output_tokens":5}}}
EOF
}
capture() {
  CLAUDE_CONFIG_DIR="$TMP/config" MAAS_MODEL=test-model \
    node "$CAPTURE" "$TMP/stream.jsonl" "$TMP/out/traces" "$@" 2>/dev/null
}

printf 'capture\n'

echo '{"terminal_state":"not-remediable"}' >"$TMP/analysis.json"
session s-analyze 7
capture analyze 0 "$TMP/analysis.json"
check "a session leaves its transcript" cmp -s "$TMP/config/projects/-workspace-repo/s-analyze.jsonl" "$TMP/out/traces/01-analyze.jsonl"
check "metadata names harness, version and format" \
  test "$(meta "$TMP/out/traces/01-analyze.meta.json" harness)/$(meta "$TMP/out/traces/01-analyze.meta.json" harness_version)/$(meta "$TMP/out/traces/01-analyze.meta.json" transcript_format)" = "claude-code/2.1.295/claude-code-transcript"
check "metadata records how it ended" \
  test "$(meta "$TMP/out/traces/01-analyze.meta.json" terminal_state)/$(meta "$TMP/out/traces/01-analyze.meta.json" exit_status)/$(meta "$TMP/out/traces/01-analyze.meta.json" num_turns)" = "not-remediable/0/7"

session s-patch-1 30; capture patch 1
session s-patch-2 12; capture patch 0
check "a retry does not overwrite the attempt it retries" \
  test "$(meta "$TMP/out/traces/02-patch.meta.json" session_id)/$(meta "$TMP/out/traces/03-patch.meta.json" session_id)" = "s-patch-1/s-patch-2"
check "attempts are counted per role" \
  test "$(meta "$TMP/out/traces/02-patch.meta.json" attempt)/$(meta "$TMP/out/traces/03-patch.meta.json" attempt)" = "1/2"

session s-verify 3
rm "$TMP/config/projects/-workspace-repo/s-verify.jsonl"
capture verify 1
check "a missing transcript keeps the stream under its own format" \
  test "$(meta "$TMP/out/traces/04-verify.meta.json" transcript_format)" = "claude-code-stream-json"

echo '{"type":"system"}' >"$TMP/stream.jsonl"
capture deliver 1
check "a stream naming no session captures nothing and exits 0" \
  test $? -eq 0 -a ! -e "$TMP/out/traces/05-deliver.meta.json"

printf '\nexport\n'

out="$(python3 "$EXPORT" --exporter none --traces "$TMP/out/traces" --run r 2>&1)"
check "no exporter sends nothing" test $? -eq 0
check "  and says so" grep -q 'no exporter selected' <<<"$out"

mkdir -p "$TMP/empty"
if [[ -n "$PYTHON" ]]; then
  out="$("$PYTHON" "$EXPORT" --exporter mlflow --traces "$TMP/empty" --run replay-1 2>&1)"
  check "a replay has nothing to trace and exits 0" grep -q 'nothing to trace' <<<"$out"

  out="$(MLFLOW_TRACKING_URI=http://127.0.0.1:9 MLFLOW_HTTP_REQUEST_MAX_RETRIES=0 MLFLOW_HTTP_REQUEST_TIMEOUT=2 \
           "$PYTHON" "$EXPORT" --exporter mlflow --traces "$TMP/out/traces" --run r 2>&1)"
  check "an unreachable backend is reported and exits 0" grep -q 'export failed' <<<"$out"

  # From /, as a Tekton step starts: the MLflow integration writes a log
  # under the working directory, and / is not writable there or here.
  ( cd / && MLFLOW_TRACKING_URI="sqlite:///$TMP/mlflow.db" \
      "$PYTHON" "$EXPORT" --exporter mlflow --traces "$TMP/out/traces" --run remediate-test \
      --application demo >"$TMP/export.log" 2>&1 )
  check "the stream-format trace is skipped, not guessed at" grep -q "no MLflow reader for format 'claude-code-stream-json'" "$TMP/export.log"

  MLFLOW_TRACKING_URI="sqlite:///$TMP/mlflow.db" "$PYTHON" - >"$TMP/read.txt" 2>/dev/null <<'PY'
import mlflow
from mlflow import MlflowClient
exp = MlflowClient().get_experiment_by_name("lightwell/remediate-test")
print("experiment", exp is not None and exp.tags.get("lightwell.application"))
for t in mlflow.search_traces(experiment_ids=[exp.experiment_id], return_type="list"):
    print("trace", t.info.trace_metadata.get("mlflow.trace.session"),
          t.info.tags.get("lightwell.role"), t.info.tags.get("lightwell.attempt"))
PY
  check "one experiment per run" grep -q '^experiment demo$' "$TMP/read.txt"
  check "one session per role" grep -q '^trace remediate-test-analyze analyze 1$' "$TMP/read.txt"
  check "retries are traces in their role's session" \
    test "$(grep -c '^trace remediate-test-patch patch [12]$' "$TMP/read.txt")" -eq 2
  check "three sessions exported, the unreadable one not" test "$(grep -c '^trace ' "$TMP/read.txt")" -eq 3
else
  printf '  skip  MLflow cases — no interpreter with mlflow (set PYTHON)\n'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
