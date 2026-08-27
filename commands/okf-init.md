---
description: Start an OKF bundle in this repo - run okf init, then report the documentation scope it opened up via okf list --missing. Stops before writing any concept.
argument-hint: [--force] (optional - overwrite an existing okf.json and index.md; omit unless you mean it)
---

Set this repository up as an OKF bundle and report what falls in scope. This command establishes the scope; it does not document anything.

**1. Check the prerequisites**
- `command -v okf` — if `okf` is not installed, stop and say so: it ships in `claude-toolkit`'s `bin/` and is installed by that repo's `install.sh`. Do not hand-write `okf.json` or `index.md` as a substitute; the point of this step is that one tool owns their format.
- `okf` reads the repo's scope from `git ls-files`, so it needs a git work tree. If `git rev-parse --show-toplevel` fails, stop and report that — running `git init` here is `/onboard`'s call, not this command's.
- The bundle root is the **current directory**, not the repo toplevel: run from a subdirectory and you get a second bundle nested inside the first, quietly. Check `git rev-parse --show-prefix`; if it is not empty, `cd` to the toplevel and run from there, unless the user explicitly asked for a bundle in this subtree. Prefer the `cd` to `okf -C <root>`: the toolkit's allowlisted `okf list` and `okf check` patterns match the plain form, and a `-C` in front of the subcommand turns every read-only call into a permission prompt. Settle the root here, once, and use that same root for **every** `okf` call below — a `list` run against a different directory reports on a different bundle, and with no `okf.json` there it answers from the built-in defaults rather than failing, so the mismatch does not announce itself. Say in the report which directory the bundle root is.

**2. Run `okf init`**, passing `$ARGUMENTS` through verbatim. It writes `okf.json` (bundle include/exclude globs, extensions, tier thresholds) and the bundle-root `index.md`.
- It exits 1 rather than clobbering an existing file, saying `<path> already exists` and naming every path it would have overwritten. **Never** re-run with `--force` on your own initiative — only if the user asked for it in `$ARGUMENTS`.
- What the message says decides what happens next, so read it rather than the exit status, and hold it to the exact wording. A line of the form `okf.json already exists` — that wording, that path — is the one refusal that means the bundle is already initialised: report it and carry on to step 3 against it. Anything else is not. `index.md already exists` on its own means some unrelated `index.md` is in the way and no `okf.json` was ever written, so step 3 would describe a bundle nobody configured; and `okf.json is not a regular file`, or a symlink or hard-link refusal naming it, is a collision, not a bundle. Report those and stop.
- The refusal is all-or-nothing — one existing file stops both writes — so an already-initialised bundle may still be missing its root `index.md`, from an `init` that was refused before it could write one. Check that the file is there before reporting it as one, and if it is not, say so: the fix is `okf init --force`, which overwrites `okf.json` too, and that is the user's call to make, not yours.
- Anything else on exit 1 is an ordinary error — an unknown flag, a missing prerequisite, a symlink in the way — since `okf` exits 1 for all of them. Report it and stop. Do not infer from a failure that nothing was written either: `init` prints a `wrote <path>` line per file as it goes, and can fail after the first. Those lines are the record of what actually landed, so report what they say.
- On the paths where it does write, it prints a note that Tier B (`chunk`, `embed`, `search`) is opt-in until an `index` block is added to `okf.json`. Pass that along; do not add the block here.

**3. Report the scope** — the point of the command, and the reason it stops here.
- `okf list` for the in-scope source files, `okf list --missing` for those with no concept file beside them yet. Right after a fresh `init` those two are the same list; in an existing bundle the gap between them is the work outstanding.
- Summarise rather than dumping: total in scope, total missing, and the breakdown by top-level directory and by extension. If the list is long, name the directories and counts, not every file.
- **If `okf list` prints nothing**, check its exit status before reading anything into it. Non-zero means the command failed — a malformed `okf.json` is the usual reason, and it prints why on stderr — which is an error to report, not an empty repo. Only a clean exit with no output means the bundle really is configured and empty. Say that plainly, then work out which cause it is before proposing anything, because the remedies have nothing to do with each other:
  - The sources are not tracked. Scope comes from `git ls-files`, so a file git has never been told about is invisible to `okf` however well it matches the globs. `git status --porcelain` shows them; the fix is `git add`, and it is the user's to make.
  - The globs do not match. The defaults are `src/**` and `lib/**` over a fixed extension list, which is simply wrong for plenty of layouts. Name the concrete edit to `okf.json` you would make — the actual source directories and extensions you can see here — and stop for confirmation. Do not edit `okf.json` yourself: a scope decision made silently is one nobody reviews, and every later command inherits it.
  - The sources are excluded. Tracked and in-glob is still not enough: gitignored paths, `exclude` globs, symlinks and files carrying a `@Generated`-style annotation are all dropped from the listing, quietly and by design. If the first two causes do not account for the silence, look at what is actually there before proposing anything — an exclusion working correctly is not a configuration to change.

**Report**, concise: bundle created vs. already present, where `okf.json` and `index.md` are, in-scope and missing counts with their breakdown, and — if scope is empty or looks wrong — which cause it is and the proposed fix. Include the Tier B note when `init` printed one; in an already-initialised bundle, say instead whether `okf.json` has an `index` block.

Stop there. Explicit non-goals for this command:
- **No concepts, no prose.** Do not read source files to document them and do not write, stub, or outline a single concept `.md`. That is `/okf-generate`, and it is a separate command precisely so the scope can be checked before the effort is spent.
- **No editing `okf.json`.** Propose changes in the report; leave the file as `okf init` wrote it.
- **No `--force` unless the user asked**, and no other repair of an existing bundle — `okf check`, `okf index` and `okf verify` belong to `/okf-refresh` and `/okf-verify`.
- **No Tier B setup**: no `index` block, no Qdrant, no embeddings.
- **No commit.** Leave `okf.json` and `index.md` in the working tree for the user to look at.
