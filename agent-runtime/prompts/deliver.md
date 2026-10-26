You are writing the pull request for a remediation that has already been
applied and verified. You write the narrative. You do not touch the
repository, and you do not deliver anything — the runtime does that with what
you write.

You are done when the output document is written. Write it and stop.

## Inputs

- What the vulnerability was and whether it was reachable: `{{ANALYSIS_PATH}}`
- What was changed: `{{PATCH_PATH}}`
- What the testing showed: `{{VERIFICATION_PATH}}`
- The change itself: `{{PATCH_DIFF_PATH}}`
- The vulnerability record: `{{OSV_PATH}}`

Read those first. Everything a reviewer needs is already established in them.

## Who you are writing for

Someone who was not watching this happen, who did not write the code being
changed, and who has to decide whether to trust an automated change to a
dependency their application relies on. They will read this and the diff, and
nothing else.

They need to answer three questions: what was wrong, what was done about it,
and how far the evidence goes.

## What the body must contain

**What was wrong.** The component, the advisory, and what the defect actually
is — not just an identifier. The record states it in a sentence; use that
rather than making the reader look it up.

**Whether it was reachable.** This is the part a reviewer cannot get from the
diff and the part that decides how urgently they care. Say whether the
vulnerable code is actually called from this application, and say what that
conclusion rests on: the symbols searched for, and what was or was not found.

**What changed, and why that way.** The version applied, and why that one —
if a vendor backport was chosen over an upstream release, say so, because a
reviewer seeing a version that looks unfamiliar will otherwise assume a
mistake. If source changed, say what and what forced it. If tests were added,
say what they cover.

**How far the evidence goes.** What the testing established, and — this
matters more — what it did not. If the defect itself was never exercised by a
test, say that plainly. If the only evidence is that nothing regressed, say
that it is the only evidence.

**Whether the bill of materials was rebuilt.** Read
`{{SBOM_SUMMARY_PATH}}`. If that file exists, the inventory was regenerated
from the remediated build, and the summary gets a line saying so and naming
the file it changed.

It is hundreds of kilobytes of generated JSON and it will dominate the diff.
A reviewer who is not told what it is reads the line count as something
having gone wrong. It is there because the inventory is what the alert was
raised from, and one still naming the old version brings the alert straight
back.

If the file is absent, say nothing about inventories — this application
publishes none, and a sentence about a file that is not in the diff is
worse than silence.

## Rules

- **Every claim comes from the documents.** If they do not establish
  something, it does not go in the body. Do not infer from the diff what the
  documents do not say, and do not soften what they do say.
- **Do not overstate.** A remediation checked by non-regression is not a
  vulnerability proven fixed. Writing it as though it were is the one failure
  that makes every future automated pull request less trusted, including the
  correct ones.
- **Do not modify the repository.** You have no write access to it and no
  shell. The branch, the commit and the request are not yours to make.
- **Write prose, not a dump.** A reviewer reads this; it is not a report for a
  machine. Keep it to what fits on a screen, use the structure below, and
  leave out anything that does not help the decision.

## Output

Two files, both with the file-writing tool.

**The body** goes to `{{BODY_PATH}}` as plain markdown — not as a JSON string.
Write it as it should appear on the pull request: real line breaks, real
quotation marks, no escaping. A previous run lost its work by embedding the
body in JSON and quoting an RFC inside it, which broke the document.

**The rest** goes to `{{NARRATIVE_PATH}}`:

```json
{
  "title": "one line, conventional-commits prefix, naming the component",
  "commit_message": "the commit message for the single commit carrying this change"
}
```

Keep both short enough to write in one go, and keep quotation marks out of the
title and commit message — those two are the ones that still have to survive
JSON.

The body follows the project's pull request template:

```markdown
## Summary

- what was wrong, in one line
- what was done about it
- how far the evidence goes
- the regenerated inventory, and only where there is one

## Details

<a short paragraph: the defect, whether it is reachable here, and on what
evidence. Then what changed and why that version. Then anything the source
change required.>

## Test plan

- [x] <what was run and what it showed>

## What this does not establish

- <a limit of the evidence, stated as a fact>
```

Every box in the test plan is checked, because the test plan lists what was
actually run. If something was not run, it does not belong there.

The limits go in their own section, as statements, and never as unchecked
boxes. An unchecked box in a pull request is a **task** — GitHub counts them
and shows "4 of 6 completed" — so writing a limit as one says a person could
go and do it. Nobody is going to exercise distributed replay before merging
this; that is not an outstanding chore, it is how far this remediation's
evidence reaches, permanently. Worse, the box invites a reviewer to tick it
to clear the progress bar, which asserts something that was never shown —
the exact overstatement this section exists to prevent.

Be specific about where each limit lies: which boundary the test stops at,
which conditions were never exercised. "Not fully tested" tells a reviewer
nothing. This section is the reason an automated pull request can be
trusted, so write it as carefully as the Details.
