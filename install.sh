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
ENABLE_STATUSLINE=false
FORCE=false

for arg in "$@"; do
    case "$arg" in
        --statusline) ENABLE_STATUSLINE=true ;;
        --force) FORCE=true ;;
    esac
done

echo "Installing claude-worktime..."

# Ensure directories exist
mkdir -p "$BIN_DIR" "${CLAUDE_DIR}/worktime"

# Install the script
if [ -f "claude-worktime.sh" ]; then
    cp "claude-worktime.sh" "$BIN_DIR/$SCRIPT_NAME"
else
    curl -fsSL "$SCRIPT_URL" -o "$BIN_DIR/$SCRIPT_NAME"
fi
chmod +x "$BIN_DIR/$SCRIPT_NAME"
echo "  Installed $BIN_DIR/$SCRIPT_NAME"

# Check PATH
if ! echo "$PATH" | tr ':' '\n' | grep -q "$BIN_DIR"; then
    echo "  Note: $BIN_DIR is not on your PATH."
    echo "  Add to your shell profile: export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

# Check for jq
if ! command -v jq &>/dev/null; then
    echo "Error: jq is required. Install it with your package manager."
    echo "  apt: sudo apt install jq"
    echo "  brew: brew install jq"
    echo "  pacman: sudo pacman -S jq"
    exit 1
fi

# Create settings.json if it doesn't exist
if [ ! -f "$SETTINGS" ]; then
    echo '{}' > "$SETTINGS"
    echo "  Created $SETTINGS"
fi

# Check if hooks already exist
if jq -e '.hooks.SessionStart' "$SETTINGS" &>/dev/null && ! $FORCE; then
    echo "  Warning: SessionStart hook already exists in $SETTINGS"
    echo "  Skipping hook installation. Use --force to overwrite."
    echo ""
    echo "Done (script installed, hooks skipped)."
    exit 0
fi

# Hook commands — clean one-liners that call the script
SESSION_START_CMD="${BIN_DIR}/${SCRIPT_NAME} log --start"
ACTIVITY_CMD="${BIN_DIR}/${SCRIPT_NAME} log"
STOP_CMD="${BIN_DIR}/${SCRIPT_NAME} stop"

jq --arg ss "$SESSION_START_CMD" \
   --arg activity "$ACTIVITY_CMD" \
   --arg stop "$STOP_CMD" \
   '.hooks = (.hooks // {})
    | .hooks.SessionStart = [{"hooks": [{"type": "command", "command": $ss, "timeout": 5}]}]
    | .hooks.UserPromptSubmit = [{"hooks": [{"type": "command", "command": $activity, "timeout": 2}]}]
    | .hooks.PostToolUse = [{"hooks": [{"type": "command", "command": $activity, "timeout": 2}]}]
    | .hooks.Stop = [{"hooks": [{"type": "command", "command": $stop, "timeout": 10}]}]' \
   "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
echo "  Added SessionStart, UserPromptSubmit, PostToolUse, and Stop hooks"

# Statusline
if $ENABLE_STATUSLINE; then
    jq --arg cmd "${BIN_DIR}/${SCRIPT_NAME} --statusline" \
        '.statusLine = {"type": "command", "command": $cmd}' \
        "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
    echo "  Enabled statusline display"
fi

echo ""
echo "Done! Restart Claude Code to activate."
echo ""
echo "Usage:"
echo "  claude-worktime              # current session"
echo "  claude-worktime --today      # today's total"
echo "  claude-worktime --summary    # per-project"
echo "  claude-worktime --csv        # export CSV"
echo ""
echo "Or inside Claude Code:  ! claude-worktime"
if ! $ENABLE_STATUSLINE; then
    echo ""
    echo "Tip: Re-run with --statusline to show active time in the status bar:"
    echo "  ./install.sh --force --statusline"
fi
