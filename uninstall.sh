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

# Remove hooks and statusline from settings.json
if [ -f "$SETTINGS" ] && command -v jq &>/dev/null; then
    changed=false
    for hook in SessionStart UserPromptSubmit PreToolUse PostToolUse Stop StopFailure; do
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

# Remove fenced section from CLAUDE.md
CLAUDE_MD="${CLAUDE_DIR}/CLAUDE.md"
MARKER_START="<!-- claude-worktime:start -->"
if [ -f "$CLAUDE_MD" ] && grep -q "$MARKER_START" "$CLAUDE_MD"; then
    awk -v start="$MARKER_START" '
        $0 == start { skip=1; next }
        skip && /^<!-- claude-worktime:end -->/ { skip=0; next }
        !skip { print }
    ' "$CLAUDE_MD" > "${CLAUDE_MD}.tmp" && mv "${CLAUDE_MD}.tmp" "$CLAUDE_MD"
    # Remove trailing blank lines left behind
    sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$CLAUDE_MD"
    echo "  Removed claude-worktime section from CLAUDE.md"
fi

echo ""
echo "Done. Restart Claude Code to deactivate."
echo "Note: Data preserved at:"
echo "  Config: ${XDG_CONFIG_HOME:-$HOME/.config}/claude-worktime/"
echo "  Logs:   ${XDG_DATA_HOME:-$HOME/.local/share}/claude-worktime/"
echo "  Legacy: ~/.claude/worktime/ (if present)"
echo "  To remove all: rm -rf ~/.config/claude-worktime ~/.local/share/claude-worktime ~/.claude/worktime"
