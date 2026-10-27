#!/usr/bin/env bash
# build-runtime-image.sh — make sure the agent runtime image exists in the
# cluster, at the tag the remediation chart names.
#
# The runtime is versioned (agents.runtimeImage.version in bootstrap-infra),
# and the BuildConfig publishes it as lightwell-agent-runtime:<version>. The
# cluster builds it on its own once the base image exists, so on a fresh
# cluster this script usually finds the image already there and does nothing.
# It is for the cases where it is not: a version bump on a cluster that already
# ran the previous one (an image change trigger does not fire on a config
# change), or a build that failed.
#
# A version is never rebuilt with different contents: the chart pulls with
# IfNotPresent, so a node that cached the old layers would keep serving them.
# Change agent-runtime/ → bump the version (runtime-image-version skill).
#
# Usage:
#   build-runtime-image.sh               build the version if it is missing
#   build-runtime-image.sh --rebuild     build it again from the BuildConfig's ref
#   build-runtime-image.sh --from-dir    build the working tree as wip-<version>-<time>
#
# --from-dir uploads agent-runtime/ as the build context, so a runtime change
# can be exercised in the cluster before it is pushed anywhere. It builds
# through a temporary BuildConfig whose output is the wip- tag, so the version
# tag is never touched, and prints the run-remediation.sh --image line to try it.
#
# Exit status:
#   0  the image is in the cluster at the expected tag
#   1  the build failed, or the tag could not be read
#   2  configuration error

set -uo pipefail

readonly NAMESPACE="${NAMESPACE:-lightwell-agents}"
readonly BUILD_CONFIG="${BUILD_CONFIG:-lightwell-agent-runtime}"
readonly IMAGE_STREAM="${IMAGE_STREAM:-lightwell-agent-runtime}"
readonly REGISTRY="image-registry.openshift-image-registry.svc:5000/$NAMESPACE/$IMAGE_STREAM"

die() { printf 'build-runtime-image: %s\n' "$*" >&2; exit 2; }
log() { printf 'build-runtime-image: %s\n' "$*" >&2; }

MODE="ensure"
case "${1:-}" in
  "")          ;;
  --rebuild)   MODE="rebuild" ;;
  --from-dir)  MODE="from-dir" ;;
  # The previous interface built a ref into a <ref>-<sha> tag. A version tag
  # comes from the BuildConfig's own ref, so the argument has nothing to do.
  main)        log "the ref argument is gone: the BuildConfig builds main into the version tag" ;;
  -h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
  *)           die "unknown argument: $1 (see --help)" ;;
esac

command -v oc >/dev/null || die "oc is not installed"
oc whoami >/dev/null 2>&1 || die "not logged in to a cluster"

output="$(oc get bc "$BUILD_CONFIG" -n "$NAMESPACE" \
  -o jsonpath='{.spec.output.to.name}' 2>/dev/null)"
[ -n "$output" ] || die "no BuildConfig $BUILD_CONFIG in $NAMESPACE — make deploy-all first"
readonly VERSION="${output##*:}"

digest_of() {
  oc get istag "$IMAGE_STREAM:$1" -n "$NAMESPACE" \
    -o jsonpath='{.image.metadata.name}' 2>/dev/null
}

# Waits for a build to finish and prints its phase. Polled rather than
# followed: `oc logs -f` on a build still Pending can return at once.
wait_build() {
  local phase="" waited=0
  while [ "$waited" -lt 3600 ]; do
    phase="$(oc get -n "$NAMESPACE" "$1" -o jsonpath='{.status.phase}' 2>/dev/null)"
    case "$phase" in Complete|Failed|Error|Cancelled) break ;; esac
    sleep 10; waited=$(( waited + 10 ))
  done
  printf '%s' "$phase"
}

follow_failed() {
  log "the build failed; its log:"
  oc logs -n "$NAMESPACE" "$1" --tail=40 >&2 2>/dev/null
  exit 1
}

if [ "$MODE" = "from-dir" ]; then
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  short="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  TAG="wip-$VERSION-$(date +%H%M%S)"
  readonly TAG

  # A context containing only what the Containerfile copies, rather than the
  # repository. `oc start-build --from-dir` tars the whole directory and does
  # **not** honour .dockerignore, so it trips over .workspace/ — owned by the
  # container's mapped UID after any local run — and fails with a permission
  # error that reads like a cluster problem. Building from exactly the inputs
  # also means a stray local file cannot change what ships.
  context="$(mktemp -d)"
  tmp_bc="$BUILD_CONFIG-wip"
  trap 'rm -rf "$context"; oc delete bc "$tmp_bc" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1' EXIT
  mkdir -p "$context/agent-runtime"
  cp -r "$root/agent-runtime/." "$context/agent-runtime/" \
    || die "cannot assemble the build context"
  rm -rf "$context/agent-runtime/test"

  # The real BuildConfig with its output moved to the wip- tag and its
  # triggers removed: same base, same build arguments, and the version tag is
  # out of reach.
  oc get bc "$BUILD_CONFIG" -n "$NAMESPACE" -o json 2>/dev/null \
    | python3 -I -c '
import json, sys
bc = json.load(sys.stdin)
name, tag = sys.argv[1], sys.argv[2]
meta = bc["metadata"]
bc["metadata"] = {"name": name, "namespace": meta["namespace"], "labels": meta.get("labels", {})}
bc["spec"]["output"]["to"]["name"] = tag
bc["spec"]["triggers"] = []
bc.pop("status", None)
print(json.dumps(bc))
' "$tmp_bc" "$IMAGE_STREAM:$TAG" \
    | oc apply -n "$NAMESPACE" -f - >/dev/null \
    || die "cannot create the temporary BuildConfig $tmp_bc"

  log "building the working tree at $root (HEAD $short) as $TAG"
  # stderr kept: an upload failure has nothing to do with the build, and
  # swallowing it leaves you reading the *previous* build's log and
  # concluding the image did not change.
  build="$(oc start-build "$tmp_bc" -n "$NAMESPACE" --from-dir="$context" -o name)" \
    || die "could not start the build"
  [ "$(wait_build "$build")" = "Complete" ] || follow_failed "$build"

  digest="$(digest_of "$TAG")"
  [ -n "$digest" ] || { log "could not read the built image's digest"; exit 1; }
  printf '\n  built    working tree at %s\n  digest   %s\n  tag      %s:%s\n\n' \
    "$short" "$digest" "$IMAGE_STREAM" "$TAG" >&2
  printf 'Try it on one run (the Pipeline itself stays on the version ArgoCD sets):\n' >&2
  printf '  scripts/run-remediation.sh <record> --image %s:%s\n' "$REGISTRY" "$TAG" >&2
  exit 0
fi

if [ "$MODE" = "ensure" ] && [ -n "$(digest_of "$VERSION")" ]; then
  log "$IMAGE_STREAM:$VERSION is already built — nothing to do"
  log "the remediation chart's default points at it; no --set needed"
  exit 0
fi

# A build the cluster started on its own may still be running; follow it
# rather than starting a second build of the same thing.
running="$(oc get builds -n "$NAMESPACE" -l "buildconfig=$BUILD_CONFIG" \
  -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1)"
if [ "$MODE" = "ensure" ] && [ -n "$running" ]; then
  log "following $running, already building $VERSION"
  build="build/$running"
else
  log "building $IMAGE_STREAM:$VERSION from the BuildConfig's ref"
  build="$(oc start-build "$BUILD_CONFIG" -n "$NAMESPACE" -o name)" \
    || die "could not start the build"
fi
[ "$(wait_build "$build")" = "Complete" ] || follow_failed "$build"

digest="$(digest_of "$VERSION")"
[ -n "$digest" ] || { log "could not read the built image's digest"; exit 1; }
printf '\n  built    %s:%s\n  digest   %s\n' "$IMAGE_STREAM" "$VERSION" "$digest" >&2
printf '\nThe remediation chart already points at it; no --set needed.\n' >&2
