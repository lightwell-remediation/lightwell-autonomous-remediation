#!/usr/bin/env bash
# generate-sbom.sh — rebuild the application's bill of materials after a
# remediation, so the inventory stops naming the version that was just fixed.
#
# The alert came from an inventory. A remediation that moves the dependency
# and leaves the inventory alone has not closed the loop: whatever re-scans
# the branch still sees the vulnerability, the alert fires again, and the
# pull request carries evidence against its own claim.
#
# Deterministic on purpose — this is a command, not a judgement, so it is a
# task rather than a session (docs/adr/0005-determinism-boundary.md).
#
# The flags match the workflow this replaces, deliberately. A different
# generator, or the same one configured differently, produces a document of a
# different shape: the diff then reads as a rewrite rather than as a version
# moving, and whatever consumes it downstream is no longer comparing like
# with like.
#
# Contract: specs/devsecops/pipeline.spec.md — The Inventory Is Regenerated
#           From the Remediated Build
#
# Usage:
#   generate-sbom.sh [<output-path>]      default: <repo>/sbom.json
#
# Exit status:
#   0  the inventory was rebuilt
#   1  the build or the scan failed
#   2  configuration error

set -uo pipefail

readonly EXIT_CONFIG=2

die() { printf 'generate-sbom: %s\n' "$*" >&2; exit "$EXIT_CONFIG"; }
log() { printf 'generate-sbom: %s\n' "$*" >&2; }

readonly WORKSPACE="${WORKSPACE:-/workspace}"
readonly REPO_DIR="${REPO_DIR:-$WORKSPACE/repo}"

[ -d "$REPO_DIR" ] || die "no checkout at $REPO_DIR"
[ -r "$REPO_DIR/pom.xml" ] || die "no pom.xml at $REPO_DIR — this build is not Maven"
command -v syft >/dev/null || die "syft is not installed"

OUTPUT="${1:-$REPO_DIR/sbom.json}"

# Only pass -s where the project ships one. A project without it resolves
# from whatever Maven is configured with, and inventing the flag would fail
# the build rather than fall back.
settings_args=()
[ -r "$REPO_DIR/settings.xml" ] && settings_args=(-s "$REPO_DIR/settings.xml")

mvn_q() {
  ( cd "$REPO_DIR" && mvn "${settings_args[@]}" -B -q \
      help:evaluate -Dexpression="$1" -DforceStdout 2>/dev/null )
}

artifact_id="$(mvn_q project.artifactId | tail -1 | tr -d '[:space:]')"
version="$(mvn_q project.version | tail -1 | tr -d '[:space:]')"
[ -n "$artifact_id" ] && [ -n "$version" ] \
  || die "cannot read the project's coordinates"
log "application $artifact_id version $version"

# Syft reads the built jar, not the manifest, so the remediated tree has to
# be compiled before it can be inventoried. Tests are skipped: verification
# has already run them, and running them again here would double the cost of
# the slowest phase to learn nothing new.
log "building (mvn -B -DskipTests package)"
if ! ( cd "$REPO_DIR" && mvn "${settings_args[@]}" -B -DskipTests package >/tmp/sbom-build.log 2>&1 ); then
  log "the build failed; last lines:"
  tail -20 /tmp/sbom-build.log >&2
  exit 1
fi

readonly JAR="$REPO_DIR/target/$artifact_id-$version.jar"
[ -r "$JAR" ] || { log "the build produced no jar at $JAR"; exit 1; }

log "scanning $(basename "$JAR")"
raw="$(mktemp)"
trap 'rm -f "$raw"' EXIT
if ! syft scan "file:$JAR" \
      -o cyclonedx-json@1.6 \
      --source-name "$artifact_id" \
      --source-version "$version" \
      --scope deep-squashed \
      --enrich java \
      --select-catalogers "+java-archive-cataloger" \
      >"$raw" 2>/tmp/sbom-scan.log; then
  log "the scan failed; last lines:"
  tail -20 /tmp/sbom-scan.log >&2
  exit 1
fi

# The workflow did this one assignment with jq. Node is already in the image
# for the output gates, so the transformation goes there rather than pulling
# in a package for a single line.
if ! node -e '
  const fs = require("fs");
  // node -e puts no script path in argv, so the first argument is at [1].
  const [, input, output] = process.argv;
  const sbom = JSON.parse(fs.readFileSync(input, "utf8"));
  sbom.metadata = sbom.metadata || {};
  sbom.metadata.component = sbom.metadata.component || {};
  sbom.metadata.component.type = "application";
  fs.writeFileSync(output, JSON.stringify(sbom, null, 2) + "\n");
' "$raw" "$OUTPUT"; then
  log "the inventory could not be written to $OUTPUT"
  exit 1
fi

components="$(node -e '
  const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  process.stdout.write(String((d.components || []).length));
' "$OUTPUT" 2>/dev/null)"

log "wrote $OUTPUT — ${components:-?} component(s)"
