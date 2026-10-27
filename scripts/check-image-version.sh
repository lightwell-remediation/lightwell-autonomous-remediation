#!/usr/bin/env bash
# check-image-version.sh — hold the agent runtime's version to its contract.
#
# The runtime image is published as lightwell-agent-runtime:<version> and the
# pipeline pulls it with IfNotPresent, so a version must never name two
# different images: a node that cached the first would keep serving it. Two
# things make that true, and this checks both:
#
#   1. The version lives in one place, agents.runtimeImage.version in
#      bootstrap-infra, and is well formed. bootstrap-infra hands it to both the
#      image build and the remediation Pipeline, so neither chart may carry a
#      version of its own.
#   2. Against a base ref, anything that changes the image — agent-runtime/
#      outside its tests and docs, the image chart, or a pin in bootstrap-infra
#      — comes with a higher version.
#
# Usage:
#   check-image-version.sh [<base-ref>]     default origin/main
#
# Run by the runtime-image-version skill after a bump, and before opening a
# pull request that touches the runtime.
#
# Exit status:
#   0  consistent, and bumped where it had to be
#   1  a chart carries its own version, the version is malformed, or the image
#      changed without a bump

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly BASE="${1:-origin/main}"
readonly BOOTSTRAP="deploy/gitops/bootstrap-infra/values.yaml"
readonly IMAGE_CHART="deploy/gitops/deployments/agents/agent-runtime-image"
readonly PIPELINE_VALUES="deploy/gitops/deployments/agents/remediation-pipeline/values.yaml"

pass=0
fail=0
ok()  { printf '  ok    %s\n' "$1"; (( pass++ )); }
nok() { printf '  FAIL  %s\n' "$1"; (( fail++ )); }

# The readers take the file content on stdin, so the same parsing reads the
# working tree and the base ref.
bootstrap_version() { awk '/^  runtimeImage:/{r=1; next} r && /^  [^ #]/{r=0} r && $1=="version:"{gsub(/"/,"",$2); print $2; exit}'; }
chart_version()     { awk '$1=="runtimeVersion:"{gsub(/"/,"",$2); print $2; exit}'; }
pipeline_version()  { awk '$1=="agent:" && /lightwell-agent-runtime:/{sub(/.*lightwell-agent-runtime:/,""); print; exit}'; }

at_base() { git -C "$ROOT" show "$BASE:$1" 2>/dev/null; }

semver_gt() {  # is $1 > $2, both MAJOR.MINOR.PATCH
  local -a a b
  local i
  IFS=. read -ra a <<<"$1"
  IFS=. read -ra b <<<"$2"
  for i in 0 1 2; do
    (( 10#${a[i]} > 10#${b[i]} )) && return 0
    (( 10#${a[i]} < 10#${b[i]} )) && return 1
  done
  return 1
}

printf 'runtime image version\n'

v_bootstrap="$(bootstrap_version <"$ROOT/$BOOTSTRAP")"
v_chart="$(chart_version <"$ROOT/$IMAGE_CHART/values.yaml")"
v_pipeline="$(pipeline_version <"$ROOT/$PIPELINE_VALUES")"

if [[ "$v_bootstrap" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  ok "version $v_bootstrap ($BOOTSTRAP)"
else
  nok "agents.runtimeImage.version in $BOOTSTRAP is '${v_bootstrap:-missing}', expected MAJOR.MINOR.PATCH"
fi
# A second copy is how the three used to drift apart; keep them out.
if [[ -z "$v_chart" ]]; then
  ok "agent-runtime-image chart carries no version of its own"
else
  nok "runtimeVersion in $IMAGE_CHART/values.yaml is '$v_chart'; leave it empty, bootstrap-infra sets it"
fi
if [[ -z "$v_pipeline" ]]; then
  ok "remediation chart carries no image tag of its own"
else
  nok "image.agent in $PIPELINE_VALUES is tagged '$v_pipeline'; leave it empty, bootstrap-infra sets it"
fi

if ! git -C "$ROOT" rev-parse --verify --quiet "$BASE" >/dev/null; then
  printf '  skip  no %s to compare against, bump not checked\n' "$BASE"
else
  base_version="$(at_base "$BOOTSTRAP" | bootstrap_version)"
  # What goes into the image: our layer, the chart that builds it, and the
  # pins bootstrap-infra hands that chart. Tests and docs are not copied in.
  changed="$(git -C "$ROOT" diff --name-only "$BASE" -- \
               agent-runtime "$IMAGE_CHART" \
               ':(exclude)agent-runtime/test/**' ':(exclude)agent-runtime/**/*.md' \
               ':(exclude)agent-runtime/*.md' 2>/dev/null)"
  pins_changed="$(diff <(at_base "$BOOTSTRAP" | awk '/^  runtimeImage:/{r=1; next} r && /^  [^ #]/{r=0} r && /^ +(claudeCodeVersion|ghVersion|upstreamRepo|upstreamRef|appRepo|appRepoRef):/') \
                       <(awk '/^  runtimeImage:/{r=1; next} r && /^  [^ #]/{r=0} r && /^ +(claudeCodeVersion|ghVersion|upstreamRepo|upstreamRef|appRepo|appRepoRef):/' "$ROOT/$BOOTSTRAP"))"

  if [[ -z "$changed" && -z "$pins_changed" ]]; then
    ok "nothing in the image changed since $BASE"
  elif [[ -z "$base_version" ]]; then
    ok "image changed since $BASE, which predates versioning; $v_bootstrap is the first version"
  elif semver_gt "$v_bootstrap" "$base_version"; then
    ok "image changed since $BASE and the version moved $base_version → $v_bootstrap"
  else
    nok "image changed since $BASE but the version is still $v_bootstrap — bump it (runtime-image-version skill):"
    [[ -n "$changed" ]] && printf '        %s\n' $changed
    [[ -n "$pins_changed" ]] && printf '        a pin in %s\n' "$BOOTSTRAP"
  fi
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
