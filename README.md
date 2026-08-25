# claude-toolkit

Personal Claude Code toolset — the `ralph` fresh-context implementation loop, plus the
slash commands built around it. Bundled so it's a one-command setup on any machine
(new laptop, an interview machine, a fresh sandbox), not a pile of dotfiles to remember.

## What's in here

- **`commands/onboard.md`** — `/onboard`, first contact with unfamiliar code: git baseline,
  `CLAUDE.md` generated from a real scan (never guessed commands/conventions), and a
  verified build/run of the untouched baseline. Stops before any planning or editing.
- **`bin/ralph`** — fresh-context implementation loop against a `PLAN.md` checklist
  (design reference lives separately in `SPEC.md`, written once, never edited by
  ralph). Most items are a genuinely fresh `claude -p` call; git history is the only
  memory between attempts. A `[mvn]` item type lets `/ralph-spec` hand off deterministic
  Maven-plugin work (OpenRewrite recipes, Spotless, Checkstyle, dependency bumps) that
  ralph runs directly — zero LLM turns, ralph itself checks it off and commits on
  success, and leaves the tree dirty for inspection on failure. See `ralph --help` once
  installed.
- **`commands/ralph-spec.md`** — `/ralph-spec`, generates `SPEC.md` (design reference)
  and `PLAN.md` (checklist, both item types) that `ralph --plan PLAN.md` consumes, from
  a feature description or an existing plan doc.
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
  get`/`kustomize`) that `install.sh` merges into `~/.claude/settings.json`'s
  `permissions.allow` so these don't stop and ask on every new machine. Not a slash
  command — see **Permissions** below.

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

## Prerequisites

- `git` (every command except `/adversarial-pair` relies on it — `ralph` for its
  inter-attempt memory, `onboard` for its baseline commit, the tdd-* commands for
  detecting existing conventions)
- The `claude` CLI (Claude Code) installed and on `PATH`
- `bash`
- `jq`, optional — only used to merge `permissions.json` into `~/.claude/settings.json`;
  `install.sh` skips that step and warns (printing the entries to add by hand) if `jq`
  isn't found. Everything else installs regardless.

## Install

```sh
git clone <this-repo-url> ~/claude-toolkit   # or wherever
cd ~/claude-toolkit
./install.sh
```

Copies `bin/ralph` to `~/.local/bin/ralph`, each `commands/*.md` to
`~/.claude/commands/`, and merges `permissions.json` into `~/.claude/settings.json`
(see **Permissions** below). Safe to re-run.

## Permissions

`install.sh` unions `permissions.json`'s `permissions.allow` entries into
`~/.claude/settings.json`, deduped, via `jq`. It only ever adds to that array — it never
removes an entry, and it never touches any other key in `settings.json` (`model`,
`theme`, MCP tool permissions, `autoMode` context, etc.), so machine-specific settings
already there are left alone. Safe to re-run; re-running never produces duplicates.
If `~/.claude/settings.json` doesn't exist yet, it's created.

## Update

```sh
cd ~/claude-toolkit
git pull
./install.sh
```

## Uninstall

```sh
rm ~/.local/bin/ralph
rm ~/.claude/commands/onboard.md ~/.claude/commands/ralph-spec.md \
   ~/.claude/commands/tdd-audit.md ~/.claude/commands/tdd-plan.md \
   ~/.claude/commands/tdd-generate.md ~/.claude/commands/adversarial-pair.md \
   ~/.claude/commands/clarify.md ~/.claude/commands/explain.md \
   ~/.claude/commands/critique.md ~/.claude/commands/tighten.md
```
