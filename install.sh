#!/bin/bash
# Install claude-worktime hooks and script for Claude Code
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Gunther-Schulz/claude-worktime/main/install.sh | bash
#   # or
#   git clone https://github.com/Gunther-Schulz/claude-worktime.git && cd claude-worktime && ./install.sh

set -euo pipefail

CLAUDE_DIR="${HOME}/.claude"
SCRIPTS_DIR="${CLAUDE_DIR}/scripts"
WORKTIME_DIR="${CLAUDE_DIR}/worktime"
SETTINGS="${CLAUDE_DIR}/settings.json"
SCRIPT_NAME="claude-worktime.sh"
SCRIPT_URL="https://raw.githubusercontent.com/Gunther-Schulz/claude-worktime/main/claude-worktime.sh"

echo "Installing claude-worktime..."

# Ensure directories exist
mkdir -p "$SCRIPTS_DIR" "$WORKTIME_DIR"

# Install the script
if [ -f "$SCRIPT_NAME" ]; then
    cp "$SCRIPT_NAME" "$SCRIPTS_DIR/$SCRIPT_NAME"
else
    curl -fsSL "$SCRIPT_URL" -o "$SCRIPTS_DIR/$SCRIPT_NAME"
fi
chmod +x "$SCRIPTS_DIR/$SCRIPT_NAME"
echo "  Installed $SCRIPTS_DIR/$SCRIPT_NAME"

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
if jq -e '.hooks.SessionStart' "$SETTINGS" &>/dev/null; then
    echo "  Warning: SessionStart hook already exists in $SETTINGS"
    if [ "${1:-}" != "--force" ]; then
        echo "  Skipping hook installation. Use --force to overwrite."
        echo ""
        echo "Done (script installed, hooks skipped)."
        exit 0
    fi
fi

# Hook commands:
# SessionStart: append session marker + timestamp with cwd
# UserPromptSubmit: append timestamp with cwd
LOGFILE="\${HOME}/.claude/worktime/activity.log"
SESSION_START_CMD="mkdir -p \${HOME}/.claude/worktime && echo \"# SESSION \$(date +%Y-%m-%dT%H:%M:%S)\" >> ${LOGFILE} && echo \"\$(date +%s) \$(pwd)\" >> ${LOGFILE} && printf '{\"systemMessage\": \"Session timer started at %s\"}' \"\$(date +%H:%M)\""
PROMPT_SUBMIT_CMD="echo \"\$(date +%s) \$(pwd)\" >> ${LOGFILE}"

jq --arg ss "$SESSION_START_CMD" --arg ps "$PROMPT_SUBMIT_CMD" '
  .hooks = (.hooks // {}) |
  .hooks.SessionStart = [{"hooks": [{"type": "command", "command": $ss, "timeout": 5}]}] |
  .hooks.UserPromptSubmit = [{"hooks": [{"type": "command", "command": $ps, "timeout": 2}]}]
' "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
echo "  Added SessionStart and UserPromptSubmit hooks"

echo ""
echo "Done! Restart Claude Code to activate."
echo ""
echo "Usage:"
echo "  ~/.claude/scripts/claude-worktime.sh        # show session time"
echo "  ~/.claude/scripts/claude-worktime.sh --raw   # JSON output"
echo ""
echo "Or inside Claude Code:  ! ~/.claude/scripts/claude-worktime.sh"
