#!/usr/bin/env bash
# fixtures.test.sh — exercise the branches the demo application never takes.
#
# These cost one agent session each, which is why they are not in the gate
# tests. They are here because nothing else reaches them: the sample has a
# direct dependency whose siblings all have rebuilds, and a suite that stays
# green, so the interesting failures never occur on their own.
#
# The repositories are real and the manipulations are real — a test actually
# deleted, actually rewritten, actually broken. Fabricating the result files
# would prove nothing, because the runtime regenerates them by running the
# suite, which is the entire point of measuring instead of trusting.
#
# Usage: agent-runtime/test/fixtures.test.sh [--dns <server>] [case ...]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$SCRIPT_DIR/../.."
readonly IMAGE="${IMAGE:-localhost/lightwell-agent-runtime:latest}"
readonly SOURCE_REPO="$REPO_ROOT/.workspace/repo"
readonly ANALYSIS="$SCRIPT_DIR/fixtures/analysis.remediable-not-reachable.json"
readonly OSV_DIR="$REPO_ROOT/.fixtures/osv"
readonly M2="$REPO_ROOT/.workspace/m2"

DNS=""
[[ "${1:-}" == "--dns" ]] && { DNS="$2"; shift 2; }
WANTED=("$@")

cd "$REPO_ROOT"
[[ -d "$SOURCE_REPO/.git" ]] || { echo "no checkout in $SOURCE_REPO" >&2; exit 2; }
[[ -r "$ANALYSIS" ]] || { echo "no analysis fixture at $ANALYSIS" >&2; exit 2; }
# podman refuses to mount a path that does not exist, and every case below
# would then fail before a session starts, looking like a test failure.
mkdir -p "$M2"

set -a; # shellcheck disable=SC1090
source "$REPO_ROOT/secrets/secrets.env"; set +a

# The fixture carries a placeholder version, and these cases resolve the real
# one with Maven, so the real one comes from secrets.env like the rest of the
# Lightwell configuration.
readonly REMEDIATED="${LW_REMEDIATED_VERSION:-}"
[[ -n "$REMEDIATED" ]] || { echo "LW_REMEDIATED_VERSION is not set in secrets/secrets.env" >&2; exit 2; }
readonly TEST_FILE="src/test/java/com/lightwell/cxf/hello/HelloWorldResourceTest.java"

pass=0; fail=0; skipped=0
BASELINE=""

reclaim() { podman unshare chown -R 0:0 "$1" 2>/dev/null || true; }

# A workspace holding a copy of the application, with the remediation already
# applied — these cases start after patching.
make_workspace() {
  local w; w="$(mktemp -d /tmp/fixture.XXXXXX)"
  mkdir -p "$w/out"
  cp -r "$SOURCE_REPO" "$w/repo"
  ( cd "$w/repo" && git checkout --quiet -- . )
  node -e '
    const fs = require("fs");
    const a = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    a.remediating_version = process.argv[3];
    fs.writeFileSync(process.argv[2], JSON.stringify(a, null, 2));
  ' "$ANALYSIS" "$w/out/analysis.json" "$REMEDIATED"
  printf '%s' "$w"
}

apply_bump() {
  sed -i "s|<cxf.version>[^<]*</cxf.version>|<cxf.version>$REMEDIATED</cxf.version>|" "$1/repo/pom.xml"
  cat >"$1/out/patch.json" <<JSON
{"terminal_state":"patched","strategy":"declaration",
 "files_changed":["pom.xml"],
 "artifacts_moved":[{"coordinates":"org.apache.cxf:cxf-rt-rs-security-oauth2","from":"4.2.2","to":"$REMEDIATED"}],
 "source_changes":[],"tests_added":[],"compiles":true}
JSON
}

run_role() {
  local w="$1"; shift
  local dns_args=(); [[ -n "$DNS" ]] && dns_args=(--dns "$DNS")
  podman run --rm --user 61000:0 "${dns_args[@]}" \
    -e MAAS_BASE_URL -e MAAS_API_KEY -e MAAS_MODEL -e MAAS_SMALL_MODEL \
    -e LW_USERNAME -e LW_PASSWORD -e LW_MAVEN_REPO_URL -e MAX_TURNS \
    -v "$w:/workspace:Z,U" -v "$OSV_DIR:/osv:ro,Z" -v "$M2:/home/claude-agent/.m2:Z,U" \
    "$IMAGE" "$@" >"$w/run.log" 2>&1
  local status=$?
  reclaim "$w"
  return $status
}

# The baseline every verify case is compared against: the suite on the
# unmodified application, captured once and reused.
capture_baseline() {
  [[ -n "$BASELINE" ]] && return 0
  local w; w="$(make_workspace)"
  local dns_args=(); [[ -n "$DNS" ]] && dns_args=(--dns "$DNS")
  podman run --rm --user 61000:0 "${dns_args[@]}" \
    -e LW_USERNAME -e LW_PASSWORD -e LW_MAVEN_REPO_URL \
    -v "$w:/workspace:Z,U" -v "$M2:/home/claude-agent/.m2:Z,U" \
    --entrypoint run-suite.sh "$IMAGE" baseline-tests.txt >/dev/null 2>&1
  reclaim "$w"
  [[ -s "$w/out/baseline-tests.txt" ]] || { echo "could not capture a baseline" >&2; exit 2; }
  BASELINE="$(mktemp)"; cp "$w/out/baseline-tests.txt" "$BASELINE"
  echo "baseline: $(wc -l <"$BASELINE") test(s)" >&2
}

# check <case> <expected-state> <expected-exit>
check() {
  local name="$1" expected_state="$2" expected_exit="$3" w="$4" doc="$5" status="$6"
  local state
  state="$(node -e '
    try { process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).terminal_state||"")); }
    catch { process.stdout.write("no-document"); }' "$w/out/$doc" 2>/dev/null)"

  if [[ "$state" == "$expected_state" && "$status" == "$expected_exit" ]]; then
    printf '  ok    %-26s %s (exit %s)\n' "$name" "$state" "$status"; (( pass++ ))
    rm -rf "$w"
  else
    printf '  FAIL  %-26s expected %s/exit %s, got %s/exit %s\n' \
      "$name" "$expected_state" "$expected_exit" "${state:-none}" "$status"
    printf '        workspace kept: %s\n' "$w"; (( fail++ ))
  fi
}

wanted() {
  (( ${#WANTED[@]} == 0 )) && return 0
  local c; for c in "${WANTED[@]}"; do [[ "$c" == "$1" ]] && return 0; done; return 1
}

printf 'fixtures (one session each)\n'

# ── A governed sibling with no remediated build ──────────────────────────
# Every CXF artifact has a rebuild, so this sibling is contrived: a dependency
# sharing the property at a version that does not exist. What is being tested
# is the reaction to the data, not the plausibility of the manifest.
if wanted governed-sibling-missing; then
  w="$(make_workspace)"
  python3 -I - "$w/repo/pom.xml" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("    </dependencies>", """        <dependency>
            <groupId>org.apache.commons</groupId>
            <artifactId>commons-lang3</artifactId>
            <version>${cxf.version}</version>
        </dependency>
    </dependencies>""",1)
open(p,'w').write(s)
PY
  run_role "$w" --role patch --no-clone --osv "/osv/CVE-2026-68079.json"
  status=$?
  # Either narrowing to the affected component or refusing is correct; moving
  # the shared property is not, and that is what the check below rules out.
  state="$(node -e 'try{const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(d.terminal_state+"/"+(d.strategy||""))}catch{process.stdout.write("no-document")}' "$w/out/patch.json" 2>/dev/null)"
  if grep -q '<cxf.version>4.2.2</cxf.version>' "$w/repo/pom.xml"; then
    printf '  ok    %-26s shared property left alone (%s)\n' "governed-sibling-missing" "$state"; (( pass++ )); rm -rf "$w"
  else
    printf '  FAIL  %-26s shared property was moved despite an unpublished sibling (%s)\n' "governed-sibling-missing" "$state"
    printf '        workspace kept: %s\n' "$w"; (( fail++ ))
  fi
fi

# ── Verification cases ───────────────────────────────────────────────────
for spec in \
  "baseline-test-deleted:cannot-verify:1" \
  "baseline-test-modified:cannot-verify:1" \
  "test-added:verified:0" \
  "regression:regression:1"
do
  name="${spec%%:*}"; rest="${spec#*:}"
  expected_state="${rest%%:*}"; expected_exit="${rest##*:}"
  wanted "$name" || continue
  capture_baseline

  w="$(make_workspace)"
  apply_bump "$w"
  cp "$BASELINE" "$w/out/baseline-tests.txt"
  t="$w/repo/$TEST_FILE"

  case "$name" in
    baseline-test-deleted)
      # Remove one test the baseline ran. The suite goes green by subtraction.
      python3 -I - "$t" <<'PY'
import re,sys
p=sys.argv[1]; s=open(p).read()
s=re.sub(r'\n    @Test\n    void rejectsRequestWithoutBearerToken\(\)[\s\S]*?\n    \}\n', '\n', s, count=1)
open(p,'w').write(s)
PY
      ;;
    baseline-test-modified)
      # Keep the name and the outcome, gut the assertions. The result lists
      # cannot see this; changed-files can.
      python3 -I - "$t" <<'PY'
import re,sys
p=sys.argv[1]; s=open(p).read()
s=re.sub(r'(void rejectsRequestWithoutBearerToken\(\)[^{]*\{)[\s\S]*?\n    \}',
         r'\1\n        // assertions removed\n    }', s, count=1)
open(p,'w').write(s)
PY
      ;;
    test-added)
      python3 -I - "$t" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read().rstrip()
s=s[:-1] + '\n    @Test\n    void addedAlongsideTheChange() { }\n}\n'
open(p,'w').write(s)
PY
      ;;
    regression)
      # Break the application, not the test. A regression is production code
      # that stopped behaving, which is what this capability has to recognise.
      # A test edited to fail is a different finding, and verify is right to
      # call that one cannot-verify — the first version of this fixture made
      # that mistake and was corrected, not the code.
      python3 -I - "$w/repo/src/main/java/com/lightwell/cxf/hello/SampleBearerTokenValidator.java" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("if (!accessToken.equals(authSchemeData)) {",
            "if (false) { // injected regression: every token is accepted")
open(p,'w').write(s)
PY
      ;;
  esac

  run_role "$w" --role verify --no-clone
  check "$name" "$expected_state" "$expected_exit" "$w" verification.json "$?"
done

[[ -n "$BASELINE" ]] && rm -f "$BASELINE"
printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skipped"
(( fail == 0 ))
