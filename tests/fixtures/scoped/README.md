# scoped

A fixture repository for `okf list`: a small source tree that exercises every
one of SPEC.md §5's exclusion rules at once.

| Path | Why it is or is not in scope |
|---|---|
| `src/app.ts`, `src/util/helper.ts`, `lib/core.py` | in scope |
| `src/generated/Handwritten.java` | in scope — names `@Generated` in prose and carries `@NotGenerated`, but no marker |
| `src/util/Accessors.java` | in scope — its `@Generated` is on one member, not on the type |
| `lib/conventions.py` | in scope — its docstring and a comment open lines with `@generated`, as prose |
| `src/generated/Api.java` | excluded — carries a type-level `@Generated` annotation |
| `src/generated/Ports.py` | excluded — carries the `# @generated` header convention |
| `src/generated/ping.go` | excluded — carries Go's generated header, with CRLF line endings |
| `src/generated/config.js` | excluded — carries the one-line `/* @generated */` block comment |
| `src/target/Stale.java` | excluded — build output, by the `**/target/**` glob |
| `lib/vendor/pinned.py` | excluded — vendored, by the `**/vendor/**` glob |
| `lib/node_modules/left-pad/index.js` | excluded — by the `**/node_modules/**` glob |
| `src/ignored/secret.ts` | excluded — gitignored, so `git ls-files` never sees it |
| `tools/build.js` | excluded — outside the `include` globs |
| `src/notes.md`, `src/data.json`, `src/util/helper.md`, this file | excluded — not a listed extension |

`src/ignored/secret.ts` is committed with `git add -f`: this directory's own
`.gitignore` is obeyed by the toolkit's repository too, so without it the file
would never be committed here, never reach a fixture copy, and the check that it
stays out of `okf list` would pass with nothing to exclude.
