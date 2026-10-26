#!/usr/bin/env bash
# sync-demo.sh — Publish the sample application into the repository the agent clones.
#
# The sample repository documents the vulnerability it carries: the affected component,
# the CVEs and the remediated version. An agent that reads that README does not solve
# the task, it copies the answer. This script republishes the sample with that block
# removed, so the agent has to derive the finding from the SBOM instead.
#
# Content sync, not a fork. A fork shares its object store with the parent, so every
# commit of the documented repository stays reachable from the fork — and the agent is
# allowed to run `git log`, `git diff` and `git checkout`. Here each commit of the demo
# repository is built from an already-filtered tree, so no revision of it ever carries
# the ground truth.
#
# Decision record: docs/adr/0004-demo-repository-ground-truth-isolation.md
#
# Usage:
#   sync-demo.sh                       sync SOURCE_REPO into DEMO_REPO and push
#   sync-demo.sh --dry-run             build and check the tree, push nothing
#   sync-demo.sh --source owner/repo --demo owner/repo
#   sync-demo.sh --source-ref <branch> publish that branch of the source
#   sync-demo.sh --demo-branch <name>  publish onto that branch of the demo
#
# Exit status:
#   0  demo repository updated, or already up to date
#   1  the filtered tree still leaks the ground truth, or the markers are unbalanced
#   2  configuration error (missing tool, bad arguments)

set -euo pipefail

readonly EXIT_LEAK=1
readonly EXIT_CONFIG=2

readonly MARKER_START='demo:strip-start'
readonly MARKER_END='demo:strip-end'

# What must never reach the demo repository: the Lightwell remediated qualifier and any
# CVE identifier. The guard is deliberately broader than the markers — a new hint added
# to the sample without markers must fail the sync, not travel silently.
readonly LEAK_PATTERN='rhlw-|RHLW-|CVE-[0-9]{4}-[0-9]+|packages\.redhat\.com|predisclosure'

# Paths that exist legitimately in the sample and must not be published.
#
# The markers handle a block inside a file. This handles a whole file whose
# problem is not what it says but where it would run — nothing is stripped
# from it, it simply does not belong downstream.
#
# .github/workflows/sbom.yml regenerates the bill of materials on a pom.xml
# push. In the sample that is correct and it builds, because nothing
# remediates that repository and its manifest stays on versions Maven
# Central publishes. In the demo repository it is wrong twice over: it
# builds without -s settings.xml, so it cannot resolve the vendor rebuild a
# remediation introduces and goes red on exactly the pull requests this
# project exists to produce; and the pipeline now writes that file itself,
# so publishing a second producer means the two overwrite each other.
readonly NOT_PUBLISHED=(
  ".github/workflows/sbom.yml"
)

# $1 is the message, $2 the optional exit code — printing "$*" would append the code to it.
die() { printf 'sync-demo: %s\n' "$1" >&2; exit "${2:-$EXIT_CONFIG}"; }
log() { printf 'sync-demo: %s\n' "$*" >&2; }

SOURCE_REPO="${SOURCE_REPO:-lightwell-remediation/lw-apache-cxf-sample}"
DEMO_REPO="${DEMO_REPO:-lightwell-remediation/lw-apache-cxf-demo}"
SOURCE_REF=""
DEMO_BRANCH=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)       SOURCE_REPO="${2:?--source needs a value}"; shift 2 ;;
    --demo)         DEMO_REPO="${2:?--demo needs a value}";     shift 2 ;;
    --source-ref)   SOURCE_REF="${2:?--source-ref needs a value}"; shift 2 ;;
    --demo-branch)  DEMO_BRANCH="${2:?--demo-branch needs a value}"; shift 2 ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)      sed -n '2,30p' "$0"; exit 0 ;;
    *)              die "unknown argument: $1" ;;
  esac
done

command -v git >/dev/null || die "git not found"
command -v gh  >/dev/null || die "gh not found"

WORK_DIR="$(mktemp -d)"
readonly WORK_DIR
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# ── Fetch both sides ─────────────────────────────────────────────────────
# The source is cloned shallow on purpose: only its current tree is ever published,
# never its history.
log "cloning $SOURCE_REPO${SOURCE_REF:+ at $SOURCE_REF} (shallow)"
gh repo clone "$SOURCE_REPO" "$WORK_DIR/src" -- --quiet --depth 1 \
  ${SOURCE_REF:+--branch "$SOURCE_REF"} >/dev/null

log "cloning $DEMO_REPO"
gh repo clone "$DEMO_REPO" "$WORK_DIR/demo" -- --quiet >/dev/null

# Publishing onto a branch rather than the default one. Work that is not ready
# for the demo's main line — a fixture still being tried out, a change waiting
# on review in the source repository — can be taken across and run against
# without committing the demo to it.
if [[ -n "$DEMO_BRANCH" ]]; then
  if git -C "$WORK_DIR/demo" rev-parse --verify -q "origin/$DEMO_BRANCH" >/dev/null; then
    git -C "$WORK_DIR/demo" checkout --quiet "$DEMO_BRANCH"
  else
    git -C "$WORK_DIR/demo" checkout --quiet -b "$DEMO_BRANCH"
  fi
  log "publishing onto branch $DEMO_BRANCH"
fi

SOURCE_SHA="$(git -C "$WORK_DIR/src" rev-parse --short HEAD)"
readonly SOURCE_SHA

# ── Replace the demo tree with the source tree ───────────────────────────
find "$WORK_DIR/demo" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
git -C "$WORK_DIR/src" archive HEAD | tar -x -C "$WORK_DIR/demo"

# ── Drop what is not published ───────────────────────────────────────────
for path in "${NOT_PUBLISHED[@]}"; do
  if [[ -e "$WORK_DIR/demo/$path" ]]; then
    rm -rf "${WORK_DIR:?}/demo/$path"
    log "not published: $path"
    # An empty .github/workflows left behind is litter a reader wonders
    # about, so the directories go too once nothing remains in them.
    dir="$(dirname "$WORK_DIR/demo/$path")"
    while [[ "$dir" != "$WORK_DIR/demo" ]] && rmdir "$dir" 2>/dev/null; do
      dir="$(dirname "$dir")"
    done
  fi
done

# ── Strip every marked block ─────────────────────────────────────────────
# -I skips binaries, so a jar or an image in the tree cannot break the scan.
mapfile -t marked < <(grep -rlI "$MARKER_START" "$WORK_DIR/demo" --exclude-dir=.git || true)

if (( ${#marked[@]} == 0 )); then
  log "warning: no $MARKER_START marker found in $SOURCE_REPO"
fi

for file in "${marked[@]}"; do
  starts="$(grep -c "$MARKER_START" "$file" || true)"
  ends="$(grep -c "$MARKER_END" "$file" || true)"
  [[ "$starts" == "$ends" ]] || die \
    "unbalanced markers in ${file#"$WORK_DIR/demo/"}: $starts $MARKER_START, $ends $MARKER_END" \
    "$EXIT_LEAK"

  awk -v s="$MARKER_START" -v e="$MARKER_END" '
    index($0, s) { stripping = 1 }
    !stripping   { print }
    index($0, e) { stripping = 0 }
  ' "$file" > "$file.stripped"
  mv "$file.stripped" "$file"

  # A file whose every line was inside the markers has nothing left to say.
  # Leaving an empty .java behind is litter that a reader will wonder about,
  # so it goes rather than being published as zero bytes.
  if [[ ! -s "$file" ]] || ! grep -q '[^[:space:]]' "$file"; then
    rm -f "$file"
    log "removed ${file#"$WORK_DIR/demo/"} — stripped empty"
    continue
  fi

  log "stripped $starts block(s) from ${file#"$WORK_DIR/demo/"}"
done

# ── Guard ────────────────────────────────────────────────────────────────
# Runs against the tree that is about to be committed, not against the source.
if leaks="$(grep -rInIE "$LEAK_PATTERN" "$WORK_DIR/demo" --exclude-dir=.git)"; then
  printf '%s\n' "$leaks" | sed "s|$WORK_DIR/demo/||" >&2
  die "filtered tree still contains the ground truth — wrap it in $MARKER_START/$MARKER_END" \
    "$EXIT_LEAK"
fi
log "guard passed: no CVE or rhlw- reference in the filtered tree"

# ── Publish ──────────────────────────────────────────────────────────────
git -C "$WORK_DIR/demo" add -A

# An empty demo repository has no HEAD to diff against: the first sync always commits.
if git -C "$WORK_DIR/demo" rev-parse --verify -q HEAD >/dev/null \
  && git -C "$WORK_DIR/demo" diff --cached --quiet; then
  log "already up to date with $SOURCE_REPO@$SOURCE_SHA"
  exit 0
fi

git -C "$WORK_DIR/demo" diff --cached --stat >&2

if (( DRY_RUN )); then
  log "dry run — nothing pushed"
  exit 0
fi

# The message is deliberately terse. `git log` is on the agent's allowlist, so anything
# written here is something the agent reads: naming the upstream repository, or saying
# that a block was removed, tells it that content is being withheld. The short SHA is
# enough for the team to trace a sync back to its source.
git -C "$WORK_DIR/demo" commit -q -m "chore: publish sample application at $SOURCE_SHA"
# The destination is always named. `HEAD:HEAD` reads like "the branch I am
# on", but git takes the right-hand side literally and creates a branch called
# HEAD on the remote, leaving the default branch untouched — which is what a
# sync without --demo-branch did on 2026-10-23.
target="$DEMO_BRANCH"
[[ -n "$target" ]] || target="$(git -C "$WORK_DIR/demo" symbolic-ref --short refs/remotes/origin/HEAD | sed 's|^origin/||')"
[[ -n "$target" ]] || die "cannot tell the default branch of $DEMO_REPO" "$EXIT_CONFIG"
git -C "$WORK_DIR/demo" push -q origin "HEAD:refs/heads/$target"
log "pushed $SOURCE_REPO${SOURCE_REF:+#$SOURCE_REF}@$SOURCE_SHA to $DEMO_REPO#$target"
