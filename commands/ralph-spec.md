---
description: Generate a SPEC.md checklist for the `ralph` fresh-context implementation loop (~/.local/bin/ralph --spec SPEC.md) from a feature description or an existing plan doc.
argument-hint: [feature description, or a path to an existing plan/design doc to convert]
---

Generate a `SPEC.md` at the repo root, formatted for `ralph` (`ralph --spec SPEC.md`) to execute as a sequence of fresh-context attempts, one checklist item at a time.

**Preconditions**
- Confirm this is a git repo — ralph relies on git history as the only memory between attempts. If not, stop and suggest `/onboard` or `git init` first.
- Check for an existing `SPEC.md` at the repo root with unchecked items. If found, stop and ask whether to append to it, replace it, or write to a different path — never silently clobber in-progress ralph work.

**Source of design**
- If `$ARGUMENTS` is a path to an existing plan/design doc (e.g. something `/plan` already produced), read it and treat its decisions as the primary source — only ask clarifying questions for gaps it doesn't cover.
- Otherwise treat `$ARGUMENTS` as a feature description and design from scratch: read `CLAUDE.md` and skim the touched areas of the codebase first for existing conventions/utilities to reuse, same discipline as `/plan` — don't invent what's already there.
- Identify decisions that would fork many checklist items if answered differently (framework/library choice, data model shape, scope boundaries, persistence, etc.). Ask about those via `AskUserQuestion`, each with a recommended default. Don't ask about anything with an obvious or conventional answer.

**Write SPEC.md** with two sections:
1. **Design Reference** — every decision more than one checklist item depends on: stack/library choices, file/package layout, data model fields, API surface, config values, testing conventions. Written once, so every item can point back to it instead of re-deriving or silently diverging on it.
2. **Checklist** — ordered `- [ ] task` lines. Each item must:
   - be completable **and** testable by one fresh-context session with zero memory of any prior attempt (a passing test suite is ralph's only success signal)
   - never depend on a later item — order data-layer before service before controller, backend before frontend, etc.
   - be a single physical line — ralph's parser (`grep -m1 -E '^[[:space:]]*-[[:space:]]\[[[:space:]]\]'`) only reads the first line of a match, so a soft-wrapped item silently breaks
   - name the specific files/classes/endpoints/routes it touches, and say "(see SPEC.md's Design Reference)" so the attempt knows to go read that section for the shared detail
   - end with the concrete command that verifies it (e.g. `mvn -q test`, `npm test`)

**Validate before reporting**
- `grep -cE '^[[:space:]]*-[[:space:]]\[[[:space:]]\]' SPEC.md` matches the number of items you intended to write.
- Confirm the file is at the repo root named exactly `SPEC.md` — ralph's default `--spec` lookup, and the only convention needed; no extra header/marker.
- Re-read every checklist item on its own, as if it were the only line you'd been handed (which is literally true for a ralph attempt). Reject any item that says "as above," "using the X from the previous step," or otherwise leans on another item's text instead of naming the file/class/endpoint itself — fix it in place before reporting, don't just note it.

**Report**: item count, a one-line summary of what's in the Design Reference, and the exact command to run it (`ralph --spec SPEC.md`, pointing to `ralph --help` for `--max-attempts`/`--items`/`--review-gate`/`--model`).

Stop there — do not invoke `ralph` itself. This command's job ends at a validated `SPEC.md`; running the loop is a separate, explicit step for the user.
