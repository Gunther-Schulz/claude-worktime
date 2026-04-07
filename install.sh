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
COMMAND_URL="https://raw.githubusercontent.com/Gunther-Schulz/claude-worktime/main/commands/worktime.md"

# XDG paths
CONFIGDIR="${CLAUDE_WORKTIME_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-worktime}"
DATADIR="${CLAUDE_WORKTIME_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/claude-worktime}"

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

# Install the script
if [ -f "claude-worktime.sh" ]; then
    cp "claude-worktime.sh" "$BIN_DIR/$SCRIPT_NAME"
else
    curl -fsSL "$SCRIPT_URL" -o "$BIN_DIR/$SCRIPT_NAME"
fi
chmod +x "$BIN_DIR/$SCRIPT_NAME"

# macOS ships bash 3.2 — script needs ≥4.0 (mapfile, read -t fractional).
# Patch the shebang to use homebrew bash if /bin/bash is too old.
if [[ "$(uname)" == "Darwin" ]]; then
    local_bash_ver=$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')
    if [ "${local_bash_ver:-3}" -lt 4 ]; then
        brew_bash="$(brew --prefix 2>/dev/null)/bin/bash"
        if [ -x "$brew_bash" ]; then
            sed -i '' "1s|#!/bin/bash|#!${brew_bash}|" "$BIN_DIR/$SCRIPT_NAME"
            echo "  Patched shebang to $brew_bash (macOS /bin/bash is too old)"
        else
            echo "  Warning: /bin/bash is v${local_bash_ver} (need ≥4.0). Install modern bash: brew install bash"
        fi
    fi
fi

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

# Install command file (slash command for Claude Code)
mkdir -p "${CLAUDE_DIR}/commands"
if [ -f "commands/worktime.md" ]; then
    cp "commands/worktime.md" "${CLAUDE_DIR}/commands/worktime.md"
else
    curl -fsSL "$COMMAND_URL" -o "${CLAUDE_DIR}/commands/worktime.md"
fi
echo "  Installed /worktime command"

# Check PATH
if ! echo "$PATH" | tr ':' '\n' | grep -q "$BIN_DIR"; then
    echo "  Note: $BIN_DIR is not on your PATH."
    echo "  Add to your shell profile: export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

# Create settings.json if it doesn't exist
[ ! -f "$SETTINGS" ] && echo '{}' > "$SETTINGS"

# Remove old CLAUDE.md section (replaced by /worktime command)
CLAUDE_MD="${CLAUDE_DIR}/CLAUDE.md"
MARKER_START="<!-- claude-worktime:start -->"
MARKER_END="<!-- claude-worktime:end -->"
if [ -f "$CLAUDE_MD" ] && grep -q "$MARKER_START" "$CLAUDE_MD"; then
    awk -v start="$MARKER_START" '
        $0 == start { skip=1; next }
        skip && /^<!-- claude-worktime:end -->/ { skip=0; next }
        !skip { print }
    ' "$CLAUDE_MD" > "${CLAUDE_MD}.tmp" && mv "${CLAUDE_MD}.tmp" "$CLAUDE_MD"
    # Remove trailing blank lines left behind
    # Remove trailing blank lines (portable: works on both GNU and BSD sed)
    while [ -s "$CLAUDE_MD" ] && [ -z "$(tail -1 "$CLAUDE_MD")" ]; do
        sed '$d' "$CLAUDE_MD" > "${CLAUDE_MD}.tmp" && mv "${CLAUDE_MD}.tmp" "$CLAUDE_MD"
    done
    echo "  Removed old claude-worktime section from CLAUDE.md (replaced by /worktime command)"
fi

# Hook commands
CW="${BIN_DIR}/${SCRIPT_NAME}"

# Append hooks — remove any existing worktime hooks first, then add fresh ones.
# This preserves hooks from other tools (unlike the old approach that overwrote entire events).
if $FORCE || ! jq -e '.hooks.SessionStart[]? | select(.hooks[0].command | contains("claude-worktime"))' "$SETTINGS" &>/dev/null; then
    jq --arg cw "$CW" '
      # Remove existing worktime hooks from all events
      (.hooks // {}) |= with_entries(
        .value |= map(select((.hooks[0].command // "") | contains("claude-worktime") | not))
      ) |
      # Append fresh worktime hooks
      .hooks.SessionStart += [{"hooks": [{"type": "command", "command": ($cw + " log --start"), "timeout": 5}]}] |
      .hooks.UserPromptSubmit += [{"hooks": [{"type": "command", "command": ($cw + " log --prompt"), "timeout": 2}]}] |
      .hooks.PreToolUse += [{"hooks": [{"type": "command", "command": ($cw + " log --tool-start"), "timeout": 2}]}] |
      .hooks.PostToolUse += [{"hooks": [{"type": "command", "command": ($cw + " log --tool-end"), "timeout": 2}]}] |
      .hooks.Stop += [{"hooks": [{"type": "command", "command": ($cw + " log --response"), "timeout": 2}]}] |
      .hooks.StopFailure += [{"hooks": [{"type": "command", "command": ($cw + " log --response"), "timeout": 2}]}]
    ' "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
    echo "  Added hooks (SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop, StopFailure)"
else
    echo "  Hooks already exist (use --force to overwrite)"
fi

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
echo "  /worktime                    # slash command in Claude Code"
echo "  /worktime --summary          # per-project breakdown"
if ! $ENABLE_STATUSLINE; then
    echo ""
    echo "Tip: Re-run with --statusline to show time in the status bar"
fi
