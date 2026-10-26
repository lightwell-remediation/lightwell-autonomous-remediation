#!/usr/bin/env bash
# run-agent.sh — Launch the remediation harness against Red Hat MaaS.
#
# Runs identically on a laptop and inside the container image, so a prompt
# debugged locally behaves the same in the pipeline.
#
# Behavior contract: specs/platform/agent-runtime.spec.md
# Packaging decisions:  docs/adr/0003-agent-runtime-packaging-and-credentials.md
#
# Usage:
#   run-agent.sh --task "<prompt>"        [--role <name>] [--repo owner/repo]
#   run-agent.sh --task @path/to/prompt   [--workspace <dir>] [--no-clone]
#   run-agent.sh --role analyze --osv <path|url>   [--model <id>]
#                                         [--branch <name>]
#
# --branch picks which branch of the application to remediate, and so which
# branch the pull request is opened against. Default: the repository's own.
#
# Without --task the role supplies its prompt from prompts/<role>.md.
#
# Exit status:
#   0  session completed with no permission denials
#   1  session failed, hit its turn budget, was blocked by a denial, or did not
#      produce the document its role is contracted to produce
#   2  configuration error (missing variable, bad arguments, unreadable input)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly EXIT_CONFIG=2

die() { printf 'run-agent: %s\n' "$*" >&2; exit "${2:-$EXIT_CONFIG}"; }
log() { printf 'run-agent: %s\n' "$*" >&2; }

# ── Arguments ────────────────────────────────────────────────────────────
# Roles reserved by the invocation contract (agent-runtime.spec.md — Non-Goals).
# Only one exists while the orchestration strategy is undecided; Milestone 2
# adds the dual-agent and judge roles here. An unrecognised role must fail
# rather than quietly run the default: a pipeline asking for a role that does
# not exist and getting a green run is the same dishonesty the exit status
# contract exists to prevent.
readonly KNOWN_ROLES=("default" "analyze" "patch" "verify" "deliver" "exploit")

# Roles whose prompt requires a vulnerability record. Asking for one of these
# without --osv is a configuration error, not a session that discovers halfway
# through that its input is missing.
#
# patch takes it as well as the analysis: the record names the class, the
# method and the guarantee the flaw breaks, which is what makes a compilation
# failure after the change interpretable. The remediating version still comes
# from the analysis — the record's prose recommends upstream releases, and
# those are not the backport being applied.
readonly OSV_ROLES=("analyze" "patch" "deliver" "exploit")

# Roles for which the runtime resolves the dependency tree up front. See
# "Resolved build facts" below for why this is not the agent's job.
readonly TREE_ROLES=("analyze")

# Roles that act on a completed analysis rather than producing one.
readonly ANALYSIS_ROLES=("patch" "verify" "deliver" "exploit")

# Roles for which the runtime enumerates what the version declaration governs,
# and whether each of those artifacts exists at the remediating version.
readonly GOVERNED_ROLES=("patch")

# Roles that measure the tree and the suite *after* a change.
readonly POST_CHANGE_ROLES=("verify")

# Roles handed an inventory of the repository's files. Every role that reads
# source needs it: without one the agent walks the tree by guessing paths.
readonly INVENTORY_ROLES=("analyze" "patch" "verify" "exploit")

# Roles that hand their work to a reviewer. The branch, the commit and the
# pull request are commands, so the runtime issues them; the session only
# writes the narrative, and has no access to the repository to do otherwise.
readonly DELIVER_ROLES=("deliver")

# Roles that write a test meant to fail. Their verdict is observed, not
# claimed: the runtime runs the suite and reads git rather than taking the
# session's word for it.
readonly EXPLOIT_ROLES=("exploit")

ROLE="default"
TASK=""
CLI_OSV=""
CLI_ANALYSIS=""
CLI_MODEL=""
# Which branch of the application to remediate. Empty means the repository's
# default, which is the right answer for a real alert. It is a parameter
# because the branch a remediation is based on is a property of the request,
# not of the deployment: the demo fixture lives on a branch of its own, and
# Milestone 2's candidates may each be based somewhere different.
CLI_APP_BRANCH="${APP_BRANCH:-}"
CLONE=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)      ROLE="${2:?--role needs a value}";      shift 2 ;;
    --task)      TASK="${2:?--task needs a value}";      shift 2 ;;
    --osv)       CLI_OSV="${2:?--osv needs a value}";    shift 2 ;;
    --model)     CLI_MODEL="${2:?--model needs a value}"; shift 2 ;;
    --analysis)  CLI_ANALYSIS="${2:?--analysis needs a value}"; shift 2 ;;
    --repo)      CLI_APP_REPO="${2:?--repo needs a value}";  shift 2 ;;
    --branch)    CLI_APP_BRANCH="${2:?--branch needs a value}"; shift 2 ;;
    --workspace) CLI_WORKSPACE="${2:?--workspace needs a value}"; shift 2 ;;
    --no-clone)  CLONE=0; shift ;;
    -h|--help)   sed -n '2,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)           die "unknown argument: $1" ;;
  esac
done

[[ " ${KNOWN_ROLES[*]} " == *" $ROLE "* ]] \
  || die "unknown role: $ROLE (known: ${KNOWN_ROLES[*]})"

# A leading @ reads the prompt from a file, so long prompts live in version
# control instead of being pasted into a pipeline definition. Without --task the
# role supplies its own prompt; see "Task resolution" below.
if [[ "$TASK" == @* ]]; then
  task_file="${TASK#@}"
  [[ -r "$task_file" ]] || die "task file not readable: $task_file"
  TASK="$(cat "$task_file")"
fi

# ── Configuration ────────────────────────────────────────────────────────
# Locally the values come from secrets/secrets.env; in a container they are
# already in the environment via a mounted Secret.
SECRETS_FILE="${SECRETS_FILE:-$SCRIPT_DIR/../secrets/secrets.env}"
if [[ -r "$SECRETS_FILE" ]]; then
  log "loading configuration from $SECRETS_FILE"
  set -a; # shellcheck disable=SC1090
  source "$SECRETS_FILE"; set +a
fi

# A credential still wrapped in quotes is a credential that will be rejected.
# secrets.env needs the quotes so that `source` does not let bash interpret a
# token containing shell metacharacters, but `podman --env-file` does not strip
# them, so the value arriving here is `"ey..."` rather than `ey...`. The symptom
# is a 401 from a service the same credential authenticates against from the
# host — an hour of looking in the wrong place. Pass secrets with `-e VAR` after
# sourcing the file, not with --env-file.
for credential in LW_USERNAME LW_PASSWORD MAAS_API_KEY GITHUB_TOKEN; do
  value="${!credential:-}"
  [[ -n "$value" ]] || continue
  if [[ ( "$value" == '"'*'"' ) || ( "$value" == "'"*"'" ) ]]; then
    die "$credential arrived wrapped in quotes — podman --env-file does not strip them; source the file and pass -e $credential instead"
  fi
done

# An explicit flag outranks the file. The file is sourced with `set -a`, so
# without this a template still holding APP_REPO=CHANGE_ME would silently
# overwrite --repo, and the run would proceed against the wrong tree.
APP_REPO="${CLI_APP_REPO:-${APP_REPO:-}}"
WORKSPACE="${CLI_WORKSPACE:-${WORKSPACE:-}}"

# An explicit --model outranks the configured one. Milestone 2 runs the same
# sequence twice with different models and has a judge compare the results,
# which needs the model to be an invocation parameter rather than deployment
# configuration — the same reasoning that made the role one.
MAAS_MODEL="${CLI_MODEL:-${MAAS_MODEL:-}}"

for required in MAAS_BASE_URL MAAS_API_KEY MAAS_MODEL; do
  [[ -n "${!required:-}" && "${!required}" != "CHANGE_ME" ]] \
    || die "$required is not set (see secrets/secrets.template.env)"
done

# ── Provider isolation ───────────────────────────────────────────────────
# A workstation configured for another provider would otherwise hijack the
# session and silently bypass MaaS — the demo would still work, and nobody
# would notice it never touched Red Hat infrastructure. The list covers every
# provider switch the harness honours (verified against the 2.1.295 binary):
# Vertex, Bedrock, Foundry, and the gateway and Mantle routes.
unset CLAUDE_CODE_USE_VERTEX ANTHROPIC_VERTEX_PROJECT_ID CLOUD_ML_REGION \
      GOOGLE_APPLICATION_CREDENTIALS ANTHROPIC_VERTEX_BASE_URL \
      CLAUDE_CODE_USE_BEDROCK ANTHROPIC_BEDROCK_BASE_URL ANTHROPIC_AWS_API_KEY \
      CLAUDE_CODE_USE_FOUNDRY ANTHROPIC_FOUNDRY_BASE_URL \
      ANTHROPIC_FOUNDRY_API_KEY ANTHROPIC_FOUNDRY_AUTH_TOKEN \
      ANTHROPIC_FOUNDRY_RESOURCE \
      CLAUDE_CODE_USE_GATEWAY CLAUDE_CODE_USE_MANTLE \
      ANTHROPIC_BEDROCK_MANTLE_BASE_URL ANTHROPIC_CUSTOM_HEADERS \
      ANTHROPIC_AUTH_TOKEN 2>/dev/null || true

# ── Inference routing ────────────────────────────────────────────────────
# MaaS (LiteLLM) accepts the x-api-key header, which is what ANTHROPIC_API_KEY
# sends. ANTHROPIC_AUTH_TOKEN would send Authorization: Bearer instead; both
# are accepted by the gateway, and x-api-key is the path validated in ADR-0002.
export ANTHROPIC_BASE_URL="${MAAS_BASE_URL%/}"
export ANTHROPIC_API_KEY="$MAAS_API_KEY"

# Every model slot must resolve to something the MaaS catalog serves. The
# harness reasons internally in terms of haiku/sonnet/opus and uses the haiku
# slot for background work; if that alias is absent the calls fail with an
# unknown-model error that is easy to misread as a gateway problem.
export ANTHROPIC_MODEL="$MAAS_MODEL"
export ANTHROPIC_DEFAULT_SONNET_MODEL="$MAAS_MODEL"
export ANTHROPIC_DEFAULT_OPUS_MODEL="$MAAS_MODEL"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="${MAAS_SMALL_MODEL:-$MAAS_MODEL}"

# ── Output budget ────────────────────────────────────────────────────────
# The gateway drops a request that runs past roughly 60 seconds, so the real
# ceiling is throughput × 60s. Claude Code otherwise asks for 32,000 output
# tokens, and every long reply dies on that wall — surfacing as a retry storm
# rather than a clear error. 2048 fits within the window at the throughput
# measured for claude-sonnet-4-6; raise it only after measuring the model in
# use. See docs/agent-runtime.md — Known limitations.
# 2048 is the general ceiling, set from the throughput of the slowest model in
# the catalog against the gateway's ~60s window. A role that writes a source
# file needs more in one reply than that allows: a test class with imports, a
# setup method and an assertion does not fit, and the request is refused
# outright rather than truncated. Roles that write code get more, which is
# only safe while the model is fast enough to still finish inside the window.
# Measured with claude-sonnet-4-6 on 2026-10-17: 4096 completes inside the
# window. It would not with a slower model — the ceiling is throughput times
# the gateway's ~60s, not a number — so this rises with the model, not on
# principle. analyze stays at 2048 because it has never needed more.
case "$ROLE" in
  exploit|patch|verify|deliver) default_output_tokens=4096 ;;
  *)                            default_output_tokens=2048 ;;
esac
export CLAUDE_CODE_MAX_OUTPUT_TOKENS="${CLAUDE_CODE_MAX_OUTPUT_TOKENS:-$default_output_tokens}"

# ── Vendor-bound traffic ─────────────────────────────────────────────────
# Note: setting this to 0 or false still disables the traffic. To re-enable it
# the variable has to be unset, not zeroed.
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export DISABLE_AUTOUPDATER=1
export DISABLE_TELEMETRY=1
export DISABLE_ERROR_REPORTING=1
# OTEL_* and CLAUDE_CODE_ENABLE_TELEMETRY are deliberately left untouched:
# they are opt-in and are ignored unless set as real environment variables.

export API_TIMEOUT_MS="${API_TIMEOUT_MS:-600000}"

# ── Workspace ────────────────────────────────────────────────────────────
WORKSPACE="${WORKSPACE:-$SCRIPT_DIR/../.workspace}"
readonly REPO_DIR="$WORKSPACE/repo"
readonly OUT_DIR="$WORKSPACE/out"
readonly INPUT_DIR="$WORKSPACE/input"
mkdir -p "$REPO_DIR" "$OUT_DIR" "$INPUT_DIR"

readonly RESULT_FILE="$OUT_DIR/result.json"
readonly LOG_FILE="$OUT_DIR/session.log"
readonly TRACE_FILE="$OUT_DIR/session.jsonl"
readonly OSV_FILE="$INPUT_DIR/osv.json"
readonly ANALYSIS_FILE="$OUT_DIR/analysis.json"
readonly TREE_FILE="$OUT_DIR/dependency-tree.txt"
readonly SBOM_FILE="$OUT_DIR/sbom-components.txt"
readonly SOURCES_FILE="$OUT_DIR/source-files.txt"
readonly GOVERNED_FILE="$OUT_DIR/governed-artifacts.txt"
readonly BASELINE_FILE="$OUT_DIR/baseline-tests.txt"
readonly POST_TESTS_FILE="$OUT_DIR/post-tests.txt"
readonly POST_TREE_FILE="$OUT_DIR/post-tree.txt"
readonly PATCH_FILE="$OUT_DIR/patch.json"
readonly VERIFICATION_FILE="$OUT_DIR/verification.json"
readonly NARRATIVE_FILE="$OUT_DIR/pr-narrative.json"
readonly BODY_FILE="$OUT_DIR/pr-body.md"
readonly DELIVERY_FILE="$OUT_DIR/delivery.json"
readonly EXPLOIT_INTENT_FILE="$OUT_DIR/exploit-intent.json"
readonly EXPLOIT_FILE="$OUT_DIR/exploit.json"
readonly API_FILE="$OUT_DIR/api-signatures.txt"
readonly CHANGED_FILES_FILE="$OUT_DIR/changed-files.txt"
readonly PATCH_DIFF_FILE="$OUT_DIR/patch.diff"
# What the pipeline task that rebuilds the bill of materials left behind.
# Absent on a local run, and absent where the project publishes none —
# the deliver prompt treats it as optional for exactly that reason.
readonly SBOM_SUMMARY_FILE="$OUT_DIR/sbom.json"
# What Trusted Profile Analyzer reported about that inventory, left by the
# same task's validate step. Absent wherever no TPA is configured.
readonly TPA_RESULT_FILE="$OUT_DIR/tpa.json"

# ── Task input ───────────────────────────────────────────────────────────
# The vulnerability record is placed in the workspace before the session
# exists, for the same reason the repository is cloned here: whoever fetches it
# authenticates, and the agent only ever sees a file. A record served behind
# credentials is retrieved with them at this point, so the allowlist can keep
# denying outbound HTTP to the session itself.
needs_osv=0
[[ " ${OSV_ROLES[*]} " == *" $ROLE "* ]] && needs_osv=1

if [[ -n "$CLI_OSV" ]]; then
  if [[ "$CLI_OSV" == http://* || "$CLI_OSV" == https://* ]]; then
    # Lightwell records need the Lightwell credentials; a public source such
    # as osv.dev needs none, so they are sent only when they are set.
    osv_auth=()
    [[ -n "${LW_USERNAME:-}" && -n "${LW_PASSWORD:-}" ]] && osv_auth=(-u "$LW_USERNAME:$LW_PASSWORD")
    log "fetching vulnerability record from ${CLI_OSV%%\?*}"
    curl -fsS --max-time 30 "${osv_auth[@]}" \
         -o "$OSV_FILE" "$CLI_OSV" \
      || die "cannot retrieve the vulnerability record from $CLI_OSV"
  else
    [[ -r "$CLI_OSV" ]] || die "vulnerability record not readable: $CLI_OSV"
    cp -- "$CLI_OSV" "$OSV_FILE"
  fi

  # Parsed here rather than in the session. A malformed record costs one turn
  # and an opaque failure if the agent discovers it; here it is a configuration
  # error before any inference is spent.
  node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' \
       "$OSV_FILE" 2>/dev/null \
    || die "vulnerability record is not valid JSON: $CLI_OSV"
elif (( needs_osv )); then
  die "role $ROLE requires --osv <path|url>"
fi

# The analysis document is the handoff between phases. A role that acts on a
# remediation does not re-derive it, so arriving without one is a configuration
# error rather than something for the session to cope with.
if [[ -n "$CLI_ANALYSIS" ]]; then
  [[ -r "$CLI_ANALYSIS" ]] || die "analysis document not readable: $CLI_ANALYSIS"
  [[ "$CLI_ANALYSIS" -ef "$ANALYSIS_FILE" ]] || cp -- "$CLI_ANALYSIS" "$ANALYSIS_FILE"
fi

if [[ " ${ANALYSIS_ROLES[*]} " == *" $ROLE "* ]]; then
  [[ -r "$ANALYSIS_FILE" ]] \
    || die "role $ROLE needs an analysis document — pass --analysis, or run the analyze role into this workspace first"
  node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' \
       "$ANALYSIS_FILE" 2>/dev/null \
    || die "analysis document is not valid JSON: $ANALYSIS_FILE"
fi

# ── Task resolution ──────────────────────────────────────────────────────
# Without an explicit --task the role names its own prompt, so the prompt is a
# versioned artifact reviewed like any other file instead of a string pasted
# into a pipeline definition.
readonly PROMPTS_DIR="${PROMPTS_DIR:-$SCRIPT_DIR/prompts}"
if [[ -z "$TASK" ]]; then
  role_prompt="$PROMPTS_DIR/$ROLE.md"
  [[ -r "$role_prompt" ]] \
    || die "no prompt for role $ROLE at $role_prompt — pass --task instead"
  TASK="$(cat "$role_prompt")"
fi



# ── Repository access ────────────────────────────────────────────────────
# Credentials are wired into git and gh before the harness starts, so the
# token never reaches the agent's prompt or context.
if [[ -n "${GITHUB_TOKEN:-}" && "${GITHUB_TOKEN}" != "CHANGE_ME" ]]; then
  export GH_TOKEN="$GITHUB_TOKEN"
  export GIT_ASKPASS=/bin/true

  # Cloning over HTTPS with this helper is deliberate. `gh repo clone` follows
  # the host's configured git protocol, so on a workstation with SSH keys it
  # would authenticate as the developer and the repository-scoped PAT would
  # never be exercised — the run would pass locally and fail in the pod. The
  # helper reads the token from the environment, so nothing lands in
  # .git/config, and scoping it to the checkout leaves the developer's global
  # gitconfig untouched.
  # shellcheck disable=SC2016  # expansion must happen when git runs the helper
  readonly GIT_CRED_HELPER='!f() { echo username=x-access-token; echo "password=${GH_TOKEN}"; }; f'

  if (( CLONE )) && [[ -n "${APP_REPO:-}" && "${APP_REPO}" != "CHANGE_ME" ]]; then
    if [[ ! -d "$REPO_DIR/.git" ]]; then
      # --branch on the clone rather than a checkout afterwards: the pull
      # request's base is read from HEAD later, so cloning the default and
      # switching would leave the base correct only by accident.
      branch_args=()
      [[ -n "$CLI_APP_BRANCH" ]] && branch_args=(--branch "$CLI_APP_BRANCH")
      log "cloning $APP_REPO${CLI_APP_BRANCH:+ at $CLI_APP_BRANCH} into $REPO_DIR"
      git -c credential.helper= -c credential.helper="$GIT_CRED_HELPER" \
          clone --quiet "${branch_args[@]}" "https://github.com/$APP_REPO" "$REPO_DIR" \
        || die "cannot clone $APP_REPO${CLI_APP_BRANCH:+ at $CLI_APP_BRANCH}" 1
    else
      log "reusing existing checkout in $REPO_DIR"
    fi
  fi

  if [[ -d "$REPO_DIR/.git" ]]; then
    git -C "$REPO_DIR" config user.name  "${GIT_AUTHOR_NAME:-lightwell-agent}"
    git -C "$REPO_DIR" config user.email "${GIT_AUTHOR_EMAIL:-lightwell-agent@users.noreply.github.com}"
    # Cleared with --unset-all rather than assigned. A reused checkout already
    # carries a helper from the previous run and another from the image
    # entrypoint, and `git config <key> <value>` refuses to collapse several
    # values into one — so the second run against a workspace died here. The
    # empty value still comes first: it resets the inherited chain so only the
    # token helper below can answer.
    git -C "$REPO_DIR" config --unset-all credential.helper 2>/dev/null || true
    git -C "$REPO_DIR" config --add credential.helper ""
    git -C "$REPO_DIR" config --add credential.helper "$GIT_CRED_HELPER"
  fi
else
  log "no GITHUB_TOKEN configured — repository delivery is unavailable"
fi

# Without a checkout the agent would work in an empty directory, find nothing
# to remediate, deny nothing, and the session would end green. That is the
# silent success the Honest Exit Status contract exists to rule out, so it is a
# configuration error instead.
[[ -d "$REPO_DIR/.git" ]] || die \
  "no git checkout in $REPO_DIR — set APP_REPO and GITHUB_TOKEN, or populate it before --no-clone"

# ── Resolved build facts ─────────────────────────────────────────────────
# The dependency tree is resolved here rather than by the agent. Three reasons,
# each measured on a run that did it the other way:
#
#   - it is data, and routing six kilobytes of it through the model's reply
#     exceeds the output-token ceiling the gateway window imposes;
#   - the natural invocation redirects into a file, and the permission model
#     treats a redirect as a compound command and denies it;
#   - the result is deterministic, so letting a model decide how to obtain it
#     buys variance and turns without buying judgement.
#
# Anything computable is computed before the session; the session is left with
# the part that needs judgement.
if [[ " ${INVENTORY_ROLES[*]} " == *" $ROLE "* ]]; then
  # An inventory of the repository's tracked files. Without it the agent has no
  # cheap way to find out what exists: a trace showed 45 Read calls of which 4
  # were useful, the rest being Reads of directories and guessed Java package
  # paths — `com/lightwell/lwapachecxfsample`, then `lw_apache_cxf_sample`,
  # then `sample`. It has Glob and Grep and does not reach for them. Listing
  # files is a command, not a deduction.
  if git -C "$REPO_DIR" ls-files >"$SOURCES_FILE" 2>/dev/null && [[ -s "$SOURCES_FILE" ]]; then
    log "source inventory: $(wc -l <"$SOURCES_FILE") tracked files"
  else
    rm -f "$SOURCES_FILE"
  fi
fi

if [[ " ${TREE_ROLES[*]} " == *" $ROLE "* ]] && [[ -f "$REPO_DIR/pom.xml" ]]; then
  mvn_args=(-B dependency:tree)
  [[ -f "$REPO_DIR/settings.xml" ]] && mvn_args=(-s settings.xml "${mvn_args[@]}")
  log "resolving the dependency tree (mvn ${mvn_args[*]})"
  if ( cd "$REPO_DIR" && mvn "${mvn_args[@]}" ) >"$TREE_FILE" 2>&1; then
    log "dependency tree: $(wc -l <"$TREE_FILE") lines"
  else
    tail -15 "$TREE_FILE" >&2
    die "cannot resolve the dependency tree — the analysis would have nothing to read" 1
  fi

  # The bill of materials is projected down to its coordinates. A CycloneDX
  # document for a small application runs to hundreds of kilobytes — tens of
  # thousands of tokens — and an agent told to consult it spends its entire
  # turn budget paging through JSON to reach one line. Extracting coordinates
  # is parsing, not judgement, so it happens here.
  # sbom.json at the root is the convention, so it wins outright. The glob is
  # the fallback for repositories still naming the file after the artifact, and
  # it is sorted rather than first-match: `find -print -quit` returns whichever
  # name the directory happens to yield first, so a repository carrying both
  # would analyse a different document from one run to the next.
  if [[ -f "$REPO_DIR/sbom.json" ]]; then
    sbom_src="$REPO_DIR/sbom.json"
  else
    sbom_src="$(find "$REPO_DIR" -maxdepth 2 -name '*sbom*.json' 2>/dev/null | sort | head -1 || true)"
  fi
  if [[ -n "$sbom_src" ]]; then
    if node -e '
      const fs = require("fs");
      const doc = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const names = (doc.components || [])
        .map(c => c.purl || [c.group, c.name, c.version].filter(Boolean).join(":"))
        .filter(Boolean)
        .sort();
      fs.writeFileSync(process.argv[2], names.join("\n") + "\n");
    ' "$sbom_src" "$SBOM_FILE" 2>/dev/null; then
      log "bill of materials: $(wc -l <"$SBOM_FILE") components (projected from $(basename "$sbom_src"))"
    else
      log "bill of materials present but unreadable — the analysis proceeds on the tree alone"
      rm -f "$SBOM_FILE"
    fi
  fi
fi

# ── What the change would move ───────────────────────────────────────────
# A version declaration is rarely one dependency's. Enumerating what it
# governs and resolving each coordinate at the remediating version is lookup,
# so the session is handed the answer rather than the job — and a patch that
# would leave a sibling unresolvable is refused before it is applied, instead
# of surfacing later as a broken build that reads like a bad patch.
if [[ " ${GOVERNED_ROLES[*]} " == *" $ROLE "* ]] && [[ -f "$REPO_DIR/pom.xml" ]]; then
  mapfile -t coords < <(
    node -e '
      const a = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      const c = a.component || {};
      process.stdout.write([c.group, c.artifact, a.remediating_version].join("\n"));
    ' "$ANALYSIS_FILE" 2>/dev/null
  )
  group="${coords[0]:-}"; artifact="${coords[1]:-}"; remediating="${coords[2]:-}"

  if [[ -z "$group" || -z "$artifact" || -z "$remediating" || "$remediating" == "null" ]]; then
    log "analysis names no component and remediating version — nothing to enumerate"
  else
    governed_args=(-B -q dependency:get)
    [[ -f "$REPO_DIR/settings.xml" ]] && governed_args=(-s settings.xml "${governed_args[@]}")

    : >"$GOVERNED_FILE"
    while IFS=$'\t' read -r coord _expression; do
      [[ -n "$coord" ]] || continue
      if ( cd "$REPO_DIR" && mvn "${governed_args[@]}" -Dartifact="$coord:$remediating" ) >/dev/null 2>&1; then
        printf '%s\t%s\tavailable\n' "$coord" "$remediating" >>"$GOVERNED_FILE"
      else
        printf '%s\t%s\tnot-published\n' "$coord" "$remediating" >>"$GOVERNED_FILE"
      fi
    done < <(node "${GOVERNED_ARTIFACTS:-$SCRIPT_DIR/lib/governed-artifacts.js}" \
                  "$REPO_DIR/pom.xml" "$group" "$artifact" 2>/dev/null)

    if [[ -s "$GOVERNED_FILE" ]]; then
      log "governed by that declaration: $(wc -l <"$GOVERNED_FILE") artifact(s), $(grep -c 'not-published' "$GOVERNED_FILE" || true) without a remediated build"
    else
      log "the affected component is not declared in the manifest — it arrives transitively"
      rm -f "$GOVERNED_FILE"
    fi
  fi
fi

# The exact invocation the policy allows and the project needs. Without it the
# agent picks one — `mvn -B package` in a measured run — which is denied, and
# the run ends red having done the work correctly. The runtime already knows
# whether a settings.xml is present, so it says so rather than leaving it to be
# guessed.
BUILD_COMMAND="(no build command available)"
TEST_COMMAND="(no test command available)"
if [[ -f "$REPO_DIR/pom.xml" ]]; then
  # test-compile, not compile: patching is asked to add tests covering any
  # source change it makes, and `compile` never looks at them. A run wrote
  # three tests that did not compile, reported the build as standing, and the
  # failure surfaced two phases later as a suite that could not run at all.
  if [[ -f "$REPO_DIR/settings.xml" ]]; then
    BUILD_COMMAND="mvn -s settings.xml -B test-compile"
    TEST_COMMAND="mvn -s settings.xml -B test -Dtest=<YourTestClass>"
  else
    BUILD_COMMAND="mvn -B test-compile"
    TEST_COMMAND="mvn -B test -Dtest=<YourTestClass>"
  fi
fi
readonly BUILD_COMMAND TEST_COMMAND

# ── State after the change ───────────────────────────────────────────────
# Verification is handed what the tree resolves now and what the suite did,
# because both are measurements and a model reading them is not. Taking them
# from the tree rather than from what patching reported applying is the point:
# one records an intention, the other what happened.
if [[ " ${POST_CHANGE_ROLES[*]} " == *" $ROLE "* ]] && [[ -f "$REPO_DIR/pom.xml" ]]; then
  post_args=(-B dependency:tree)
  [[ -f "$REPO_DIR/settings.xml" ]] && post_args=(-s settings.xml "${post_args[@]}")
  log "resolving the dependency tree after the change"
  if ! ( cd "$REPO_DIR" && mvn "${post_args[@]}" ) >"$POST_TREE_FILE" 2>&1; then
    tail -15 "$POST_TREE_FILE" >&2
    die "the patched tree does not resolve — verification has nothing to measure" 1
  fi

  # What the change actually touched, by status. The test comparison alone
  # cannot see a test whose assertions were rewritten while its name stayed:
  # same line, same outcome, no evidence left. git distinguishes a modified
  # file from an added one, which is exactly the distinction the spec draws —
  # removing or weakening an assertion destroys evidence, adding one creates
  # it. It also gives verification what the change was, instead of leaving it
  # to infer that from the files.
  if git -C "$REPO_DIR" status --porcelain >"$CHANGED_FILES_FILE" 2>/dev/null; then
    log "changed by the patch: $(wc -l <"$CHANGED_FILES_FILE") file(s)"
    # The diff itself, not only which files moved. A test file's status cannot
    # separate a method added from assertions gutted — both read as modified —
    # and that distinction is the whole anti-cheat guarantee. The diff shows
    # which lines went away, and whether an existing test lost anything is a
    # judgement rather than a lookup. Untracked files are included so a new
    # test class is visible as an addition rather than as nothing at all.
    git -C "$REPO_DIR" add --intent-to-add --all >/dev/null 2>&1 || true
    git -C "$REPO_DIR" diff >"$PATCH_DIFF_FILE" 2>/dev/null \
      && log "patch diff: $(wc -l <"$PATCH_DIFF_FILE") line(s)" \
      || rm -f "$PATCH_DIFF_FILE"
  else
    rm -f "$CHANGED_FILES_FILE"
  fi

  log "running the suite after the change"
  # set -e is lifted deliberately: a red suite is the input verification needs,
  # not a reason to stop. Left on, the subshell's exit 1 killed the run before
  # the session started, so a regression never reached the capability whose
  # job is to explain it — and the retry loop had nothing to retry.
  set +e
  ( WORKSPACE="$WORKSPACE" "${RUN_SUITE:-$SCRIPT_DIR/run-suite.sh}" "$(basename "$POST_TESTS_FILE")" )
  post_status=$?
  set -e
  # A red suite is a finding, not an error here: telling a regression from an
  # obsolete assertion is the session's work, and it needs the results to do
  # it. Only a suite that could not run at all leaves nothing to reason about.
  if (( post_status == 2 )); then
    die "the suite could not be run after the change — verification has nothing to measure" 1
  fi
fi

# ── API the defect lives in ──────────────────────────────────────────────
# Written before the session, because a test that exercises a defect has to
# construct the types the flawed class works with, and those are in a jar.
# Without them the session hunts for the dependency on disk and finds nothing.
if [[ " ${EXPLOIT_ROLES[*]} " == *" $ROLE "* ]] && [[ -r "$ANALYSIS_FILE" ]]; then
  "${API_SIGNATURES:-$SCRIPT_DIR/lib/api-signatures.sh}" \
    "$REPO_DIR" "$ANALYSIS_FILE" "$API_FILE" || true
fi

# Paths are substituted rather than written into the prompt so the same prompt
# runs unchanged on a workstation and in a container, where the workspace lives
# somewhere else.
TASK="${TASK//\{\{OSV_PATH\}\}/$OSV_FILE}"
TASK="${TASK//\{\{ANALYSIS_PATH\}\}/$ANALYSIS_FILE}"
TASK="${TASK//\{\{TREE_PATH\}\}/$TREE_FILE}"
TASK="${TASK//\{\{SBOM_PATH\}\}/$SBOM_FILE}"
TASK="${TASK//\{\{SOURCES_PATH\}\}/$SOURCES_FILE}"
TASK="${TASK//\{\{ANALYSIS_PATH\}\}/$ANALYSIS_FILE}"
TASK="${TASK//\{\{GOVERNED_PATH\}\}/$GOVERNED_FILE}"
TASK="${TASK//\{\{BASELINE_PATH\}\}/$BASELINE_FILE}"
TASK="${TASK//\{\{POST_TESTS_PATH\}\}/$POST_TESTS_FILE}"
TASK="${TASK//\{\{POST_TREE_PATH\}\}/$POST_TREE_FILE}"
TASK="${TASK//\{\{PATCH_PATH\}\}/$PATCH_FILE}"
TASK="${TASK//\{\{VERIFICATION_PATH\}\}/$VERIFICATION_FILE}"
TASK="${TASK//\{\{BUILD_COMMAND\}\}/$BUILD_COMMAND}"
TASK="${TASK//\{\{TEST_COMMAND\}\}/$TEST_COMMAND}"
TASK="${TASK//\{\{CHANGED_FILES_PATH\}\}/$CHANGED_FILES_FILE}"
TASK="${TASK//\{\{PATCH_DIFF_PATH\}\}/$PATCH_DIFF_FILE}"
TASK="${TASK//\{\{NARRATIVE_PATH\}\}/$NARRATIVE_FILE}"
TASK="${TASK//\{\{BODY_PATH\}\}/$BODY_FILE}"
TASK="${TASK//\{\{SBOM_SUMMARY_PATH\}\}/$SBOM_SUMMARY_FILE}"
TASK="${TASK//\{\{EXPLOIT_PATH\}\}/$EXPLOIT_INTENT_FILE}"
TASK="${TASK//\{\{DEMONSTRATION_PATH\}\}/$EXPLOIT_FILE}"
TASK="${TASK//\{\{API_PATH\}\}/$API_FILE}"

# ── Launch ───────────────────────────────────────────────────────────────
# --bare keeps the run reproducible: no CLAUDE.md, hooks, plugins or MCP
#   servers from the host or from the cloned repository leak into the session.
# --permission-mode dontAsk + --permission-prompts none make every action that
#   the allowlist does not cover a denial instead of a wait.
#
# Each role carries its own policy where it has one. A capability that only
# reads should not run under a policy that can commit and push: the narrower
# the allowlist, the fewer ways a run has to end green having done something
# nobody asked for.
readonly SETTINGS_DIR="${SETTINGS_DIR:-$SCRIPT_DIR/claude}"
if [[ -z "${SETTINGS_FILE:-}" ]]; then
  if [[ -r "$SETTINGS_DIR/settings.$ROLE.json" ]]; then
    SETTINGS_FILE="$SETTINGS_DIR/settings.$ROLE.json"
  else
    SETTINGS_FILE="$SETTINGS_DIR/settings.json"
  fi
fi
readonly SETTINGS_FILE
[[ -r "$SETTINGS_FILE" ]] || die "settings file not readable: $SETTINGS_FILE"
log "policy=$(basename "$SETTINGS_FILE")"

cd "$REPO_DIR"
log "role=$ROLE model=$ANTHROPIC_MODEL workspace=$WORKSPACE"

# stream-json rather than json. The result document says what a session spent,
# never what it spent it on: a run that exhausts its budget leaves the same
# summary whether it was blocked, looping, or reading a large file in pieces.
# Diagnosing those from the summary alone meant guessing, and the guess was
# wrong every time the trace later became available. The stream carries each
# tool call, and the result document is the last event in it, so nothing
# downstream has to change.
set +e
claude --bare -p "$TASK" \
  --settings "$SETTINGS_FILE" \
  --output-format stream-json --verbose \
  --permission-mode dontAsk \
  --permission-prompts none \
  --max-turns "${MAX_TURNS:-25}" \
  >"$TRACE_FILE" 2>"$LOG_FILE"
harness_status=$?
set -e

[[ -s "$TRACE_FILE" ]] || {
  log "harness produced no output (exit $harness_status)"
  tail -20 "$LOG_FILE" >&2 || true
  exit 1
}

node -e '
  const fs = require("fs");
  const last = fs.readFileSync(process.argv[1], "utf8")
    .split("\n").filter(Boolean)
    .map(l => { try { return JSON.parse(l); } catch { return null; } })
    .filter(e => e && e.type === "result")
    .pop();
  if (!last) process.exit(1);
  fs.writeFileSync(process.argv[2], JSON.stringify(last));
' "$TRACE_FILE" "$RESULT_FILE" || {
  log "stream carried no result event (exit $harness_status)"
  tail -20 "$LOG_FILE" >&2 || true
  exit 1
}

# Printed on every run, not only on failure: a green run that took eighty turns
# is a finding too, and nobody goes looking for a trace they were not told about.
node "${TRACE_SUMMARY:-$SCRIPT_DIR/lib/trace-summary.js}" "$TRACE_FILE" || true

# ── Honest exit status ───────────────────────────────────────────────────
# Which document this role is contracted to produce, chosen here rather than
# at the point of use: the session check below needs to know whether anything
# will judge the work afterwards.
case "$ROLE" in
  analyze) output_gate="${CHECK_ANALYSIS:-$SCRIPT_DIR/lib/check-analysis.js}";     output_doc="$ANALYSIS_FILE" ;;
  patch)   output_gate="${CHECK_PATCH:-$SCRIPT_DIR/lib/check-patch.js}";           output_doc="$PATCH_FILE" ;;
  verify)  output_gate="${CHECK_VERIFICATION:-$SCRIPT_DIR/lib/check-verification.js}"; output_doc="$VERIFICATION_FILE" ;;
  deliver) output_gate="${CHECK_DELIVERY:-$SCRIPT_DIR/lib/check-delivery.js}";     output_doc="$DELIVERY_FILE" ;;
  exploit) output_gate="${CHECK_EXPLOIT:-$SCRIPT_DIR/lib/check-exploit.js}";       output_doc="$EXPLOIT_FILE" ;;
  *)       output_gate="" ;;
esac

# A completed session is not necessarily a successful one — see
# agent-runtime/lib/check-result.js. --gated says a role gate follows, so a
# denied action is reported and left to it: the policy already prevented the
# action, and whether the work got done is the document's question, not the
# denial's.
gated_flag=()
[[ -n "$output_gate" ]] && gated_flag=(--gated)
if ! node "${CHECK_RESULT:-$SCRIPT_DIR/lib/check-result.js}" "$RESULT_FILE" "${gated_flag[@]}"; then
  log "artifacts: $RESULT_FILE $LOG_FILE"
  exit 1
fi

# A session can clear the check above — never denied, never out of turns — and
# still have produced nothing a later stage can use. Roles contracted to emit a
# document are held to that separately.
# ── Exploit demonstration ────────────────────────────────────────────────
# The session wrote a test and said so. Whether it fails against this
# application, and whether it left everything else alone, are observations —
# so they are made here, by running the suite and reading what git reports.
# A session able to write its own verdict would eventually write
# "demonstrated" for a test that passes, and that test then travels onward as
# evidence.
if [[ " ${EXPLOIT_ROLES[*]} " == *" $ROLE "* ]]; then
  if git -C "$REPO_DIR" status --porcelain >"$CHANGED_FILES_FILE" 2>/dev/null; then
    log "changed by generation: $(wc -l <"$CHANGED_FILES_FILE") file(s)"
  else
    : >"$CHANGED_FILES_FILE"
  fi

  log "running the suite with the generated test in place"
  set +e
  ( WORKSPACE="$WORKSPACE" "${RUN_SUITE:-$SCRIPT_DIR/run-suite.sh}" "$(basename "$POST_TESTS_FILE")" )
  set -e

  node "${ASSESS_EXPLOIT:-$SCRIPT_DIR/lib/assess-exploit.js}" \
       "$EXPLOIT_INTENT_FILE" "$BASELINE_FILE" "$POST_TESTS_FILE" \
       "$CHANGED_FILES_FILE" "$EXPLOIT_FILE"
fi

# ── Delivery ─────────────────────────────────────────────────────────────
# Branching, committing, pushing and opening the request are commands, so the
# runtime issues them (ADR-0005). The session only wrote the narrative, and
# its policy gives it no access to the repository — it could not have
# delivered anything even if it tried.
if [[ " ${DELIVER_ROLES[*]} " == *" $ROLE "* ]]; then
  delivery_fail() {
    node -e '
      const fs = require("fs");
      fs.writeFileSync(process.argv[1], JSON.stringify(
        { terminal_state: "cannot-deliver", reason: process.argv[2] }, null, 2) + "\n");
    ' "$DELIVERY_FILE" "$1"
    log "delivery failed — $1"
  }

  # The body is markdown in its own file rather than a string inside the JSON.
  # A run lost its work by quoting an RFC inside that string and breaking the
  # document — prose and JSON escaping do not belong in the same place.
  narrative="$(node -e '
    try {
      const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      if (!d.title) process.exit(1);
      process.stdout.write([d.title, d.commit_message || d.title].join("\n"));
    } catch { process.exit(1); }
  ' "$NARRATIVE_FILE" 2>/dev/null)" || narrative=""

  [[ -s "$BODY_FILE" ]] || narrative=""

  verified="$(node -e '
    try {
      const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      process.stdout.write(String(d.terminal_state || ""));
    } catch { process.stdout.write(""); }
  ' "$VERIFICATION_FILE" 2>/dev/null)"

  if [[ "$verified" != "verified" ]]; then
    # A pull request is a claim that something is ready to merge. Nothing that
    # failed verification has earned it.
    delivery_fail "verification did not pass (${verified:-no document}) — nothing is delivered"
  elif [[ -z "$narrative" ]]; then
    delivery_fail "the session wrote no usable title at $NARRATIVE_FILE or no body at $BODY_FILE"
  elif [[ -z "${APP_REPO:-}" || "${GITHUB_TOKEN:-}" == "" ]]; then
    delivery_fail "no repository credentials — cannot open a pull request"
  else
    # The branch the checkout was on, captured before a new one exists. A
    # pull request belongs against what the work was based on, which is not
    # necessarily the repository's default branch.
    base_branch="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    [[ -n "$base_branch" && "$base_branch" != "HEAD" ]] \
      || base_branch="$(git -C "$REPO_DIR" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
    [[ -n "$base_branch" ]] || base_branch=main

    pr_title="$(printf '%s' "$narrative" | head -1)"
    commit_msg="$(printf '%s' "$narrative" | tail -n +2)"
    branch="remediate/$(node -e '
      try {
        const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
        const id = (d.vulnerability && d.vulnerability.id) || "vulnerability";
        process.stdout.write(String(id).toLowerCase().replace(/[^a-z0-9.-]+/g, "-").replace(/^-|-$/g, ""));
      } catch { process.stdout.write("vulnerability"); }
    ' "$ANALYSIS_FILE")-$(date +%Y%m%d%H%M%S)"

    delivered=0
    if ! git -C "$REPO_DIR" checkout -q -b "$branch"; then
      delivery_fail "cannot create branch $branch"
    elif ! git -C "$REPO_DIR" add -A; then
      delivery_fail "cannot stage the change"
    # One commit, not the history of the attempts: a reviewer reads the diff,
    # and a retry's intermediate states cost attention and tell them nothing.
    elif ! git -C "$REPO_DIR" commit -q -m "$pr_title" -m "$commit_msg"; then
      delivery_fail "nothing to commit — the working tree carries no change"
    elif ! git -C "$REPO_DIR" push -q origin "$branch" 2>"$OUT_DIR/delivery.log"; then
      delivery_fail "cannot push $branch — $(tail -1 "$OUT_DIR/delivery.log" 2>/dev/null)"
    else
      body_file="$BODY_FILE"
      # What TPA said about the regenerated inventory is appended here rather
      # than handed to the session: it is a service's answer, not something
      # to phrase (ADR-0005). Absent document, nothing appended.
      if [[ -s "$TPA_RESULT_FILE" ]]; then
        body_file="$OUT_DIR/pr-body.delivered.md"
        { cat "$BODY_FILE"
          node "${TPA_SECTION:-$SCRIPT_DIR/lib/tpa-section.js}" "$TPA_RESULT_FILE"
        } >"$body_file" 2>/dev/null || body_file="$BODY_FILE"
      fi
      if pr_url="$(cd "$REPO_DIR" && gh pr create --base "$base_branch" \
                      --head "$branch" --title "$pr_title" --body-file "$body_file" 2>"$OUT_DIR/delivery.log")"; then
        node -e '
          const fs = require("fs");
          fs.writeFileSync(process.argv[1], JSON.stringify({
            terminal_state: "delivered",
            branch: process.argv[2],
            base: process.argv[5],
            pull_request: process.argv[3].trim(),
            commit: process.argv[4]
          }, null, 2) + "\n");
        ' "$DELIVERY_FILE" "$branch" "$pr_url" "$(git -C "$REPO_DIR" rev-parse HEAD)" "$base_branch"
        log "delivered: $pr_url"
        delivered=1
      else
        # The branch is pushed but nobody has been asked to look at it, which
        # is not delivery.
        delivery_fail "pushed $branch but could not open the pull request — $(tail -1 "$OUT_DIR/delivery.log" 2>/dev/null)"
      fi
    fi
    (( delivered )) || true
  fi
fi

if [[ -n "$output_gate" ]]; then
  if ! node "$output_gate" "$output_doc"; then
    log "artifacts: $RESULT_FILE $LOG_FILE"
    exit 1
  fi
fi

log "session completed — artifacts in $OUT_DIR"
exit 0
