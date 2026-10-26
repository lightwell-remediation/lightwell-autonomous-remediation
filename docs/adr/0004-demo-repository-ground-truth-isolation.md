# ADR-0004: Isolate the Demo Ground Truth from the Agent's Repository

## Status

Accepted

## Date

2026-10-15

## Layer

Platform

## Context

`lightwell-remediation/lw-apache-cxf-sample` is the application the remediation agent is
pointed at. Its README documents, in full, the answer the agent is supposed to produce:

- the affected component, `pkg:maven/org.apache.cxf/cxf-rt-rs-security-oauth2@4.2.2`
- the four CVEs that affect it
- the Lightwell remediated version
- the exact `pom.xml` edit that applies the fix

That documentation is valuable. The team wants it, and other demos use the repository as a
worked example. But an agent that reads it does not analyze anything: it copies the answer,
and the demo stops demonstrating autonomous remediation.

Hiding the block from the agent is harder than deleting it, for two reasons.

**History is readable.** `agent-runtime/run-agent.sh` clones the application repository in
full, with no `--depth`, and `agent-runtime/claude/settings.json` allows `Bash(git log:*)`,
`Bash(git diff:*)` and `Bash(git checkout:*)`. Any of the three recovers deleted content:

```bash
git log -p README.md
git diff <before> <after>
git checkout <before> -- README.md   # then Read
```

Those entries cannot simply be dropped. The agent's deliverable is a branch, a commit and a
pull request; it needs `git diff` to review its own patch and `git checkout` to create its
branch. Permissions are the wrong layer for this problem.

**Forks share storage.** Per [GitHub's *About forks*][forks], "commits pushed to any
repository in a network can be accessible from other repositories in that network" and Git
data "may be accessed from any repository in the same network, including the upstream
repository, even after a fork is deleted". A fork is a view over the parent's objects, not
an isolated copy.

## Options Considered

### Option 1: Fork the sample and delete the section in the fork

Keeps `git`-level sync with upstream, which is the reason a fork is attractive: the sample
will keep changing and the demo should follow.

Rejected. The deletion commit leaves the content one `git log -p` away, and rewriting the
fork's history to remove it breaks the parent relationship — `gh repo sync` and upstream
merges stop working, and each sync reintroduces the documented README. The fork gives sync
*because* it shares history, and shared history is exactly what must not exist here. The two
halves cannot be had together.

### Option 2: Deny `Read` on the README in the harness settings

Cheap to apply, and composes with anything else.

Rejected as a primary mechanism. `Grep`, `Glob` and the three `git` entries above all bypass
a path deny rule. It is friction, not isolation.

### Option 3: Move the Lightwell section out of the sample entirely

A single repository, no synchronization, no duplication — the documentation would live in
this repository's `docs/` instead, which the agent never clones.

Rejected. It requires rewriting the sample's history once to drop commit `37369b7`, and it
takes the explanation away from the code it describes, which is what makes the sample useful
to the team and to the other demos.

### Option 4: A separate repository, synchronized by content

A second repository, `lightwell-remediation/lw-apache-cxf-demo`, created empty — not forked —
and populated by `scripts/sync-demo.sh` from the sample's working tree with the marked blocks
removed. Every commit of the demo repository is built from an already-filtered tree, so no
revision of it ever contains the ground truth, no matter how its history is inspected.

Selected.

## Decision

Publish the agent's repository from the sample by content, not by fork.

0. A path listed in `NOT_PUBLISHED` never reaches the demo repository. The markers
   handle a block inside a file; this handles a whole file whose problem is not what
   it says but where it would run. `.github/workflows/sbom.yml` is the case: correct
   in the sample, and in the demo repository it both fails on every remediation and
   fights the pipeline for the file it writes.
1. In the sample, the sensitive block is wrapped in `<!-- demo:strip-start -->` /
   `<!-- demo:strip-end -->` markers. The markers document themselves: whoever edits the
   README sees that the block does not travel downstream.
2. `scripts/sync-demo.sh` clones the sample shallow, replaces the demo repository's tree with
   it, removes every marked block, and commits. The demo repository's history is its own and
   starts clean.
3. A guard greps the filtered tree for `rhlw-|RHLW-|CVE-[0-9]{4}-[0-9]+|packages\.redhat\.com|predisclosure` and fails the sync if
   anything matches. A new hint added to the sample without markers stops the sync instead of
   travelling silently.
4. Sync commit messages stay terse. `git log` is on the agent's allowlist, so naming the
   upstream repository or mentioning that a block was removed would itself disclose that
   content is being withheld.
5. Both repositories are private. `APP_REPO` points at `lw-apache-cxf-demo`.

What deliberately stays in the demo repository:

| Kept | Why |
|---|---|
| The CycloneDX SBOM | The legitimate input. Deriving the finding from it is the thing being demonstrated |
| Build, test and run instructions | The agent must compile and verify its patch |
| `settings.xml` with the Lightwell repositories enabled | Infrastructure. The agent must be able to resolve the remediated artifact once it works out which one it needs |
| `cxf-rt-rs-security-oauth2:4.2.2` in `pom.xml` | The vulnerability itself |

The `lightwell-remediated` profile name in `settings.xml` is a soft hint. It is accepted:
in a real enterprise that repository configuration exists, and the agent still has to
determine the component, the CVEs and the exact remediated version.

## Consequences

### Positive

- No revision of the agent's repository contains the answer — verified against every object
  in the repository, not just the checked-out tree.
- The sample keeps its documentation and keeps evolving, for the team and the other demos.
- The guard converts "someone documented a new hint" from a silent demo failure into a
  failed sync.
- Not being a fork, the demo repository shares no object network with the sample.

### Negative

- Two repositories to keep aligned, and a script to run when the sample changes. Sync is
  manual until a workflow runs it.
- The demo repository's history is synthetic: it does not show how the application was
  actually written.
- The markers must be maintained by hand. The guard catches the known patterns, not an
  arbitrary new hint phrased differently.

## Validation

Against a fresh clone of `lw-apache-cxf-demo`, on 2026-10-15:

```bash
git log -p --all                     | grep -cEi 'rhlw-|CVE-[0-9]{4}-'   # 0
git rev-list --all --objects | cut -d' ' -f1 | git cat-file --batch \
                                     | grep -acEi 'rhlw|CVE-[0-9]{4}-'   # 0
gh repo view ... --json isFork       # false, parent null, PRIVATE
```

The last check decompresses all 27 objects in the repository (232 KB) rather than reading
the working tree, so content reachable only by SHA would still be found.

## Related Decisions

- [ADR-0003](0003-agent-runtime-packaging-and-credentials.md) — the clone and permission
  model this ADR works within

## References

- [GitHub — About forks][forks]
- `scripts/sync-demo.sh`
- `agent-runtime/claude/settings.json` — the allowlist that makes history readable

[forks]: https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/working-with-forks/about-forks
