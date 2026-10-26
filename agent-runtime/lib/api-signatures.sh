#!/usr/bin/env bash
# api-signatures.sh — the public API of the classes a defect names.
#
# Usage: api-signatures.sh <repo-dir> <analysis.json> <output>
# Exit:  0 signatures written, or nothing to write
#        1 the classpath could not be resolved
#
# A test that exercises a defect has to construct the types the flawed class
# works with, and those live in a jar rather than in the repository. An agent
# without them searches for them: a measured run spent 28 of its 30 tool calls
# looking for the dependency on disk — `find ~/.m2`, reads of /home and of
# directories — and never wrote anything.
#
# Reading signatures out of a jar is javap, so it happens here (ADR-0005).
# What a test should assert is not, and that is what the session is for.

set -uo pipefail

REPO_DIR="${1:?usage: api-signatures.sh <repo-dir> <analysis.json> <output>}"
ANALYSIS="${2:?}"
OUTPUT="${3:?}"

log() { printf 'api-signatures: %s\n' "$*" >&2; }

command -v javap >/dev/null || { log "javap not available"; exit 1; }
[[ -f "$REPO_DIR/pom.xml" ]] || exit 0

# The symbols the analysis searched for are the classes the defect lives in.
mapfile -t symbols < <(
  node -e '
    try {
      const a = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      const s = (a.reachability && a.reachability.symbols_searched) || [];
      // Methods are named alongside classes; only the capitalised ones are types.
      process.stdout.write(s.filter(x => /^[A-Z]/.test(x)).join("\n"));
    } catch {}
  ' "$ANALYSIS" 2>/dev/null
)

(( ${#symbols[@]} )) || { log "the analysis names no classes"; exit 0; }

mvn_args=(-B -q dependency:build-classpath -Dmdep.outputFile=/tmp/cp.txt)
[[ -f "$REPO_DIR/settings.xml" ]] && mvn_args=(-s settings.xml "${mvn_args[@]}")

( cd "$REPO_DIR" && mvn "${mvn_args[@]}" ) >/dev/null 2>&1 \
  || { log "cannot resolve the classpath"; exit 1; }

[[ -s /tmp/cp.txt ]] || { log "the classpath came back empty"; exit 1; }
classpath="$(cat /tmp/cp.txt)"

# Every class in the same package as a named symbol, not just the symbol
# itself: a test has to build the arguments its methods take, and those are
# its neighbours.
packages=()
for symbol in "${symbols[@]}"; do
  while IFS= read -r entry; do
    [[ "$entry" == *.jar ]] || continue
    while IFS= read -r cls; do
      packages+=("$(dirname "$cls")")
    done < <(unzip -Z1 "$entry" "*/$symbol.class" 2>/dev/null)
  done < <(tr ':' '\n' <<<"$classpath")
done

(( ${#packages[@]} )) || { log "none of ${symbols[*]} found on the classpath"; exit 0; }

mapfile -t unique_packages < <(printf '%s\n' "${packages[@]}" | sort -u)

: >"$OUTPUT"
count=0
for package in "${unique_packages[@]}"; do
  while IFS= read -r entry; do
    [[ "$entry" == *.jar ]] || continue
    while IFS= read -r cls; do
      # Inner and anonymous classes add noise without adding API.
      [[ "$cls" == *'$'* ]] && continue
      fqcn="${cls%.class}"; fqcn="${fqcn//\//.}"
      if javap -cp "$classpath" "$fqcn" >>"$OUTPUT" 2>/dev/null; then
        count=$((count + 1))
      fi
    done < <(unzip -Z1 "$entry" "$package/*.class" 2>/dev/null)
  done < <(tr ':' '\n' <<<"$classpath")
done

if (( count == 0 )); then
  rm -f "$OUTPUT"
  log "no signatures could be read"
  exit 0
fi

log "$count class signature(s) from ${#unique_packages[@]} package(s)"
