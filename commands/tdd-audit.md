---
description: Diagnose test coverage and conventions for existing code before planning what to add
argument-hint: [target] (optional - file, function, or description of what needs coverage; if omitted, ask what to target)
---

Diagnose what testing already exists (or doesn't) for a target, before any test-case planning happens.

**1. Identify the target**
- If `$ARGUMENTS` names a file, function, or area, use that as the scope.
- If `$ARGUMENTS` is empty, ask what to target rather than guessing — don't default to "the whole repo."

**2. Read the target**
- Open and read the target code itself, and its callers if that context matters, before assessing anything.

**3. Detect the test framework and conventions**
- Look for a framework already in use: manifest files (`package.json` devDependencies, `pyproject.toml`/`requirements.txt`, `pom.xml`/`build.gradle`, `go.mod`, `Cargo.toml`) and existing test locations (`test/`, `tests/`, `__tests__/`, `spec/`, `*_test.go`, `*Test.java`, etc.).
- If one exists, note its naming, file placement, structure, and assertion style — later steps will match it exactly, not introduce a preferred alternative.
- If none exists anywhere in the repo, propose one based on what's already a dependency for this ecosystem — don't invent a new framework choice silently. State the reasoning in one line and confirm via `AskUserQuestion`; this is the one genuine fork-worthy decision in this command, since it determines every test file's name, imports, and run command from here on.

**4. Assess current coverage**
- Report what's already tested for this target (if anything) and what's conspicuously untested — don't build a case list yet, just name the gap.

**Report**: target identified, framework detected or proposed+confirmed, and the coverage gap found.

This command only diagnoses — building the actual test-case checklist is `/tdd-plan`'s job, not this one.
