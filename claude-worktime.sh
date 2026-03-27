#!/bin/bash
# claude-worktime — show active session time for Claude Code
#
# Reads timestamps logged by Claude Code hooks and calculates
# active working time, excluding idle periods (default: >10min gap).
#
# Usage:
#   claude-worktime              # show current session time
#   claude-worktime --raw        # JSON output (for statusline/scripts)
#   claude-worktime --history    # show all sessions today
#   claude-worktime --history N  # show last N sessions

set -euo pipefail

LOGDIR="${CLAUDE_WORKTIME_DIR:-${HOME}/.claude/worktime}"
LOGFILE="${LOGDIR}/activity.log"
PAUSE_THRESHOLD="${CLAUDE_WORKTIME_PAUSE:-600}"  # seconds (default: 10min)

if [ ! -f "$LOGFILE" ]; then
    if [ "${1:-}" = "--raw" ]; then
        echo '{"active":0,"wall":0,"paused":0,"started":"","project":""}'
    else
        echo "No session activity recorded"
    fi
    exit 0
fi

# Parse current session (everything after last # SESSION marker)
current_session=$(awk '/^# SESSION/{content=""} {content=content"\n"$0} END{print content}' "$LOGFILE")
if [ -z "$current_session" ]; then
    current_session=$(cat "$LOGFILE")
fi

# Extract timestamps and project from current session
timestamps=()
project=""
while IFS=' ' read -r ts rest; do
    case "$ts" in
        '#'*) continue ;;  # skip markers
        ''|*[!0-9]*) continue ;;  # skip non-numeric
    esac
    timestamps+=("$ts")
    if [ -n "$rest" ]; then
        project="$rest"
    fi
done <<< "$current_session"

if [ ${#timestamps[@]} -eq 0 ]; then
    if [ "${1:-}" = "--raw" ]; then
        echo '{"active":0,"wall":0,"paused":0,"started":"","project":""}'
    else
        echo "No session activity recorded"
    fi
    exit 0
fi

# Calculate active time
active=0
prev=""
for ts in "${timestamps[@]}"; do
    if [ -n "$prev" ]; then
        gap=$((ts - prev))
        if [ "$gap" -le "$PAUSE_THRESHOLD" ]; then
            active=$((active + gap))
        fi
    fi
    prev=$ts
done

# Add time since last prompt (if within threshold)
now=$(date +%s)
gap=$((now - prev))
if [ "$gap" -le "$PAUSE_THRESHOLD" ]; then
    active=$((active + gap))
fi

# Wall clock from first timestamp
first="${timestamps[0]}"
wall=$((now - first))
paused=$((wall - active))
started=$(date -d "@$first" +%H:%M 2>/dev/null || date -r "$first" +%H:%M 2>/dev/null || echo "?")

# Short project name (last two path components)
project_short=""
if [ -n "$project" ]; then
    project_short=$(echo "$project" | awk -F/ '{if(NF>=2) print $(NF-1)"/"$NF; else print $NF}')
fi

if [ "${1:-}" = "--raw" ]; then
    printf '{"active":%d,"wall":%d,"paused":%d,"started":"%s","project":"%s"}\n' \
        "$active" "$wall" "$paused" "$started" "$project_short"
    exit 0
fi

fmt_time() {
    local secs=$1
    local h=$((secs / 3600))
    local m=$(( (secs % 3600) / 60 ))
    if [ "$h" -gt 0 ]; then
        printf "%dh %dmin" "$h" "$m"
    else
        printf "%dmin" "$m"
    fi
}

line="Active: $(fmt_time $active)  |  Wall: $(fmt_time $wall)  |  Paused: $(fmt_time $paused)  |  Started: $started"
if [ -n "$project_short" ]; then
    line="$line  |  Project: $project_short"
fi
echo "$line"
