---
description: Onboard onto unfamiliar code - git baseline, CLAUDE.md via real codebase scan, verify it builds untouched, then open an OKF bundle and document what is in scope. Stops before planning/editing.
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

**4. Open an OKF bundle for the code** — the same sequence `/okf-init` and `/okf-generate` run, done for you here so onboarding ends with the code documented as well as built. Both stay separately invocable; this step automates the order, it does not replace them. Where their documents disagree with this summary, they win — they are the authority on the details.

- **`command -v okf` first. If `okf` is not installed, print a note saying so and skip the rest of this step**, then go straight to the report. `okf` ships in `claude-toolkit`'s `bin/` and is installed by that repo's `install.sh`; say that in the note so the reader knows where it comes from. Onboarding does not fail over a missing optional tool, and it does not substitute for it either: do not hand-write `okf.json`, `index.md`, or a single concept file. Skip the same way, with the same kind of note, if `okf` is installed but its preflight refuses — it exits 1 naming the tools it is missing. Working without it is `/okf-generate`'s documented fallback, not this command's.
- **This step is placed here on purpose.** The baseline build in step 3 has to run against a tree nobody has added anything to, so that a failure is unambiguously theirs and not yours. Concept files landing first would blur exactly the line step 3 exists to draw. Do not reorder it, and if step 3 failed, still run this step — a bundle over code that does not build is worth having, and the failure is already on record.
- **Run from the repo toplevel.** `okf` takes the bundle root from the current directory, not from the repo, so running it in a subdirectory quietly opens a second bundle nested inside the eventual real one. `cd "$(git rev-parse --show-toplevel)"` before the first call, and use that one root for every call.
- **`okf init`**, with no arguments. **Never `--force`** — onboarding is not the place to overwrite a file that was already there. Read the message rather than the exit status: `okf.json already exists`, that wording and that path, is the one refusal that means the repo is already a bundle. Report it and carry on. Anything else — `index.md already exists` on its own, or a non-regular-file or link refusal — is an unrelated file in the way, so no bundle was configured and there is nothing to document against: report it and skip the rest of this step.
- **Then generate the concepts.** `okf list --missing` is the work list — in-scope sources with no concept file beside them. Read each one, tier it from `okf fanin` and its size, and write the co-located `.md` per `/okf-generate`. Stamp `generated.by: claude-code/<model>` and add **no** `verified` entry: nothing here has been reviewed by a person yet, and `/okf-verify` is how that gets recorded, deliberately and later.
- **Scope comes from `git ls-files`**, so a source git has never been told about is invisible to `okf` however well it matches the globs. On an existing repo that step 1 found dirty, that is a real possibility. Name those files in the report; the fix is `git add`, and it stays the user's call, exactly as in step 1.
- **If scope comes back empty, work out why before proposing anything.** Check `okf list`'s exit status first — non-zero is a failure, usually a malformed `okf.json`, not an empty repo. A clean exit with no output means the globs do not match this layout, the sources are untracked, or the exclusions are doing their job. Say which, and propose the concrete `okf.json` edit if that is the cause. **Do not edit `okf.json` yourself**: a scope decision made silently is one nobody reviews, and every later command inherits it.
- **Leave it all uncommitted** in the working tree, `okf.json` and `index.md` included, for the user to look at.

**Report**, concise: ecosystem detected, fresh init vs. existing repo, what's now in `CLAUDE.md`, the baseline build/test result (pass/fail, with output on failure), and whether an OKF bundle was opened — where it is and how many concepts were written, or the note saying why the step was skipped.

Stop there. Do not move into planning or make any code changes — this command's job ends at a verified, documented baseline. Planning depends on the actual task, which isn't known yet. The concept files step 4 writes are that documentation, not a change to the code: nothing under version control that the project builds from is touched by this command.

Explicit non-goals, all of them things it would be easy to slide into from here:
- **No `--force` and no repair of an existing bundle.** `okf check`, `okf index` and `okf verify` belong to `/okf-refresh` and `/okf-verify`.
- **No `verified` entries.** Onboarding has confirmed nothing with a human; stamping it as reviewed would forge exactly the signal that record exists to carry.
- **No commit** beyond step 1's `baseline: as received`, and none at all on a repo that already had history.
- **No Tier B setup**: no `index` block in `okf.json`, no embeddings.
