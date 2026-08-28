# claude-toolkit

Personal Claude Code toolset — the `ralph` fresh-context implementation loop, the `okf`
code-knowledge bundler, plus the slash commands built around them. Bundled so it's a
one-command setup on any machine (new laptop, an interview machine, a fresh sandbox),
not a pile of dotfiles to remember.

## What's in here

- **`commands/onboard.md`** — `/onboard`, first contact with unfamiliar code: git baseline,
  `CLAUDE.md` generated from a real scan (never guessed commands/conventions), and a
  verified build/run of the untouched baseline. Stops before any planning or editing.
  Ends with an OKF step (`okf init`, then concepts for the in-scope files) that skips with
  a printed note when `okf` isn't installed.
- **`bin/ralph`** — fresh-context implementation loop against a `PLAN.md` checklist
  (design reference lives separately in `SPEC.md`, written once, never edited by
  ralph). Most items are a genuinely fresh `claude -p` call; git history is the only
  memory between attempts. A `[mvn]` item type lets `/ralph-spec` hand off deterministic
  Maven-plugin work (OpenRewrite recipes, Spotless, Checkstyle, dependency bumps) that
  ralph runs directly — zero LLM turns, ralph itself checks it off and commits on
  success, and leaves the tree dirty for inspection on failure. Where `okf` is on `PATH` it
  also pastes the concept docs for an item's files into that attempt's prompt, and tells the
  attempt to refresh the concepts of whatever it touched in the same commit; without `okf`
  installed every such lookup is skipped silently, bundle in the tree or not.
  See `ralph --help` once installed.
- **`commands/ralph-spec.md`** — `/ralph-spec`, generates `SPEC.md` (design reference)
  and `PLAN.md` (checklist, both item types) that `ralph --plan PLAN.md` consumes, from
  a feature description or an existing plan doc.
- **`bin/okf`** — the deterministic half of the OKF code-knowledge workflow: file scoping,
  sha256 drift detection, ripgrep fan-in counts, `index.md` regeneration, and (opt-in)
  chunking/embedding/search against Qdrant. Never parses source, never calls an LLM — that
  half is Claude's, via the `/okf-*` commands. See **OKF code knowledge** below and
  `okf --help` once installed.
- **`commands/okf-init.md`** — `/okf-init`, starts an OKF bundle: runs `okf init`, then
  reports the documentation scope it opened up via `okf list --missing`. Stops before
  writing a single concept.
- **`commands/okf-generate.md`** — `/okf-generate`, authors the concept files: reads each
  in-scope source, extracts its declared types, tiers them from `okf fanin` and size, and
  writes the co-located `.md` beside each. Stamped `generated.by: claude-code/<model>`,
  never `verified`.
- **`commands/okf-refresh.md`** — `/okf-refresh`, re-authors drifted concepts: runs
  `okf check`, rewrites what the code change falsified, and restamps `code.content_hash`
  and `generated.at` without touching an existing `verified` entry.
- **`commands/okf-verify.md`** — `/okf-verify`, walks the draft and drifted concepts with
  you and stamps the ones you confirm via `okf verify --by human:<id>`. The one thing in
  the bundle no unattended run is allowed to manufacture. Writes no prose.
- **`commands/okf-search.md`** — `/okf-search`, HyDE retrieval over the bundle: runs
  `okf search --hyde-prompt`, answers that prompt itself, and searches with the
  hypothetical concept body it wrote, presenting hits grouped by concept with each one's
  trust tier. Falls back to a ripgrep sweep of the concept files when Tier B isn't
  configured.
- **`commands/tdd-audit.md`** — `/tdd-audit`, diagnoses existing test coverage and
  conventions for a target before any planning happens.
- **`commands/tdd-plan.md`** — `/tdd-plan`, builds a test-case checklist (baseline: nulls,
  empty collections, boundary values, error paths, plus code-specific cases) and stops
  for approval before any test code is written.
- **`commands/tdd-generate.md`** — `/tdd-generate`, writes and runs the tests for an
  approved `/tdd-plan` checklist. Deliberately does not automate "break the implementation
  to prove the tests catch it" — that's left as a manual, live step by design.
- **`commands/adversarial-pair.md`** — `/adversarial-pair`, designs and launches a
  producer-vs-critic(s) `Workflow`: one artifact against a critic panel, or many
  independent items each in its own isolated loop (so cross-item anchoring/bleed-through
  can't bias the result), iterating until approved or rounds run out. No git dependency —
  unlike `ralph`, it doesn't mutate a shared codebase, so it works on plain documents too.
- **`commands/clarify.md`** — `/clarify`, restates the ask, surfaces constraints and
  edge cases, and states assumptions out loud *before* any code gets written. No code in
  its own output — clarification only.
- **`commands/explain.md`** — `/explain`, narrates a completed change in plain,
  spoken-out-loud language (what it does, why this approach, anything non-obvious) in
  under 30 seconds. For explaining a diff to someone watching, not for documentation.
- **`commands/critique.md`** — `/critique`, an opinionated keep/change/why review of a
  just-made (often AI-generated) change, ending in a ship/fix/redo call. Single inline
  turn, sized for immediately after a diff — not a launched job like `/adversarial-pair`.
- **`commands/tighten.md`** — `/tighten`, proposes concrete surgical hand-edits (exact
  lines, replacement, reason) to tighten a diff that's more generic or verbose than the
  moment calls for — several small edits a human could type by hand, not a regeneration.
- **`permissions.json`** — a generic, client-agnostic read-only allowlist (`docker
  compose ps/logs/config`, `ss`, `du`, `git rev-list`, `git check-ignore`, `kubectl
  get`/`kustomize`, and the read-only `okf list`/`hash`/`fanin`/`check`/`search`) that
  `install.sh` merges into `~/.claude/settings.json`'s `permissions.allow` so these don't
  stop and ask on every new machine. Not a slash command — see **Permissions** below.

`/tdd-audit` → `/tdd-plan` → `/tdd-generate` are meant to be run in that order, in the same
conversation, on live/attended code review — unlike `ralph`, which runs unattended.
`/onboard` is the natural step before any of them when the code is unfamiliar (a fresh
clone, an interview machine, a repo with no `CLAUDE.md` yet).

`/clarify` → (make the change) → `/explain` → `/critique` → `/tighten` is a lighter,
faster loop than the `/tdd-*` pipeline — built for live/spoken narration (e.g. a
pair-programming interview) rather than formal, approval-gated test planning. Reach for
`/testcases`-style coverage via `/tdd-plan` instead when you have time for the full
`/tdd-audit` → `/tdd-plan` ceremony; use `/clarify`/`/explain`/`/critique`/`/tighten` when
you don't.

## OKF code knowledge

`bin/okf` and the five `/okf-*` commands document a codebase as an **OKF bundle** — Open
Knowledge Format (Google Cloud, v0.2, June 2026), which is just markdown with YAML
frontmatter. A concept file lives *beside* the source it describes (`RouteRegistry.java` →
`RouteRegistry.md` in the same directory), so the concept ID, the file path and the link
target are all the same fact. Every first-party declared top-level type gets a file, so the
graph is total by design and links don't dangle (`/okf-generate` names the handful of
sources it has to skip — reserved `index`/`log` stems, colliding stems); only the depth varies — tier 0 (stub: frontmatter,
signature, links), tier 1 (standard), tier 2 (adds invariants, failure modes, examples).
There's no database and no compiled artifact: the bundle *is* the markdown in your repo, so
it diffs in review, and it stays readable with the tooling uninstalled.

The split between the shell and the model is the load-bearing decision here:

| Owner | Does |
|---|---|
| `bin/okf` (bash) | cheap, deterministic, repo-wide facts — file scoping, `sha256`, ripgrep fan-in counts, drift comparison, `index.md` regeneration, Qdrant/embedding HTTP |
| Claude (`/okf-*`) | reads the source, extracts the declared types, picks the tier, authors the frontmatter and every word of prose |

`okf` never parses source code and never calls an LLM. Claude has to read a file anyway to
document it, so extraction rides along on that same pass.

Typical order: `/okf-init` → `/okf-generate` → then `/okf-refresh` as the code moves,
`/okf-verify` when a human actually reads one, and `/okf-search` to ask the bundle a
question. Every underlying step stays separately invocable. Without `okf` on `PATH`,
`/okf-generate`, `/okf-refresh` and `/okf-verify` still work by reading and writing the
concept files directly — that's the documented fallback, not a second implementation.
`/okf-init` and `/okf-search` stop instead, and `/onboard` skips its OKF step with a note:
nothing hand-writes an `okf.json` or an `index.md`, and there is no by-hand substitute for
a vector search.

### Tier A and Tier B

- **Tier A** — deterministic, offline, no services: scope, drift, fan-in, `index.md`. This
  is everything `okf init` sets up, and for most repos it's all you need.
- **Tier B** — **opt-in** semantic retrieval: chunking, embeddings, Qdrant, HyDE search.
  `okf init` deliberately writes no `index` block, so `okf chunk`, `okf embed` and `okf
  search` exit 2 with one line naming the missing keys until you add one by hand. Nothing
  in Tier A degrades without it.

**MCP is deliberately deferred.** Bash is a poor host for a stdio JSON-RPC server, and the
requirement was never confirmed. The bundle is the product — any reader, including an MCP
server in any language, can be added later against the same files without touching the
format.

### Subcommands

```
okf init [--force]                 write okf.json + the bundle-root index.md
okf list [--missing] [--orphans]   in-scope source files (gitignore + include/exclude aware)
okf hash <file>                    the sha256:… digest of one file
okf fanin <Name>                   whole-word reference count across in-scope files
okf check [--strict] [--stamp] [--json]
                                   drifted, missing and orphan concepts
okf index                          regenerate the per-directory index.md files
okf verify <concept> [--by ACTOR]  append a verified entry
okf chunk <concept>                Tier B: emit JSON chunks for one concept
okf embed [--all]                  Tier B: embed + upsert to Qdrant
okf search <query> [--hyde-prompt] [--k N] [--repo R] [--type T]
                                   Tier B: HyDE retrieval
```

Every subcommand also takes `-C DIR` (resolve paths against another repo root) and
`--config PATH` (default `./okf.json`).

Exit codes: `0` success · `1` error or missing prerequisite · `2` a Tier B subcommand
invoked without an `index` block · `3` `check --strict` found drift.

Drift is a stored `code.content_hash` that no longer matches the source's current sha256.
Plain `okf check` never mutates a file and never makes drift an error — whatever it finds,
it exits 0, so CI warns rather than gates. (An exit 1 from it is a real failure: an
unreadable `okf.json`, a failed preflight.) `--stamp`
writes a standard OKF `stale_after` so plain OKF consumers see the signal too. `verified`
entries are historical facts and are never stripped by anything.

### `okf.json`

Written at the repo root by `okf init`. JSON rather than TOML because `jq` is already a
hard dependency and bash has no TOML parser. Every field defaults if absent.

| Key | What it does |
|---|---|
| `okf_version` | the OKF version the bundle is written against (`"0.2"`) |
| `bundle.root` | must be the repo root — `"."`, `"./"` or `""`. `okf` refuses any other value and points you at `-C DIR` |
| `bundle.include` | globs that bring source into scope (default `["src/**", "lib/**"]`) |
| `bundle.exclude` | globs that take it back out again. Nothing is hard-coded on top of these, and writing the key **replaces** the default rather than adding to it — so repeat `**/target/**`, `**/build/**`, `**/node_modules/**`, `**/dist/**` if you still want them out. A vendored tree isn't in the default at all: add `**/vendor/**` yourself. (Gitignored files are separately never in scope — the listing comes from `git ls-files`.) |
| `bundle.extensions` | file extensions considered source (`java`, `ts`, `tsx`, `py`, `rs`, `go`, `js`, `mjs`) |
| `tiers.tier0_max_members` | at or under this member count a type can be demoted to a stub |
| `tiers.tier0_max_loc` | …and at or under this line count |
| `tiers.tier2_min_fan_in` | fan-in at or above this promotes a type to the deep tier |
| `tiers.tier2_min_loc` | …as does a line count at or above this |
| `index.repo` | Tier B: the repo name stamped on every point, so cross-repo search is a filter |
| `index.qdrant_url` | Tier B: Qdrant REST endpoint (e.g. `http://localhost:6333`) |
| `index.collection` | Tier B: collection name (e.g. `okf_concepts`) |
| `index.embedding_url` | Tier B: OpenAI-shaped `/v1/embeddings` endpoint |
| `index.embedding_model` | Tier B: embedding model (documented default: Ollama `nomic-embed-text`) |
| `index.embedding_dim` | Tier B: vector dimension, and the collection's (768 for the default) |

The whole `index` block is what makes Tier B opt-in: omit it and Tier A is unaffected.

## Prerequisites

- `git` (every command except `/adversarial-pair` relies on it — `ralph` for its
  inter-attempt memory, `onboard` for its baseline commit, the tdd-* commands for
  detecting existing conventions)
- The `claude` CLI (Claude Code) installed and on `PATH`
- `bash`
- For `bin/okf`, all hard requirements: `bash`, `git`, `sha256sum`, `awk`, `sed`, `sort`,
  `rg` (ripgrep) and `jq`. `okf` runs a preflight on every invocation and exits 1 with a
  single line naming exactly which of them are missing. Two more are demanded on demand
  rather than up front, each by the runs that actually need it: `curl` by the Tier B calls
  that actually speak HTTP (`embed` and `search` — but not `chunk`, which splits a concept
  body locally, nor `search --hyde-prompt`, which prints a prompt and exits without
  reaching anything), and `date` by the two that record the instant they ran (`verify` and
  `check --stamp`). `install.sh` warns about the preflight list and `curl` if it can't find
  them, but installs anyway.
- `jq`, optional *for `install.sh` itself* — it's only used there to merge
  `permissions.json` into `~/.claude/settings.json`; `install.sh` skips that step and warns
  (printing the entries to add by hand) if `jq` isn't found. Everything else installs
  regardless. (`okf`, above, does require it.)

## Install

```sh
git clone <this-repo-url> ~/claude-toolkit   # or wherever
cd ~/claude-toolkit
./install.sh
```

Copies everything in `bin/` — `ralph` and `okf` — to `~/.local/bin/`, each
`commands/*.md` to `~/.claude/commands/`, and merges `permissions.json` into
`~/.claude/settings.json` (see **Permissions** below). Safe to re-run. Verify with
`ralph --help` and `okf --help`.

## Permissions

`install.sh` unions `permissions.json`'s `permissions.allow` entries into
`~/.claude/settings.json`, deduped, via `jq`. It only ever adds to that array — it never
removes an entry, and it never touches any other key in `settings.json` (`model`,
`theme`, MCP tool permissions, `autoMode` context, etc.), so machine-specific settings
already there are left alone. Safe to re-run; re-running never produces duplicates.
If `~/.claude/settings.json` doesn't exist yet, it's created.

The `okf` subcommands `permissions.json` names are the five read-only ones: `list`, `hash`,
`fanin`, `check` and `search`. Everything else asks — the ones that write (`init`, `index`, `verify`, `embed`)
because they should, and `chunk`, which only reads, because the list was drawn up before it
existed. Two caveats. The entries are anchored at `okf <subcommand>`, so the `-C DIR` form
turns even an allowlisted read into a prompt — `cd` to the bundle root instead. And
"read-only" here means read-only *to your repo*: `okf search` writes nothing, but it does
POST your query and the HyDE body to whatever `index.embedding_url` and `index.qdrant_url`
name. Add `chunk` if the prompts get tiresome. Note that the `check` entry is a glob, so
it also auto-approves `okf check --stamp`, the one `check` that writes (a `stale_after` onto
drifted concepts) — narrow it to bare `okf check` if you'd rather be asked.

## Update

```sh
cd ~/claude-toolkit
git pull
./install.sh
```

## Uninstall

```sh
rm ~/.local/bin/ralph ~/.local/bin/okf
rm ~/.claude/commands/onboard.md ~/.claude/commands/ralph-spec.md \
   ~/.claude/commands/tdd-audit.md ~/.claude/commands/tdd-plan.md \
   ~/.claude/commands/tdd-generate.md ~/.claude/commands/adversarial-pair.md \
   ~/.claude/commands/clarify.md ~/.claude/commands/explain.md \
   ~/.claude/commands/critique.md ~/.claude/commands/tighten.md \
   ~/.claude/commands/okf-init.md ~/.claude/commands/okf-generate.md \
   ~/.claude/commands/okf-refresh.md ~/.claude/commands/okf-verify.md \
   ~/.claude/commands/okf-search.md
```

An OKF bundle is left behind on purpose: `okf.json`, the `index.md` files and the
co-located concepts are committed repo content, not installed state, and they stay
readable without the tooling.
