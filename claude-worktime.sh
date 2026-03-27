#!/bin/bash
# claude-worktime — show active session time for Claude Code
#
# Reads timestamps logged by Claude Code hooks and calculates
# active working time, excluding idle periods (default: >10min gap).
#
# Usage:
#   claude-worktime                        # current session
#   claude-worktime --raw                  # JSON output
#   claude-worktime --filter PATH          # all time spent in PATH
#   claude-worktime --filter PATH --raw    # same, JSON
#   claude-worktime --summary              # time per project

set -euo pipefail

LOGDIR="${CLAUDE_WORKTIME_DIR:-${HOME}/.claude/worktime}"
LOGFILE="${LOGDIR}/activity.log"
PAUSE_THRESHOLD="${CLAUDE_WORKTIME_PAUSE:-600}"  # seconds (default: 10min)

# Parse arguments
MODE="session"
RAW=false
FILTER_PATH=""
for arg in "$@"; do
    case "$arg" in
        --raw) RAW=true ;;
        --filter) MODE="filter" ;;
        --summary) MODE="summary" ;;
        *)
            if [ "$MODE" = "filter" ] && [ -z "$FILTER_PATH" ]; then
                FILTER_PATH="$arg"
            fi
            ;;
    esac
done

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

# Calculate active time from a list of timestamps (one per line)
calc_active() {
    local active=0
    local prev=""
    while read -r ts; do
        if [ -n "$prev" ]; then
            local gap=$((ts - prev))
            if [ "$gap" -le "$PAUSE_THRESHOLD" ]; then
                active=$((active + gap))
            fi
        fi
        prev=$ts
    done
    # Add time since last prompt if within threshold
    if [ -n "$prev" ]; then
        local now=$(date +%s)
        local gap=$((now - prev))
        if [ "$gap" -le "$PAUSE_THRESHOLD" ]; then
            active=$((active + gap))
        fi
    fi
    echo "$active"
}

short_project() {
    echo "$1" | awk -F/ '{if(NF>=2) print $(NF-1)"/"$NF; else print $NF}'
}

if [ ! -f "$LOGFILE" ]; then
    if $RAW; then
        echo '{"active":0,"wall":0,"paused":0,"started":"","project":""}'
    else
        echo "No session activity recorded"
    fi
    exit 0
fi

# ---- Summary mode: time per project across all sessions ----
if [ "$MODE" = "summary" ]; then
    declare -A project_times
    while IFS=' ' read -r ts path; do
        case "$ts" in '#'*|''|*[!0-9]*) continue ;; esac
        [ -z "$path" ] && continue
        key=$(short_project "$path")
        project_times[$key]+="$ts "
    done < "$LOGFILE"

    if $RAW; then
        printf '{'
        first=true
        for proj in "${!project_times[@]}"; do
            secs=$(echo "${project_times[$proj]}" | tr ' ' '\n' | grep -v '^$' | calc_active)
            $first || printf ','
            printf '"%s":%d' "$proj" "$secs"
            first=false
        done
        printf '}\n'
    else
        for proj in "${!project_times[@]}"; do
            secs=$(echo "${project_times[$proj]}" | tr ' ' '\n' | grep -v '^$' | calc_active)
            printf "%-40s %s\n" "$proj" "$(fmt_time $secs)"
        done | sort -t' ' -k2 -rn
    fi
    exit 0
fi

# ---- Filter mode: all time in a specific project ----
if [ "$MODE" = "filter" ] && [ -n "$FILTER_PATH" ]; then
    timestamps=$(grep "$FILTER_PATH" "$LOGFILE" | awk '{print $1}' | grep '^[0-9]')
    if [ -z "$timestamps" ]; then
        if $RAW; then
            echo '{"active":0,"wall":0,"paused":0,"started":"","project":""}'
        else
            echo "No activity recorded for $FILTER_PATH"
        fi
        exit 0
    fi

    active=$(echo "$timestamps" | calc_active)
    first_ts=$(echo "$timestamps" | head -1)
    now=$(date +%s)
    wall=$((now - first_ts))
    paused=$((wall - active))
    started=$(date -d "@$first_ts" +%H:%M 2>/dev/null || date -r "$first_ts" +%H:%M 2>/dev/null || echo "?")
    proj_short=$(short_project "$FILTER_PATH")

    if $RAW; then
        printf '{"active":%d,"wall":%d,"paused":%d,"started":"%s","project":"%s"}\n' \
            "$active" "$wall" "$paused" "$started" "$proj_short"
    else
        echo "Active: $(fmt_time $active)  |  Wall: $(fmt_time $wall)  |  Paused: $(fmt_time $paused)  |  Started: $started  |  Project: $proj_short"
    fi
    exit 0
fi

# ---- Default: current session (everything after last # SESSION marker) ----
current_session=$(awk '/^# SESSION/{content=""} {content=content"\n"$0} END{print content}' "$LOGFILE")
if [ -z "$current_session" ]; then
    current_session=$(cat "$LOGFILE")
fi

timestamps=()
project=""
while IFS=' ' read -r ts rest; do
    case "$ts" in
        '#'*) continue ;;
        ''|*[!0-9]*) continue ;;
    esac
    timestamps+=("$ts")
    if [ -n "$rest" ]; then
        project="$rest"
    fi
done <<< "$current_session"

if [ ${#timestamps[@]} -eq 0 ]; then
    if $RAW; then
        echo '{"active":0,"wall":0,"paused":0,"started":"","project":""}'
    else
        echo "No session activity recorded"
    fi
    exit 0
fi

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

now=$(date +%s)
gap=$((now - prev))
if [ "$gap" -le "$PAUSE_THRESHOLD" ]; then
    active=$((active + gap))
fi

first="${timestamps[0]}"
wall=$((now - first))
paused=$((wall - active))
started=$(date -d "@$first" +%H:%M 2>/dev/null || date -r "$first" +%H:%M 2>/dev/null || echo "?")

project_short=""
if [ -n "$project" ]; then
    project_short=$(short_project "$project")
fi

if $RAW; then
    printf '{"active":%d,"wall":%d,"paused":%d,"started":"%s","project":"%s"}\n' \
        "$active" "$wall" "$paused" "$started" "$project_short"
    exit 0
fi

line="Active: $(fmt_time $active)  |  Wall: $(fmt_time $wall)  |  Paused: $(fmt_time $paused)  |  Started: $started"
if [ -n "$project_short" ]; then
    line="$line  |  Project: $project_short"
fi
echo "$line"
