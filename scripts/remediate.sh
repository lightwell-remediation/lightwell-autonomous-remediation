#!/usr/bin/env bash
# remediate.sh — sequence the remediation phases against one vulnerability.
#
#   analyze → remediable? → baseline → green? → demonstrate → patch → verify → deliver
#                              │ no                   ↑          │ regression, one retry
#                              ↓                      └──────────┘
#                           stop, nothing patched
#
# Disposable on purpose. Tekton replaces this in ROADMAP Phase 3, and the
# contract between phases — files in the workspace's out/ directory — does not
# change when it does. It lives here rather than in run-agent.sh because
# agent-runtime.spec.md Non-Goals keeps the runtime orchestration-agnostic, so
# that orchestration-strategy.spec.md can still be decided on its merits.
#
# It owns the four guarantees fix-verification.spec.md assigns to whatever
# sequences these capabilities:
#   1. the baseline is taken after the analysis concludes remediable, and
#      before patching edits anything;
#   2. a baseline that is not green stops the run before any change;
#   3. a returned regression re-enters patching at most once;
#   4. the original baseline is carried into the retry, never recaptured.
#
# Usage:
#   remediate.sh --osv <path|url> [--workspace <dir>] [--repo owner/repo]
#                [--image <ref>] [--no-clone] [--dns <server>]
#                [--maven-cache <dir>]
#   remediate.sh --replay <scenario-dir> [--workspace <dir>]
#
# --replay serves recorded documents instead of starting sessions: no
# container, no credentials, no tokens, seconds instead of minutes. The gates
# still run, so a replay rejects a self-contradicting document exactly as a
# real run does. The same scenarios go through the Tekton Pipeline via
# scripts/test-pipeline.sh — two implementations of one contract drift unless
# something holds them together, and this is it.
#
# Exit status:
#   0  remediated, verified and delivered as a pull request
#   1  stopped: nothing to remediate, a red baseline, or a phase that failed
#   2  configuration error

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$SCRIPT_DIR/.."
readonly EXIT_CONFIG=2
readonly MAX_PATCH_ATTEMPTS=2

die()   { printf 'remediate: %s\n' "$*" >&2; exit "$EXIT_CONFIG"; }
log()   { printf 'remediate: %s\n' "$*" >&2; }
stage() { printf '\nremediate: ── %s ──\n' "$*" >&2; }

OSV=""
WORKSPACE="$REPO_ROOT/.workspace"
# Outside the workspace on purpose. A cache that lives in the workspace dies
# with it, and a cold one costs over fifteen minutes against roughly two warm
# — which is most of a run. Consecutive runs, and runs against different
# workspaces, share this. In a pod it is a volume rather than a per-run
# directory (ROADMAP Phase 3).
MAVEN_CACHE="${MAVEN_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/lightwell/m2}"
IMAGE="${IMAGE:-localhost/lightwell-agent-runtime:latest}"
SECRETS="${SECRETS:-$REPO_ROOT/secrets/secrets.env}"
DNS=""
REPLAY=""
EXTRA=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --osv)       OSV="${2:?--osv needs a value}"; shift 2 ;;
    --replay)    REPLAY="${2:?--replay needs a scenario directory}"; shift 2 ;;
    --workspace) WORKSPACE="${2:?--workspace needs a value}"; shift 2 ;;
    --maven-cache) MAVEN_CACHE="${2:?--maven-cache needs a value}"; shift 2 ;;
    --image)     IMAGE="${2:?--image needs a value}"; shift 2 ;;
    --dns)       DNS="${2:?--dns needs a value}"; shift 2 ;;
    --repo)      EXTRA+=(--repo "${2:?--repo needs a value}"); shift 2 ;;
    --no-clone)  EXTRA+=(--no-clone); shift ;;
    -h|--help)   sed -n '2,32p' "$0"; exit 0 ;;
    *)           die "unknown argument: $1" ;;
  esac
done

if [[ -n "$REPLAY" ]]; then
  [[ -d "$REPLAY" ]] || die "scenario directory not found: $REPLAY"
  REPLAY="$(cd "$REPLAY" && pwd)"
  command -v node >/dev/null || die "node is not installed (the gates need it)"
  # A replay starts no container and reads no credentials. That is the point:
  # the sequencing is what is being tested, and none of it needs either.
  #
  # Its own directory, not a corner of .workspace: that one is owned by the
  # container's mapped UID after any real run, and a replay must not need a
  # container to clean up after one.
  [[ "$WORKSPACE" == "$REPO_ROOT/.workspace" ]] && WORKSPACE="$REPO_ROOT/.replay"
  WORKSPACE="${WORKSPACE}/$(basename "$REPLAY")"
  rm -rf "$WORKSPACE"
else
  [[ -n "$OSV" ]] || die "--osv <path|url> is required"
  command -v podman >/dev/null || die "podman is not installed"
  [[ -r "$SECRETS" ]] || die "secrets file not readable: $SECRETS"
fi

mkdir -p "$WORKSPACE/out" || die "cannot create the workspace at $WORKSPACE"
WORKSPACE="$(cd "$WORKSPACE" && pwd)" || die "cannot enter the workspace at $WORKSPACE"
readonly OUT="$WORKSPACE/out"

if [[ -z "$REPLAY" ]]; then
  # Sourced rather than handed to podman as --env-file: the file quotes values
  # whose tokens contain shell metacharacters, and --env-file does not strip
  # quotes. See docs/agent-runtime.md — Quoted secrets and --env-file.
  set -a; # shellcheck disable=SC1090
  source "$SECRETS"; set +a
fi

# One run per application, not merely per workspace. Two runs sharing a
# workspace hang — the second resets the repository under the first, which
# then waits on work that no longer exists. But two runs against the same
# application in *different* workspaces are wrong for a separate reason: both
# branch from the same base, both open a pull request, and a reviewer gets two
# remediations of the same repository that know nothing about each other.
#
# The exception is deliberate: a dual-agent run produces several candidates of
# the same application on purpose and a judge delivers one of them. That is
# not two runs, it is one run with several candidates, and when it exists it
# takes this lock once and manages its candidates underneath.
#
# Keyed on the application rather than the directory, so it holds across
# workspaces. Released when this shell exits, however it exits.
lock_key="$(printf '%s' "${APP_REPO:-$WORKSPACE}" | tr -c 'a-zA-Z0-9.-' '-')"
readonly LOCK="${TMPDIR:-/tmp}/remediate-$lock_key.lock"
exec 9>"$LOCK"
flock -n 9 || die "another run is already remediating ${APP_REPO:-$WORKSPACE}"

# A local OSV path has to be visible inside the container; a URL is fetched by
# the runtime and passed through untouched.
osv_mount=()
osv_arg="$OSV"
if [[ -z "$REPLAY" && "$OSV" != http://* && "$OSV" != https://* ]]; then
  [[ -r "$OSV" ]] || die "vulnerability record not readable: $OSV"
  osv_dir="$(cd "$(dirname "$OSV")" && pwd)"
  osv_mount=(-v "$osv_dir:/osv:ro,Z")
  osv_arg="/osv/$(basename "$OSV")"
fi

# Which document each role is contracted to leave, and the gate that decides
# whether it means what it says. A replay serves the document and still runs
# the gate: a document can satisfy its schema and claim something its own
# fields deny, and a replay that skipped that rejection would be testing a
# sequencer more forgiving than the real one.
replay_phase() {
  local role="$1"
  local document gate fixture

  case "$role" in
    analyze) document=analysis.json;     gate=check-analysis.js ;;
    exploit) document=exploit.json;      gate=check-exploit.js ;;
    patch)   document=patch.json;        gate=check-patch.js ;;
    verify)  document=verification.json; gate=check-verification.js ;;
    deliver) document=delivery.json;     gate=check-delivery.js ;;
    *)       log "replay: unknown role $role"; return 2 ;;
  esac

  # The second attempt is served its own verification, where the scenario has
  # one. That is how a retry scenario differs from a straight one.
  fixture="$REPLAY/$document"
  if [[ "$role" == "verify" && "${attempt:-1}" -gt 1 && -r "$REPLAY/verification.retry.json" ]]; then
    fixture="$REPLAY/verification.retry.json"
  fi

  if [[ ! -r "$fixture" ]]; then
    log "replay: $role has no recorded document at $(basename "$fixture")"
    return 1
  fi

  cp "$fixture" "$OUT/$document"
  log "replay: $role ← $(basename "$fixture")"
  node "$REPO_ROOT/agent-runtime/lib/$gate" "$OUT/$document" >/dev/null 2>&1
}

# The baseline has no gate: run-suite.sh's exit status is the signal, so a
# scenario modelling a red suite states it rather than implying it.
replay_baseline() {
  if [[ -r "$REPLAY/baseline-tests.txt" ]]; then
    cp "$REPLAY/baseline-tests.txt" "$OUT/baseline-tests.txt"
  else
    : >"$OUT/baseline-tests.txt"
  fi
  local status=0
  [[ -r "$REPLAY/baseline.status" ]] && status="$(cat "$REPLAY/baseline.status")"
  log "replay: baseline ← exit $status"
  return "$status"
}

readonly PASSED_ENV=(
  MAAS_BASE_URL MAAS_API_KEY MAAS_MODEL MAAS_SMALL_MODEL
  GITHUB_TOKEN APP_REPO GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL
  LW_USERNAME LW_PASSWORD LW_MAVEN_REPO_URL MAX_TURNS TOLERATE_DENIALS
)

# Ownership flips to the container's mapped UID on every :U mount, which locks
# the host out of its own workspace between phases.
reclaim() { podman unshare chown -R 0:0 "$WORKSPACE" 2>/dev/null || true; }

run_phase() {
  local entrypoint="$1"; shift

  # One interception point, so a replay follows exactly the sequence a real
  # run does — the same preconditions, the same retry, the same exit status.
  # Nothing below the dispatch knows which it is.
  if [[ -n "$REPLAY" ]]; then
    if [[ "$entrypoint" == run-suite.sh ]]; then
      replay_baseline
      return $?
    fi
    local role=""
    local -a argv=("$@")
    for i in "${!argv[@]}"; do
      [[ "${argv[$i]}" == "--role" ]] && role="${argv[$((i + 1))]}"
    done
    replay_phase "$role"
    return $?
  fi

  local env_args=()
  local name
  for name in "${PASSED_ENV[@]}"; do
    [[ -n "${!name:-}" ]] && env_args+=(-e "$name")
  done
  local dns_args=()
  [[ -n "$DNS" ]] && dns_args=(--dns "$DNS")

  podman run --rm --user 61000:0 \
    "${env_args[@]}" "${dns_args[@]}" \
    -v "$WORKSPACE:/workspace:Z,U" \
    -v "$MAVEN_CACHE:/home/claude-agent/.m2:Z,U" \
    "${osv_mount[@]}" \
    ${entrypoint:+--entrypoint "$entrypoint"} \
    "$IMAGE" "$@"
  local status=$?
  reclaim
  return $status
}

state_of() {
  node -e '
    try {
      const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      process.stdout.write(String(d.terminal_state || ""));
    } catch { process.stdout.write(""); }
  ' "$1" 2>/dev/null
}

if [[ -n "$REPLAY" ]]; then
  log "replaying $REPLAY — no container, no credentials, no tokens"
else
  mkdir -p "$MAVEN_CACHE"
  MAVEN_CACHE="$(cd "$MAVEN_CACHE" && pwd)"
  log "maven cache: $MAVEN_CACHE"
  reclaim
fi
readonly MAVEN_CACHE

# ── Analyse ──────────────────────────────────────────────────────────────
stage "analyse"
run_phase "" --role analyze --osv "$osv_arg" "${EXTRA[@]}"
analyze_status=$?

analysis_state="$(state_of "$OUT/analysis.json")"
if [[ "$analysis_state" == "no-action-needed" ]]; then
  log "nothing to remediate — $analysis_state"
  exit 0
fi
if (( analyze_status != 0 )) || [[ "$analysis_state" != "remediable" ]]; then
  log "analysis did not reach a remediation (${analysis_state:-no document})"
  exit 1
fi

# ── Baseline ─────────────────────────────────────────────────────────────
# Guarantee 1 and 2. After the analysis, so a run with nothing to remediate
# never pays for the suite; before any edit, so there is still an unmodified
# tree to measure.
stage "baseline"
run_phase run-suite.sh baseline-tests.txt
baseline_status=$?

case "$baseline_status" in
  0) log "baseline is green — $(wc -l <"$OUT/baseline-tests.txt") test(s)" ;;
  1) log "the suite does not pass on the unmodified checkout; fix the tests before remediating"
     log "nothing was changed"
     exit 1 ;;
  *) log "the suite could not be run on the unmodified checkout"
     exit 1 ;;
esac

# Guarantee 4: kept aside so a retry is measured against the starting state,
# never against the results of the attempt that failed.
cp "$OUT/baseline-tests.txt" "$OUT/baseline-tests.original.txt"

# ── Demonstrate the defect ───────────────────────────────────────────────
# After the baseline, never before: the generated test is meant to fail, and
# a baseline containing it would be red by construction and stop the run.
# Before patching, because a test written afterwards cannot show the defect
# was ever there.
stage "demonstrate"
run_phase "" --role exploit --osv "$osv_arg" --no-clone
exploit_status=$?
exploit_state="$(state_of "$OUT/exploit.json")"

if (( exploit_status != 0 )); then
  log "the defect could not be demonstrated (${exploit_state:-no document})"
  log "stopping: without it, an incomplete remediation cannot be told from a complete one"
  exit 1
fi

if [[ "$exploit_state" == "not-demonstrable" ]]; then
  log "no demonstration is possible here — the remediation will rest on non-regression evidence"
fi

# ── Patch and verify ─────────────────────────────────────────────────────
# Guarantee 3: at most MAX_PATCH_ATTEMPTS passes. A remediation still breaking
# behaviour after one informed correction is not converging.
attempt=1
while (( attempt <= MAX_PATCH_ATTEMPTS )); do
  stage "patch (attempt $attempt of $MAX_PATCH_ATTEMPTS)"
  run_phase "" --role patch --osv "$osv_arg" --no-clone
  if (( $? != 0 )); then
    log "patching failed — $(state_of "$OUT/patch.json")"
    exit 1
  fi

  cp "$OUT/baseline-tests.original.txt" "$OUT/baseline-tests.txt"

  stage "verify (attempt $attempt of $MAX_PATCH_ATTEMPTS)"
  run_phase "" --role verify --no-clone
  verify_status=$?
  verification_state="$(state_of "$OUT/verification.json")"

  if (( verify_status == 0 )); then
    stage "deliver"
    run_phase "" --role deliver --osv "$osv_arg" --no-clone
    if (( $? != 0 )); then
      log "verified but not delivered — $(state_of "$OUT/delivery.json")"
      log "the change is in $OUT and on the working tree; nothing was opened"
      exit 1
    fi
    stage "remediated, verified and delivered"
    exit 0
  fi

  if [[ "$verification_state" != "regression" ]]; then
    log "verification could not establish the evidence (${verification_state:-no document}) — not retried"
    exit 1
  fi

  if (( attempt == MAX_PATCH_ATTEMPTS )); then
    log "the regression persists after $MAX_PATCH_ATTEMPTS attempts; the evidence is in $OUT/verification.json"
    exit 1
  fi

  log "regression reported — returning it to patching once"
  (( attempt++ ))
done

exit 1
