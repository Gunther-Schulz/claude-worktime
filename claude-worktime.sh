#!/bin/bash
# claude-worktime — track active working time in Claude Code sessions
#
# JSONL log format: {"t":UNIX_TS,"p":"/path","b":"branch","e":"start"|"activity"}
# One entry per hook event. Sessions detected by activity gaps, not markers.
#
# Usage:
#   claude-worktime log [--start]        # append entry (called by hooks)
#   claude-worktime stop                 # session end summary (Stop hook)
#   claude-worktime                      # current session
#   claude-worktime --today              # today's total
#   claude-worktime --week               # this week
#   claude-worktime --since 2026-03-25   # since a date
#   claude-worktime --filter PATH        # time in a project
#   claude-worktime --summary [--today]  # per-project breakdown
#   claude-worktime --csv [--today]      # export as CSV
#   claude-worktime --statusline         # compact for status bar
#   claude-worktime --rotate             # archive old entries
#   claude-worktime --raw                # JSON output (any mode)

set -euo pipefail

LOGDIR="${CLAUDE_WORKTIME_DIR:-${HOME}/.claude/worktime}"
LOGFILE="${LOGDIR}/activity.log"
PAUSE="${CLAUDE_WORKTIME_PAUSE:-900}"

# Reusable jq function: compute active seconds from sorted array
# Must be prepended to jq expressions that use calc_active
JQ_CALC='def calc_active($pause): . as $a | reduce range(1; $a|length) as $i (0;
  . + (if ($a[$i].t - $a[$i-1].t) <= $pause then $a[$i].t - $a[$i-1].t else 0 end));'

# --- date helper: GNU coreutils vs BSD ---
_date() {
    date -d "$1" "+$2" 2>/dev/null || date -j -f "%Y-%m-%d" "$1" "+$2" 2>/dev/null
}
_date_at() {
    date -d "@$1" "+$2" 2>/dev/null || date -r "$1" "+$2" 2>/dev/null
}
_today_start() {
    date -d "today 00:00" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$(date +%Y-%m-%d)" +%s 2>/dev/null
}
_week_start() {
    local dow
    dow=$(date +%u)
    if [ "$dow" = "1" ]; then
        _today_start
    else
        date -d "last monday" +%s 2>/dev/null || date -j -v-monday +%s 2>/dev/null
    fi
}

_require_jq() {
    if ! command -v jq &>/dev/null; then
        echo "Error: jq is required. Install with your package manager." >&2
        exit 1
    fi
}

# ============================================================
# Subcommand: log — append a JSONL entry (called by hooks)
# ============================================================
cmd_log() {
    mkdir -p "$LOGDIR"
    local event="activity"
    [ "${1:-}" = "--start" ] && event="start"

    local ts path branch
    ts=$(date +%s)
    path=$(pwd)
    branch=$(git branch --show-current 2>/dev/null || true)

    if [ -n "$branch" ]; then
        printf '{"t":%d,"p":"%s","b":"%s","e":"%s"}\n' "$ts" "$path" "$branch" "$event" >> "$LOGFILE"
    else
        printf '{"t":%d,"p":"%s","e":"%s"}\n' "$ts" "$path" "$event" >> "$LOGFILE"
    fi

    if [ "$event" = "start" ]; then
        printf '{"systemMessage":"Session timer started at %s"}' "$(date +%H:%M)"
    fi
}

# ============================================================
# Subcommand: stop — compute today's total, print systemMessage
# ============================================================
cmd_stop() {
    _require_jq
    [ ! -f "$LOGFILE" ] && { printf '{"systemMessage":"Today active: 0min"}'; exit 0; }

    local today_start
    today_start=$(_today_start)

    local active
    active=$(jq -s --argjson since "$today_start" --argjson pause "$PAUSE" "
        ${JQ_CALC}
        [.[] | select(.t >= \$since)] | sort_by(.t) | calc_active(\$pause)
    " "$LOGFILE")

    local h m today_str
    h=$((active / 3600))
    m=$(( (active % 3600) / 60 ))
    if [ "$h" -gt 0 ]; then
        today_str="${h}h ${m}min"
    else
        today_str="${m}min"
    fi

    printf '{"systemMessage":"Today active: %s"}' "$today_str"
}

# ============================================================
# Query helpers
# ============================================================

_entries() {
    local since=${1:-0} filter=${2:-}
    local jq_filter

    if [ -n "$filter" ]; then
        jq_filter=". | select(.t >= $since) | select(.p | test(\"$filter\"))"
    else
        jq_filter=". | select(.t >= $since)"
    fi

    jq -c "$jq_filter" "$LOGFILE" 2>/dev/null || true
}

_current_session() {
    jq -s --argjson pause "$PAUSE" '
        sort_by(.t)
        | if length == 0 then []
          else
            . as $a | length as $n
            | { start: ($n - 1), i: ($n - 1), done: false }
            | until(.i <= 0 or .done;
                if ($a[.i].t - $a[.i - 1].t) > $pause then .done = true
                else .start = (.i - 1) | .i = (.i - 1) end)
            | .start as $s | $a[$s:]
          end
    ' "$LOGFILE" 2>/dev/null || echo '[]'
}

fmt() {
    local s=$1
    local h=$((s / 3600)) m=$(( (s % 3600) / 60 ))
    if [ "$h" -gt 0 ]; then printf "%dh %dmin" "$h" "$m"
    else printf "%dmin" "$m"; fi
}

fmt_short() {
    local s=$1
    local h=$((s / 3600)) m=$(( (s % 3600) / 60 ))
    if [ "$h" -gt 0 ]; then printf "%dh%02dm" "$h" "$m"
    else printf "%dm" "$m"; fi
}

short_project() {
    echo "$1" | awk -F/ '{if(NF>=2) print $(NF-1)"/"$NF; else print $NF}'
}

# ============================================================
# Modes
# ============================================================

mode_session() {
    local raw=$1
    local session
    session=$(_current_session)

    local count
    count=$(echo "$session" | jq 'length')
    if [ "$count" -eq 0 ]; then
        if $raw; then echo '{"active":0,"wall":0,"paused":0,"started":"","project":""}';
        else echo "No session activity recorded"; fi
        return
    fi

    local info
    info=$(echo "$session" | jq --argjson pause "$PAUSE" "
        ${JQ_CALC}
        {
            first: (.[0].t),
            last: (.[-1].t),
            project: ([.[] | .p] | last),
            branch: ([.[] | .b // empty] | if length > 0 then last else \"\" end),
            active: (sort_by(.t) | calc_active(\$pause))
        }
    ")

    _output_info "$info" "$raw"
}

mode_range() {
    local raw=$1 since=$2 filter=$3
    local entries
    entries=$(_entries "$since" "$filter")

    if [ -z "$entries" ]; then
        if $raw; then echo '{"active":0,"wall":0,"paused":0,"started":"","project":""}';
        else echo "No activity recorded for this filter/range"; fi
        return
    fi

    local info
    info=$(echo "$entries" | jq -s --argjson pause "$PAUSE" "
        ${JQ_CALC}
        sort_by(.t) | {
            first: (.[0].t),
            last: (.[-1].t),
            project: ([.[] | .p] | last),
            branch: ([.[] | .b // empty] | if length > 0 then last else \"\" end),
            active: calc_active(\$pause)
        }
    ")

    _output_info "$info" "$raw"
}

_output_info() {
    local info=$1 raw=$2

    local active first_ts project branch
    active=$(echo "$info" | jq -r '.active')
    first_ts=$(echo "$info" | jq -r '.first')
    project=$(echo "$info" | jq -r '.project')
    branch=$(echo "$info" | jq -r '.branch')

    local now=$(date +%s)
    local wall=$(( now - first_ts ))
    local paused=$(( wall - active ))
    local started
    started=$(_date_at "$first_ts" "%H:%M" || echo "?")
    local proj_short
    proj_short=$(short_project "$project")
    [ -n "$branch" ] && proj_short="$proj_short ($branch)"

    if $raw; then
        jq -n --argjson a "$active" --argjson w "$wall" --argjson p "$paused" \
            --arg s "$started" --arg proj "$proj_short" --arg br "$branch" \
            '{active:$a,wall:$w,paused:$p,started:$s,project:$proj,branch:$br}'
    else
        echo "Active: $(fmt $active)  |  Wall: $(fmt $wall)  |  Paused: $(fmt $paused)  |  Started: $started  |  Project: $proj_short"
    fi
}

mode_summary() {
    local raw=$1 since=$2 filter=$3
    local entries
    entries=$(_entries "$since" "$filter")

    if [ -z "$entries" ]; then
        if $raw; then echo '{}'; else echo "No activity recorded"; fi
        return
    fi

    local result
    result=$(echo "$entries" | jq -s --argjson pause "$PAUSE" "
        ${JQ_CALC}
        group_by(.p) | map({
            project: (.[0].p | split(\"/\") | if length >= 2 then [.[-2], .[-1]] | join(\"/\") else last end),
            active: (sort_by(.t) | calc_active(\$pause))
        }) | sort_by(-.active)
    ")

    if $raw; then
        echo "$result" | jq 'reduce .[] as $x ({}; . + {($x.project): $x.active})'
    else
        echo "$result" | jq -r '.[] | "  \(.project)  \(
            if .active >= 3600 then "\(.active / 3600 | floor)h \((.active % 3600) / 60 | floor)min"
            else "\(.active / 60 | floor)min" end)"'
    fi
}

mode_csv() {
    local since=$1 filter=$2
    local entries
    entries=$(_entries "$since" "$filter")

    echo "date,start,end,active_min,wall_min,project"
    [ -z "$entries" ] && return

    # Split into sessions and output CSV fields as raw text
    echo "$entries" | jq -rs --argjson pause "$PAUSE" "
        ${JQ_CALC}
        sort_by(.t)
        | . as \$all
        | reduce range(1; length) as \$i (
            [[\$all[0]]];
            if (\$all[\$i].t - .[-1][-1].t) > \$pause
            then . + [[\$all[\$i]]]
            else .[-1] += [\$all[\$i]] end)
        | .[] | . as \$s | {
            start: (\$s[0].t),
            end_t: (\$s[-1].t),
            project: ([\$s[].p] | last | split(\"/\") | if length >= 2 then [.[-2], .[-1]] | join(\"/\") else last end),
            active_min: ((\$s | sort_by(.t) | calc_active(\$pause)) + 30) / 60 | floor
        }
        | \"\(.start),\(.end_t),\(.active_min),\(((.end_t - .start + 30) / 60) | floor),\(.project)\"
    " | while IFS=, read -r start_ts end_ts active_min wall_min project; do
        local d s e
        d=$(_date_at "$start_ts" "%Y-%m-%d")
        s=$(_date_at "$start_ts" "%H:%M")
        e=$(_date_at "$end_ts" "%H:%M")
        echo "$d,$s,$e,$active_min,$wall_min,$project"
    done
}

mode_statusline() {
    local session
    session=$(_current_session)

    local count
    count=$(echo "$session" | jq 'length')
    if [ "$count" -eq 0 ]; then
        echo "⏱ --"
        return
    fi

    local info
    info=$(echo "$session" | jq --argjson pause "$PAUSE" "
        ${JQ_CALC}
        {
            project: ([.[] | .p] | last | split(\"/\") | if length >= 2 then [.[-2], .[-1]] | join(\"/\") else last end),
            branch: ([.[] | .b // empty] | if length > 0 then last else \"\" end),
            last_t: (.[-1].t),
            active: (sort_by(.t) | calc_active(\$pause))
        }
    ")

    local active last_t project branch
    active=$(echo "$info" | jq -r '.active')
    last_t=$(echo "$info" | jq -r '.last_t')
    project=$(echo "$info" | jq -r '.project')
    branch=$(echo "$info" | jq -r '.branch')

    local now=$(date +%s)
    local gap=$(( now - last_t ))
    local idle=false
    [ "$gap" -gt "$PAUSE" ] && idle=true

    # Today's total
    local today_start
    today_start=$(_today_start)
    local today_active
    today_active=$(jq -s --argjson since "$today_start" --argjson pause "$PAUSE" "
        ${JQ_CALC}
        [.[] | select(.t >= \$since)] | sort_by(.t) | calc_active(\$pause)
    " "$LOGFILE")

    local proj_short="$project"
    [ -n "$branch" ] && proj_short="$proj_short ($branch)"

    if $idle; then
        echo "⏸ idle $(fmt_short $gap) · $(fmt_short $active) ($(fmt_short $today_active)) · $proj_short"
    else
        echo "⏱ $(fmt_short $active) ($(fmt_short $today_active)) · $proj_short"
    fi
}

mode_rotate() {
    local month_start
    month_start=$(date -d "$(date +%Y-%m-01)" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$(date +%Y-%m-01)" +%s 2>/dev/null)
    local archive_month
    archive_month=$(date -d "last month" +%Y-%m 2>/dev/null || date -j -v-1m +%Y-%m 2>/dev/null)
    local archive="${LOGDIR}/activity-${archive_month}.log"

    local old_count
    old_count=$(jq --argjson since "$month_start" 'select(.t < $since)' "$LOGFILE" 2>/dev/null | wc -l)

    if [ "$old_count" -eq 0 ]; then
        echo "Nothing to rotate (all entries are from this month)"
        return
    fi

    jq -c --argjson since "$month_start" 'select(.t < $since)' "$LOGFILE" >> "$archive"
    jq -c --argjson since "$month_start" 'select(.t >= $since)' "$LOGFILE" > "${LOGFILE}.tmp" \
        && mv "${LOGFILE}.tmp" "$LOGFILE"

    echo "Rotated $old_count entries to $archive"
}

# ============================================================
# Main
# ============================================================

case "${1:-}" in
    log)  shift; cmd_log "$@"; exit 0 ;;
    stop) cmd_stop; exit 0 ;;
esac

_require_jq

MODE="session"
RAW=false
FILTER_PATH=""
SINCE_TS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --raw) RAW=true ;;
        --summary) MODE="summary" ;;
        --csv) MODE="csv" ;;
        --statusline) MODE="statusline" ;;
        --rotate) MODE="rotate" ;;
        --filter) shift; FILTER_PATH="${1:-}"; [ "$MODE" = "session" ] && MODE="range" ;;
        --today) SINCE_TS=$(_today_start); [ "$MODE" = "session" ] && MODE="range" ;;
        --week) SINCE_TS=$(_week_start); [ "$MODE" = "session" ] && MODE="range" ;;
        --since) shift; SINCE_TS=$(_date "$1" "%s" || echo 0); [ "$MODE" = "session" ] && MODE="range" ;;
        *) ;;
    esac
    shift
done

if [ ! -f "$LOGFILE" ]; then
    if [ "$MODE" = "statusline" ]; then echo "⏱ --"
    elif $RAW; then echo '{"active":0,"wall":0,"paused":0,"started":"","project":""}';
    else echo "No session activity recorded"; fi
    exit 0
fi

case "$MODE" in
    session)    mode_session "$RAW" ;;
    range)      mode_range "$RAW" "$SINCE_TS" "$FILTER_PATH" ;;
    summary)    mode_summary "$RAW" "$SINCE_TS" "$FILTER_PATH" ;;
    csv)        mode_csv "$SINCE_TS" "$FILTER_PATH" ;;
    statusline) mode_statusline ;;
    rotate)     mode_rotate ;;
esac
