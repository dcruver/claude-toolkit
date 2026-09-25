---
description: Generate a SPEC.md design reference and PLAN.md checklist for the `ralph` fresh-context implementation loop (~/.local/bin/ralph --plan PLAN.md) from a feature description or an existing plan doc.
argument-hint: [feature description, or a path to an existing plan/design doc to convert]
---

Generate `SPEC.md` (design reference) and `PLAN.md` (checklist) at the repo root, formatted for `ralph` (`ralph --plan PLAN.md`) to execute as a sequence of fresh-context attempts, one checklist item at a time. The two files have different owners: SPEC.md is written once here and never programmatically edited again by anything; PLAN.md is pure run state that ralph itself (or a spawned `claude -p` session, depending on the item's type) checks items off in.

**Preconditions**
- Confirm this is a git repo — ralph relies on git history as the only memory between attempts. If not, stop and suggest `/onboard` or `git init` first.
- Check for an existing `PLAN.md` at the repo root with unchecked items — that's where in-progress ralph run state lives. If found, stop and ask whether to append to it, replace it, or write to a different path — never silently clobber in-progress ralph work.
- Separately, check whether `SPEC.md` already exists. Regenerating it after PLAN.md items already say "(see SPEC.md's Design Reference)" is riskier than a fresh setup — ask before overwriting rather than silently regenerating; treating it as append-only (adding new decisions without touching what's already there) is usually the safer choice once PLAN.md references it.

**Source of design**
- If `$ARGUMENTS` is a path to an existing plan/design doc (e.g. something `/plan` already produced), read it and treat its decisions as the primary source — only ask clarifying questions for gaps it doesn't cover.
- Otherwise treat `$ARGUMENTS` as a feature description and design from scratch: read `CLAUDE.md` and skim the touched areas of the codebase first for existing conventions/utilities to reuse, same discipline as `/plan` — don't invent what's already there.
- Identify decisions that would fork many checklist items if answered differently (framework/library choice, data model shape, scope boundaries, persistence, etc.). Ask about those via `AskUserQuestion`, each with a recommended default. Don't ask about anything with an obvious or conventional answer.
- If the repo is a Java/Maven project (`pom.xml` at the repo root, or found only in a subdirectory for a multi-module layout — note that path), check whether any candidate checklist item is genuinely a deterministic, plugin-shaped action — a framework major-version migration (e.g. an OpenRewrite recipe), a formatting/lint pass, a dependency version bump — rather than bespoke business logic. For each one, confirm the specific plugin coordinates, goal, and properties via `AskUserQuestion` (recommended default) rather than guessing: verify current plugin/recipe coordinates (e.g. against Maven Central or the plugin's own docs), since a stale or wrong version would silently fail every retry. This only applies to Maven — Gradle's equivalent plugin-invocation conventions are out of scope; on a Gradle-only project, skip this and treat every item as normal.

**Write SPEC.md** — the Design Reference only:
- Every decision more than one checklist item depends on: stack/library choices, file/package layout, data model fields, API surface, config values, testing conventions. Written once, so every item can point back to it instead of re-deriving or silently diverging on it.
- If any Maven-plugin items were identified above: a subsection recording which plugin(s)/goal(s)/pinned version(s) were chosen, why, and how they were confirmed (e.g. checked against Maven Central on this date).
- Close with an explicit note: this file is written once — nothing (not ralph, not a checklist item, not a future `/ralph-spec` run) should ever programmatically edit it again; corrections are a deliberate manual step.

**Write PLAN.md** — the Checklist, ordered `- [ ] task` lines, all item types. Each item must:
- be completable **and** testable by one fresh-context session with zero memory of any prior attempt (a passing test suite is ralph's only success signal) — except `[mvn]` items below, which have no fresh-context session at all
- never depend on a later item — order data-layer before service before controller, backend before frontend, etc.
- carry **one** deliverable and only the behaviors belonging to it. Treat more than about three "and" clauses as the signal to split: prefer several items that each add one function, flag, or subcommand to a file an earlier item created over a single item that builds the whole file at once. Sequential items extending the same file are correct and expected — only *forward* dependencies are forbidden.
- be a single physical line — ralph's parser (`grep -m1 -E '^[[:space:]]*-[[:space:]]\[[[:space:]]\]'`) only reads the first line of a match, so a soft-wrapped item silently breaks
- name the specific files/classes/endpoints/routes it touches, and say "(see SPEC.md's Design Reference)" so the attempt knows to go read that section for the shared detail
- end with the concrete command that verifies it (e.g. `mvn -q test`, `npm test`)
- optionally open with a tier marker saying what the item is worth running on: `[cheap]` for mechanical work needing little judgement (mostly-mechanical edits, renames, adding a case to an existing switch), `[deep]` for genuine design work (a new abstraction, a protocol rewrite, anything the Design Reference spends a section justifying), `[standard]` or no marker for everything else. Mark the exceptions only — most items are standard, and an unmarked plan is valid. The names are agent-neutral by design: ralph's wrapper maps them to its own models, so never write a model name into PLAN.md. Never put a tier on a `[mvn]` item — those run no LLM, and ralph exits 1 on one that carries a marker
- **If (and only if)** the item is a deterministic Maven-plugin action identified above, author it as this structured type instead of a normal item — ralph assembles and runs the actual `mvn` invocation itself, with no LLM call:
  ```
  - [ ] [mvn] <description> :: goal=<groupId:artifactId:version:goal> [prop=<key>=<value>]... [pom=<path/to/pom.xml>] then=<verify command>
  ```
  `goal=` is Maven's own ad hoc plugin-coordinate string, version always pinned — never `LATEST`/`RELEASE`, so reruns are deterministic. `prop=` may repeat (each becomes a `-D<key>=<value>` flag); values must not contain spaces. `pom=` is only needed for a non-root `pom.xml` (multi-module layout). `then=` is required and must be the **last** field — everything after it to end of line is the verify command, run only if the plugin invocation itself succeeds. Still a single physical line; the literal `::` separating the description from the fields appears exactly once. Not OpenRewrite-specific — the same shape fits any Maven plugin goal (Spotless, Checkstyle, versions-maven-plugin, etc.).

**Item size sets run time.** Under ralph's default `--review-gate full`, every normal (non-`[mvn]`) item must clear its step agent's review gate at high effort before it can be checked off, and any surviving finding sends the attempt back into fix-and-re-review within that same attempt. The length of that loop scales with how much surface the item introduced at once: one item bundling five deliverables can spend hours cycling before it converges, where the same work split across five items clears five short gates instead. Size items accordingly, and if the plan is large, say so in your report and point at `--review-gate light`.

**Validate before reporting**
- `grep -cE '^[[:space:]]*-[[:space:]]\[[[:space:]]\]' PLAN.md` matches the number of items you intended to write, across both item types.
- Confirm SPEC.md contains **zero** `- [ ]` lines — nothing checklist-shaped leaked out of PLAN.md.
- Confirm both files are at the repo root, named exactly `SPEC.md` and `PLAN.md` — ralph's default `--plan` lookup, and the only convention needed; no extra header/marker.
- Re-read every PLAN.md item on its own, as if it were the only line you'd been handed (which is literally true for a ralph attempt). Reject any item that says "as above," "using the X from the previous step," or otherwise leans on another item's text instead of naming the file/class/endpoint itself — fix it in place before reporting, don't just note it. Naming a concrete artifact an earlier item created ("add `assert_exit` to tests/toolkit.sh") is **not** a back-reference and must not be rewritten into a self-restating item — the path names the thing, so a fresh attempt can simply open it.
- For every tier marker specifically: it is the first thing in the item text, one of exactly `[cheap]`, `[standard]` or `[deep]`, followed by a space; and no `[mvn]` item carries one.
- For every `[mvn]` item specifically: exactly one `::`; a non-empty `goal=` field whose version segment is not `LATEST`/`RELEASE`; a `then=` field present and last; single physical line, same as above.

**Report**: item count (split by type: normal vs `[mvn]`, and how many normal items you tiered `[cheap]` or `[deep]`), a one-line summary of what's in the Design Reference, and the exact command to run it (`ralph --plan PLAN.md`, pointing to `ralph --help` for `--max-attempts`/`--items`/`--review-gate`/`--model`).

Stop there — do not invoke `ralph` itself. This command's job ends at validated `SPEC.md`/`PLAN.md`; running the loop is a separate, explicit step for the user.
