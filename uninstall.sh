#!/bin/bash
# Uninstall claude-worktime hooks, statusline, and script
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

# Remove hooks and statusline from settings.json
if [ -f "$SETTINGS" ] && command -v jq &>/dev/null; then
    changed=false
    for hook in SessionStart UserPromptSubmit Stop; do
        if jq -e ".hooks.$hook" "$SETTINGS" &>/dev/null; then
            jq "del(.hooks.$hook)" "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
            changed=true
        fi
    done
    # Clean up empty hooks object
    if jq -e '.hooks == {}' "$SETTINGS" &>/dev/null; then
        jq 'del(.hooks)' "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
    fi
    # Remove statusline if it's ours
    if jq -e '.statusLine.command' "$SETTINGS" 2>/dev/null | grep -q 'claude-worktime'; then
        jq 'del(.statusLine)' "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
        echo "  Removed statusline"
    fi
    $changed && echo "  Removed hooks from settings.json"
fi

echo ""
echo "Done. Restart Claude Code to deactivate."
echo "Note: Activity logs preserved at ~/.claude/worktime/"
echo "  To remove all data: rm -rf ~/.claude/worktime/"
