---
name: ralph-code-review
description: Review the current uncommitted changes for correctness bugs at a stated effort level (low, medium or high), verify every candidate finding adversarially, and report only the ones that survive. Use when a ralph attempt must clear its review gate before checking a checklist item off, or whenever asked to review the working-tree diff before committing.
---

# ralph-code-review

A review gate. It answers exactly one question: **is there a correctness bug in
the changes that are about to be committed?**

It is the pi counterpart of Claude Code's built-in `/code-review`, and it exists
because `ralph-pi` needs a gate that means the same thing `ralph-claude`'s does.
The effort words match that command's levels so a `--review-gate` value carries
the same meaning whichever wrapper is driving the loop.

## Invocation

```
/skill:ralph-code-review <effort>
```

`<effort>` is `low`, `medium` or `high`. When it is missing, use `medium`.

## Scope

Review **the changes, not the repository.** The diff is:

```bash
git --no-pager diff HEAD        # unstaged + staged, against the last commit
git status --porcelain          # and anything untracked the change added
```

Read untracked files the change introduced — they are part of it even though
they are absent from the diff. Read enough of each touched file around the
change to judge it; a hunk read without its surroundings is how a reviewer
invents bugs that aren't there and misses the ones that are.

Do **not** review code the change did not touch, and do not open a rewrite of
something that merely offends taste. Pre-existing problems are out of scope
unless this change makes one reachable that was not reachable before.

## Effort levels

| Effort | What to report |
|---|---|
| `low` | Only bugs you are certain of. Silence over speculation. |
| `medium` | Fewer, high-confidence findings. The default. |
| `high` | Broader coverage; a well-argued but uncertain finding may be reported, clearly marked as uncertain. |

Effort changes the confidence bar, never the honesty bar. A finding you cannot
construct a concrete failure for is not a finding at any level.

## What counts as a finding

In priority order:

1. **Correctness** — wrong output, wrong state, a case the code silently gets
   wrong. Off-by-one, inverted condition, wrong variable, lost error.
2. **Crashes and unhandled failure** — null/undefined dereference, unchecked
   index, a partial write left behind on the error path, a swallowed exception
   that hides a real failure.
3. **Contract violation** — the change breaks a caller, a documented interface,
   a serialized format, or an invariant the surrounding code relies on.
4. **Concurrency and resource handling** — a race the change introduces, a file
   or lock that is not released on every path.
5. **Security** — injection, path traversal, a secret written where it will be
   read back or logged.

Not findings: formatting, naming you would have chosen differently, a missing
abstraction, test coverage you wish existed, or anything whose only argument is
that you would have written it another way.

## Procedure

### 1. Review

Work through the diff and collect **candidate** findings. For each one, write
down, before going further:

- the file and line
- what is wrong, in one sentence
- **a concrete failure**: the specific input or state that reaches it, and what
  goes wrong when it does

If you cannot write that third line, you do not have a finding. Drop it.

### 2. Verify — adversarially

This pass is the point of the gate, and it is done **against yourself**. For
every candidate, try to prove it wrong. Re-read the code and ask:

- Does a guard earlier in the function already exclude the input I assumed?
- Does the caller — find it and read it — ever actually pass that value?
- Is the type, schema or invariant already enforced somewhere I did not look?
- Does a test in the change already cover this path and pass?
- Am I asserting a language or library behaves a way I have not checked? If the
  finding rests on that, check it.

A candidate that survives all of it is a finding. One that does not, **drop
silently** — do not report it as "worth a look". A gate that reports doubt as
defect trains its reader to ignore it.

### 3. Report

Report only survivors, most severe first:

```
<file>:<line> — <one-sentence defect>
  Failure: <the concrete input/state, and what goes wrong>
  Fix: <the specific change that resolves it>
```

When nothing survives, say exactly this and nothing more:

```
No surviving findings.
```

That line is what the loop reads to decide the gate is clear, so do not soften
it, qualify it, or pad it with observations.

## Boundaries

This skill **reviews and reports. It changes nothing.**

- Do not edit, fix, stage, commit, revert or push. The caller decides what to do
  with the findings; in a ralph attempt, the caller fixes them and re-runs the
  gate itself.
- Do not post comments to a forge, open issues, or contact anything over the
  network.
- Do not run the test suite as part of the review — the loop has already run it,
  and running it again only burns an attempt's budget. Reading a test to check
  whether it covers a path you are suspicious of is fine, and encouraged.
