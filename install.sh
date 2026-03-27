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
#   --pomodoro      Enable pomodoro in default config

set -euo pipefail

BIN_DIR="${HOME}/.local/bin"
CLAUDE_DIR="${HOME}/.claude"
WORKTIME_DIR="${CLAUDE_DIR}/worktime"
SETTINGS="${CLAUDE_DIR}/settings.json"
SCRIPT_NAME="claude-worktime"
SCRIPT_URL="https://raw.githubusercontent.com/Gunther-Schulz/claude-worktime/main/claude-worktime.sh"
CONFIG_URL="https://raw.githubusercontent.com/Gunther-Schulz/claude-worktime/main/config.sh"
ENABLE_STATUSLINE=false
ENABLE_POMODORO=false
FORCE=false

for arg in "$@"; do
    case "$arg" in
        --statusline) ENABLE_STATUSLINE=true ;;
        --pomodoro) ENABLE_POMODORO=true ;;
        --force) FORCE=true ;;
    esac
done

echo "Installing claude-worktime..."

mkdir -p "$BIN_DIR" "$WORKTIME_DIR"

# Check for jq
if ! command -v jq &>/dev/null; then
    echo "Error: jq is required. Install with your package manager."
    echo "  apt: sudo apt install jq  |  brew: brew install jq  |  pacman: sudo pacman -S jq"
    exit 1
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
if [ ! -f "$WORKTIME_DIR/config.sh" ]; then
    if [ -f "config.sh" ]; then
        cp "config.sh" "$WORKTIME_DIR/config.sh"
    else
        curl -fsSL "$CONFIG_URL" -o "$WORKTIME_DIR/config.sh"
    fi

    if $ENABLE_POMODORO; then
        sed -i 's/^POMODORO_ENABLED=false/POMODORO_ENABLED=true/' "$WORKTIME_DIR/config.sh"
        sed -i 's/^# POMODORO_WORK=/POMODORO_WORK=/' "$WORKTIME_DIR/config.sh"
        sed -i 's/^# POMODORO_SHORT_BREAK=/POMODORO_SHORT_BREAK=/' "$WORKTIME_DIR/config.sh"
        sed -i 's/^# POMODORO_LONG_BREAK=/POMODORO_LONG_BREAK=/' "$WORKTIME_DIR/config.sh"
        sed -i 's/^# POMODORO_LONG_EVERY=/POMODORO_LONG_EVERY=/' "$WORKTIME_DIR/config.sh"
    fi

    echo "  Installed default config at $WORKTIME_DIR/config.sh"
else
    echo "  Config already exists at $WORKTIME_DIR/config.sh (kept)"
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
# Lifecycle: SessionStart → UserPromptSubmit → PreToolUse → PostToolUse → Stop/StopFailure
# Idle rule: only response→prompt gap > threshold is idle. All other gaps are work.
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

echo ""
echo "Done! Restart Claude Code to activate."
echo ""
echo "Config: $WORKTIME_DIR/config.sh"
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
