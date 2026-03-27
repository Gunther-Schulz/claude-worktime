#!/bin/bash
# claude-worktime — track active working time in Claude Code sessions
#
# JSONL log: {"t":TS,"p":"/path","b":"branch","s":"session-id","e":"EVENT"}
# Event types: start, prompt, tool_start, tool_end, response
#
# Idle rule: only a response→prompt gap exceeding PAUSE_THRESHOLD counts as idle.
# That's the only moment the ball is in the user's court.
# All other gaps (tool running, Claude thinking/outputting) are active work time.
#
# Usage:
#   claude-worktime log [--EVENT]           # append entry (called by hooks, reads stdin)
#   claude-worktime stop                    # session end summary (Stop hook, reads stdin)
#   claude-worktime                         # current session stats
#   claude-worktime --today                 # today's total
#   claude-worktime --week                  # this week
#   claude-worktime --since 2026-03-25      # since a date
#   claude-worktime --filter PATH           # filter by project path
#   claude-worktime --branch BRANCH         # filter by git branch
#   claude-worktime --breakdown [--today]   # phase breakdown (tool/thinking/user)
#   claude-worktime --summary [--today]     # per-project breakdown
#   claude-worktime --csv [--today]         # export as CSV
#   claude-worktime --statusline            # compact for status bar (reads stdin)
#   claude-worktime --rotate                # archive old entries
#   claude-worktime --raw                   # JSON output (any mode)

set -euo pipefail

LOGDIR="${CLAUDE_WORKTIME_DIR:-${HOME}/.claude/worktime}"
LOGFILE="${LOGDIR}/activity.log"
CONFIGFILE="${LOGDIR}/config.sh"

# --- Defaults (overridden by config.sh) ---
PAUSE_THRESHOLD=900
STATUSLINE_FORMAT="{session} ({today}) · {project}"
STATUSLINE_IDLE_FORMAT="idle {idle} · {session} ({today}) · {project}"
POMODORO_ENABLED=false
POMODORO_WORK=1500
POMODORO_SHORT_BREAK=300
POMODORO_LONG_BREAK=900
POMODORO_LONG_EVERY=4
COLOR_NORMAL="\033[32m"
COLOR_BREAK_DUE="\033[31m"
COLOR_ON_BREAK="\033[33m"
COLOR_IDLE="\033[90m"
COLOR_RESET="\033[0m"

[ -f "$CONFIGFILE" ] && source "$CONFIGFILE"

# Reusable jq: compute active seconds using event-aware idle detection
# A gap is idle ONLY when: previous event is "response" (or "start") AND gap > pause threshold
# All other gaps (tool_start→tool_end, prompt→tool_start, etc.) are always work
JQ_CALC='def calc_active($pause):
  . as $a | reduce range(1; $a|length) as $i (0;
    ($a[$i].t - $a[$i-1].t) as $gap
    | if $gap <= 0 then .
      elif ($a[$i-1].e == "response" or $a[$i-1].e == "start") and $gap > $pause then .
      else . + $gap
      end);'

# Reusable jq: compute phase breakdown — two categories
# claude = prompt→response (thinking, tools, output — Claude's turn)
# user = response→prompt within threshold (reading, thinking, typing — your turn)
# idle = response→prompt over threshold (excluded from active)
JQ_BREAKDOWN='def calc_breakdown($pause):
  . as $a | reduce range(1; $a|length) as $i (
    {claude: 0, user: 0, idle: 0};
    ($a[$i].t - $a[$i-1].t) as $gap
    | if $gap <= 0 then .
      elif ($a[$i-1].e == "response" or $a[$i-1].e == "start") and $gap > $pause then .idle += $gap
      elif $a[$i-1].e == "response" or $a[$i-1].e == "start" then .user += $gap
      else .claude += $gap
      end);'

# --- Date helpers ---
_date_at() {
    date -d "@$1" "+$2" 2>/dev/null || date -r "$1" "+$2" 2>/dev/null
}
_today_start() {
    date -d "today 00:00" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$(date +%Y-%m-%d)" +%s 2>/dev/null
}
_week_start() {
    local dow; dow=$(date +%u)
    if [ "$dow" = "1" ]; then _today_start
    else date -d "last monday" +%s 2>/dev/null || date -j -v-monday +%s 2>/dev/null; fi
}
_date_parse() {
    date -d "$1" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$1" +%s 2>/dev/null || echo 0
}
_require_jq() {
    command -v jq &>/dev/null || { echo "Error: jq is required." >&2; exit 1; }
}

# --- Read hook stdin JSON ---
_read_hook_stdin() {
    HOOK_SESSION_ID=""
    HOOK_CWD=""
    if read -t 0.1 -r _STDIN_JSON 2>/dev/null; then
        HOOK_SESSION_ID=$(echo "$_STDIN_JSON" | jq -r '.session_id // empty' 2>/dev/null || true)
        HOOK_CWD=$(echo "$_STDIN_JSON" | jq -r '.cwd // empty' 2>/dev/null || true)
    fi
}

# --- Format helpers ---
_fmt() {
    local s=${1:-0}
    local h=$((s / 3600)) m=$(( (s % 3600) / 60 ))
    if [ "$h" -gt 0 ]; then printf "%dh %dmin" "$h" "$m"
    else printf "%dmin" "$m"; fi
}
_fmt_short() {
    local s=${1:-0}
    local h=$((s / 3600)) m=$(( (s % 3600) / 60 ))
    if [ "$h" -gt 0 ]; then printf "%dh%02dm" "$h" "$m"
    else printf "%dm" "$m"; fi
}
_short_project() {
    echo "$1" | awk -F/ '{if(NF>=2) print $(NF-1)"/"$NF; else print $NF}'
}

# ============================================================
# Subcommand: log — append a JSONL entry (called by hooks)
# ============================================================
cmd_log() {
    mkdir -p "$LOGDIR"

    _read_hook_stdin

    local event="prompt"
    case "${1:-}" in
        --start)      event="start" ;;
        --prompt)     event="prompt" ;;
        --tool-start) event="tool_start" ;;
        --tool-end)   event="tool_end" ;;
        --response)   event="response" ;;
    esac

    local ts path branch session_id
    ts=$(date +%s)
    path="${HOOK_CWD:-$(pwd)}"
    branch=$(git -C "$path" branch --show-current 2>/dev/null || true)
    session_id="${HOOK_SESSION_ID:-unknown}"

    jq -nc \
        --argjson t "$ts" --arg p "$path" --arg s "$session_id" \
        --arg e "$event" --arg b "$branch" \
        'if $b == "" then {t:$t,p:$p,s:$s,e:$e} else {t:$t,p:$p,b:$b,s:$s,e:$e} end' \
        >> "$LOGFILE"

    if [ "$event" = "start" ]; then
        printf '{"systemMessage":"Session timer started at %s"}' "$(date +%H:%M)"
    fi
}

# ============================================================
# Subcommand: stop — session end summary
# ============================================================
cmd_stop() {
    _require_jq
    _read_hook_stdin
    [ ! -f "$LOGFILE" ] && { printf '{"systemMessage":"Today active: 0min"}'; exit 0; }

    local today_start; today_start=$(_today_start)

    local active
    active=$(jq -s --argjson since "$today_start" --argjson pause "$PAUSE_THRESHOLD" "
        ${JQ_CALC}
        [.[] | select(.t >= \$since)] | sort_by(.t) | calc_active(\$pause)
    " "$LOGFILE")

    local h=$((active / 3600)) m=$(( (active % 3600) / 60 ))
    local today_str
    if [ "$h" -gt 0 ]; then today_str="${h}h ${m}min"
    else today_str="${m}min"; fi

    printf '{"systemMessage":"Today active: %s"}' "$today_str"
}

# ============================================================
# Query helpers
# ============================================================

_entries() {
    local since=${1:-0} filter=${2:-} branch_filter=${3:-}
    local jq_filter=". | select(.t >= $since)"
    [ -n "$filter" ] && jq_filter="$jq_filter | select(.p | test(\"$filter\"))"
    [ -n "$branch_filter" ] && jq_filter="$jq_filter | select(.b // \"\" | test(\"$branch_filter\"))"
    jq -c "$jq_filter" "$LOGFILE" 2>/dev/null || true
}

_session_entries() {
    local sid=$1
    jq -c --arg s "$sid" 'select(.s == $s)' "$LOGFILE" 2>/dev/null || true
}

_current_session_id() {
    tail -1 "$LOGFILE" 2>/dev/null | jq -r '.s // empty' 2>/dev/null || true
}

# ============================================================
# Pomodoro — display-only, does not affect time accounting
# ============================================================

_pomodoro_status() {
    $POMODORO_ENABLED || { echo "disabled"; return; }

    local sid=$1 now=$2
    local entries; entries=$(_session_entries "$sid")
    [ -z "$entries" ] && { echo "work:$POMODORO_WORK"; return; }

    # Get active time and info about last idle gap (= last break)
    local info
    info=$(echo "$entries" | jq -s --argjson pause "$PAUSE_THRESHOLD" "
        ${JQ_CALC}
        sort_by(.t) | {
            active: calc_active(\$pause),
            last_t: (.[-1].t),
            last_e: (.[-1].e),
            active_since_break: (
                # Find last idle gap (= break), count active time after it
                . as \$a
                | (reduce range(1; \$a|length) as \$i (null;
                    if (\$a[\$i-1].e == \"response\" or \$a[\$i-1].e == \"start\")
                       and (\$a[\$i].t - \$a[\$i-1].t) > \$pause
                    then \$i else . end)) as \$break_idx
                | if \$break_idx == null then calc_active(\$pause)
                  else .\$break_idx: | calc_active(\$pause)
                  end)
        }
    " 2>/dev/null)

    # Fallback if jq fails (active_since_break is tricky)
    if [ -z "$info" ] || [ "$info" = "null" ]; then
        info=$(echo "$entries" | jq -s --argjson pause "$PAUSE_THRESHOLD" "
            ${JQ_CALC}
            sort_by(.t) | {
                active: calc_active(\$pause),
                last_t: (.[-1].t),
                last_e: (.[-1].e),
                active_since_break: calc_active(\$pause)
            }
        ")
    fi

    local active_since_break last_t last_e
    active_since_break=$(echo "$info" | jq -r '.active_since_break')
    last_t=$(echo "$info" | jq -r '.last_t')
    last_e=$(echo "$info" | jq -r '.last_e')

    local gap=$(( now - last_t ))

    local is_idle=false
    if [ "$gap" -gt "$PAUSE_THRESHOLD" ] && { [ "$last_e" = "response" ] || [ "$last_e" = "start" ]; }; then
        is_idle=true
    fi

    if [ "$active_since_break" -ge "$POMODORO_WORK" ]; then
        if $is_idle; then
            # User is on a break — show progress
            # Determine break target
            local total_active
            total_active=$(echo "$info" | jq -r '.active')
            local completed=$(( total_active / POMODORO_WORK ))
            local break_target=$POMODORO_SHORT_BREAK
            if [ "$POMODORO_LONG_EVERY" -gt 0 ] && [ "$(( completed % POMODORO_LONG_EVERY ))" -eq 0 ]; then
                break_target=$POMODORO_LONG_BREAK
            fi
            echo "on_break:${gap}/${break_target}"
        else
            echo "break_due:0"
        fi
    else
        local remaining=$(( POMODORO_WORK - active_since_break ))
        echo "work:$remaining"
    fi
}

# ============================================================
# Statusline
# ============================================================

mode_statusline() {
    _read_hook_stdin

    local sid="${HOOK_SESSION_ID:-$(_current_session_id)}"
    [ -z "$sid" ] && { printf '%b' "${COLOR_IDLE}⏱ --${COLOR_RESET}"; return; }

    local entries; entries=$(_session_entries "$sid")
    [ -z "$entries" ] && { printf '%b' "${COLOR_IDLE}⏱ --${COLOR_RESET}"; return; }

    local now=$(date +%s)

    local info
    info=$(echo "$entries" | jq -s --argjson pause "$PAUSE_THRESHOLD" "
        ${JQ_CALC}
        sort_by(.t) | {
            active: calc_active(\$pause),
            first_t: (.[0].t),
            last_t: (.[-1].t),
            last_e: (.[-1].e),
            project: ([.[] | .p] | last),
            branch: ([.[] | .b // empty] | if length > 0 then last else \"\" end)
        }
    ")

    local session_active session_first session_last last_e project branch
    session_active=$(echo "$info" | jq -r '.active')
    session_first=$(echo "$info" | jq -r '.first_t')
    session_last=$(echo "$info" | jq -r '.last_t')
    last_e=$(echo "$info" | jq -r '.last_e')
    project=$(echo "$info" | jq -r '.project')
    branch=$(echo "$info" | jq -r '.branch')

    local session_wall=$(( now - session_first ))
    local gap=$(( now - session_last ))

    local is_idle=false
    if [ "$gap" -gt "$PAUSE_THRESHOLD" ] && { [ "$last_e" = "response" ] || [ "$last_e" = "start" ]; }; then
        is_idle=true
    fi

    # Today total (all sessions, all projects)
    local today_start; today_start=$(_today_start)
    local today_active
    today_active=$(jq -s --argjson since "$today_start" --argjson pause "$PAUSE_THRESHOLD" "
        ${JQ_CALC}
        [.[] | select(.t >= \$since)] | sort_by(.t) | calc_active(\$pause)
    " "$LOGFILE")

    # Today total for current project
    local today_project_active
    today_project_active=$(jq -s --argjson since "$today_start" --argjson pause "$PAUSE_THRESHOLD" --arg proj "$project" "
        ${JQ_CALC}
        [.[] | select(.t >= \$since) | select(.p == \$proj)] | sort_by(.t) | calc_active(\$pause)
    " "$LOGFILE")

    # Build tokens
    local proj_short; proj_short=$(_short_project "$project")
    local tok_session tok_session_wall tok_today tok_today_project tok_project tok_branch tok_idle tok_break
    tok_session=$(_fmt_short "$session_active")
    tok_session_wall=$(_fmt_short "$session_wall")
    tok_today=$(_fmt_short "$today_active")
    tok_today_project=$(_fmt_short "$today_project_active")
    tok_project="$proj_short"
    tok_branch="$branch"
    tok_idle=$(_fmt_short "$gap")

    # Pomodoro
    tok_break=""
    local pomo_status; pomo_status=$(_pomodoro_status "$sid" "$now")
    local color="$COLOR_NORMAL"

    case "$pomo_status" in
        work:*)
            local remaining=${pomo_status#work:}
            tok_break="🍅$(_fmt_short "$remaining")"
            ;;
        break_due:*)
            tok_break="☕ break!"
            color="$COLOR_BREAK_DUE"
            ;;
        on_break:*)
            local parts=${pomo_status#on_break:}
            local elapsed=${parts%/*} target=${parts#*/}
            tok_break="☕$(_fmt_short "$elapsed")/$(_fmt_short "$target")"
            color="$COLOR_ON_BREAK"
            ;;
        disabled) ;;
    esac

    $is_idle && color="$COLOR_IDLE"

    local format
    if $is_idle; then format="$STATUSLINE_IDLE_FORMAT"
    else format="$STATUSLINE_FORMAT"; fi

    local output="$format"
    output="${output//\{session\}/$tok_session}"
    output="${output//\{session_wall\}/$tok_session_wall}"
    output="${output//\{today\}/$tok_today}"
    output="${output//\{today_project\}/$tok_today_project}"
    output="${output//\{project\}/$tok_project}"
    output="${output//\{branch\}/$tok_branch}"
    output="${output//\{idle\}/$tok_idle}"
    output="${output//\{break\}/$tok_break}"

    output=$(echo "$output" | sed 's/  */ /g; s/^ *//; s/ *$//')

    printf '%b' "${color}${output}${COLOR_RESET}"
}

# ============================================================
# CLI query modes
# ============================================================

mode_session() {
    local raw=$1
    local sid; sid=$(_current_session_id)
    [ -z "$sid" ] && {
        if $raw; then echo '{"active":0,"wall":0,"paused":0,"started":"","project":"","session_id":""}';
        else echo "No session activity recorded"; fi; return; }

    local entries; entries=$(_session_entries "$sid")
    [ -z "$entries" ] && {
        if $raw; then echo '{"active":0,"wall":0,"paused":0,"started":"","project":"","session_id":""}';
        else echo "No session activity recorded"; fi; return; }

    local info
    info=$(echo "$entries" | jq -s --argjson pause "$PAUSE_THRESHOLD" "
        ${JQ_CALC}
        sort_by(.t) | {
            first: (.[0].t), last: (.[-1].t),
            project: ([.[] | .p] | last),
            branch: ([.[] | .b // empty] | if length > 0 then last else \"\" end),
            session_id: (.[0].s),
            active: calc_active(\$pause)
        }
    ")
    _output_info "$info" "$raw"
}

mode_range() {
    local raw=$1 since=$2 filter=$3 branch_filter=$4
    local entries; entries=$(_entries "$since" "$filter" "$branch_filter")

    if [ -z "$entries" ]; then
        if $raw; then echo '{"active":0,"wall":0,"paused":0,"started":"","project":""}';
        else echo "No activity recorded for this filter/range"; fi; return; fi

    local info
    info=$(echo "$entries" | jq -s --argjson pause "$PAUSE_THRESHOLD" "
        ${JQ_CALC}
        sort_by(.t) | {
            first: (.[0].t), last: (.[-1].t),
            project: ([.[] | .p] | last),
            branch: ([.[] | .b // empty] | if length > 0 then last else \"\" end),
            active: calc_active(\$pause)
        }
    ")
    _output_info "$info" "$raw"
}

_output_info() {
    local info=$1 raw=$2

    local active first_ts project branch session_id
    active=$(echo "$info" | jq -r '.active')
    first_ts=$(echo "$info" | jq -r '.first')
    project=$(echo "$info" | jq -r '.project')
    branch=$(echo "$info" | jq -r '.branch')
    session_id=$(echo "$info" | jq -r '.session_id // empty')

    local now=$(date +%s)
    local wall=$(( now - first_ts ))
    local paused=$(( wall - active ))
    local started; started=$(_date_at "$first_ts" "%H:%M" || echo "?")
    local proj_short; proj_short=$(_short_project "$project")
    [ -n "$branch" ] && proj_short="$proj_short ($branch)"

    if $raw; then
        jq -n --argjson a "$active" --argjson w "$wall" --argjson p "$paused" \
            --arg s "$started" --arg proj "$proj_short" --arg br "$branch" \
            --arg sid "$session_id" \
            '{active:$a,wall:$w,paused:$p,started:$s,project:$proj,branch:$br,session_id:$sid}'
    else
        echo "Active: $(_fmt $active)  |  Wall: $(_fmt $wall)  |  Paused: $(_fmt $paused)  |  Started: $started  |  Project: $proj_short"
    fi
}

mode_breakdown() {
    local raw=$1 since=$2 filter=$3 branch_filter=$4
    local entries; entries=$(_entries "$since" "$filter" "$branch_filter")

    if [ -z "$entries" ]; then
        if $raw; then echo '{"claude":0,"user":0,"idle":0,"active":0}';
        else echo "No activity recorded"; fi; return; fi

    local result
    result=$(echo "$entries" | jq -s --argjson pause "$PAUSE_THRESHOLD" "
        ${JQ_CALC}
        ${JQ_BREAKDOWN}
        sort_by(.t) | {
            breakdown: calc_breakdown(\$pause),
            active: calc_active(\$pause)
        }
    ")

    local claude_time user_time idle active
    claude_time=$(echo "$result" | jq '.breakdown.claude')
    user_time=$(echo "$result" | jq '.breakdown.user')
    idle=$(echo "$result" | jq '.breakdown.idle')
    active=$(echo "$result" | jq '.active')

    if $raw; then
        echo "$result" | jq '{claude: .breakdown.claude, user: .breakdown.user, idle: .breakdown.idle, active: .active}'
    else
        local pct_claude=0 pct_user=0
        if [ "$active" -gt 0 ]; then
            pct_claude=$(( claude_time * 100 / active ))
            pct_user=$(( user_time * 100 / active ))
        fi

        printf "  Claude:   %-12s %d%%\n" "$(_fmt $claude_time)" "$pct_claude"
        printf "  You:      %-12s %d%%\n" "$(_fmt $user_time)" "$pct_user"
        echo "  ───────────────────────"
        printf "  Active:   %s\n" "$(_fmt $active)"
        if [ "$idle" -gt 0 ]; then
            printf "  Idle:     %s\n" "$(_fmt $idle)"
        fi
    fi
}

mode_summary() {
    local raw=$1 since=$2 filter=$3 branch_filter=$4
    local entries; entries=$(_entries "$since" "$filter" "$branch_filter")

    if [ -z "$entries" ]; then
        if $raw; then echo '{}'; else echo "No activity recorded"; fi; return; fi

    local result
    result=$(echo "$entries" | jq -s --argjson pause "$PAUSE_THRESHOLD" "
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
    local since=$1 filter=$2 branch_filter=$3
    local entries; entries=$(_entries "$since" "$filter" "$branch_filter")

    echo "date,start,end,active_min,wall_min,project,session_id"
    [ -z "$entries" ] && return

    echo "$entries" | jq -rs --argjson pause "$PAUSE_THRESHOLD" "
        ${JQ_CALC}
        sort_by(.t) | . as \$all
        | reduce range(1; length) as \$i (
            [[\$all[0]]];
            if (\$all[\$i].s != .[-1][-1].s) or
               ((\$all[\$i-1].e == \"response\" or \$all[\$i-1].e == \"start\") and (\$all[\$i].t - .[-1][-1].t) > \$pause)
            then . + [[\$all[\$i]]]
            else .[-1] += [\$all[\$i]] end)
        | .[] | . as \$s | {
            start: (\$s[0].t), end_t: (\$s[-1].t), sid: (\$s[0].s),
            project: ([\$s[].p] | last | split(\"/\") | if length >= 2 then [.[-2], .[-1]] | join(\"/\") else last end),
            active_min: ((\$s | sort_by(.t) | calc_active(\$pause)) + 30) / 60 | floor
        }
        | \"\(.start),\(.end_t),\(.active_min),\(((.end_t - .start + 30) / 60) | floor),\(.project),\(.sid)\"
    " | while IFS=, read -r start_ts end_ts active_min wall_min project sid; do
        local d s e
        d=$(_date_at "$start_ts" "%Y-%m-%d")
        s=$(_date_at "$start_ts" "%H:%M")
        e=$(_date_at "$end_ts" "%H:%M")
        echo "$d,$s,$e,$active_min,$wall_min,$project,$sid"
    done
}

mode_rotate() {
    local month_start
    month_start=$(date -d "$(date +%Y-%m-01)" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$(date +%Y-%m-01)" +%s 2>/dev/null)
    local archive_month
    archive_month=$(date -d "last month" +%Y-%m 2>/dev/null || date -j -v-1m +%Y-%m 2>/dev/null)
    local archive="${LOGDIR}/activity-${archive_month}.log"

    local old_count
    old_count=$(jq --argjson since "$month_start" 'select(.t < $since)' "$LOGFILE" 2>/dev/null | wc -l)
    if [ "$old_count" -eq 0 ]; then echo "Nothing to rotate (all entries are from this month)"; return; fi

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
FILTER_BRANCH=""
SINCE_TS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --raw) RAW=true ;;
        --summary) MODE="summary" ;;
        --breakdown) MODE="breakdown" ;;
        --csv) MODE="csv" ;;
        --statusline) MODE="statusline" ;;
        --rotate) MODE="rotate" ;;
        --filter) shift; FILTER_PATH="${1:-}"; [ "$MODE" = "session" ] && MODE="range" ;;
        --branch) shift; FILTER_BRANCH="${1:-}"; [ "$MODE" = "session" ] && MODE="range" ;;
        --today) SINCE_TS=$(_today_start); [ "$MODE" = "session" ] && MODE="range" ;;
        --week) SINCE_TS=$(_week_start); [ "$MODE" = "session" ] && MODE="range" ;;
        --since) shift; SINCE_TS=$(_date_parse "$1"); [ "$MODE" = "session" ] && MODE="range" ;;
        *) ;;
    esac
    shift
done

if [ ! -f "$LOGFILE" ]; then
    if [ "$MODE" = "statusline" ]; then printf '%b' "${COLOR_IDLE}⏱ --${COLOR_RESET}"
    elif $RAW; then echo '{"active":0,"wall":0,"paused":0,"started":"","project":""}';
    else echo "No session activity recorded"; fi
    exit 0
fi

case "$MODE" in
    session)    mode_session "$RAW" ;;
    range)      mode_range "$RAW" "$SINCE_TS" "$FILTER_PATH" "$FILTER_BRANCH" ;;
    breakdown)  mode_breakdown "$RAW" "$SINCE_TS" "$FILTER_PATH" "$FILTER_BRANCH" ;;
    summary)    mode_summary "$RAW" "$SINCE_TS" "$FILTER_PATH" "$FILTER_BRANCH" ;;
    csv)        mode_csv "$SINCE_TS" "$FILTER_PATH" "$FILTER_BRANCH" ;;
    statusline) mode_statusline ;;
    rotate)     mode_rotate ;;
esac
