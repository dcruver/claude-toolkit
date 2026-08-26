# tiny

A minimal source tree used by `tests/toolkit.sh` to exercise `with_fixture_repo`.
It is copied into a temp directory and `git init`ed there, so tests may edit or
delete anything in the copy without touching this committed original.
