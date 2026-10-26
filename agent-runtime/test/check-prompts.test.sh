#!/usr/bin/env bash
# check-prompts.test.sh — the role prompts against what run-agent.sh fills in.
#
# A placeholder the runtime does not substitute reaches the agent as literal
# `{{NAME}}`, and a build command written into a prompt only works for the
# applications it was written against: `mvn -s settings.xml` fails on one
# that resolves from Maven Central alone, because there is no settings.xml.
# Both are cheap to catch here and expensive to find in a paid run.
#
# Usage: agent-runtime/test/check-prompts.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROMPTS="$SCRIPT_DIR/../prompts"
readonly RUNTIME="$SCRIPT_DIR/../run-agent.sh"

pass=0
fail=0

ok()   { printf '  ok    %s\n' "$1"; (( pass++ )); }
nok()  { printf '  FAIL  %s\n' "$1"; (( fail++ )); }

# Every placeholder used by a prompt is substituted by the runtime.
for placeholder in $(grep -ohE '\{\{[A-Z_]+\}\}' "$PROMPTS"/*.md | sort -u); do
  name="${placeholder//[\{\}]/}"
  # run-agent.sh writes them escaped for bash pattern substitution: \{\{NAME\}\}
  if grep -qF "\\{\\{$name\\}\\}" "$RUNTIME"; then
    ok "$placeholder is substituted"
  else
    nok "$placeholder is used by a prompt but run-agent.sh never fills it"
  fi
done

# No prompt hardcodes how Maven is invoked; the runtime decides, per repository.
if hits="$(grep -nE 'mvn +-s +settings\.xml' "$PROMPTS"/*.md)"; then
  nok "a prompt hardcodes 'mvn -s settings.xml':"
  printf '        %s\n' "$hits"
else
  ok "no prompt hardcodes 'mvn -s settings.xml'"
fi

# The commands the runtime hands out are ones the policies allow, in both forms.
for command in "mvn -B test -Dtest=" "mvn -s settings.xml -B test -Dtest=" \
               "mvn -B test-compile" "mvn -s settings.xml -B test-compile"; do
  if grep -qF "\"Bash($command" "$SCRIPT_DIR/../claude/settings.exploit.json"; then
    ok "exploit policy allows '$command…'"
  else
    nok "exploit policy does not allow '$command…'"
  fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
