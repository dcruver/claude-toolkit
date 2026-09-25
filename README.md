# claude-toolkit

Personal Claude Code toolset: a code-knowledge format that lives in your repo, an
unattended implementation loop, and the slash commands built around them. Bundled so
it's a one-command setup on any machine — a new laptop, an interview machine, a fresh
sandbox — instead of a pile of dotfiles to remember.

---

## What this is

Three problems keep recurring when working with Claude Code on real repositories, and
this toolkit is one answer to each.

**A model that has never seen your codebase spends its first minutes rediscovering it,
every session.** The fix here is [OKF code knowledge](#okf-code-knowledge): a concept
file written *beside* each source file, in markdown, committed to the repo. It is read
like any other file, diffs in review, and stays useful with the tooling uninstalled.

**A long implementation run degrades as its context fills.** The fix is
[`ralph`](#implementation-ralph-and-ralph-spec): a loop that gives each checklist item a
genuinely fresh session, with git history as the only memory between attempts. Nothing
accumulates, so attempt fifty is as sharp as attempt one.

**Some work wants a human in the loop and some doesn't.** The slash commands are split
accordingly — [`/onboard`](#first-contact-onboard), the
[TDD](#test-driven-work-tdd-audit--tdd-plan--tdd-generate),
[review](#live-review-clarify--explain--critique--tighten), and
[first-principles](#first-principles-thinking-dare-decompose--dare-audit--dare-recombine--dare-experiment)
pipelines are attended and conversational; `ralph` and
[`/adversarial-pair`](#adversarial-review-adversarial-pair) run unattended.

### The design stance

Three commitments run through all of it, and they explain most of the decisions you'll
find surprising:

- **The artifact is markdown in your repository.** No database, no compiled index, no
  service you have to be running. Uninstall the toolkit and the knowledge is still
  there, still readable, still in git.
- **Deterministic work belongs in bash; judgment belongs in the model.** `bin/okf` never
  parses source and never calls an LLM. Claude never computes a hash or walks a file
  tree. Neither half guesses at the other's job.
- **Everything degrades to something legible.** Missing `okf`? The `/okf-*` commands
  that only read and write concept files keep working. No Qdrant? Search falls back to
  ripgrep. No `jq` during install? It prints the permission entries for you to paste.

---

## Getting started

### 1. Install

```sh
git clone <this-repo-url> ~/claude-toolkit   # or wherever
cd ~/claude-toolkit
./install.sh
```

This copies `bin/ralph` and `bin/okf` into `~/.local/bin/`, every `commands/*.md` into
`~/.claude/commands/`, and merges `permissions.json` into `~/.claude/settings.json`
(see [Permissions](#permissions)). Safe to re-run. Verify with `ralph --help` and
`okf --help`.

`./install.sh --dry-run` prints every change it would make and writes nothing — worth a
look before letting someone else's script edit your `settings.json`.

**The binaries are copied, not symlinked.** After `git pull`, re-run `./install.sh` or
your installed copy stays at the old version.

### 2. Document a repository

Once per repo, from its root:

```
/okf-init
```

That writes `okf.json` and a bundle-root `index.md`, then reports what
`okf list --missing` now considers in scope. It writes no concepts — it just establishes
the scope and tells you how big the job is.

Then:

```
/okf-generate
```

which reads each in-scope source, extracts its declared types, tiers them, and writes
the co-located `.md` beside each one. Run it again whenever new sources appear.

Check the scope before generating if the repo is unusual — `bundle.include` defaults to
`src/**` and `lib/**`, which is wrong for plenty of layouts:

```sh
okf list --missing | head -50
```

As the code moves, `/okf-refresh` re-authors what drifted, `/okf-verify` stamps the
concepts you've actually read, and `/okf-search` answers questions from the bundle.

If the code is unfamiliar to you as well as to the model, start with `/onboard` instead
— it establishes a git baseline, writes `CLAUDE.md` from a real scan, verifies the
untouched build, and ends by opening a bundle.

### 3. Run an implementation loop

```
/ralph-spec <feature description, or a path to an existing plan doc>
```

which writes `SPEC.md` (the design reference, written once) and `PLAN.md` (an ordered
checklist). Read both, then:

```sh
ralph --plan PLAN.md
```

Each item gets a fresh session. See `ralph --help` for `--max-attempts`, `--items`,
`--review-gate` and `--model`.

### 4. Optional: semantic search

Everything above is offline and dependency-free. Semantic retrieval over the bundle is
opt-in — see [Tier A and Tier B](#tier-a-and-tier-b).

---

## OKF code knowledge

`bin/okf` and the five `/okf-*` commands document a codebase as an **OKF bundle** — Open
Knowledge Format (Google Cloud, v0.2, June 2026), which is just markdown with YAML
frontmatter.

A concept file lives *beside* the source it describes (`RouteRegistry.java` →
`RouteRegistry.md` in the same directory), so the concept ID, the file path and the link
target are all the same fact. Every first-party declared top-level type gets a file, so
the graph is total by design and links don't dangle — `/okf-generate` names the handful
of sources it has to skip (reserved `index`/`log` stems, colliding stems). Only the
depth varies: tier 0 (stub: frontmatter, signature, links), tier 1 (standard), tier 2
(adds invariants, failure modes, examples).

There's no database and no compiled artifact. The bundle *is* the markdown in your repo.

### Who does what

The split between the shell and the model is the load-bearing decision:

| Owner | Does |
|---|---|
| `bin/okf` (bash) | cheap, deterministic, repo-wide facts — file scoping, `sha256`, ripgrep fan-in counts, drift comparison, `index.md` regeneration, Qdrant/embedding HTTP |
| Claude (`/okf-*`) | reads the source, extracts the declared types, picks the tier, authors the frontmatter and every word of prose |

`okf` never parses source code and never calls an LLM. Claude has to read a file anyway
to document it, so extraction rides along on that same pass.

One consequence worth stating plainly: **`okf` is language-agnostic.** `okf fanin` is a
whole-word reference count, tiers come from fan-in and line count, and the prose is the
model's. Nothing in the tool knows Java from YAML — which is why bringing a new file
type into scope is a config change, not a parser.

### The commands

| Command | When | Writes |
|---|---|---|
| `/okf-init` | once per repo | `okf.json`, `index.md` |
| `/okf-generate` | whenever sources are undocumented | one `.md` per source |
| `/okf-refresh` | when sources drift | rewrites concepts whose hash moved |
| `/okf-verify` | when a human actually reads one | a `verified:` entry, nothing else |
| `/okf-search` | anytime | nothing — it answers questions |

`/okf-verify` is the one thing in the bundle no unattended run is allowed to
manufacture. It writes no prose.

Without `okf` on `PATH`, `/okf-generate`, `/okf-refresh` and `/okf-verify` still work by
reading and writing the concept files directly — that's the documented fallback, not a
second implementation. `/okf-init` and `/okf-search` stop instead, and `/onboard` skips
its OKF step with a printed note: nothing hand-writes an `okf.json` or an `index.md`,
and there is no by-hand substitute for a vector search.

### Tier A and Tier B

- **Tier A** — deterministic, offline, no services: scope, drift, fan-in, `index.md`.
  This is everything `okf init` sets up, and for most repos it's all you need.
- **Tier B** — **opt-in** semantic retrieval: chunking, embeddings, Qdrant, HyDE search.
  `okf init` deliberately writes no `index` block, so `okf chunk`, `okf embed` and
  `okf search` exit 2 with one line naming the missing keys until you add one by hand.
  Nothing in Tier A degrades without it.

**MCP is deliberately deferred.** Bash is a poor host for a stdio JSON-RPC server, and
the requirement was never confirmed. The bundle is the product — any reader, including
an MCP server in any language, can be added later against the same files without
touching the format.

#### Standing up Tier B

Tier B needs two services: a vector store and an embeddings server. A
`docker-compose.yml` at the repo root brings up both, and the defaults `okf init` writes
point at it, so a bundle created afterwards needs no edits.

```sh
docker compose up -d      # qdrant on :6333, embeddings on :7997
```

Then add an `index` block to the bundle's `okf.json`:

```json
{
  "index": {}
}
```

An empty block is enough: every key falls back to the default, which is this stack. Set
a key only to depart from it.

Two things worth knowing before you embed anything:

- **A collection is bound to one embedding model.** Qdrant fixes a collection's
  dimension when it is created, so switching models later means a new collection, not a
  config edit. The default here and Ollama's `nomic-embed-text` are both 768-dim, so
  those two are interchangeable; most others are not.
- **The endpoint shape is the contract, not its path.** Anything OpenAI-shaped works.
  Infinity serves `/embeddings`, Ollama and HuggingFace TEI serve `/v1/embeddings`;
  `okf` sends whatever full URL you configure.

To use something you already run instead — Ollama, TEI, a hosted provider — skip the
compose file and set `embedding_url`, `embedding_model` and `embedding_dim` to match it.

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

Drift is a stored `code.content_hash` that no longer matches the source's current
sha256. Plain `okf check` never mutates a file and never makes drift an error — whatever
it finds, it exits 0, so CI warns rather than gates. (An exit 1 from it is a real
failure: an unreadable `okf.json`, a failed preflight.) `--stamp` writes a standard OKF
`stale_after` so plain OKF consumers see the signal too. `verified` entries are
historical facts and are never stripped by anything.

### `okf.json`

Written at the repo root by `okf init`. JSON rather than TOML because `jq` is already a
hard dependency and bash has no TOML parser. Every field defaults if absent.

| Key | What it does |
|---|---|
| `okf_version` | the OKF version the bundle is written against (`"0.2"`) |
| `bundle.root` | must be the repo root — `"."`, `"./"` or `""`. `okf` refuses any other value and points you at `-C DIR` |
| `bundle.include` | globs that bring source into scope (default `["src/**", "lib/**"]`) |
| `bundle.exclude` | globs that take it back out again. Nothing is hard-coded on top of these, and writing the key **replaces** the default rather than adding to it — so repeat `**/target/**`, `**/build/**`, `**/node_modules/**`, `**/dist/**` if you still want them out. A vendored tree isn't in the default at all: add `**/vendor/**` yourself. (Gitignored files are separately never in scope — the listing comes from `git ls-files`.) |
| `bundle.extensions` | file extensions considered source (`java`, `ts`, `tsx`, `py`, `rs`, `go`, `js`, `mjs`, `yaml`, `yml`) |
| `bundle.filenames` | whole filenames considered source, for files that have no extension at all (`Dockerfile`, `Containerfile`) |
| `tiers.tier0_max_members` | at or under this member count a type can be demoted to a stub |
| `tiers.tier0_max_loc` | …and at or under this line count |
| `tiers.tier2_min_fan_in` | fan-in at or above this promotes a type to the deep tier |
| `tiers.tier2_min_loc` | …as does a line count at or above this |
| `index.repo` | Tier B: the repo name stamped on every point, so cross-repo search is a filter |
| `index.qdrant_url` | Tier B: Qdrant REST endpoint (e.g. `http://localhost:6333`) |
| `index.collection` | Tier B: collection name (e.g. `okf_concepts`) |
| `index.embedding_url` | Tier B: OpenAI-shaped embeddings endpoint (the shape is the contract, not the path) |
| `index.embedding_model` | Tier B: embedding model (default: `nomic-ai/nomic-embed-text-v1.5`, served by `docker-compose.yml`) |
| `index.embedding_dim` | Tier B: vector dimension, and the collection's (768 for the default) |

The whole `index` block is what makes Tier B opt-in: omit it and Tier A is unaffected.

#### Scoping by extension and by name

`extensions` matches a path's final extension. `filenames` matches a whole basename, and
exists because `extensions` cannot reach a file that has none: `Dockerfile` has no dot,
so it reads as extensionless and is ruled out. A path in scope by either is in scope.

They differ on the empty list, deliberately. An empty `extensions` is *no restriction*,
because it narrows a listing that already exists. An empty `filenames` is *no files*,
because it only ever widens one.

`filenames` is a whole name and not a prefix: `Dockerfile.dev` is a different basename
and needs its own entry. The reverse spelling needs nothing — `web.Dockerfile` has the
extension `Dockerfile` and is reachable through `extensions`.

Config files carry a lot of a system's real design — a Kustomize overlay or a
`Dockerfile` often says more about how something runs than the code does — which is why
both are in scope by default.

---

## The other commands

### Implementation: `ralph` and `/ralph-spec`

**`bin/ralph`** — a fresh-context implementation loop against a `PLAN.md` checklist. The
design reference lives separately in `SPEC.md`, written once and never edited by ralph.
Most items are a genuinely fresh `claude -p` call; git history is the only memory
between attempts.

A `[mvn]` item type lets `/ralph-spec` hand off deterministic Maven-plugin work
(OpenRewrite recipes, Spotless, Checkstyle, dependency bumps) that ralph runs directly —
zero LLM turns. Ralph checks it off and commits on success, and leaves the tree dirty
for inspection on failure.

Where `okf` is on `PATH`, ralph also pastes the concept docs for an item's files into
that attempt's prompt, and tells the attempt to refresh the concepts of whatever it
touched in the same commit. Without `okf` installed every such lookup is skipped
silently, bundle in the tree or not.

**`/ralph-spec`** generates the `SPEC.md` and `PLAN.md` pair that `ralph --plan PLAN.md`
consumes, from a feature description or an existing plan doc.

### First contact: `/onboard`

First contact with unfamiliar code: git baseline, `CLAUDE.md` generated from a real scan
(never guessed commands or conventions), and a verified build/run of the untouched
baseline. Stops before any planning or editing. Ends with an OKF step (`okf init`, then
concepts for the in-scope files) that skips with a printed note when `okf` isn't
installed.

The natural first step on a fresh clone, an interview machine, or any repo with no
`CLAUDE.md` yet.

### Test-driven work: `/tdd-audit` → `/tdd-plan` → `/tdd-generate`

Meant to run in that order, in the same conversation, on live and attended work.

- **`/tdd-audit`** diagnoses existing test coverage and conventions for a target before
  any planning happens.
- **`/tdd-plan`** builds a test-case checklist — baseline nulls, empty collections,
  boundary values, error paths, plus code-specific cases — and stops for approval before
  any test code is written.
- **`/tdd-generate`** writes and runs the tests for an approved checklist. It
  deliberately does not automate "break the implementation to prove the tests catch it"
  — that's left as a manual, live step by design.

### Live review: `/clarify` → `/explain` → `/critique` → `/tighten`

A lighter, faster loop than the TDD pipeline, built for live or spoken narration (a
pair-programming interview, say) rather than formal approval-gated test planning.

- **`/clarify`** restates the ask, surfaces constraints and edge cases, and states
  assumptions out loud *before* any code gets written. No code in its own output.
- **`/explain`** narrates a completed change in plain, spoken-out-loud language — what
  it does, why this approach, anything non-obvious — in under 30 seconds. For explaining
  a diff to someone watching, not for documentation.
- **`/critique`** is an opinionated keep/change/why review of a just-made (often
  AI-generated) change, ending in a ship/fix/redo call. A single inline turn, sized for
  immediately after a diff.
- **`/tighten`** proposes concrete surgical hand-edits — exact lines, replacement,
  reason — for a diff that's more generic or verbose than the moment calls for. Several
  small edits a human could type by hand, not a regeneration.

Reach for the `/tdd-*` ceremony when you have time for it; reach for these when you
don't.

### First-principles thinking: `/dare-decompose` → `/dare-audit` → `/dare-recombine` → `/dare-experiment`

The D.A.R.E. framework, for a problem that's stuck in "how it's normally done." Four
prompts, meant to run in that order, in the same conversation, each consuming the
previous step's output:

- **`/dare-decompose`** breaks the problem into its smallest useful parts — no
  solutions, no assumptions, no evaluating the pieces. Stops to confirm with you if the
  stated problem looks like it's masking a deeper one.
- **`/dare-audit`** red-teams those parts: which are load-bearing assumptions rather
  than facts, classified fact/convention/unknown, with what breaks (or opens up) if
  each is eliminated or inverted.
- **`/dare-recombine`** rebuilds from only the blocks that survived the audit — no
  fresh ideas pulled from the standard playbook. Produces 3 structurally distinct
  solutions, each naming its biggest point of failure.
- **`/dare-experiment`** designs the cheapest real-world test for each solution, with
  explicit pass/fail lines and a fallback: which assumption to revisit if every test
  fails.

Source: [D.A.R.E. Framework prompt pack](https://sandeepswadia.com/first-principles-prompts)
by Sandeep Swadia.

### Adversarial review: `/adversarial-pair`

Designs and launches a producer-vs-critic(s) `Workflow`: one artifact against a critic
panel, or many independent items each in its own isolated loop, so cross-item anchoring
and bleed-through can't bias the result. Iterates until approved or rounds run out.

No git dependency — unlike `ralph`, it doesn't mutate a shared codebase, so it works on
plain documents too.

---

## Reference

### Prerequisites

- `git` — every command except `/adversarial-pair` relies on it: `ralph` for its
  inter-attempt memory, `/onboard` for its baseline commit, the `/tdd-*` commands for
  detecting existing conventions.
- The `claude` CLI (Claude Code) installed and on `PATH`.
- `bash`.
- For `bin/okf`, all hard requirements: `bash`, `git`, `sha256sum`, `awk`, `sed`, `sort`,
  `rg` (ripgrep) and `jq`. `okf` runs a preflight on every invocation and exits 1 with a
  single line naming exactly which of them are missing.

  Two more are demanded on demand rather than up front, each by the runs that actually
  need it: `curl` by the Tier B calls that speak HTTP (`embed` and `search` — but not
  `chunk`, which splits a concept body locally, nor `search --hyde-prompt`, which prints
  a prompt and exits without reaching anything), and `date` by the two that record the
  instant they ran (`verify` and `check --stamp`). `install.sh` warns about the preflight
  list and `curl` if it can't find them, but installs anyway.
- `jq`, optional *for `install.sh` itself* — it's only used there to merge
  `permissions.json` into `~/.claude/settings.json`; `install.sh` skips that step and
  warns (printing the entries to add by hand) if `jq` isn't found. Everything else
  installs regardless. (`okf`, above, does require it.)

### Install destinations

Every destination is overridable from the environment, so you can install under a
different prefix, into a staging directory, or somewhere disposable to try it out:

| Variable | Default | |
|---|---|---|
| `BIN_DIR` | `~/.local/bin` | where `ralph` and `okf` go |
| `CLAUDE_CONFIG_DIR` | `~/.claude` | Claude Code's own variable; honoured if you set it |
| `COMMANDS_DIR` | `$CLAUDE_CONFIG_DIR/commands` | where the slash commands go |
| `SETTINGS_FILE` | `$CLAUDE_CONFIG_DIR/settings.json` | the file `permissions.json` merges into |

```sh
BIN_DIR=/tmp/t/bin CLAUDE_CONFIG_DIR=/tmp/t/claude ./install.sh
```

### Permissions

`permissions.json` is a generic, client-agnostic read-only allowlist — `docker compose
ps/logs/config`, `ss`, `du`, `git rev-list`, `git check-ignore`, `kubectl get`/`kustomize`,
and the read-only `okf list`/`hash`/`fanin`/`check`/`search` — so these don't stop and
ask on every new machine.

`install.sh` unions its `permissions.allow` entries into `~/.claude/settings.json`,
deduped, via `jq`. It only ever adds to that array — it never removes an entry, and it
never touches any other key in `settings.json` (`model`, `theme`, MCP tool permissions,
`autoMode` context, etc.), so machine-specific settings already there are left alone.
Safe to re-run; re-running never produces duplicates. If `~/.claude/settings.json`
doesn't exist yet, it's created.

The `okf` subcommands named are the five read-only ones: `list`, `hash`, `fanin`, `check`
and `search`. Everything else asks — the ones that write (`init`, `index`, `verify`,
`embed`) because they should, and `chunk`, which only reads, because the list was drawn
up before it existed.

Three caveats:

- The entries are anchored at `okf <subcommand>`, so the `-C DIR` form turns even an
  allowlisted read into a prompt. `cd` to the bundle root instead.
- "Read-only" means read-only *to your repo*. `okf search` writes nothing, but it does
  POST your query and the HyDE body to whatever `index.embedding_url` and
  `index.qdrant_url` name.
- The `check` entry is a glob, so it also auto-approves `okf check --stamp`, the one
  `check` that writes (a `stale_after` onto drifted concepts). Narrow it to bare
  `okf check` if you'd rather be asked.

Add `chunk` if the prompts get tiresome.

### Update

```sh
cd ~/claude-toolkit
git pull
./install.sh
```

The re-run matters: `install.sh` copies the binaries rather than symlinking them, so
without it your installed `okf` and `ralph` stay at the old version.

### Uninstall

```sh
cd ~/claude-toolkit
./uninstall.sh
```

Removes whatever is in this checkout's `bin/` and `commands/` from wherever
`install.sh` put it — it mirrors the install loops rather than naming files, so adding a
script or a command leaves nothing here to keep in step. It takes the same `--dry-run`
flag and the same environment overrides as `install.sh`.

Only files whose names match this checkout are touched; `~/.local/bin` and
`~/.claude/commands` are shared with other tools and are never removed wholesale.

`settings.json` is left alone by default. The install is a *union*, so an entry in
`permissions.allow` may equally be one you added yourself, and silently removing it
would be a surprise. Pass `--purge-permissions` to remove the entries listed in
`permissions.json`.

The checkout itself is untouched — delete it to finish.

An OKF bundle is left behind on purpose: `okf.json`, the `index.md` files and the
co-located concepts are committed repo content, not installed state, and they stay
readable without the tooling.

### Repository layout

| Path | What |
|---|---|
| `bin/okf` | the deterministic half of the OKF workflow |
| `bin/ralph` | the fresh-context implementation loop |
| `commands/*.md` | the slash commands, installed into `~/.claude/commands/` |
| `permissions.json` | the read-only allowlist merged into `settings.json` |
| `docker-compose.yml` | Qdrant + embeddings, for Tier B |
| `SPEC.md` | design reference for `okf` — written once, edited only by hand |
| `PLAN.md` | the checklist `ralph` worked through to build it |
| `tests/toolkit.sh` | the test harness; `./tests/toolkit.sh [name-filter]` |
