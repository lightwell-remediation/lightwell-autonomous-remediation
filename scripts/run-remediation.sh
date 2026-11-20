#!/usr/bin/env bash
# run-remediation.sh — start a real remediation run in the cluster.
#
# The counterpart to test-pipeline.sh: same Pipeline, real sessions. This one
# spends money and opens a pull request.
#
# The vulnerability record is given one of three ways:
#
#   a file          mounted as a ConfigMap: no network, and the same record
#                   replays later. A public record committed here goes this way.
#   a URL           fetched in the cluster by the first phase, with the
#                   Lightwell credentials where they are set. The agent never
#                   sees them.
#   a Lightwell id  RHLW-2026-2d8697b26ccd16c3 — turned into a URL under
#                   LW_OSV_BASE_URL from the lightwell-lightwell Secret, and
#                   fetched as above. Lightwell names records by hash now, so
#                   the id no longer carries the CVE: pass --vulnerability. The
#                   older x_RHLW-CVE-2026-68079-4.2.2 form still works and its
#                   CVE becomes --vulnerability. scripts/find-lightwell-record.sh
#                   finds the id for a CVE.
#   an OSV id       GHSA-hfrx-6qgj-fp6c, or a file named after one that is not
#                   on disk — fetched from the public OSV registry
#                   (OSV_API_URL, osv.dev by default), no credentials.
#
# Usage:
#   run-remediation.sh <osv-file|url|lightwell-id|osv-id> [--vulnerability <id>]
#                      [--repo <owner/repo>] [--branch <name>] [--model <id>]
#                      [--image <ref>] [--no-follow]
#
# --repo names the application to remediate. Default: APP_REPO from the
# lightwell-github Secret. Runs against different repositories may run at the
# same time — one per application, the lock refuses a second (ADR-0011) — so
# one advisory reaching several applications is several invocations:
#
#   for app in acme/orders acme/billing; do
#     run-remediation.sh GHSA-hfrx-6qgj-fp6c --repo "$app" --no-follow
#   done
#
# Each application may have its own token, in the Secret
# lightwell-github-<owner>-<repo> (the name is printed when the run starts).
# Where the GitHub App is configured (secrets/github-app.env) a token scoped to
# that one repository is minted into it first; otherwise create it with a
# token of your own, e.g. a fine-grained PAT, from stdin:
#
#   oc create secret generic lightwell-github-acme-orders -n lightwell-agents \
#     --from-file=GITHUB_TOKEN=/dev/stdin
#
# An application without one uses the token in lightwell-github, which then
# has to reach it (ADR-0011).
#
# --image runs this one remediation on another runtime image, typically a
# wip- build from build-runtime-image.sh --from-dir. The Pipeline's own image
# is ArgoCD's to set (agents.runtimeImage.version), so a change to try goes
# here rather than into the chart.
#
# --vulnerability names the vulnerability the run is for when the record
# bundles several fixed by one release, as Lightwell advisories do.
#
# --branch picks which branch of the application to remediate, and so which
# branch the pull request is opened against. The demo fixture, where the
# vulnerable code is actually reachable, lives on a branch of its own.
#
# Examples:
#   run-remediation.sh RHLW-2026-2d8697b26ccd16c3 --vulnerability CVE-2026-68079
#   run-remediation.sh deploy/pipelineruns/osv/GHSA-hfrx-6qgj-fp6c.json
#
# Exit status:
#   0  remediated, verified and delivered (or nothing needed doing)
#   1  the run did not complete
#   2  configuration error

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly NAMESPACE="${NAMESPACE:-lightwell-agents}"
readonly CACHE_CLAIM="${CACHE_CLAIM:-lightwell-maven-cache}"
readonly SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-lightwell-agent}"
readonly CLAIM_ACCOUNT="${CLAIM_ACCOUNT:-lightwell-run-claim}"
readonly TRACE_ACCOUNT="${TRACE_ACCOUNT:-lightwell-tracer}"

# The trace task runs under the tracer's identity only where the chart created
# one, which it does when a backend that needs it is selected (ADR-0010).
# Elsewhere it runs as the agent and sends nothing.
trace_spec=""
if oc get serviceaccount "$TRACE_ACCOUNT" -n "$NAMESPACE" >/dev/null 2>&1; then
  trace_spec="
    - pipelineTaskName: trace
      serviceAccountName: $TRACE_ACCOUNT"
fi
readonly STATUS_DIR="$SCRIPT_DIR/../.agent-status"
readonly OSV_API_URL="${OSV_API_URL:-https://api.osv.dev/v1/vulns}"

die() { printf 'run-remediation: %s\n' "$*" >&2; exit 2; }
log() { printf 'run-remediation: %s\n' "$*" >&2; }

OSV=""
MODEL=""
IMAGE=""
VULNERABILITY=""
REPO=""
BRANCH="${APP_BRANCH:-}"
FOLLOW=1
while [ $# -gt 0 ]; do
  case "$1" in
    --model)     MODEL="${2:?--model needs a value}"; shift 2 ;;
    --image)     IMAGE="${2:?--image needs a value}"; shift 2 ;;
    --branch)    BRANCH="${2:?--branch needs a value}"; shift 2 ;;
    --repo)      REPO="${2:?--repo needs a value}"; shift 2 ;;
    --vulnerability) VULNERABILITY="${2:?--vulnerability needs a value}"; shift 2 ;;
    --no-follow) FOLLOW=0; shift ;;
    -h|--help)   sed -n '2,70p' "$0"; exit 0 ;;
    -*)          die "unknown argument: $1" ;;
    *)           OSV="$1"; shift ;;
  esac
done

[ -n "$OSV" ] || die "a vulnerability record is required"
command -v oc >/dev/null || die "oc is not installed"
oc whoami >/dev/null 2>&1 || die "not logged in to a cluster"

# A GitHub App installation token lasts one hour, and a run can start long after
# the one that minted it. With the App configured and no --repo, mint a fresh one
# for the APP_REPO in secrets.env and update the Secret. A --repo run gets a
# token of its own instead, minted below into its application's Secret.
if [ -z "$REPO" ] && [ -r "$(dirname "${BASH_SOURCE[0]}")/../secrets/github-app.env" ]; then
  "$(dirname "${BASH_SOURCE[0]}")/provision-app-repo.sh" --refresh \
    || die "could not refresh the GitHub token (scripts/provision-app-repo.sh --refresh)"
fi

# The application is the request's, or the Secret's default. Either way it is
# one value, and both the lock label and the repository param are derived from
# it below, so the run cannot lock one application and clone another.
application="$REPO"
if [ -z "$application" ]; then
  application="$(oc get secret lightwell-github -n "$NAMESPACE" \
    -o go-template='{{index .data "APP_REPO" | base64decode}}' 2>/dev/null)"
  [ -n "$application" ] || die "no --repo given and APP_REPO is not set in the lightwell-github Secret"
fi
[[ "$application" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || die "the repository must be owner/repo, not: $application"

# Which Secret every phase takes its GITHUB_TOKEN from (ADR-0011): the
# application's own when it has one, the deployment's default otherwise. Only
# a --repo run looks for its own: without --repo the run is the default
# application, whose token lightwell-github already holds.
github_secret="lightwell-github"
if [ -n "$REPO" ]; then
  # Not truncated: a Secret name may be 253 characters and owner/repo fits in
  # 140, while cutting it would give two repositories that share a prefix the
  # same Secret.
  own_secret="lightwell-github-$(printf '%s' "$application" | tr 'A-Z/_' 'a-z--' \
    | tr -c 'a-z0-9.-' '-' | sed 's/[-.]*$//')"
  if [ -r "$SCRIPT_DIR/../secrets/github-app.env" ]; then
    "$SCRIPT_DIR/provision-app-repo.sh" --repo "$application" --secret "$own_secret" \
      || die "could not mint a token for $application (scripts/provision-app-repo.sh --repo $application --secret $own_secret)"
  fi
  if oc get secret "$own_secret" -n "$NAMESPACE" >/dev/null 2>&1; then
    github_secret="$own_secret"
  else
    log "no Secret $own_secret — this run uses the token in lightwell-github, which must reach $application"
  fi
fi

for required in lightwell-maas lightwell-github; do
  oc get secret "$required" -n "$NAMESPACE" >/dev/null 2>&1 \
    || die "missing Secret $required — run scripts/push-secrets.sh"
done
# Only an application that builds against the Lightwell repository needs it,
# and without it that build fails in a way that reads like a bad patch.
oc get secret lightwell-lightwell -n "$NAMESPACE" >/dev/null 2>&1 \
  || echo "run-remediation: no lightwell-lightwell Secret — fine for an application on Maven Central only" >&2

# Which form. A file wins over anything that merely looks like an id, so a
# record saved under its own name still mounts; one that is not on disk is
# fetched from the registry it was published in.
osv_id="$(basename "$OSV" .json)"
case "$OSV" in
  http://*|https://*) source_kind="url" ;;
  *) if [ -e "$OSV" ]; then source_kind="file"
     elif [[ "$OSV" =~ ^(x_)?RHLW-[A-Za-z0-9.-]+$ ]]; then source_kind="lightwell"
     elif [[ "$osv_id" =~ ^[A-Z][A-Za-z0-9]*-[A-Za-z0-9.-]+$ ]]; then
       log "$OSV is not on disk — fetching $osv_id from $OSV_API_URL"
       OSV="${OSV_API_URL%/}/$osv_id"
       source_kind="url"
     else die "vulnerability record not found: $OSV (a file, a URL, a Lightwell id such as RHLW-2026-2d8697b26ccd16c3, or an OSV id such as GHSA-hfrx-6qgj-fp6c)"
     fi ;;
esac
[ "$source_kind" != file ] || [ -r "$OSV" ] || die "vulnerability record not readable: $OSV"

if [ "$source_kind" = lightwell ]; then
  base="$(oc get secret lightwell-lightwell -n "$NAMESPACE" \
    -o go-template='{{with index .data "LW_OSV_BASE_URL"}}{{. | base64decode}}{{end}}' 2>/dev/null)"
  [ -n "$base" ] || die "LW_OSV_BASE_URL is not set in the lightwell-lightwell Secret — scripts/push-secrets.sh lightwell"
  # The older id carries the CVE (x_RHLW-CVE-2026-68079-4.2.2), the hash id
  # does not. The record may bundle that CVE's siblings, so the run says which
  # one it is.
  if [ -z "$VULNERABILITY" ] && [[ "$OSV" =~ (CVE-[0-9]{4}-[0-9]+) ]]; then
    VULNERABILITY="${BASH_REMATCH[1]}"
  fi
  [ -n "$VULNERABILITY" ] \
    || echo "run-remediation: $OSV names no CVE; without --vulnerability the analysis is not held to one of the CVEs the record bundles" >&2
  OSV="${base%/}/$OSV.json"
  source_kind="url"
fi

if [ "$source_kind" = url ]; then
  record="$(basename "${OSV%%\?*}")"
  osv_param="$OSV"
else
  record="$(basename "$OSV")"
  osv_param="/osv/$record"
fi
# A label value cannot contain '/' or uppercase, and the claim lists on it.
label="$(printf '%s' "$application" | tr 'A-Z/' 'a-z-' | cut -c1-63)"
# Per application as well as per record: runs for the same advisory against
# different applications are concurrent, and recreating a shared ConfigMap
# would pull the record out from under a run still mounting it.
app_hash="$(printf '%s' "$application" | sha256sum | cut -c1-8)"
cm="osv-$(printf '%s' "${record%.json}" | tr 'A-Z_.' 'a-z--' | cut -c1-46)-$app_hash"

# The run's name says what it is for: <repo>-<vulnerability>-xxxxx, so
# concurrent runs are told apart in a listing (pipeline.spec.md — A Run Is
# Legible Without Reading Logs), and MLflow names the experiment and sessions
# after it. Tekton names every TaskRun and pod after the run too, and replaces
# any name over 63 characters with a hash; the longest is the retry pod of
# patch-and-verify, <run>-patch-and-verify-pod-retry1, so the run gets 35
# characters and this prefix 30. The vulnerability is kept whole; the
# repository keeps its end, which is what tells applications apart
# (…-mlqbn from …-mlqbn-b), cut at a dash so no word is split.
dns_part() { printf '%s' "$1" | tr 'A-Z_.' 'a-z--' | tr -c 'a-z0-9-' '-' | sed 's/--*/-/g; s/^-*//; s/-*$//'; }
tail_part() { # <text> <max>: the last <max> characters, starting at a word
  local text="$1" max="$2" cut
  [ "${#text}" -le "$max" ] && { printf '%s' "$text"; return; }
  cut="${text: -$max}"
  [ "${text: -$((max + 1)):1}" = "-" ] || [ "${cut#*-}" = "$cut" ] || cut="${cut#*-}"
  printf '%s' "${cut#-}"
}
vuln_part="$(dns_part "${VULNERABILITY:-${record%.json}}" | cut -c1-16 | sed 's/-*$//')"
repo_part="$(tail_part "$(dns_part "${application#*/}")" $((28 - ${#vuln_part})))"
run_prefix="${repo_part:+$repo_part-}$vuln_part-"

osv_workspace=""
if [ "$source_kind" = file ]; then
  oc delete configmap "$cm" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
  oc create configmap "$cm" -n "$NAMESPACE" --from-file="$OSV" >/dev/null \
    || die "could not create the record ConfigMap"
  osv_workspace="    - name: osv
      configMap:
        name: $cm"
fi

mkdir -p "$STATUS_DIR"

run="$(oc create -n "$NAMESPACE" -o name -f - <<YAML | cut -d/ -f2
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: $run_prefix
  labels:
    app.kubernetes.io/part-of: lightwell-remediation
    lightwell.dev/application: $label
  annotations:
    tekton.dev/auto-cleanup-pvc: "true"
    lightwell.dev/record: $record
spec:
  pipelineRef:
    name: remediate
  taskRunTemplate:
    serviceAccountName: $SERVICE_ACCOUNT
  taskRunSpecs:
    - pipelineTaskName: claim-application
      serviceAccountName: $CLAIM_ACCOUNT$trace_spec
  timeouts:
    pipeline: 1h30m0s
  params:
    - name: application
      value: $label
    - name: repository
      value: "$application"
    - name: github-secret
      value: $github_secret
    - name: osv
      value: "$osv_param"
    - name: vulnerability
      value: "$VULNERABILITY"
    - name: app-branch
      value: "$BRANCH"
    - name: model
      value: "$MODEL"
$( [ -z "$IMAGE" ] || printf '    - name: image\n      value: "%s"\n' "$IMAGE" )
    - name: replay
      value: "false"
    - name: cache-claim
      value: $CACHE_CLAIM
  workspaces:
    - name: source
      volumeClaimTemplate:
        spec:
          accessModes: [ReadWriteOnce]
          resources:
            requests:
              storage: 5Gi
$osv_workspace
YAML
)"
[ -n "$run" ] || die "could not create the PipelineRun"

log "started $run"
log "  application $application"
log "  token from  $github_secret"
log "  record      $record ($source_kind)"
[ -z "$VULNERABILITY" ] || log "  vulnerability $VULNERABILITY"
log "  branch      ${BRANCH:-the repository default}"
log "  model       ${MODEL:-from the MaaS Secret}"
[ -z "$IMAGE" ] || log "  image       $IMAGE"

[ "$FOLLOW" -eq 1 ] || { printf '%s\n' "$run"; exit 0; }

# A full sequence is seven to eleven minutes, and the first run against a
# cold cache adds more than fifteen. Polling rather than tailing: the logs
# are worth reading afterwards, not streamed.
waited=0
while [ "$waited" -lt 5400 ]; do
  [ -n "$(oc get pipelinerun "$run" -n "$NAMESPACE" \
    -o jsonpath='{.status.completionTime}' 2>/dev/null)" ] && break
  sleep 15
  waited=$(( waited + 15 ))
done

oc get pipelinerun "$run" -n "$NAMESPACE" -o json >"$STATUS_DIR/$run.json" 2>/dev/null

reason="$(oc get pipelinerun "$run" -n "$NAMESPACE" \
  -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null)"
message="$(oc get pipelinerun "$run" -n "$NAMESPACE" \
  -o jsonpath='{.status.conditions[0].message}' 2>/dev/null)"

printf '\n' >&2
oc get taskruns -n "$NAMESPACE" -l "tekton.dev/pipelineRun=$run" \
  -o custom-columns='TASK:.metadata.labels.tekton\.dev/pipelineTask,STATUS:.status.conditions[0].reason' >&2 2>/dev/null
printf '\n%s: %s\n' "$reason" "$message" >&2
# The pull request is the run's product, and the workspace that held
# delivery.json is deleted with the run, so it is read off the deliver log.
pr="$(oc logs -n "$NAMESPACE" -l "tekton.dev/pipelineRun=$run,tekton.dev/pipelineTask=deliver" \
  --all-containers 2>/dev/null | grep -oE 'https://github\.com/[^ "]+/pull/[0-9]+' | tail -1)"
[ -z "$pr" ] || printf 'pull request:  %s\n' "$pr" >&2
printf 'logs:  oc logs -n %s -l tekton.dev/pipelineRun=%s --all-containers\n' "$NAMESPACE" "$run" >&2

[ "$reason" = "Succeeded" ] || [ "$reason" = "Completed" ]
