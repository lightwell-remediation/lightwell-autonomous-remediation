#!/usr/bin/env bash
# run-suite.sh — run the application's tests and record them comparably.
#
# Runs inside the image, the same way run-agent.sh does, so the baseline and
# the post-change run are produced by identical means. A baseline measured by
# a different toolchain than the run it is compared against is not a baseline.
#
# Usage:
#   run-suite.sh <output-name>        writes $WORKSPACE/out/<output-name>
#
# Exit status:
#   0  the suite ran and every test passed
#   1  the suite ran and at least one test did not pass
#   2  the suite could not be run at all
#
# The distinction between 1 and 2 is what the sequencer acts on: a red suite
# stops the run so a person can fix it, while a suite that cannot execute is a
# different problem and says nothing about the tests.
#
# Contract: specs/agents/fix-verification.spec.md — A Green Baseline Is a
# Precondition

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly EXIT_CONFIG=2

die() { printf 'run-suite: %s\n' "$*" >&2; exit "$EXIT_CONFIG"; }
log() { printf 'run-suite: %s\n' "$*" >&2; }

OUTPUT_NAME="${1:-}"
[[ -n "$OUTPUT_NAME" ]] || die "usage: run-suite.sh <output-name>"

WORKSPACE="${WORKSPACE:-$SCRIPT_DIR/../.workspace}"
readonly REPO_DIR="$WORKSPACE/repo"
readonly OUT_DIR="$WORKSPACE/out"
readonly OUTPUT="$OUT_DIR/$OUTPUT_NAME"
mkdir -p "$OUT_DIR"

[[ -d "$REPO_DIR" ]] || die "no checkout in $REPO_DIR"
[[ -f "$REPO_DIR/pom.xml" ]] || die "no pom.xml in $REPO_DIR — only Maven is supported"

mvn_args=(-B test)
[[ -f "$REPO_DIR/settings.xml" ]] && mvn_args=(-s settings.xml "${mvn_args[@]}")

# Reports from an earlier run would be read as this one's. Surefire overwrites
# per class, so a test class deleted since would otherwise linger and appear
# in the comparison as still present.
rm -rf "$REPO_DIR/target/surefire-reports"

log "running the suite (mvn ${mvn_args[*]})"
suite_log="$OUT_DIR/${OUTPUT_NAME%.txt}.log"
( cd "$REPO_DIR" && mvn "${mvn_args[@]}" ) >"$suite_log" 2>&1
mvn_status=$?

readonly REPORTS="$REPO_DIR/target/surefire-reports"
if ! node "${TEST_RESULTS:-$SCRIPT_DIR/lib/test-results.js}" "$REPORTS" >"$OUTPUT" 2>/dev/null; then
  # No reports at all. Either compilation failed or the suite never started —
  # both mean there is nothing to compare, which is not the same as a failure.
  log "the suite produced no results; last lines of the build:"
  tail -15 "$suite_log" >&2
  rm -f "$OUTPUT"
  exit "$EXIT_CONFIG"
fi

total="$(wc -l <"$OUTPUT")"
failed="$(grep -cvP '\t(pass|skipped)$' "$OUTPUT" || true)"

if (( failed > 0 )); then
  log "$failed of $total test(s) did not pass:"
  grep -vP '\t(pass|skipped)$' "$OUTPUT" | sed 's/^/run-suite:   /' >&2
  exit 1
fi

log "$total test(s) passed — recorded in $OUTPUT"

# Maven can fail for reasons the reports do not show, so its status is not
# ignored even when every recorded test passed.
if (( mvn_status != 0 )); then
  log "every test passed but the build exited $mvn_status; last lines:"
  tail -15 "$suite_log" >&2
  exit "$EXIT_CONFIG"
fi

exit 0
