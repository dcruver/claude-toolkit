#!/usr/bin/env bash
# install.sh — put this toolkit's pieces where Claude Code and the shell expect them.
# Idempotent: safe to re-run after `git pull` to pick up updates.
set -euo pipefail

TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
COMMANDS_DIR="$HOME/.claude/commands"

echo "Installing from $TOOLKIT_DIR"

mkdir -p "$BIN_DIR" "$COMMANDS_DIR"

cp "$TOOLKIT_DIR/bin/ralph" "$BIN_DIR/ralph"
chmod +x "$BIN_DIR/ralph"
echo "  ralph -> $BIN_DIR/ralph"

for f in "$TOOLKIT_DIR"/commands/*.md; do
  cp "$f" "$COMMANDS_DIR/"
  echo "  $(basename "$f") -> $COMMANDS_DIR/$(basename "$f")"
done

echo
# Sanity checks — warn, don't fail the install over these.
if ! command -v claude > /dev/null 2>&1; then
  echo "WARNING: 'claude' CLI not found on PATH. Install Claude Code before these commands are usable." >&2
fi

if ! command -v git > /dev/null 2>&1; then
  echo "WARNING: 'git' not found on PATH. ralph and these commands rely on git as their memory/baseline." >&2
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "WARNING: $BIN_DIR is not on your PATH. Add it (e.g. in ~/.bashrc: export PATH=\"\$HOME/.local/bin:\$PATH\") so 'ralph' resolves." >&2 ;;
esac

echo
echo "Done. Verify with: ralph --help"
echo "And in Claude Code: /ralph-spec, /tdd-audit, /tdd-plan, /tdd-generate should now be available."
