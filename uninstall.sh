#!/usr/bin/env bash
# uninstall.sh — remove what install.sh put on this machine.
#
# Mirrors install.sh's loops rather than naming files: it removes whatever is in
# this checkout's bin/ and commands/, so adding a script or a slash command
# leaves nothing here to update. A hand-written uninstall list drifts the moment
# somebody adds a file, which is exactly what happened to the README's manual
# instructions.
#
# Removes only files this toolkit installs, and only where the name matches
# something in this checkout — never the whole directory, which is shared with
# other tools' commands and binaries.
set -euo pipefail

TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Same overrides as install.sh, so uninstalling from a non-default prefix is the
# same invocation that installed there.
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
COMMANDS_DIR="${COMMANDS_DIR:-$CLAUDE_DIR/commands}"
SETTINGS_FILE="${SETTINGS_FILE:-$CLAUDE_DIR/settings.json}"
PERMISSIONS_FILE="$TOOLKIT_DIR/permissions.json"

DRY_RUN=0
PURGE_PERMISSIONS=0
usage() {
  cat <<'EOF'
Usage: ./uninstall.sh [-n|--dry-run] [--purge-permissions] [-h|--help]

Removes this toolkit's bin/* from BIN_DIR and commands/*.md from COMMANDS_DIR.

  -n, --dry-run            print what would be removed, delete nothing
      --purge-permissions  also remove permissions.json's entries from
                           SETTINGS_FILE. Off by default: the install is a
                           union, so an entry may equally be one you added
                           yourself, and removing it would be a surprise.
  -h, --help               this message

Environment: BIN_DIR, CLAUDE_CONFIG_DIR, COMMANDS_DIR, SETTINGS_FILE — same
defaults as install.sh.
EOF
}
for arg in "$@"; do
  case "$arg" in
    -n | --dry-run) DRY_RUN=1 ;;
    --purge-permissions) PURGE_PERMISSIONS=1 ;;
    -h | --help) usage; exit 0 ;;
    *)
      echo "uninstall.sh: unknown option: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  would: %s\n' "$*"
  else
    "$@"
  fi
}

have_tool() { command -v -- "$1" > /dev/null 2>&1; }

echo "Uninstalling the toolkit in $TOOLKIT_DIR"
[ "$DRY_RUN" -eq 1 ] && echo "(dry run — nothing will be removed)"
echo

REMOVED=0
MISSING=0

# Binaries. The glob standing as its own literal on an empty bin/ is why the
# -e test guards the loop body rather than the loop.
for f in "$TOOLKIT_DIR"/bin/*; do
  [ -e "$f" ] || continue
  target="$BIN_DIR/$(basename "$f")"
  if [ -e "$target" ]; then
    run rm -f "$target"
    [ "$DRY_RUN" -eq 1 ] || echo "  removed $target"
    REMOVED=$((REMOVED + 1))
  else
    MISSING=$((MISSING + 1))
  fi
done

# Slash commands.
for f in "$TOOLKIT_DIR"/commands/*.md; do
  [ -e "$f" ] || continue
  target="$COMMANDS_DIR/$(basename "$f")"
  if [ -e "$target" ]; then
    run rm -f "$target"
    [ "$DRY_RUN" -eq 1 ] || echo "  removed $target"
    REMOVED=$((REMOVED + 1))
  else
    MISSING=$((MISSING + 1))
  fi
done

echo
if [ "$PURGE_PERMISSIONS" -eq 1 ]; then
  if ! have_tool jq; then
    echo "WARNING: 'jq' not found — cannot edit $SETTINGS_FILE. Remove the entries in" >&2
    echo "  $PERMISSIONS_FILE from permissions.allow by hand." >&2
  elif [ ! -s "$SETTINGS_FILE" ]; then
    echo "  $SETTINGS_FILE does not exist — nothing to purge."
  elif [ "$DRY_RUN" -eq 1 ]; then
    echo "  would remove $PERMISSIONS_FILE's entries from $SETTINGS_FILE"
  else
    # Staged beside settings.json and renamed, for the same reason install.sh
    # does it: a same-filesystem rename is atomic, so an interrupted run leaves
    # the original settings.json intact rather than a truncated one.
    TMP_SETTINGS="$SETTINGS_FILE.uninstall.$$"
    cp "$SETTINGS_FILE" "$TMP_SETTINGS"
    if jq -s '
      .[0].permissions.allow as $ours |
      .[1] * {permissions: {allow: ((.[1].permissions.allow // []) - $ours)}}
    ' "$PERMISSIONS_FILE" "$SETTINGS_FILE" > "$TMP_SETTINGS"; then
      mv -f "$TMP_SETTINGS" "$SETTINGS_FILE"
      echo "  removed this toolkit's entries from $SETTINGS_FILE"
    else
      rm -f "$TMP_SETTINGS"
      echo "WARNING: jq could not edit $SETTINGS_FILE; it is unchanged." >&2
    fi
  fi
else
  echo "  $SETTINGS_FILE left alone. Its permissions.allow entries are a union,"
  echo "  so this script cannot tell which came from here. Pass --purge-permissions"
  echo "  to remove the ones listed in $PERMISSIONS_FILE."
fi

echo
if [ "$DRY_RUN" -eq 1 ]; then
  echo "Dry run complete."
else
  echo "Done. Removed $REMOVED file(s); $MISSING were already absent."
fi
echo "This checkout itself is untouched — delete $TOOLKIT_DIR to finish."
