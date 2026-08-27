# concepts

A fixture for bin/okf's frontmatter reader: a handful of OKF concept files, and
the sources they document, covering what SPEC.md §4 says the shell may read out
of a concept and where the shell must stop reading.

| File | What it is here for |
|---|---|
| `src/route/RouteRegistry.md` | Every field §4 lists as shell-read, all present |
| `src/route/RouteSource.md` | A concept declaring almost none of them |
| `src/route/Boundaries.md` | Lines that look like those fields and are not |
| `src/route/Legacy.md` | The same block written with CRLF and a UTF-8 BOM |
| `src/route/README.md` | Prose beside sources: markdown with no frontmatter |
| `src/route/Interrupted.md` | A block that opens and is never closed |

The sources are small but real, so a concept here documents something that
exists rather than a name invented for the test.
