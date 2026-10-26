#!/usr/bin/env bash
# build-image.sh — build the agent runtime image.
#
# Two chained builds, because the Red Hat starter-kit image this runtime layers
# on cannot be redistributed (it contains Anthropic's proprietary binary), so
# there is no registry to pull it from. On OpenShift the same two steps are two
# chained BuildConfigs.
#
# Behavior contract: specs/platform/agent-runtime.spec.md
# Packaging decisions:  docs/adr/0003-agent-runtime-packaging-and-credentials.md
#
# Usage:
#   agent-runtime/build-image.sh                 # build both images
#   agent-runtime/build-image.sh --base-only     # stop after the upstream base
#   agent-runtime/build-image.sh --force         # rebuild the base even if present
#
# Exit status:
#   0  image built and the toolchain it needs is present
#   1  a build or the post-build check failed
#   2  bad arguments or a missing tool

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly REPO_ROOT="$SCRIPT_DIR/.."

die() { printf 'build-image: %s\n' "$*" >&2; exit "${2:-2}"; }
log() { printf 'build-image: %s\n' "$*" >&2; }

# Pinned so two builds a month apart produce the same image. Upstream is
# actively maintained; bump these deliberately, and re-run the validation in
# ADR-0003 when you do.
UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/red-hat-data-services/agentic-starter-kits.git}"
UPSTREAM_REF="${UPSTREAM_REF:-61d2ea8}"

# Upstream pins a Claude Code that predates --permission-prompts, which this
# runtime passes, so the version has to be set here rather than inherited.
# See docs/agent-runtime.md — Known limitations.
CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-2.1.295}"

BASE_IMAGE="${BASE_IMAGE:-localhost/upstream-claude-code:$CLAUDE_CODE_VERSION}"
IMAGE="${IMAGE:-localhost/lightwell-agent-runtime:latest}"
CHECKOUT="${CHECKOUT:-${XDG_CACHE_HOME:-$HOME/.cache}/lightwell/agentic-starter-kits}"

BASE_ONLY=0
FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-only) BASE_ONLY=1; shift ;;
    --force)     FORCE=1; shift ;;
    -h|--help)   sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)           die "unknown argument: $1" ;;
  esac
done

command -v podman >/dev/null || die "podman is not installed"
command -v git    >/dev/null || die "git is not installed"

# ── Upstream checkout ────────────────────────────────────────────────────
# Fetched at a pinned ref rather than tracking a branch, so the base image is
# reproducible. A shallow clone cannot be checked out at an arbitrary commit,
# hence the fetch-by-ref dance.
if [[ ! -d "$CHECKOUT/.git" ]]; then
  log "cloning upstream into $CHECKOUT"
  mkdir -p "$(dirname "$CHECKOUT")"
  git clone --quiet --filter=blob:none "$UPSTREAM_REPO" "$CHECKOUT"
fi

git -C "$CHECKOUT" fetch --quiet origin
git -C "$CHECKOUT" checkout --quiet --detach "$UPSTREAM_REF"
log "upstream at $(git -C "$CHECKOUT" rev-parse --short HEAD)"

readonly UPSTREAM_CTX="$CHECKOUT/agents/claude-code/deployment"
[[ -f "$UPSTREAM_CTX/Containerfile" ]] \
  || die "upstream layout changed: no Containerfile in $UPSTREAM_CTX"

# ── Base image ───────────────────────────────────────────────────────────
if (( FORCE )) || ! podman image exists "$BASE_IMAGE"; then
  log "building base $BASE_IMAGE (Claude Code $CLAUDE_CODE_VERSION)"
  podman build \
    --build-arg "CLAUDE_CODE_VERSION=$CLAUDE_CODE_VERSION" \
    -t "$BASE_IMAGE" \
    -f "$UPSTREAM_CTX/Containerfile" \
    "$UPSTREAM_CTX" || die "upstream base build failed" 1
else
  log "reusing base $BASE_IMAGE (--force to rebuild)"
fi

if (( BASE_ONLY )); then
  log "base ready: $BASE_IMAGE"
  exit 0
fi

# ── Runtime image ────────────────────────────────────────────────────────
log "building $IMAGE"
podman build \
  --build-arg "BASE_IMAGE=$BASE_IMAGE" \
  -t "$IMAGE" \
  -f "$SCRIPT_DIR/Containerfile" \
  "$REPO_ROOT" || die "runtime build failed" 1

# ── Post-build check ─────────────────────────────────────────────────────
# A missing build tool is not a permission denial and does not set is_error, so
# an agent that cannot run the project's tests would still end its session
# green. Catching it at build time is the only cheap place to catch it.
log "verifying the toolchain"
missing=0
for tool in claude git gh java mvn node; do
  if podman run --rm --entrypoint sh "$IMAGE" -c "command -v $tool" >/dev/null 2>&1; then
    printf '  %-6s ok\n' "$tool" >&2
  else
    printf '  %-6s MISSING\n' "$tool" >&2
    missing=1
  fi
done
(( missing == 0 )) || die "image is missing tools the permission allowlist grants" 1

log "built $IMAGE on $BASE_IMAGE"
