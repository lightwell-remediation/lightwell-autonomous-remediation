# Public target application: document-intake-service

> Status: public **template** since 2026-10-26; the pipeline runs against a
> private copy of it (path B of [replicate.md](replicate.md)). ADR-0004 and the
> `lw-apache-cxf-*` path are unchanged.
> Do not copy anything from this document into the target repository: the
> agent clones it in full and would read the answer.

## Why it exists

Publishing our repositories may expose Lightwell information we should not
publish. The remediation process stays identical, but it can point at a
**brand-new public application with no Lightwell content**, whose vulnerable
dependency comes from Maven Central and whose fix is an upstream release.

| | |
|---|---|
| Repository | [`lightwell-remediation/document-intake-service`](https://github.com/lightwell-remediation/document-intake-service) (public) |
| Local checkout | `~/git/ai/agents/document-intake-service` |
| Stack | Java 21, JDK `com.sun.net.httpserver`, `commons-fileupload:1.4` (one runtime dependency) |
| Vulnerability fed to the run | **CVE-2023-24998** / [GHSA-hfrx-6qgj-fp6c](https://osv.dev/vulnerability/GHSA-hfrx-6qgj-fp6c) |

## The vulnerability and the expected fix

The advisory: FileUpload before 1.5 does not limit the number of request parts,
and the new option `FileUploadBase#setFileCountMax` "is not enabled by default
and must be explicitly configured". The agent therefore has to **bump the
version and change code** — what a dependency bot cannot do. A bump alone
leaves the exploit test red.

Expected patch: `commons-fileupload` `1.4` → `1.5` (the OSV `fixed` event) and
`upload.setFileCountMax(...)` in `DocumentsHandler`. If the 1.5 exception for
that limit extends `FileUploadException`, the existing handler answers `400`
(not verified against the 1.5 source yet).

Verified on 2026-10-26 against osv.dev and Maven Central:

| fileupload | commons-io (transitive) | Open advisories |
|---|---|---|
| 1.4 (start) | 2.2 | CVE-2023-24998, CVE-2025-48976 (fixed 1.6.0), commons-io CVE-2021-29425, CVE-2024-47554 |
| 1.5 (OSV fixed) | 2.11.0 | CVE-2025-48976, commons-io CVE-2024-47554 |
| 1.6.0 | 2.19.0 | none found |

Known and accepted: following
[vulnerability-analysis.spec.md](../specs/agents/vulnerability-analysis.spec.md)
("take the fixed event") the agent lands on 1.5, so the regenerated SBOM still
carries residual advisories. Told as "inventory validation catches what
remains". Not verified: what else changes in 1.6.0 (source not inspected).

Alternatives considered and discarded: SnakeYAML CVE-2022-1471 (fix also needs
code, but RCE content is touchier for a public repo; 2.0 API break unverified),
Commons Text CVE-2022-42889 (bump-only, does not exercise the agent),
jackson-databind (15+ open advisories on one version, muddy).

## How the app meets the pipeline contract

From `agent-runtime/run-agent.sh`, `run-suite.sh`, `generate-sbom.sh`,
`lib/test-results.js`, `lib/assess-exploit.js`:

| Requirement | How |
|---|---|
| Single-module Maven, root `pom.xml`, `jar` | Yes |
| `target/<artifactId>-<version>.jar` containing the dependencies | `maven-shade-plugin` replaces the main jar (no classifier, no `finalName`, no dependency-reduced pom). `generate-sbom.sh` runs syft on that jar: a thin jar would yield an SBOM without FileUpload |
| JDK 21 + image Maven (3.9.9) | `maven.compiler.release=21`, plugins pinned |
| No `settings.xml` | Central only |
| Baseline green, deterministic, ≥1 test | 12 JUnit 6 tests, port 0, `@TempDir`; green 3 runs in a row in the runtime image |
| Surefire XML at root | `target/surefire-reports/TEST-*.xml` |
| Exploit phase cannot edit `pom.xml` | JUnit Jupiter and JDK `HttpClient` already usable; `MultipartBody` test helper exists |
| Vulnerable dependency direct in root pom | `commons-fileupload` via property `commons-fileupload.version` |
| Reachable | `DocumentsHandler` calls `FileUpload.parseRequest(RequestContext)` |
| Root `sbom.json` | Generated with the image's `generate-sbom.sh`: fileupload 1.4, commons-io 2.2, the app |

`javax.servlet-api:4.0.1` is `provided`: javac needs it to resolve the
deprecated `parseRequest(HttpServletRequest)` overload. It is not in the jar
nor in the SBOM. Using the streaming API instead would avoid it but would
change the vulnerable code path (`setFileCountMax` is enforced in `parseRequest`).

## Keeping the answer out of the repository

The agent clones in full and may use `git log/diff/checkout` (same reasoning as
[ADR-0004](adr/0004-demo-repository-ground-truth-isolation.md)).

- Fresh repository, not a fork; one commit with a neutral message.
- Nothing about part counts in code, tests, README or `AGENTS.md`.
- The target repo's `AGENTS.md` is neutral development guidance only, and there
  is **no `CLAUDE.md`** on purpose: Claude Code would load it into the agent's
  context during a run.
- Leak guard before every push (and run on a fresh clone on 2026-10-26: 0
  matches over 29 objects):

```bash
P='CVE-|GHSA-|fileCountMax|FileCountLimit|lightwell|rhlw|redhat|dseveria|vulnerab|outdated|insecure|exploit|remediat|number of parts|part count|fileupload[^"]*1\.5|1\.6\.0'
git log -p --all | grep -ciE "$P"                                          # 0
git rev-list --all --objects | cut -d' ' -f1 | git cat-file --batch | grep -aciE "$P"   # 0
```

## GitHub settings (state on 2026-10-26, after going public)

| Setting | State |
|---|---|
| Visibility | **Public**, marked as a template. Forking cannot be disabled on a public org repository; nothing in it needs protecting |
| Dependabot alerts | Disabled (`GET /vulnerability-alerts` → 404) |
| Dependabot security updates | Disabled. Would open a PR with the bump |
| Code scanning default setup | `not-configured` |
| Secret scanning / push protection | Disabled |
| Branch protection on `main` | 1 approval, no force push, no deletion |
| Wiki, Projects | Disabled |

The org (free plan) enables nothing for new repositories, and its "GitHub
recommended" code security configuration is not a default nor attached to this
repository. If someone attaches it, Dependabot alerts and code scanning come
back on: re-check after any org-level change.

## After every demo run

- **Never merge** the agent's pull request; close it.
- **Delete the `remediate/*` branch.** A full clone fetches remote branches, so
  a leftover branch hands the next run the answer. Closed-PR refs
  (`refs/pull/*`) are not fetched by a normal clone, and the agent has no `gh`
  in analyze, exploit or patch.

## Running against it

Nobody runs against this repository, us included: create a private copy from
the template and point `APP_REPO` at the copy ([replicate.md — step 1](replicate.md#1-the-application-to-remediate)).
Ours is `lightwell-remediation/document-intake-service-demo`.

- The PAT is scoped to the copy: Contents RW, Pull requests RW, Metadata R.
- No `LW_*` values and no `lightwell-lightwell` Secret are needed.
- The vulnerability record is committed:
  `scripts/run-remediation.sh deploy/pipelineruns/osv/GHSA-hfrx-6qgj-fp6c.json`.
- The first run on new dependencies takes 15+ minutes: warm the Maven cache
  PVC with one run before demoing.

Validated on 2026-10-26 with only the MaaS and GitHub Secrets in the
namespace. The first run returned a regression twice: the exploit test sent
exactly 1000 parts and the patch chose a limit of 1000, so the attack still
fitted. After the exploit and patch prompts were told not to test on a
boundary and to check the chosen limit against the exploit test, the second
run delivered: `1.4` → `1.5`, `setFileCountMax` with a default of 200, an
exploit test sending 5000 parts, and the regenerated SBOM.

## Rebuilding and checking locally

Same image, JDK and Maven as the pipeline. `:U` chowns the mount to the
container user, so ownership is reclaimed afterwards (as `reclaim()` in
`scripts/verify-backport-resolves.sh` does).

```bash
cd ~/git/ai/agents/document-intake-service
podman run --rm --user 61000:0 -v "$PWD:/app:Z,U" -v /tmp/dis-m2:/home/claude-agent/.m2:Z,U \
  -w /app -e REPO_DIR=/app --entrypoint bash localhost/lightwell-agent-runtime:latest \
  -c 'mvn -B test && generate-sbom.sh /app/sbom.json'
podman unshare chown -R 0:0 "$PWD" /tmp/dis-m2
```

Builds in the container can leave a `.m2/` in the project; it is gitignored.
