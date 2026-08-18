---
description: Onboard onto unfamiliar code - git baseline, CLAUDE.md via real codebase scan, verify it builds untouched. Stops before planning/editing.
argument-hint: [git-url] (optional - clone this first; omit if already sitting in the code)
---

If `$ARGUMENTS` looks like a git URL, clone it into a new directory here and `cd` into it before continuing. Otherwise assume the current directory already contains the code (raw drop, zip extract, whatever form it arrived in).

**1. Git baseline**
- If `.git` doesn't exist: `git init`, stage everything, commit as `"baseline: as received"`. This is the safety net for the whole session — from this point on, every edit (yours or mine) is diffable against a known-good starting point, even though nobody handed you a repo.
- If `.git` already exists: do not re-init and do not force a commit over their history. Just confirm `git status` is clean; if it's dirty, say so plainly rather than committing on their behalf.

**2. Generate context** — scan the codebase and write/update `CLAUDE.md` with:
- What the project is/does, briefly
- Real build/test/run commands — sourced from an actual signal (README, CI config under `.github/workflows/`, `.gitlab-ci.yml`, a Makefile, `package.json` scripts, etc.), never guessed
- Directory structure, at a level useful for navigating, not exhaustive
- Any obvious conventions worth knowing (test framework, linter/formatter config present)

If a `CLAUDE.md` already exists, update it rather than overwriting wholesale, and say what changed.

**3. Verify the untouched baseline actually builds/runs**
- Detect the ecosystem from manifest files (`package.json`, `pom.xml`, `go.mod`, `Cargo.toml`, `pyproject.toml`/`requirements.txt`, etc.)
- Use the real command found in step 2, not a guess
- Run it and report pass/fail plainly. **If it fails on the untouched baseline, say so explicitly and clearly** — that's essential information to have on record before anything changes, since it means whatever's broken isn't something you introduced.

**Report**, concise: ecosystem detected, fresh init vs. existing repo, what's now in `CLAUDE.md`, and the baseline build/test result (pass/fail, with output on failure).

Stop there. Do not move into planning or make any code changes — this command's job ends at a verified, documented baseline. Planning depends on the actual task, which isn't known yet.
