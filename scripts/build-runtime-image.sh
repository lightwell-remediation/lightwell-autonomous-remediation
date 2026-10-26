#!/usr/bin/env bash
# build-runtime-image.sh — build the agent runtime in the cluster, at a tag
# that names what was built.
#
# The BuildConfig writes to a fixed tag and overwrites it on every build, so
# pinning that tag only looks like pinning: with the default IfNotPresent a
# node keeps serving the layer it cached first and a rebuild changes nothing.
# This tags the result `<ref>-<short-sha>` as well, which is a name that is
# never reused, and prints the values override that points the chart at it.
#
# The BuildConfig is also pinned to a branch that is not main, so the ref has
# to be passed on every build rather than configured once.
#
# Usage:
#   build-runtime-image.sh [<git-ref>]      build a pushed ref, default main
#   build-runtime-image.sh --from-dir       build the working tree as it is
#
# --from-dir uploads the local directory as the build context, so a runtime
# change can be exercised in the cluster before it is pushed anywhere. Its
# tag carries a timestamp, because a working tree is not content-addressed
# and the tag's only job is to never be reused.
#
# Exit status:
#   0  the build completed and the immutable tag points at it
#   1  the build failed, or the tag could not be created
#   2  configuration error

set -uo pipefail

readonly NAMESPACE="${NAMESPACE:-lightwell-agents}"
readonly BUILD_CONFIG="${BUILD_CONFIG:-lightwell-agent-runtime}"
readonly IMAGE_STREAM="${IMAGE_STREAM:-lightwell-agent-runtime}"
readonly REF="${1:-main}"

die() { printf 'build-runtime-image: %s\n' "$*" >&2; exit 2; }
log() { printf 'build-runtime-image: %s\n' "$*" >&2; }

command -v oc >/dev/null || die "oc is not installed"
oc whoami >/dev/null 2>&1 || die "not logged in to a cluster"

repository="$(oc get bc "$BUILD_CONFIG" -n "$NAMESPACE" \
  -o jsonpath='{.spec.source.git.uri}' 2>/dev/null)"
[ -n "$repository" ] || die "no BuildConfig $BUILD_CONFIG in $NAMESPACE"

if [ "$REF" = "--from-dir" ]; then
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  short="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  readonly TAG="wip-$short-$(date +%H%M%S)"

  # A context containing only what the Containerfile copies, rather than the
  # repository. `oc start-build --from-dir` tars the whole directory and does
  # **not** honour .dockerignore, so it trips over .workspace/ — owned by the
  # container's mapped UID after any local run — and fails with a permission
  # error that reads like a cluster problem. Building from exactly the inputs
  # also means a stray local file cannot change what ships.
  context="$(mktemp -d)"
  trap 'rm -rf "$context"' EXIT
  mkdir -p "$context/agent-runtime"
  cp -r "$root/agent-runtime/." "$context/agent-runtime/" \
    || die "cannot assemble the build context"
  rm -rf "$context/agent-runtime/test"

  log "building the working tree at $root (HEAD $short)"
  # stderr kept: an upload failure has nothing to do with the build, and
  # swallowing it leaves you reading the *previous* build's log and
  # concluding the image did not change.
  oc start-build "$BUILD_CONFIG" -n "$NAMESPACE" --from-dir="$context" --follow >/dev/null
  built=$?
else
  # Resolve the ref to a commit here rather than trusting the branch to stay
  # put: the tag has to name a specific tree, not whatever main was when
  # someone read this.
  sha="$(git ls-remote "$repository" "refs/heads/$REF" 2>/dev/null | cut -f1)"
  [ -n "$sha" ] || die "cannot resolve $REF in $repository"
  short="${sha:0:7}"
  readonly TAG="$REF-$short"

  log "building $REF at $short"
  oc start-build "$BUILD_CONFIG" -n "$NAMESPACE" --commit="$sha" --follow >/dev/null 2>&1
  built=$?
fi

if [ "$built" -ne 0 ]; then
  log "the build failed; last build's logs:"
  oc logs -n "$NAMESPACE" "bc/$BUILD_CONFIG" --tail=40 >&2 2>/dev/null
  exit 1
fi

# The BuildConfig's output tag, whatever it is called, now points at what was
# just built. Read the digest from it and give that digest a name of its own.
output="$(oc get bc "$BUILD_CONFIG" -n "$NAMESPACE" \
  -o jsonpath='{.spec.output.to.name}' 2>/dev/null)"
output_tag="${output##*:}"

digest="$(oc get istag "$IMAGE_STREAM:$output_tag" -n "$NAMESPACE" \
  -o jsonpath='{.image.metadata.name}' 2>/dev/null)"
[ -n "$digest" ] || { log "could not read the built image's digest"; exit 1; }

oc tag "$NAMESPACE/$IMAGE_STREAM@$digest" "$NAMESPACE/$IMAGE_STREAM:$TAG" >/dev/null 2>&1 \
  || { log "could not create the tag $TAG"; exit 1; }

registry="image-registry.openshift-image-registry.svc:5000/$NAMESPACE/$IMAGE_STREAM"

printf '\n'
printf '  built    %s at %s\n' "$REF" "$short" >&2
printf '  digest   %s\n' "$digest" >&2
printf '  tag      %s:%s\n' "$IMAGE_STREAM" "$TAG" >&2
printf '\n' >&2
printf 'Point the chart at it:\n' >&2
printf '  helm upgrade --install remediation-pipeline \\\n' >&2
printf '    deploy/gitops/deployments/agents/remediation-pipeline \\\n' >&2
printf '    --namespace %s --set image.agent=%s:%s\n' "$NAMESPACE" "$registry" "$TAG" >&2
printf '\nOr set it in values.yaml:\n  %s:%s\n' "$registry" "$TAG" >&2
