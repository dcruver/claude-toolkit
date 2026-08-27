# nested

A fixture for `okf index`: concepts scattered over a directory tree several
levels deep, so that what the subcommand has to work out — which directories
get an `index.md`, what each of them lists, and which are only there to keep
the link chain whole — is a question with more than one answer.

| Path | What it is here for |
|---|---|
| `index.md` | A bundle-root index that already exists, carrying SPEC.md §4's one legal `okf_version` and prose above the marker |
| `src/core/index.md` | A non-root index carrying an `okf_version` it may not have, and the wrong `type` |
| `src/deep/a/b/Deep.md` | A concept whose ancestor directories hold none of their own |
| `src/plain/` | Sources with no concept beside them: a directory that gets no index and is linked from nowhere |
| `src/odd/` | A concept whose name needs escaping before it can be a markdown link |
| `docs/Playbook.md` | A higher-order concept outside `bundle.include`, which is still part of the bundle |
| `lib/vendor/` | A concept inside an `exclude`d tree, which is not |
