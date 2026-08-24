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
SETTINGS_FILE="$HOME/.claude/settings.json"
PERMISSIONS_FILE="$TOOLKIT_DIR/permissions.json"
if command -v jq > /dev/null 2>&1; then
  [ -f "$SETTINGS_FILE" ] || echo '{}' > "$SETTINGS_FILE"
  TMP_SETTINGS="$(mktemp)"
  # Union this toolkit's generic read-only allowlist into settings.json's
  # permissions.allow, deduped, without touching anything else already there
  # (model, theme, MCP permissions, etc.) — `*` replaces arrays wholesale
  # rather than merging them, so the union has to be computed explicitly first.
  jq -s '
    .[0].permissions.allow as $new |
    .[1] * {permissions: {allow: (((.[1].permissions.allow // []) + $new) | unique)}}
  ' "$PERMISSIONS_FILE" "$SETTINGS_FILE" > "$TMP_SETTINGS" \
    && mv "$TMP_SETTINGS" "$SETTINGS_FILE" \
    && echo "  merged generic read-only permissions -> $SETTINGS_FILE"
else
  echo "WARNING: 'jq' not found — skipped merging the generic permission allowlist into $SETTINGS_FILE." >&2
  echo "  Add these to permissions.allow by hand for fewer approval prompts:" >&2
  sed 's/^/    /' "$PERMISSIONS_FILE" >&2
fi

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
echo "And in Claude Code: /onboard, /ralph-spec, /tdd-audit, /tdd-plan, /tdd-generate, /adversarial-pair,"
echo "/clarify, /explain, /critique, /tighten should now be available."
