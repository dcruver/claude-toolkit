---
description: Design and launch a producer-vs-critic(s) Workflow — one artifact against a critic panel, or many independent items each in isolation — iterating until approved or rounds run out.
argument-hint: [task description, or a path to an existing draft/plan to review]
---

Design and launch an `adversarial-pair` Workflow: a producer iterates against critic(s)
until they approve or rounds run out. Two shapes — pick the one that fits `$ARGUMENTS`:

- **Single-artifact mode** — one producer builds ONE thing (a plan, a design, an
  implementation), a panel of N critics reviews it (N identical critics voting for
  robustness, or N distinct-lens critics for coverage — e.g. correctness/security/perf).
- **Per-item mode** — the task decomposes into M independent items (line items in an
  estimate, findings in a review, files in a migration) that must NOT see each other's
  numbers/decisions. Each gets its own isolated producer+critic loop, run in parallel,
  with an optional final reconciliation pass once everything's settled. Use this
  whenever cross-item anchoring/bleed-through would bias the result more than losing
  cross-item consistency during production costs you — reconciliation afterward, seeing
  everything at once, recovers that consistency without reintroducing the bias.

**Preconditions**
- No git dependency, unlike the rest of this toolkit — `Workflow`'s fresh-context agents
  don't need shared-file safety the way `ralph`'s sequential code edits do, so this works
  outside a repo too (a pure document/estimate/plan review, nothing to commit to).
- Invoking this command is itself the harness's required multi-agent opt-in — no need to
  ask again before calling `Workflow`, *unless* the resulting scale is large (see
  "Report and launch" below).
- If `$ARGUMENTS` is a path to an existing draft/plan, read it as the thing to be
  produced/reviewed (or the source to decompose into items for per-item mode).
  Otherwise treat `$ARGUMENTS` as the task description and design from scratch.

**Determine the shape**
- Ask via `AskUserQuestion` (recommended default first) whenever it's not obvious from
  `$ARGUMENTS`: single-artifact vs per-item; if per-item, how items are enumerated and
  whether they're genuinely independent (no shared file/state — if they're not, this
  is the wrong tool, point at `ralph`/`/ralph-spec` instead); if single-artifact, panel
  size and identical-vs-distinct-lens critics.
- Don't ask about round cap unless the user cares — default to 2 (initial + 1 revision).

**Design the script** (plain JS, not TypeScript — no `Date.now()`/`Math.random()`/argless
`new Date()`; stamp timestamps via `args` or after the workflow returns)
- Write a `BACKGROUND` block: what the thing under review actually is, and — if it's
  code/repo-grounded — the real file paths to check facts against, with an explicit
  instruction that both producer and critic must verify claims against the repo/source,
  not take the brief on faith.
- Producer prompt: independent, bottom-up. When revising after a rejection, hand it the
  critic's specific *objection*, not "here's what you said before, please defend it" —
  the point is a genuinely fresh attempt at the objection, not a defense of the prior.
- Critic prompt: explicitly adversarial — must find real problems, not rubber-stamp, but
  must also watch for the opposite failure (missing scope, an underestimate, an
  unjustified cut) so it doesn't just reflexively shrink/simplify everything. Must
  re-verify any factual claim itself rather than trusting the producer's citations.
- Structured output for both roles via `schema` (not free text): producer returns its
  answer + a justification + what it actually checked; critic returns
  `{approved, concern}` — one specific, actionable concern if rejecting, not a vague
  "seems long"/"needs work".
- Per-item mode: `parallel(items.map(item => () => runItem(item)))` where `runItem` is a
  plain async function doing its own produce→critique→[revise→critique] loop — NOT
  `pipeline()`, since items must not see each other mid-flight. Follow with one final
  `agent()` call given the whole settled table, for cross-item consistency only (flag
  outliers/inconsistencies, don't re-litigate every item's number).
- Single-artifact mode: the panel runs via `parallel()` each round (N critics reviewing
  the same draft concurrently), producer revises once addressing all objections
  together, loop until the whole panel approves or rounds run out.

**Report and launch**
- State the resulting scale plainly before launching: item/panel count × round cap ×
  roles ≈ estimated agent calls. If that's roughly 20+ agent calls, say so explicitly and
  give the user a beat to object before calling `Workflow`; otherwise launch directly —
  the command invocation was already the opt-in.
- After launching, tell the user it's running in the background, point at `/workflows`
  for live progress, and that you'll report back with the settled result on completion.
