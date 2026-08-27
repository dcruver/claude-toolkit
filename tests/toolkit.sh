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
# The stub that every unimplemented subcommand shares is replaced, after
# sourcing, with one that reports instead of dying — so main runs all the way
# through dispatch and the report is made from inside the subcommand, where the
# process has finished moving.
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
not_implemented() { # $1 = subcommand name
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
  # has begun work against the wrong tree. "not implemented" is what every
  # stub says, and its absence is what shows nothing was dispatched.
  assert_exit 1 "$okf" -C "$FIXTURE_DIR/definitely-not-a-directory" list
  out="$(last_output)"
  assert_eq 1 "$(_okf_line_count "$out")" "a -C at a missing directory is one line"
  assert_contains "$out" "definitely-not-a-directory" "that line names the directory"
  case "$out" in
    *"not implemented"*)
      _fail "a -C at a missing directory stops before dispatch" \
        "the subcommand ran anyway:" "$out"
      ;;
    *) _pass "a -C at a missing directory stops before dispatch" ;;
  esac

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

# The two things the init checks need before they can mean anything: a bin/okf
# to run, and the jq SPEC.md §3 makes a hard requirement of it. jq is not an
# extra dependency taken on here — a machine without it cannot run okf at all,
# so there would be nothing for these checks to read back.
_okf_init_preconditions() {
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
  # where it was told the settings live rather than to a hard-coded okf.json.
  assert_exit 0 "$okf" --config okf.ci.json init
  if [ ! -f okf.ci.json ]; then
    _fail "okf --config PATH init writes PATH" "no okf.ci.json under $PWD"
  else
    assert_eq "$expected" "$(jq -S 'del(.index)' okf.ci.json)" \
      "okf --config PATH init writes the same defaults to PATH"
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
  assert_contains "$(last_output)" "--fore" "okf init names a flag it does not know"
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
  _okf_init_preconditions || return 1
  # In a throwaway repo, not the checkout: `okf init` here would drop an
  # okf.json into the toolkit itself.
  with_fixture_repo tiny _okf_init_defaults_probe
}

# The other half of the same PLAN.md item: an existing okf.json is not
# overwritten without --force.
test_okf_init_refuses_to_overwrite_without_force() {
  _okf_init_preconditions || return 1
  with_fixture_repo tiny _okf_init_force_probe
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
