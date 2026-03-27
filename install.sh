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

CLAUDE_DIR="${HOME}/.claude"
SCRIPTS_DIR="${CLAUDE_DIR}/scripts"
WORKTIME_DIR="${CLAUDE_DIR}/worktime"
SETTINGS="${CLAUDE_DIR}/settings.json"
SCRIPT_NAME="claude-worktime.sh"
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
if jq -e '.hooks.SessionStart' "$SETTINGS" &>/dev/null && ! $FORCE; then
    echo "  Warning: SessionStart hook already exists in $SETTINGS"
    echo "  Skipping hook installation. Use --force to overwrite."
    echo ""
    echo "Done (script installed, hooks skipped)."
    exit 0
fi

# Hook commands
SESSION_START_CMD="mkdir -p \${HOME}/.claude/worktime && echo \"# SESSION \$(date +%Y-%m-%dT%H:%M:%S)\" >> \${HOME}/.claude/worktime/activity.log && echo \"\$(date +%s) \$(pwd)\" >> \${HOME}/.claude/worktime/activity.log && printf '{\"systemMessage\": \"Session timer started at %s\"}' \"\$(date +%H:%M)\""
PROMPT_SUBMIT_CMD="echo \"\$(date +%s) \$(pwd)\" >> \${HOME}/.claude/worktime/activity.log"
STOP_CMD="${SCRIPTS_DIR}/${SCRIPT_NAME} --today --raw | { read -r json; active=\$(echo \"\$json\" | sed 's/.*\"active\":\\([0-9]*\\).*/\\1/'); h=\$((active/3600)); m=\$(((active%3600)/60)); today_str=\"\"; [ \$h -gt 0 ] && today_str=\"\${h}h \${m}min\" || today_str=\"\${m}min\"; echo \"\$(date +%Y-%m-%d) \$today_str\" >> \${HOME}/.claude/worktime/daily.log; printf '{\"systemMessage\": \"Today active: %s\"}' \"\$today_str\"; }"

# Build jq expression
JQ_EXPR='.hooks = (.hooks // {})
  | .hooks.SessionStart = [{"hooks": [{"type": "command", "command": $ss, "timeout": 5}]}]
  | .hooks.UserPromptSubmit = [{"hooks": [{"type": "command", "command": $ps, "timeout": 2}]}]
  | .hooks.Stop = [{"hooks": [{"type": "command", "command": $stop, "timeout": 10}]}]'

jq --arg ss "$SESSION_START_CMD" \
   --arg ps "$PROMPT_SUBMIT_CMD" \
   --arg stop "$STOP_CMD" \
   "$JQ_EXPR" "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
echo "  Added SessionStart, UserPromptSubmit, and Stop hooks"

# Statusline
if $ENABLE_STATUSLINE; then
    jq --arg cmd "${SCRIPTS_DIR}/${SCRIPT_NAME} --statusline" \
        '.statusLine = {"type": "command", "command": $cmd}' \
        "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
    echo "  Enabled statusline display"
fi

echo ""
echo "Done! Restart Claude Code to activate."
echo ""
echo "Usage:"
echo "  ~/.claude/scripts/claude-worktime.sh              # current session"
echo "  ~/.claude/scripts/claude-worktime.sh --today      # today's total"
echo "  ~/.claude/scripts/claude-worktime.sh --summary    # per-project"
echo "  ~/.claude/scripts/claude-worktime.sh --csv        # export CSV"
echo ""
echo "Or inside Claude Code:  ! ~/.claude/scripts/claude-worktime.sh"
if ! $ENABLE_STATUSLINE; then
    echo ""
    echo "Tip: Re-run with --statusline to show active time in the status bar:"
    echo "  ./install.sh --force --statusline"
fi
