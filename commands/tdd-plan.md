---
description: Build a test-case checklist for a target and stop for approval before any test code is written
argument-hint: [target] (optional - file, function, or description of what needs coverage; defaults to whatever /tdd-audit last established in this conversation)
---

Build a test-case checklist for a target, and stop there — this command's job ends at an approved plan, not code.

**1. Establish the target and context**
- If `/tdd-audit` already ran earlier in this conversation for this target, reuse its framework/conventions findings rather than re-detecting them.
- Otherwise, treat `$ARGUMENTS` as the target (asking if empty) and do the minimum reading/framework-detection needed yourself — same discipline as `/tdd-audit` steps 2-3, just inline.

**2. Build the test-case plan**
- Produce a checklist of cases to cover, grouped by the function/method/path each belongs to.
- Baseline floor — always include, wherever the target's actual inputs make it applicable:
  - nulls / missing values
  - empty collections / empty strings
  - boundary values (min/max, zero, off-by-one, first/last element)
  - error paths (exceptions thrown, error results, invalid input rejected)
- This baseline is a floor, not a ceiling. Add code-specific cases from actually reading the target — branches, loops, conditionals, state/ordering dependencies, anything domain-specific to what the code does. If a baseline case genuinely doesn't apply (e.g. nothing in scope collects anything), say so and drop it rather than force-fitting it.

**Report**: the full checklist, grouped and labeled baseline vs. code-specific.

Stop there — do not write any test code. That's `/tdd-generate`'s job, to run once this checklist looks right to you.
