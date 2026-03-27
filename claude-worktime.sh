#!/bin/bash
# claude-worktime — show active session time for Claude Code
#
# Reads timestamps logged by Claude Code hooks and calculates
# active working time, excluding idle periods (default: >10min gap).
#
# Usage:
#   claude-worktime                                  # current session
#   claude-worktime --today                          # all active time today
#   claude-worktime --week                           # this week
#   claude-worktime --since 2026-03-25               # since a date
#   claude-worktime --filter PATH                    # time in a project
#   claude-worktime --today --filter Todenbuettel    # combined
#   claude-worktime --summary                        # per-project breakdown
#   claude-worktime --summary --today                # per-project today
#   claude-worktime --raw                            # JSON (any mode)

set -euo pipefail

LOGDIR="${CLAUDE_WORKTIME_DIR:-${HOME}/.claude/worktime}"
LOGFILE="${LOGDIR}/activity.log"
PAUSE_THRESHOLD="${CLAUDE_WORKTIME_PAUSE:-600}"  # seconds (default: 10min)

# Parse arguments
MODE="session"
RAW=false
FILTER_PATH=""
SINCE_TS=0

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --raw) RAW=true ;;
            --summary) MODE="summary" ;;
            --filter)
                MODE="${MODE:-filter}"
                [ "$MODE" = "session" ] && MODE="filter"
                shift
                FILTER_PATH="${1:-}"
                ;;
            --today)
                SINCE_TS=$(date -d "today 00:00" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$(date +%Y-%m-%d)" +%s 2>/dev/null)
                [ "$MODE" = "session" ] && MODE="range"
                ;;
            --week)
                # Monday of this week
                SINCE_TS=$(date -d "last monday" +%s 2>/dev/null || date -j -v-monday -f "%Y-%m-%d" "$(date +%Y-%m-%d)" +%s 2>/dev/null)
                [ "$(date +%u)" = "1" ] && SINCE_TS=$(date -d "today 00:00" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$(date +%Y-%m-%d)" +%s 2>/dev/null)
                [ "$MODE" = "session" ] && MODE="range"
                ;;
            --since)
                shift
                SINCE_TS=$(date -d "$1" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$1" +%s 2>/dev/null || echo 0)
                [ "$MODE" = "session" ] && MODE="range"
                ;;
            *) ;;
        esac
        shift
    done
}

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

# Calculate active time from timestamps on stdin (one per line)
calc_active() {
    local active=0
    local prev=""
    while read -r ts; do
        [ -z "$ts" ] && continue
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

# Extract matching lines from log: numeric timestamp lines, optionally filtered
# Output: "timestamp path" lines
get_lines() {
    local lines
    lines=$(grep '^[0-9]' "$LOGFILE" 2>/dev/null || true)
    # Filter by time range
    if [ "$SINCE_TS" -gt 0 ]; then
        lines=$(echo "$lines" | awk -v since="$SINCE_TS" '{if ($1 >= since) print}')
    fi
    # Filter by path
    if [ -n "$FILTER_PATH" ]; then
        lines=$(echo "$lines" | grep "$FILTER_PATH" || true)
    fi
    echo "$lines"
}

# Format and output results
output_result() {
    local active=$1 first_ts=$2 project_path=$3 label=${4:-}

    local now=$(date +%s)
    local wall=$((now - first_ts))
    local paused=$((wall - active))
    local started
    started=$(date -d "@$first_ts" +%H:%M 2>/dev/null || date -r "$first_ts" +%H:%M 2>/dev/null || echo "?")

    local proj_short=""
    if [ -n "$project_path" ]; then
        proj_short=$(short_project "$project_path")
    fi

    if $RAW; then
        printf '{"active":%d,"wall":%d,"paused":%d,"started":"%s","project":"%s"}\n' \
            "$active" "$wall" "$paused" "$started" "$proj_short"
    else
        local line="Active: $(fmt_time $active)  |  Wall: $(fmt_time $wall)  |  Paused: $(fmt_time $paused)  |  Started: $started"
        if [ -n "$proj_short" ]; then
            line="$line  |  Project: $proj_short"
        fi
        if [ -n "$label" ]; then
            line="$label: $line"
        fi
        echo "$line"
    fi
}

parse_args "$@"

if [ ! -f "$LOGFILE" ]; then
    if $RAW; then
        echo '{"active":0,"wall":0,"paused":0,"started":"","project":""}'
    else
        echo "No session activity recorded"
    fi
    exit 0
fi

# ---- Summary mode: time per project ----
if [ "$MODE" = "summary" ]; then
    declare -A project_times
    lines=$(get_lines)
    if [ -z "$lines" ]; then
        echo "No activity recorded"
        exit 0
    fi
    while IFS=' ' read -r ts path; do
        [ -z "$path" ] && continue
        key=$(short_project "$path")
        project_times[$key]+="$ts "
    done <<< "$lines"

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
        # Collect and sort by time descending
        results=()
        for proj in "${!project_times[@]}"; do
            secs=$(echo "${project_times[$proj]}" | tr ' ' '\n' | grep -v '^$' | calc_active)
            results+=("$(printf "%06d %s" "$secs" "$proj")")
        done
        IFS=$'\n' sorted=($(sort -rn <<< "${results[*]}")); unset IFS
        for entry in "${sorted[@]}"; do
            secs=$(echo "$entry" | awk '{print $1+0}')
            proj=$(echo "$entry" | awk '{print $2}')
            printf "  %-40s %s\n" "$proj" "$(fmt_time $secs)"
        done
    fi
    exit 0
fi

# ---- Filter / Range mode: all matching lines ----
if [ "$MODE" = "filter" ] || [ "$MODE" = "range" ]; then
    lines=$(get_lines)
    if [ -z "$lines" ]; then
        if $RAW; then
            echo '{"active":0,"wall":0,"paused":0,"started":"","project":""}'
        else
            echo "No activity recorded for this filter/range"
        fi
        exit 0
    fi

    timestamps=$(echo "$lines" | awk '{print $1}')
    project_path=$(echo "$lines" | tail -1 | awk '{print $2}')
    first_ts=$(echo "$timestamps" | head -1)
    active=$(echo "$timestamps" | calc_active)
    output_result "$active" "$first_ts" "$project_path"
    exit 0
fi

# ---- Default: current session (after last # SESSION marker) ----
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
output_result "$active" "$first" "$project"
