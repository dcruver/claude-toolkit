# SPEC.md — OKF Code Knowledge (Design Reference)

Design reference for the `okf` component of claude-toolkit. Every `PLAN.md` item that says
"(see SPEC.md's Design Reference)" means: read the relevant section here instead of
re-deriving the decision. These sections are the shared contract between checklist items
that never see each other's context.

Source of intent: `/home/dcruver/.claude/plans/squishy-rolling-balloon.md`.

---

## 1. What this is

CodeBrain-style automated code documentation plus RAG/HyDE retrieval, rebuilt on **OKF**
(Open Knowledge Format, Google Cloud, v0.2, June 2026) instead of a bespoke JSON index.

Two tiers:

- **Tier A** — deterministic, offline, no services. Scope, drift, fan-in, `index.md`.
- **Tier B** — opt-in semantic retrieval. Chunk, embed, Qdrant, HyDE.

**There is no compiled artifact.** `bin/okf` is a bash script installed exactly like
`bin/ralph`. This is a deliberate reversal of an earlier Rust design — see §13.

### Division of labour

The split matters more than any other decision here. Get it wrong and work is duplicated.

| Owner | Does |
|---|---|
| `bin/okf` (shell) | Cheap, deterministic, repo-wide facts: file scoping, sha256, ripgrep fan-in counts, drift comparison, `index.md` regeneration, Qdrant/embedding HTTP |
| Claude (slash commands) | Reads source, extracts declared types and members, decides tier from SPEC rules, authors frontmatter and prose |

Claude must read a file anyway to document it, so type extraction happens on that same
pass. The shell never parses source code. It never invokes an LLM either.

## 2. Repo layout

```
claude-toolkit/
  bin/ralph                 existing
  bin/okf                   new — bash, committed, installed like ralph
  commands/okf-*.md         slash commands
  tests/toolkit.sh          shell harness; the verify command for every item
  tests/fixtures/           small fixture repos for okf's own tests
  install.sh, permissions.json, README.md
```

`.gitignore` gains `.okf/`.

## 3. Runtime prerequisites

`bin/okf` requires `bash`, `git`, `sha256sum`, `awk`, `sed`, `sort`, `rg` (ripgrep),
`jq`, and — for Tier B only — `curl`. All are present on this machine.

`sort` was added 2026-08-27. Its earlier absence was not a portability decision —
it is coreutils, present wherever `bash` and `git` are — but it did cost real
behaviour: `okf list` omits untracked files entirely because merging them into
sorted order needed `sort`. That omission is now a bug to fix, not a constraint
to design around.

`okf` runs a preflight on every invocation and exits 1 with a single line naming exactly
which tools are missing and what is degraded. `jq` and `rg` are **hard** requirements for
`bin/okf` (unlike `install.sh`'s optional-`jq` handling, which concerns only permission
merging). When `okf` is absent or unusable altogether, the slash commands still work by
reading and writing concepts directly — that is the documented fallback, not a second
implementation.

## 4. OKF frontmatter taxonomy

### `type` vocabulary

Code concepts (co-located with source): `Class`, `Interface`, `Enum`, `Record`, `Struct`,
`Trait`, `Function`, `Module`, `Package`.

Higher-order concepts (under `docs/`): `Service`, `API Endpoint`, `Data Model`,
`Architecture Decision`, `Playbook`, `Concept`, `Test Suite`, `Dependency`.

Reserved OKF filenames: repo-root `index.md` is the bundle root, `type: Codebase`, and the
**only** file where `okf_version` is legal. Per-directory `index.md` is `type: Package`.
`log.md` is left to OKF's own semantics and is never generated.

### The `code:` extension namespace

All extension fields nest under one `code:` key so future OKF fields cannot collide.

```yaml
---
type: Class
title: RouteRegistry
description: Resolves and caches IntegrationRoute definitions by matrix room id.
resource: /src/main/java/com/kairos/route/RouteRegistry.java
tags: [routing, cache]
status: stable
generated:
  by: claude-code/opus-5
  at: 2026-08-26T14:02:11Z
verified:
  - by: human:dcruver
    at: 2026-08-26T16:40:00Z
stale_after: 2026-11-24T00:00:00Z
sources:
  - resource: https://example.invalid/DON-86
    id: don-86
    title: Move kairos-agent into integration/
code:
  language: java
  symbol: com.kairos.route.RouteRegistry
  kind: class
  visibility: public
  lines: [28, 214]
  signature: "public final class RouteRegistry implements RouteSource"
  extends: []
  implements: ["/src/main/java/com/kairos/route/RouteSource"]
  members:
    - {name: register, signature: "public void register(Route)", lines: [66, 88]}
    - {name: resolve, signature: "public Optional<Route> resolve(String)", lines: [90, 121]}
  fan_in: 14
  tier: 2
  content_hash: "sha256:9f2a…"
  commit: "0b94c63"
---
```

`resource` is the concept's own source file. `sources` is for **external** references only
(tickets, RFCs, upstream docs) — never a restatement of `resource`. Path-valued fields use
bundle-absolute form (leading `/`), which OKF recommends because it survives file moves.

### Formatting contract (load-bearing)

The shell reads frontmatter with `awk`, so layout is a contract, not a preference. Every
writer — `okf` and every slash command — must emit frontmatter that obeys:

- Opens with `---` on line 1; closes with the next line that is exactly `---`.
- Top-level keys unindented, `key: value`, no tabs anywhere.
- The `code:` block appears as a bare `code:` line, its scalars indented exactly two
  spaces, its list items exactly four.
- No multi-line or folded scalars in any field the shell reads.

Fields the shell reads: `type`, `resource`, `status`, `stale_after`, `generated.at`,
`generated.by`, `verified[].at`, and `code.` `content_hash`, `tier`, `symbol`, `language`.
Extraction rule for `code.X`: the first line matching `^  X: ` after the `^code:$` line and
before the next unindented key.

### Actor strings (OKF §7)

`claude-code/<model>`, `ralph/<model>`, `human:<id>`, `process:<id>`. `bin/okf` writes
`process:okf/<version>` when it stamps anything itself.

### Body sections

These headings are the chunk boundaries, so they are structural, not cosmetic. `# Schema`
and `# Examples` are OKF-standard; the rest belong to this taxonomy.

| Heading | Tier | Chunk it feeds |
|---|---|---|
| `# Responsibilities` | 1+ | `summary` |
| `# Collaborators` | 1+ | `summary` |
| `# Methods`, one `## <signature>` per member | 1+ | one `method` chunk each |
| `# Schema` | records/DTOs | `schema` |
| `# Invariants`, `# Failure Modes`, `# Examples` | 2 | `summary` |

## 5. Bundle mechanics

- **Co-location.** A concept lives beside its source: `UserException.java` →
  `UserException.md` in the same directory. One concept per declared top-level type.
- **Concept ID** is the bundle-relative path minus `.md`, so concept ID, file path, and
  link target are the same fact.
- **Multiple top-level types in one file**: the first or same-named type takes
  `<stem>.md`; each additional type takes `<stem>.<TypeName>.md`.
- **Inner/nested types** are documented inside the enclosing type's file, not their own,
  unless they are `public static` (or the language equivalent) *and* referenced from
  outside the enclosing file.
- **Exclusions**, narrow and mechanical: anything gitignored, build/output directories,
  vendored trees, files matching `exclude` globs, and files carrying a `@Generated`-style
  annotation.

### Generation tiers

Every first-party declared type gets a file, so the graph is total and links never dangle.
Only effort varies. Claude assigns the tier using these rules and the thresholds in
`okf.json`; `okf fanin` and `okf hash` supply the inputs.

- **Tier 0 (stub)** — frontmatter, signature, links only. No prose. `status: draft`.
  Applies when a type is a pure exception or marker (extends an error type, adds no
  members), or has at most `tier0_max_members` members and at most `tier0_max_loc` lines,
  or is a pure data holder with no logic and no doc comment.
- **Tier 2 (deep)** — Tier 1 plus `# Invariants`, `# Failure Modes`, `# Examples`. Applies
  when `fan_in >= tier2_min_fan_in`, or `loc >= tier2_min_loc`, or the type is exported
  with `fan_in >= 4`.
- **Tier 1 (standard)** — everything else. The default.

Tier 0 is a *demotion*, never an exclusion: the file still exists and still resolves as a
link target. Re-running `/okf-generate` on a concept with an explicit higher `code.tier`
raises it.

### On fan-in

`okf fanin <Name>` is a whole-word ripgrep count across in-scope files, minus the
declaration site. It is a **ranking signal for where documentation effort goes**, never a
correctness claim. An earlier design computed this with tree-sitter, but tree-sitter has no
type resolution, so that too resolved by name — the same signal with a compiler in front of
it. Do not add a parser to "fix" this.

## 6. `okf.json` (repo root)

JSON, not TOML, because `jq` is already a hard dependency and bash has no TOML parser.

```json
{
  "okf_version": "0.2",
  "bundle": {
    "root": ".",
    "include": ["src/**", "lib/**"],
    "exclude": ["**/target/**", "**/build/**", "**/node_modules/**", "**/dist/**"],
    "extensions": ["java", "ts", "tsx", "py", "rs", "go", "js", "mjs"]
  },
  "tiers": {
    "tier0_max_members": 2,
    "tier0_max_loc": 15,
    "tier2_min_fan_in": 8,
    "tier2_min_loc": 200
  },
  "index": {
    "repo": "claude-toolkit",
    "qdrant_url": "http://localhost:6333",
    "collection": "okf_concepts",
    "embedding_url": "http://localhost:11434/v1/embeddings",
    "embedding_model": "nomic-embed-text",
    "embedding_dim": 768
  }
}
```

Absent `index`, Tier B subcommands exit 2 with one line naming the missing keys. Every
field defaults if absent.

## 7. CLI surface

```
okf init [--force]                 write okf.json + bundle-root index.md
okf list [--missing] [--orphans]   in-scope source files (gitignore + include/exclude aware)
okf hash <file>                    sha256:… of one file
okf fanin <Name>                   whole-word reference count across in-scope files
okf check [--strict] [--stamp] [--json]
okf index                          regenerate per-directory index.md
okf verify <concept> [--by ACTOR]  append a verified entry
okf chunk <concept>                Tier B: emit JSON chunks for one concept
okf embed [--all]                  Tier B: embed + upsert to Qdrant
okf search <query> [--hyde-prompt] [--k N] [--repo R] [--type T]
```

Exit codes: `0` success · `1` error or missing prerequisite · `2` Tier B invoked without
`index` config · `3` `check --strict` found drift. Every subcommand accepts `-C DIR` to run
against another repo root and `--config PATH` (default `./okf.json`).

## 8. Staleness and trust

- Drift = stored `code.content_hash` differs from the current sha256 of `resource`.
  Computed on demand; plain `okf check` never mutates a file.
- `okf check --stamp` writes the standard `stale_after` at the detection instant, so plain
  OKF consumers see the signal without understanding `code:`.
- `verified` entries are **never** stripped. They are historical facts.
- Trust tier, per OKF then narrowed: no `verified` → **Unverified**; verified only by
  non-`human:` actors → **Machine-confirmed**; a `human:<id>` entry → **Human-reviewed**,
  but only if that entry's `at >= generated.at` and the concept is not drifted. Otherwise
  it degrades to Machine-confirmed.
- Plain `okf check` always exits 0 — CI warns, never gates. `--strict` exits 3.

## 9. Tier B

**Chunking** (`okf chunk`) splits a concept body on the §4 headings into `summary`,
`method` (one per `## ` under `# Methods`), and `schema`, emitting a JSON array. A Tier 0
concept with no body yields exactly one `summary` chunk built from `title`, `description`,
and `code.signature`.

**Qdrant** over its **REST** API with `curl` + `jq`. One collection, cosine distance,
dimension `embedding_dim`. Point ID is a UUIDv5-shaped digest of
`{repo}|{concept_id}|{chunk_kind}|{symbol}` so upserts are idempotent and deletes targeted.
Payload:

```
repo, concept_id, chunk_kind, symbol, path, lines, language, type,
tags, status, trust_tier, content_hash, commit
```

Every point carries `repo`, so cross-repo search is a filter change, not a schema change.

**Embeddings** go to an OpenAI-shaped `/v1/embeddings` endpoint — Ollama
`nomic-embed-text`, 768-dim, is the documented default.

**HyDE.** `okf` never calls an LLM. `okf search --hyde-prompt` prints a prompt and exits;
the slash command answers it and passes the hypothetical body back as the query text. The
corpus is docs, so hypothetical and target are the same kind of object.

**MCP is deferred, deliberately.** Bash is a poor host for a stdio JSON-RPC server, and the
requirement was never confirmed. The OKF bundle is the product; any reader — including an
MCP server in any language — can be added later against the same files without touching the
format. Do not add one as part of this plan.

## 10. Testing conventions

The verify command for **every** item is `./tests/toolkit.sh`.

`tests/toolkit.sh` is a dependency-free bash harness (no bats) providing `assert_eq`,
`assert_contains`, `assert_exit`, and a `with_fixture_repo` helper that copies a fixture
into a temp dir, `git init`s it, and runs a callback there. It must:

- pass on a clean checkout at every point in the checklist;
- validate repo invariants — every `commands/*.md` has YAML frontmatter with a non-empty
  `description`; `bash -n` passes on `install.sh`, `bin/ralph`, and on `bin/okf` **only if
  it exists** (it is created later in the checklist, so guard the check on file presence);
- run behavioural tests for each `okf` subcommand against `tests/fixtures/`;
- print a per-check pass/fail summary and exit non-zero if anything fails;
- **never touch the network.** Tier B tests point `qdrant_url` and `embedding_url` at a
  local stub served by a temp file or a trap-based fake `curl` on `PATH`.

Fixtures live in `tests/fixtures/<name>/` — small, real, committed source trees plus the
concepts they should produce.

## 11. Toolkit integration

- **`commands/okf-*.md`** follow the house style of `commands/onboard.md` and
  `commands/tdd-plan.md`: YAML frontmatter with `description` (and `argument-hint` when
  arguments are taken), an explicit stopping point, explicit non-goals.
- **`/onboard`** gains an OKF step *after* the CLAUDE.md write and the verified baseline
  build: `okf init`, then generate concepts for in-scope files. Every underlying operation
  stays separately invocable; `/onboard` only automates the sequence, and skips with a
  printed note when `okf` is not installed.
- **`bin/ralph`** gains two things: concept docs for in-scope files injected into each
  attempt's prompt, and an instruction to refresh concepts for touched files in the same
  commit. Ralph-authored prose is stamped `generated.by: ralph/<model>` and **never** gets
  a `verified` entry — unattended regeneration is safe precisely because it cannot forge
  review.
- **`install.sh`** copies `bin/okf` to `$HOME/.local/bin/okf` alongside `ralph`, reports it
  in the same style, and warns (without failing) about any missing runtime prerequisite
  from §3.
- **`permissions.json`** gains the read-only `okf` subcommands: `okf list`, `okf hash`,
  `okf fanin`, `okf check`, `okf search`.

### Note on ralph's review gate

`bin/ralph`'s `full`/`light` gates referenced `/review-team`, which does not exist on this
machine. They were repointed to the built-in `/code-review` skill (`high` for `full`,
`medium` for `light`) before this plan was written. `/code-review`'s `ultra` level is
user-triggered and billed and must never be invoked from ralph.

## 12. Non-goals

- No compiled binary, no release pipeline, no cross-compilation.
- No source parsing in the shell — that is Claude's pass.
- No MCP server in this plan (§9).
- No LLM calls from `bin/okf`, ever.
- No gate on drift in CI; warn only.

## 13. Design history worth not re-litigating

An earlier revision specified a static Rust binary embedding five tree-sitter grammars.
It was dropped because: `claude-toolkit` is a text-only repo with no release pipeline, so
"fetch a platform release" was unimplementable; the binary's headline feature, fan-in
tiering, resolves references by name and is therefore equivalent to ripgrep; and Claude
already reads every file to document it, making a separate parse pass duplicated work.
Do not reintroduce a compiled component without revisiting those three points.

---

## This file is written once

Nothing edits `SPEC.md` again — not ralph, not a `claude -p` attempt, not a future
`/ralph-spec` run. `PLAN.md` holds all checklist state. Corrections here are a deliberate
manual step by a human.
