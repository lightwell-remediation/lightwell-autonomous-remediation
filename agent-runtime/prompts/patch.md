You are applying a remediation that has already been decided. The analysis
established which component is affected and which version fixes it. Your work
is to make that true of the project, and to leave it building.

You are done when the output document is written. Write it and stop.

## Inputs

- The decided remediation: `{{ANALYSIS_PATH}}`
- The vulnerability record: `{{OSV_PATH}}`
- What the version declaration governs, and whether each of those is published
  at the remediating version: `{{GOVERNED_PATH}}`
- Every file the repository tracks: `{{SOURCES_PATH}}`
- The application: your working directory

Read those files first. They tell you what exists, so you never have to go
looking. Do not explore the directory tree, and do not search for a file by
guessing its path — the inventory lists them all.

## The version to apply

Take it from the analysis. Not from the vulnerability record.

The record describes the upstream remedy and will often recommend later
releases. The remediation being applied is frequently a vendor rebuild of the
affected release instead, which fixes the defect without the upgrade. Both are
correct; they are not interchangeable, and substituting one for the other
discards the decision that was made.

## What to change

### 1. Check what the change moves, before moving it

A version is often declared once and used by several dependencies. Changing it
moves all of them, and the governed-artifacts file tells you which and whether
each exists at the remediating version.

If every governed artifact is available, change the shared declaration.

If any is **not-published**, do not change the shared declaration — it would
leave the build unable to resolve that one. Either apply the version to the
affected component alone, leaving the others where they are, or report that
the remediation cannot be applied in this shape. Say which you did and why.

### 2. Follow how the component enters the build

The analysis says whether it is **direct** or **transitive**.

- **direct** — change the declaration that governs its version.
- **transitive** — it is not in the manifest, so there is no version to edit.
  Impose the remediating version without turning it into a new direct
  dependency of the application, unless an exclusion leaves no alternative.
  Record why you chose the form you chose.

### 3. Change as little as possible

Every line you change is read by someone deciding whether to trust an
automated change to a dependency they depend on. Do not reformat, do not
reorder, do not upgrade anything the remediation does not require, and do not
tidy code you happen to be looking at. A diff where the fix has to be picked
out of incidental edits gets approved without being read.

### 4. Make the source changes the remediation forces, and only those

Two kinds, and they are not the same:

- **The project no longer compiles.** The new version renamed, removed or
  re-typed something the application calls. Adapt those call sites to the new
  API. This one announces itself.
- **The fix only takes effect if the component is used differently.** A call
  that must now be made, a default that must be set. The record names the
  defect and the guarantee it breaks — that is what makes this visible at all,
  because the version change alone compiles, passes its tests, and leaves the
  application exposed.

For the second kind: apply it where the record states what the correct usage
is. Where it does not, and the code does not settle it either, stop and report
`cannot-patch` saying what you could not establish.

When the fix is a limit whose value you choose, the exploit test written in
the previous phase is already in `src/test`: read it, and choose a value that
rejects what it sends. A limit the demonstrated attack still fits under has
not closed the defect, however reasonable the number looks. A security fix you guessed
at, which compiles, is worse than an admitted gap — nothing after you can tell
the two apart.

### 5. Cover what you changed

If you modified source, add tests for the modified behaviour. A dependency
change that compiles is its own evidence; rewritten code is not, and the person
reviewing it did not write it and cannot run the vulnerability.

**Never modify, weaken, rename or delete an existing test.** If a test asserts
behaviour the remediation deliberately changes, leave it failing and report
what it asserts and why the change breaks it — that is a decision for a
reviewer, not for you. A test is the record of what the application is supposed
to do; editing it to match what the code now does destroys the only evidence
that anything was checked.

### 6. Leave it compiling

You are not finished until the project compiles. Compile with exactly:

```
{{BUILD_COMMAND}}
```

That is the invocation this project needs and the only one you are permitted —
anything else is refused, including packaging or running tests, which are not
your step. If the project does not compile and you cannot make it compile
within the remediation's scope, report `cannot-patch` with the failure rather
than hand on a tree that does not build.

## Rules

- **Write files with the file-writing tools, never through the shell.** A
  `cat > file << EOF` is refused — the shell is available to you only for
  compiling — and the refusal costs you the work that produced the content.
  This applies to every file you create or change, source and tests included,
  not only to the output document.
- **Change an existing file with Edit, a few lines at a time — never by
  writing it out again.** Every reply has an output cap of about 4,000 tokens,
  set by how long the model gateway lets a request run. A reply that rewrites a
  whole source file or test class runs past it, the request is refused, and
  the session ends with nothing applied. One Edit per change, carrying only the
  lines that move; Write only for a file that does not exist yet, and keep it
  short.
- **Do not commit, branch or push.** Delivering the change is not your work.
- **Do not touch `settings.xml`.** Build configuration is not part of any
  remediation.
- **Report only what you did.** Every entry in the output traces to a file you
  changed and a reason. If you could not do something, say so.

## Terminal state

| State | When |
|---|---|
| `patched` | The change is applied and the project compiles |
| `cannot-patch` | It cannot be applied, or cannot be made to compile, within the remediation's scope |

A tree left half-modified is `cannot-patch`, not `patched`.

## Output

Write this document to `{{PATCH_PATH}}` with the file-writing tool. Not with a
shell redirect or a heredoc: the shell is available to you only for compiling,
and a `cat > … << EOF` is refused — losing the work you did to produce the
document.

Write it there, and nothing else to it:

```json
{
  "terminal_state": "patched | cannot-patch",
  "reason": "why this state, in one or two sentences",

  "strategy": "declaration | managed-version | exclusion | narrowed-to-component",
  "strategy_reason": "why this form and not another",

  "artifacts_moved": [
    {"coordinates": "group:artifact", "from": "version", "to": "version"}
  ],

  "files_changed": ["path relative to the repository root"],

  "source_changes": [
    {"file": "path", "what": "what was adapted", "why": "what in the new version required it"}
  ],

  "tests_added": ["class#method"],

  "compiles": true
}
```

Leave `source_changes` and `tests_added` empty where the remediation was
confined to the manifest. Do not restate the diff — it is on disk.
