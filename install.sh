#!/bin/bash
# Install claude-worktime hooks and script for Claude Code
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Gunther-Schulz/claude-worktime/main/install.sh | bash
#   # or
#   git clone https://github.com/Gunther-Schulz/claude-worktime.git && cd claude-worktime && ./install.sh
#
# Options:
#   --force         Overwrite existing hooks
#   --statusline    Enable statusline display

set -euo pipefail

BIN_DIR="${HOME}/.local/bin"
CLAUDE_DIR="${HOME}/.claude"
SETTINGS="${CLAUDE_DIR}/settings.json"
SCRIPT_NAME="claude-worktime"
SCRIPT_URL="https://raw.githubusercontent.com/Gunther-Schulz/claude-worktime/main/claude-worktime.sh"
CONFIG_URL="https://raw.githubusercontent.com/Gunther-Schulz/claude-worktime/main/config.sh"

# XDG paths
CONFIGDIR="${CLAUDE_WORKTIME_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-worktime}"
DATADIR="${CLAUDE_WORKTIME_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/claude-worktime}"

# Legacy path
LEGACY_DIR="${CLAUDE_DIR}/worktime"

ENABLE_STATUSLINE=false
FORCE=false

for arg in "$@"; do
    case "$arg" in
        --statusline) ENABLE_STATUSLINE=true ;;
        --force) FORCE=true ;;
    esac
done

echo "Installing claude-worktime..."

mkdir -p "$BIN_DIR" "$CONFIGDIR" "$DATADIR"

# Check for jq
if ! command -v jq &>/dev/null; then
    echo "Error: jq is required. Install with your package manager."
    echo "  apt: sudo apt install jq  |  brew: brew install jq  |  pacman: sudo pacman -S jq"
    exit 1
fi

# Migrate from legacy location (~/.claude/worktime/)
if [ -d "$LEGACY_DIR" ]; then
    echo "  Migrating from legacy location ($LEGACY_DIR)..."
    # Move config
    if [ -f "$LEGACY_DIR/config.sh" ] && [ ! -f "$CONFIGDIR/config.sh" ]; then
        cp "$LEGACY_DIR/config.sh" "$CONFIGDIR/config.sh"
        echo "    Config → $CONFIGDIR/config.sh"
    fi
    # Move data files
    for f in "$LEGACY_DIR"/activity*.log; do
        [ -f "$f" ] || continue
        local_name=$(basename "$f")
        if [ ! -f "$DATADIR/$local_name" ]; then
            cp "$f" "$DATADIR/$local_name"
            echo "    $local_name → $DATADIR/"
        fi
    done
    echo "  Migration complete. Legacy files kept at $LEGACY_DIR (safe to remove)."
fi

# Install the script
if [ -f "claude-worktime.sh" ]; then
    cp "claude-worktime.sh" "$BIN_DIR/$SCRIPT_NAME"
else
    curl -fsSL "$SCRIPT_URL" -o "$BIN_DIR/$SCRIPT_NAME"
fi
chmod +x "$BIN_DIR/$SCRIPT_NAME"
echo "  Installed $BIN_DIR/$SCRIPT_NAME"

# Install default config (don't overwrite existing)
if [ ! -f "$CONFIGDIR/config.sh" ]; then
    if [ -f "config.sh" ]; then
        cp "config.sh" "$CONFIGDIR/config.sh"
    else
        curl -fsSL "$CONFIG_URL" -o "$CONFIGDIR/config.sh"
    fi
    echo "  Installed default config at $CONFIGDIR/config.sh"
else
    echo "  Config already exists at $CONFIGDIR/config.sh (kept)"
fi

# Check PATH
if ! echo "$PATH" | tr ':' '\n' | grep -q "$BIN_DIR"; then
    echo "  Note: $BIN_DIR is not on your PATH."
    echo "  Add to your shell profile: export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

# Create settings.json if it doesn't exist
[ ! -f "$SETTINGS" ] && echo '{}' > "$SETTINGS"

# Check if hooks already exist
if jq -e '.hooks.SessionStart' "$SETTINGS" &>/dev/null && ! $FORCE; then
    echo "  Warning: Hooks already exist. Use --force to overwrite."
    echo "Done (script updated, hooks skipped)."
    exit 0
fi

# Hook commands
CW="${BIN_DIR}/${SCRIPT_NAME}"

jq --arg cw "$CW" \
   '.hooks = (.hooks // {})
    | .hooks.SessionStart = [{"hooks": [{"type": "command", "command": ($cw + " log --start"), "timeout": 5}]}]
    | .hooks.UserPromptSubmit = [{"hooks": [{"type": "command", "command": ($cw + " log --prompt"), "timeout": 2}]}]
    | .hooks.PreToolUse = [{"hooks": [{"type": "command", "command": ($cw + " log --tool-start"), "timeout": 2}]}]
    | .hooks.PostToolUse = [{"hooks": [{"type": "command", "command": ($cw + " log --tool-end"), "timeout": 2}]}]
    | .hooks.Stop = [{"hooks": [{"type": "command", "command": ($cw + " log --response"), "timeout": 2}]}]
    | .hooks.StopFailure = [{"hooks": [{"type": "command", "command": ($cw + " log --response"), "timeout": 2}]}]' \
   "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
echo "  Added hooks (SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop, StopFailure)"

# Statusline
if $ENABLE_STATUSLINE; then
    jq --arg cmd "${CW} --statusline" \
        '.statusLine = {"type": "command", "command": $cmd}' \
        "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
    echo "  Enabled statusline"
fi

# Verify dependencies
echo ""
"$BIN_DIR/$SCRIPT_NAME" --check
echo ""
echo "Done! Restart Claude Code to activate."
echo ""
echo "Config: $CONFIGDIR/config.sh"
echo "Data:   $DATADIR/"
echo ""
echo "Usage:"
echo "  claude-worktime              # current session"
echo "  claude-worktime --today      # today's total"
echo "  claude-worktime --summary    # per-project"
echo "  claude-worktime --csv        # export CSV"
if ! $ENABLE_STATUSLINE; then
    echo ""
    echo "Tip: Re-run with --statusline to show time in the status bar"
fi
