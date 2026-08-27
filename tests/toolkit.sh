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

# CDPATH cleared for every cd in this file: exported, it makes a relative cd
# search it first and echo where it landed, which would resolve the repo root
# to somebody else's directory and print a path into the middle of a captured
# value.
TOOLKIT_ROOT="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

# The subcommand names bin/okf's help actually documents: the first word of
# every indented, non-flag line in its `Subcommands:` block.
_okf_help_subcommands() { # help text on stdin
  awk '
    /^Subcommands:/ { in_block = 1; next }
    # The block runs to the next unindented line — the prose or the exit-code
    # table that follows it. Deliberately not "to the next blank line": that
    # would make a cosmetic blank line inside the block load-bearing, and
    # removing one would silently shrink the set this comparison is built on.
    in_block && /^[^[:space:]]/ { exit }
    # Flag entries such as "-h, --help" are not subcommands.
    in_block && $1 ~ /^-/ { next }
    in_block && NF > 0 { print $1 }
  ' | sort -u
}

# The entries of one of bin/okf's top-level array literals, one per line and in
# the order the script writes them: what the script itself claims, as against
# what SPEC.md says. Prints nothing if there is no such array, which every
# caller has to treat as a failure rather than as an empty list.
_okf_bin_array() { # $1 = array name
  sed -n "s/^$1=(\(.*\))\$/\1/p" "$TOOLKIT_ROOT/bin/okf" | tr ' ' '\n' | sed '/^$/d'
}

# The names bin/okf's dispatch accepts, read out of its OKF_SUBCOMMANDS array.
_okf_dispatch_subcommands() {
  _okf_bin_array OKF_SUBCOMMANDS | sort -u
}

# The usage portion of a subcommand's SPEC.md §7 line — the name and its flags,
# with the aligned description (two or more spaces, then prose) cut off.
#
#   okf list [--missing] [--orphans]   in-scope source files
#     -> list [--missing] [--orphans]
_okf_spec_usage() { # $1 = subcommand name
  awk -v want="$1" '
    /^## 7\./ { in_section = 1; next }
    in_section && /^## / { exit }
    in_section && $1 == "okf" && $2 == want {
      sub(/^okf[ \t]+/, "")
      sub(/[ \t][ \t]+.*$/, "")
      print
      exit
    }
  ' "$TOOLKIT_ROOT/SPEC.md"
}

# Every <arg> and [--flag ARG] token of a SPEC.md §7 usage line, one per line.
_okf_spec_usage_tokens() { # $1 = subcommand name
  _okf_spec_usage "$1" | grep -oE '<[^>]+>|\[[^]]+\]' || true
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
  # forbids the suite touching the network at all, so shadow every tool okf
  # would speak HTTP with — bin/okf's own OKF_TIER_B_TOOLS, so a second one
  # added there is stubbed too rather than left to dial out unobserved — with a
  # stub that records the attempt and fails. The guard stays even if some later
  # config-resolution change stops those two exiting early.
  local fakebin marker
  fakebin="$(mktemp -d "${TMPDIR:-/tmp}/toolkit-fakebin.XXXXXX")" || {
    _fail "okf dispatch probe" "mktemp -d failed"
    return 1
  }
  # Registered the way with_fixture_repo registers its copies, so an interrupted
  # run takes it with everything else rather than leaving it in TMPDIR.
  printf '%s\n' "$fakebin" >> "$HARNESS_STATE/fixture_dirs"
  marker="$fakebin/tier-b-tool-was-called"
  local -a tier_b_tools=()
  local tb_tool
  while IFS= read -r tb_tool; do
    [ -n "$tb_tool" ] && tier_b_tools+=("$tb_tool")
  done < <(_okf_bin_array OKF_TIER_B_TOOLS)
  if [ "${#tier_b_tools[@]}" -eq 0 ]; then
    _fail "bin/okf lists the tools its Tier B subcommands speak HTTP with" \
      "no OKF_TIER_B_TOOLS array in bin/okf, or it is empty, so this probe" \
      "cannot stub what it has to keep off the network"
    rm -rf "$fakebin"
    return 1
  fi
  for tb_tool in "${tier_b_tools[@]}"; do
    cat > "$fakebin/$tb_tool" <<FAKE_TOOL
#!/usr/bin/env bash
printf '%s %s\n' "$tb_tool" "\$*" >> "$marker"
exit 1
FAKE_TOOL
    chmod +x "$fakebin/$tb_tool"
  done
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
      "a Tier B tool was called, with:" "$(cat "$marker")"
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

test_okf_help_lists_every_spec_subcommand() {
  local okf="$TOOLKIT_ROOT/bin/okf"
  if [ ! -x "$okf" ]; then
    _fail "bin/okf is an executable script" "missing or not executable: $okf"
    return 1
  fi

  # SPEC.md §3's preflight runs ahead of help and does not exempt it, so this
  # asserts 0 on the strength of every required tool being installed here. On a
  # machine missing one it fails by design, alongside every other okf test —
  # which is the whole point of a preflight. The preflight's own behaviour with
  # a tool missing is exercised by test_okf_preflight_names_every_missing_tool,
  # against a PATH built for the purpose.
  assert_exit 0 "$okf" --help

  # Captured again with the two streams kept apart, because assert_exit merges
  # them and so cannot tell help printed on stdout from help printed on stderr.
  # Everything below reads this stdout-only copy.
  local help help_err="$HARNESS_STATE/okf_help_stderr"
  help="$("$okf" --help 2> "$help_err")"
  assert_contains "$help" "Subcommands:" "okf --help prints its help on stdout"
  assert_eq "" "$(cat "$help_err")" "okf --help prints nothing on stderr"
  rm -f "$help_err"

  local -a subs=()
  local name
  while IFS= read -r name; do
    [ -n "$name" ] && subs+=("$name")
  done < <(_okf_spec_subcommands)
  # Same guard as the dispatch test: no names extracted would turn every check
  # below into one that cannot fail, and "${subs[@]}" on an empty array aborts
  # the run under `set -u` on bash 3.2.
  if [ "${#subs[@]}" -eq 0 ]; then
    _fail "SPEC.md §7 lists its subcommands" \
      "extracted no subcommand names from SPEC.md's CLI surface section"
    return 1
  fi

  local sub entry token
  for sub in "${subs[@]}"; do
    # The help entry for this subcommand: the line whose first word is its name.
    entry="$(printf '%s\n' "$help" | awk -v want="$sub" '$1 == want { print; exit }')"
    if [ -z "$entry" ]; then
      _fail "okf --help lists $sub" "no line in the help output begins with \"$sub\""
      continue
    fi
    _pass "okf --help lists $sub"

    # The §7 usage line itself, guarded before its tokens are read out of it.
    # An empty token list is not on its own a sign of trouble — `okf index`
    # takes neither a flag nor an argument — but a §7 whose fence or
    # indentation has moved past _okf_spec_usage yields an empty line for every
    # subcommand, and then every per-flag check below silently stops existing
    # while the suite still reports all-pass.
    if [ -z "$(_okf_spec_usage "$sub")" ]; then
      _fail "SPEC.md §7 gives a usage line for $sub" \
        "extracted none from the CLI surface section"
      continue
    fi

    # Its flags and arguments, read back out of SPEC.md rather than restated
    # here, so a flag added to the spec and not to the help fails as a missing
    # flag instead of quietly never being checked.
    while IFS= read -r token; do
      [ -n "$token" ] || continue
      assert_contains "$entry" "$token" "okf --help shows $sub $token"
    done < <(_okf_spec_usage_tokens "$sub")
  done

  # A bare invocation is the same help, so a user who typed `okf` and a user who
  # typed `okf --help` are told the same things. It exits non-zero because
  # nothing was asked for and nothing was done.
  local bare
  bare="$("$okf" 2>&1)"
  local bare_rc=$?
  assert_eq "$help" "$bare" "a bare invocation prints the same help as --help"
  if [ "$bare_rc" -ne 0 ]; then
    _pass "a bare invocation exits non-zero"
  else
    _fail "a bare invocation exits non-zero" "exit status was 0"
  fi
  # ...and on stderr, so a pipeline capturing okf's stdout gets nothing rather
  # than a page of help text where its data should be. The stderr side is
  # asserted first on purpose: on its own, "stdout was empty" is a check that
  # would also pass if okf had died without printing anything at all.
  local bare_out bare_err="$HARNESS_STATE/okf_bare_stderr"
  bare_out="$("$okf" 2> "$bare_err" || true)"
  assert_contains "$(cat "$bare_err")" "Subcommands:" \
    "a bare invocation prints its help on stderr"
  assert_eq "" "$bare_out" "a bare invocation prints nothing on stdout"
  rm -f "$bare_err"

  # Both directions, so the help cannot document a subcommand that SPEC.md §7
  # does not define and dispatch would reject, and dispatch cannot accept one
  # the help never mentions. The per-subcommand checks above only cover
  # spec -> help; on their own an invented entry would ship unnoticed.
  local spec_names help_names table_names
  spec_names="$(_okf_spec_subcommands)"
  help_names="$(printf '%s\n' "$help" | _okf_help_subcommands)"
  table_names="$(_okf_dispatch_subcommands)"
  assert_eq "$spec_names" "$help_names" \
    "okf --help documents exactly the SPEC.md §7 subcommands, and no others"
  assert_eq "$spec_names" "$table_names" \
    "okf dispatch accepts exactly the SPEC.md §7 subcommands, and no others"

  # -h is the same help on stdout, exiting 0: asking for help is not an error.
  assert_exit 0 "$okf" -h
  assert_eq "$help" "$(last_output)" "okf -h prints the same help as --help"
}

# The tools SPEC.md §3 says bin/okf needs, one per line as "<tier> <name>":
# tier A for the ones every invocation needs, tier B for the ones §3 qualifies
# with "for Tier B only". Read back out of the prose rather than restated here,
# so a tool added to the spec and not to bin/okf fails as a missing tool
# instead of quietly never being checked.
_okf_spec_tools() {
  awk '
    /^## 3\./ { in_section = 1; next }
    in_section && /^## / { exit }
    in_section { text = text " " $0 }
    END {
      # The requirements sentence, from "requires" to the first full stop.
      # Nothing between the two is a period, so [^.]* cannot overshoot the end
      # of the sentence and swallow the paragraphs after it.
      if (!match(text, /requires[^.]*\./)) exit
      n = split(substr(text, RSTART, RLENGTH), part, "`")
      # Splitting on backticks puts the quoted tool names at the even indices
      # and the prose between them at the odd ones — and it is that prose which
      # says whether the name it introduces is Tier B only. The qualifier is
      # sticky: it comes last in the sentence and governs everything after it,
      # so "for Tier B only — `curl` and `wget`" is two Tier B tools and not
      # one of each. Classifying a tool as hard is the costly direction — it
      # would have bin/okf refuse to run without something Tier A never needs.
      tier = "A"
      for (i = 2; i <= n; i += 2) {
        if (part[i - 1] ~ /Tier B only/) tier = "B"
        print tier " " part[i]
      }
    }
  ' "$TOOLKIT_ROOT/SPEC.md"
}

_okf_spec_tools_in_tier() { # $1 = A or B
  _okf_spec_tools | awk -v tier="$1" '$1 == tier { print $2 }' | sort -u
}

# The subcommands bin/okf's help calls Tier B: every SPEC.md §7 subcommand name
# that appears in the help's Tier B line. Tier B is a wider set than the
# subcommands that speak HTTP — SPEC.md §9 has `okf chunk` split a concept body
# locally — and the tests below need both to tell one from the other.
_okf_help_tier_b_subcommands() {
  local line name
  line="$("$TOOLKIT_ROOT/bin/okf" --help | grep 'are Tier B')"
  # Only the subjects of the sentence: what follows "are Tier B" is what they
  # need, and that mentions an `index` block — which would otherwise be read as
  # the `index` subcommand being Tier B, and it is not.
  line="${line%%are Tier B*}"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if printf '%s\n' "$line" | grep -Fqw -- "$name"; then
      printf '%s\n' "$name"
    fi
  done < <(_okf_spec_subcommands)
}

# bin/okf run with PATH replaced by a probe directory. Restricting PATH is the
# only honest way to make a tool missing: bin/okf finds its tools with
# `command -v`, and nothing can hide one that is still on PATH.
_okf_with_path() { # $1 = PATH to run under, $2.. = okf arguments
  local path="$1"
  shift
  PATH="$path" "$TOOLKIT_ROOT/bin/okf" ${1+"$@"}
}

# Fills a directory with symlinks to exactly the named commands, resolved on the
# real PATH, and returns non-zero if any of them is not installed here.
#
# bash comes along whatever the caller asks for, and it is the only thing that
# does: the shebang resolves bash on PATH, so a probe directory without it
# would fail the run before the script started, for a reason that has nothing
# to do with the preflight. Nothing else is smuggled in — a probe PATH holding
# more than SPEC.md §3's tools would hide bin/okf reaching for one that is not
# on that list.
_okf_probe_path() { # $1 = directory, $2.. = command names
  local dir="$1" tool path
  shift
  mkdir -p "$dir" || return 1
  for tool in bash "$@"; do
    path="$(command -v -- "$tool" 2> /dev/null)" || return 1
    [ -n "$path" ] || return 1
    ln -sf "$path" "$dir/$tool" || return 1
  done
  return 0
}

# Whether a message names a tool, as a word. Substring matching would read
# "gawk" as a mention of "awk", and telling a tool that is missing from one
# that is merely a suffix of it is the entire job of the checks below.
_okf_names_tool() { # $1 = text, $2 = tool name
  printf '%s\n' "$1" | grep -Fqw -- "$2"
}

_okf_assert_names_tool() { # $1 = text, $2 = tool name, $3 = description
  if _okf_names_tool "$1" "$2"; then
    _pass "$3"
    return 0
  fi
  local -a detail=("looked for the word: $2" "in:")
  local line
  while IFS= read -r line; do detail+=("$line"); done < <(_detail_lines "$1")
  _fail "$3" "${detail[@]}"
}

# The number of non-empty lines in a blob — "a single line" is the whole point
# of SPEC.md §3's preflight message, so it gets counted rather than eyeballed.
_okf_line_count() { # $1 = text
  printf '%s\n' "$1" | grep -c . || true
}

# SPEC.md §3 is the list of prerequisites, so bin/okf's own list is compared
# against it rather than against a copy written out here.
test_okf_preflight_requires_exactly_the_spec_tools() {
  local okf="$TOOLKIT_ROOT/bin/okf"
  if [ ! -x "$okf" ]; then
    _fail "bin/okf is an executable script" "missing or not executable: $okf"
    return 1
  fi

  local spec_hard spec_tier_b
  spec_hard="$(_okf_spec_tools_in_tier A)"
  spec_tier_b="$(_okf_spec_tools_in_tier B)"

  # Guards the extraction: were §3's sentence reworded past it, the comparisons
  # below would compare two empty lists and pass without checking anything.
  if [ -z "$spec_hard" ]; then
    _fail "SPEC.md §3 names the tools bin/okf requires" \
      "extracted no tool names from the runtime prerequisites section"
    return 1
  fi
  if [ -z "$spec_tier_b" ]; then
    _fail "SPEC.md §3 names a tool as needed for Tier B only" \
      "extracted no Tier B tool names from the runtime prerequisites section"
    return 1
  fi
  # The two SPEC.md §3 calls hard, and the two this item exists to pin.
  _okf_assert_names_tool "$spec_hard" jq "SPEC.md §3 requires jq of every invocation"
  _okf_assert_names_tool "$spec_hard" rg "SPEC.md §3 requires rg of every invocation"

  assert_eq "$spec_hard" "$(_okf_bin_array OKF_REQUIRED_TOOLS | sort -u)" \
    "bin/okf requires exactly the tools SPEC.md §3 lists, and no others"
  assert_eq "$spec_tier_b" "$(_okf_bin_array OKF_TIER_B_TOOLS | sort -u)" \
    "bin/okf holds back exactly SPEC.md §3's Tier B tools for Tier B"

  # Which subcommands reach for those tools is load-bearing for the preflight:
  # a name missing from that list is a subcommand that would sail past the
  # check and fail mid-HTTP for want of curl instead.
  local -a http_subs=()
  local name
  while IFS= read -r name; do
    [ -n "$name" ] && http_subs+=("$name")
  done < <(_okf_bin_array OKF_HTTP_SUBCOMMANDS)
  if [ "${#http_subs[@]}" -eq 0 ]; then
    _fail "bin/okf lists the subcommands that speak HTTP" \
      "no OKF_HTTP_SUBCOMMANDS array in bin/okf, or it is empty"
    return 1
  fi

  # Pinned literally, and the one thing here that is: every other check in this
  # test reads the same array the preflight does, so on this question it could
  # only ever agree with itself — the two mutations that matter, chunk added
  # and search dropped, both pass otherwise. The authority is SPEC.md §9, which
  # is prose and not a list a test can parse: Qdrant over REST is embed and
  # search, and chunk splits a concept body locally.
  assert_eq "$(printf '%s\n' embed search)" \
    "$(_okf_bin_array OKF_HTTP_SUBCOMMANDS | sort -u)" \
    "bin/okf demands its HTTP tools of exactly embed and search"

  # Cross-checked against the two places that already had to know: dispatch,
  # which must recognise the name at all, and the help, which tells the user
  # which subcommands are Tier B. Speaking HTTP is a narrower thing than being
  # Tier B — SPEC.md §9 has `okf chunk` split a concept body locally — so this
  # is containment, not equality.
  local dispatch help_tier_b
  dispatch="$(_okf_dispatch_subcommands)"
  help_tier_b="$(_okf_help_tier_b_subcommands)"
  if [ -z "$help_tier_b" ]; then
    _fail "okf --help says which subcommands are Tier B" \
      "no SPEC.md §7 subcommand name appears in the help's Tier B line"
    return 1
  fi
  for name in "${http_subs[@]}"; do
    assert_contains "$dispatch" "$name" \
      "bin/okf's HTTP subcommand $name is a subcommand at all"
    _okf_assert_names_tool "$help_tier_b" "$name" "okf --help calls $name Tier B"
  done
  return 0
}

# SPEC.md §3: a preflight on every invocation, exiting 1 with a single line
# naming exactly which required tools are missing.
test_okf_preflight_names_every_missing_tool() {
  local okf="$TOOLKIT_ROOT/bin/okf"
  if [ ! -x "$okf" ]; then
    _fail "bin/okf is an executable script" "missing or not executable: $okf"
    return 1
  fi

  local -a hard=() tier_b=()
  local name
  while IFS= read -r name; do
    [ -n "$name" ] && hard+=("$name")
  done < <(_okf_spec_tools_in_tier A)
  while IFS= read -r name; do
    [ -n "$name" ] && tier_b+=("$name")
  done < <(_okf_spec_tools_in_tier B)
  # Same guard as the test above, and for the same reason: an empty list here
  # would turn every loop below into one that runs no checks at all. Bailing
  # rather than continuing, because "${hard[@]}" on an empty array aborts the
  # whole run under `set -u` on bash 3.2.
  if [ "${#hard[@]}" -eq 0 ] || [ "${#tier_b[@]}" -eq 0 ]; then
    _fail "SPEC.md §3 names the tools bin/okf requires" \
      "extracted no tool names from the runtime prerequisites section"
    return 1
  fi

  local root
  root="$(mktemp -d "${TMPDIR:-/tmp}/toolkit-preflight.XXXXXX")" || {
    _fail "okf preflight probe" "mktemp -d failed"
    return 1
  }
  # Registered the way with_fixture_repo registers its copies, so an interrupted
  # run takes it with everything else rather than leaving it in TMPDIR.
  printf '%s\n' "$root" >> "$HARNESS_STATE/fixture_dirs"

  # The control. $root/all holds every tool §3 requires of every invocation and
  # nothing else — no curl, because that one is Tier B's. Without this, each
  # check below would pass just as happily against a probe PATH so broken that
  # okf could never have run at all.
  if ! _okf_probe_path "$root/all" "${hard[@]}"; then
    _fail "a probe PATH holding every required tool can be built" \
      "a tool SPEC.md §3 requires is not installed here, so a tool this test" \
      "removes cannot be told from one that was never there"
    return 1
  fi
  assert_exit 0 _okf_with_path "$root/all" --help
  assert_contains "$(last_output)" "Subcommands:" \
    "okf runs on a PATH holding nothing but the tools SPEC.md §3 requires"

  local tool other out dir
  for tool in "${hard[@]}"; do
    if [ "$tool" = bash ]; then
      # Not provable by removal: the shebang resolves bash on PATH, so a probe
      # PATH without it never starts the script and never reaches the
      # preflight. bin/okf takes the interpreter it is running under as proof
      # enough, which is the same argument from the other side.
      _skip "okf names bash when it is missing" "the script cannot start without bash"
      continue
    fi

    dir="$root/without-$tool"
    local -a present=()
    for other in "${hard[@]}"; do
      [ "$other" = "$tool" ] || present+=("$other")
    done
    # Guarded like every other array expansion here: an empty one under `set -u`
    # aborts the whole run on bash 3.2 rather than failing a single check.
    if [ "${#present[@]}" -eq 0 ]; then
      _fail "a probe PATH without $tool can be built" \
        "removing $tool left no tools to put on it"
      continue
    fi
    if ! _okf_probe_path "$dir" "${present[@]}"; then
      _fail "a probe PATH without $tool can be built" "could not populate $dir"
      continue
    fi

    assert_exit 1 _okf_with_path "$dir" list
    out="$(last_output)"
    assert_eq 1 "$(_okf_line_count "$out")" \
      "okf says so in a single line when $tool is missing"
    _okf_assert_names_tool "$out" "$tool" "that line names the missing tool $tool"

    # The preflight got there first, so nothing had the chance to half-do its
    # work and only then discover the tool it needed was not there. Probed with
    # a name dispatch is bound to reject: "unknown subcommand" is what bin/okf
    # says whenever dispatch is reached at all, which will still be true long
    # after the subcommands stop being stubs — as a check for a stub's own
    # "not implemented" would not.
    local probe
    probe="$(_okf_with_path "$dir" definitely-not-a-subcommand 2>&1)" || true
    case "$probe" in
      *"unknown subcommand"*)
        _fail "okf runs its preflight ahead of dispatch" \
          "with $tool missing, dispatch ran anyway:" "$probe"
        ;;
      *) _pass "okf runs its preflight ahead of dispatch" ;;
    esac

    # "exactly which tools are missing" — naming an installed one sends someone
    # off to install what they already have.
    local named_others=""
    for other in "${hard[@]}"; do
      [ "$other" = "$tool" ] && continue
      if _okf_names_tool "$out" "$other"; then
        named_others="${named_others:+$named_others }$other"
      fi
    done
    if [ -n "$named_others" ]; then
      _fail "that line names only the tool that is missing" \
        "with only $tool removed, the line also named: $named_others" "$out"
    else
      _pass "that line names only the tool that is missing"
    fi
  done

  # Two at once, on one line. SPEC.md §3 singles out jq and rg as the hard
  # requirements, and being told to install jq, installing it, and only then
  # being told about rg is the failure mode a single line replaces.
  local -a without_jq_rg=()
  for other in "${hard[@]}"; do
    case "$other" in
      jq | rg) ;;
      *) without_jq_rg+=("$other") ;;
    esac
  done
  if [ "${#without_jq_rg[@]}" -eq 0 ]; then
    _fail "a probe PATH without jq and rg can be built" \
      "removing jq and rg left no tools to put on it"
  elif _okf_probe_path "$root/without-jq-rg" "${without_jq_rg[@]}"; then
    assert_exit 1 _okf_with_path "$root/without-jq-rg" list
    out="$(last_output)"
    assert_eq 1 "$(_okf_line_count "$out")" "two missing tools are named on one line"
    _okf_assert_names_tool "$out" jq "that line names jq"
    _okf_assert_names_tool "$out" rg "that line names rg"
  else
    _fail "a probe PATH without jq and rg can be built" \
      "could not populate $root/without-jq-rg"
  fi

  # "on every invocation": --help is not exempt, and neither is a bare `okf`.
  # Someone whose okf cannot run is better served by the name of the tool to
  # install than by a page describing subcommands that would every one of them
  # fail on the way to doing anything.
  local help_out help_err="$HARNESS_STATE/okf_preflight_stderr"
  if [ "${#without_jq_rg[@]}" -eq 0 ]; then
    _fail "a probe PATH without jq can be built" \
      "removing jq and rg left no tools to put on it"
  elif _okf_probe_path "$root/help-without-jq" "${without_jq_rg[@]}" rg; then
    help_out="$(_okf_with_path "$root/help-without-jq" --help 2> "$help_err")"
    local help_rc=$?
    assert_eq 1 "$help_rc" "okf --help exits 1 when a required tool is missing"
    out="$(cat "$help_err")"
    _okf_assert_names_tool "$out" jq "okf --help names the missing tool, on stderr"
    assert_eq 1 "$(_okf_line_count "$out")" "okf --help says it in a single line"
    assert_eq "" "$help_out" "okf --help prints no help on stdout when a tool is missing"

    assert_exit 1 _okf_with_path "$root/help-without-jq"
    out="$(last_output)"
    _okf_assert_names_tool "$out" jq "a bare invocation names the missing tool too"
    case "$out" in
      *"Subcommands:"*)
        _fail "a bare invocation prints no help when a tool is missing" "$out"
        ;;
      *) _pass "a bare invocation prints no help when a tool is missing" ;;
    esac
  else
    _fail "a probe PATH without jq can be built" "could not populate $root/help-without-jq"
  fi
  rm -f "$help_err"

  # SPEC.md §3 needs curl for Tier B only, so its absence has to degrade okf to
  # Tier A rather than stop it. `okf --help` on $root/all — which has no curl —
  # already exited 0 above; what is left is that a Tier A subcommand does not
  # send its caller off to install curl either.
  # The status is deliberately not asserted: `okf list` exits 1 only while it
  # is a stub, and what is being checked here is what it says, not that it
  # failed. It must get past the preflight — which the control above, `okf
  # --help` exiting 0 on this same curl-less PATH, has already shown.
  out="$(_okf_with_path "$root/all" list 2>&1)" || true
  local tb_tool named_tier_b=""
  for tb_tool in "${tier_b[@]}"; do
    if _okf_names_tool "$out" "$tb_tool"; then
      named_tier_b="${named_tier_b:+$named_tier_b }$tb_tool"
    fi
  done
  if [ -n "$named_tier_b" ]; then
    _fail "a Tier A subcommand asks for no Tier B tool" \
      "okf list, with no curl on PATH, named: $named_tier_b" "$out"
  else
    _pass "a Tier A subcommand asks for no Tier B tool"
  fi

  # ...and that the subcommands which cannot work without it say so.
  local -a http_subs=()
  while IFS= read -r name; do
    [ -n "$name" ] && http_subs+=("$name")
  done < <(_okf_bin_array OKF_HTTP_SUBCOMMANDS)
  if [ "${#http_subs[@]}" -eq 0 ]; then
    _fail "bin/okf lists the subcommands that speak HTTP" \
      "no OKF_HTTP_SUBCOMMANDS array in bin/okf, or it is empty"
    return 1
  fi

  local sub
  for sub in "${http_subs[@]}"; do
    assert_exit 1 _okf_with_path "$root/all" "$sub"
    out="$(last_output)"
    assert_eq 1 "$(_okf_line_count "$out")" \
      "okf $sub says what it is missing in a single line"
    for tb_tool in "${tier_b[@]}"; do
      _okf_assert_names_tool "$out" "$tb_tool" "okf $sub names the missing $tb_tool"
    done
  done

  # A Tier B subcommand that speaks no HTTP is not asked for curl either:
  # SPEC.md §9 has `okf chunk` split a concept body into JSON locally, and
  # nothing about that needs a network tool. The status is not asserted —
  # SPEC.md §7 has Tier B exit 2 without an `index` block, which this
  # okf.json-less directory has not got.
  # Pinned literally, for the same reason the HTTP set is: the Tier B
  # subcommands come out of bin/okf's own help, so dropping chunk from that
  # sentence would leave this loop iterating over the HTTP subcommands alone
  # and skipping every check below in silence. SPEC.md §7 marks chunk and embed
  # Tier B and §9 puts search's Qdrant query there too.
  assert_eq "$(printf '%s\n' chunk embed search)" "$(_okf_help_tier_b_subcommands)" \
    "okf --help calls exactly chunk, embed and search Tier B"

  # The Tier B subcommands that are not HTTP ones — which is the whole point of
  # keeping the two lists apart, so there had better be one.
  local -a local_only=()
  local tier_b_sub
  while IFS= read -r tier_b_sub; do
    [ -n "$tier_b_sub" ] || continue
    case " ${http_subs[*]} " in
      *" $tier_b_sub "*) continue ;;
    esac
    local_only+=("$tier_b_sub")
  done < <(_okf_help_tier_b_subcommands)
  if [ "${#local_only[@]}" -eq 0 ]; then
    _fail "a Tier B subcommand speaks no HTTP" \
      "every subcommand okf --help calls Tier B is also in OKF_HTTP_SUBCOMMANDS," \
      "so nothing is left to show that being Tier B is not what demands curl"
    return 1
  fi

  for tier_b_sub in "${local_only[@]}"; do
    out="$(_okf_with_path "$root/all" "$tier_b_sub" 2>&1)" || true
    named_tier_b=""
    for tb_tool in "${tier_b[@]}"; do
      if _okf_names_tool "$out" "$tb_tool"; then
        named_tier_b="${named_tier_b:+$named_tier_b }$tb_tool"
      fi
    done
    if [ -n "$named_tier_b" ]; then
      _fail "okf $tier_b_sub asks for no HTTP tool it never uses" \
        "with no curl on PATH, okf $tier_b_sub named: $named_tier_b" "$out"
    else
      _pass "okf $tier_b_sub asks for no HTTP tool it never uses"
    fi
  done

  # SPEC.md §9's exception, which the same reasoning reaches from the other
  # side: `okf search --hyde-prompt` prints a prompt for the slash command to
  # answer and exits without reaching Qdrant, so curl is not its to demand
  # either. The status is not asserted — today it is a stub that exits 1, and
  # once implemented it prints its prompt and exits 0.
  out="$(_okf_with_path "$root/all" search --hyde-prompt 2>&1)" || true
  named_tier_b=""
  for tb_tool in "${tier_b[@]}"; do
    if _okf_names_tool "$out" "$tb_tool"; then
      named_tier_b="${named_tier_b:+$named_tier_b }$tb_tool"
    fi
  done
  if [ -n "$named_tier_b" ]; then
    _fail "okf search --hyde-prompt asks for no HTTP tool it never uses" \
      "with no curl on PATH, it named: $named_tier_b" "$out"
  else
    _pass "okf search --hyde-prompt asks for no HTTP tool it never uses"
  fi

  # Past a `--` the same word is the query text, and a query does have to reach
  # Qdrant — so this one is held to curl like any other search.
  assert_exit 1 _okf_with_path "$root/all" search -- --hyde-prompt
  out="$(last_output)"
  for tb_tool in "${tier_b[@]}"; do
    _okf_assert_names_tool "$out" "$tb_tool" \
      "okf search -- --hyde-prompt is a query, and still needs $tb_tool"
  done

  # And with the Tier B tools present they get past the preflight. Their curl
  # is a stub that records the call and fails: SPEC.md §10 forbids this suite
  # touching the network, and a real curl here would be one implemented Tier B
  # subcommand away from doing exactly that.
  local marker="$root/curl-was-called"
  if ! _okf_probe_path "$root/tier-b" "${hard[@]}"; then
    _fail "a probe PATH for Tier B can be built" "could not populate $root/tier-b"
    return 1
  fi
  for tb_tool in "${tier_b[@]}"; do
    # Removed first, not overwritten: _okf_probe_path may have just symlinked
    # this name to the real binary, and a redirection would write straight
    # through the symlink and truncate whatever it points at on the real PATH.
    rm -f "$root/tier-b/$tb_tool"
    cat > "$root/tier-b/$tb_tool" <<FAKE_TOOL
#!/usr/bin/env bash
printf '%s %s\n' "$tb_tool" "\$*" >> "$marker"
exit 1
FAKE_TOOL
    chmod +x "$root/tier-b/$tb_tool"
  done
  for sub in "${http_subs[@]}"; do
    # The exit status is deliberately not asserted: SPEC.md §7 has Tier B exit
    # 2 without an `index` block in okf.json, and this fixture-less directory
    # has no okf.json at all. What is asserted is that whatever it says, it is
    # no longer the preflight talking.
    out="$(_okf_with_path "$root/tier-b" "$sub" 2>&1)" || true
    case "$out" in
      *"missing required"*)
        _fail "okf $sub gets past the preflight once its tools are installed" "$out"
        ;;
      *) _pass "okf $sub gets past the preflight once its tools are installed" ;;
    esac
  done
  if [ -s "$marker" ]; then
    _fail "no okf invocation in this test tries to reach the network" \
      "a Tier B tool was called, with:" "$(cat "$marker")"
  else
    _pass "no okf invocation in this test tries to reach the network"
  fi
  return 0
}

# SPEC.md §7's global flags, read back out of its prose the way the subcommand
# names are: every backticked token in that section that looks like a flag. A
# third global flag added to the spec then arrives here as a flag with nothing
# testing it, rather than as one nobody noticed.
_okf_spec_global_flags() {
  awk '
    /^## 7\./ { in_section = 1; next }
    in_section && /^## / { exit }
    in_section {
      n = split($0, part, "`")
      # Backticks come in pairs, so the quoted spans are the even indices.
      for (i = 2; i <= n; i += 2) {
        if (part[i] ~ /^-/) print part[i]
      }
    }
  ' "$TOOLKIT_ROOT/SPEC.md" | sort -u
}

# bin/okf's own view of one command line: the root it resolved, the config file
# it would read, the directory it ends up in, and what is left for dispatch.
#
# Obtained by sourcing bin/okf and calling parse_globals directly, because none
# of it is printed anywhere — every subcommand is still a stub, and a flag that
# printed it would be CLI surface SPEC.md §7 does not define. Sourcing gets the
# functions without running a command line, which is what the guard around
# bin/okf's `main` call is for. The names used here — parse_globals, enter_root,
# OKF_ROOT, OKF_CONFIG, OKF_ARGV — are the contract this item owes every
# subcommand written after it, so a rename that breaks them should fail loudly.
_okf_context() { # $1 = directory to run from, $2.. = okf arguments
  local from="$1"
  shift
  local probe="$HARNESS_STATE/okf-context-probe.sh"
  if [ ! -f "$probe" ]; then
    cat > "$probe" <<'PROBE'
#!/usr/bin/env bash
okf_script="$1"
shift
# shellcheck source=/dev/null
. "$okf_script"
parse_globals ${1+"$@"}
enter_root
printf 'root=%s\n' "$OKF_ROOT"
printf 'config=%s\n' "$OKF_CONFIG"
printf 'cwd=%s\n' "$PWD"
# Bracketed one by one rather than joined: "$OKF_ARGV[*]" would read the same
# whether an argument with a space in it survived as one argument or was split
# into two, and surviving as one is the whole point of the quoting in bin/okf.
args=""
for arg in ${OKF_ARGV[@]+"${OKF_ARGV[@]}"}; do
  args="$args[$arg]"
done
printf 'args=%s\n' "$args"
PROBE
    chmod +x "$probe" || return 1
  fi
  (CDPATH= cd "$from" && "$probe" "$TOOLKIT_ROOT/bin/okf" ${1+"$@"}) 2>&1
}

# The same context, but reached the way a real invocation reaches it: through
# main, which is the thing that actually has to enter the root and hand what is
# left of the line to the subcommand. Calling parse_globals directly proves the
# resolution and nothing about who acts on it.
#
# Every subcommand's own function is replaced, after sourcing, with one that
# reports instead of doing its work — so main runs all the way through dispatch
# and the report is made from inside the subcommand, where the process has
# finished moving. All of them rather than the stub they used to share: as the
# checklist replaces those stubs one by one, a probe that hooked the stub would
# quietly stop being reached by the subcommand it was pointed at.
_okf_dispatch_context() { # $1 = directory to run from, $2.. = okf arguments
  local from="$1"
  shift
  local probe="$HARNESS_STATE/okf-dispatch-probe.sh"
  if [ ! -f "$probe" ]; then
    cat > "$probe" <<'PROBE'
#!/usr/bin/env bash
okf_script="$1"
shift
# shellcheck source=/dev/null
. "$okf_script"
_report_context() { # $1 = subcommand name
  local args="" arg
  for arg in ${OKF_ARGV[@]+"${OKF_ARGV[@]}"}; do
    args="$args[$arg]"
  done
  printf 'root=%s\n' "$OKF_ROOT"
  printf 'config=%s\n' "$OKF_CONFIG"
  printf 'cwd=%s\n' "$PWD"
  printf 'sub=%s\n' "$1"
  printf 'args=%s\n' "$args"
}
for _sub in "${OKF_SUBCOMMANDS[@]}"; do
  eval "cmd_$_sub() { _report_context $_sub; }"
done
main ${1+"$@"}
PROBE
    chmod +x "$probe" || return 1
  fi
  (CDPATH= cd "$from" && "$probe" "$TOOLKIT_ROOT/bin/okf" ${1+"$@"}) 2>&1
}

_okf_context_field() { # $1 = context output, $2 = field name
  printf '%s\n' "$1" | sed -n "s/^$2=//p"
}

# SPEC.md §7 defines the two global flags, so the help is checked against the
# spec rather than against a copy of the flags written out here.
test_okf_global_flags_are_documented() {
  local okf="$TOOLKIT_ROOT/bin/okf"
  if [ ! -x "$okf" ]; then
    _fail "bin/okf is an executable script" "missing or not executable: $okf"
    return 1
  fi

  local -a flags=()
  local flag
  while IFS= read -r flag; do
    [ -n "$flag" ] && flags+=("$flag")
  done < <(_okf_spec_global_flags)
  # Guards the extraction: were §7's sentence reworded past it, every check
  # below would vanish and this test would pass having asserted nothing.
  # Bailing rather than continuing, because "${flags[@]}" on an empty array
  # aborts the whole run under `set -u` on bash 3.2.
  if [ "${#flags[@]}" -eq 0 ]; then
    _fail "SPEC.md §7 names its global flags" \
      "extracted no flag names from the CLI surface section"
    return 1
  fi
  assert_eq 2 "${#flags[@]}" "SPEC.md §7 defines 2 global flags"

  local help
  help="$("$okf" --help)"
  for flag in "${flags[@]}"; do
    assert_contains "$help" "$flag" "okf --help documents the global $flag"
  done

  # The default SPEC.md §7 gives for --config, which is the one thing about
  # these flags a user cannot work out from the flag name alone.
  assert_contains "$help" "./okf.json" \
    "okf --help gives SPEC.md §7's default config path"

  # The usage line, so someone who reads only the first line of the help still
  # learns that the two exist.
  local usage_line
  usage_line="$(printf '%s\n' "$help" | grep '^Usage:')"
  for flag in "${flags[@]}"; do
    assert_contains "$usage_line" "${flag%% *}" "okf --help's usage line shows ${flag%% *}"
  done
  return 0
}

# The command-line half: the flags are taken out of the line wherever they
# appear, and what is left is still dispatched.
_okf_global_flags_dispatch_probe() {
  local okf="$TOOLKIT_ROOT/bin/okf" out

  # Absence of a rejection only means anything if a rejection was reachable at
  # all: were the global-flag parser to exit early on every line, each check
  # below would silently become one that cannot fail.
  out="$("$okf" definitely-not-a-subcommand 2>&1)" || true
  case "$out" in
    *"unknown subcommand: definitely-not-a-subcommand"*)
      _pass "an okf invocation in the fixture reaches dispatch"
      ;;
    *)
      _fail "an okf invocation in the fixture reaches dispatch" \
        "an unknown subcommand was not rejected by name, so nothing below can" \
        "tell a consumed flag from an early exit:" "$out"
      return 1
      ;;
  esac

  local -a flags=()
  local flag value
  while IFS= read -r flag; do
    [ -n "$flag" ] && flags+=("$flag")
  done < <(_okf_spec_global_flags)
  if [ "${#flags[@]}" -eq 0 ]; then
    _fail "SPEC.md §7 names its global flags" \
      "extracted no flag names from the CLI surface section"
    return 1
  fi

  for flag in "${flags[@]}"; do
    flag="${flag%% *}"
    case "$flag" in
      -C) value="$FIXTURE_DIR" ;;
      --config) value="okf.json" ;;
      *)
        # A global flag SPEC.md §7 has grown since this test was written. Said
        # out loud rather than skipped: an unexercised flag is how one ships
        # documented and unimplemented.
        _fail "tests/toolkit.sh exercises the global $flag" \
          "no argument is defined here for it, so it goes unchecked"
        continue
        ;;
    esac

    # Before the subcommand and after it, because SPEC.md §7 says *every
    # subcommand* accepts these. Either way the flag and its argument are gone
    # by the time dispatch sees the line — if they were not, the offender named
    # would be the flag or its value rather than the subcommand.
    out="$("$okf" "$flag" "$value" definitely-not-a-subcommand 2>&1)" || true
    assert_contains "$out" "unknown subcommand: definitely-not-a-subcommand" \
      "okf $flag VALUE <subcommand> dispatches the subcommand"
    out="$("$okf" definitely-not-a-subcommand "$flag" "$value" 2>&1)" || true
    assert_contains "$out" "unknown subcommand: definitely-not-a-subcommand" \
      "okf <subcommand> $flag VALUE dispatches the subcommand"

    # A flag with nothing after it would otherwise swallow the subcommand:
    # `okf -C list` running against a directory called list.
    assert_exit 1 "$okf" "$flag"
    out="$(last_output)"
    assert_contains "$out" "$flag" "okf $flag with no argument says which flag is short one"
    case "$out" in
      *"Subcommands:"*)
        _fail "okf $flag with no argument does not print the whole help" "$out"
        ;;
      *) _pass "okf $flag with no argument does not print the whole help" ;;
    esac

    # Twice is a mistake, and the two values disagree more often than not.
    assert_exit 1 "$okf" "$flag" "$value" "$flag" "$value" list
    assert_contains "$(last_output)" "$flag" \
      "okf refuses a repeated $flag rather than picking one"

    # An empty argument is not the default, and silently treating it as one
    # would run against $PWD while the caller believed otherwise.
    assert_exit 1 "$okf" "$flag" "" list
    assert_contains "$(last_output)" "$flag" \
      "okf refuses an empty $flag argument"
  done

  # -C names a directory, and one that is not there is worth saying so about in
  # the same single line the preflight uses — before dispatch, so no subcommand
  # has begun work against the wrong tree. The one line being -C's own refusal
  # is what shows nothing was dispatched: anything the subcommand said instead,
  # having been handed a root that is not there, would be a different line.
  assert_exit 1 "$okf" -C "$FIXTURE_DIR/definitely-not-a-directory" list
  out="$(last_output)"
  assert_eq 1 "$(_okf_line_count "$out")" "a -C at a missing directory is one line"
  assert_contains "$out" "definitely-not-a-directory" "that line names the directory"
  assert_contains "$out" "-C:" \
    "a -C at a missing directory stops before dispatch, with -C's own refusal"

  # A directory that is there but cannot be entered is -C's failure to report,
  # in the same single line: bash's own cd diagnostic names a line number
  # inside bin/okf, which tells the caller nothing they can act on.
  local locked="$FIXTURE_DIR/locked"
  if ! mkdir -p "$locked" || ! chmod 000 "$locked"; then
    _fail "an unenterable directory can be made" "mkdir/chmod failed: $locked"
  elif (cd "$locked") 2> /dev/null; then
    # root, or a filesystem that does not enforce the mode. There is no
    # unenterable directory to be had here, so there is nothing to check.
    _skip "okf -C at an unenterable directory says so in one line" \
      "this user can enter a chmod 000 directory"
    chmod 700 "$locked" 2> /dev/null || true
  else
    assert_exit 1 "$okf" -C "$locked" list
    out="$(last_output)"
    assert_eq 1 "$(_okf_line_count "$out")" \
      "okf -C at an unenterable directory says so in one line"
    assert_contains "$out" "locked" "that line names the directory"
    # Restored so the fixture copy can be removed with everything else.
    chmod 700 "$locked" 2> /dev/null || true
  fi

  # A flag where the path should be is the same slip one word later, and
  # taking it for a filename loses the flag as well as the config.
  assert_exit 1 "$okf" check --config --strict
  out="$(last_output)"
  assert_contains "$out" "--strict" "okf --config --strict says what it was given instead"

  # A dashed word can never be a subcommand, so the useful thing to say about
  # one is which flags do belong there — `okf -Csrc list` is the -C spelling
  # okf does not take, and the glued directory is why.
  assert_exit 1 "$okf" -Csrc list
  out="$(last_output)"
  assert_contains "$out" "unknown subcommand: -Csrc" "okf -CDIR is rejected by name"
  assert_contains "$out" "-C DIR" "and is told how -C is spelled"

  # `okf --config list` is a --config with its path left out, and taking the
  # subcommand for a filename leaves nothing to run and nothing said about why.
  assert_exit 1 "$okf" --config list
  out="$(last_output)"
  assert_contains "$out" "list" "okf --config <subcommand> names what it was given"
  case "$out" in
    *"Subcommands:"*)
      _fail "okf --config <subcommand> explains itself instead of printing help" "$out"
      ;;
    *) _pass "okf --config <subcommand> explains itself instead of printing help" ;;
  esac

  # A `--` ahead of the subcommand ends the global flags rather than being
  # taken for a subcommand called `--`, so what follows it is dispatched.
  out="$("$okf" -- definitely-not-a-subcommand 2>&1)" || true
  assert_contains "$out" "unknown subcommand: definitely-not-a-subcommand" \
    "okf -- <subcommand> dispatches the subcommand"

  # ...and on its own it leaves nothing to do, like a bare invocation.
  assert_exit 1 "$okf" --
  out="$(last_output)"
  assert_contains "$out" "Subcommands:" "okf -- on its own prints its help"
  case "$out" in
    *"unknown subcommand"*)
      _fail "okf -- on its own is not read as a subcommand named --" "$out"
      ;;
    *) _pass "okf -- on its own is not read as a subcommand named --" ;;
  esac

  # A root and nothing to do with it is still nothing to do: the same help on
  # stderr, exiting non-zero, that a bare `okf` prints.
  local bare_out bare_err="$HARNESS_STATE/okf_globals_stderr"
  bare_out="$("$okf" -C "$FIXTURE_DIR" 2> "$bare_err")" && true
  local bare_rc=$?
  assert_eq 1 "$bare_rc" "okf -C DIR with no subcommand exits 1"
  assert_eq "" "$bare_out" "okf -C DIR with no subcommand prints nothing on stdout"
  assert_contains "$(cat "$bare_err")" "Subcommands:" \
    "okf -C DIR with no subcommand prints its help on stderr"
  rm -f "$bare_err"

  # ...and asking for help is still asking for help.
  assert_exit 0 "$okf" -C "$FIXTURE_DIR" --help
  assert_contains "$(last_output)" "Subcommands:" "okf -C DIR --help still prints help"
  return 0
}

test_okf_global_flags_reach_dispatch() {
  local okf="$TOOLKIT_ROOT/bin/okf"
  if [ ! -x "$okf" ]; then
    _fail "bin/okf is an executable script" "missing or not executable: $okf"
    return 1
  fi
  # In a throwaway repo, not the checkout: `okf -C .` on the toolkit itself
  # would have any implemented subcommand write into the repo under test.
  with_fixture_repo tiny _okf_global_flags_dispatch_probe
}

# The resolution half: what -C and --config actually come to. SPEC.md §7 gives
# -C the repo root every subcommand resolves paths against and --config the
# override for ./okf.json, and neither is visible from the outside while every
# subcommand is a stub — so this reads bin/okf's own resolved context.
_okf_global_flags_context_probe() {
  local root src ctx
  root="$(CDPATH= cd "$FIXTURE_DIR" && pwd)" || {
    _fail "the fixture repo can be entered" "cd failed: $FIXTURE_DIR"
    return 1
  }
  src="$root/src"
  if [ ! -d "$src" ]; then
    _fail "the tiny fixture has a src/ subdirectory" "no such directory: $src"
    return 1
  fi

  # Guards everything below: if bin/okf cannot be sourced, or these functions
  # have been renamed, every field read comes back empty and every comparison
  # below would be against an empty string.
  ctx="$(_okf_context "$root" list --missing)"
  case "$ctx" in
    *"root="*) _pass "bin/okf's resolved context can be read back" ;;
    *)
      _fail "bin/okf's resolved context can be read back" \
        "sourcing bin/okf and calling parse_globals printed no root:" "$ctx"
      return 1
      ;;
  esac

  # No flags at all: the directory okf was invoked in, and SPEC.md §7's default
  # ./okf.json inside it.
  assert_eq "$root" "$(_okf_context_field "$ctx" root)" \
    "without -C the root is the current directory"
  assert_eq "$root/okf.json" "$(_okf_context_field "$ctx" config)" \
    "without --config the config is the root's okf.json"
  assert_eq "[list][--missing]" "$(_okf_context_field "$ctx" args)" \
    "a line with no global flags reaches dispatch unchanged"

  # -C DIR: the root moves, the process moves with it — a subcommand that runs
  # `git ls-files` gets the other repo's files without having to know about -C
  # at all — and the default config moves too, because SPEC.md §6 puts okf.json
  # at the repo root.
  ctx="$(_okf_context "$root" -C src list)"
  assert_eq "$src" "$(_okf_context_field "$ctx" root)" \
    "-C DIR makes DIR the root, resolved from where okf was invoked"
  assert_eq "$src" "$(_okf_context_field "$ctx" cwd)" \
    "-C DIR is entered, so relative paths resolve against it"
  assert_eq "$src/okf.json" "$(_okf_context_field "$ctx" config)" \
    "-C DIR moves the default okf.json to the new root"
  assert_eq "[list]" "$(_okf_context_field "$ctx" args)" \
    "-C DIR and its argument are taken out of the line"

  # An absolute -C from somewhere else entirely, which is the form a caller
  # scripting okf against another checkout will use.
  ctx="$(_okf_context "$src" -C "$root" list)"
  assert_eq "$root" "$(_okf_context_field "$ctx" root)" "an absolute -C is used as given"

  # --config PATH overrides the default. Relative to the root, not to the
  # caller: -C sets what `.` means for the run, and SPEC.md §7's default is
  # `./okf.json`, so `-C other --config okf.ci.json` reads the other repo's CI
  # config. An absolute path is how to point outside the root.
  ctx="$(_okf_context "$root" --config okf.ci.json list)"
  assert_eq "$root/okf.ci.json" "$(_okf_context_field "$ctx" config)" \
    "--config PATH overrides the default okf.json"
  assert_eq "[list]" "$(_okf_context_field "$ctx" args)" \
    "--config and its argument are taken out of the line"
  ctx="$(_okf_context "$root" -C src --config okf.ci.json list)"
  assert_eq "$src/okf.ci.json" "$(_okf_context_field "$ctx" config)" \
    "a relative --config resolves against the -C root"
  ctx="$(_okf_context "$src" --config "$root/elsewhere.json" list)"
  assert_eq "$root/elsewhere.json" "$(_okf_context_field "$ctx" config)" \
    "an absolute --config is used as given"

  # Order-independent, so nobody has to remember which of the two comes first.
  # The reversed line is pinned to its expected root and config first: on its
  # own, comparing two context blobs would pass just as happily if both of them
  # were the same failure.
  local ordered reversed
  ordered="$(_okf_context "$root" -C src --config okf.ci.json list)"
  reversed="$(_okf_context "$root" --config okf.ci.json -C src list)"
  assert_eq "$src" "$(_okf_context_field "$reversed" root)" \
    "--config ahead of -C still leaves -C's directory as the root"
  assert_eq "$src/okf.ci.json" "$(_okf_context_field "$reversed" config)" \
    "--config ahead of -C still resolves against the -C root"
  assert_eq "$ordered" "$reversed" \
    "the two global flags may be given in either order"

  # After the subcommand, and mixed in with its flags: SPEC.md §7 says every
  # subcommand accepts them, and what is left of the line keeps its order.
  ctx="$(_okf_context "$root" check --config okf.ci.json --strict)"
  assert_eq "$root/okf.ci.json" "$(_okf_context_field "$ctx" config)" \
    "a global flag is honoured after the subcommand too"
  assert_eq "[check][--strict]" "$(_okf_context_field "$ctx" args)" \
    "the subcommand keeps its own flags, in order"

  # --config=PATH, the spelling anyone used to the GNU tools will type. Passed
  # through instead, it would be an okf.json silently not read.
  ctx="$(_okf_context "$root" --config=okf.ci.json list)"
  assert_eq "$root/okf.ci.json" "$(_okf_context_field "$ctx" config)" \
    "--config=PATH is the same as --config PATH"
  assert_eq "[list]" "$(_okf_context_field "$ctx" args)" \
    "--config=PATH is taken out of the line too"

  # Its short counterpart is deliberately not a flag: `okf search -Csrc` is a
  # query, and a scan that glued -C to whatever followed it would swallow the
  # one argument that subcommand exists to take.
  ctx="$(_okf_context "$root" search -Csrc)"
  assert_eq "$root" "$(_okf_context_field "$ctx" root)" \
    "-CDIR does not re-root the run"
  assert_eq "[search][-Csrc]" "$(_okf_context_field "$ctx" args)" \
    "-CDIR reaches the subcommand as the operand it looks like"

  # Past a `--` the same words are the subcommand's own arguments — a query for
  # `okf search` is free to contain --config — and the root and config are the
  # defaults, untouched.
  ctx="$(_okf_context "$root" search -- --config /tmp/nope -C /tmp)"
  assert_eq "$root/okf.json" "$(_okf_context_field "$ctx" config)" \
    "a --config past -- is query text, not a flag"
  assert_eq "$root" "$(_okf_context_field "$ctx" root)" \
    "a -C past -- is query text, not a flag"
  assert_eq "[search][--][--config][/tmp/nope][-C][/tmp]" "$(_okf_context_field "$ctx" args)" \
    "everything past -- reaches the subcommand unchanged"

  # Through main, and all the way into the subcommand: the resolution above is
  # only worth anything if the invocation acts on it. A -C that resolved
  # perfectly and then dispatched from the directory the caller happened to be
  # standing in would pass every check above it.
  ctx="$(_okf_dispatch_context "$root" -C src list --missing)"
  case "$ctx" in
    *"cwd="*) _pass "a real okf invocation reports where it got to" ;;
    *)
      _fail "a real okf invocation reports where it got to" \
        "main printed no context from inside the subcommand:" "$ctx"
      return 1
      ;;
  esac
  assert_eq "$src" "$(_okf_context_field "$ctx" cwd)" \
    "okf -C DIR dispatches from inside DIR"
  assert_eq "$src" "$(_okf_context_field "$ctx" root)" \
    "the subcommand is given DIR as the root"
  assert_eq "$src/okf.json" "$(_okf_context_field "$ctx" config)" \
    "the subcommand is given the new root's okf.json"
  assert_eq "list" "$(_okf_context_field "$ctx" sub)" \
    "the subcommand named after the global flags is the one dispatched"
  assert_eq "[list][--missing]" "$(_okf_context_field "$ctx" args)" \
    "it keeps its own flags"

  # An argument is one argument however many spaces are inside it, and a glob
  # in one is a glob the subcommand receives rather than a directory listing.
  # This is what every ${1+"$@"} and ${arr[@]+"..."} in bin/okf is for, and
  # nothing else here would notice their loss: a line that came apart into more
  # arguments than it started with still dispatches, and still reads the right
  # config.
  ctx="$(_okf_context "$root" search "two words" --k 5)"
  assert_eq "[search][two words][--k][5]" "$(_okf_context_field "$ctx" args)" \
    "an argument with a space in it stays one argument"
  ctx="$(_okf_context "$root" fanin '*' --config okf.ci.json)"
  assert_eq "[fanin][*]" "$(_okf_context_field "$ctx" args)" \
    "an argument that is a glob reaches the subcommand unexpanded"

  # CDPATH makes a relative cd search it before the current directory, and echo
  # where it landed. Exported — and it is exported, in plenty of shell profiles
  # — an okf that read it would resolve `-C src` to a stranger's src.
  local decoy="$root/decoy"
  if ! mkdir -p "$decoy/src"; then
    _fail "a CDPATH decoy can be made" "mkdir failed: $decoy/src"
  else
    ctx="$(
      export CDPATH="$decoy"
      _okf_context "$root" -C src list
    )"
    assert_eq "$src" "$(_okf_context_field "$ctx" root)" \
      "an exported CDPATH does not redirect a relative -C"
    assert_eq "$src" "$(_okf_context_field "$ctx" cwd)" \
      "an exported CDPATH does not redirect the directory okf enters"
    rm -rf "$decoy"
  fi

  # Ahead of the subcommand the same `--` is this parser's own end-of-flags
  # marker: there is no subcommand yet for it to belong to, so it is consumed
  # and dispatch sees the word after it.
  ctx="$(_okf_context "$root" -- -C /tmp list)"
  assert_eq "$root" "$(_okf_context_field "$ctx" root)" \
    "a -C after a leading -- is not a flag"
  assert_eq "[-C][/tmp][list]" "$(_okf_context_field "$ctx" args)" \
    "a leading -- is consumed, and what follows it is dispatched"
  return 0
}

test_okf_global_flags_resolve_the_root_and_config() {
  local okf="$TOOLKIT_ROOT/bin/okf"
  if [ ! -x "$okf" ]; then
    _fail "bin/okf is an executable script" "missing or not executable: $okf"
    return 1
  fi
  with_fixture_repo tiny _okf_global_flags_context_probe
}

# SPEC.md §6 is where okf.json's defaults are decided, so they are read back out
# of its JSON block rather than restated here: a default changed there without
# bin/okf following then fails as a mismatch instead of quietly never being
# checked against anything.
_okf_spec_config_json() {
  awk '
    /^## 6\./ { in_section = 1; next }
    in_section && /^## / { exit }
    in_section && /^```json$/ { in_block = 1; next }
    in_block && /^```$/ { exit }
    in_block { print }
  ' "$TOOLKIT_ROOT/SPEC.md"
}

# The two things any okf check needs before it can mean anything: a bin/okf
# to run, and the jq SPEC.md §3 makes a hard requirement of it. jq is not an
# extra dependency taken on here — a machine without it cannot run okf at all,
# so there would be nothing for these checks to read back.
_okf_preconditions() {
  local okf="$TOOLKIT_ROOT/bin/okf"
  if [ ! -x "$okf" ]; then
    _fail "bin/okf is an executable script" "missing or not executable: $okf"
    return 1
  fi
  if ! command -v jq > /dev/null 2>&1; then
    _fail "jq is installed" \
      "SPEC.md §3 makes jq a hard requirement of bin/okf, so okf could not have" \
      "run here at all — install jq before reading anything into this failure"
    return 1
  fi
  return 0
}

_okf_init_defaults_probe() {
  local okf="$TOOLKIT_ROOT/bin/okf" spec expected actual

  spec="$(_okf_spec_config_json)"
  # Guards the extraction: were §6's block retitled or its fence changed past
  # this, every comparison below would be against an empty string.
  if [ -z "$spec" ]; then
    _fail "SPEC.md §6 shows the okf.json defaults" \
      "extracted no JSON block from the okf.json section"
    return 1
  fi
  # §6's `index` block is dropped from both sides: SPEC.md §1 calls Tier B
  # opt-in and §6 defines an exit 2 for a config without one, so a freshly
  # initialised repo has to be without it. That it stays absent is asserted
  # separately below — this comparison alone could not see it arrive.
  if ! expected="$(printf '%s\n' "$spec" | jq -S 'del(.index)' 2>&1)"; then
    _fail "SPEC.md §6's JSON block parses" "$expected"
    return 1
  fi

  # The fixture is a source tree, not an initialised bundle. Were an okf.json
  # already sitting here, init would refuse and everything below would be
  # reading a file it never wrote.
  if [ -e okf.json ]; then
    _fail "the fixture repo starts without an okf.json" "already present under $PWD"
    return 1
  fi

  assert_exit 0 "$okf" init
  assert_contains "$(last_output)" "okf.json" "okf init says what it wrote"

  if [ ! -f okf.json ]; then
    _fail "okf init writes okf.json in the repo root" "no okf.json under $PWD"
    return 1
  fi
  _pass "okf init writes okf.json in the repo root"

  if ! actual="$(jq -S 'del(.index)' okf.json 2>&1)"; then
    _fail "okf init writes parseable JSON" "$actual"
    return 1
  fi
  assert_eq "$expected" "$actual" "okf init writes SPEC.md §6's defaults"
  assert_eq "null" "$(jq -c '.index' okf.json)" \
    "okf init writes no index block, so Tier B stays something to opt into"

  # SPEC.md §7 gives every subcommand --config PATH, init included: it writes
  # where it was told the settings live rather than to a hard-coded okf.json,
  # and that path is resolved against the root rather than against the caller's
  # directory. Run against a root of its own, because init also writes a
  # bundle-root index.md and refuses as a whole when any of its targets is
  # already there — the repo above has had one since the plain init.
  if ! mkdir -p ci; then
    _fail "a subdirectory can be made in the fixture" "mkdir failed: $PWD/ci"
  else
    assert_exit 0 "$okf" -C ci --config okf.ci.json init
    if [ ! -f ci/okf.ci.json ]; then
      _fail "okf --config PATH init writes PATH" "no ci/okf.ci.json under $PWD"
    else
      assert_eq "$expected" "$(jq -S 'del(.index)' ci/okf.ci.json)" \
        "okf --config PATH init writes the same defaults to PATH"
    fi
  fi

  # ...and -C DIR, which has already moved the default okf.json to that root.
  if ! mkdir -p sub; then
    _fail "a subdirectory can be made in the fixture" "mkdir failed: $PWD/sub"
  else
    assert_exit 0 "$okf" -C sub init
    if [ -f sub/okf.json ]; then
      _pass "okf -C DIR init writes DIR's okf.json"
    else
      _fail "okf -C DIR init writes DIR's okf.json" "no sub/okf.json under $PWD"
    fi
  fi

  # A mistyped flag is answered rather than acted on: `okf init --fore` must
  # not be an init that quietly skipped the --force it was asked for. Both of
  # these would exit 1 anyway on this now-initialised repo, so it is the named
  # offender and not the status that tells the two refusals apart.
  assert_exit 1 "$okf" init --fore
  # "unknown flag: --fore" and not "--fore" on its own: the usage line the
  # refusal prints alongside it contains "[--force]", which any check for the
  # bare typo matches whether or not the message ever names it.
  assert_contains "$(last_output)" "unknown flag: --fore" \
    "okf init names a flag it does not know"
  assert_exit 1 "$okf" init extra
  assert_contains "$(last_output)" "extra" "okf init names an argument it does not take"
  return 0
}

_okf_init_force_probe() {
  local okf="$TOOLKIT_ROOT/bin/okf" before out

  assert_exit 0 "$okf" init
  # Replaced with something nobody would mistake for what init writes, so an
  # overwrite below is seen rather than inferred.
  printf '{"okf_version": "hand-edited"}\n' > okf.json
  before="$(cat okf.json)"

  assert_exit 1 "$okf" init
  out="$(last_output)"
  assert_contains "$out" "okf.json" "the refusal names the file in the way"
  assert_contains "$out" "--force" "the refusal says how to overwrite it anyway"
  assert_eq "$before" "$(cat okf.json)" "a refused init leaves the file exactly as it was"

  # Existence is what the refusal turns on, not content: okf cannot tell a
  # config somebody tuned by hand from one it wrote itself, and an empty file
  # is still somebody's.
  : > okf.json
  assert_exit 1 "$okf" init
  if [ -f okf.json ] && [ ! -s okf.json ]; then
    _pass "an empty okf.json is still an okf.json"
  else
    _fail "an empty okf.json is still an okf.json" \
      "okf init wrote over it, or removed it"
  fi

  # --force is the caller saying they know which of the two it is.
  printf '{"okf_version": "hand-edited"}\n' > okf.json
  assert_exit 0 "$okf" init --force
  assert_eq "0.2" "$(jq -r '.okf_version // empty' okf.json 2>/dev/null)" \
    "okf init --force overwrites what was there"

  # ...and on a repo with no okf.json at all it is just init.
  rm -f okf.json
  assert_exit 0 "$okf" init --force
  assert_eq "0.2" "$(jq -r '.okf_version // empty' okf.json 2>/dev/null)" \
    "okf init --force also writes an okf.json that is not there yet"

  # A symlinked okf.json is refused both ways, --force included: a redirection
  # writes through the link, so the file destroyed would be the one it points
  # at — somewhere else entirely, and outside the repo as often as not.
  local shared="$FIXTURE_DIR/shared.json" was
  was='{"okf_version": "pointed-at"}'
  printf '%s\n' "$was" > "$shared"
  rm -f okf.json
  if ! ln -s "$shared" okf.json; then
    _fail "a symlinked okf.json can be made in the fixture" "ln -s failed"
  else
    assert_exit 1 "$okf" init
    assert_contains "$(last_output)" "link" "okf init says a symlinked okf.json is a link"
    assert_exit 1 "$okf" init --force
    assert_contains "$(last_output)" "link" \
      "okf init --force says so too, rather than writing through it"
    assert_eq "$was" "$(cat "$shared")" \
      "okf init --force does not write through a symlinked okf.json"
    if [ -L okf.json ]; then
      _pass "and does not quietly replace the link either"
    else
      _fail "and does not quietly replace the link either" "the symlink is gone"
    fi
    rm -f okf.json
  fi
  rm -f "$shared"

  # An error okf cannot avoid is still okf's to report: bash's own diagnostic
  # names a line number inside bin/okf, which tells the caller nothing they can
  # act on, and it arrives first.
  if ! mkdir okf.json; then
    _fail "a directory can be made where okf.json goes" "mkdir failed: $PWD/okf.json"
  else
    assert_exit 1 "$okf" init --force
    out="$(last_output)"
    assert_eq 1 "$(_okf_line_count "$out")" \
      "a write okf cannot do is reported in one line, not in two"
    assert_contains "$out" "okf.json" "and that line names the file"
    rmdir okf.json
  fi
  return 0
}

# SPEC.md §6 defines okf.json's contents and §7 makes writing it `okf init`.
test_okf_init_writes_the_spec_defaults() {
  _okf_preconditions || return 1
  # In a throwaway repo, not the checkout: `okf init` here would drop an
  # okf.json into the toolkit itself.
  with_fixture_repo tiny _okf_init_defaults_probe
}

# The other half of the same PLAN.md item: an existing okf.json is not
# overwritten without --force.
test_okf_init_refuses_to_overwrite_without_force() {
  _okf_preconditions || return 1
  with_fixture_repo tiny _okf_init_force_probe
}

# A file's YAML frontmatter, without its `---` delimiters, read exactly the way
# SPEC.md §4's formatting contract says the shell reads it: `---` on line 1,
# closing on the next line that is exactly `---`. Prints nothing when the file
# does not open that way — which is the failure its callers report, so nothing
# here has to guess at a diagnosis.
_okf_frontmatter() { # $1 = path
  awk '
    NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { exit }
    { print }
  ' "$1"
}

# Whether that block is closed. Separate from _okf_frontmatter because an
# unterminated block and a file that never opened one both read back as no
# frontmatter at all, and only one of them is "the delimiter is missing".
_okf_frontmatter_closed() { # $1 = path
  awk '
    NR == 1 { if ($0 != "---") exit 1; next }
    $0 == "---" { closed = 1; exit }
    END { exit closed ? 0 : 1 }
  ' "$1"
}

# One top-level scalar out of a frontmatter block. The §4 extraction rule for
# an unindented key, which is all the root index.md has.
_okf_frontmatter_value() { # $1 = frontmatter text, $2 = key
  printf '%s\n' "$1" | sed -n "s/^$2: //p" | sed -n 1p
}

# SPEC.md §4's formatting contract, checked against a file okf wrote whose
# frontmatter is flat — every key top-level, no `code:` block. It is
# load-bearing rather than cosmetic (the shell reads frontmatter with awk), so a
# writer that drifts off it breaks every reader at once, silently.
#
# Flat is a precondition, not an oversight: §4 also spells out how a nested
# `code:` block must be indented, and a checker that accepted one would have to
# have an opinion about indentation this file's only caller cannot exercise.
# Whatever writes a `code:` block brings its own check for that half.
_okf_assert_flat_frontmatter_contract() { # $1 = path, $2 = what to call it
  local path="$1" what="$2" front line
  local -a bad=()

  if [ ! -f "$path" ]; then
    _fail "$what obeys the SPEC.md §4 formatting contract" "no such file: $path"
    return 1
  fi

  front="$(_okf_frontmatter "$path")"
  if [ -z "$front" ]; then
    _fail "$what obeys the SPEC.md §4 formatting contract" \
      "no --- delimited frontmatter at the top of $path"
    return 1
  fi
  if ! _okf_frontmatter_closed "$path"; then
    bad+=("the frontmatter block is never closed by a line that is exactly ---")
  fi
  case "$(cat "$path")" in
    *$'\t'*) bad+=("the file contains a tab") ;;
  esac

  while IFS= read -r line; do
    case "$line" in
      # A folded or literal scalar, which §4 rules out in any field the shell
      # reads.
      [A-Za-z]*": |" | [A-Za-z]*": >") bad+=("folded scalar: $line") ;;
      [A-Za-z]*": "*) ;;
      *) bad+=("not an unindented \`key: value\` line: $line") ;;
    esac
  done <<< "$front"

  if [ "${#bad[@]}" -eq 0 ]; then
    _pass "$what obeys the SPEC.md §4 formatting contract"
    return 0
  fi
  _fail "$what obeys the SPEC.md §4 formatting contract" "${bad[@]}"
  return 1
}

_okf_init_index_probe() {
  local okf="$TOOLKIT_ROOT/bin/okf" spec_version front out

  # The version is read back out of SPEC.md §6's own block for the same reason
  # the defaults are: §4 makes the bundle root the only file allowed to declare
  # one, so the number it declares had better be the number §6 settled on.
  spec_version="$(_okf_spec_config_json | jq -r '.okf_version // empty' 2> /dev/null)"
  if [ -z "$spec_version" ]; then
    _fail "SPEC.md §6 declares an okf_version" \
      "extracted none from the okf.json block in the okf.json section"
    return 1
  fi

  if [ -e index.md ]; then
    _fail "the fixture repo starts without a bundle-root index.md" \
      "already present under $PWD"
    return 1
  fi

  assert_exit 0 "$okf" init
  assert_contains "$(last_output)" "index.md" \
    "okf init says it wrote the bundle-root index.md"

  if [ ! -f index.md ]; then
    _fail "okf init writes index.md in the bundle root" "no index.md under $PWD"
    return 1
  fi
  _pass "okf init writes index.md in the bundle root"

  _okf_assert_flat_frontmatter_contract index.md "the bundle-root index.md"

  front="$(_okf_frontmatter index.md)"
  # SPEC.md §4's reserved filenames: the repo-root index.md is the bundle root
  # and is `type: Codebase`. Per-directory index.md files are `type: Package`,
  # which is `okf index`'s business and not this file's.
  assert_eq "Codebase" "$(_okf_frontmatter_value "$front" type)" \
    "the bundle-root index.md is type: Codebase"
  # Quoted, as SPEC.md §6 makes it a JSON string: unquoted, YAML reads 0.2 as a
  # float, and the version after next — 0.10 — is read as 0.1 and stops
  # matching the okf.json it was copied from.
  assert_eq "\"$spec_version\"" "$(_okf_frontmatter_value "$front" okf_version)" \
    "the bundle-root index.md declares SPEC.md §6's okf_version, as a string"
  # ...and carries exactly one, counted over the whole file rather than the
  # frontmatter alone: §4 calls this the only file where the key is legal, so a
  # second one anywhere in it is a second answer to a question with one answer.
  assert_eq "1" "$(grep -o 'okf_version' index.md | wc -l | tr -d ' ')" \
    "the bundle-root index.md names okf_version exactly once"
  # The bundle is named for its root, not for whatever repo okf was built in.
  assert_eq "\"${PWD##*/}\"" "$(_okf_frontmatter_value "$front" title)" \
    "the bundle-root index.md is titled after the bundle root"

  # -C moves the bundle root, and the bundle root is where this file goes.
  if ! mkdir -p sub; then
    _fail "a subdirectory can be made in the fixture" "mkdir failed: $PWD/sub"
  else
    assert_exit 0 "$okf" -C sub init
    if [ -f sub/index.md ]; then
      _pass "okf -C DIR init writes DIR's bundle-root index.md"
      assert_eq "Codebase" \
        "$(_okf_frontmatter_value "$(_okf_frontmatter sub/index.md)" type)" \
        "and it is type: Codebase too"
    else
      _fail "okf -C DIR init writes DIR's bundle-root index.md" \
        "no sub/index.md under $PWD"
    fi
  fi

  # ...and --config cannot be pointed at it: init writes two documents, and one
  # file cannot be both. Refused rather than resolved, and refused before
  # anything is written — with --force there would be nothing about the result
  # to notice, both writes having succeeded into the same file.
  #
  # Checked in a root where neither file exists yet, and that is the point:
  # against an initialised bundle the same-inode check inside init_guard would
  # answer too, and this check — the only one that can speak for two files
  # neither of which is there — would never be the reason for the refusal.
  local alias
  if ! mkdir -p alias; then
    _fail "a subdirectory can be made in the fixture" "mkdir failed: $PWD/alias"
  else
    # `link` is a symlinked directory component: two paths that look nothing
    # alike naming one file. It is made up front so a filesystem without
    # symlinks skips only that spelling and not the plain one.
    local -a aliases=(index.md ./index.md)
    if ln -s . alias/link 2> /dev/null; then
      aliases+=(link/index.md)
    else
      _skip "a --config alias through a symlinked directory is refused" \
        "this filesystem has no symbolic links"
    fi
    for alias in "${aliases[@]}"; do
      assert_exit 1 "$okf" -C alias --config "$alias" init
      assert_contains "$(last_output)" "names the bundle-root index.md" \
        "okf --config $alias init refuses to write both documents into one file"
      if [ -e alias/index.md ] || [ -e alias/okf.json ]; then
        _fail "and that refusal writes nothing at all" \
          "found $(ls -A alias) under $PWD/alias"
        rm -f alias/index.md alias/okf.json
      else
        _pass "and that refusal writes nothing at all"
      fi
    done
  fi

  # --config does not move it. That flag says where the *settings* live — CI's
  # okf.ci.json is still this repo's settings — while SPEC.md §4 puts the
  # bundle root index.md at the root of the bundle and nowhere else. Run in a
  # root of its own so this is one plain init and not an --force overwriting
  # the index.md written above.
  if ! mkdir -p ci; then
    _fail "a second subdirectory can be made in the fixture" "mkdir failed: $PWD/ci"
  else
    assert_exit 0 "$okf" -C ci --config okf.ci.json init
    if [ -f ci/okf.ci.json ] && [ -f ci/index.md ] && [ ! -e ci/okf.json ]; then
      _pass "okf --config PATH init still writes the bundle root's own index.md"
    else
      out="$(ls -A ci 2>&1)"
      _fail "okf --config PATH init still writes the bundle root's own index.md" \
        "expected ci/okf.ci.json and ci/index.md, and no ci/okf.json" \
        "found: $out"
    fi
  fi
  return 0
}

_okf_init_index_force_probe() {
  local okf="$TOOLKIT_ROOT/bin/okf" was out

  # A hand-written root index.md, of the kind a repo may well already have, and
  # nothing else — so what init does about it is not confused with what it does
  # about an okf.json.
  was='# Notes I wrote myself'
  printf '%s\n' "$was" > index.md

  assert_exit 1 "$okf" init
  out="$(last_output)"
  assert_contains "$out" "index.md" "the refusal names the index.md in the way"
  assert_contains "$out" "--force" "the refusal says how to overwrite it anyway"
  assert_eq "$was" "$(cat index.md)" \
    "a refused init leaves the bundle-root index.md exactly as it was"
  # All-or-nothing: init writes two files, and a run that wrote the one that was
  # missing and refused the one that was there would leave a half-initialised
  # bundle behind an exit status meaning both.
  if [ -e okf.json ]; then
    _fail "a refused init writes nothing at all" \
      "index.md was refused, but okf.json was written anyway"
  else
    _pass "a refused init writes nothing at all"
  fi

  # --force is the caller saying they know what is there.
  assert_exit 0 "$okf" init --force
  assert_eq "Codebase" "$(_okf_frontmatter_value "$(_okf_frontmatter index.md)" type)" \
    "okf init --force overwrites the bundle-root index.md"
  if [ -f okf.json ]; then
    _pass "and writes the okf.json its refusal had been holding up"
  else
    _fail "and writes the okf.json its refusal had been holding up" "no okf.json under $PWD"
  fi

  # A symlinked index.md is refused both ways, exactly as a symlinked okf.json
  # is: a redirection writes through the link, so --force would replace a file
  # somewhere else entirely.
  local shared="$FIXTURE_DIR/shared-index.md"
  was='# Pointed at'
  printf '%s\n' "$was" > "$shared"
  rm -f index.md
  if ! ln -s "$shared" index.md; then
    _fail "a symlinked index.md can be made in the fixture" "ln -s failed"
  else
    assert_exit 1 "$okf" init --force
    assert_contains "$(last_output)" "link" \
      "okf init --force says a symlinked index.md is a link"
    assert_eq "$was" "$(cat "$shared")" \
      "okf init --force does not write through a symlinked index.md"
    if [ -L index.md ]; then
      _pass "and does not quietly replace that link either"
    else
      _fail "and does not quietly replace that link either" "the symlink is gone"
    fi
    rm -f index.md
  fi
  rm -f "$shared"

  # A target that is not a regular file — a directory sitting where index.md
  # goes — is refused before anything is written, --force or not: a redirection
  # cannot replace a directory, and left to the write that failure would arrive
  # only after okf.json had already gone in, which is the half-initialised
  # bundle init refuses whole runs to avoid.
  rm -f okf.json
  if ! mkdir index.md; then
    _fail "a directory can be made where index.md goes" "mkdir failed: $PWD/index.md"
  else
    assert_exit 1 "$okf" init --force
    out="$(last_output)"
    assert_eq 1 "$(_okf_line_count "$out")" \
      "a target okf cannot write is reported in one line, not in two"
    assert_contains "$out" "index.md" "and that line names it"
    if [ -e okf.json ]; then
      _fail "and nothing was written on the way to it" \
        "okf.json went in before the refusal, leaving a half-initialised bundle"
    else
      _pass "and nothing was written on the way to it"
    fi
    rmdir index.md
  fi

  # And the same for a target that exists but cannot be written to. This one is
  # a permission okf can ask about in advance, unlike a full disk, so asking is
  # the difference between a refusal and a bundle half-written before the
  # failure was discovered.
  assert_exit 0 "$okf" init --force
  printf '%s\n' '{"okf_version": "hand-edited"}' > okf.json
  if ! chmod 444 index.md; then
    _fail "index.md can be made read-only in the fixture" "chmod failed"
  elif [ -w index.md ]; then
    # Running as root, where the mode bits do not stop a write. Nothing here is
    # a result then, so record a skip rather than a pass that proved nothing.
    _skip "a read-only index.md is refused before okf.json is written" \
      "this user can write it anyway"
    chmod 644 index.md
  else
    assert_exit 1 "$okf" init --force
    out="$(last_output)"
    assert_eq 1 "$(_okf_line_count "$out")" \
      "a read-only target is reported in one line, not in two"
    assert_contains "$out" "index.md" "and that line names it"
    assert_eq '{"okf_version": "hand-edited"}' "$(cat okf.json)" \
      "and okf.json was not overwritten on the way to it"
    chmod 644 index.md
  fi

  # Two names for one file, which no comparison of the paths themselves can
  # see. Left alone, init writes okf.json's document and then the index
  # document on top of it, reports both as written and exits 0, and the bundle
  # ends up with no settings at all.
  rm -f index.md
  if ! ln okf.json index.md 2> /dev/null; then
    _skip "a hard-linked index.md is refused" "this filesystem has no hard links"
  else
    assert_exit 1 "$okf" init --force
    assert_contains "$(last_output)" "same file" \
      "okf init refuses two targets that are one file"
    assert_eq '{"okf_version": "hand-edited"}' "$(cat okf.json)" \
      "and neither document was written over the other"
    rm -f index.md
  fi
  return 0
}

# SPEC.md §4 reserves the repo-root index.md as the bundle root: type Codebase,
# and the only file in a bundle where okf_version is legal. §7 makes writing it
# `okf init`'s job, alongside okf.json.
test_okf_init_writes_the_bundle_root_index() {
  _okf_preconditions || return 1
  with_fixture_repo tiny _okf_init_index_probe
}

# The other half of the same PLAN.md item: an existing bundle-root index.md is
# not overwritten without --force.
test_okf_init_refuses_to_overwrite_the_index_without_force() {
  _okf_preconditions || return 1
  with_fixture_repo tiny _okf_init_index_force_probe
}

# What `okf list` prints in tests/fixtures/scoped, whose own okf.json is
# SPEC.md §6's defaults plus a `**/vendor/**` glob. Every other file in that
# tree is left out by one of SPEC.md §5's exclusion rules, and the fixture's
# README.md says which rule leaves out which file.
_OKF_SCOPED_LISTING='lib/conventions.py
lib/core.py
src/app.ts
src/generated/Handwritten.java
src/util/Accessors.java
src/util/helper.ts'

# Compares okf's stdout — not the stdout+stderr assert_exit records — against a
# whole expected listing. A listing is an ordered set, and a check that could
# only say "src/app.ts is in there somewhere" would pass a command that also
# printed the vendored tree.
_okf_assert_listing() { # $1 = expected listing, $2 = description, $3.. = okf arguments
  local expected="$1" what="$2"
  shift 2

  local stderr="$HARNESS_STATE/okf-list-stderr" actual rc
  actual="$("$TOOLKIT_ROOT/bin/okf" "$@" 2> "$stderr")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    local -a detail=("okf $* exited $rc" "stderr:")
    local line
    while IFS= read -r line; do detail+=("$line"); done \
      < <(_detail_lines "$(cat "$stderr" 2> /dev/null)")
    _fail "$what" "${detail[@]}"
    return 1
  fi
  assert_eq "$expected" "$actual" "$what"
}

# Runs okf and hands its stdout back in the named variable, having first checked
# that okf exited 0. An okf that failed prints nothing, and nothing is a listing
# every _okf_assert_not_listed passes against without having checked anything —
# the vacuous check this file's header warns about.
#
# Through a variable rather than a command substitution, because a _fail from in
# here would otherwise be captured as part of the listing instead of reported.
_okf_capture() { # $1 = variable to fill, $2.. = okf arguments
  local _var="$1"
  shift
  local _stderr="$HARNESS_STATE/okf-list-stderr" _out _rc
  _out="$("$TOOLKIT_ROOT/bin/okf" "$@" 2> "$_stderr")"
  _rc=$?
  if [ "$_rc" -ne 0 ]; then
    local -a _detail=("okf $* exited $_rc" "stderr:")
    local _line
    while IFS= read -r _line; do _detail+=("$_line"); done \
      < <(_detail_lines "$(cat "$_stderr" 2> /dev/null)")
    _fail "okf $* exits 0" "${_detail[@]}"
    return 1
  fi
  printf -v "$_var" '%s' "$_out"
  return 0
}

# Whole-line membership, not `assert_contains`: `src/util/helper.md` contains
# `src/util/helper.ts`'s stem, and a substring check would call the concept file
# listed whenever its source was.
_okf_assert_listed() { # $1 = listing, $2 = path, $3 = description
  local line
  while IFS= read -r line; do
    if [ "$line" = "$2" ]; then
      _pass "$3"
      return 0
    fi
  done <<< "$1"
  _fail "$3" "$2 is not in the listing"
  return 1
}

_okf_assert_not_listed() { # $1 = listing, $2 = path, $3 = description
  local line
  while IFS= read -r line; do
    if [ "$line" = "$2" ]; then
      _fail "$3" "$2 is in the listing"
      return 1
    fi
  done <<< "$1"
  _pass "$3"
  return 0
}

# SPEC.md §5's exclusion rules, each named on its own, so a listing that goes
# wrong says which rule stopped working rather than only that one did.
_okf_list_scope_probe() {
  local okf="$TOOLKIT_ROOT/bin/okf" listing probe

  # tests/fixtures/scoped carries its own .gitignore, which the *toolkit's*
  # repository obeys too: without a `git add -f`, the ignored fixture file is
  # never committed here, never copied into the fixture repo, and every check
  # below that it is not listed passes because there is nothing to list. A
  # check that cannot fail is worse than no check, so look for the file first.
  if [ -f src/ignored/secret.ts ]; then
    _pass "the fixture's gitignored source is present to be excluded"
  else
    _fail "the fixture's gitignored source is present to be excluded" \
      "no src/ignored/secret.ts under $PWD — it needs a git add -f in the toolkit repo"
    return 1
  fi
  assert_eq "" "$(git ls-files src/ignored 2> /dev/null)" \
    "and git does not track it, so git ls-files cannot see it"

  _okf_assert_listing "$_OKF_SCOPED_LISTING" \
    "okf list prints the fixture's in-scope sources" list || return 1

  listing="$("$okf" list 2> /dev/null)"

  _okf_assert_listed "$listing" src/app.ts "a source under an include glob is listed"
  _okf_assert_listed "$listing" lib/core.py "so is one under the second include glob"

  _okf_assert_not_listed "$listing" src/ignored/secret.ts \
    "a gitignored source is out of scope"
  _okf_assert_not_listed "$listing" src/target/Stale.java \
    "a build-output directory is out of scope"
  _okf_assert_not_listed "$listing" lib/vendor/pinned.py \
    "a vendored tree is out of scope"
  _okf_assert_not_listed "$listing" lib/node_modules/left-pad/index.js \
    "and so is node_modules"
  _okf_assert_not_listed "$listing" tools/build.js \
    "a source outside every include glob is out of scope"
  _okf_assert_not_listed "$listing" src/notes.md \
    "a file whose extension is not listed is out of scope"
  _okf_assert_not_listed "$listing" src/util/helper.md \
    "a concept file is not itself a source"
  _okf_assert_not_listed "$listing" src/data.json "and neither is a data file"

  # The one exclusion that has to read the file: a @Generated annotation on the
  # top-level type puts a source out of scope, while a sentence about one, and
  # one on a single member of a hand-written class, do not.
  _okf_assert_not_listed "$listing" src/generated/Api.java \
    "a source carrying a @Generated annotation is out of scope"
  _okf_assert_not_listed "$listing" src/generated/Ports.py \
    "and so is one carrying the # @generated header convention"
  _okf_assert_not_listed "$listing" src/generated/ping.go \
    "and Go's generated header, which that fixture writes with CRLF line endings"
  _okf_assert_not_listed "$listing" src/generated/config.js \
    "and the one-line /* @generated */ block comment"
  _okf_assert_listed "$listing" src/generated/Handwritten.java \
    "a source that only names @Generated in prose and in @NotGenerated stays in scope"
  _okf_assert_listed "$listing" src/util/Accessors.java \
    "so does one whose @Generated is on a member rather than on the type"
  _okf_assert_listed "$listing" lib/conventions.py \
    "and one whose docstring and comments open lines with @generated, as prose"

  # A tracked symlink is a second name for a file that already has a concept of
  # its own, so listing it would put two independently drifting concepts beside
  # one declared type.
  if ln -s app.ts src/alias.ts > /dev/null 2>&1 \
    && git add src/alias.ts > /dev/null 2>&1; then
    listing="$("$okf" list 2> /dev/null)"
    _okf_assert_not_listed "$listing" src/alias.ts \
      "a tracked symlink is not itself a source"
    _okf_assert_listed "$listing" src/app.ts "while the file it points at still is"
    git rm -q --cached src/alias.ts > /dev/null 2>&1
    rm -f src/alias.ts
  else
    _fail "a tracked symlink can be made in the fixture copy" "ln -s src/alias.ts failed"
  fi
  listing="$("$okf" list 2> /dev/null)"

  # git ls-files answers from the index, which still names a file deleted from
  # the working tree. Nothing downstream can read a path that is not there.
  rm -f lib/core.py
  _okf_capture probe list \
    && _okf_assert_not_listed "$probe" lib/core.py \
      "a source deleted from the working tree is not listed"
  if git checkout -- lib/core.py > /dev/null 2>&1; then
    _okf_capture probe list \
      && _okf_assert_listed "$probe" lib/core.py \
        "and is listed again once it is back"
  else
    _fail "the fixture copy restores a deleted file" "git checkout -- lib/core.py failed"
  fi

  # git's order is sorted, and nothing downstream should have to sort it again.
  assert_eq "$listing" "$("$okf" list 2> /dev/null)" \
    "okf list prints the same listing twice running"

  # Scope comes out of the index, so a file git has never been told about is
  # not yet part of what the repo says it is.
  printf 'export const fresh = 1;\n' > src/fresh.ts
  _okf_capture probe list \
    && _okf_assert_not_listed "$probe" src/fresh.ts \
      "a source git does not track is not listed"
  if git add src/fresh.ts > /dev/null 2>&1; then
    _okf_capture probe list \
      && _okf_assert_listed "$probe" src/fresh.ts \
        "and is listed once git has been told about it"
    git rm -q --cached src/fresh.ts > /dev/null 2>&1
  else
    _fail "the fixture copy accepts a git add" "git add src/fresh.ts failed"
  fi
  rm -f src/fresh.ts

  # -C moves the root every path resolves against, so the same listing comes
  # out of a run started somewhere else entirely.
  local elsewhere
  elsewhere="$(CDPATH= cd "$TOOLKIT_ROOT" && "$okf" -C "$FIXTURE_DIR" list 2> /dev/null)"
  assert_eq "$_OKF_SCOPED_LISTING" "$elsewhere" \
    "okf -C DIR list lists DIR's sources, whatever the caller's own directory"

  # git reads GIT_DIR and GIT_INDEX_FILE ahead of both -C and the directory it
  # is standing in, and git exports them to every hook it runs — which is where
  # SPEC.md §11 has bin/ralph refreshing concepts. Inherited, they would have
  # `git ls-files` answer for the toolkit's own repository, whose paths do not
  # exist under this root: an empty listing, exiting 0, saying nothing.
  local hooked
  hooked="$(env "GIT_DIR=$TOOLKIT_ROOT/.git" "GIT_INDEX_FILE=$TOOLKIT_ROOT/.git/index" \
    "$okf" -C "$FIXTURE_DIR" list 2> /dev/null)"
  assert_eq "$_OKF_SCOPED_LISTING" "$hooked" \
    "okf list answers for the root it was given, not for a GIT_DIR in the environment"
  return 0
}

# SPEC.md §6's include, exclude and extensions, each moved in turn. The fixture
# copy is a throwaway, so its okf.json can be rewritten between checks.
_okf_list_settings_probe() {
  # include narrows the listing. The exclude globs are restated because a
  # settings file that leaves a key out gets SPEC.md §6's default for it, and
  # §6's default exclude has no `**/vendor/**` in it.
  printf '%s\n' '{"bundle": {"include": ["lib/**"],
    "exclude": ["**/vendor/**", "**/node_modules/**"]}}' > okf.json
  _okf_assert_listing 'lib/conventions.py
lib/core.py' \
    "okf list honours a narrowed include" list

  # The same two files, reached by SPEC.md §4's bundle-absolute spelling and
  # with a trailing separator: `/lib/` and `lib/**` name one directory.
  printf '%s\n' '{"bundle": {"include": ["/lib/"],
    "exclude": ["**/vendor/**", "**/node_modules/**"]}}' > okf.json
  _okf_assert_listing 'lib/conventions.py
lib/core.py' \
    "okf list reads /lib/ as the same include as lib/**" list

  # Emptying exclude is what shows the exclusions were doing the work: the
  # build output, the vendored tree and node_modules all come back.
  printf '%s\n' '{"bundle": {"include": ["src/**", "lib/**"], "exclude": []}}' > okf.json
  _okf_assert_listing 'lib/conventions.py
lib/core.py
lib/node_modules/left-pad/index.js
lib/vendor/pinned.py
src/app.ts
src/generated/Handwritten.java
src/target/Stale.java
src/util/Accessors.java
src/util/helper.ts' \
    "okf list honours an emptied exclude" list

  # ...but not the gitignored one or the generated one, which no okf.json can
  # bring back.
  local listing
  listing="$("$TOOLKIT_ROOT/bin/okf" list 2> /dev/null)"
  _okf_assert_not_listed "$listing" src/ignored/secret.ts \
    "an emptied exclude does not un-ignore a gitignored source"
  _okf_assert_not_listed "$listing" src/generated/Api.java \
    "nor does it un-generate a @Generated source"

  # extensions decides what counts as a source at all.
  printf '%s\n' '{"bundle": {"include": ["src/**"], "exclude": [],
    "extensions": ["md"]}}' > okf.json
  _okf_assert_listing 'src/notes.md
src/util/helper.md' \
    "okf list honours a changed extensions list" list

  # An include list that narrows nothing leaves the rest of the repo in reach,
  # which is what puts tools/ — outside every default include — in the listing.
  printf '%s\n' '{"bundle": {"include": [],
    "exclude": ["**/target/**", "**/node_modules/**", "**/vendor/**"],
    "extensions": ["js"]}}' > okf.json
  _okf_assert_listing 'tools/build.js' \
    "okf list treats an empty include as no narrowing rather than no files" list

  # An exclude naming the bundle root excludes the bundle. Dropping such a
  # pattern as "narrows nothing" would be the right reading for include and the
  # exact opposite of it here.
  printf '%s\n' '{"bundle": {"include": [], "exclude": ["/"]}}' > okf.json
  _okf_assert_listing '' "an exclude of / excludes everything" list
  printf '%s\n' '{"bundle": {"include": ["."], "exclude": ["**/target/**",
    "**/node_modules/**", "**/vendor/**"], "extensions": ["js"]}}' > okf.json
  _okf_assert_listing 'tools/build.js' \
    "while an include of . is the whole bundle" list

  # SPEC.md §7 gives every subcommand --config PATH, and it is the settings it
  # moves, not the root: both runs below are of the same repo.
  printf '%s\n' '{"bundle": {"include": ["lib/**"],
    "exclude": ["**/vendor/**", "**/node_modules/**"]}}' > okf.ci.json
  printf '%s\n' '{"bundle": {"include": ["src/**"], "exclude": [],
    "extensions": ["ts"]}}' > okf.json
  _okf_assert_listing 'lib/conventions.py
lib/core.py' \
    "okf --config PATH list reads its settings from PATH" --config okf.ci.json list
  _okf_assert_listing 'src/app.ts
src/util/helper.ts' \
    "and the default okf.json still answers for a run without it" list
  rm -f okf.ci.json

  # SPEC.md §6: every field defaults if absent, so a repo that has never run
  # okf init is a repo using the defaults — whose exclude has no
  # `**/vendor/**`, which is exactly how the listing shows they are in use.
  rm -f okf.json
  _okf_assert_listing 'lib/conventions.py
lib/core.py
lib/vendor/pinned.py
src/app.ts
src/generated/Handwritten.java
src/util/Accessors.java
src/util/helper.ts' \
    "okf list falls back to SPEC.md §6's defaults when there is no okf.json" list
  return 0
}

# What `okf list --missing` prints in tests/fixtures/scoped: the in-scope
# listing minus src/util/helper.ts, the one source the fixture ships a
# co-located concept for.
_OKF_SCOPED_MISSING='lib/conventions.py
lib/core.py
src/app.ts
src/generated/Handwritten.java
src/util/Accessors.java'

# SPEC.md §5's co-location rule, read backwards: which in-scope sources have no
# concept beside them. The fixture copy is a throwaway, so concepts can be
# written into it and taken back out again between checks.
_okf_list_missing_probe() {
  local listing

  # The fixture's one concept has to be there for any of this to mean anything:
  # without it every check below would be comparing --missing against the whole
  # listing, and a --missing that filtered nothing would pass them all.
  if [ -f src/util/helper.md ]; then
    _pass "the fixture ships a co-located concept to be filtered out"
  else
    _fail "the fixture ships a co-located concept to be filtered out" \
      "no src/util/helper.md under $PWD"
    return 1
  fi

  _okf_assert_listing "$_OKF_SCOPED_MISSING" \
    "okf list --missing prints the in-scope sources with no concept beside them" \
    list --missing || return 1

  _okf_capture listing list --missing || return 1
  _okf_assert_not_listed "$listing" src/util/helper.ts \
    "a source whose sibling .md exists is not missing"
  _okf_capture listing list || return 1
  _okf_assert_listed "$listing" src/util/helper.ts \
    "while plain okf list still prints it"

  # A concept written but not yet committed still counts: /okf-generate writes
  # concepts into the working tree, and `okf list --missing` straight after is
  # how what is left gets seen.
  printf -- '---\ntype: Module\nresource: /src/app.ts\n---\n' > src/app.md
  _okf_capture listing list --missing || return 1
  _okf_assert_not_listed "$listing" src/app.ts \
    "a concept git has not been told about still counts"

  # A file that is not frontmatter is not a concept: a README beside a source of
  # the same name is prose, and an /okf-generate interrupted between creating
  # the file and writing its frontmatter leaves an empty one. Counting either
  # would take the source off this list for good, including out of the re-run
  # that is how the interrupted write gets finished.
  : > src/app.md
  _okf_capture listing list --missing || return 1
  _okf_assert_listed "$listing" src/app.ts \
    "an empty .md is not a concept"
  printf 'Notes about the app. No frontmatter, so not a concept.\n' > src/app.md
  _okf_capture listing list --missing || return 1
  _okf_assert_listed "$listing" src/app.ts \
    "nor is a markdown file that never opens with ---"
  printf -- '---\ntype: Modu' > src/app.md
  _okf_capture listing list --missing || return 1
  _okf_assert_listed "$listing" src/app.ts \
    "nor is one that opens a frontmatter block and never closes it"
  printf -- '---\r\ntype: Module\r\n---\r\n' > src/app.md
  _okf_capture listing list --missing || return 1
  _okf_assert_not_listed "$listing" src/app.ts \
    "while a concept checked out with CRLF line endings still is one"
  printf -- '\357\273\277---\ntype: Module\n---\n' > src/app.md
  _okf_capture listing list --missing || return 1
  _okf_assert_not_listed "$listing" src/app.ts \
    "and so is one an editor on Windows opened with a UTF-8 BOM"
  printf -- '---\ntype: Module\nresource: /src/app.ts\n---\n' > src/app.md

  # Co-located means the same directory. The same name one directory up, or in
  # a sibling directory, is a different concept for a different source.
  printf -- '---\ntype: Module\n---\n' > app.md
  printf -- '---\ntype: Module\n---\n' > src/util/app.md
  rm -f src/app.md
  _okf_capture listing list --missing || return 1
  _okf_assert_listed "$listing" src/app.ts \
    "a concept in another directory does not cover src/app.ts"
  rm -f app.md src/util/app.md

  # The stem is the name minus its final extension: Accessors.java is covered by
  # Accessors.md and not by Accessors.java.md.
  printf -- '---\ntype: Class\n---\n' > src/util/Accessors.java.md
  _okf_capture listing list --missing || return 1
  _okf_assert_listed "$listing" src/util/Accessors.java \
    "a <name>.<ext>.md does not cover <name>.<ext>"
  rm -f src/util/Accessors.java.md
  printf -- '---\ntype: Class\n---\n' > src/util/Accessors.md
  _okf_capture listing list --missing || return 1
  _okf_assert_not_listed "$listing" src/util/Accessors.java \
    "while the sibling <name>.md does"
  rm -f src/util/Accessors.md

  # A directory is not a concept file, and neither is a symlink pointing at
  # nothing or a file whose permissions have been taken away. Counted as one,
  # each would mark a source documented that no reader could read a word of.
  #
  # Every one of them is checked against a concept that does work in the same
  # place first: lib/core.py and lib/conventions.py have no concept either way,
  # so without the positive these would all pass on a has_concept that never
  # looked at the sibling at all.
  printf -- '---\ntype: Module\n---\n' > lib/core.md
  _okf_capture listing list --missing || return 1
  _okf_assert_not_listed "$listing" lib/core.py \
    "lib/core.py is covered while a readable lib/core.md is there"
  if chmod 000 lib/core.md > /dev/null 2>&1 && [ ! -r lib/core.md ]; then
    _okf_capture listing list --missing \
      && _okf_assert_listed "$listing" lib/core.py \
        "but a concept that cannot be read is not one okf may count"
    assert_eq "" "$(cat "$HARNESS_STATE/okf-list-stderr" 2> /dev/null)" \
      "and okf says nothing on stderr about it, having answered on stdout"
  else
    # root reads anything, so the check cannot be made to hold there.
    _skip "a concept that cannot be read is not one okf may count" \
      "chmod 000 does not make a file unreadable here"
  fi
  chmod 644 lib/core.md > /dev/null 2>&1
  rm -f lib/core.md
  if mkdir lib/core.md > /dev/null 2>&1; then
    _okf_capture listing list --missing \
      && _okf_assert_listed "$listing" lib/core.py \
        "nor is a directory named like the concept"
    rmdir lib/core.md
  else
    _fail "a directory can be made in the fixture copy" "mkdir lib/core.md failed"
  fi

  printf -- '---\ntype: Module\n---\n' > lib/conventions.md
  _okf_capture listing list --missing || return 1
  _okf_assert_not_listed "$listing" lib/conventions.py \
    "lib/conventions.py is covered while a real lib/conventions.md is there"
  rm -f lib/conventions.md
  if ln -s nowhere.md lib/conventions.md > /dev/null 2>&1; then
    _okf_capture listing list --missing \
      && _okf_assert_listed "$listing" lib/conventions.py \
        "but a symlink pointing at nothing is not a concept either"
    rm -f lib/conventions.md
  else
    _fail "a symlink can be made in the fixture copy" "ln -s lib/conventions.md failed"
  fi

  # SPEC.md §4 reserves index.md for the directory's own Package document, so a
  # source named index.<ext> has no <stem>.md of its own to be found. Counting
  # the directory's would have `okf index` mark every such source documented
  # without writing a word about it — a source dropped from the bundle in
  # silence, which is the one failure mode worth being noisy to avoid.
  mkdir -p src/pkg
  printf 'export const port = 1;\n' > src/pkg/index.ts
  printf 'export const other = 1;\n' > src/pkg/index.spec.ts
  if git add src/pkg/index.ts src/pkg/index.spec.ts > /dev/null 2>&1; then
    _okf_capture listing list --missing \
      && _okf_assert_listed "$listing" src/pkg/index.ts \
        "a source named index.ts starts out missing like any other"
    printf -- '---\ntype: Package\n---\n' > src/pkg/index.md
    _okf_capture listing list --missing \
      && _okf_assert_listed "$listing" src/pkg/index.ts \
        "and the directory's own index.md does not cover it"

    # index.spec.md is index.spec.ts's own concept. Read as an index.<TypeName>
    # spelling for index.ts it would take index.ts off this list the moment its
    # neighbour was documented, and nothing would ever put it back.
    printf -- '---\ntype: Module\nresource: /src/pkg/index.spec.ts\n---\n' \
      > src/pkg/index.spec.md
    if _okf_capture listing list --missing; then
      _okf_assert_listed "$listing" src/pkg/index.ts \
        "nor does a sibling source's concept that happens to start with index."
      _okf_assert_not_listed "$listing" src/pkg/index.spec.ts \
        "while that sibling itself is covered by it"
    fi

    # The same file under two names is still the directory's own document, and
    # a hard link is the one spelling of that a string compare cannot see —
    # the same blind spot a case-insensitive filesystem opens up for `Index.md`
    # beside `index.md`, which is not reproducible here.
    rm -f src/pkg/index.spec.md
    if ln src/pkg/index.md src/pkg/index.spec.md > /dev/null 2>&1; then
      _okf_capture listing list --missing \
        && _okf_assert_listed "$listing" src/pkg/index.spec.ts \
          "a hard link to the directory's index.md is not a concept either"
    else
      _fail "a hard link can be made in the fixture copy" "ln src/pkg/index.md failed"
    fi
    git rm -q --cached src/pkg/index.ts src/pkg/index.spec.ts > /dev/null 2>&1
  else
    _fail "the fixture copy accepts a git add" "git add src/pkg failed"
  fi
  rm -rf src/pkg

  # bundle.extensions decides what counts as a source, and nothing stops it
  # naming md. A markdown source derives its own name — notes.md has a stem of
  # notes — so without a check that the concept and the source are two files,
  # every one of them would mark itself documented and drop out of the listing
  # /okf-generate walks.
  printf '%s\n' '{"bundle": {"include": ["src/**"], "exclude": [],
    "extensions": ["md"]}}' > okf.json
  _okf_assert_listing 'src/notes.md
src/util/helper.md' \
    "a markdown source is not its own concept" list --missing

  # --missing narrows the listing, so everything that decides the listing still
  # decides this one: a source no include glob reaches has no concept either and
  # is still not printed.
  printf '%s\n' '{"bundle": {"include": ["lib/**"],
    "exclude": ["**/vendor/**", "**/node_modules/**"]}}' > okf.json
  _okf_assert_listing 'lib/conventions.py
lib/core.py' \
    "okf list --missing honours the bundle settings" list --missing

  # Every in-scope source documented is an empty listing exiting 0, not an
  # error: nothing missing is the outcome /okf-generate is driving towards.
  printf '%s\n' '{"bundle": {"include": ["src/util/**"], "exclude": []}}' > okf.json
  _okf_assert_listing 'src/util/Accessors.java' \
    "a narrowed scope leaves only its own undocumented sources" list --missing
  printf -- '---\ntype: Class\n---\n' > src/util/Accessors.md
  _okf_assert_listing '' \
    "and a scope with a concept for every source prints nothing, exiting 0" \
    list --missing
  rm -f src/util/Accessors.md okf.json
  return 0
}

# Stages a concept file so `git ls-files` sees it, since the orphan listing is
# over what the repo has put under version control. `git add` and not a commit:
# the index is what git ls-files reads, and a commit would only make each of
# these slower.
_okf_stage() { # $1.. = paths
  if ! git add -- "$@" > /dev/null 2>&1; then
    _fail "the fixture copy accepts a git add" "git add $* failed"
    return 1
  fi
  return 0
}

# SPEC.md §5's co-location read the other way round from --missing: not a source
# with no concept beside it, but a concept whose `resource` names a file that is
# not there any more.
_okf_list_orphans_probe() {
  local listing

  # The fixture's one concept, src/util/helper.md, has `resource:
  # /src/util/helper.ts` and that source is there — so nothing is orphaned. An
  # empty listing exiting 0, not an error: a bundle with no orphans in it is the
  # ordinary state, and the same run has to be able to say so.
  #
  # It is also the check that a markdown file which is not a concept stays off
  # this listing: the fixture carries README.md and src/notes.md, neither with
  # frontmatter and neither naming any file that exists. Counted as concepts,
  # both would be on a listing whose whole use is naming files to delete.
  _okf_assert_listing '' \
    "a bundle whose concepts all still have their sources prints nothing, exiting 0" \
    list --orphans

  # The orphan itself. Deleted from the working tree and not staged as removed,
  # which is what a source being deleted looks like at the moment it happens:
  # git ls-files still names it, so the answer has to come from the filesystem.
  rm -f src/util/helper.ts
  _okf_assert_listing 'src/util/helper.md' \
    "a concept whose resource has been deleted is an orphan" list --orphans
  git checkout -q -- src/util/helper.ts > /dev/null 2>&1
  _okf_assert_listing '' "and stops being one when its resource comes back" \
    list --orphans

  # --orphans lists concepts, and the sources --missing lists are exactly what
  # must not turn up here. src/util/Accessors.java has no concept at all, so it
  # is on the --missing listing and belongs on neither half of this one.
  _okf_capture listing list --missing || return 1
  _okf_assert_listed "$listing" src/util/Accessors.java \
    "an undocumented source is on the --missing listing"
  _okf_capture listing list --orphans || return 1
  _okf_assert_not_listed "$listing" src/util/Accessors.java \
    "and never on the --orphans one, which lists concepts and not sources"

  # A concept that declares no resource is not an orphan. okf has not been told
  # what it documents, so it cannot have found out that thing is gone — and this
  # is a listing acted on by deleting files, where a wrong name costs a concept
  # somebody wrote and a missing one costs a stale file that stays.
  printf -- '---\ntype: Class\ntitle: Nameless\n---\n' > src/util/Nameless.md
  _okf_stage src/util/Nameless.md || return 1
  _okf_assert_listing '' "a concept that names no resource is not an orphan" \
    list --orphans
  printf -- '---\ntype: Class\nresource:\n---\n' > src/util/Nameless.md
  _okf_assert_listing '' "nor is one whose resource is empty" list --orphans

  # A resource that never existed is as gone as one that was deleted: what is
  # asked is whether the file is there, not what became of it.
  printf -- '---\ntype: Class\nresource: /src/util/Nameless.java\n---\n' \
    > src/util/Nameless.md
  _okf_assert_listing 'src/util/Nameless.md' \
    "a concept whose resource was never there is an orphan too" list --orphans

  # SPEC.md §4 puts path-valued fields in bundle-absolute form — a leading `/`
  # that means the bundle root and not the filesystem's. Read as a filesystem
  # path, /src/util/helper.ts is a file on nobody's machine and every concept in
  # every bundle would be an orphan.
  printf -- '---\ntype: Class\nresource: /src/util/Accessors.java\n---\n' \
    > src/util/Nameless.md
  _okf_assert_listing '' \
    "a bundle-absolute resource is resolved against the bundle root" list --orphans
  # The same path without the leading slash names the same file, so it is read
  # the same way rather than refused: §4's form is a recommendation about
  # surviving file moves, not a gate on being understood.
  printf -- '---\ntype: Class\nresource: src/util/Accessors.java\n---\n' \
    > src/util/Nameless.md
  _okf_assert_listing '' "so is one written without the leading slash" list --orphans
  printf -- '---\ntype: Class\nresource: src/util/Gone.java\n---\n' \
    > src/util/Nameless.md
  _okf_assert_listing 'src/util/Nameless.md' \
    "and a missing one is still found without it" list --orphans

  # SPEC.md §4's example writes some values quoted. Both directions again: a
  # quote left on the front of the path takes the value out of the concept's own
  # directory, so a reader that does not strip them reports nothing at all — and
  # nothing is what a bundle with no orphans in it also prints.
  printf -- '---\ntype: Class\nresource: "/src/util/Accessors.java"\n---\n' \
    > src/util/Nameless.md
  _okf_assert_listing '' "a quoted resource has its quotes taken off" list --orphans
  printf -- '---\ntype: Class\nresource: "/src/util/Gone.java"\n---\n' \
    > src/util/Nameless.md
  _okf_assert_listing 'src/util/Nameless.md' \
    "and a quoted one that is gone is still found" list --orphans
  printf -- "---\ntype: Class\nresource: '/src/util/Accessors.java'\n---\n" \
    > src/util/Nameless.md
  _okf_assert_listing '' "single quotes as well as double" list --orphans
  printf -- "---\ntype: Class\nresource: '/src/util/Gone.java'\n---\n" \
    > src/util/Nameless.md
  _okf_assert_listing 'src/util/Nameless.md' "in that direction too" list --orphans

  # SPEC.md §4 is explicit that `sources` holds external references — tickets,
  # RFCs — and is never a restatement of `resource`. Its entries are indented
  # list items, and a reader that took one for the concept's own resource would
  # be testing a URL for being a file.
  printf -- '---\ntype: Class\nsources:\n  - resource: https://example.invalid/DON-86\n    id: don-86\n---\n' \
    > src/util/Nameless.md
  _okf_assert_listing '' \
    "a resource inside the sources list is not the concept's own" list --orphans
  printf -- '---\ntype: Class\nsources:\n  - resource: https://example.invalid/DON-86\nresource: /src/util/Gone.java\n---\n' \
    > src/util/Nameless.md
  _okf_assert_listing 'src/util/Nameless.md' \
    "and the unindented one is still read past it" list --orphans

  # Two top-level `resource:` lines is malformed YAML with no defined meaning.
  # The first wins — the same rule SPEC.md §4's extraction rule for `code.X`
  # states — because it is the only answer that does not depend on how far past
  # the mistake the reader kept going.
  printf -- '---\ntype: Class\nresource: /src/util/Gone.java\nresource: /src/util/Accessors.java\n---\n' \
    > src/util/Nameless.md
  _okf_assert_listing 'src/util/Nameless.md' \
    "the first of two resource lines is the one read" list --orphans

  # Whitespace around the value comes off. A path with a space still on the end
  # of it exists nowhere, so a live concept would be reported dead.
  printf -- '---\ntype: Class\nresource:   /src/util/Accessors.java   \n---\n' \
    > src/util/Nameless.md
  _okf_assert_listing '' "the value is read without the whitespace around it" \
    list --orphans

  # A checkout with CRLF line endings and an editor on Windows change how the
  # lines are spelled, not what they say. Both directions are checked here, and
  # deliberately: a reader that does not know the spelling recognises no
  # frontmatter, reads no resource, and reports no orphan — which passes any
  # check that only ever expects an empty listing.
  printf -- '---\r\ntype: Class\r\nresource: /src/util/Accessors.java\r\n---\r\n' \
    > src/util/Nameless.md
  _okf_assert_listing '' "a concept checked out with CRLF endings is read" list --orphans
  printf -- '---\r\ntype: Class\r\nresource: /src/util/Gone.java\r\n---\r\n' \
    > src/util/Nameless.md
  _okf_assert_listing 'src/util/Nameless.md' \
    "and its orphan is found, not passed over as unreadable" list --orphans
  printf -- '\357\273\277---\ntype: Class\nresource: /src/util/Accessors.java\n---\n' \
    > src/util/Nameless.md
  _okf_assert_listing '' "and so is one opened with a UTF-8 BOM" list --orphans
  printf -- '\357\273\277---\ntype: Class\nresource: /src/util/Gone.java\n---\n' \
    > src/util/Nameless.md
  _okf_assert_listing 'src/util/Nameless.md' "whose orphan is found too" list --orphans

  # Only the frontmatter block is read, and the block ends at the closing `---`.
  # A `resource:` line in the body is prose about the concept — a worked example,
  # a quoted fragment — and not the concept's own field.
  printf -- '---\ntype: Class\n---\n\nresource: /src/util/Gone.java\n' \
    > src/util/Nameless.md
  _okf_assert_listing '' "a resource line in the body is not frontmatter" list --orphans
  # And the frontmatter's own is what answers when there is one of each.
  printf -- '---\ntype: Class\nresource: /src/util/Accessors.java\n---\n\nresource: /src/util/Gone.java\n' \
    > src/util/Nameless.md
  _okf_assert_listing '' "the frontmatter's resource is the one that answers" \
    list --orphans

  # A file that opens a frontmatter block and never closes it is the half-written
  # concept has_frontmatter exists to tell from a whole one. Counted here it
  # would be an orphan, and the fix — finishing the write — is the one thing a
  # caller who deleted it can no longer do.
  printf -- '---\ntype: Class\nresource: /src/util/Gone.java\n' > src/util/Nameless.md
  _okf_assert_listing '' \
    "a half-written concept is not a concept, so not an orphan" list --orphans
  rm -f src/util/Nameless.md
  git rm -q --cached src/util/Nameless.md > /dev/null 2>&1

  # SPEC.md §4 reserves index.md for the directory's own Package document and
  # leaves log.md to OKF. Neither is any source's concept, so neither can be
  # orphaned by a source going away — whatever is written in it.
  local reserved
  for reserved in index.md log.md; do
    printf -- '---\ntype: Package\nresource: /src/util/Gone.java\n---\n' \
      > "src/util/$reserved"
    _okf_stage "src/util/$reserved" || return 1
    _okf_assert_listing '' "src/util/$reserved is a reserved name, never an orphan" \
      list --orphans
    rm -f "src/util/$reserved"
    git rm -q --cached "src/util/$reserved" > /dev/null 2>&1
  done

  # SPEC.md §5 co-locates a concept as `<stem>.md`, so a concept is a markdown
  # file and nothing else. A source that happens to open with a `---` block —
  # a language where that is a legal first line, a file with an editor's own
  # header on it — is still a source, and reading it as a concept would put a
  # file the bundle is meant to document on the list of files to delete.
  printf -- '---\ntype: Class\nresource: /src/gone.ts\n---\nexport const x = 1;\n' \
    > src/frontmatter.ts
  _okf_stage src/frontmatter.ts || return 1
  _okf_assert_listing '' "a source is not a concept, whatever it opens with" \
    list --orphans
  rm -f src/frontmatter.ts
  git rm -q --cached src/frontmatter.ts > /dev/null 2>&1

  # A concept written and never committed is not in the bundle yet. Scope is
  # read out of git — the same reading that keeps gitignored files off `okf
  # list` — so a stray .md in the working tree is not something okf answers for.
  printf -- '---\ntype: Class\nresource: /src/util/Gone.java\n---\n' \
    > src/util/Untracked.md
  _okf_assert_listing '' "an untracked concept is not in the bundle" list --orphans
  _okf_stage src/util/Untracked.md || return 1
  _okf_assert_listing 'src/util/Untracked.md' "and is once it is staged" list --orphans

  # The concept's own deletion, the other way the pair can be broken. git
  # ls-files still names it; there is no file to read a resource out of, and
  # nothing left to report.
  rm -f src/util/Untracked.md
  _okf_assert_listing '' "a concept deleted from the working tree is not listed" \
    list --orphans
  git rm -q --cached src/util/Untracked.md > /dev/null 2>&1

  # A concept is the bundle's when the source it names is, so `include` and
  # `exclude` are asked of the resource. A vendored tree and a directory outside
  # every include glob are out of scope for `okf list`, and a concept naming a
  # file in one of them is out of scope here for the same reason.
  printf -- '---\ntype: Module\nresource: /lib/vendor/gone.py\n---\n' \
    > lib/vendor/pinned.md
  printf -- '---\ntype: Module\nresource: /tools/gone.js\n---\n' > tools/build.md
  _okf_stage lib/vendor/pinned.md tools/build.md || return 1
  _okf_assert_listing '' \
    "an excluded resource and one outside include contribute no orphans" \
    list --orphans
  rm -f lib/vendor/pinned.md tools/build.md
  git rm -q --cached lib/vendor/pinned.md tools/build.md > /dev/null 2>&1

  # SPEC.md §5 co-locates a concept beside its source, so a resource naming a
  # file in some other directory is not one this concept documents. The
  # directory is as much as can be checked — §5's `<stem>.<TypeName>.md` gives
  # additional types a filename no source ever has — and it is the part that
  # matters.
  printf -- '---\ntype: Module\nresource: /src/gone.ts\n---\n' > src/util/away.md
  _okf_stage src/util/away.md || return 1
  _okf_assert_listing '' \
    "a resource in another directory is not the concept's own source" list --orphans
  printf -- '---\ntype: Module\nresource: /src/util/gone.ts\n---\n' > src/util/away.md
  _okf_assert_listing 'src/util/away.md' \
    "while the same name beside it is, and is an orphan" list --orphans
  rm -f src/util/away.md
  git rm -q --cached src/util/away.md > /dev/null 2>&1

  # What co-location is really guarding is the bundle boundary. A nested
  # repository with its own okf.json is its own bundle, and its concepts write
  # `resource` bundle-absolute against *its* root: read from out here,
  # /src/pkg/Thing.java is a file that was never in this repository. Without §5
  # to tell the two apart, every concept a vendored bundle has would be on this
  # listing — and this listing is acted on by deleting files.
  #
  # The include glob is widened to `**` for this one, so that what keeps the
  # nested concept off the listing is demonstrably co-location and not a glob
  # that never reached it.
  mkdir -p nested/src/pkg
  printf '{}\n' > nested/okf.json
  printf 'class Thing {}\n' > nested/src/pkg/Thing.java
  printf -- '---\ntype: Class\nresource: /src/pkg/Thing.java\n---\n' \
    > nested/src/pkg/Thing.md
  printf '%s\n' '{"bundle": {"include": ["**"], "exclude": []}}' > okf.json
  _okf_stage nested/okf.json nested/src/pkg/Thing.java nested/src/pkg/Thing.md \
    || return 1
  _okf_assert_listing '' \
    "a nested bundle's concepts are not this bundle's orphans" list --orphans
  rm -rf nested
  rm -f okf.json
  git rm -q -r --cached nested > /dev/null 2>&1

  # A concept at the bundle root that declares an empty resource is the one
  # place where "names no source" and "names a source beside it" are the same
  # string: the root's directory part is empty, and so is the value. Everywhere
  # else co-location throws such a concept out on its own; here it would fall
  # through to the existence test and be reported, putting a document at the top
  # of the bundle on a listing of files to delete.
  printf -- '---\ntype: Class\nresource:\n---\n' > Rootless.md
  printf '%s\n' '{"bundle": {"include": ["**"], "exclude": []}}' > okf.json
  _okf_stage Rootless.md || return 1
  _okf_assert_listing '' \
    "a root concept with an empty resource is not an orphan" list --orphans
  rm -f Rootless.md okf.json
  git rm -q --cached Rootless.md > /dev/null 2>&1

  # An include glob shaped by extension rather than by directory matches no .md
  # anywhere in the repository. Asked of the concept's own path it would empty
  # this listing and exit 0 — a repo full of orphans reported as having none,
  # which is the one answer a listing of leftovers must never give.
  printf '%s\n' '{"bundle": {"include": ["src/**/*.ts"], "exclude": []}}' > okf.json
  rm -f src/util/helper.ts
  _okf_assert_listing 'src/util/helper.md' \
    "an include glob written by extension still finds its orphans" list --orphans
  rm -f okf.json

  # `extensions` is the one bundle setting that does not reach this listing: it
  # says what kind of file gets documented, and a concept that exists is
  # evidence one already was. Narrowing it to java today cannot make yesterday's
  # TypeScript concept stop being a leftover when its source goes.
  printf '%s\n' '{"bundle": {"include": ["src/**", "lib/**"],
    "exclude": ["**/vendor/**", "**/node_modules/**"], "extensions": ["java"]}}' \
    > okf.json
  _okf_assert_listing 'src/util/helper.md' \
    "extensions names what is a source, and does not gate concepts" list --orphans
  rm -f okf.json
  git checkout -q -- src/util/helper.ts > /dev/null 2>&1

  # Two orphans come out in the order the bundle holds them — git's — which is
  # the order plain `okf list` prints and the order --missing keeps.
  printf -- '---\ntype: Module\nresource: /src/app.ts\n---\n' > src/app.md
  printf -- '---\ntype: Module\nresource: /lib/core.py\n---\n' > lib/core.md
  _okf_stage src/app.md lib/core.md || return 1
  rm -f src/app.ts lib/core.py
  _okf_assert_listing 'lib/core.md
src/app.md' \
    "several orphans come out in the order the bundle holds them" list --orphans

  # A resource that is there but is not a file — a directory left where one was
  # — is a resource that has not gone away. What okf can say is that something
  # is at that path; what it is belongs to the drift check, not to this listing.
  mkdir -p src/app.ts
  _okf_assert_listing 'lib/core.md' \
    "a resource that exists as a directory is not gone" list --orphans
  rmdir src/app.ts
  rm -f src/app.md lib/core.md
  git rm -q --cached src/app.md lib/core.md > /dev/null 2>&1
  git checkout -q -- src/app.ts lib/core.py > /dev/null 2>&1
  return 0
}

# The refusals: a line okf cannot act on is answered, not guessed at.
_okf_list_refusal_probe() {
  local okf="$TOOLKIT_ROOT/bin/okf"

  assert_exit 1 "$okf" list --bogus
  assert_contains "$(last_output)" "unknown flag: --bogus" \
    "okf list names a flag it does not know"
  assert_exit 1 "$okf" list extra
  assert_contains "$(last_output)" "extra" "okf list names an argument it does not take"

  # --missing narrows the source listing and --orphans replaces it with a
  # listing of concepts, so no listing answers both. Ranking one over the other
  # would hand back paths of the wrong kind to a caller with no way to see which
  # flag was dropped — `okf list --missing --orphans | xargs rm` on the sources.
  # The refusal has to come out whichever order they are typed in, and it has to
  # name both flags, or it reads as a complaint about only one of them.
  assert_exit 1 "$okf" list --missing --orphans
  assert_contains "$(last_output)" "--orphans" \
    "okf list refuses --missing and --orphans together"
  assert_contains "$(last_output)" "--missing" \
    "and names the other flag as well as the one it stopped on"
  assert_exit 1 "$okf" list --orphans --missing
  assert_contains "$(last_output)" "--orphans" "the refusal holds in the other order"
  assert_contains "$(last_output)" "--missing" "and still names both flags there"

  printf 'not json at all\n' > okf.json
  assert_exit 1 "$okf" list
  assert_contains "$(last_output)" "okf.json" "an unparseable okf.json is named"

  : > okf.json
  assert_exit 1 "$okf" list
  assert_contains "$(last_output)" "okf.json" "so is an empty one"

  printf '%s\n' '{"bundle": {"include": "src/**"}}' > okf.json
  assert_exit 1 "$okf" list
  assert_contains "$(last_output)" ".bundle.include" \
    "a setting of the wrong shape is named by its key"

  # --orphans reads the same settings and has to refuse the same file. It gets
  # there by a different route — the concepts are gathered before the globs are
  # compiled — and a route that skipped the compile would answer an unusable
  # okf.json with a listing built from no include at all.
  assert_exit 1 "$okf" list --orphans
  assert_contains "$(last_output)" ".bundle.include" \
    "okf list --orphans refuses the same settings okf list does"

  # The gitignore constructs okf's globs have not got are refused by name, like
  # every other setting okf cannot act on. Escaped into literals instead, a
  # `[Gg]` would be an exclude that excluded nothing and said nothing about it.
  printf '%s\n' '{"bundle": {"exclude": ["src/[Gg]enerated/**"]}}' > okf.json
  assert_exit 1 "$okf" list
  assert_contains "$(last_output)" ".bundle.exclude" \
    "a character class in a glob is refused rather than read as a literal"
  printf '%s\n' '{"bundle": {"exclude": ["!src/app.ts"]}}' > okf.json
  assert_exit 1 "$okf" list
  assert_contains "$(last_output)" "negation" \
    "so is gitignore's ! negation, which okf does not implement"

  # A glob that reaches outside the bundle can only ever match nothing, and an
  # include matching nothing is an empty listing exiting 0 — a repo with no
  # sources and a repo whose include is unusable, told apart by neither.
  printf '%s\n' '{"bundle": {"include": ["../shared/**"]}}' > okf.json
  assert_exit 1 "$okf" list
  assert_contains "$(last_output)" ".bundle.include" \
    "a glob with a .. segment is refused rather than left to match nothing"

  # An empty string is not a glob. Dropped as unusable it would leave no include
  # patterns at all, which reads as no narrowing — the whole repository in
  # scope, for a setting nobody could act on.
  printf '%s\n' '{"bundle": {"include": [""]}}' > okf.json
  assert_exit 1 "$okf" list
  assert_contains "$(last_output)" ".bundle.include" \
    "an empty glob is refused rather than dropped into a repo-wide scope"

  # A null is the one wrong shape that could pass for something: SPEC.md §6's
  # defaults are merged underneath, and a null written over one of them would
  # otherwise read as an empty list — putting the whole build directory in scope
  # without a word about it. An exclude list of nothing is spelled [].
  printf '%s\n' '{"bundle": {"exclude": null}}' > okf.json
  assert_exit 1 "$okf" list
  assert_contains "$(last_output)" ".bundle.exclude" \
    "a null written over a default is refused, not read as an empty list"

  # A scan that did not happen looks exactly like a repo with no generated code:
  # ripgrep prints nothing either way. Said rather than acted on, because acting
  # on it would put every generated file in the bundle without a word. Driven by
  # a stand-in ripgrep that fails the way the real one does, since there is no
  # way to make a working ripgrep fail on demand.
  # A settings file that is fine, so the run below gets as far as the scan
  # rather than stopping on the last check's deliberately broken one.
  rm -f okf.json
  local fakebin
  if ! fakebin="$(mktemp -d "${TMPDIR:-/tmp}/toolkit-fakerg.XXXXXX")"; then
    _fail "a stand-in ripgrep can be made" "mktemp -d failed"
  else
    printf '%s\n' "$fakebin" >> "$HARNESS_STATE/fixture_dirs"
    printf '#!/bin/sh\nprintf "rg: broken\\n" >&2\nexit 2\n' > "$fakebin/rg"
    if ! chmod +x "$fakebin/rg"; then
      _fail "a stand-in ripgrep can be made" "chmod +x failed: $fakebin/rg"
    else
      assert_exit 1 env "PATH=$fakebin:$PATH" "$okf" list
      assert_contains "$(last_output)" "ripgrep" \
        "a failed generated-source scan is reported, not read as no generated code"
    fi
    rm -rf "$fakebin"
  fi

  # SPEC.md §6 gives bundle.root a default of `.` and nothing in okf acts on any
  # other value. A setting written down and then ignored is a caller who has
  # said where their bundle is and been overruled in silence, so it is refused
  # while the default still passes.
  printf '%s\n' '{"bundle": {"root": "src"}}' > okf.json
  assert_exit 1 "$okf" list
  assert_contains "$(last_output)" "bundle.root" \
    "a bundle.root okf does not act on is refused rather than ignored"
  printf '%s\n' '{"bundle": {"root": "."}}' > okf.json
  assert_exit 0 "$okf" list

  # A --config naming a file that is not there is a typo, while no okf.json at
  # all is SPEC.md §6's defaults. The two must not be answered the same way.
  rm -f okf.json
  assert_exit 1 "$okf" --config nowhere.json list
  assert_contains "$(last_output)" "nowhere.json" \
    "a --config that names nothing is refused"
  assert_exit 0 "$okf" list
  return 0
}

# Runs bin/okf's own glob matcher over a table of cases, one process for the
# whole table. bin/okf is sourced rather than run, because what is being checked
# here is a dialect and not a subcommand — `okf list` can only show that a whole
# listing came out right, which says nothing about which rule of the dialect was
# the one that decided it.
_okf_glob_verdicts() { # $1.. = alternating glob and path
  local probe="$HARNESS_STATE/okf-glob-probe.sh"
  if [ ! -f "$probe" ]; then
    cat > "$probe" <<'PROBE'
#!/usr/bin/env bash
okf_script="$1"
shift
# shellcheck source=/dev/null
. "$okf_script"
while [ $# -gt 1 ]; do
  pattern="$(bundle_pattern "$1")"
  expression="$(glob_regex "$pattern")"
  if matches_any "$2" "$expression"; then
    printf '%s vs %s: match\n' "$1" "$2"
  else
    printf '%s vs %s: miss\n' "$1" "$2"
  fi
  shift 2
done
PROBE
    chmod +x "$probe" || return 1
  fi
  "$probe" "$TOOLKIT_ROOT/bin/okf" "$@"
}

# The include and exclude globs are matched by bin/okf itself rather than by
# git, so the dialect they are written in is okf's to get right: gitignore's,
# which is the one SPEC.md §6's own defaults are written in.
test_okf_scope_globs_are_gitignore_shaped() {
  _okf_preconditions || return 1

  # Each case's verdict is spelled out beside it, so a dialect that drifts says
  # which rule drifted rather than only that the listing changed. The last of
  # them are the two rules about the separator: a `/` in the pattern anchors it
  # to the bundle root and a bare name floats, and a pattern reaches what is
  # under it — without which `"exclude": ["target"]` and `["**/vendor/"]` both
  # quietly exclude nothing at all, since git ls-files prints no directories for
  # them to match.
  local expected='**/target/** vs target/Old.java: match
**/target/** vs src/target/Stale.java: match
**/target/** vs src/targeted/Keep.java: miss
src/** vs src/a/b/c.ts: match
src/** vs srcx/a.ts: miss
src/*.ts vs src/a.ts: match
src/*.ts vs src/util/a.ts: miss
src/?.ts vs src/a.ts: match
src/?.ts vs src/ab.ts: miss
lib vs lib/core.py: match
lib vs library/core.py: miss
/lib/ vs lib/core.py: match
a.b vs axb: miss
** vs any/depth/at/all.py: match
target vs src/target/Stale.java: match
target vs target/Old.java: match
*.min.js vs src/vendor/jquery.min.js: match
/target vs src/target/Stale.java: miss
src/target vs src/target/Stale.java: match
**/vendor/ vs lib/vendor/pinned.py: match
vendor/ vs lib/vendor/pinned.py: match
vendor/ vs lib/vendor: miss
/ vs src/app.ts: match
. vs src/app.ts: match
./ vs src/app.ts: match
./src vs src/app.ts: match
./src vs lib/vendor/src/a.ts: miss
src vs lib/vendor/src/a.ts: match
src/**.ts vs src/helper.ts: match
src/**.ts vs src/util/helper.ts: miss
a**b vs axb: match
a**b vs a/x/b: miss
src//** vs src/app.ts: match
src/**//util/* vs src/util/helper.ts: match'

  local actual
  actual="$(_okf_glob_verdicts \
    '**/target/**' target/Old.java \
    '**/target/**' src/target/Stale.java \
    '**/target/**' src/targeted/Keep.java \
    'src/**' src/a/b/c.ts \
    'src/**' srcx/a.ts \
    'src/*.ts' src/a.ts \
    'src/*.ts' src/util/a.ts \
    'src/?.ts' src/a.ts \
    'src/?.ts' src/ab.ts \
    lib lib/core.py \
    lib library/core.py \
    /lib/ lib/core.py \
    a.b axb \
    '**' any/depth/at/all.py \
    target src/target/Stale.java \
    target target/Old.java \
    '*.min.js' src/vendor/jquery.min.js \
    /target src/target/Stale.java \
    src/target src/target/Stale.java \
    '**/vendor/' lib/vendor/pinned.py \
    vendor/ lib/vendor/pinned.py \
    vendor/ lib/vendor \
    / src/app.ts \
    . src/app.ts \
    ./ src/app.ts \
    ./src src/app.ts \
    ./src lib/vendor/src/a.ts \
    src lib/vendor/src/a.ts \
    'src/**.ts' src/helper.ts \
    'src/**.ts' src/util/helper.ts \
    'a**b' axb \
    'a**b' a/x/b \
    'src//**' src/app.ts \
    'src/**//util/*' src/util/helper.ts)"
  assert_eq "$expected" "$actual" \
    "okf's include and exclude globs read as gitignore's do"
  return 0
}

# SPEC.md §5's scope rules over tests/fixtures/scoped, which carries one file
# for each of them.
test_okf_list_prints_the_in_scope_sources() {
  _okf_preconditions || return 1
  with_fixture_repo scoped _okf_list_scope_probe
}

# The other half of the same PLAN.md item: the include, exclude and extensions
# settings SPEC.md §6 defines actually move the listing.
test_okf_list_honours_the_bundle_settings() {
  _okf_preconditions || return 1
  with_fixture_repo scoped _okf_list_settings_probe
}

test_okf_list_refuses_what_it_cannot_answer() {
  _okf_preconditions || return 1
  with_fixture_repo scoped _okf_list_refusal_probe
}

# SPEC.md §5 co-locates a concept beside its source, so --missing is that rule
# read backwards: the in-scope sources with no sibling concept file.
test_okf_list_missing_lists_undocumented_sources() {
  _okf_preconditions || return 1
  with_fixture_repo scoped _okf_list_missing_probe
}

# The same rule read the other way round: --orphans lists the concept files
# whose `resource` names a source that is no longer there.
test_okf_list_orphans_lists_concepts_whose_source_is_gone() {
  _okf_preconditions || return 1
  with_fixture_repo scoped _okf_list_orphans_probe
}

# Scope is read out of git, so a bundle root outside a work tree is a question
# okf cannot answer — and says so rather than printing an empty listing and
# exiting 0.
test_okf_list_needs_a_git_work_tree() {
  _okf_preconditions || return 1

  local tmp
  # Named without "git" in it, because the directory's own path is echoed back
  # in every message okf prints about it — including the ones that never got as
  # far as looking for a work tree.
  if ! tmp="$(mktemp -d "${TMPDIR:-/tmp}/toolkit-bare.XXXXXX")"; then
    _fail "a directory outside any git repo can be made" "mktemp -d failed"
    return 1
  fi
  # Registered the way with_fixture_repo registers its copies, so an interrupted
  # run takes it with everything else rather than leaving it in TMPDIR.
  printf '%s\n' "$tmp" >> "$HARNESS_STATE/fixture_dirs"

  # TMPDIR is usually nobody's repository, but it does not have to be: someone
  # whose TMPDIR is $HOME/tmp under a dotfiles repo has a temp directory inside
  # a work tree, and this check would fail there for a reason that has nothing
  # to do with okf. Said as a skip rather than left to be a spurious failure of
  # the suite every PLAN.md item verifies with.
  if (CDPATH= cd "$tmp" && git rev-parse --is-inside-work-tree > /dev/null 2>&1); then
    _skip "okf list says why it cannot list a directory outside a work tree" \
      "TMPDIR is itself inside a git work tree"
    rm -rf "$tmp"
    return 0
  fi

  assert_exit 1 "$TOOLKIT_ROOT/bin/okf" -C "$tmp" list
  # "work tree" and not "git": the latter would be satisfied by the temp path
  # itself, so a -C that failed before ever reaching the work-tree check — a
  # directory that is not there, one that cannot be entered — would pass this
  # for the wrong reason.
  assert_contains "$(last_output)" "work tree" \
    "okf list says why it cannot list a directory that is not in a work tree"

  # The same for the filtered listings. --orphans reads a different set out of
  # git than plain `list` does, and left to git alone it would fail with git's
  # own line about the index instead of okf's about the root it was pointed at.
  local flag
  for flag in --missing --orphans; do
    assert_exit 1 "$TOOLKIT_ROOT/bin/okf" -C "$tmp" list "$flag"
    assert_contains "$(last_output)" "work tree" \
      "okf list $flag says so too, rather than leaving it to git"
  done
  rm -rf "$tmp"
  return 0
}

# SPEC.md §8's drift rule is a comparison between a digest stored when a concept
# was written and one computed now, so what these check is not that okf ran
# sha256sum — it is that the number it printed is the sha256 of those exact
# bytes. Every expected value below is written out as a constant for that
# reason: a test that recomputed it with sha256sum would agree with okf about
# anything, including being wrong in the same way.
_okf_hash_digest_probe() {
  local okf="$TOOLKIT_ROOT/bin/okf"
  local greeter="sha256:cda1b9b92ca2cbf335c365972ff175c46b22998f4046e7eb12d8f7ac8ec18280"

  # _okf_assert_listing is "okf exits 0 and its stdout is exactly this", which is
  # the check a one-line digest wants as much as a listing does; only its name is
  # about `okf list`. Exactly, and not a substring: a digest with anything else
  # on the line is one no `okf check` could compare, and `sha256:` in front of it
  # is part of the stored value SPEC.md §4 writes into `code.content_hash`.
  _okf_assert_listing "$greeter" \
    "okf hash prints the sha256: digest of a committed fixture file" \
    hash src/greeter.py

  # Written here rather than committed, so the bytes really are these whatever
  # the checkout did to them. Each one is a way a plausible implementation goes
  # wrong: `$(cat file)` strips the trailing newline, so the last two would
  # collide; a digest routed through a shell variable loses everything from a
  # NUL byte on; and a reader that went through git's text filters, or through
  # awk, would make the CRLF file and the LF one agree.
  printf 'hello\n' > payload.txt
  printf 'hello' > no-trailing-newline.txt
  : > empty.txt
  printf 'a\r\nb\n' > crlf.txt
  printf 'a\nb\n' > lf.txt
  printf 'a\0b\n' > nul.dat

  # payload.txt and the rest were made after the fixture's commit, so they are
  # untracked — and hashing them proves what SPEC.md §7 asks of `okf hash`: one
  # file's digest, with no scope test and no index lookup in front of it. A
  # source that has just been written is exactly the one somebody is about to
  # document.
  _okf_assert_listing \
    "sha256:5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03" \
    "an untracked file is hashed like any other" \
    hash payload.txt
  _okf_assert_listing \
    "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" \
    "a file with no trailing newline hashes as its own bytes, not as payload.txt" \
    hash no-trailing-newline.txt
  _okf_assert_listing \
    "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" \
    "an empty file has the empty sha256 rather than no answer" \
    hash empty.txt
  _okf_assert_listing \
    "sha256:953bba9ac9726eaea07e844abcf144a0afe998039257c7a88b6665819597f39d" \
    "line endings are hashed, not normalised" \
    hash crlf.txt
  _okf_assert_listing \
    "sha256:911169ddaaf146aff539f58c26c489af3b892dff0fe283c1c264c65ae5aa59a2" \
    "so the same text with LF endings has a different digest" \
    hash lf.txt
  _okf_assert_listing \
    "sha256:3a100994c4e38751871e6e8eef9adad2b20177fdeaf650daacdcd74f4c9421e3" \
    "a NUL byte is hashed rather than truncating the file" \
    hash nul.dat

  # A file whose name begins with a dash, reachable both ways every other tool
  # spells it. `okf hash -weird.py` is refused by name in the refusal probe;
  # these two are what the refusal tells the caller to type instead.
  printf '%s\n' '-weird.py content' > ./-weird.py
  local weird="sha256:186df911c1177487a59bdb8c4a92389239ce89f150f4e21e3a1270eb07f76e1a"
  _okf_assert_listing "$weird" "-- ends the flags, so a dash-named file is hashed" \
    hash -- -weird.py
  _okf_assert_listing "$weird" "and ./ names the same file without --" \
    hash ./-weird.py

  # SPEC.md §7's -C, asked of a subcommand whose argument is a path: the file is
  # resolved against the root -C names and not against the directory okf was
  # invoked from. Run from the toolkit checkout, where `src/greeter.py` is not
  # there at all — so a -C that had been ignored would fail rather than quietly
  # hash the wrong file.
  local outside
  outside="$(CDPATH= cd "$TOOLKIT_ROOT" && "$okf" -C "$FIXTURE_DIR" hash src/greeter.py 2>&1)"
  assert_eq "$greeter" "$outside" \
    "-C names the root okf hash resolves its argument against"
  return 0
}

_okf_hash_refusal_probe() {
  local okf="$TOOLKIT_ROOT/bin/okf"

  assert_exit 1 "$okf" hash
  assert_contains "$(last_output)" "usage: okf hash" \
    "okf hash with nothing to hash says what it takes"

  # The second path named in the refusal, because the alternative okf must not
  # choose is hashing the first and saying nothing about the second — a digest
  # that is right for a file the caller did not ask about.
  assert_exit 1 "$okf" hash src/greeter.py README.md
  assert_contains "$(last_output)" "README.md" \
    "okf hash refuses a second file rather than silently dropping it"

  assert_exit 1 "$okf" hash --bogus
  assert_contains "$(last_output)" "unknown flag: --bogus" \
    "okf hash names a flag it does not know"

  # A word beginning with a dash is a flag here, and no filename check could
  # tell the two apart — so the refusal carries the two spellings that do.
  assert_exit 1 "$okf" hash -weird.py
  assert_contains "$(last_output)" "./-weird.py" \
    "and says how to name a file whose name begins with a dash"

  assert_exit 1 "$okf" hash no-such-file.py
  assert_contains "$(last_output)" "no-such-file.py" \
    "a file that is not there is named rather than hashed as empty"

  # sha256sum answers "Is a directory" for this one, on stderr, having already
  # exited non-zero — but a caller who typed a directory by tab-completion is
  # owed the reason and not that.
  assert_exit 1 "$okf" hash src
  assert_contains "$(last_output)" "directory" \
    "a directory is refused as one"

  # SPEC.md §4 writes `resource` bundle-absolute, so a caller pasting one
  # straight out of a concept lands here. The refusal has to say which of the
  # two spellings okf read it as, or it looks like the file is gone.
  assert_exit 1 "$okf" hash /src/greeter.py
  assert_contains "$(last_output)" "bundle-absolute" \
    "a bundle-absolute path is refused with the spelling okf did not read it as"
  assert_contains "$(last_output)" "src/greeter.py" \
    "and with the path that would have worked"

  # A fifo has no bytes until somebody writes them, so an okf that opened this
  # one would wait for a writer that never comes — and the test suite every
  # PLAN.md item verifies with would hang instead of failing. Run under
  # `timeout` so that a regression is a failed check, not a run that never ends.
  if command -v mkfifo > /dev/null 2>&1 && command -v timeout > /dev/null 2>&1; then
    if mkfifo waiting.fifo 2> /dev/null; then
      assert_exit 1 timeout 10 "$okf" hash waiting.fifo
      assert_contains "$(last_output)" "regular file" \
        "a fifo is refused rather than opened and waited on"
      rm -f waiting.fifo
    else
      _skip "okf hash refuses a fifo rather than waiting on it" \
        "mkfifo failed in the fixture copy"
    fi
  else
    _skip "okf hash refuses a fifo rather than waiting on it" \
      "mkfifo or timeout is not installed, and an unguarded fifo check could hang"
  fi
  return 0
}

# The PLAN.md item itself: the sha256: prefixed digest of one file, asserted
# against a known digest over a tests/fixtures/ file.
test_okf_hash_prints_a_known_digest() {
  _okf_preconditions || return 1
  with_fixture_repo tiny _okf_hash_digest_probe
}

test_okf_hash_refuses_what_it_cannot_digest() {
  _okf_preconditions || return 1
  with_fixture_repo tiny _okf_hash_refusal_probe
}

# Unlike `okf list`, `okf hash` answers about one file's bytes and not about the
# bundle, so it needs neither a work tree nor an okf.json. That is what lets
# `okf check` hash a resource in a repository mid-rebase, and what keeps a
# repo with no okf.json — SPEC.md §6's defaults — from being a repo where
# nothing can be hashed.
test_okf_hash_needs_no_repository() {
  _okf_preconditions || return 1

  local tmp
  if ! tmp="$(mktemp -d "${TMPDIR:-/tmp}/toolkit-hash.XXXXXX")"; then
    _fail "a directory outside any git repo can be made" "mktemp -d failed"
    return 1
  fi
  # Registered the way with_fixture_repo registers its copies, so an interrupted
  # run takes it with everything else rather than leaving it in TMPDIR.
  printf '%s\n' "$tmp" >> "$HARNESS_STATE/fixture_dirs"
  printf 'hashed outside any git repository\n' > "$tmp/plain.txt"

  assert_exit 0 "$TOOLKIT_ROOT/bin/okf" -C "$tmp" hash plain.txt
  assert_eq "sha256:3b9e4fa6b81d40b5f4df687241be16d0507507adc7aa9b4bc14c7c525f0c5996" \
    "$(last_output)" \
    "okf hash answers for a file with no okf.json and no git repository around it"
  rm -rf "$tmp"
  return 0
}

# SPEC.md §5's fan-in: "a whole-word ripgrep count across in-scope files, minus
# the declaration site". Every expected number below is written out as a
# constant over committed fixture bytes, for the reason the digest probe gives
# — a test that recomputed it with its own ripgrep call would agree with okf
# about anything, including being wrong the same way.
_okf_fanin_count_probe() {
  # tests/fixtures/scoped's in-scope sources are lib/conventions.py,
  # lib/core.py, src/app.ts, src/generated/Handwritten.java,
  # src/util/Accessors.java and src/util/helper.ts — the listing
  # _okf_list_scope_probe pins down. Every count here is over those six files.

  # `helper` is named four times across them: three in src/app.ts — twice on the
  # import line, once in the call — and once in src/util/helper.ts's own
  # `export function helper`. The fourth is the declaration site, and SPEC.md §5
  # takes it out, so the answer is 3 and not 4.
  #
  # _okf_assert_listing is "okf exits 0 and its stdout is exactly this", which is
  # the check a bare count wants as much as a listing does; only its name is
  # about `okf list`. Exactly, and not a substring: `3` and `13` share one, and a
  # fan-in read by a tier rule is a number, not a line to be searched.
  _okf_assert_listing "3" \
    "okf fanin counts a known name across the in-scope sources" \
    fanin helper

  # The zero SPEC.md §5's tier rules have to be able to read: a name nothing
  # refers to is 0 on stdout and exit 0, not an empty line and not a refusal.
  # ripgrep exits 1 when it matches nothing, so this is also the check that okf
  # is not passing that status on as its own.
  _okf_assert_listing "0" \
    "a name nothing refers to counts zero, and is not an error" \
    fanin NoSuchTypeAnywhere

  # Whole words, which is the part of §5's definition that keeps a fan-in from
  # being a substring count. `Generated` is named five times in the in-scope
  # files — twice in src/util/Accessors.java, three times in
  # src/generated/Handwritten.java — and Handwritten.java also carries
  # `@NotGenerated("hand-written")`, which ends with the letters and is not the
  # word. A count of 6 here is a --word-regexp that got dropped.
  _okf_assert_listing "5" \
    "a name is counted as a whole word, so @NotGenerated is not a Generated" \
    fanin Generated

  # And case-sensitively. The same six files name `generated` in lower case
  # seven times — three in Handwritten.java's prose, four in
  # lib/conventions.py's — so a smart-case or case-insensitive count would
  # answer 12 for either spelling and make two different names one number.
  _okf_assert_listing "7" \
    "and case-sensitively, so generated and Generated are counted apart" \
    fanin generated
  return 0
}

# Matches and not matching lines, and the declaration-site rule seen moving.
# Written into the fixture copy rather than counted over the committed tree,
# because what these pin down is a shape no fixture file happens to have: two
# references on one line, and one file that is the declaration site for one name
# and an ordinary reference for another.
_okf_fanin_granularity_probe() {
  # Two references on one line, and nothing else on it. `rg --count` would
  # report the line and answer 1; `rg --count-matches` reports the references
  # and answers 2. That is the whole difference, and it is the one flag here
  # easy to reach for by mistake.
  printf 'export const pair: [Widget, Widget] = [makeWidget(), makeWidget()];\n' \
    > src/pair.ts
  _okf_stage src/pair.ts || return 1

  _okf_assert_listing "2" \
    "two references on one line count twice, so a fan-in is matches and not lines" \
    fanin Widget

  # The declaration site, added second so the number before and after it says
  # what the rule did. src/Widget.ts names `Widget` three times and `makeWidget`
  # once; SPEC.md §5 co-locates a concept beside its source as `<stem>.md`, so
  # `Widget.ts` is where a type called `Widget` is declared and its own mentions
  # of itself are not fan-in.
  printf 'export class Widget {}\nexport function makeWidget(): Widget { return new Widget(); }\n' \
    > src/Widget.ts
  _okf_stage src/Widget.ts || return 1

  _okf_assert_listing "2" \
    "a name's own declaration site is left out, so adding it moves nothing" \
    fanin Widget

  # The same file, asked about the other name it declares. `makeWidget` is not
  # `Widget`, so src/Widget.ts is an ordinary in-scope file for this count and
  # its one mention is counted — two in src/pair.ts and one here. This is the
  # limit of what co-location can decide, stated as a number: only the type the
  # file is named after gets its declaration taken out.
  _okf_assert_listing "3" \
    "a second type declared in that file keeps its own declaration in the count" \
    fanin makeWidget

  # A second file bearing the same stem, which is where "the declaration site"
  # stops being a thing co-location can point at. lib/Widget.ts declares no
  # `Widget` at all — it imports one and names a variable — but nothing okf can
  # see tells it apart from src/Widget.ts, so neither is taken out and the
  # count is 8: two in src/pair.ts, three in src/Widget.ts, three here.
  #
  # 5 would be this probe's own second file thrown away, and 2 would be both of
  # them. Either is a name counted *low* for having callers in like-named files
  # — the failure worth avoiding, since SPEC.md §5's tier rules read fan-in
  # against a threshold and a hot type counted low is one nobody documents.
  printf 'import { Widget } from "../src/Widget";\nexport const spare = new Widget();\n' \
    > lib/Widget.ts
  _okf_stage lib/Widget.ts || return 1

  _okf_assert_listing "8" \
    "two files could be the declaration site, so neither is taken out" \
    fanin Widget

  # And the ambiguity is over the stem alone: `makeWidget` still has exactly one
  # candidate file — none — so its count is unchanged by lib/Widget.ts, which
  # never names it.
  _okf_assert_listing "3" \
    "and a name with no candidate file at all is unaffected by the ambiguity" \
    fanin makeWidget

  rm -f src/pair.ts src/Widget.ts lib/Widget.ts
  git rm -q --cached src/pair.ts src/Widget.ts lib/Widget.ts > /dev/null 2>&1

  # The declaration site is found by name and by case, and lib/core.py is where
  # that shows: it declares `Core`, but §5's `<stem>.md` co-location has nothing
  # to match `core` against `Core` with, so the declaration stays in the count
  # and the answer is 1 rather than 0. Asserted rather than left implicit —
  # SPEC.md §5 makes fan-in a ranking signal and not a correctness claim, and
  # this is one of the places the difference is visible.
  _okf_assert_listing "1" \
    "a file whose stem differs in case from the type is not spotted as its declaration" \
    fanin Core

  # The other side of the same rule: src/util/Accessors.java is named after the
  # only type that mentions `Accessors`, so taking it out leaves nothing at all.
  _okf_assert_listing "0" \
    "and a name mentioned only where it is declared counts zero" \
    fanin Accessors
  return 0
}

# The one case where SPEC.md §5's co-location reads a fan-in *low*: a single
# in-scope file bears the name as its stem and is not the file that declares it.
# Pinned as a number rather than left to be discovered, because it is the shape
# of wrongness a caller acting on `fan_in` has to be able to recognise — and
# because an okf that quietly started counting these would be changing what §5
# defines without anything saying so.
_okf_fanin_misread_declaration_probe() {
  # `Gauge` is declared in src/index.ts, which names it twice, and referenced
  # three times from src/probes/Gauge.ts, which declares nothing at all. Five
  # references are there; the stem match takes src/probes/Gauge.ts out whole,
  # and 2 comes back.
  printf 'export class Gauge {}\nexport const first = new Gauge();\n' > src/index.ts
  mkdir -p src/probes
  printf 'import { Gauge } from "../index";\nexport const g = new Gauge();\nexport const h = new Gauge();\n' \
    > src/probes/Gauge.ts
  _okf_stage src/index.ts src/probes/Gauge.ts || return 1

  _okf_assert_listing "2" \
    "a lone stem match is taken for the declaration site even when it is not one" \
    fanin Gauge

  # Renaming that file — the same three references, in a file no longer named
  # after them — is what the missing 3 were, and 5 is the count with nothing
  # excluded. Asserted so the 2 above reads as an exclusion rather than as three
  # references okf failed to find.
  git mv -f src/probes/Gauge.ts src/probes/gauges.ts > /dev/null 2>&1 \
    || { _fail "the fixture copy accepts a git mv" "git mv src/probes/Gauge.ts failed"; return 1; }
  _okf_assert_listing "5" \
    "and the same references count in full once the file is not named after them" \
    fanin Gauge
  return 0
}

# One ripgrep per OKF_FANIN_BATCH paths, summed across batches. Nothing in
# tests/fixtures/ is big enough to reach a second batch, so the tree is built
# here: without it, a total reset or dropped per batch would leave every
# repository over 400 in-scope files reporting one batch's count, and the suite
# would still say PASS.
_okf_fanin_batching_probe() {
  # One over the batch size, so the second batch holds exactly one file. 401 is
  # then the only right answer: 1 is a total reset per batch, 400 is a last
  # batch never counted, and 800 is a batch counted twice.
  local batch i
  batch="$(sed -n 's/^OKF_FANIN_BATCH=\([0-9][0-9]*\)$/\1/p' "$TOOLKIT_ROOT/bin/okf")"
  if [ -z "$batch" ]; then
    _fail "bin/okf declares OKF_FANIN_BATCH" "no OKF_FANIN_BATCH=<number> line in bin/okf"
    return 1
  fi

  mkdir -p src/bulk
  i=0
  while [ "$i" -le "$batch" ]; do
    # Named so no stem is `Bulkref`: a file the declaration-site rule took out
    # would make this off by one for a reason that has nothing to do with
    # batching.
    printf 'export const u%s = new Bulkref();\n' "$i" > "src/bulk/ref$i.ts"
    i=$((i + 1))
  done
  _okf_stage src/bulk || return 1

  _okf_assert_listing "$((batch + 1))" \
    "a reference in every file of a tree larger than one batch is counted once" \
    fanin Bulkref
  return 0
}

# The "across in-scope files" half of SPEC.md §5's definition: the same scope
# `okf list` prints, so every exclusion that keeps a file out of the listing
# keeps its references out of the count. Each rule is asked about a word that
# appears only in the file that rule excludes, so a failure names which
# exclusion stopped working.
_okf_fanin_scope_probe() {
  # `pong` is returned by src/generated/Api.java and by src/generated/ping.go,
  # and by nothing in scope. Neither file's stem is `pong`, so a count of 2 here
  # would be the @Generated exclusion gone rather than the declaration-site rule
  # doing the work.
  _okf_assert_listing "0" \
    "a word only generated sources use is not counted" \
    fanin pong

  # src/target/Stale.java, excluded by the `**/target/**` glob. Its stem is
  # `Stale`, so the word asked about is the package it declares instead.
  _okf_assert_listing "0" \
    "nor one only a build-output directory uses" \
    fanin target

  # lib/vendor/pinned.py and lib/node_modules/left-pad/index.js, excluded by
  # `**/vendor/**` and `**/node_modules/**`. `leftPad` is named in index.js,
  # whose stem is `index`, and `vendored` in pinned.py, whose stem is `pinned`.
  _okf_assert_listing "0" "nor one only a vendored file uses" fanin vendored
  _okf_assert_listing "0" "nor one only node_modules uses" fanin leftPad

  # tools/build.js, outside the `include` globs. Its stem is `build`, so the
  # word is one from the line it prints.
  _okf_assert_listing "0" \
    "nor one only a file outside the include globs uses" \
    fanin tooling

  # src/ignored/secret.ts, gitignored and so absent from `git ls-files`. Checked
  # to be on disk first: the file is committed in the toolkit's own repository
  # with `git add -f`, and without it every count below would be 0 for want of
  # anything to exclude.
  if [ -f src/ignored/secret.ts ]; then
    _pass "the gitignored fixture source reached the fixture copy"
  else
    _fail "the gitignored fixture source reached the fixture copy" \
      "no src/ignored/secret.ts under $PWD — it needs a git add -f in the toolkit repo"
  fi
  _okf_assert_listing "0" "nor one only a gitignored file uses" fanin gitignored

  # src/notes.md and src/data.json, which are not listed extensions. So is
  # src/util/helper.md, a concept file — its own prose must not count as fan-in
  # for the type it documents, or every documented type would out-rank an
  # undocumented one for having been documented.
  _okf_assert_listing "0" "nor one only a non-source extension uses" fanin sample
  _okf_assert_listing "0" "nor one only a concept file uses" fanin Prints
  return 0
}

_okf_fanin_refusal_probe() {
  local okf="$TOOLKIT_ROOT/bin/okf"

  assert_exit 1 "$okf" fanin
  assert_contains "$(last_output)" "usage: okf fanin" \
    "okf fanin with no name says what it takes"

  # The second name is in the refusal, because the alternative okf must not
  # choose is counting the first and saying nothing about the second — a fan_in
  # that is right for a type the caller did not ask about.
  assert_exit 1 "$okf" fanin Widget Gadget
  assert_contains "$(last_output)" "Gadget" \
    "okf fanin refuses a second name rather than silently dropping it"

  assert_exit 1 "$okf" fanin --bogus
  assert_contains "$(last_output)" "unknown flag: --bogus" \
    "okf fanin names a flag it does not know"

  # ripgrep reads the empty pattern as a match at every position, so an okf that
  # passed this through would answer with roughly the size of the repository —
  # wrong, and wrong in the direction that promotes a concept to Tier 2.
  assert_exit 1 "$okf" fanin ""
  assert_contains "$(last_output)" "empty" \
    "an empty name is refused rather than counted as every position in the repo"

  # A newline is the one ripgrep itself rejects, outside multiline mode. Refused
  # here so the caller is told their name is malformed rather than that the scan
  # failed.
  assert_exit 1 "$okf" fanin "$(printf 'Route\nRegistry')"
  assert_contains "$(last_output)" "whitespace" \
    "and so is a name with a newline in it, before ripgrep is asked"

  assert_exit 1 "$okf" fanin "Route Registry"
  assert_contains "$(last_output)" "whitespace" \
    "and one with a space, which is a quoting slip and not a word to count"

  # -- is the escape hatch for a name beginning with a dash. No type is called
  # this, but without it there would be a name okf could not be asked about at
  # all — and what comes back has to be a count, not the flag refusal.
  _okf_assert_listing "0" "-- ends the flags, so a dash-led name is counted" \
    fanin -- -Weird
  return 0
}

# The PLAN.md item itself: a whole-word ripgrep count over the in-scope files,
# asserted against known numbers, with an unreferenced name coming back as 0.
test_okf_fanin_counts_whole_word_references() {
  _okf_preconditions || return 1
  with_fixture_repo scoped _okf_fanin_count_probe
}

# SPEC.md §5's "minus the declaration site", and the matches-not-lines reading
# of "count" that the same sentence settles.
test_okf_fanin_excludes_the_declaration_site() {
  _okf_preconditions || return 1
  with_fixture_repo scoped _okf_fanin_granularity_probe
}

# "Across in-scope files": the same scope `okf list` prints, exclusion by
# exclusion.
test_okf_fanin_counts_only_in_scope_files() {
  _okf_preconditions || return 1
  with_fixture_repo scoped _okf_fanin_scope_probe
}

# The failure direction SPEC.md §5's co-location cannot avoid, pinned as a
# number so it is a documented limit rather than a surprise in somebody's tier
# rule.
test_okf_fanin_can_mistake_a_like_named_file_for_the_declaration() {
  _okf_preconditions || return 1
  with_fixture_repo scoped _okf_fanin_misread_declaration_probe
}

# The count is summed across ripgrep invocations, and no fixture is big enough
# to need a second one.
test_okf_fanin_sums_across_ripgrep_batches() {
  _okf_preconditions || return 1
  with_fixture_repo scoped _okf_fanin_batching_probe
}

test_okf_fanin_refuses_what_it_cannot_count() {
  _okf_preconditions || return 1
  with_fixture_repo scoped _okf_fanin_refusal_probe
}

# SPEC.md §7's -C, asked of the subcommand whose answer is a bare number: the
# count is over the bundle -C names and not over the directory okf was invoked
# from. Run from the toolkit checkout, whose own sources mention none of this —
# so a -C that had been ignored would answer 0 rather than fail, and a check
# that only asserted "not an error" would pass.
_okf_fanin_root_probe() {
  local okf="$TOOLKIT_ROOT/bin/okf" outside
  outside="$(CDPATH= cd "$TOOLKIT_ROOT" && "$okf" -C "$FIXTURE_DIR" fanin helper 2>&1)"
  assert_eq "3" "$outside" "-C names the bundle okf fanin counts across"
  return 0
}

test_okf_fanin_counts_across_the_root_given_by_C() {
  _okf_preconditions || return 1
  with_fixture_repo scoped _okf_fanin_root_probe
}

# Scope is read out of git, so a bundle root outside a work tree is a count okf
# cannot make — and says so rather than printing 0 and exiting 0, which is the
# answer a tier rule would act on.
test_okf_fanin_needs_a_git_work_tree() {
  _okf_preconditions || return 1

  local tmp
  if ! tmp="$(mktemp -d "${TMPDIR:-/tmp}/toolkit-bare.XXXXXX")"; then
    _fail "a directory outside any git repo can be made" "mktemp -d failed"
    return 1
  fi
  printf '%s\n' "$tmp" >> "$HARNESS_STATE/fixture_dirs"

  # The same skip `okf list`'s work-tree check takes, and for the same reason: a
  # TMPDIR that is itself inside somebody's dotfiles repo would fail this for a
  # reason that has nothing to do with okf.
  if (CDPATH= cd "$tmp" && git rev-parse --is-inside-work-tree > /dev/null 2>&1); then
    _skip "okf fanin says why it cannot count outside a work tree" \
      "TMPDIR is itself inside a git work tree"
    rm -rf "$tmp"
    return 0
  fi

  assert_exit 1 "$TOOLKIT_ROOT/bin/okf" -C "$tmp" fanin Widget
  assert_contains "$(last_output)" "work tree" \
    "okf fanin says why it cannot count in a directory that is not in a work tree"
  rm -rf "$tmp"
  return 0
}

# SPEC.md §4 names the fields the shell is allowed to read, so the list is read
# back out of it rather than restated here: a field added to §4 with no reader
# in bin/okf then fails as a missing one instead of going quietly unread.
#
# §4 writes the last four with the prefix factored out — "`code.` `content_hash`,
# `tier`, `symbol`, `language`" — so a quoted token ending in a dot is a prefix
# for the tokens after it rather than a field of its own. The sentence stops at
# the extraction rule that follows it, whose own quoted spans (`^  X: `, and the
# rest) are pattern syntax and not field names.
_okf_spec_frontmatter_fields() {
  awk '
    /^## 4\./ { in_section = 1; next }
    in_section && /^## / { exit }
    in_section && /^Fields the shell reads:/ { in_fields = 1 }
    in_fields && /^Extraction rule/ { exit }
    in_fields {
      n = split($0, part, "`")
      # Backticks come in pairs, so the quoted spans are the even indices.
      for (i = 2; i <= n; i += 2) {
        token = part[i]
        if (token ~ /\.$/) { prefix = token; continue }
        print prefix token
      }
    }
  ' "$TOOLKIT_ROOT/SPEC.md"
}

# bin/okf's own reading of one concept: `status=<rc>` for what read_frontmatter
# returned, then one `field:<name>=<value>` line per SPEC.md §4 field asked
# about — or `missing:<name>` for a field bin/okf keeps no variable for.
# `verified[].at` is a list, so it prints one line per entry and none at all
# when there are none.
#
# Obtained by sourcing bin/okf and calling read_frontmatter directly, the way
# _okf_context calls parse_globals: none of this is printed anywhere, because
# SPEC.md §7 defines no subcommand that prints frontmatter and a flag invented
# to test with would be CLI surface the spec has not got. The names used here —
# read_frontmatter, and the OKF_FM_ variables it fills — are the contract this
# item owes every subcommand written after it, so a rename that breaks them
# should fail loudly.
#
# The variable name is derived from §4's field name rather than looked up in a
# table written here: `OKF_FM_` plus the field upper-cased, its dots turned into
# underscores and its `[]` dropped. That derivation is what makes this a check
# on §4's list and not on a copy of it.
#
# $1 is a concept to read *before* the one under test, or empty for none. It is
# what makes an empty field mean "this concept has not got one" rather than
# "nothing was ever read": after a full concept, every variable holds a value
# that a failed or sparser read has to clear.
_okf_frontmatter_probe() { # $1 = concept to read first or "", $2 = concept, $3.. = field names
  local probe="$HARNESS_STATE/okf-frontmatter-probe.sh"
  if [ ! -f "$probe" ]; then
    cat > "$probe" <<'PROBE'
#!/usr/bin/env bash
okf_script="$1"
preload="$2"
concept="$3"
shift 3
# shellcheck source=/dev/null
. "$okf_script"

if [ -n "$preload" ]; then
  read_frontmatter "$preload" || true
fi

rc=0
read_frontmatter "$concept" || rc=$?
printf 'status=%s\n' "$rc"

report_field() { # $1 = a SPEC.md §4 field name
  local field="$1" var decl item
  local -a items=()
  var="OKF_FM_$(printf '%s' "$field" | tr -d '[]' | tr '.' '_' | tr '[:lower:]' '[:upper:]')"
  if ! decl="$(declare -p "$var" 2> /dev/null)"; then
    printf 'missing:%s\n' "$field"
    return 0
  fi
  case "$decl" in
    "declare -a"*)
      eval "items=( \${$var[@]+\"\${$var[@]}\"} )"
      for item in ${items[@]+"${items[@]}"}; do
        printf 'field:%s=%s\n' "$field" "$item"
      done
      ;;
    *) printf 'field:%s=%s\n' "$field" "${!var}" ;;
  esac
}

for field in "$@"; do
  report_field "$field"
done
PROBE
    chmod +x "$probe" || return 1
  fi
  "$probe" "$TOOLKIT_ROOT/bin/okf" "$@" 2>&1
}

_okf_frontmatter_status() { # $1 = probe output
  printf '%s\n' "$1" | sed -n 's/^status=//p'
}

# Every value the probe reported for one field, in order: one line for a scalar,
# one per entry for `verified[].at`, and nothing at all for a field that is
# absent or empty. Matched as a literal prefix rather than with a regular
# expression, because `verified[].at` is a bracket expression to sed and would
# match nothing at all.
_okf_frontmatter_field() { # $1 = probe output, $2 = field name
  local line
  while IFS= read -r line; do
    case "$line" in
      "field:$2="*) printf '%s\n' "${line#"field:$2="}" ;;
    esac
  done <<< "$1"
}

# Every SPEC.md §4 field, read out of one concept and asserted empty — what a
# file that is not a concept must leave behind. The probe reads a full concept
# first, so every variable held a value that this had to clear.
_okf_frontmatter_assert_not_a_concept() { # $1 = path, $2 = what it is, $3.. = field names
  local path="$1" what="$2"
  shift 2
  local out field
  out="$(_okf_frontmatter_probe \
    "$FIXTURES_DIR/concepts/src/route/RouteRegistry.md" "$path" "$@")"

  assert_eq "1" "$(_okf_frontmatter_status "$out")" \
    "read_frontmatter refuses $what"
  for field in "$@"; do
    assert_eq "" "$(_okf_frontmatter_field "$out" "$field")" \
      "$field is empty after read_frontmatter refused $what"
  done
}

# The reader owed by PLAN.md's Phase 4: every field SPEC.md §4 lists as
# shell-read, out of a concept that carries all of them.
test_okf_frontmatter_reader_exposes_every_spec_field() {
  local okf="$TOOLKIT_ROOT/bin/okf"
  if [ ! -x "$okf" ]; then
    _fail "bin/okf is an executable script" "missing or not executable: $okf"
    return 1
  fi

  local -a fields=()
  local field
  while IFS= read -r field; do
    [ -n "$field" ] && fields+=("$field")
  done < <(_okf_spec_frontmatter_fields)

  # Guards the extraction above: were §4's sentence reworded past it, every
  # check below would vanish and this test would pass having asserted nothing.
  # Bailing rather than continuing, because "${fields[@]}" on an empty array
  # aborts the whole run under `set -u` on bash 3.2.
  if [ "${#fields[@]}" -eq 0 ]; then
    _fail "SPEC.md §4 lists the fields the shell reads" \
      "extracted no field names from §4's \"Fields the shell reads\" sentence"
    return 1
  fi

  local out
  out="$(_okf_frontmatter_probe "" \
    "$FIXTURES_DIR/concepts/src/route/RouteRegistry.md" "${fields[@]}")"
  assert_eq "0" "$(_okf_frontmatter_status "$out")" \
    "read_frontmatter accepts a concept carrying a §4 frontmatter block"

  local expected
  for field in "${fields[@]}"; do
    case "$out" in
      *"missing:$field"*)
        _fail "bin/okf exposes SPEC.md §4's $field" \
          "read_frontmatter fills no variable for it, so §4 lists a field that" \
          "nothing in bin/okf reads"
        continue
        ;;
    esac
    case "$field" in
      type) expected="Class" ;;
      resource) expected="/src/route/RouteRegistry.java" ;;
      status) expected="stable" ;;
      stale_after) expected="2026-11-24T00:00:00Z" ;;
      generated.at) expected="2026-08-26T14:02:11Z" ;;
      generated.by) expected="claude-code/opus-5" ;;
      # Both entries, in document order: SPEC.md §8 never strips one, so the
      # newest is not the only one a caller gets to see.
      "verified[].at") expected="$(printf '2026-08-26T15:00:00Z\n2026-08-26T16:40:00Z')" ;;
      code.content_hash)
        expected="sha256:e36b6b992dae1387b2cc894187355b3556b3ca483e4670efa7283ce08c88fa19"
        ;;
      code.tier) expected="2" ;;
      code.symbol) expected="com.kairos.route.RouteRegistry" ;;
      code.language) expected="java" ;;
      *)
        _fail "this test knows what SPEC.md §4's $field should read as" \
          "§4 lists a field the fixture concept and this test say nothing about" \
          "— add it to tests/fixtures/concepts/src/route/RouteRegistry.md and" \
          "to the expected values here"
        continue
        ;;
    esac
    assert_eq "$expected" "$(_okf_frontmatter_field "$out" "$field")" \
      "okf reads $field out of a concept's frontmatter"
  done
  return 0
}

# The other half of reading §4: where the reader has to stop. Every line in the
# Boundaries fixture that looks like one of these fields is one it must not be
# read as — a `sources:` entry's `resource:`, a `symbol:` nested deeper inside
# the `code:` block, an unindented `tier:` written after that block closed — and
# each impostor sits above the real field it imitates, so a reader that took it
# would take it in preference rather than be outvoted by first-one-wins.
test_okf_frontmatter_reader_stops_where_spec_says_it_stops() {
  local concept="$FIXTURES_DIR/concepts/src/route/Boundaries.md" out
  out="$(_okf_frontmatter_probe "" "$concept" \
    resource status stale_after generated.at generated.by "verified[].at" \
    code.content_hash code.tier code.symbol code.language)"

  assert_eq "0" "$(_okf_frontmatter_status "$out")" \
    "read_frontmatter accepts the boundaries concept"

  # §4: `sources` is external references and never a restatement of `resource`,
  # so the indented `resource:` inside that list is not the concept's own. The
  # trailing `# comment` on the real one is not part of the path either — YAML
  # ends an unquoted scalar at a `#` with whitespace in front of it.
  assert_eq "/src/route/Boundaries.java" "$(_okf_frontmatter_field "$out" resource)" \
    "a sources[] entry's resource is not read as the concept's resource"

  # A top-level key ends the block above it, so `status:` written after the
  # `code:` block is the concept's status; and the first line naming a value
  # wins, so the second `status:` further down does not replace it. Two keys of
  # one name is malformed YAML with no defined meaning — this is bin/okf's
  # documented choice for it, and the same one §4 makes for `code.X`.
  assert_eq "stable" "$(_okf_frontmatter_field "$out" status)" \
    "a top-level key after the code: block is read, and the first one wins"

  # §4's extraction rule is `^  X: ` inside the `code:` block — exactly two
  # spaces — so neither the unindented `tier:` written after the block nor the
  # `symbol:` and `tier:` of a mapping nested a level deeper inside it is a
  # value of that field.
  assert_eq "" "$(_okf_frontmatter_field "$out" code.tier)" \
    "an unindented tier: after the code: block is not code.tier"
  assert_eq "" "$(_okf_frontmatter_field "$out" code.symbol)" \
    "a symbol: nested a level deeper inside the code: block is not code.symbol"
  # The `code:` header carries a comment, so this also says the comment did not
  # stop the bare header opening its block; and a whole-line comment sits inside
  # that block, above `content_hash:`, so the hash below says the comment did
  # not end the block either.
  assert_eq "java" "$(_okf_frontmatter_field "$out" code.language)" \
    "a deeper mapping inside the code: block neither ends it nor supplies its scalars"
  # Quoted, and with a comment after the closing quote: the quotes go, the
  # comment goes, and what is left is what `okf hash` has to match for SPEC.md
  # §8 to call the concept undrifted.
  assert_eq "sha256:52f70d8e08c013253274deae575fa6f3e725ed5bd9ae6705c4b15714b9119645" \
    "$(_okf_frontmatter_field "$out" code.content_hash)" \
    "the two-space content_hash is read and the four-space one above it is not"

  # `generated.at` is read by the same rule, so a deeper `at:` nested under
  # `generated:` is not it.
  assert_eq "2026-08-26T14:02:11Z" "$(_okf_frontmatter_field "$out" generated.at)" \
    "an at: nested deeper under generated: is not generated.at"
  assert_eq "claude-code/opus-5" "$(_okf_frontmatter_field "$out" generated.by)" \
    "generated.by is read from the same block"

  # A verified entry names its `at` on the `-` line or on one of the lines after
  # it, whichever comes first. An entry naming none contributes no timestamp,
  # and an `at:` nested deeper inside an entry that has already named one
  # belongs to something else.
  #
  # This fixture writes those entries flush left, which is the same document as
  # §4's indented example and what most YAML writers emit. Read as top-level
  # keys they would end the block on its first entry, and a concept a human has
  # reviewed would come back with no verified timestamps at all.
  #
  # Its second entry buries an `at:` in a nested mapping and another in a nested
  # list, both above the one that is really the entry's. Only a reader that
  # knows which column the entry's own keys are in gets that entry right. Its
  # last entry names `at` twice, which is one entry however malformed, so it
  # contributes the first of the two and no more.
  assert_eq "$(printf '2026-08-27T09:00:00Z\n2026-08-27T10:00:00Z\n2026-08-27T11:00:00Z')" \
    "$(_okf_frontmatter_field "$out" "verified[].at")" \
    "verified[].at is one timestamp per entry that names one, and nothing else"

  assert_eq "" "$(_okf_frontmatter_field "$out" stale_after)" \
    "a field the concept does not declare reads as absent"
  return 0
}

# A concept that declares almost nothing is read, not refused: the fields it
# leaves out are absent rather than an error, because SPEC.md §5's Tier 0 stub
# is a concept with frontmatter and little else.
test_okf_frontmatter_reader_leaves_absent_fields_empty() {
  local concept="$FIXTURES_DIR/concepts/src/route/RouteSource.md" out
  out="$(_okf_frontmatter_probe \
    "$FIXTURES_DIR/concepts/src/route/RouteRegistry.md" "$concept" \
    type resource status stale_after generated.at generated.by "verified[].at" \
    code.content_hash code.tier code.symbol code.language)"

  assert_eq "0" "$(_okf_frontmatter_status "$out")" \
    "read_frontmatter accepts a concept declaring only type and resource"
  assert_eq "Interface" "$(_okf_frontmatter_field "$out" type)" \
    "the fields a sparse concept does declare are read"
  assert_eq "/src/route/RouteSource.java" "$(_okf_frontmatter_field "$out" resource)" \
    "a sparse concept's resource is read"

  local field
  for field in status stale_after generated.at generated.by "verified[].at" \
    code.content_hash code.tier code.symbol code.language; do
    assert_eq "" "$(_okf_frontmatter_field "$out" "$field")" \
      "$field reads as absent, and not as the last concept's value"
  done
  return 0
}

# SPEC.md §4's own example quotes some values and not others, and a concept
# written on Windows arrives with CRLF line endings and a UTF-8 BOM. Neither
# changes what the block says, and a reader that let either change what it read
# would report a concept drifted, or orphaned, on the strength of punctuation.
test_okf_frontmatter_reader_reads_quoted_crlf_frontmatter() {
  local concept="$FIXTURES_DIR/concepts/src/route/Legacy.md" out
  out="$(_okf_frontmatter_probe "" "$concept" \
    type resource status generated.by "verified[].at" \
    code.content_hash code.tier code.symbol)"

  assert_eq "0" "$(_okf_frontmatter_status "$out")" \
    "read_frontmatter accepts a concept written with CRLF and a BOM"
  assert_eq "Class" "$(_okf_frontmatter_field "$out" type)" \
    "the first key is read through a UTF-8 BOM"
  assert_eq "/src/route/Legacy.java" "$(_okf_frontmatter_field "$out" resource)" \
    "a double-quoted resource is read without its quotes"
  assert_eq "stable" "$(_okf_frontmatter_field "$out" status)" \
    "a single-quoted value is read without its quotes"
  assert_eq "claude-code/opus-5" "$(_okf_frontmatter_field "$out" generated.by)" \
    "a quoted value inside a nested block is read without its quotes"
  assert_eq "2026-08-26T16:40:00Z" "$(_okf_frontmatter_field "$out" "verified[].at")" \
    "a quoted verified entry's at is read without its quotes, and without a CR"
  assert_eq "sha256:795f83987409387de7865a9e6bf1616535a9abee05abf3a32be590dd3e23c656" \
    "$(_okf_frontmatter_field "$out" code.content_hash)" \
    "a quoted content_hash is read without its quotes"
  assert_eq "0" "$(_okf_frontmatter_field "$out" code.tier)" \
    "a quoted tier is read without its quotes"
  assert_eq "com.kairos.route.Legacy" "$(_okf_frontmatter_field "$out" code.symbol)" \
    "a CRLF line's value keeps no carriage return"
  return 0
}

# What is not a concept is refused, and refusing leaves nothing of the last
# concept behind. A caller looping over files takes the fields as read; values
# left standing from the file before would attribute one concept's hash, or one
# concept's resource, to the next file along.
test_okf_frontmatter_reader_refuses_what_is_not_a_concept() {
  local -a fields=()
  local field
  while IFS= read -r field; do
    [ -n "$field" ] && fields+=("$field")
  done < <(_okf_spec_frontmatter_fields)

  if [ "${#fields[@]}" -eq 0 ]; then
    _fail "SPEC.md §4 lists the fields the shell reads" \
      "extracted no field names from §4's \"Fields the shell reads\" sentence"
    return 1
  fi

  local route="$FIXTURES_DIR/concepts/src/route"
  _okf_frontmatter_assert_not_a_concept "$route/README.md" \
    "prose with no frontmatter" "${fields[@]}"
  # An interrupted /okf-generate: the block opens, names fields, and stops. What
  # it says was on its way to being superseded, and reporting it as read cleanly
  # is how a half-written content_hash becomes a drift report nobody can explain.
  _okf_frontmatter_assert_not_a_concept "$route/Interrupted.md" \
    "a frontmatter block that is never closed" "${fields[@]}"
  _okf_frontmatter_assert_not_a_concept "$route/NoSuchConcept.md" \
    "a file that is not there" "${fields[@]}"
  _okf_frontmatter_assert_not_a_concept "$route" \
    "a directory" "${fields[@]}"
  return 0
}

# bin/okf's own writing of one field: `status=<rc>` for what
# write_frontmatter_field returned and `error=<reason>` for what it left in
# OKF_FRONTMATTER_ERROR.
#
# Obtained by sourcing bin/okf and calling the function directly, the way
# _okf_frontmatter_probe calls read_frontmatter and for the same reason:
# SPEC.md §7 defines no subcommand that sets a field, and a flag invented to
# test with would be CLI surface the spec has not got. The names used here —
# write_frontmatter_field, and OKF_FRONTMATTER_ERROR — are the contract this
# item owes `check --stamp` and `verify`, so a rename that breaks them should
# fail loudly.
_okf_frontmatter_write() { # $1 = concept, $2 = field, $3 = value
  local probe="$HARNESS_STATE/okf-frontmatter-write.sh"
  if [ ! -f "$probe" ]; then
    cat > "$probe" <<'PROBE'
#!/usr/bin/env bash
okf_script="$1"
shift
# shellcheck source=/dev/null
. "$okf_script"

rc=0
write_frontmatter_field "$1" "$2" "$3" || rc=$?
printf 'status=%s\n' "$rc"
printf 'error=%s\n' "$OKF_FRONTMATTER_ERROR"
PROBE
    chmod +x "$probe" || return 1
  fi
  "$probe" "$TOOLKIT_ROOT/bin/okf" "$@" 2>&1
}

_okf_write_status() { # $1 = probe output
  printf '%s\n' "$1" | sed -n 's/^status=//p'
}

_okf_write_error() { # $1 = probe output
  printf '%s\n' "$1" | sed -n 's/^error=//p'
}

# Every byte of a concept, with the lines named by the given literal prefixes
# left out, in a form two files can be compared as strings.
#
# This is what "byte for byte" is asserted with. Every line is printed exactly
# as read — its CR, its BOM, its trailing comment, its indentation — and the
# marker at the end says whether the file ended with a newline, which a `$(...)`
# would otherwise strip from both sides and so could never report. Omitting the
# line the writer was asked to set is what leaves the assertion saying "and
# nothing else changed", which is the whole claim: SPEC.md §1 puts a concept's
# unknown keys and its prose on Claude's side of the division of labour, and a
# writer that reflowed either would be the shell overwriting work it cannot
# reproduce.
_okf_concept_bytes() { # $1 = path, $2.. = literal line prefixes to omit
  local path="$1"
  shift
  local line prefix final=nl partial=0 emit
  while true; do
    if IFS= read -r line; then
      partial=0
    else
      # A last line with no newline after it: still a line, and the fact that
      # nothing followed it is part of what this has to report.
      [ -n "$line" ] || break
      partial=1
      final=no-nl
    fi
    emit=1
    # `${1+"$@"}` because an unquoted `"$@"` with no positional parameters is
    # an unbound variable under `set -u` on bash 3.2, and this is called with
    # no prefixes at all whenever a whole file is being compared.
    for prefix in ${1+"$@"}; do
      case "$line" in "$prefix"*) emit=0 ;; esac
    done
    [ "$emit" -eq 0 ] || printf '%s\n' "$line"
    [ "$partial" -eq 0 ] || break
  done < "$path"
  printf '[[eof:%s]]\n' "$final"
}

# The first line of a concept starting with a literal prefix, exactly as it is
# written in the file. Used to say that one particular line is still there and
# still says what it said — an unknown key that survived — where
# _okf_concept_bytes says that everything else did.
_okf_concept_line() { # $1 = path, $2 = literal line prefix
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$2"*)
        printf '%s\n' "$line"
        return 0
        ;;
    esac
  done < "$1"
  return 0
}

# The writer owed by PLAN.md's Phase 4, on the field that already exists: it is
# rewritten where it stood, and the rest of the concept is not touched.
#
# The fixture is the same one the reader is tested against, which is the point:
# it carries keys SPEC.md §4 defines and bin/okf has no variable for (`title`,
# `tags`, `sources`), and keys inside the `code:` block in the same position
# (`kind`, `members`, `commit`). PLAN.md asks that an unknown top-level key and
# an unknown key inside `code:` both survive a rewrite byte for byte, and they
# are named individually below as well as covered by the whole-file comparison.
_okf_writer_sets_a_field_in_place() {
  local concept="src/route/RouteRegistry.md"
  local pristine="$FIXTURES_DIR/concepts/$concept"
  local digest="sha256:0000000000000000000000000000000000000000000000000000000000000000"
  local out

  out="$(_okf_frontmatter_write "$concept" code.content_hash "$digest")"
  assert_eq "0" "$(_okf_write_status "$out")" \
    "write_frontmatter_field sets code.content_hash"
  assert_eq "" "$(_okf_write_error "$out")" \
    "a write that succeeded leaves no error behind"

  # Read back with bin/okf's own reader: a value written where the reader does
  # not look is a write that silently did nothing.
  local read_out
  read_out="$(_okf_frontmatter_probe "" "$concept" \
    type resource status stale_after generated.at generated.by "verified[].at" \
    code.content_hash code.tier code.symbol code.language)"
  assert_eq "$digest" "$(_okf_frontmatter_field "$read_out" code.content_hash)" \
    "the written code.content_hash is what read_frontmatter reads back"
  assert_eq "2" "$(_okf_frontmatter_field "$read_out" code.tier)" \
    "the field beside it in the code: block is unchanged"
  assert_eq "stable" "$(_okf_frontmatter_field "$read_out" status)" \
    "a top-level field is unchanged"
  assert_eq "$(printf '2026-08-26T15:00:00Z\n2026-08-26T16:40:00Z')" \
    "$(_okf_frontmatter_field "$read_out" "verified[].at")" \
    "both verified entries survive, as SPEC.md §8 requires"

  # The two PLAN.md names outright, before the whole-file comparison says the
  # same thing about every other line.
  assert_eq "title: RouteRegistry" "$(_okf_concept_line "$concept" "title:")" \
    "an unknown top-level key survives the rewrite"
  assert_eq "  kind: class" "$(_okf_concept_line "$concept" "  kind:")" \
    "an unknown key inside the code: block survives the rewrite"

  assert_eq "$(_okf_concept_bytes "$pristine" "  content_hash:")" \
    "$(_okf_concept_bytes "$concept" "  content_hash:")" \
    "every byte but the content_hash line is exactly as it was"
  return 0
}

test_okf_frontmatter_writer_sets_a_field_in_place() {
  with_fixture_repo concepts _okf_writer_sets_a_field_in_place
}

# The other half: a field the concept has not got, and a `code:` block it has
# not got either. Both are inserted where SPEC.md §4's extraction rule looks
# for them, and again nothing else moves.
_okf_writer_inserts_absent_fields() {
  local concept="src/route/RouteSource.md"
  local pristine="$FIXTURES_DIR/concepts/$concept"
  local out

  out="$(_okf_frontmatter_write "$concept" status draft)"
  assert_eq "0" "$(_okf_write_status "$out")" \
    "write_frontmatter_field inserts an absent top-level field"

  out="$(_okf_frontmatter_write "$concept" code.tier 0)"
  assert_eq "0" "$(_okf_write_status "$out")" \
    "write_frontmatter_field opens the code: block a concept has not got"

  local read_out
  read_out="$(_okf_frontmatter_probe "" "$concept" \
    type resource status code.tier)"
  assert_eq "0" "$(_okf_frontmatter_status "$read_out")" \
    "the rewritten concept is still a concept"
  assert_eq "draft" "$(_okf_frontmatter_field "$read_out" status)" \
    "the inserted top-level field is read back"
  assert_eq "0" "$(_okf_frontmatter_field "$read_out" code.tier)" \
    "the field inserted into the new code: block is read back"
  assert_eq "Interface" "$(_okf_frontmatter_field "$read_out" type)" \
    "the fields the concept already declared are unchanged"

  # Two spaces, exactly, because that is what §4's extraction rule matches and
  # what read_frontmatter above implements.
  assert_eq "  tier: 0" "$(_okf_concept_line "$concept" "  tier:")" \
    "the inserted code.X sits at exactly two spaces"
  assert_eq "code:" "$(_okf_concept_line "$concept" "code:")" \
    "the block it went into is a bare header"

  assert_eq "$(_okf_concept_bytes "$pristine")" \
    "$(_okf_concept_bytes "$concept" "status:" "code:" "  tier:")" \
    "insertion adds its lines and changes nothing else"
  return 0
}

test_okf_frontmatter_writer_inserts_absent_fields() {
  with_fixture_repo concepts _okf_writer_inserts_absent_fields
}

# Where the writer puts a field has to be where the reader takes it from, so
# the awkward concept the reader is held to is the one the writer is held to as
# well. Every line in it that looks like one of these fields is one neither of
# them may treat as one.
_okf_writer_writes_where_the_reader_reads() {
  local concept="src/route/Boundaries.md"
  local pristine="$FIXTURES_DIR/concepts/$concept"
  local out

  # `code.symbol` is absent from this block — the `symbol:` lines in it are a
  # `code.members` entry and a mapping nested one level deeper, both at four
  # spaces — so this inserts rather than replaces, and inserting it anywhere
  # below those two would be writing a field the reader still would not read.
  out="$(_okf_frontmatter_write "$concept" code.symbol com.kairos.route.Boundaries)"
  assert_eq "0" "$(_okf_write_status "$out")" \
    "write_frontmatter_field sets code.symbol on the boundaries concept"

  # Two top-level `status:` lines, which is malformed YAML with no defined
  # meaning: the reader takes the first, so the writer must rewrite that one.
  out="$(_okf_frontmatter_write "$concept" status draft)"
  assert_eq "0" "$(_okf_write_status "$out")" \
    "write_frontmatter_field sets the first of two status: lines"

  local read_out
  read_out="$(_okf_frontmatter_probe "" "$concept" \
    status code.symbol code.tier code.language code.content_hash)"
  assert_eq "com.kairos.route.Boundaries" \
    "$(_okf_frontmatter_field "$read_out" code.symbol)" \
    "the inserted code.symbol is what read_frontmatter reads back"
  assert_eq "draft" "$(_okf_frontmatter_field "$read_out" status)" \
    "the rewritten status is what read_frontmatter reads back"
  assert_eq "java" "$(_okf_frontmatter_field "$read_out" code.language)" \
    "the code: block's own scalars are untouched"
  assert_eq "" "$(_okf_frontmatter_field "$read_out" code.tier)" \
    "a field the reader does not read is still not read after the write"

  # The impostors are still there, still saying what they said: the writer read
  # them the way the reader does and left them alone.
  assert_eq "    symbol: com.kairos.route.OldBoundaries" \
    "$(_okf_concept_line "$concept" "    symbol:")" \
    "a symbol: nested deeper inside the code: block is not rewritten"
  assert_eq "status: draft" "$(_okf_concept_line "$concept" "status: draft")" \
    "the second status: line is left where it was"

  # The same three lines omitted from both sides, spelled out in full rather
  # than as prefixes: this concept has a second `status:` and a `  symbol:` of
  # its own further down, and a prefix wide enough to catch the line that
  # changed would take those with it and quietly stop comparing them.
  assert_eq \
    "$(_okf_concept_bytes "$pristine" \
      "status: stable" "status: draft" "  symbol: com.kairos.route.Boundaries")" \
    "$(_okf_concept_bytes "$concept" \
      "status: stable" "status: draft" "  symbol: com.kairos.route.Boundaries")" \
    "the rest of the awkward concept is byte for byte as it was"
  return 0
}

test_okf_frontmatter_writer_writes_where_the_reader_reads() {
  with_fixture_repo concepts _okf_writer_writes_where_the_reader_reads
}

# A concept written on Windows stays written on Windows. The line the writer
# replaces takes the line ending of the line it replaced, and every other byte
# — the UTF-8 BOM on line 1 included — comes through untouched. A writer that
# normalised either would rewrite every line of the file on the first field it
# was asked to set.
_okf_writer_keeps_crlf_and_a_bom() {
  local concept="src/route/Legacy.md"
  local pristine="$FIXTURES_DIR/concepts/$concept"
  local out

  out="$(_okf_frontmatter_write "$concept" code.tier 1)"
  assert_eq "0" "$(_okf_write_status "$out")" \
    "write_frontmatter_field sets a field in a CRLF concept"

  assert_eq "$(printf '  tier: 1\r')" "$(_okf_concept_line "$concept" "  tier:")" \
    "the rewritten line keeps the CRLF ending of the line it replaced"
  assert_eq "$(printf '\xef\xbb\xbf---\r')" "$(_okf_concept_line "$concept" "$(printf '\xef\xbb\xbf')")" \
    "the UTF-8 BOM on line 1 is still there"

  local read_out
  read_out="$(_okf_frontmatter_probe "" "$concept" code.tier code.symbol)"
  assert_eq "1" "$(_okf_frontmatter_field "$read_out" code.tier)" \
    "the written value is read back without a carriage return"
  assert_eq "com.kairos.route.Legacy" \
    "$(_okf_frontmatter_field "$read_out" code.symbol)" \
    "the rest of the CRLF block still reads"

  assert_eq "$(_okf_concept_bytes "$pristine" "  tier:")" \
    "$(_okf_concept_bytes "$concept" "  tier:")" \
    "every other byte of the CRLF concept is as it was"
  return 0
}

test_okf_frontmatter_writer_keeps_crlf_and_a_bom() {
  with_fixture_repo concepts _okf_writer_keeps_crlf_and_a_bom
}

# SPEC.md §4's formatting contract is what the shell reads by, but a concept is
# also YAML that OKF's own readers parse. A value that would not survive both
# readings is quoted; one that could not survive either is refused rather than
# written, because the field it would land in is `content_hash` — and a hash
# that reads back as something else is a concept reported drifted for ever.
_okf_writer_quotes_what_it_must() {
  local concept="src/route/RouteSource.md" out read_out value

  for value in "a value with spaces" "no" "trailing space " "with #hash" \
    "it's quoted" 'says "so"' 'back\slash' "-leading-dash" "a: b"; do
    out="$(_okf_frontmatter_write "$concept" code.symbol "$value")"
    assert_eq "0" "$(_okf_write_status "$out")" \
      "write_frontmatter_field writes [$value]"
    read_out="$(_okf_frontmatter_probe "" "$concept" code.symbol)"
    assert_eq "$value" "$(_okf_frontmatter_field "$read_out" code.symbol)" \
      "[$value] reads back exactly as it was written"
  done

  # A value carrying both kinds of quote has no spelling okf can read back:
  # escaping it means `\"` or `''`, and frontmatter_scalar undoes neither.
  out="$(_okf_frontmatter_write "$concept" code.symbol "it's \"both\"")"
  assert_eq "1" "$(_okf_write_status "$out")" \
    "a value carrying both kinds of quote is refused"
  assert_contains "$(_okf_write_error "$out")" "both kinds of quote" \
    "and the refusal says why"

  # §4: no multi-line or folded scalars in any field the shell reads, and no
  # tabs anywhere.
  out="$(_okf_frontmatter_write "$concept" code.symbol "$(printf 'one\ntwo')")"
  assert_eq "1" "$(_okf_write_status "$out")" \
    "a value spanning two lines is refused"
  out="$(_okf_frontmatter_write "$concept" code.symbol "$(printf 'one\ttwo')")"
  assert_eq "1" "$(_okf_write_status "$out")" \
    "a value containing a tab is refused"

  # `key:` with nothing after it is a block header, so writing an empty value
  # would write a structure rather than an empty field.
  out="$(_okf_frontmatter_write "$concept" code.symbol "")"
  assert_eq "1" "$(_okf_write_status "$out")" \
    "an empty value is refused"
  return 0
}

test_okf_frontmatter_writer_quotes_what_it_must() {
  with_fixture_repo concepts _okf_writer_quotes_what_it_must
}

# What is not a concept is not edited, and neither is a line that is not a
# field. Every refusal below has to leave the file byte for byte as it was:
# a writer that truncated a file it then decided against would destroy the very
# half-written concept it was refusing to touch.
_okf_writer_refuses_what_it_must() {
  local out before

  before="$(_okf_concept_bytes src/route/README.md)"
  out="$(_okf_frontmatter_write src/route/README.md status draft)"
  assert_eq "1" "$(_okf_write_status "$out")" \
    "prose with no frontmatter is refused"
  assert_contains "$(_okf_write_error "$out")" "carries no frontmatter block" \
    "and the refusal says why"
  assert_eq "$before" "$(_okf_concept_bytes src/route/README.md)" \
    "the refused file is byte for byte as it was"

  before="$(_okf_concept_bytes src/route/Interrupted.md)"
  out="$(_okf_frontmatter_write src/route/Interrupted.md status draft)"
  assert_eq "1" "$(_okf_write_status "$out")" \
    "a frontmatter block that is never closed is refused"
  assert_eq "$before" "$(_okf_concept_bytes src/route/Interrupted.md)" \
    "the interrupted concept is byte for byte as it was"

  out="$(_okf_frontmatter_write src/route/NoSuchConcept.md status draft)"
  assert_eq "1" "$(_okf_write_status "$out")" \
    "a file that is not there is refused"
  out="$(_okf_frontmatter_write src/route status draft)"
  assert_eq "1" "$(_okf_write_status "$out")" \
    "a directory is refused"

  # Overwriting a block header with a scalar strands every line under it, and
  # a `verified:` holding `- ` items is a list: appending an entry to it is
  # SPEC.md §7's `okf verify` and not this.
  before="$(_okf_concept_bytes src/route/RouteRegistry.md)"
  out="$(_okf_frontmatter_write src/route/RouteRegistry.md code x)"
  assert_eq "1" "$(_okf_write_status "$out")" \
    "a field whose line is a bare block header is refused"
  assert_contains "$(_okf_write_error "$out")" "opens a block" \
    "and the refusal says why"
  out="$(_okf_frontmatter_write src/route/RouteRegistry.md verified.at 2026-01-01T00:00:00Z)"
  assert_eq "1" "$(_okf_write_status "$out")" \
    "a field inside a block of list entries is refused"
  assert_contains "$(_okf_write_error "$out")" "is a list" \
    "and the refusal says why"
  assert_eq "$before" "$(_okf_concept_bytes src/route/RouteRegistry.md)" \
    "neither refusal touched the concept"

  # Names that are not field names: nothing here is written into a file, but
  # each would be built into a pattern or into the line itself.
  local name
  for name in "" "2tier" "st atus" "code.*" "a.b.c"; do
    out="$(_okf_frontmatter_write src/route/RouteRegistry.md "$name" x)"
    assert_eq "1" "$(_okf_write_status "$out")" \
      "[$name] is refused as a field name"
  done
  assert_eq "$before" "$(_okf_concept_bytes src/route/RouteRegistry.md)" \
    "and none of them touched the concept either"
  return 0
}

test_okf_frontmatter_writer_refuses_what_it_must() {
  with_fixture_repo concepts _okf_writer_refuses_what_it_must
}

# ---------------------------------------------------------------------------
# okf check (SPEC.md §8)
# ---------------------------------------------------------------------------

# okf check's stdout, its stderr and its exit status, kept apart rather than
# folded into one stream. SPEC.md §8 gives each of the three a job — findings on
# stdout, a status that is always 0, and warnings that must stay out of both —
# and a helper that ran them together could not tell a finding from a warning
# about a file it could not read.
OKF_CHECK_OUT=""
OKF_CHECK_ERR=""
OKF_CHECK_RC=0
_okf_check() { # $1.. = okf arguments
  local stderr="$HARNESS_STATE/okf-check-stderr"
  : > "$stderr"
  OKF_CHECK_OUT="$("$TOOLKIT_ROOT/bin/okf" "$@" 2> "$stderr")"
  OKF_CHECK_RC=$?
  OKF_CHECK_ERR="$(cat "$stderr" 2> /dev/null)"
  return 0
}

# okf check exits 0 and its stdout is exactly this.
#
# The status is asserted on every call rather than once at the end, because
# SPEC.md §8's "always exits 0" is the promise a CI job branches on: it has to
# hold over a clean bundle, a drifted one, and every state in between that these
# probes put the fixture into.
#
# Exactly, and not a substring: `drifted: src/route/Legacy.md` contains nothing
# of `drifted: src/route/RouteRegistry.md`, but a listing checked by substring
# passes on a run that reported three concepts when one had changed — and a
# check whose whole use is naming the files to re-read cannot be allowed to name
# extra ones.
_okf_assert_check() { # $1 = expected stdout, $2 = description, $3.. = okf arguments
  local expected="$1" what="$2"
  shift 2
  _okf_check "$@"
  if [ "$OKF_CHECK_RC" -ne 0 ]; then
    local -a detail=("okf $* exited $OKF_CHECK_RC" \
      "SPEC.md §8: plain okf check always exits 0 — CI warns, never gates" "stderr:")
    local line
    while IFS= read -r line; do detail+=("$line"); done < <(_detail_lines "$OKF_CHECK_ERR")
    _fail "$what" "${detail[@]}"
    return 1
  fi
  assert_eq "$expected" "$OKF_CHECK_OUT" "$what"
}

# SPEC.md §8's drift rule over tests/fixtures/concepts, whose concepts are all
# committed carrying the true sha256 of the sources beside them.
_okf_check_drift_probe() {
  local registry="drifted: src/route/RouteRegistry.md"
  local legacy="drifted: src/route/Legacy.md"
  local boundaries="drifted: src/route/Boundaries.md"

  # Nothing has been touched, so nothing has drifted. An empty listing exiting
  # 0, not an error and not a "0 drifted" line: a bundle in step with its
  # sources is the ordinary state, and something to read has to mean something
  # to do.
  #
  # It is also where three ways of reading a concept wrongly would show up at
  # once, each of which reports drift in a bundle that has none:
  #
  #   * src/route/Boundaries.md carries a `code.supersedes.content_hash` of all
  #     zeroes, one level deeper than SPEC.md §4's extraction rule reaches, and
  #     its real `content_hash` line ends in a trailing `# regenerate after the
  #     refactor` comment.
  #   * src/route/Interrupted.md opens a frontmatter block it never closes and
  #     puts an all-zero hash in it. It is not a concept, and a reader that took
  #     it for one would report a file nobody can act on.
  #   * src/route/Legacy.md is written with CRLF line endings and a UTF-8 BOM,
  #     and quotes every value.
  _okf_assert_check '' "a bundle whose concepts all match their sources prints nothing, exiting 0" \
    check

  # One source changed, one concept named. The other four concepts in the
  # directory are the check that this is a comparison per concept and not a
  # verdict on the bundle.
  printf '// touched\n' >> src/route/RouteRegistry.java
  _okf_assert_check "$registry" \
    "a source whose bytes have changed drifts its concept, and only its concept" \
    check
  git checkout -q -- src/route/RouteRegistry.java
  _okf_assert_check '' "and stops being drifted when the source goes back" check

  # Content and not mtime, which is the whole reason SPEC.md §4 stores a digest
  # rather than a timestamp: a checkout, a `cp -R` or a rebase rewrites every
  # mtime in the tree without changing a byte, and a check built on them would
  # report the entire bundle drifted after any of the three. Every fixture copy
  # gets here through `cp -R`, so this is also the check that the whole suite is
  # not passing by accident.
  touch src/route/RouteRegistry.java
  _okf_assert_check '' "a source touched but not edited has not drifted" check

  # The same rule reaching the two concepts written to be hard to read. Legacy.md
  # is CRLF-with-a-BOM and quotes its `content_hash`; Boundaries.md hides its
  # behind a trailing comment and a same-named decoy. Both were clean above,
  # which only says they were not misread into drift — this says they are read
  # at all, rather than skipped and so clean whatever happens to their source.
  printf '// touched\n' >> src/route/Legacy.java
  _okf_assert_check "$legacy" \
    "a concept written with CRLF, a BOM and quoted values is compared like any other" \
    check
  printf '// touched\n' >> src/route/Boundaries.java
  _okf_assert_check "$boundaries
$legacy" \
    "and so is one whose content_hash carries a trailing comment" check

  # Every drifted concept, in git's order, which is the order `okf list` prints
  # its own listing in. One line per finding and no summary: a caller reads this
  # with `while read`, and a total on the end would be a path that names no file.
  printf '// touched\n' >> src/route/RouteRegistry.java
  _okf_assert_check "$boundaries
$legacy
$registry" \
    "every drifted concept is named, one per line, in the bundle's order" check

  # Twice, with nothing in between. SPEC.md §8 computes drift on demand from the
  # two files, so there is no cache to go stale and no first run that primes a
  # second — and a check that answered differently the second time would be one
  # nobody could act on.
  _okf_assert_check "$boundaries
$legacy
$registry" \
    "and the same run repeated says the same thing" check

  git checkout -q -- src/route/
  _okf_assert_check '' "restoring every source clears every finding" check
  return 0
}

test_okf_check_reports_drifted_concepts() {
  with_fixture_repo concepts _okf_check_drift_probe
}

# The concepts a drift check has nothing to say about. Each one is a way of
# manufacturing a finding out of a comparison that was never made — which is the
# expensive direction here, because every line of this listing is a file
# somebody is going to be sent to re-read.
_okf_check_silence_probe() {
  # A concept with no `code.content_hash` has never claimed to describe a
  # particular version of its source, so there is nothing for SPEC.md §8 to
  # compare. src/route/RouteSource.md declares almost nothing — no hash, no
  # `generated`, no `verified` — and its source is edited here to prove the
  # silence is the missing field and not an unchanged file.
  printf '// touched\n' >> src/route/RouteSource.java
  _okf_assert_check '' \
    "a concept that stores no content_hash is not drift, whatever its source does" \
    check
  git checkout -q -- src/route/RouteSource.java

  # A resource that is gone is an orphan, which is a different finding with a
  # different repair — the concept goes, or its `resource` is corrected — and
  # calling it drift would send somebody to re-read a file that is not there.
  # Checked against `okf list --orphans`, so this says the two listings account
  # for the concept the same way rather than only that check said something.
  rm -f src/route/RouteRegistry.java
  _okf_assert_check 'orphan: src/route/RouteRegistry.md' \
    "a concept whose resource has been deleted is an orphan, not drift" check
  _okf_assert_listing 'src/route/RouteRegistry.md' \
    "and okf list --orphans names the same concept" list --orphans
  git checkout -q -- src/route/RouteRegistry.java

  # SPEC.md §5 co-locates a concept beside its source, and concept_resource is
  # where okf decides which concepts this bundle answers for at all. A concept
  # naming a file in another directory is a nested bundle's, read from out
  # here — its `resource` is bundle-absolute against a root that is not this
  # one — so a hash that cannot match must still produce nothing.
  printf -- '---\ntype: Class\nresource: /README.md\ncode:\n  content_hash: "sha256:%s"\n---\n' \
    "0000000000000000000000000000000000000000000000000000000000000000" \
    > src/route/Elsewhere.md
  _okf_stage src/route/Elsewhere.md || return 1
  _okf_assert_check '' \
    "a concept whose resource is not co-located with it is not this bundle's to check" \
    check
  rm -f src/route/Elsewhere.md
  git rm -q --cached src/route/Elsewhere.md > /dev/null 2>&1

  # SPEC.md §6's `exclude`, asked of the source. A concept inside an excluded
  # tree is not this bundle's either, and the same run before and after the
  # setting is what says the listing moved because of the setting.
  printf '// touched\n' >> src/route/RouteRegistry.java
  _okf_assert_check 'drifted: src/route/RouteRegistry.md' \
    "the drifted concept is reported while nothing excludes it" check
  printf '{"bundle": {"exclude": ["**/route/**"]}}\n' > okf.json
  _okf_assert_check '' "and drops out when exclude covers its resource" check
  printf '{"bundle": {"include": ["lib/**"]}}\n' > okf.json
  _okf_assert_check '' "and when include no longer reaches it" check
  rm -f okf.json
  _okf_assert_check 'drifted: src/route/RouteRegistry.md' \
    "and comes back with the settings taken away again" check
  git checkout -q -- src/route/RouteRegistry.java

  # A concept written and never added is not in the bundle yet, which is the
  # rule `okf list --orphans` is already held to: scope is read out of git
  # throughout okf, and the two subcommands must not disagree about which
  # concepts exist. Pinned here as a decision rather than left as an accident,
  # because it is the one place `okf check` is stricter than `okf list
  # --missing`, whose has_concept asks the filesystem.
  #
  # `git add` is enough — no commit — which is what keeps the cost of the rule
  # at nothing: a concept written from its source this minute stores that
  # source's current digest and has no drift to find anyway.
  printf -- '---\ntype: Class\nresource: /src/route/RouteSource.java\ncode:\n  content_hash: "sha256:%s"\n---\n' \
    "0000000000000000000000000000000000000000000000000000000000000000" \
    > src/route/Untracked.md
  _okf_assert_check '' "an unstaged concept is not in the bundle yet, so it is not checked" \
    check
  _okf_stage src/route/Untracked.md || return 1
  _okf_assert_check 'drifted: src/route/Untracked.md' \
    "and is compared as soon as it is staged, with no commit needed" check
  rm -f src/route/Untracked.md
  git rm -q --cached src/route/Untracked.md > /dev/null 2>&1

  # A markdown file with no frontmatter is prose and not a concept, and one
  # whose block is never closed is a half-written concept — src/route/README.md
  # and src/route/Interrupted.md respectively. Neither is on any listing above,
  # which is only worth stating because Interrupted.md carries an all-zero
  # `content_hash` beside a `resource` that exists: read as a concept it would
  # be drifted on every run of every one of these checks.
  _okf_assert_check '' "the bundle is clean again once every source is restored" check
  return 0
}

test_okf_check_stays_silent_about_what_it_cannot_compare() {
  with_fixture_repo concepts _okf_check_silence_probe
}

# What okf cannot compare, it says so about — on stderr, and still exiting 0.
# A check that quietly stopped checking a concept would leave it looking checked
# for as long as nobody opened it, which is the one failure a drift report exists
# to prevent.
_okf_check_warning_probe() {
  local zeroes="0000000000000000000000000000000000000000000000000000000000000000"

  # A stored value that is not one of `okf hash`'s digests. It cannot be
  # compared, so it is not a finding; it is also not nothing, because the
  # concept it is written in can never be reported drifted until somebody fixes
  # it. Three spellings, each one somebody would plausibly write by hand.
  local bad
  for bad in "not-a-digest" "$zeroes" "sha256:deadbeef" "SHA256:$zeroes"; do
    printf -- '---\ntype: Class\nresource: /src/route/RouteSource.java\ncode:\n  content_hash: "%s"\n---\n' \
      "$bad" > src/route/Bad.md
    _okf_stage src/route/Bad.md || return 1
    _okf_assert_check '' "[$bad] is not compared, so it is not reported as drift" check
    assert_contains "$OKF_CHECK_ERR" "src/route/Bad.md" \
      "[$bad] is warned about on stderr, naming the concept"
    assert_contains "$OKF_CHECK_ERR" "okf hash src/route/RouteSource.java" \
      "[$bad] and the warning says how to put a real digest there"
  done

  # An upper-case digest of the very file the concept documents. It is the same
  # number spelled a way okf never writes, so it is warned about rather than
  # compared: case-folding it would be okf inventing a second spelling of its
  # own output, and comparing it as written would report the concept drifted on
  # every run against a source nobody had touched.
  local real upper
  real="$("$TOOLKIT_ROOT/bin/okf" hash src/route/RouteSource.java)"
  upper="sha256:$(printf '%s' "${real#sha256:}" | tr 'a-f' 'A-F')"
  printf -- '---\ntype: Class\nresource: /src/route/RouteSource.java\ncode:\n  content_hash: "%s"\n---\n' \
    "$upper" > src/route/Bad.md
  _okf_assert_check '' "an upper-case digest is warned about, not reported as drift" check
  assert_contains "$OKF_CHECK_ERR" "src/route/Bad.md" \
    "and the warning names the concept to restore"

  # The same concept, the same file, spelled the way `okf hash` prints it: clean,
  # and silent. Without this every check above would also pass on a reader that
  # had stopped comparing anything at all.
  printf -- '---\ntype: Class\nresource: /src/route/RouteSource.java\ncode:\n  content_hash: "%s"\n---\n' \
    "$real" > src/route/Bad.md
  _okf_assert_check '' "the same concept carrying okf hash's own digest is clean" check
  assert_eq "" "$OKF_CHECK_ERR" "and okf says nothing on stderr about it"

  # A resource that is there but is not a regular file falls between the two
  # listings — `okf list --orphans` sees something under that name, and this run
  # cannot take a sha256 of it — so it has to be said out loud here or not at
  # all.
  #
  # src/route/Bad.md is left in place carrying the digest above, because it is
  # the only concept in the fixture that stores one for RouteSource.java:
  # RouteSource.md stores none, and a concept with nothing to compare is quiet
  # about its resource whatever state the file is in.
  rm -f src/route/RouteSource.java
  if mkdir src/route/RouteSource.java > /dev/null 2>&1; then
    _okf_assert_check '' "a resource that has become a directory is not reported as drift" check
    assert_contains "$OKF_CHECK_ERR" "is not a regular file" \
      "it is warned about instead, so the concept is not silently skipped"
    rmdir src/route/RouteSource.java
  else
    _fail "a directory can be made in the fixture copy" "mkdir src/route/RouteSource.java failed"
  fi
  git checkout -q -- src/route/RouteSource.java

  # And a resource whose permissions have been taken away. Same reasoning: it is
  # there, so it is not an orphan, and okf cannot read it, so it cannot be
  # compared.
  if chmod 000 src/route/RouteSource.java > /dev/null 2>&1 \
    && [ ! -r src/route/RouteSource.java ]; then
    _okf_assert_check '' "a resource that cannot be read is not reported as drift" check
    assert_contains "$OKF_CHECK_ERR" "cannot read src/route/RouteSource.java" \
      "it is warned about too, naming the file okf could not open"

    # It is also the file the in-scope walk cannot read: ripgrep's `@Generated`
    # scan gives up on it and load_in_scope refuses to guess which sources a
    # generator wrote. That is SPEC.md §7's exit 1 for `okf list`, whose whole
    # answer is that one listing — and it is the status `okf check` must not
    # inherit, because SPEC.md §8 has plain check always exiting 0 and one
    # chmod'ed file turning "CI warns, never gates" into a failed build is
    # exactly what that line is against.
    #
    # So the missing set is dropped rather than half-reported — a short listing
    # of undocumented sources reads exactly like a well-documented repo — and
    # the two sets read out of the concepts themselves are unaffected.
    assert_contains "$OKF_CHECK_ERR" "no missing concepts are reported by this run" \
      "the missing set okf could not work out is reported absent, not reported short"
    printf '// touched\n' >> src/route/Legacy.java
    _okf_assert_check 'drifted: src/route/Legacy.md' \
      "and drift is still reported in full, since it is not read out of scope" check
    git checkout -q -- src/route/Legacy.java
  else
    # root reads anything, so the check cannot be made to hold there.
    _skip "a resource that cannot be read is warned about" \
      "chmod 000 does not make a file unreadable here"
  fi
  chmod 644 src/route/RouteSource.java > /dev/null 2>&1
  return 0
}

test_okf_check_warns_about_what_it_cannot_compare() {
  with_fixture_repo concepts _okf_check_warning_probe
}

# SPEC.md §8's two promises about plain `okf check`, asserted as the properties
# they are rather than as a consequence of one particular run: it never mutates
# a file, and it always exits 0.
_okf_check_promises_probe() {
  local marker=".okf-check-marker" before_status after_status touched

  # Drift in the bundle, plus a concept okf can only warn about, so the run has
  # every reason it will ever have to want to write something down — a stamp, a
  # cache, a repaired hash.
  printf '// touched\n' >> src/route/RouteRegistry.java
  printf -- '---\ntype: Class\nresource: /src/route/RouteSource.java\ncode:\n  content_hash: "not-a-digest"\n---\n' \
    > src/route/Bad.md
  _okf_stage src/route/Bad.md || return 1

  local before_registry before_bad
  before_registry="$(_okf_concept_bytes src/route/RouteRegistry.md)"
  before_bad="$(_okf_concept_bytes src/route/Bad.md)"

  # The marker is made last, so every file already in the copy is older than it
  # and anything `find -newer` turns up afterwards was written by the run under
  # test. `.git` is pruned: git's own index is refreshed by the `git status`
  # below, which is this probe's doing and not okf's.
  : > "$marker"
  before_status="$(git status --porcelain)"

  _okf_assert_check 'drifted: src/route/RouteRegistry.md' \
    "a bundle with drift in it and a concept okf can only warn about" check

  after_status="$(git status --porcelain)"
  assert_eq "$before_status" "$after_status" \
    "okf check leaves the work tree exactly as it found it"
  touched="$(find . -path ./.git -prune -o -type f -newer "$marker" -print | sort)"
  assert_eq "" "$touched" "and not one file in the copy was written to"
  assert_eq "$before_registry" "$(_okf_concept_bytes src/route/RouteRegistry.md)" \
    "the drifted concept is byte for byte as it was — no stale_after was stamped"
  assert_eq "$before_bad" "$(_okf_concept_bytes src/route/Bad.md)" \
    "and the concept okf warned about was not repaired behind the caller's back"

  # "Always exits 0" over every state these probes can put the bundle in. Drift
  # is the ordinary state of a repository between a refactor and the doc refresh
  # that follows it: a check that failed the build for it would be turned off
  # within a week, which is what SPEC.md §8's "CI warns, never gates" is about.
  local okf="$TOOLKIT_ROOT/bin/okf"
  assert_exit 0 "$okf" check
  rm -f src/route/RouteSource.java
  assert_exit 0 "$okf" check
  git checkout -q -- src/route/RouteSource.java
  git checkout -q -- src/route/RouteRegistry.java
  rm -f src/route/Bad.md
  git rm -q --cached src/route/Bad.md > /dev/null 2>&1
  assert_exit 0 "$okf" check
  assert_eq "" "$(last_output)" "and a clean bundle's run prints nothing at all"
  return 0
}

test_okf_check_never_writes_and_always_exits_zero() {
  with_fixture_repo concepts _okf_check_promises_probe
}

# The two sets `okf check` grew past drift: an in-scope source with no concept
# beside it, and a concept whose resource is gone. Each already has a listing of
# its own — `okf list --missing` and `okf list --orphans` — and folding them into
# one report is what lets a caller ask "what is wrong with this bundle" without
# first knowing which of the three questions to put.
_okf_check_missing_orphan_probe() {
  # tests/fixtures/concepts has a concept for every source and a source for
  # every concept, so the report starts empty and every finding below is one
  # this probe caused.
  _okf_assert_check '' \
    "a bundle with a concept for every source and a source for every concept is silent" \
    check

  # A source with nothing documenting it. `git add` and no commit, for
  # _okf_stage's reason: scope is `git ls-files`, which reads the index.
  printf 'package route;\n\nclass Dispatcher {}\n' > src/route/Dispatcher.java
  _okf_stage src/route/Dispatcher.java || return 1
  _okf_assert_check 'missing: src/route/Dispatcher.java' \
    "an in-scope source with no concept beside it is reported missing, naming the source" \
    check
  _okf_assert_listing 'src/route/Dispatcher.java' \
    "and okf list --missing names the same source" list --missing

  # A markdown file beside it that is not a concept does not cover it. This is
  # has_concept's rule rather than a second copy of it — which is why check
  # calls that function instead of deriving the name itself — but a README
  # written beside a source is common enough to be worth one line here saying
  # the report agrees with the listing about it.
  printf '# Dispatcher\n\nDesign notes, not a concept.\n' > src/route/Dispatcher.md
  _okf_assert_check 'missing: src/route/Dispatcher.java' \
    "a markdown file with no frontmatter beside it is prose, so the source is still missing" \
    check

  # A real concept does cover it, and does so before it is staged. This is the
  # asymmetry inside `okf check`, pinned as a decision: the missing set is
  # has_concept's filesystem question, so a concept /okf-generate has just
  # written takes its source off the listing at once, where the orphan set below
  # is git's and a concept has to be staged to be in the bundle at all. Asking
  # git's index here would report every freshly generated concept's source as
  # still undocumented, which is noise on the one listing whose whole use is
  # "what is left to write".
  printf -- '---\ntype: Class\nresource: /src/route/Dispatcher.java\n---\n' \
    > src/route/Dispatcher.md
  _okf_assert_check '' \
    "a concept written and not yet staged already takes its source off the missing set" \
    check
  _okf_stage src/route/Dispatcher.md || return 1
  _okf_assert_check '' "and staging it changes nothing" check

  # The other direction: the concept stays and the source goes. An orphan, and
  # not also a missing source — the source left the bundle with the file, so
  # there is nothing left to write a concept for, and sending somebody to
  # document a path that is not there is the one way this report wastes a
  # reader's time twice over.
  rm -f src/route/Dispatcher.java
  _okf_assert_check 'orphan: src/route/Dispatcher.md' \
    "a concept whose resource is deleted is an orphan, and the source is not also called missing" \
    check
  _okf_assert_listing 'src/route/Dispatcher.md' \
    "and okf list --orphans names the same concept" list --orphans
  rm -f src/route/Dispatcher.md
  git rm -q --cached src/route/Dispatcher.md src/route/Dispatcher.java > /dev/null 2>&1
  _okf_assert_check '' "with both taken away the bundle is clean again" check

  # A concept that stores no `code.content_hash` is still an orphan when its
  # resource goes. src/route/RouteSource.md declares no hash at all — it is the
  # concept the silence probe uses for "nothing to compare" — and it is exactly
  # the hand-written concept somebody deleted the source for.
  #
  # The order of the two questions inside the concept walk is the whole of
  # whether this holds: `okf list --orphans` never looks at `code.content_hash`,
  # so a check that skipped hashless concepts before asking where their resource
  # had gone would put this one on that listing and leave it off its own report.
  rm -f src/route/RouteSource.java
  _okf_assert_check 'orphan: src/route/RouteSource.md' \
    "a concept storing no content_hash is still an orphan once its resource goes" check
  _okf_assert_listing 'src/route/RouteSource.md' \
    "and okf list --orphans agrees, which is what that ordering protects" list --orphans
  git checkout -q -- src/route/RouteSource.java

  # All three kinds in one run, which is the report's whole point. Grouped
  # drifted, then missing, then orphan, each group in the bundle's own order —
  # and every line carrying its kind, so `grep '^orphan: '` gets the same answer
  # whatever order the groups come out in.
  printf '// touched\n' >> src/route/RouteRegistry.java
  printf 'package route;\n\nclass Dispatcher {}\n' > src/route/Dispatcher.java
  _okf_stage src/route/Dispatcher.java || return 1
  rm -f src/route/Legacy.java
  _okf_assert_check 'drifted: src/route/RouteRegistry.md
missing: src/route/Dispatcher.java
orphan: src/route/Legacy.md' \
    "drift, an undocumented source and an orphan are reported together, each labelled" \
    check

  git checkout -q -- src/route/
  rm -f src/route/Dispatcher.java
  git rm -q --cached src/route/Dispatcher.java > /dev/null 2>&1
  _okf_assert_check '' "and putting all three right clears the whole report" check

  # SPEC.md §6's settings decide the missing set exactly as they decide `okf
  # list`'s, because it is the same walk: a source the bundle does not reach is
  # not one the bundle is missing a concept for. The same run before and after
  # each setting is what says the listing moved because of the setting.
  printf 'package route;\n\nclass Dispatcher {}\n' > src/route/Dispatcher.java
  _okf_stage src/route/Dispatcher.java || return 1
  _okf_assert_check 'missing: src/route/Dispatcher.java' \
    "the undocumented source is reported while nothing excludes it" check
  printf '{"bundle": {"exclude": ["**/route/**"]}}\n' > okf.json
  _okf_assert_check '' "and drops out when exclude covers it" check
  printf '{"bundle": {"extensions": ["ts"]}}\n' > okf.json
  _okf_assert_check '' "and when extensions no longer reach it" check
  rm -f okf.json
  _okf_assert_check 'missing: src/route/Dispatcher.java' \
    "and comes back with the settings taken away again" check

  # A source git has never been told about is not in the bundle, so it is not
  # missing from it. Scope is read out of git throughout okf, and this is what
  # keeps a scratch file in a work tree off the listing /okf-generate walks.
  rm -f src/route/Dispatcher.java
  git rm -q --cached src/route/Dispatcher.java > /dev/null 2>&1
  printf 'package route;\n\nclass Scratch {}\n' > src/route/Scratch.java
  _okf_assert_check '' "an untracked source is not in the bundle, so it is not missing" check
  _okf_stage src/route/Scratch.java || return 1
  _okf_assert_check 'missing: src/route/Scratch.java' \
    "and is reported the moment git is told about it, with no commit needed" check
  rm -f src/route/Scratch.java
  git rm -q --cached src/route/Scratch.java > /dev/null 2>&1
  _okf_assert_check '' "the bundle is clean once more" check
  return 0
}

test_okf_check_reports_missing_and_orphan_concepts() {
  with_fixture_repo concepts _okf_check_missing_orphan_probe
}

# The invariant that makes one report out of three listings: what `okf check`
# prints under a kind is exactly what the listing for that kind prints. Asserted
# mechanically rather than left as a claim in a comment, because the report and
# the listings are separate code paths over separate sets — the missing half
# asks the filesystem and the orphan half asks git — and a caller who reads the
# report and then runs the listing on what it said must not be told two
# different things about the same file.
_okf_check_agrees_with_list_probe() {
  local okf="$TOOLKIT_ROOT/bin/okf"

  # All three states at once, so the comparison is over a report with something
  # in every group rather than over three empty listings agreeing.
  printf '// touched\n' >> src/route/RouteRegistry.java
  printf 'package route;\n\nclass Dispatcher {}\n' > src/route/Dispatcher.java
  _okf_stage src/route/Dispatcher.java || return 1
  rm -f src/route/Legacy.java

  _okf_check check
  if [ "$OKF_CHECK_RC" -ne 0 ]; then
    _fail "okf check exits 0 over a bundle in all three states" \
      "okf check exited $OKF_CHECK_RC"
    return 1
  fi

  local reported expected
  reported="$(printf '%s\n' "$OKF_CHECK_OUT" | sed -n 's/^missing: //p')"
  expected="$("$okf" list --missing)"
  assert_eq "$expected" "$reported" \
    "okf check's missing: lines are exactly okf list --missing's listing"

  reported="$(printf '%s\n' "$OKF_CHECK_OUT" | sed -n 's/^orphan: //p')"
  expected="$("$okf" list --orphans)"
  assert_eq "$expected" "$reported" \
    "and its orphan: lines are exactly okf list --orphans' listing"

  # No path under two kinds. A source deleted with its concept left behind is an
  # orphan and nothing else; a report that also called it missing would send a
  # reader to write a concept for a file that is gone.
  local duplicated
  duplicated="$(printf '%s\n' "$OKF_CHECK_OUT" | sed -n 's/^[a-z]*: //p' | sort | uniq -d)"
  assert_eq "" "$duplicated" "and no path is reported under two kinds at once"

  git checkout -q -- src/route/
  rm -f src/route/Dispatcher.java
  git rm -q --cached src/route/Dispatcher.java > /dev/null 2>&1
  return 0
}

test_okf_check_agrees_with_the_listings_it_folds_in() {
  with_fixture_repo concepts _okf_check_agrees_with_list_probe
}

# The flags SPEC.md §7 gives `okf check`, and what it does with a line it cannot
# carry out. Nothing here is about what the flags *do* — three later PLAN.md
# items own that — only that check is the subcommand answering for them, so a
# caller is never sent looking for a typo in a flag that is spelled right.
_okf_check_flag_probe() {
  local okf="$TOOLKIT_ROOT/bin/okf" flag out

  for flag in --strict --stamp --json; do
    out="$("$okf" check "$flag" 2>&1)" || true
    case "$out" in
      *"unknown flag"*)
        _fail "okf check $flag is a flag check knows about" \
          "check rejected it as unknown, which sends the caller looking for a" \
          "typo in a flag SPEC.md §7 spells exactly that way:" "$out"
        ;;
      *) _pass "okf check $flag is a flag check knows about" ;;
    esac
  done

  assert_exit 1 "$okf" check --nope
  assert_contains "$(last_output)" "check: unknown flag: --nope" \
    "a flag that is not one of the three is refused by name"
  assert_contains "$(last_output)" "usage: okf check" \
    "and the refusal says what check does take"

  # A path is not an argument to check: SPEC.md §7 gives it none, and a caller
  # who typed one meant something — one concept, one directory — that this
  # cannot do. Answering with a whole-bundle report instead would be a run they
  # did not ask for.
  assert_exit 1 "$okf" check src/route/RouteRegistry.md
  assert_contains "$(last_output)" "check takes no arguments" \
    "a stray argument is refused rather than silently ignored"
  return 0
}

test_okf_check_answers_for_its_own_flags() {
  with_fixture_repo concepts _okf_check_flag_probe
}

# `okf check`'s exit status alongside its listing, which is the pair `--strict`
# has to be judged on. The flag changes only the first of the two, so both are
# asserted on every call below: a `--strict` run that exited 3 while printing
# something other than what the plain run prints would be a second, sterner
# check rather than the same one with a status on the end — and a caller who
# read the report and then acted on it would be acting on the wrong listing.
_okf_assert_check_status() { # $1 = expected status, $2 = expected stdout, $3 = description, $4.. = okf arguments
  local expected_rc="$1" expected_out="$2" what="$3"
  shift 3
  _okf_check "$@"
  if [ "$OKF_CHECK_RC" -eq "$expected_rc" ]; then
    _pass "$what"
  else
    local -a detail=("okf $* exited $OKF_CHECK_RC, expected $expected_rc" "stderr:")
    local line
    while IFS= read -r line; do detail+=("$line"); done < <(_detail_lines "$OKF_CHECK_ERR")
    _fail "$what" "${detail[@]}"
  fi
  assert_eq "$expected_out" "$OKF_CHECK_OUT" \
    "$what: and its listing is the plain report, line for line"
}

# SPEC.md §8's "`--strict` exits 3" and SPEC.md §7's exit-code table, which name
# the same finding: drift, and only drift. Everything the flag must *not* gate
# on is asserted here too, because a status is the one part of this report a CI
# job branches on without ever reading it, and a gate that fires on the wrong
# thing gets switched off rather than fixed.
_okf_check_strict_probe() {
  local okf="$TOOLKIT_ROOT/bin/okf" root="$PWD"

  # tests/fixtures/concepts starts with a concept for every source and every
  # concept carrying the true digest of the source beside it. Finding nothing is
  # success however the caller asked, so this is the flag's quiet case.
  _okf_assert_check_status 0 '' \
    "--strict over a bundle with nothing wrong with it exits 0, printing nothing" \
    check --strict

  # One source edited under its concept. The plain run is asserted first, on the
  # same state, because "--strict exits 3" only means something next to "plain
  # check always exits 0": asserting the 3 on its own would pass just as
  # happily against a check that had quietly started failing for everybody.
  printf '// touched\n' >> src/route/RouteRegistry.java
  _okf_assert_check_status 0 'drifted: src/route/RouteRegistry.md' \
    "drift leaves a plain run at 0 — SPEC.md §8's CI warns, never gates" check
  _okf_assert_check_status 3 'drifted: src/route/RouteRegistry.md' \
    "and the same drift makes a --strict run exit 3" check --strict

  # A second drifted concept is the same answer, not a worse one. There is one
  # non-zero status for drift in SPEC.md §7's table, and a count leaking into it
  # would give a caller an exit status to do arithmetic on.
  printf '// touched\n' >> src/route/Legacy.java
  _okf_assert_check_status 3 'drifted: src/route/Legacy.md
drifted: src/route/RouteRegistry.md' \
    "two drifted concepts are still exit 3, not a count" check --strict

  git checkout -q -- src/route/
  _okf_assert_check_status 0 '' "and putting both sources back returns --strict to 0" \
    check --strict

  # An in-scope source nobody has written a concept for. Not drift: SPEC.md §8
  # defines drift as a stored hash differing from its resource's, and there is
  # no concept here to have stored one. Gating on it would also be hopeless —
  # a repository part way through being written up is nearly all `missing:`, so
  # the job would fail from the first commit until the last concept was authored.
  printf 'package route;\n\nclass Dispatcher {}\n' > src/route/Dispatcher.java
  _okf_stage src/route/Dispatcher.java || return 1
  _okf_assert_check_status 0 'missing: src/route/Dispatcher.java' \
    "an undocumented source is reported but does not make --strict exit 3" \
    check --strict

  # A concept whose resource is gone. Also not drift, and its repair is not a
  # re-read of anything: the concept goes, or the `resource` it names is
  # corrected.
  rm -f src/route/Dispatcher.java
  git rm -q --cached src/route/Dispatcher.java > /dev/null 2>&1
  rm -f src/route/Legacy.java
  _okf_assert_check_status 0 'orphan: src/route/Legacy.md' \
    "an orphan concept is reported but does not make --strict exit 3 either" \
    check --strict

  # Both of the non-drift kinds at once, in case either only stayed off the
  # status because the other was absent.
  printf 'package route;\n\nclass Dispatcher {}\n' > src/route/Dispatcher.java
  _okf_stage src/route/Dispatcher.java || return 1
  _okf_assert_check_status 0 'missing: src/route/Dispatcher.java
orphan: src/route/Legacy.md' \
    "a report of nothing but missing and orphan findings still exits 0" check --strict

  # And drift on top of them, which is the state a real repository mid-refactor
  # is in. The 3 has to survive the company of findings that do not cause it.
  printf '// touched\n' >> src/route/RouteRegistry.java
  _okf_assert_check_status 3 'drifted: src/route/RouteRegistry.md
missing: src/route/Dispatcher.java
orphan: src/route/Legacy.md' \
    "drift alongside a missing source and an orphan is exit 3" check --strict
  _okf_assert_check_status 0 'drifted: src/route/RouteRegistry.md
missing: src/route/Dispatcher.java
orphan: src/route/Legacy.md' \
    "and the same three findings leave a plain run at 0" check

  git checkout -q -- src/route/
  rm -f src/route/Dispatcher.java
  git rm -q --cached src/route/Dispatcher.java > /dev/null 2>&1
  _okf_assert_check_status 0 '' "the bundle is clean and --strict is back to 0" check --strict

  # The stderr half. A concept okf can only warn about — a `content_hash` that
  # was never a digest — is a fact about one file, not a finding about the
  # bundle: it is not on the listing, so it must not be on the status either. A
  # --strict run that failed a build over it would be gating on something no
  # amount of refreshing concepts could clear.
  printf -- '---\ntype: Class\nresource: /src/route/RouteSource.java\ncode:\n  content_hash: "not-a-digest"\n---\n' \
    > src/route/Bad.md
  _okf_stage src/route/Bad.md || return 1
  _okf_assert_check_status 0 '' \
    "a concept okf can only warn about leaves --strict at 0, printing no finding" \
    check --strict
  assert_contains "$OKF_CHECK_ERR" "code.content_hash is not" \
    "and the warning it did not gate on was still said out loud"
  rm -f src/route/Bad.md
  git rm -q --cached src/route/Bad.md > /dev/null 2>&1

  # SPEC.md §8's other promise, which `--strict` does not get to break: plain
  # `okf check` never mutates a file, and the flag that changes the status must
  # not have quietly become the flag that writes — that is `--stamp`, a separate
  # one, for exactly this reason. Asserted over a run that exits 3, since that
  # is the run with something it might think worth writing down.
  local marker=".okf-strict-marker" before_status touched
  printf '// touched\n' >> src/route/RouteRegistry.java
  local before_registry
  before_registry="$(_okf_concept_bytes src/route/RouteRegistry.md)"
  : > "$marker"
  before_status="$(git status --porcelain)"
  _okf_assert_check_status 3 'drifted: src/route/RouteRegistry.md' \
    "a --strict run that finds drift exits 3" check --strict
  assert_eq "$before_status" "$(git status --porcelain)" \
    "and leaves the work tree exactly as it found it"
  touched="$(find . -path ./.git -prune -o -type f -newer "$marker" -print | sort)"
  assert_eq "" "$touched" "and not one file in the copy was written to"
  assert_eq "$before_registry" "$(_okf_concept_bytes src/route/RouteRegistry.md)" \
    "and the drifted concept is byte for byte as it was — no stale_after was stamped"
  rm -f "$marker"

  # The status has to survive dispatch, and it is the one status in okf that is
  # neither 0 nor an error. These two spellings are where it would be lost: a
  # global flag taken out of the line after the subcommand, and a run re-rooted
  # into another checkout from outside it.
  assert_exit 3 "$okf" check -C "$root" --strict
  assert_exit 3 "$okf" -C "$root" check --strict
  git checkout -q -- src/route/
  assert_exit 0 "$okf" -C "$root" check --strict

  # `--strict` is a flag, not an argument, so it stops being one past a `--` and
  # the line is refused as a stray argument rather than silently gating.
  assert_exit 1 "$okf" check -- --strict
  assert_contains "$(last_output)" "check takes no arguments" \
    "past a -- it is an argument check does not take, not a flag"
  return 0
}

test_okf_check_strict_exits_three_only_on_drift() {
  with_fixture_repo concepts _okf_check_strict_probe
}


# `okf check --json` — SPEC.md §7's third flag on this subcommand, and the one
# that changes the shape of the report rather than what is in it.
#
# Everything below is written around one claim: the flag is a rendering of the
# finished report and nothing else. The same walk, the same findings, the same
# warnings on stderr, the same exit status — so the two shapes are compared
# against each other on the same state rather than each being asserted against
# a literal of its own, which is the one way two spellings of a report drift
# apart without either looking wrong.

# okf check's stdout, parsed, with the parse itself asserted rather than
# assumed. A jq filter over output that was not JSON comes back empty, so every
# comparison underneath an unchecked parse would be against an empty string and
# would pass whatever the run had printed.
#
# Slurped rather than filtered in place, because "one JSON document" is part of
# what is being asserted: a report emitted as one object per finding would parse
# perfectly well one line at a time and could not tell a clean bundle from a run
# that stopped before it printed anything.
OKF_CHECK_JSON=""
_okf_check_json() { # $1.. = okf arguments
  _okf_check "$@"
  OKF_CHECK_JSON=""

  local slurped
  if ! slurped="$(printf '%s\n' "$OKF_CHECK_OUT" | jq -s -c . 2> /dev/null)"; then
    local -a detail=("okf $* did not print JSON" "stdout:")
    local line
    while IFS= read -r line; do detail+=("$line"); done < <(_detail_lines "$OKF_CHECK_OUT")
    _fail "okf $* prints one JSON document" "${detail[@]}"
    return 1
  fi

  local count
  count="$(printf '%s\n' "$slurped" | jq -c 'length')"
  if [ "$count" != "1" ]; then
    _fail "okf $* prints one JSON document" \
      "stdout parsed as $count JSON documents, not one" "stdout:" "$OKF_CHECK_OUT"
    return 1
  fi

  OKF_CHECK_JSON="$(printf '%s\n' "$slurped" | jq -c '.[0]')"
  return 0
}

# The document okf check --json printed, exactly, next to the status it came
# back with. Both on every call for _okf_assert_check_status' reason: `--json`
# must not have quietly become a flag that also changes what a caller branches
# on.
_okf_assert_check_json() { # $1 = expected status, $2 = expected compact JSON, $3 = description, $4.. = okf arguments
  local expected_rc="$1" expected_json="$2" what="$3"
  shift 3
  _okf_check_json "$@" || return 1
  if [ "$OKF_CHECK_RC" -eq "$expected_rc" ]; then
    _pass "$what: exits $expected_rc"
  else
    local -a detail=("okf $* exited $OKF_CHECK_RC, expected $expected_rc" "stderr:")
    local line
    while IFS= read -r line; do detail+=("$line"); done < <(_detail_lines "$OKF_CHECK_ERR")
    _fail "$what: exits $expected_rc" "${detail[@]}"
  fi
  assert_eq "$expected_json" "$OKF_CHECK_JSON" "$what"
  return 0
}

_okf_check_json_probe() {
  # A bundle with nothing wrong with it, which is where the two shapes part
  # company on purpose. The plain report prints nothing — something to read
  # means something to do — and nothing is not a JSON document: a caller who
  # asked for JSON is parsing what comes back, and `jq` given an empty stream
  # fails rather than reporting a clean bundle. So the empty answer is spelled
  # out, three empty arrays and no findings.
  _okf_assert_check_json 0 '{"drifted":[],"missing":[],"orphan":[]}' \
    "a clean bundle is three empty arrays, not the plain report's silence" \
    check --json

  # The three keys, and only those three. Named for the labels the plain report
  # prints — `drifted:`, `missing:`, `orphan:` — so `grep '^orphan: '` and
  # `.orphan` are one set and not two that can come apart, and asserted in the
  # document's own order so the two listings stay readable side by side.
  assert_eq '["drifted","missing","orphan"]' \
    "$(printf '%s\n' "$OKF_CHECK_JSON" | jq -c 'keys_unsorted')" \
    "its keys are the three kinds the plain report labels its lines with"

  _okf_assert_check '' "while the plain run over the same bundle still prints nothing" \
    check

  # All three kinds at once, which is the only state that says the sets are kept
  # apart rather than concatenated.
  printf '// touched\n' >> src/route/RouteRegistry.java
  printf 'package route;\n\nclass Dispatcher {}\n' > src/route/Dispatcher.java
  _okf_stage src/route/Dispatcher.java || return 1
  rm -f src/route/Legacy.java

  _okf_assert_check_json 0 \
    '{"drifted":["src/route/RouteRegistry.md"],"missing":["src/route/Dispatcher.java"],"orphan":["src/route/Legacy.md"]}' \
    "drift, an undocumented source and an orphan each land under their own key" \
    check --json

  # The same run, both ways, compared to each other. This is the invariant the
  # flag lives or dies by: a caller who reads the JSON and a caller who greps
  # the lines must be told the same thing about the same bundle, and asserting
  # each against a literal of its own could not catch the day they stop
  # agreeing.
  local kind reported rendered
  _okf_check check
  for kind in drifted missing orphan; do
    reported="$(printf '%s\n' "$OKF_CHECK_OUT" | sed -n "s/^$kind: //p")"
    rendered="$(printf '%s\n' "$OKF_CHECK_JSON" | jq -r --arg kind "$kind" '.[$kind][]')"
    assert_eq "$reported" "$rendered" \
      "the $kind array is exactly the plain report's $kind: lines"
  done

  # SPEC.md §8's statuses are the walk's, not the rendering's. `--json` is not a
  # quieter run and not a sterner one: the plain report exits 0 over these three
  # findings and `--strict` exits 3 over the drift among them, and asking for
  # JSON changes neither.
  local three='{"drifted":["src/route/RouteRegistry.md"],"missing":["src/route/Dispatcher.java"],"orphan":["src/route/Legacy.md"]}'
  _okf_assert_check_json 3 "$three" \
    "--json alongside --strict still exits 3 on drift, printing the same document" \
    check --json --strict
  _okf_assert_check_json 3 "$three" \
    "and the two flags in the other order are the same run" check --strict --json

  # SPEC.md §8's other promise, which the new flag does not get to break: plain
  # `okf check` never mutates a file. Asserted over the run that exits 3, since
  # that is the run with something it might think worth writing down.
  local marker=".okf-json-marker" before_status touched
  : > "$marker"
  before_status="$(git status --porcelain)"
  _okf_assert_check_json 3 "$three" \
    "a --json --strict run that finds drift exits 3" check --json --strict
  assert_eq "$before_status" "$(git status --porcelain)" \
    "and leaves the work tree exactly as it found it"
  touched="$(find . -path ./.git -prune -o -type f -newer "$marker" -print | sort)"
  assert_eq "" "$touched" "and not one file in the copy was written to"
  rm -f "$marker"

  git checkout -q -- src/route/
  rm -f src/route/Dispatcher.java
  git rm -q --cached src/route/Dispatcher.java > /dev/null 2>&1
  _okf_assert_check_json 0 '{"drifted":[],"missing":[],"orphan":[]}' \
    "putting all three right empties every array" check --json

  # What JSON is actually for, and the reason the sets reach jq NUL-separated
  # rather than a line at a time. A path with a `"` in it is a document a
  # hand-rolled encoder would have produced invalid JSON for, and a path with a
  # newline in it is a *finding* the plain report cannot express: its two lines
  # read as two paths, neither of which exists. Both are legal names in git and
  # on any POSIX filesystem.
  local quoted=$'src/route/Odd "Name".java'
  local split=$'src/route/Two\nLines.java'
  printf 'package route;\n\nclass Odd {}\n' > "$quoted"
  printf 'package route;\n\nclass Two {}\n' > "$split"
  _okf_stage "$quoted" "$split" || return 1

  _okf_check_json check --json || return 1
  assert_eq "0" "$OKF_CHECK_RC" "a bundle holding awkwardly named sources still exits 0"
  assert_eq '["src/route/Odd \"Name\".java","src/route/Two\nLines.java"]' \
    "$(printf '%s\n' "$OKF_CHECK_JSON" | jq -c '.missing')" \
    "a quote and a newline in a path are escaped, not emitted raw or split in two"

  # Read back out, which is the half that matters to a caller: the newline path
  # survives the round trip as one string. `jq -r` would print it as two lines
  # again, so it comes back as JSON and is compared as JSON.
  assert_eq '"src/route/Two\nLines.java"' \
    "$(printf '%s\n' "$OKF_CHECK_JSON" | jq -c '.missing[1]')" \
    "and the path with a newline in it is one element, not two"

  rm -f "$quoted" "$split"
  git rm -q --cached -- "$quoted" "$split" > /dev/null 2>&1
  _okf_assert_check_json 0 '{"drifted":[],"missing":[],"orphan":[]}' \
    "the bundle is clean once the awkward names are gone" check --json
  return 0
}

test_okf_check_json_emits_one_document() {
  with_fixture_repo concepts _okf_check_json_probe
}

# The two things that must stay off stdout when a caller has asked for JSON: the
# warnings SPEC.md §8 has this subcommand say out loud, and a set that could not
# be worked out at all. The first would make the document unparseable; the
# second would make it wrong in a way nothing in it admits to.
_okf_check_json_degraded_probe() {
  # A concept okf can only warn about — a `content_hash` that was never a
  # digest. The warning is a fact about one file rather than a finding about the
  # bundle, so it goes to stderr, and under `--json` that separation stops being
  # a nicety: a line of prose on stdout is a document that will not parse.
  printf -- '---\ntype: Class\nresource: /src/route/RouteSource.java\ncode:\n  content_hash: "not-a-digest"\n---\n' \
    > src/route/Bad.md
  _okf_stage src/route/Bad.md || return 1
  _okf_assert_check_json 0 '{"drifted":[],"missing":[],"orphan":[]}' \
    "a concept okf can only warn about leaves the document empty and parseable" \
    check --json
  assert_contains "$OKF_CHECK_ERR" "code.content_hash is not" \
    "and the warning it kept off stdout was still said on stderr"
  rm -f src/route/Bad.md
  git rm -q --cached src/route/Bad.md > /dev/null 2>&1

  # The missing set is the one of the three read out of scope, and a run that
  # cannot work out its scope has not found no undocumented sources — it has
  # not looked. `null` says so; `[]` would be indistinguishable from a fully
  # documented repository, which is the reading a dashboard lights up green
  # for. The plain report says the same thing on stderr, which is exactly the
  # stream a caller piping stdout into jq has thrown away.
  #
  # Driven by a stand-in ripgrep, since there is no way to make a working one
  # fail on demand — the same device the scope tests use, and the @Generated
  # scan is the step of the in-scope walk that needs it. `okf check`'s other two
  # sets come out of git and are unaffected, which is what the drift and orphan
  # below are here to show.
  printf '// touched\n' >> src/route/RouteRegistry.java
  rm -f src/route/Legacy.java

  local fakebin
  if ! fakebin="$(mktemp -d "${TMPDIR:-/tmp}/toolkit-fakerg.XXXXXX")"; then
    _fail "a stand-in ripgrep can be made" "mktemp -d failed"
    return 1
  fi
  printf '%s\n' "$fakebin" >> "$HARNESS_STATE/fixture_dirs"
  printf '#!/bin/sh\nprintf "rg: broken\\n" >&2\nexit 2\n' > "$fakebin/rg"
  if ! chmod +x "$fakebin/rg"; then
    _fail "a stand-in ripgrep can be made" "chmod +x failed: $fakebin/rg"
    rm -rf "$fakebin"
    return 1
  fi

  # Put in front on PATH for exactly the two calls below and taken off again:
  # every other command this probe runs — git, jq, sed — still resolves to the
  # real one, and a fake left on PATH would silently degrade every test after
  # this one.
  local saved_path="$PATH"
  PATH="$fakebin:$PATH"
  _okf_assert_check_json 0 \
    '{"drifted":["src/route/RouteRegistry.md"],"missing":null,"orphan":["src/route/Legacy.md"]}' \
    "a scope that could not be worked out is a null missing set, not an empty one" \
    check --json
  assert_contains "$OKF_CHECK_ERR" "in-scope source listing could not be made" \
    "and the run says why on stderr, as the plain report does"
  PATH="$saved_path"
  rm -rf "$fakebin"

  # The same state with a working ripgrep, so the null above is the failed scan
  # and not something about this bundle. An array either way for the other two
  # keys: neither is read out of scope, so both were answered on both runs.
  _okf_assert_check_json 0 \
    '{"drifted":["src/route/RouteRegistry.md"],"missing":[],"orphan":["src/route/Legacy.md"]}' \
    "and the same bundle scanned properly reports an empty missing set instead" \
    check --json

  git checkout -q -- src/route/
  return 0
}

test_okf_check_json_says_what_it_could_not_work_out() {
  with_fixture_repo concepts _okf_check_json_degraded_probe
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
