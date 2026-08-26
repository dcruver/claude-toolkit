#!/usr/bin/env bash
# tests/toolkit.sh — the test harness for claude-toolkit, and the verify command
# for every item in PLAN.md.
#
# Dependency-free by design: no bats, no npm, nothing to install — just bash,
# git and coreutils. It must pass on a clean checkout at every point in the
# checklist, and it must never touch the network.
#
# Adding tests later:
#   * Write a function named `test_<something>`, in the Tests section below.
#     It is discovered and run automatically, in alphabetical order, with the
#     repo root as its cwd. Put it ABOVE the Runner section at the bottom of
#     this file — the runner only ever sees functions defined before it runs,
#     so a test appended to the end of the file is silently never run.
#   * Report with assert_eq / assert_contains / assert_exit (whose command
#     output is then readable via `last_output`), or _pass / _fail
#     directly. A test passes when it records at least one check, records no
#     failed check, and returns 0 — so end it on an assertion or `return 0`,
#     and never let it silently assert nothing.
#   * Asserting that a command prints nothing? Use `assert_exit 0 <cmd>` then
#     `assert_eq "" "$(last_output)"`. Plain `assert_eq "" "$(cmd)"` also passes
#     when the command is missing or errors, which is a check that cannot fail.
#   * Need a scratch repo? `with_fixture_repo <name> <callback> [args...]`
#     copies tests/fixtures/<name> into a temp dir, git-inits and commits it,
#     and runs the callback in there.
#
# Usage: ./tests/toolkit.sh [name-filter]

# No `set -e`: a failed *check* must be recorded and reported, not abort the run.
# `set -u` stays on deliberately — an unbound variable is a bug in a test, not a
# result, and aborting loudly on one is better than reporting a made-up tally.
set -uo pipefail

TOOLKIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES_DIR="$TOOLKIT_ROOT/tests/fixtures"
CURRENT_TEST="<none>"

# ---------------------------------------------------------------------------
# Harness state
#
# Counters live in files, not variables, because checks also run inside the
# subshell that with_fixture_repo uses to isolate a callback's cwd.
# ---------------------------------------------------------------------------

HARNESS_STATE="$(mktemp -d "${TMPDIR:-/tmp}/toolkit-state.XXXXXX")" || {
  echo "toolkit.sh: could not create a temp state directory" >&2
  exit 1
}

_state_init() {
  printf '0\n' > "$HARNESS_STATE/passed"
  printf '0\n' > "$HARNESS_STATE/failed"
  : > "$HARNESS_STATE/failures"
  : > "$HARNESS_STATE/fixture_dirs"
  : > "$HARNESS_STATE/last_output"
  : > "$HARNESS_STATE/last_fixture_dir"
  printf '0\n' > "$HARNESS_STATE/skipped"
}
_state_init

_cleanup() {
  local status=$? dir failed_now
  failed_now="$(_state_read failed)"
  # Read before the state directory is removed below.
  local completed=no
  [ -f "$HARNESS_STATE/completed" ] && completed=yes
  if [ -f "$HARNESS_STATE/fixture_dirs" ]; then
    while IFS= read -r dir || [ -n "$dir" ]; do
      [ -n "$dir" ] && [ -d "$dir" ] && rm -rf "$dir"
    done < "$HARNESS_STATE/fixture_dirs"
  fi
  [ -n "${HARNESS_STATE:-}" ] && [ -d "$HARNESS_STATE" ] && rm -rf "$HARNESS_STATE"

  # The exit status is the only thing a PLAN.md item's verify step looks at, so
  # it has to mean something. A run that never reached its summary did not
  # finish — a test bailing out with a bare `exit 0` would otherwise abandon
  # every remaining test and still report success.
  if [ "$status" -eq 0 ] && [ "$completed" = no ]; then
    printf 'toolkit.sh: the run ended before its summary (did a test call exit?)\n' >&2
    exit 1
  fi
  case "$failed_now" in
    '' | 0) ;;
    *) [ "$status" -eq 0 ] && exit 1 ;;
  esac
}
trap _cleanup EXIT

# The one sanctioned way out of this script: marks the run as having reached a
# real conclusion, which is what stops _cleanup from overriding the status.
_finish() { # $1 = exit status
  : > "$HARNESS_STATE/completed"
  exit "$1"
}

# Infrastructure has failed and no test result can be trusted. $$ stays the
# top-level shell even inside ( ), so this ends the whole run rather than the
# subshell a fixture callback happens to be running in — where a bare `exit`
# would look like nothing worse than one failing test.
_abort() { # $1 = message
  printf 'toolkit.sh: %s\n' "$1" >&2
  kill -TERM $$ 2> /dev/null
  exit 1
}
trap 'exit 143' TERM

_state_read() { cat "$HARNESS_STATE/$1" 2>/dev/null || echo 0; }

_state_bump() {
  local n
  n="$(_state_read "$1")"
  # An unwritable state directory would silently discard recorded failures and
  # let the run report a clean tally it never earned.
  # stderr is redirected before the target, so a failure to open the target is
  # reported once, by _abort, rather than twice.
  printf '%s\n' "$((n + 1))" 2> /dev/null > "$HARNESS_STATE/$1" \
    || _abort "cannot write harness state to $HARNESS_STATE/$1"
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

_pass() { # $1 = what was checked
  _state_bump passed
  printf '    ok    %s\n' "$1"
  return 0
}

_fail() { # $1 = what was checked, $2.. = detail lines
  local what="$1"
  shift
  _state_bump failed
  printf '    FAIL  %s\n' "$what"
  local line
  for line in "$@"; do printf '          %s\n' "$line"; done
  printf '%s: %s\n' "$CURRENT_TEST" "$what" >> "$HARNESS_STATE/failures"
  return 1
}

# A skip is a recorded outcome, not the absence of one: a test whose checks are
# all guarded away (bin/okf before it exists) must not trip the runner's
# "recorded nothing" guard.
_skip() { # $1 = what was skipped, $2 = why
  _state_bump skipped
  printf '    skip  %s (%s)\n' "$1" "$2"
  return 0
}

# Render up to 20 lines of a captured blob as indented detail lines.
_detail_lines() {
  local blob="$1" line
  while IFS= read -r line || [ -n "$line" ]; do
    printf '| %s\n' "$line"
  done < <(printf '%s\n' "$blob" | head -n 20)
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

assert_eq() { # <expected> <actual> [description]
  local expected="$1" actual="$2" what="${3:-values match}"
  if [ "$expected" = "$actual" ]; then
    _pass "$what"
  else
    _fail "$what" "expected: $expected" "actual:   $actual"
  fi
}

assert_contains() { # <haystack> <needle> [description]
  local haystack="$1" needle="$2" what="${3:-output contains \"$2\"}"
  if [ -z "$needle" ]; then
    # Every string contains the empty string, so this could never fail.
    _fail "$what" "assert_contains was given an empty needle"
    return 1
  fi
  case "$haystack" in
    *"$needle"*) _pass "$what" ;;
    *)
      local -a detail=("looked for: $needle" "in:")
      local line
      while IFS= read -r line; do detail+=("$line"); done < <(_detail_lines "$haystack")
      _fail "$what" "${detail[@]}"
      ;;
  esac
}

# The combined stdout+stderr of the most recent assert_exit, for a follow-up
# assert_contains. File-backed rather than a global, so it still reads correctly
# after an assert_exit that ran inside a with_fixture_repo callback's subshell,
# and so it can be cleared between tests instead of going stale.
last_output() { cat "$HARNESS_STATE/last_output" 2>/dev/null; }

# Runs a command, compares its exit status, and records its combined output.
assert_exit() { # <expected-status> <command> [args...]
  local expected="$1"
  shift
  # Cleared first: on any path out of here, last_output must describe this call
  # and not the one before it.
  : > "$HARNESS_STATE/last_output"
  if [ $# -eq 0 ]; then
    # "$@" would expand to nothing and quietly report success.
    _fail "assert_exit $expected" "assert_exit was given no command to run"
    return 1
  fi
  local cmd="$*" out rc
  out="$("$@" 2>&1)"
  rc=$?
  printf '%s\n' "$out" > "$HARNESS_STATE/last_output"
  if [ "$rc" -eq "$expected" ]; then
    _pass "\`$cmd\` exits $expected"
  else
    local -a detail=("expected exit: $expected" "actual exit:   $rc" "output:")
    local line
    while IFS= read -r line; do detail+=("$line"); done < <(_detail_lines "$out")
    _fail "\`$cmd\` exits $expected" "${detail[@]}"
  fi
}

# ---------------------------------------------------------------------------
# Fixture repos
# ---------------------------------------------------------------------------

# with_fixture_repo <fixture-name> <callback> [args...]
#
# Copies tests/fixtures/<fixture-name> into a fresh temp directory, turns it
# into a git repo with one commit (so `git ls-files` and gitignore semantics
# work), and runs the callback there. The copy is deleted afterwards, so a
# callback may mutate it freely; the committed fixture is never touched.
# Returns the callback's exit status.
with_fixture_repo() {
  local fixture="${1:-}"
  shift || true
  local src="$FIXTURES_DIR/$fixture"

  # Cleared up front so a caller inspecting it after a bailed-out call cannot
  # read the path left behind by an earlier one.
  : > "$HARNESS_STATE/last_fixture_dir"

  if [ -z "$fixture" ] || [ ! -d "$src" ]; then
    _fail "fixture tests/fixtures/$fixture exists" "no such directory: $src"
    return 1
  fi
  if [ $# -eq 0 ]; then
    _fail "with_fixture_repo $fixture" "no callback given"
    return 1
  fi

  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/toolkit-fixture.XXXXXX")" || {
    _fail "with_fixture_repo $fixture" "mktemp -d failed"
    return 1
  }
  printf '%s\n' "$tmp" >> "$HARNESS_STATE/fixture_dirs"
  printf '%s\n' "$tmp" > "$HARNESS_STATE/last_fixture_dir"
  rm -f "$HARNESS_STATE/fixture_setup_error"

  if ! cp -R "$src/." "$tmp/"; then
    _fail "with_fixture_repo $fixture" "could not copy $src into $tmp"
    rm -rf "$tmp"
    return 1
  fi

  local rc
  (
    cd "$tmp" || exit 1
    # Hermetic git: no global/system config, no ambient identity, no hooks or
    # templates, and no repo pointed at by whoever happens to be running the
    # suite. core.excludesFile is set explicitly because git falls back to
    # ~/.config/git/ignore on its own, config file or not — a personal ignore
    # rule matching a fixture path would otherwise silently empty the index.
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
    export GIT_AUTHOR_NAME="toolkit tests" GIT_AUTHOR_EMAIL="tests@example.invalid"
    export GIT_COMMITTER_NAME="toolkit tests" GIT_COMMITTER_EMAIL="tests@example.invalid"
    export FIXTURE_NAME="$fixture" FIXTURE_DIR="$tmp"
    export GIT_ATTR_NOSYSTEM=1
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_CEILING_DIRECTORIES \
      GIT_NAMESPACE
    # init.defaultBranch as -c rather than `init -b`, which needs git >= 2.28;
    # older git ignores the unknown key instead of failing the whole fixture.
    if ! git -c init.defaultBranch=main init -q --template= . > /dev/null 2>&1 \
      || ! git config core.excludesFile /dev/null > /dev/null 2>&1 \
      || ! git add -A > /dev/null 2>&1 \
      || ! git commit -q --allow-empty -m "fixture: $fixture" > /dev/null 2>&1; then
      printf 'git setup failed\n' > "$HARNESS_STATE/fixture_setup_error"
      exit 1
    fi
    "$@"
  )
  rc=$?

  if [ -f "$HARNESS_STATE/fixture_setup_error" ]; then
    _fail "with_fixture_repo $fixture" "could not git init the fixture copy"
    rm -f "$HARNESS_STATE/fixture_setup_error"
  fi

  [ -n "$tmp" ] && [ -d "$tmp" ] && rm -rf "$tmp"
  return $rc
}

# Runs an assertion against a throwaway state directory: its pass/fail counters
# and output are discarded and only its exit status survives. This is what lets
# the harness test its own negative paths without polluting the real tally.
_isolated_assert() {
  local state rc
  if ! state="$(mktemp -d "${TMPDIR:-/tmp}/toolkit-selftest.XXXXXX")"; then
    # Every call site reads the return status as the isolated assertion's own
    # verdict, so there is no status left to mean "it never ran". An unusable
    # temp directory is an infrastructure failure, not a test result: abort.
    _abort "mktemp -d failed, cannot run isolated self-tests"
  fi
  (
    HARNESS_STATE="$state"
    _state_init
    "$@" > /dev/null 2>&1
  )
  rc=$?
  rm -rf "$state"
  return $rc
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# Every PLAN.md item's verify command is this script, so an assertion that can
# never fail would silently green-light the whole checklist. Prove otherwise.
test_harness_assertions() {
  local rc

  assert_eq "" "$(last_output)" "last_output starts empty in every test"
  assert_eq "abc" "abc" "assert_eq accepts equal values"
  assert_contains "hello world" "lo wo" "assert_contains finds a substring"
  assert_exit 0 true
  assert_exit 3 bash -c 'exit 3'

  assert_exit 0 bash -c 'echo captured; echo also captured >&2'
  assert_contains "$(last_output)" "captured" "assert_exit records output for last_output"
  assert_contains "$(last_output)" "also captured" "assert_exit captures stderr too"

  _isolated_assert assert_eq "abc" "xyz"
  rc=$?
  assert_eq 1 "$rc" "assert_eq rejects different values"

  _isolated_assert assert_contains "hello world" "goodbye"
  rc=$?
  assert_eq 1 "$rc" "assert_contains rejects a missing substring"

  _isolated_assert assert_exit 0 bash -c 'exit 2'
  rc=$?
  assert_eq 1 "$rc" "assert_exit rejects the wrong exit status"

  # Two ways to write a check that could never fail; both must be refused.
  _isolated_assert assert_contains "anything at all" ""
  rc=$?
  assert_eq 1 "$rc" "assert_contains refuses an empty needle"

  _isolated_assert assert_exit 0
  rc=$?
  assert_eq 1 "$rc" "assert_exit refuses a missing command"
}

# SPEC.md §11: commands/*.md carry YAML frontmatter with a description, which is
# what Claude Code lists the command by.
test_commands_have_frontmatter_description() {
  local f found=0
  for f in "$TOOLKIT_ROOT"/commands/*.md; do
    [ -e "$f" ] || continue
    found=$((found + 1))
    local rel="commands/$(basename "$f")"
    local first="" line="" desc="" closed=0 n=0

    IFS= read -r first < "$f"
    first="${first%$'\r'}"
    if [ "$first" != "---" ]; then
      _fail "$rel opens with YAML frontmatter" "line 1 is: $first"
      continue
    fi

    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n + 1))
      [ "$n" -eq 1 ] && continue
      line="${line%$'\r'}"
      if [ "$line" = "---" ]; then
        closed=1
        break
      fi
      case "$line" in
        description:*) desc="${line#description:}" ;;
      esac
    done < "$f"

    if [ "$closed" -ne 1 ]; then
      _fail "$rel closes its frontmatter block" "no closing '---' found"
      continue
    fi

    # trim surrounding whitespace, then one layer of matching quotes
    desc="${desc#"${desc%%[![:space:]]*}"}"
    desc="${desc%"${desc##*[![:space:]]}"}"
    case "$desc" in
      \"*\") desc="${desc:1:${#desc} - 2}" ;;
      \'*\') desc="${desc:1:${#desc} - 2}" ;;
    esac
    desc="${desc#"${desc%%[![:space:]]*}"}"
    desc="${desc%"${desc##*[![:space:]]}"}"

    if [[ "$desc" =~ ^[\|\>][0-9]*[+-]?$ ]] || [[ "$desc" =~ ^[\|\>][+-][0-9]*$ ]]; then
      # `description: >` / `description: |` put the text on following lines,
      # where nothing that reads the key's own line will ever see it.
      _fail "$rel has a non-empty frontmatter description" \
        "the value is the YAML block scalar '$desc', not a description —" \
        "put the description on the description: line itself"
    elif [ -n "$desc" ]; then
      _pass "$rel has a non-empty frontmatter description"
    else
      _fail "$rel has a non-empty frontmatter description" \
        "description is missing or empty in the frontmatter block"
    fi
  done

  if [ "$found" -gt 0 ]; then
    _pass "commands/ contains $found command file(s)"
  else
    _fail "commands/ contains at least one command file" "no commands/*.md found"
  fi
}

# Shipped shell scripts must parse and be executable — install.sh copies bin/*
# straight onto $PATH. Everything in bin/ is discovered rather than listed, so a
# script added later cannot go unchecked; bin/okf arrives partway through
# PLAN.md, so its absence is a skip rather than a failure.
test_shell_scripts_parse() {
  local rel path
  local -a scripts=(install.sh tests/toolkit.sh)
  for path in "$TOOLKIT_ROOT"/bin/*; do
    [ -f "$path" ] && scripts+=("bin/$(basename "$path")")
  done
  [ -e "$TOOLKIT_ROOT/bin/okf" ] || _skip "bash -n bin/okf" "not created yet"

  for rel in "${scripts[@]}"; do
    if [ ! -e "$TOOLKIT_ROOT/$rel" ]; then
      _fail "$rel exists" "missing from the repo"
      continue
    fi
    assert_exit 0 bash -n "$rel"
    if [ -x "$TOOLKIT_ROOT/$rel" ]; then
      _pass "$rel is executable"
    else
      _fail "$rel is executable" "chmod +x $rel"
    fi
  done
}

_probe_fixture_repo() {
  # This callback deletes and overwrites files in its cwd, so it verifies where
  # it is standing before doing so — a copy of it run outside with_fixture_repo
  # would otherwise chew through whatever directory it landed in.
  local here want
  here="$(pwd -P)"
  want="$(cd "${FIXTURE_DIR:-/nonexistent}" 2> /dev/null && pwd -P)"
  if [ -z "$want" ] || [ "$here" != "$want" ]; then
    _fail "the fixture probe is running inside a fixture copy" \
      "cwd is $here, FIXTURE_DIR is ${FIXTURE_DIR:-unset}"
    return 1
  fi
  _pass "the callback runs inside the fixture copy, not the repo"

  if [ -f src/greeter.py ]; then
    _pass "fixture files are copied into the temp repo"
  else
    _fail "fixture files are copied into the temp repo" "no src/greeter.py under $PWD"
  fi

  assert_eq "true" "$(git rev-parse --is-inside-work-tree 2>/dev/null)" \
    "the copy is a git work tree"
  assert_contains "$(git ls-files)" "src/greeter.py" \
    "the copy has an initial commit, so git ls-files sees the sources"
  assert_exit 0 git status --porcelain
  assert_eq "" "$(last_output)" "the copy starts clean"
  assert_exit 0 git log --format=%s -1

  # Mutate the copy: the committed fixture must not follow it back.
  printf 'clobbered\n' > src/greeter.py
  rm -f README.md
}

test_with_fixture_repo() {
  local rc dir

  with_fixture_repo tiny _probe_fixture_repo
  rc=$?
  assert_eq 0 "$rc" "with_fixture_repo returns the callback's exit status"
  assert_contains "$(last_output)" "fixture: tiny" \
    "an assert_exit inside the callback is still readable via last_output"

  dir="$(cat "$HARNESS_STATE/last_fixture_dir" 2>/dev/null)"
  if [ -n "$dir" ] && [ ! -e "$dir" ]; then
    _pass "the temp copy is removed after the callback"
  else
    _fail "the temp copy is removed after the callback" "still present: $dir"
  fi

  assert_contains "$(cat "$FIXTURES_DIR/tiny/src/greeter.py" 2>&1)" "class Greeter" \
    "a callback's edits do not reach tests/fixtures/"
  if [ -f "$FIXTURES_DIR/tiny/README.md" ]; then
    _pass "a callback's deletions do not reach tests/fixtures/"
  else
    _fail "a callback's deletions do not reach tests/fixtures/" \
      "tests/fixtures/tiny/README.md was removed"
  fi

  with_fixture_repo tiny bash -c 'exit 7'
  rc=$?
  assert_eq 7 "$rc" "with_fixture_repo propagates a failing callback's status"

  _isolated_assert with_fixture_repo no-such-fixture true
  rc=$?
  assert_eq 1 "$rc" "with_fixture_repo reports a missing fixture instead of running the callback"
}

# SPEC.md §7 is the CLI surface, so the subcommand names are read back out of it
# rather than restated here: a name in the spec with no handler in bin/okf then
# fails as a missing subcommand instead of quietly never being exercised.
_okf_spec_subcommands() {
  awk '
    /^## 7\./ { in_section = 1; next }
    in_section && /^## / { exit }
    in_section && /^okf[ \t]/ { print $2 }
  ' "$TOOLKIT_ROOT/SPEC.md" | sort -u
}

# Runs each subcommand inside a throwaway fixture repo, because the ones already
# implemented do real work: `init` writes okf.json, `index` writes index.md. In
# the toolkit checkout that would edit the repo under test.
#
# The only thing asserted is that dispatch did not reject the name — whatever a
# subcommand goes on to say about its arguments or a missing okf.json is that
# subcommand's own contract, checked by its own PLAN.md item.
_okf_probe_dispatch() { # $1.. = subcommand names
  local okf="$TOOLKIT_ROOT/bin/okf" sub out

  # `embed` and `search` are Tier B and reach for HTTP once implemented, and
  # this fixture has no okf.json to point them somewhere harmless. SPEC.md §10
  # forbids the suite touching the network at all, so shadow curl with a stub
  # that records the attempt and fails — the guard stays even if some later
  # config-resolution change stops those two exiting early.
  local fakebin marker
  fakebin="$(mktemp -d "${TMPDIR:-/tmp}/toolkit-fakebin.XXXXXX")" || {
    _fail "okf dispatch probe" "mktemp -d failed"
    return 1
  }
  # Registered the way with_fixture_repo registers its copies, so an interrupted
  # run takes it with everything else rather than leaving it in TMPDIR.
  printf '%s\n' "$fakebin" >> "$HARNESS_STATE/fixture_dirs"
  marker="$fakebin/curl-was-called"
  cat > "$fakebin/curl" <<FAKE_CURL
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$marker"
exit 1
FAKE_CURL
  chmod +x "$fakebin/curl"
  local saved_path="$PATH"
  PATH="$fakebin:$PATH"

  # Absence of a rejection only means anything if a rejection was reachable at
  # all. Something added ahead of dispatch that exits early — the preflight, a
  # global flag parser — would otherwise silently turn every check below into a
  # check that cannot fail, so prove the name a rejection here first.
  out="$("$okf" definitely-not-a-subcommand 2>&1)" || true
  case "$out" in
    *"unknown subcommand"*) _pass "an okf invocation in the fixture reaches dispatch" ;;
    *)
      _fail "an okf invocation in the fixture reaches dispatch" \
        "an unknown subcommand was not rejected by name, so the checks that" \
        "follow cannot tell a recognised subcommand from an early exit:" "$out"
      # Bail rather than report ten passes that were just shown to mean nothing.
      PATH="$saved_path"
      rm -rf "$fakebin"
      return 1
      ;;
  esac

  for sub in "$@"; do
    out="$("$okf" "$sub" 2>&1)" || true
    case "$out" in
      *"unknown subcommand"*)
        _fail "okf $sub is a recognised subcommand" "dispatch rejected it:" "$out"
        ;;
      *) _pass "okf $sub is a recognised subcommand" ;;
    esac
  done

  if [ -s "$marker" ]; then
    _fail "no okf invocation in the probe tries to reach the network" \
      "curl was called, with:" "$(cat "$marker")"
  else
    _pass "no okf invocation in the probe tries to reach the network"
  fi

  PATH="$saved_path"
  rm -rf "$fakebin"
  return 0
}

test_okf_dispatches_every_spec_subcommand() {
  local okf="$TOOLKIT_ROOT/bin/okf"
  if [ ! -x "$okf" ]; then
    _fail "bin/okf is an executable script" "missing or not executable: $okf"
    return 1
  fi

  local -a subs=()
  local name
  while IFS= read -r name; do
    [ -n "$name" ] && subs+=("$name")
  done < <(_okf_spec_subcommands)

  # Guards the extraction above: were it to stop matching, every per-subcommand
  # check below would vanish and this test would pass by asserting nothing.
  # Empty is handled separately and bails, because expanding "${subs[@]}" on an
  # empty array under `set -u` aborts the whole run on bash 3.2 — one reported
  # failure is worth more than a suite that dies before its summary.
  if [ "${#subs[@]}" -eq 0 ]; then
    _fail "SPEC.md §7 lists its subcommands" \
      "extracted no subcommand names from SPEC.md's CLI surface section"
    return 1
  fi
  assert_eq 10 "${#subs[@]}" "SPEC.md §7 lists 10 subcommands"

  local sub
  for sub in "${subs[@]}"; do
    if grep -qE "^cmd_$sub\(\)" "$okf"; then
      _pass "bin/okf routes $sub to cmd_$sub"
    else
      _fail "bin/okf routes $sub to cmd_$sub" "no cmd_$sub function in bin/okf"
    fi
  done

  with_fixture_repo tiny _okf_probe_dispatch "${subs[@]}"
}

test_okf_rejects_an_unknown_subcommand() {
  local okf="$TOOLKIT_ROOT/bin/okf"
  # bin/okf is committed, so its absence is a broken checkout rather than a
  # point in the checklist it has not been reached yet — a failure, not a skip.
  # Named here so it reads as one missing file instead of four "exits 127".
  if [ ! -x "$okf" ]; then
    _fail "bin/okf is an executable script" "missing or not executable: $okf"
    return 1
  fi

  assert_exit 1 "$okf" frobnicate
  assert_contains "$(last_output)" "unknown subcommand: frobnicate" \
    "the error names the offending subcommand"

  # A prefix of a real subcommand is still not that subcommand.
  assert_exit 1 "$okf" ini
  assert_contains "$(last_output)" "unknown subcommand: ini" \
    "dispatch matches subcommand names whole, not by prefix"

  # A bare invocation has no offender to name, so all this item pins is that it
  # points at what it will accept. What it prints and with what status is the
  # --help item's to decide, so the status is deliberately not asserted —
  # pinning it here would fail that item for printing help and exiting 0.
  local bare
  bare="$("$okf" 2>&1)" || true
  assert_contains "$bare" "init" "a bare invocation names the subcommands"
  assert_contains "$bare" "search" "a bare invocation names the subcommands"
}

# --- add new test_* functions above this line ------------------------------

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

usage() {
  cat <<'USAGE'
Usage: ./tests/toolkit.sh [name-filter]

Runs every test_* function in this file, or only those whose name contains
name-filter. Exits non-zero if any check fails.
USAGE
}

case "${1:-}" in
  -h | --help)
    usage
    _finish 0
    ;;
esac

# Matched against the function name, so "shell scripts" finds
# test_shell_scripts_parse just as "shell_scripts" does.
FILTER="${1:-}"
FILTER="${FILTER// /_}"
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_RUN=0

run_test() {
  local fn="$1" name before after before_ok after_ok before_skip rc
  name="${fn#test_}"
  name="${name//_/ }"
  CURRENT_TEST="$name"
  TESTS_RUN=$((TESTS_RUN + 1))
  printf '  %s\n' "$name"

  before="$(_state_read failed)"
  before_ok="$(_state_read passed)"
  before_skip="$(_state_read skipped)"
  : > "$HARNESS_STATE/last_output"
  : > "$HARNESS_STATE/last_fixture_dir"
  cd "$TOOLKIT_ROOT" || exit 1
  "$fn"
  rc=$?
  cd "$TOOLKIT_ROOT" || exit 1
  after="$(_state_read failed)"
  after_ok="$(_state_read passed)"

  # A test that recorded nothing is broken, not passing — otherwise a body that
  # never runs (an empty loop, an early return) green-lights the whole suite.
  if [ "$after" -eq "$before" ]; then
    if [ "$after_ok" -eq "$before_ok" ] && [ "$(_state_read skipped)" -eq "$before_skip" ]; then
      _fail "$name records at least one check" \
        "the test function ran but made no assertion and skipped nothing"
    elif [ "$rc" -ne 0 ]; then
      # Every assertion returns 0 when it holds, so a test that passed all of
      # its checks and still returns non-zero bailed out part way through.
      _fail "$name runs to completion" \
        "all recorded checks passed but the test returned status $rc" \
        "end a test on an assertion, or on an explicit \`return 0\`"
    fi
    after="$(_state_read failed)"
  fi

  if [ "$after" -gt "$before" ]; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
  else
    TESTS_PASSED=$((TESTS_PASSED + 1))
  fi
}

printf 'claude-toolkit test harness\n'
printf 'repo: %s\n\n' "$TOOLKIT_ROOT"

# Discovery is `declare -F` at this point in the file, so a test_* function
# written below this section would simply not exist yet and would be skipped in
# silence — on a suite that is the verify command for every PLAN.md item. Compare
# what is defined against what the file declares, and fail on the difference.
# Spelled in two halves on purpose: assembled at runtime, the only literal copy
# of the boundary comment anywhere in this file is the boundary comment itself.
# A literal here would match its own source line and keep the guard "working"
# even after the real comment was deleted.
BOUNDARY_COMMENT="add new test_""* functions above this line"
DEFINED=" $(declare -F | awk '{print $NF}' | tr '\n' ' ')"
CURRENT_TEST="test discovery"
UNREACHABLE=0

# A second function with an existing test's name replaces it outright: the first
# one stops existing and its checks stop running, with nothing else to notice.
while IFS= read -r dupe; do
  [ -n "$dupe" ] || continue
  UNREACHABLE=1
  _fail "$dupe is declared once" \
    "declared more than once — the later definition replaces the earlier one," \
    "so that test's checks silently stop running"
done < <(awk '
    /^(function[ \t]+)?test_[A-Za-z0-9_]+[ \t]*(\(\)|\{)/ {
      name = $0
      sub(/^function[ \t]+/, "", name)
      sub(/[ \t]*(\(\)|\{).*$/, "", name)
      print name
    }
  ' "${BASH_SOURCE[0]}" | sort | uniq -d)
while IFS= read -r declared; do
  [ -n "$declared" ] || continue
  if [ "$declared" = "!no-marker!" ]; then
    UNREACHABLE=1
    _fail "the Tests/Runner boundary comment is intact" \
      "the boundary comment just above the Runner section has been removed," \
      "so unreachable tests can no longer be detected — restore it"
    continue
  fi
  case "$DEFINED" in
    *" $declared "*) ;;
    *)
      UNREACHABLE=1
      _fail "$declared is reachable by the runner" \
        "declared below the runner, so it is never defined in time to run" \
        "move it into the Tests section, above the Runner section"
      ;;
  esac
# Only the region below the boundary comment is scanned: a test file legitimately
# contains heredocs and quoted strings that look like function declarations, and
# the only declarations that can be unreachable are the ones after the runner.
# Two passes, anchored on the comment's LAST occurrence, so a test quoting it
# cannot shrink the scanned region.
done < <(awk -v marker="$BOUNDARY_COMMENT" '
    NR == FNR { if (index($0, marker)) last = FNR; next }
    FNR == 1 && !last { print "!no-marker!"; exit }
    FNR <= last { next }
    /^(function[ \t]+)?test_[A-Za-z0-9_]+[ \t]*(\(\)|\{)/ {
      name = $0
      sub(/^function[ \t]+/, "", name)
      sub(/[ \t]*(\(\)|\{).*$/, "", name)
      print name
    }
  ' "${BASH_SOURCE[0]}" "${BASH_SOURCE[0]}" | sort -u)
[ "$UNREACHABLE" -eq 0 ] || printf '\n'

for fn in $(declare -F | awk '{print $NF}' | sort); do
  case "$fn" in
    test_*) ;;
    *) continue ;;
  esac
  if [ -n "$FILTER" ]; then
    case "$fn" in
      *"$FILTER"*) ;;
      *) continue ;;
    esac
  fi
  run_test "$fn"
done

CHECKS_PASSED="$(_state_read passed)"
CHECKS_FAILED="$(_state_read failed)"

printf '\n'
printf -- '----------------------------------------------------------\n'
if [ "$TESTS_RUN" -eq 0 ]; then
  printf 'no tests ran'
  [ -n "$FILTER" ] && printf ' (filter: %s)' "$FILTER"
  printf '\n'
  _finish 1
fi

if [ "$CHECKS_FAILED" -gt 0 ]; then
  printf 'failed checks:\n'
  while IFS= read -r entry || [ -n "$entry" ]; do
    [ -n "$entry" ] && printf '  - %s\n' "$entry"
  done < "$HARNESS_STATE/failures"
  printf '\n'
fi

CHECKS_SKIPPED="$(_state_read skipped)"

printf 'tests:  %d passed, %d failed\n' "$TESTS_PASSED" "$TESTS_FAILED"
printf 'checks: %d passed, %d failed' "$CHECKS_PASSED" "$CHECKS_FAILED"
[ "$CHECKS_SKIPPED" -gt 0 ] && printf ', %d skipped' "$CHECKS_SKIPPED"
printf '\n' 

if [ "$CHECKS_FAILED" -gt 0 ]; then
  printf 'RESULT: FAIL\n'
  _finish 1
fi
printf 'RESULT: PASS\n'
_finish 0
