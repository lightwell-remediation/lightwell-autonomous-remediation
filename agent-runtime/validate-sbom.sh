#!/usr/bin/env bash
# validate-sbom.sh — send the regenerated inventory to Trusted Profile
# Analyzer and record what it says about the vulnerability the run started
# from, next to what it says about the inventory being replaced.
#
# The alert came from an inventory, so the remediation is answered by one: TPA
# reading the branch's bill of materials and no longer reporting the defect.
# Done before delivery so the result is in the pull request while the change
# can still be rejected.
#
# Never fatal on TPA's account. An unreachable service leaves a document
# saying so, and delivery states it in the pull request; withholding a
# verified fix because a second system is down would make that system a gate
# it was never meant to be. TPA still reporting the vulnerability is not
# hidden either — it goes to the reviewer as a warning.
#
# Deterministic: an upload and two queries (docs/adr/0005-determinism-boundary.md).
#
# Contract: specs/devsecops/pipeline.spec.md — Validated Before Merge
#
# Usage:
#   validate-sbom.sh
#
# Environment:
#   APPLICATION     owner/repo, the label the baseline was registered under
#   APP_BRANCH      the branch remediated; prefers a baseline of that ref
#   RUN_NAME        labels the upload, so an inventory leads back to its run
#   TPA_URL, TPA_TOKEN_URL, TPA_CLIENT_ID, TPA_CLIENT_SECRET — see tpa.sh
#
# Exit status:
#   0  a verdict was recorded, or there was nothing to validate
#   2  configuration error

set -uo pipefail

readonly EXIT_CONFIG=2

die() { printf 'validate-sbom: %s\n' "$*" >&2; exit "$EXIT_CONFIG"; }
log() { printf 'validate-sbom: %s\n' "$*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly WORKSPACE="${WORKSPACE:-/workspace}"
readonly REPO_DIR="${REPO_DIR:-$WORKSPACE/repo}"
readonly OUT_DIR="${OUT_DIR:-$WORKSPACE/out}"
readonly TPA="${TPA:-$SCRIPT_DIR/tpa.sh}"
readonly VERDICT="${TPA_VERDICT:-$SCRIPT_DIR/lib/tpa-verdict.js}"
readonly SBOM="$REPO_DIR/sbom.json"
readonly RESULT="$OUT_DIR/tpa.json"

# Optional by design: a replicator without an instance runs the whole
# pipeline, and the pull request simply carries no TPA section.
if [ -z "${TPA_URL:-}" ]; then
  log "no TPA configured (the lightwell-tpa Secret is absent) — not validating"
  exit 0
fi
[ -r "$SBOM" ] || { log "no regenerated inventory at $SBOM — nothing to validate"; exit 0; }
[ -n "${APPLICATION:-}" ] || die "APPLICATION is not set"
mkdir -p "$OUT_DIR"

not_validated() {
  log "not validated: $1"
  node -e '
    require("fs").writeFileSync(process.argv[1],
      JSON.stringify({ validated: false, reason: process.argv[2] }, null, 2) + "\n");
  ' "$RESULT" "$1"
  exit 0
}

vulnerability="$(node -e '
  try {
    const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    process.stdout.write(String((d.vulnerability && d.vulnerability.id) || ""));
  } catch {}
' "$OUT_DIR/analysis.json")"
[ -n "$vulnerability" ] || not_validated "the analysis names no vulnerability to look for"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

labels=("app=$APPLICATION" "role=remediated")
[ -n "${RUN_NAME:-}" ] && labels+=("run=$RUN_NAME")
[ -n "${APP_BRANCH:-}" ] && labels+=("ref=$APP_BRANCH")

log "uploading $(basename "$SBOM") for $APPLICATION"
"$TPA" upload "$SBOM" "${labels[@]}" >"$tmp/ingest.json" 2>"$tmp/err" \
  || not_validated "TPA refused the upload — $(tail -1 "$tmp/err")"
sbom_id="$(node -e '
  try { process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).id || "")); } catch {}
' "$tmp/ingest.json")"
[ -n "$sbom_id" ] || not_validated "TPA accepted the upload but returned no id"
log "ingested as $sbom_id"

"$TPA" advisories "$sbom_id" >"$tmp/remediated.json" 2>"$tmp/err" \
  || not_validated "TPA did not report on $sbom_id — $(tail -1 "$tmp/err")"

# The baseline is what onboarding registered (scripts/tpa-onboard.sh). One of
# the remediated ref first; any of the application's after that.
baseline=()
found=""
if [ -n "${APP_BRANCH:-}" ]; then
  found="$("$TPA" find "app=$APPLICATION" "role=baseline" "ref=$APP_BRANCH" 2>/dev/null)"
fi
[ -n "$found" ] || found="$("$TPA" find "app=$APPLICATION" "role=baseline" 2>/dev/null)"
if [ -n "$found" ]; then
  baseline_id="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).id)' "$found")"
  if "$TPA" advisories "$baseline_id" >"$tmp/baseline.json" 2>/dev/null; then
    baseline=("$baseline_id" "$tmp/baseline.json")
    log "baseline $baseline_id"
  fi
else
  log "no baseline registered for $APPLICATION — run scripts/tpa-onboard.sh"
fi

node "$VERDICT" "$vulnerability" "$TPA_URL" "$sbom_id" "$tmp/remediated.json" "${baseline[@]}" \
  >"$RESULT" || not_validated "TPA's answer could not be read"

node -e '
  const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const b = d.baseline ? `${d.baseline.state} before, ` : "";
  console.error(`validate-sbom: ${d.vulnerability}: ${b}${d.remediated.state} on this branch`);
' "$RESULT"
