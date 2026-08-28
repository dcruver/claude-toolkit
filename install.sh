#!/usr/bin/env bash
# install.sh — put this toolkit's pieces where Claude Code and the shell expect them.
# Idempotent: safe to re-run after `git pull` to pick up updates.
set -euo pipefail

TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
COMMANDS_DIR="$HOME/.claude/commands"

echo "Installing from $TOOLKIT_DIR"

mkdir -p "$BIN_DIR" "$COMMANDS_DIR"

# Every temp file this script renames through, removed on every exit path. $$
# differs on the next run, so a temp left behind by an interrupted or
# out-of-space install would sit in ~/.local/bin as a mode-755 half-written
# script that nothing ever cleans up. A successful rename empties the entry's
# target, which makes the rm a no-op rather than a second chance to delete
# something that matters.
INSTALL_TMPS=()
cleanup_tmps() {
  # Expanded through `${x[@]+...}`, because a bare "${x[@]}" on an empty array
  # is an unbound variable under `set -u` on bash 3.2 — which is what macOS
  # ships, and empty is the case on any run that failed before install_bin.
  local tmp
  for tmp in ${INSTALL_TMPS[@]+"${INSTALL_TMPS[@]}"}; do
    rm -f "$tmp"
  done
  return 0
}
trap cleanup_tmps EXIT

# Copy to a temp name and rename, rather than copying over the destination. A
# plain `cp` onto the live path truncates it in place, which corrupts a ralph
# loop that happens to be running right now: bash reads a script incrementally
# by byte offset, so rewriting the file underneath it makes the running shell
# execute garbage. Renaming leaves the running process on its old inode
# untouched; the update takes effect on its next invocation. `cp` + `chmod`
# rather than `install -m 755`, which would be one more tool this script dies
# without — and it dies before installing anything at all.
install_bin() { # $1 = the script's name in bin/
  local name="$1"
  # Two statements, not one `local name=... tmp=...`: bash creates every name in
  # a `local` before it evaluates any of the values, so the second would read an
  # as-yet-unset `name` and abort under `set -u`.
  local tmp="$BIN_DIR/.$name.new.$$"
  INSTALL_TMPS+=("$tmp")
  cp "$TOOLKIT_DIR/bin/$name" "$tmp"
  # Symbolic, not 755: `+x` is filtered through the umask, so someone running
  # under `umask 077` keeps a private ~/.local/bin instead of having this script
  # quietly widen every file it installs to world-readable.
  chmod +x "$tmp"
  mv -f "$tmp" "$BIN_DIR/$name"
  echo "  $name -> $BIN_DIR/$name"
}

# Everything in bin/ goes onto PATH, discovered rather than listed: a script
# added to bin/ later would otherwise pass every check tests/toolkit.sh makes of
# it — which also walks bin/* — and still never be installed.
INSTALLED_BINS=0
for f in "$TOOLKIT_DIR"/bin/*; do
  [ -f "$f" ] || continue
  install_bin "${f##*/}"
  INSTALLED_BINS=$((INSTALLED_BINS + 1))
done

# Discovery has a failure mode naming the scripts did not: without `nullglob` an
# empty or missing bin/ leaves the glob standing as its own literal, the loop
# body never runs, and the script would go on to print "Done" over an install
# that put nothing on PATH at all. The old explicit `cp bin/ralph` failed loudly
# there; so does this.
if [ "$INSTALLED_BINS" -eq 0 ]; then
  echo "ERROR: no scripts found in $TOOLKIT_DIR/bin — nothing would reach $BIN_DIR." >&2
  exit 1
fi

have_tool() { # $1 = command name
  # bash is answered by the interpreter already running this script rather than
  # by a PATH lookup, exactly as bin/okf's preflight answers it: a shell that
  # got this far has bash, whether or not PATH happens to mention it.
  if [ "$1" = bash ] && [ -n "${BASH_VERSION:-}" ]; then
    return 0
  fi
  command -v -- "$1" > /dev/null 2>&1
}

# SPEC.md §3's runtime prerequisites for okf, split the way bin/okf splits them:
# what every invocation needs, and what only Tier B reaches for. Duplicated here
# rather than read out of bin/okf because this file is a plain installer with no
# business sourcing the script it installs; tests/toolkit.sh pins both lists
# against SPEC.md §3, so a tool added there cannot go unmentioned in either.
#
# Warned about and not enforced: the files belong on disk whether or not ripgrep
# is installed yet, and okf's own preflight refuses every run until it is — so
# nothing half-works in the gap. Failing the install would take ralph and the
# slash commands down with it, and they need none of this.
OKF_REQUIRED_TOOLS=(bash git sha256sum awk sed sort rg jq)
OKF_TIER_B_TOOLS=(curl)

# The missing ones of the given tools, comma-separated on one line — someone who
# has to install three things wants all three now, not one per re-run.
missing_tools() { # $1.. = command names
  local tool missing=""
  for tool in "$@"; do
    if ! have_tool "$tool"; then
      missing="${missing:+$missing, }$tool"
    fi
  done
  printf '%s' "$missing"
}

MISSING_REQUIRED="$(missing_tools "${OKF_REQUIRED_TOOLS[@]}")"
if [ -n "$MISSING_REQUIRED" ]; then
  echo "WARNING: okf needs these and they are not on PATH: $MISSING_REQUIRED" >&2
  echo "  okf is installed, but every okf run refuses to start until they are there." >&2
fi

MISSING_TIER_B="$(missing_tools "${OKF_TIER_B_TOOLS[@]}")"
if [ -n "$MISSING_TIER_B" ]; then
  # Not "the Tier B subcommands": SPEC.md §9 has `okf chunk` split a concept
  # body locally, and bin/okf demands curl only of the ones that speak HTTP.
  echo "WARNING: the Tier B okf subcommands that reach Qdrant over HTTP need these and they are not on PATH: $MISSING_TIER_B" >&2
  echo "  Everything else okf does works without them." >&2
fi

for f in "$TOOLKIT_DIR"/commands/*.md; do
  cp "$f" "$COMMANDS_DIR/"
  echo "  $(basename "$f") -> $COMMANDS_DIR/$(basename "$f")"
done

echo
SETTINGS_FILE="$HOME/.claude/settings.json"
PERMISSIONS_FILE="$TOOLKIT_DIR/permissions.json"
if have_tool jq; then
  # `-s`, not `-f`: a settings.json that exists but is empty is no more
  # mergeable than one that is missing — `jq -s` would slurp a single value and
  # every install would report a parse failure over an empty file.
  [ -s "$SETTINGS_FILE" ] || echo '{}' > "$SETTINGS_FILE"
  # Staged beside settings.json rather than in TMPDIR, and seeded by copying it:
  # the rename below is then a same-filesystem rename, which is atomic, where a
  # move across devices is a copy and an unlink that leaves the destination
  # truncated if it is interrupted. Copying first also hands the temp file
  # settings.json's own mode, instead of replacing a file somebody had set to
  # 0644 with `mktemp`'s private 0600. jq reads the original and writes the
  # copy, so the seeding cannot corrupt its own input. `cp -p`, because a plain
  # `cp` masks the source's mode with the umask — which is the whole point of
  # copying a file whose contents are about to be truncated away.
  TMP_SETTINGS="$SETTINGS_FILE.new.$$"
  # Registered like install_bin's temps: a Ctrl-C between here and the rename
  # below would otherwise leave it in ~/.claude under a name nothing revisits.
  INSTALL_TMPS+=("$TMP_SETTINGS")
  # Best effort, and deliberately not fatal: the copied contents are truncated
  # away by jq's redirect a moment later, so this call exists only to hand the
  # temp file settings.json's mode. `cp -p` fails on a settings.json owned by
  # another uid, whose ownership it cannot preserve — and aborting a merge that
  # was written to warn rather than fail, over a mode, would be the wrong trade.
  cp -p "$SETTINGS_FILE" "$TMP_SETTINGS" 2> /dev/null || true
  # Union this toolkit's generic read-only allowlist into settings.json's
  # permissions.allow, deduped, without touching anything else already there
  # (model, theme, MCP permissions, etc.) — `*` replaces arrays wholesale
  # rather than merging them, so the union has to be computed explicitly first.
  # Spelled as if/else rather than an `&&` chain: a failing command in an
  # `&&` list is exempt from `set -e`, so the chain reported nothing but jq's
  # own parse error, left its temp file behind, and still printed "Done".
  if jq -s '
    .[0].permissions.allow as $new |
    .[1] * {permissions: {allow: (((.[1].permissions.allow // []) + $new) | unique)}}
  ' "$PERMISSIONS_FILE" "$SETTINGS_FILE" > "$TMP_SETTINGS"; then
    mv -f "$TMP_SETTINGS" "$SETTINGS_FILE"
    echo "  merged generic read-only permissions -> $SETTINGS_FILE"
  else
    rm -f "$TMP_SETTINGS"
    echo "WARNING: jq could not merge $PERMISSIONS_FILE into $SETTINGS_FILE." >&2
    echo "  Nothing there was changed — check that it is valid JSON. The rest of" >&2
    echo "  the install is unaffected." >&2
  fi
else
  echo "WARNING: 'jq' not found — skipped merging the generic permission allowlist into $SETTINGS_FILE." >&2
  # Guarded, because `sed` is itself one of the prerequisites warned about
  # above: unguarded, a machine missing both jq and sed would die here under
  # `set -e`, part way through an install, over a tool it has already been told
  # about.
  if have_tool sed; then
    echo "  Add these to permissions.allow by hand for fewer approval prompts:" >&2
    sed 's/^/    /' "$PERMISSIONS_FILE" >&2
  else
    echo "  Add the entries in $PERMISSIONS_FILE to permissions.allow by hand" >&2
    echo "  for fewer approval prompts." >&2
  fi
fi

echo
# Sanity checks — warn, don't fail the install over these.
if ! have_tool claude; then
  echo "WARNING: 'claude' CLI not found on PATH. Install Claude Code before these commands are usable." >&2
fi

if ! have_tool git; then
  echo "WARNING: 'git' not found on PATH. ralph and these commands rely on git as their memory/baseline." >&2
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "WARNING: $BIN_DIR is not on your PATH. Add it (e.g. in ~/.bashrc: export PATH=\"\$HOME/.local/bin:\$PATH\") so 'ralph' and 'okf' resolve." >&2 ;;
esac

echo
echo "Done. Verify with: ralph --help and okf --help"
echo "And in Claude Code: /onboard, /ralph-spec, /tdd-audit, /tdd-plan, /tdd-generate, /adversarial-pair,"
echo "/clarify, /explain, /critique, /tighten, /okf-init, /okf-generate should now be available."
