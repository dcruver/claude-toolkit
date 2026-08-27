# PLAN.md — OKF Code Knowledge

Checklist for `ralph --plan PLAN.md`. Every item is one fresh-context attempt with no memory
of any other. Shared design decisions live in `SPEC.md` (read-only — never check anything off
there). Items are ordered so none depends on a later one. Every item verifies with
`./tests/toolkit.sh`, which the Phase 0 item creates.

## Phase 0 — test harness

- [x] Add tests/toolkit.sh, an executable dependency-free bash harness providing assert_eq, assert_contains, assert_exit, and a with_fixture_repo helper that copies a directory from tests/fixtures/ into a temp dir, runs git init in it and executes a callback there, plus repo-invariant checks that every commands/*.md has YAML frontmatter with a non-empty description and that bash -n passes on install.sh and bin/ralph, printing a per-check pass/fail summary and exiting non-zero if any check fails (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh

## Phase 1 — Tier A: `bin/okf` skeleton

- [x] Add bin/okf as an executable bash script whose subcommand dispatch recognises every subcommand name in SPEC.md §7, routing each to a stub function, and exits 1 naming the offender on an unknown subcommand (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [x] Add a --help output to bin/okf listing every subcommand in SPEC.md §7 with its flags, printed for both --help and a bare invocation with no subcommand (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [x] Add a preflight to bin/okf that runs on every invocation and exits 1 with a single line naming exactly which of the SPEC.md §3 required tools are missing, treating jq and rg as hard requirements (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [x] Add the global -C DIR and --config PATH flags to bin/okf, where -C changes the repo root every subcommand resolves paths against and --config overrides the default ./okf.json (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh

## Phase 2 — Tier A: bundle initialisation

- [x] Implement okf init in bin/okf to write okf.json containing the SPEC.md §6 defaults, refusing to overwrite an existing okf.json without --force (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [x] Extend okf init in bin/okf to also write the bundle-root index.md with type Codebase carrying the only legal okf_version key, refusing to overwrite an existing bundle-root index.md without --force (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh

## Phase 3 — Tier A: scope and metrics

- [x] Implement okf list in bin/okf to print in-scope source files via git ls-files, honouring the include, exclude and extensions settings from okf.json and the SPEC.md §5 exclusion rules, with a tests/fixtures/ tree to exercise it (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [x] Add --missing to okf list in bin/okf, restricting output to in-scope sources that have no co-located concept file (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [x] Add --orphans to okf list in bin/okf, instead listing concept files whose resource no longer exists (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [x] Implement okf hash in bin/okf to print the sha256: prefixed digest of one file, asserting a known digest over a tests/fixtures/ file (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [x] Implement okf fanin in bin/okf to print a whole-word ripgrep reference count for a type name across in-scope files with the declaration site excluded per SPEC.md §5, asserting a known count and that an unreferenced name returns zero (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh

## Phase 4 — Tier A: frontmatter I/O

- [x] Add a frontmatter reader to bin/okf exposing the fields SPEC.md §4 lists as shell-read (type, resource, status, stale_after, generated.at, generated.by, verified[].at, and code.content_hash, code.tier, code.symbol, code.language), using the §4 extraction rule for code.X (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [x] Add a frontmatter writer to bin/okf that sets one field in place under the SPEC.md §4 formatting contract, with tests proving an unknown top-level key and an unknown key inside the code: block both survive a rewrite byte for byte (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh

## Phase 5 — Tier A: drift and trust

- [x] Implement okf check in bin/okf to report concepts whose stored code.content_hash differs from the current sha256 of their resource, always exiting 0 and never mutating a file, per SPEC.md §8 (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [x] Extend okf check in bin/okf to also report in-scope sources having no concept and orphan concepts whose resource is gone (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [x] Add --strict to okf check in bin/okf, exiting 3 when drift exists and leaving every other outcome exiting 0 (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [x] Add --json to okf check in bin/okf, emitting the drifted, missing and orphan sets as one JSON document (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [x] Add --stamp to okf check in bin/okf, writing stale_after at the detection instant onto drifted concepts without ever removing an existing verified entry (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [x] Implement okf index in bin/okf to regenerate a per-directory index.md of type Package listing that directory's concepts and subdirectories as bundle-absolute markdown links, never writing an okf_version key into a non-root index.md and leaving the bundle-root index.md's okf_version intact, over a nested tests/fixtures/ tree (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [x] Implement okf verify in bin/okf to append a verified entry carrying the --by actor, defaulting to human: plus the current username, and the current UTC timestamp in ISO 8601, preserving all unknown frontmatter keys (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [x] Extend okf verify in bin/okf to print the resulting SPEC.md §8 trust tier, covering its degradation to Machine-confirmed when the new entry predates generated.at or the concept is drifted (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh

## Phase 6 — install and permissions

- [x] Extend install.sh to copy bin/okf to $HOME/.local/bin/okf alongside ralph, report it in the same style, and warn without failing about any missing SPEC.md §3 runtime prerequisite (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [x] Add the read-only okf list, okf hash, okf fanin, okf check and okf search entries to permissions.json, and add .okf/ to .gitignore (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh

## Phase 7 — slash commands

- [x] Add commands/okf-init.md following the house style of commands/onboard.md with YAML frontmatter, an explicit stopping point and explicit non-goals, which runs okf init and reports scope via okf list --missing without authoring any prose (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [ ] Add commands/okf-generate.md following the house style of commands/onboard.md, which reads each in-scope source, extracts its declared types, calls okf fanin for the ranking signal, assigns a tier by the SPEC.md §5 rules, and writes co-located concept files obeying the SPEC.md §4 formatting contract stamped generated.by claude-code/<model> with no verified entry (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [ ] Add commands/okf-refresh.md following the house style of commands/onboard.md, which runs okf check, re-authors the bodies of drifted concepts, and updates their code.content_hash and generated.at without removing any verified entry (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [ ] Add commands/okf-verify.md following the house style of commands/onboard.md, which walks draft or drifted concepts with the user and stamps each confirmed one via okf verify --by human:<id> (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh

## Phase 8 — integration with /onboard and ralph

- [ ] Extend commands/onboard.md with an OKF step placed after the CLAUDE.md write and after the verified baseline build, running okf init then generating concepts for in-scope files, skipping cleanly with a printed note when okf is not installed and preserving onboard's existing stopping point (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [ ] Extend bin/ralph with a shell helper that extracts path-like tokens from a checklist item's text and resolves each to its sibling co-located .md concept file, emitting nothing at all when okf is not installed or no sibling concept exists (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [ ] Extend bin/ralph so each normal non-[mvn] attempt's PROMPT includes the concept docs resolved by that helper, leaving [mvn] item handling and the review-gate strings untouched (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [ ] Extend bin/ralph so a normal non-[mvn] item's PROMPT instructs the attempt to refresh the co-located concept doc of every source file it modified and include those files in the same commit, stamping generated.by as ralph/<model> and never writing a verified entry per SPEC.md §11, skipping silently when okf is absent (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh

## Phase 9 — Tier B: chunking

- [ ] Implement okf chunk in bin/okf to split one concept into a JSON array of summary, method and schema chunks on the body headings defined in SPEC.md §4, with tests for a Tier 1 concept carrying several methods and for a record with a Schema section (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [ ] Extend okf chunk in bin/okf to emit exactly one summary chunk built from title, description and code.signature when a Tier 0 concept has no body (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [ ] Extend okf chunk in bin/okf to carry the full SPEC.md §9 payload field set on every chunk, including the computed trust tier (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [ ] Add the Tier B configuration guard to bin/okf so okf chunk, okf embed and okf search each exit 2 with a single line naming the missing keys when okf.json has no index block, per SPEC.md §6 (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh

## Phase 10 — Tier B: embedding and search

- [ ] Implement okf embed in bin/okf to request embeddings from the OpenAI-shaped /v1/embeddings endpoint configured in okf.json using curl, with tests driving a fake curl placed on PATH and asserting the request body, never touching the network per SPEC.md §10 (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [ ] Extend okf embed in bin/okf to create the Qdrant collection over its REST API with cosine distance and embedding_dim when it does not already exist, asserted against a fake curl on PATH (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [ ] Extend okf embed in bin/okf to upsert one point per chunk carrying the SPEC.md §9 payload and a deterministic UUIDv5-shaped point id, asserted against a fake curl on PATH (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [ ] Implement okf search in bin/okf to embed the query text and search Qdrant over REST with a --k limit, driven by a fake curl placed on PATH (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [ ] Add the optional --repo and --type payload filters to okf search in bin/okf, asserted against the request body sent to a fake curl on PATH (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [ ] Extend okf search in bin/okf to group hits by concept_id so a method hit returns its parent concept alongside it, showing each result's trust tier (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [ ] Add --hyde-prompt to okf search in bin/okf, printing the HyDE prompt and exiting without ever calling an LLM or an embedding endpoint, per SPEC.md §9 (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [ ] Add commands/okf-search.md following the house style of commands/onboard.md, which calls okf search --hyde-prompt, answers the printed prompt itself, passes the resulting hypothetical concept body back as the query text, and presents results grouped by concept with their trust tier shown (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
- [ ] Extend commands/okf-search.md with a fallback that performs a ripgrep sweep over co-located concept files and prints a note explaining it, used when okf.json has no index block (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh

## Phase 11 — documentation

- [ ] Update README.md to document the okf component: what OKF is, the Tier A and Tier B split with Tier B opt-in, that MCP is deliberately deferred, the five new slash commands, the okf subcommands from SPEC.md §7, the okf.json keys, the SPEC.md §3 runtime prerequisites, and okf entries in the Install and Uninstall sections alongside ralph (see SPEC.md's Design Reference). Verify: ./tests/toolkit.sh
