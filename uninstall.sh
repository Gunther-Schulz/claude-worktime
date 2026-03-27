#!/bin/bash
# Uninstall claude-worktime hooks, statusline, and script
set -euo pipefail

BIN_DIR="${HOME}/.local/bin"
CLAUDE_DIR="${HOME}/.claude"
SETTINGS="${CLAUDE_DIR}/settings.json"

echo "Uninstalling claude-worktime..."

# Remove script
if [ -f "$BIN_DIR/claude-worktime" ]; then
    rm "$BIN_DIR/claude-worktime"
    echo "  Removed $BIN_DIR/claude-worktime"
fi

# Also clean up old location if present
rm -f "$CLAUDE_DIR/scripts/claude-worktime.sh" "$CLAUDE_DIR/scripts/session-elapsed.sh"

# Remove hooks and statusline from settings.json
if [ -f "$SETTINGS" ] && command -v jq &>/dev/null; then
    changed=false
    for hook in SessionStart UserPromptSubmit PostToolUse Stop; do
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
