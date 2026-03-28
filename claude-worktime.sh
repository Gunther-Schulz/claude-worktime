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
#   claude-worktime                         # current session stats
#   claude-worktime --today                 # today's total
#   claude-worktime --week                  # this week
#   claude-worktime --since 2026-03-25      # since a date
#   claude-worktime --filter PATH           # filter by project path
#   claude-worktime --branch BRANCH         # filter by git branch
#   claude-worktime --breakdown [--today]   # phase breakdown (Claude/You)
#   claude-worktime --summary [--today]     # per-project breakdown
#   claude-worktime --csv [--today]         # export as CSV
#   claude-worktime --statusline            # compact for status bar (reads stdin)
#   claude-worktime --rotate                # archive old entries
#   claude-worktime --raw                   # JSON output (any mode)

set -euo pipefail
export LC_ALL=C

LOGDIR="${CLAUDE_WORKTIME_DIR:-${HOME}/.claude/worktime}"
LOGFILE="${LOGDIR}/activity.log"
CONFIGFILE="${LOGDIR}/config.sh"

# --- Defaults (overridden by config.sh) ---
PAUSE_THRESHOLD=900
STATUSLINE_FORMAT="{status} session {session} · today {today} · {project}"
STATUSLINE_FORMAT_2=""
STATUSLINE_FORMAT_3=""
STATUSLINE_IDLE_FORMAT="{status} idle {idle} · session {session} · today {today} · {project}"
STATUSLINE_IDLE_FORMAT_2=""
STATUSLINE_IDLE_FORMAT_3=""
COLOR_NORMAL="\033[32m"
COLOR_IDLE="\033[90m"
COLOR_RATE_WARNING="\033[33m"
COLOR_RATE_CRITICAL="\033[31m"
COLOR_RESET="\033[0m"
RATE_7D_PROJ_MIN_DAYS=0.5

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
    _STDIN_JSON=""
    if read -t 1 -r _STDIN_JSON 2>/dev/null && [ -n "$_STDIN_JSON" ]; then
        local parsed
        parsed=$(echo "$_STDIN_JSON" | jq -r '[.session_id // "", .cwd // ""] | @tsv' 2>/dev/null || true)
        HOOK_SESSION_ID="${parsed%%	*}"
        HOOK_CWD="${parsed#*	}"
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
    local p="${1%/}"
    local last="${p##*/}"
    local rest="${p%/*}"
    local second="${rest##*/}"
    if [ -n "$second" ] && [ "$second" != "$last" ]; then
        echo "$second/$last"
    else
        echo "$last"
    fi
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

    # Write JSONL directly — avoid jq subprocess on the hot path
    if [ -n "$branch" ]; then
        printf '{"t":%d,"p":"%s","b":"%s","s":"%s","e":"%s"}\n' "$ts" "$path" "$branch" "$session_id" "$event" >> "$LOGFILE"
    else
        printf '{"t":%d,"p":"%s","s":"%s","e":"%s"}\n' "$ts" "$path" "$session_id" "$event" >> "$LOGFILE"
    fi

    if [ "$event" = "start" ]; then
        printf '{"systemMessage":"Session timer started at %s"}' "$(date +%H:%M)"
    fi
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
# Statusline
# ============================================================

mode_statusline() {
    _read_hook_stdin

    local sid="${HOOK_SESSION_ID:-$(_current_session_id)}"
    [ -z "$sid" ] && { printf '%b' "${COLOR_IDLE}⏱ --${COLOR_RESET}"; return; }

    local now=$(date +%s)

    local today_start; today_start=$(_today_start)

    # Single jq call: compute session info + today + today_project + project_total
    local all_info
    all_info=$(jq -s --argjson pause "$PAUSE_THRESHOLD" --argjson since "$today_start" --arg sid "$sid" "
        ${JQ_CALC}
        . as \$all
        | (\$all | map(select(.s == \$sid)) | sort_by(.t)) as \$session
        | (\$all | map(select(.t >= \$since)) | sort_by(.t)) as \$today
        | (\$session | if length > 0 then ([.[] | .p] | last) else \"\" end) as \$proj
        | {
            session_active: (\$session | calc_active(\$pause)),
            first_t: (\$session | if length > 0 then .[0].t else 0 end),
            last_t: (\$session | if length > 0 then .[-1].t else 0 end),
            last_e: (\$session | if length > 0 then .[-1].e else \"\" end),
            project: \$proj,
            branch: (\$session | [.[] | .b // empty] | if length > 0 then last else \"\" end),
            today_active: (\$today | calc_active(\$pause)),
            today_project_active: (\$today | map(select(.p == \$proj)) | sort_by(.t) | calc_active(\$pause)),
            project_total_active: (\$all | map(select(.p == \$proj)) | sort_by(.t) | calc_active(\$pause))
        }
    " "$LOGFILE")

    local session_active session_first session_last last_e project branch today_active today_project_active project_total_active
    session_active=$(echo "$all_info" | jq -r '.session_active')
    session_first=$(echo "$all_info" | jq -r '.first_t')
    session_last=$(echo "$all_info" | jq -r '.last_t')
    last_e=$(echo "$all_info" | jq -r '.last_e')
    project=$(echo "$all_info" | jq -r '.project')
    branch=$(echo "$all_info" | jq -r '.branch')
    today_active=$(echo "$all_info" | jq -r '.today_active')
    today_project_active=$(echo "$all_info" | jq -r '.today_project_active')
    project_total_active=$(echo "$all_info" | jq -r '.project_total_active')

    local session_wall=$(( now - session_first ))
    local gap=$(( now - session_last ))

    local is_idle=false
    if [ "$gap" -gt "$PAUSE_THRESHOLD" ] && { [ "$last_e" = "response" ] || [ "$last_e" = "start" ]; }; then
        is_idle=true
    fi

    # Build tokens
    local proj_short; proj_short=$(_short_project "$project")
    local tok_session tok_session_wall tok_today tok_today_project tok_project_total tok_project tok_branch tok_idle tok_git
    tok_session=$(_fmt_short "$session_active")
    tok_session_wall=$(_fmt_short "$session_wall")
    tok_today=$(_fmt_short "$today_active")
    tok_today_project=$(_fmt_short "$today_project_active")
    tok_project_total=$(_fmt_short "$project_total_active")
    tok_project="$proj_short"
    tok_branch="$branch"
    tok_idle=$(_fmt_short "$gap")

    # Git status — only compute if {git} is in any format string
    tok_git=""
    local all_formats="${STATUSLINE_FORMAT}${STATUSLINE_FORMAT_2:-}${STATUSLINE_FORMAT_3:-}${STATUSLINE_IDLE_FORMAT}${STATUSLINE_IDLE_FORMAT_2:-}${STATUSLINE_IDLE_FORMAT_3:-}"
    if [[ "$all_formats" == *"{git}"* ]] && [ -n "$project" ]; then
        local git_status git_str=""
        git_status=$(git -C "$project" status --porcelain -b 2>/dev/null || true)
        if [ -n "$git_status" ]; then
            local git_branch_line git_state=""
            git_branch_line=$(echo "$git_status" | head -1)
            # Branch name from "## branch...tracking"
            local gb
            gb=$(echo "$git_branch_line" | sed 's/^## //; s/\.\.\..*//')
            # Ahead/behind
            local ahead="" behind=""
            [[ "$git_branch_line" == *"ahead "* ]] && ahead=$(echo "$git_branch_line" | sed 's/.*ahead \([0-9]*\).*/\1/')
            [[ "$git_branch_line" == *"behind "* ]] && behind=$(echo "$git_branch_line" | sed 's/.*behind \([0-9]*\).*/\1/')
            # Working tree state
            local dirty=false staged=false untracked=false
            local file_lines
            file_lines=$(echo "$git_status" | tail -n +2)
            if [ -n "$file_lines" ]; then
                echo "$file_lines" | grep -q '^[MADRC]' && staged=true
                echo "$file_lines" | grep -q '^.[MDRC]' && dirty=true
                echo "$file_lines" | grep -q '^??' && untracked=true
            fi
            # Build state string
            if ! $dirty && ! $staged && ! $untracked; then
                git_state="✓"
            else
                $staged && git_state="${git_state}+"
                $dirty && git_state="${git_state}✗"
                $untracked && git_state="${git_state}?"
            fi
            [ -n "$ahead" ] && git_state="${git_state}↑${ahead}"
            [ -n "$behind" ] && git_state="${git_state}↓${behind}"
            tok_git="${gb} ${git_state}"
        fi
    fi

    # Tokens from Claude Code stdin JSON (rate limits, context, cost, model)
    local tok_rate_5h="" tok_rate_5h_reset="" tok_rate_5h_proj="" tok_rate_7d="" tok_rate_7d_reset="" tok_rate_7d_day="" tok_rate_7d_proj="" tok_context="" tok_cost="" tok_model=""
    if [ -n "${_STDIN_JSON:-}" ]; then
        # Single jq call to extract all fields
        local stdin_parsed
        stdin_parsed=$(echo "$_STDIN_JSON" | jq -r '[
            (.rate_limits.five_hour.used_percentage // ""),
            (.rate_limits.five_hour.resets_at // ""),
            (.rate_limits.seven_day.used_percentage // ""),
            (.rate_limits.seven_day.resets_at // ""),
            (.context_window.used_percentage // ""),
            (.cost.total_cost_usd // ""),
            (.model.display_name // "")
        ] | @tsv' 2>/dev/null || true)

        local r5h r5h_reset r7d r7d_reset ctx cst mdl
        IFS=$'\t' read -r r5h r5h_reset r7d r7d_reset ctx cst mdl <<< "$stdin_parsed"

        [ -n "$r5h" ] && tok_rate_5h=$(printf "%.0f%%" "$r5h")
        [ -n "$r5h_reset" ] && tok_rate_5h_reset=$(_fmt_short $(( r5h_reset - now )))
        [ -n "$r7d" ] && tok_rate_7d=$(printf "%.0f%%" "$r7d")
        [ -n "$r7d_reset" ] && tok_rate_7d_reset=$(_fmt_short $(( r7d_reset - now )))
        [ -n "$r7d_reset" ] && tok_rate_7d_day=$(date -d "@$r7d_reset" +%a 2>/dev/null || date -r "$r7d_reset" +%a 2>/dev/null)
        [ -n "$ctx" ] && tok_context=$(printf "%.0f%%" "$ctx")
        [ -n "$cst" ] && tok_cost=$(printf "$%.2f" "$cst")
        [ -n "$mdl" ] && tok_model="$mdl"

        # Projected rate limit usage at window reset
        # burn_rate = used% / elapsed_time, projected = used% + burn_rate * remaining_time
        _project_rate() {
            local used=$1 reset_at=$2 window=$3
            local remaining=$(( reset_at - now ))
            local elapsed=$(( window - remaining ))
            [ "$elapsed" -le 60 ] && return  # need at least 1min of data
            local proj
            proj=$(awk "BEGIN { rate = $used / $elapsed; proj = $used + rate * $remaining; printf \"%.0f\", proj }")
            local proj_color=""
            if [ "$proj" -ge 100 ] && [ -n "${COLOR_RATE_CRITICAL:-}" ]; then
                proj_color="$COLOR_RATE_CRITICAL"
            elif [ "$proj" -ge 90 ] && [ -n "${COLOR_RATE_WARNING:-}" ]; then
                proj_color="$COLOR_RATE_WARNING"
            fi
            if [ -n "$proj_color" ]; then
                printf '%s' "${proj_color}→${proj}%${COLOR_RESET}"
            else
                printf '%s' "→${proj}%"
            fi
        }
        [ -n "$r5h" ] && [ -n "$r5h_reset" ] && tok_rate_5h_proj=$(_project_rate "$r5h" "$r5h_reset" 18000)
        # 7d projection: average by daily buckets (resets Fridays)
        if [ -n "$r7d" ] && [ -n "$r7d_reset" ]; then
            local days_elapsed days_total=7
            days_elapsed=$(awk "BEGIN { d = ($days_total * 86400 - ($r7d_reset - $now)) / 86400; printf \"%.2f\", (d > 0.01 ? d : 0.01) }")
            local enough_data
            enough_data=$(awk "BEGIN { print ($days_elapsed >= ${RATE_7D_PROJ_MIN_DAYS}) ? 1 : 0 }")
            if [ "$enough_data" = "1" ]; then
                local proj
                proj=$(awk "BEGIN { daily = $r7d / $days_elapsed; printf \"%.0f\", daily * $days_total }")
                local proj_color=""
                if [ "$proj" -ge 100 ] && [ -n "${COLOR_RATE_CRITICAL:-}" ]; then
                    proj_color="$COLOR_RATE_CRITICAL"
                elif [ "$proj" -ge 90 ] && [ -n "${COLOR_RATE_WARNING:-}" ]; then
                    proj_color="$COLOR_RATE_WARNING"
                fi
                if [ -n "$proj_color" ]; then
                    tok_rate_7d_proj="${proj_color}→${proj}%${COLOR_RESET}"
                else
                    tok_rate_7d_proj="→${proj}%"
                fi
            fi
        fi
    fi

    # Status icon and color
    local tok_status color
    if $is_idle; then
        tok_status="⏸"
        color="$COLOR_IDLE"
    else
        tok_status="⏱"
        color="$COLOR_NORMAL"
    fi

    # Render a format string: replace all tokens, clean up empty segments
    _render_line() {
        local output="$1"
        # Always-available tokens (simple substitution)
        output="${output//\{session\}/$tok_session}"
        output="${output//\{session_wall\}/$tok_session_wall}"
        output="${output//\{today\}/$tok_today}"
        output="${output//\{today_project\}/$tok_today_project}"
        output="${output//\{project_total\}/$tok_project_total}"
        output="${output//\{project\}/$tok_project}"
        output="${output//\{branch\}/$tok_branch}"
        output="${output//\{idle\}/$tok_idle}"
        output="${output//\{status\}/$tok_status}"
        output="${output//\{git\}/$tok_git}"
        # Optional tokens: replace if set, remove entire · segment if empty
        local -a opt_tokens=( '{rate_5h}' '{rate_5h_reset}' '{rate_5h_proj}' '{rate_7d}' '{rate_7d_reset}' '{rate_7d_day}' '{rate_7d_proj}' '{context}' '{cost}' '{model}' )
        local -a opt_values=( "$tok_rate_5h" "$tok_rate_5h_reset" "$tok_rate_5h_proj" "$tok_rate_7d" "$tok_rate_7d_reset" "$tok_rate_7d_day" "$tok_rate_7d_proj" "$tok_context" "$tok_cost" "$tok_model" )
        local i
        for i in "${!opt_tokens[@]}"; do
            [[ "$output" != *"${opt_tokens[$i]}"* ]] && continue
            if [ -n "${opt_values[$i]}" ]; then
                output="${output//${opt_tokens[$i]}/${opt_values[$i]}}"
            else
                output=$(echo "$output" | sed "s/ *· *[^·]*${opt_tokens[$i]}[^·]*//g; s/[^·]*${opt_tokens[$i]}[^·]* *· *//g; s/[^·]*${opt_tokens[$i]}[^·]*//g")
            fi
        done
        # Clean up
        output=$(echo "$output" | sed 's/ *() *//g; s/ *· */ · /g; s/ · · / · /g; s/^ *//; s/ *$//; s/^ · //; s/ · $//')
        echo "$output"
    }

    local fmt1 fmt2 fmt3
    if $is_idle; then
        fmt1="$STATUSLINE_IDLE_FORMAT"
        fmt2="${STATUSLINE_IDLE_FORMAT_2:-${STATUSLINE_FORMAT_2:-}}"
        fmt3="${STATUSLINE_IDLE_FORMAT_3:-${STATUSLINE_FORMAT_3:-}}"
    else
        fmt1="$STATUSLINE_FORMAT"
        fmt2="${STATUSLINE_FORMAT_2:-}"
        fmt3="${STATUSLINE_FORMAT_3:-}"
    fi

    printf '%b' "${color}$(_render_line "$fmt1")${COLOR_RESET}"

    local extra line
    for extra in "$fmt2" "$fmt3"; do
        [ -z "$extra" ] && continue
        line=$(_render_line "$extra")
        [ -n "$line" ] && printf '\n%b' "${color}${line}${COLOR_RESET}"
    done
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

    # Single pass: split into old and current
    local old_entries current_entries
    old_entries=$(jq -c --argjson since "$month_start" 'select(.t < $since)' "$LOGFILE" 2>/dev/null || true)
    [ -z "$old_entries" ] && { echo "Nothing to rotate (all entries are from this month)"; return; }

    echo "$old_entries" >> "$archive"
    jq -c --argjson since "$month_start" 'select(.t >= $since)' "$LOGFILE" > "${LOGFILE}.tmp" \
        && mv "${LOGFILE}.tmp" "$LOGFILE"

    local old_count
    old_count=$(echo "$old_entries" | wc -l)
    echo "Rotated $old_count entries to $archive"
}

# ============================================================
# Main
# ============================================================

case "${1:-}" in
    log)  shift; cmd_log "$@"; exit 0 ;;
    -h|--help|help)
        sed -n '2,/^$/{ s/^# //; s/^#//; p }' "$0"
        exit 0
        ;;
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
