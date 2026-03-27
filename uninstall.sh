#!/bin/bash
# Uninstall claude-worktime hooks and script
set -euo pipefail

CLAUDE_DIR="${HOME}/.claude"
SCRIPTS_DIR="${CLAUDE_DIR}/scripts"
SETTINGS="${CLAUDE_DIR}/settings.json"

echo "Uninstalling claude-worktime..."

# Remove script
if [ -f "$SCRIPTS_DIR/claude-worktime.sh" ]; then
    rm "$SCRIPTS_DIR/claude-worktime.sh"
    echo "  Removed script"
fi

# Remove hooks from settings.json
if [ -f "$SETTINGS" ] && command -v jq &>/dev/null; then
    if jq -e '.hooks.SessionStart' "$SETTINGS" &>/dev/null; then
        jq 'del(.hooks.SessionStart) | del(.hooks.UserPromptSubmit) | if .hooks == {} then del(.hooks) else . end' \
            "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
        echo "  Removed hooks from settings.json"
    fi
fi

echo ""
echo "Done. Restart Claude Code to deactivate."
echo "Note: Activity log preserved at ~/.claude/worktime/activity.log"
echo "  To remove it: rm -rf ~/.claude/worktime/"
