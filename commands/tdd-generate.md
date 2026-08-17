---
description: Write and run the tests from an approved /tdd-plan checklist
argument-hint: [target] (optional - defaults to the most recently approved /tdd-plan checklist in this conversation)
---

Write and run tests for a checklist `/tdd-plan` already produced and you've approved.

**1. Confirm a plan exists**
- If no `/tdd-plan` checklist exists earlier in this conversation for `$ARGUMENTS` (or it isn't obvious which one to use), say so and suggest running `/tdd-plan` first rather than improvising a case list here.

**2. Generate tests**
- Write tests for the confirmed checklist, matching the framework and conventions from `/tdd-audit`/`/tdd-plan`: same naming pattern, same file placement, same assertion style already used elsewhere in the repo.

**3. Run and report**
- Run the new tests with the repo's actual test command — sourced from a real signal (`package.json` scripts, CI config, Makefile, etc.), never guessed, same discipline as `/onboard`.

**Report**: what tests were written and where, the run command used, and the pass/fail result plainly, with output on any failure.

Close by reminding the user — not doing it for them — that deliberately breaking the implementation to prove the tests actually fail is the strong next move to make live, on camera, themselves. Do not perform that break automatically.
