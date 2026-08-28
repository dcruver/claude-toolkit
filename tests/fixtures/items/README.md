# items

A source tree shaped like the paths a `PLAN.md` checklist item mentions, used by
`tests/toolkit.sh` to exercise `bin/ralph`'s `item_concept_docs` helper.

Every co-location case SPEC.md §5 distinguishes is here exactly once:

| Path | What it is there for |
|---|---|
| `install.sh` / `install.md` | a source at the bundle root with its concept beside it |
| `bin/tool` / `bin/tool.md` | a source with no extension at all |
| `src/registry.ts` / `src/registry.md` | a source in a subdirectory with its concept |
| `.editorconfig` / `.editorconfig.md` | a name that is all extension, which keeps its whole name |
| `src/helper.ts` | a source with no concept beside it |
| `src/notes.py` / `src/notes.md` | prose sitting beside a source, carrying no frontmatter |
| `src/half.ts` / `src/half.md` | a concept whose frontmatter block was never closed |
| `src/index.ts` / `src/index.md` | a stem landing on one of SPEC.md §4's reserved names |
| `docs/guide.md` | markdown that would derive itself as its own concept |

There is deliberately no `PLAN.md` here: a test sources `bin/ralph` inside this
copy, and a checklist for it to pick up is the one thing that could turn a
sourcing that should do nothing into a run that spawns `claude`.
