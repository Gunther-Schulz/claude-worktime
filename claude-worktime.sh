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
# Known limitation: Claude Code hooks fire ~93% of the time. Missed events don't
# affect total active time but can skew the Claude/You breakdown by a few percent.
# Mitigation option: supplement hooks with transcript file mtime polling. Claude Code
# writes to ~/.claude/projects/{path-hash}/{session}.jsonl — checking its mtime
# detects activity even when hooks don't fire. See cyanglee/Kilok for this approach.
# This would add a heartbeat entry in the statusline command when mtime is recent
# but no hook event has fired recently.
#
# Usage:
#   claude-worktime log [--EVENT]           # append entry (called by hooks, reads stdin)
#   claude-worktime                         # current session stats
#   claude-worktime --today                 # today's total
#   claude-worktime --week                  # this week
#   claude-worktime --since 2026-03-25      # since a date
#   claude-worktime --filter PATH           # filter by project path
#   claude-worktime --branch BRANCH         # filter by git branch
#   claude-worktime --session ID             # stats for a specific session
#   claude-worktime --breakdown [--today]   # phase breakdown (Claude/You)
#   claude-worktime --gaps [--today]        # gap distribution (tune threshold)
#   claude-worktime --cost [--today]        # cost analysis (needs LOG_COST=true)
#   claude-worktime --summary [--today]     # per-project breakdown
#   claude-worktime --csv [--today]         # export as CSV
#   claude-worktime --statusline            # compact for status bar (reads stdin)
#   claude-worktime --rotate                # archive old entries
#   claude-worktime --check                 # verify dependencies
#   claude-worktime --debug                 # full diagnostic info
#   claude-worktime --repair                # remove corrupt log lines
#   claude-worktime --raw                   # JSON output (any mode)

set -euo pipefail
export LC_ALL=C

# Paths: env vars > XDG spec > defaults
CONFIGDIR="${CLAUDE_WORKTIME_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-worktime}"
CONFIGFILE="${CONFIGDIR}/config.sh"
DATADIR="${CLAUDE_WORKTIME_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/claude-worktime}"

# --- Defaults (overridden by config.sh) ---
PAUSE_THRESHOLD=900
STATUSLINE_FORMAT="{project} ({git}) · {status}  today {today_project} · total {project_total}"
STATUSLINE_FORMAT_2="{timeline} {today} · {since_break} {last_break} · {rate_5h} ↻{rate_5h_reset} {rate_5h_proj} · {rate_7d} 7d ↻{rate_7d_day} {rate_7d_proj}"
STATUSLINE_FORMAT_3=""
COLOR_NORMAL="\033[32m"
COLOR_RATE_WARNING="\033[33m"
COLOR_RATE_CRITICAL="\033[31m"
COLOR_TIMELINE_WORK=""   # color for ▮ blocks (empty = same as line color)
COLOR_TIMELINE_BREAK=""  # color for ▯ blocks (empty = same as line color)
TIMELINE_WIDTH=20  # number of blocks in {timeline} (adapts to day length)
COLOR_RESET="\033[0m"
RATE_7D_PROJ_MIN_DAYS=0.5
AUTO_ROTATE=true
ROTATE_INTERVAL=daily  # daily, weekly, monthly
GAP_BUCKETS="60,300,600,900,1800"  # seconds: 1m, 5m, 10m, 15m, 30m
LOG_COST=false  # log session cost snapshots (for API/extra usage billing)

[ -f "$CONFIGFILE" ] && source "$CONFIGFILE"

# DATADIR can be overridden in config.sh, so set LOGDIR/LOGFILE after sourcing
LOGDIR="${DATADIR}"
LOGFILE="${LOGDIR}/activity.jsonl"

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

# Reusable jq: compute phase breakdown — four categories
# claude = prompt→response (thinking, tools, output — Claude's turn)
# user = response→prompt within threshold (reading, thinking, typing — your turn)
# breaks = response→prompt over threshold, no "start" between (paused mid-session)
# downtime = response→start (quit and came back)
JQ_BREAKDOWN='def calc_breakdown($pause):
  . as $a | reduce range(1; $a|length) as $i (
    {claude: 0, user: 0, breaks: 0, break_count: 0, downtime: 0, downtime_count: 0};
    ($a[$i].t - $a[$i-1].t) as $gap
    | if $gap <= 0 then .
      elif $a[$i].e == "start" then .downtime += $gap | .downtime_count += 1
      elif ($a[$i-1].e == "response" or $a[$i-1].e == "start") and $gap > $pause then .breaks += $gap | .break_count += 1
      elif $a[$i-1].e == "response" or $a[$i-1].e == "start" then .user += $gap
      else .claude += $gap
      end);'

# --- Color name resolver: "red" → "\033[31m", passthrough for raw codes ---
_resolve_color() {
    case "${1:-}" in
        black)        echo "\033[30m" ;;
        red)          echo "\033[31m" ;;
        green)        echo "\033[32m" ;;
        yellow)       echo "\033[33m" ;;
        blue)         echo "\033[34m" ;;
        magenta)      echo "\033[35m" ;;
        cyan)         echo "\033[36m" ;;
        white)        echo "\033[37m" ;;
        gray|grey)    echo "\033[90m" ;;
        orange)       echo "\033[38;5;208m" ;;
        pink)         echo "\033[38;5;213m" ;;
        purple)       echo "\033[38;5;141m" ;;
        bright-green) echo "\033[1;32m" ;;
        bright-red)   echo "\033[1;31m" ;;
        bright-yellow) echo "\033[1;33m" ;;
        bright-blue)  echo "\033[1;34m" ;;
        bright-white) echo "\033[1;37m" ;;
        dim)          echo "\033[2m" ;;
        ""|none)      echo "" ;;
        *)            echo "$1" ;;  # passthrough raw ANSI codes
    esac
}

# Resolve all color config values
COLOR_NORMAL=$(_resolve_color "$COLOR_NORMAL")
COLOR_RATE_WARNING=$(_resolve_color "$COLOR_RATE_WARNING")
COLOR_RATE_CRITICAL=$(_resolve_color "$COLOR_RATE_CRITICAL")
COLOR_TIMELINE_WORK=$(_resolve_color "$COLOR_TIMELINE_WORK")
COLOR_TIMELINE_BREAK=$(_resolve_color "$COLOR_TIMELINE_BREAK")
COLOR_RESET=$(_resolve_color "${COLOR_RESET:-"\033[0m"}")

# --- Date helpers (GNU coreutils, BSD fallback) ---
_date_at() { date -d "@$1" "+$2" 2>/dev/null || date -r "$1" "+$2" 2>/dev/null; }
_today_start() { date -d "today 00:00" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$(date +%Y-%m-%d)" +%s 2>/dev/null; }
_week_start() {
    local dow; dow=$(date +%u)
    if [ "$dow" = "1" ]; then _today_start
    else date -d "last monday" +%s 2>/dev/null || date -j -v-monday +%s 2>/dev/null; fi
}
_date_parse() { date -d "$1" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$1" +%s 2>/dev/null || echo 0; }

# --- Dependency check ---
_require_jq() { command -v jq &>/dev/null || { echo "Error: jq is required." >&2; exit 1; }; }

# Read log file safely. Fast path: direct read. Fallback: skip corrupt lines.
_safe_log() {
    local file="${1:-$LOGFILE}"
    if jq -ce '.' "$file" >/dev/null 2>&1; then
        cat "$file"
    else
        jq -Rc 'fromjson? // empty' "$file" 2>/dev/null
    fi
}

# Minimum versions: bash 4.0, jq 1.6, git 2.22
cmd_check() {
    local ok=true

    # bash
    local bash_ver="${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"
    if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
        printf "  bash %s  ✓  (need ≥4.0)\n" "$bash_ver"
    else
        printf "  bash %s  ✗  (need ≥4.0 — mapfile, read -t fractional)\n" "$bash_ver"
        ok=false
    fi

    # jq
    if command -v jq &>/dev/null; then
        local jq_ver; jq_ver=$(jq --version 2>/dev/null | sed 's/jq-//')
        local jq_major; jq_major=$(echo "$jq_ver" | cut -d. -f1)
        local jq_minor; jq_minor=$(echo "$jq_ver" | cut -d. -f2)
        if [ "$jq_major" -ge 1 ] && [ "$jq_minor" -ge 6 ]; then
            printf "  jq %s  ✓  (need ≥1.6)\n" "$jq_ver"
        else
            printf "  jq %s  ✗  (need ≥1.6 — @tsv, try-catch, def args)\n" "$jq_ver"
            ok=false
        fi
    else
        printf "  jq  ✗  (not installed)\n"
        ok=false
    fi

    # git (optional)
    if command -v git &>/dev/null; then
        local git_ver; git_ver=$(git --version | sed 's/git version //')
        printf "  git %s  ✓  (optional, for {git} token)\n" "$git_ver"
    else
        printf "  git  —  (not installed, {git} token unavailable)\n"
    fi

    # date
    if date -d "today 00:00" +%s &>/dev/null; then
        printf "  date (GNU coreutils)  ✓\n"
    elif date -j -f "%Y-%m-%d" "2026-01-01" +%s &>/dev/null; then
        printf "  date (BSD)  ✓\n"
    else
        printf "  date  ✗  (neither GNU nor BSD date found)\n"
        ok=false
    fi

    echo ""
    $ok && echo "All dependencies met." || echo "Some dependencies missing or outdated."
    $ok
}

cmd_debug() {
    echo "claude-worktime debug"
    echo "====================="
    echo ""

    # Paths
    echo "Paths:"
    echo "  Config:     $CONFIGFILE $([ -f "$CONFIGFILE" ] && echo "✓" || echo "✗")"
    echo "  Data dir:   $LOGDIR"
    echo "  Log file:   $LOGFILE $([ -f "$LOGFILE" ] && echo "✓" || echo "✗")"
    echo ""

    # Log stats
    if [ -f "$LOGFILE" ]; then
        local total_lines valid_lines corrupt_lines
        total_lines=$(wc -l < "$LOGFILE")
        valid_lines=$(jq -Rc 'fromjson? // empty' "$LOGFILE" 2>/dev/null | wc -l)
        corrupt_lines=$((total_lines - valid_lines))
        local file_size; file_size=$(du -h "$LOGFILE" | cut -f1)
        echo "Log file:"
        echo "  Size:           $file_size"
        echo "  Total lines:    $total_lines"
        echo "  Valid entries:   $valid_lines"
        echo "  Corrupt lines:  $corrupt_lines"
        if [ "$corrupt_lines" -gt 0 ]; then
            echo "  ⚠ Corrupt lines found! Run with --repair to fix."
        fi

        # Session info
        local sid; sid=$(_current_session_id)
        echo "  Current session: ${sid:-none}"

        # Event counts
        echo "  Events:"
        jq -Rc 'fromjson? // empty' "$LOGFILE" 2>/dev/null \
            | jq -r 'select((.type // null) == null) | .e' 2>/dev/null \
            | sort | uniq -c | sort -rn | while read -r count event; do
                printf "    %-15s %s\n" "$event" "$count"
            done

        # Summaries
        local summary_count
        summary_count=$(jq -Rc 'fromjson? // empty' "$LOGFILE" 2>/dev/null | jq 'select(.type == "summary")' 2>/dev/null | wc -l)
        echo "  Summaries:      $summary_count"

        # Time range
        local first_ts last_ts
        first_ts=$(jq -Rc 'fromjson? // empty' "$LOGFILE" 2>/dev/null | jq -r 'select((.type // null) == null) | .t' 2>/dev/null | head -1 || true)
        last_ts=$(jq -Rc 'fromjson? // empty' "$LOGFILE" 2>/dev/null | jq -r 'select((.type // null) == null) | .t' 2>/dev/null | tail -1 || true)
        [ -n "$first_ts" ] && echo "  First entry:    $(_date_at "$first_ts" "%Y-%m-%d %H:%M")"
        [ -n "$last_ts" ] && echo "  Last entry:     $(_date_at "$last_ts" "%Y-%m-%d %H:%M")"

        # Projects
        echo "  Projects:"
        jq -Rc 'fromjson? // empty' "$LOGFILE" 2>/dev/null \
            | jq -r 'select((.type // null) == null) | .p' 2>/dev/null \
            | sort -u | while read -r p; do
                printf "    %s\n" "$(_short_project "$p")"
            done
    fi
    echo ""

    # Archives
    local archives=("$LOGDIR"/activity-*.jsonl)
    if [ -f "${archives[0]:-}" ]; then
        echo "Archives:"
        for f in "${archives[@]}"; do
            [ -f "$f" ] || continue
            local name; name=$(basename "$f")
            local lines; lines=$(wc -l < "$f")
            local size; size=$(du -h "$f" | cut -f1)
            printf "  %-30s %s lines  %s\n" "$name" "$lines" "$size"
        done
    else
        echo "Archives: none"
    fi
    echo ""

    # Config
    echo "Config:"
    echo "  PAUSE_THRESHOLD:    ${PAUSE_THRESHOLD}s ($((PAUSE_THRESHOLD / 60))min)"
    echo "  AUTO_ROTATE:        $AUTO_ROTATE"
    echo "  ROTATE_INTERVAL:    $ROTATE_INTERVAL"
    echo "  RATE_7D_PROJ_MIN:   ${RATE_7D_PROJ_MIN_DAYS} days"
    echo "  STATUSLINE_FORMAT:  $STATUSLINE_FORMAT"
    [ -n "${STATUSLINE_FORMAT_2:-}" ] && echo "  STATUSLINE_FORMAT_2: $STATUSLINE_FORMAT_2"
    [ -n "${STATUSLINE_FORMAT_3:-}" ] && echo "  STATUSLINE_FORMAT_3: $STATUSLINE_FORMAT_3"
    echo ""

    # Hooks
    local settings="${HOME}/.claude/settings.json"
    if [ -f "$settings" ]; then
        echo "Hooks in settings.json:"
        local hook
        for hook in SessionStart UserPromptSubmit PreToolUse PostToolUse Stop StopFailure; do
            if jq -e ".hooks.$hook" "$settings" &>/dev/null; then
                local cmd; cmd=$(jq -r ".hooks.${hook}[0].hooks[0].command // \"?\"" "$settings")
                printf "  %-20s ✓  %s\n" "$hook" "$cmd"
            else
                printf "  %-20s ✗  missing\n" "$hook"
            fi
        done
        if jq -e '.statusLine' "$settings" &>/dev/null; then
            local sl_cmd; sl_cmd=$(jq -r '.statusLine.command // "?"' "$settings")
            printf "  %-20s ✓  %s\n" "statusLine" "$sl_cmd"
        else
            printf "  %-20s ✗  not configured\n" "statusLine"
        fi
    else
        echo "Hooks: settings.json not found at $settings"
    fi
    echo ""

    # Performance
    echo "Performance:"
    local t0 t1
    t0=$(date +%s%N)
    ~/.local/bin/claude-worktime --statusline >/dev/null 2>&1
    t1=$(date +%s%N)
    echo "  Statusline: $(( (t1 - t0) / 1000000 ))ms"

    # Dependencies
    echo ""
    echo "Dependencies:"
    cmd_check
}

# --- Read hook stdin JSON ---
_read_hook_stdin() {
    HOOK_SESSION_ID=""
    HOOK_CWD=""
    _STDIN_JSON=""
    if read -t 0.1 -r _STDIN_JSON 2>/dev/null && [ -n "$_STDIN_JSON" ]; then
        # Fast bash parsing — avoid jq on the hot path
        # Extract "session_id":"VALUE" and "cwd":"VALUE" with parameter expansion
        local tmp="${_STDIN_JSON#*\"session_id\":\"}"
        HOOK_SESSION_ID="${tmp%%\"*}"
        [ "$HOOK_SESSION_ID" = "$_STDIN_JSON" ] && HOOK_SESSION_ID=""
        tmp="${_STDIN_JSON#*\"cwd\":\"}"
        HOOK_CWD="${tmp%%\"*}"
        [ "$HOOK_CWD" = "$_STDIN_JSON" ] && HOOK_CWD=""
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
    set +e  # hooks must not fail — a missed entry is better than blocking Claude Code
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

    # Write JSONL directly — escape \ and " for valid JSON, avoid jq on hot path
    local jp="${path//\\/\\\\}"; jp="${jp//\"/\\\"}"
    local jb="${branch//\\/\\\\}"; jb="${jb//\"/\\\"}"
    local js="${session_id//\\/\\\\}"; js="${js//\"/\\\"}"
    if [ -n "$branch" ]; then
        printf '{"t":%d,"p":"%s","b":"%s","s":"%s","e":"%s"}\n' "$ts" "$jp" "$jb" "$js" "$event" >> "$LOGFILE"
    else
        printf '{"t":%d,"p":"%s","s":"%s","e":"%s"}\n' "$ts" "$jp" "$js" "$event" >> "$LOGFILE"
    fi

    if [ "$event" = "start" ]; then
        # Auto-rotate on session start
        $AUTO_ROTATE && [ -f "$LOGFILE" ] && _do_rotate true
        printf '{"systemMessage":"Session timer started at %s"}' "$(date +%H:%M)"
    fi
}


# ============================================================
# Query helpers
# ============================================================

# Collect log files that may contain entries for the given time range
_log_files() {
    local since=${1:-0}
    # Always include the active log
    local files=("$LOGFILE")
    # If querying historical data, include matching archives
    if [ "$since" -gt 0 ]; then
        local f
        for f in "$LOGDIR"/activity-*.jsonl; do
            [ -f "$f" ] || continue
            files+=("$f")
        done
    fi
    printf '%s\n' "${files[@]}"
}

_entries() {
    local since=${1:-0} filter=${2:-} branch_filter=${3:-} session_filter=${4:-}
    local jq_filter=". | select((.type // null) == null) | select(.t >= $since)"
    [ -n "$filter" ] && jq_filter="$jq_filter | select(.p | test(\"$filter\"))"
    [ -n "$branch_filter" ] && jq_filter="$jq_filter | select(.b // \"\" | test(\"$branch_filter\"))"
    [ -n "$session_filter" ] && jq_filter="$jq_filter | select(.s | test(\"$session_filter\"))"

    local files
    # If filtering by session, always include archives (session may span rotation)
    local search_since="$since"
    [ -n "$session_filter" ] && search_since=1
    mapfile -t files < <(_log_files "$search_since")
    cat "${files[@]}" 2>/dev/null | jq -Rc 'fromjson? // empty' 2>/dev/null | jq -c "$jq_filter" 2>/dev/null || true
}

_session_entries() {
    local sid=$1
    local files
    mapfile -t files < <(_log_files 1)
    cat "${files[@]}" 2>/dev/null | jq -Rc 'fromjson? // empty' 2>/dev/null | jq -c --arg s "$sid" 'select(.s == $s)' 2>/dev/null || true
}

_current_session_id() {
    # Read last valid JSON line (skip any corrupt trailing lines)
    local line sid
    while IFS= read -r line; do
        sid=$(echo "$line" | jq -r '.s // empty' 2>/dev/null || true)
        [ -n "$sid" ] && { echo "$sid"; return; }
    done < <(tac "$LOGFILE" 2>/dev/null || true)
}

# ============================================================
# Statusline
# ============================================================

mode_statusline() {
    # Disable errexit in statusline — a crash should never blank the display
    set +e

    _read_hook_stdin

    local sid="${HOOK_SESSION_ID:-$(_current_session_id)}"
    [ -z "$sid" ] && { printf '%b' "⏱ --"; return; }

    local now=$(date +%s)

    local today_start; today_start=$(_today_start)

    # Single jq call: compute session info + today + today_project + project_total
    local all_info
    local _jq_query="
        ${JQ_CALC}
        . as \$raw
        | [.[] | select((.type // null) == null)] as \$all
        | (\$all | map(select(.s == \$sid)) | sort_by(.t)) as \$session
        | (\$all | map(select(.t >= \$since)) | sort_by(.t)) as \$today
        | (\$session | if length > 0 then ([.[] | .p] | last) else \"\" end) as \$proj
        | {
            session_active: (\$session | calc_active(\$pause)),
            first_t: (\$session | if length > 0 then .[0].t else 0 end),
            last_t: (\$session | if length > 0 then .[-1].t else 0 end),
            last_e: (\$session | if length > 0 then .[-1].e else \"\" end),
            last_break: ([range(\$today|length-1; 0; -1) as \$i
                | select(\$today[\$i].e == \"prompt\" and (\$today[\$i-1].e == \"response\" or \$today[\$i-1].e == \"start\"))
                | (\$today[\$i].t - \$today[\$i-1].t) | select(. > \$pause)] | first // 0),
            since_break: (\$today | . as \$s |
                ([range(length-1; 0; -1) as \$i
                    | select(\$s[\$i].e == \"prompt\" and (\$s[\$i-1].e == \"response\" or \$s[\$i-1].e == \"start\")
                        and (\$s[\$i].t - \$s[\$i-1].t) > \$pause)
                    | \$i] | first) as \$brk_idx
                | if \$brk_idx then \$s[\$brk_idx:] | calc_active(\$pause) else calc_active(\$pause) end),
            project: \$proj,
            branch: (\$session | [.[] | .b // empty] | if length > 0 then last else \"\" end),
            today_first_t: (\$today | if length > 0 then .[0].t else 0 end),
            today_active: (\$today | calc_active(\$pause)),
            today_project_active: (\$today | map(select(.p == \$proj)) | sort_by(.t) | calc_active(\$pause)),
            project_total_active: (
                (\$all | map(select(.p == \$proj)) | sort_by(.t) | calc_active(\$pause))
                + ([\$raw[] | select(.type == \"summary\" and .p == \$proj) | .active] | add // 0)
            ),
            timeline: (if \$width > 0 and (\$today | length) > 0 then
                (\$today[0].t) as \$tstart
                | ((\$now - \$tstart) / \$width + 1 | floor) as \$tblock
                # Build set of break block indices using rounded block count
                | [range(1; \$today|length)
                    | select(\$today[.].e == \"prompt\" and (\$today[.-1].e == \"response\" or \$today[.-1].e == \"start\")
                        and (\$today[.].t - \$today[.-1].t) > \$pause)
                    | {from: \$today[.-1].t, to: \$today[.].t}
                    | . as \$brk
                    | ((.to - .from) / \$tblock | ceil | if . < 1 then 1 else . end) as \$nblocks
                    | ((.from - \$tstart) / \$tblock | floor) as \$first_block
                    | range(\$first_block; \$first_block + \$nblocks)
                    | select(. >= 0 and . < \$width)
                ] | unique as \$break_blocks
                | [range(0; \$width) | . as \$i
                    | if ([\$break_blocks[] | select(. == \$i)] | length) > 0
                      then \"▯\"
                      elif ([\$today[] | select(.t >= (\$tstart + \$i * \$tblock) and .t < (\$tstart + (\$i + 1) * \$tblock))] | length) > 0
                      then \"▮\" else \"▯\" end
                ] | join(\"\")
              else \"\" end)
        }
        | [.session_active, .first_t, .last_t, .last_e, .last_break, .since_break, .today_first_t, .project, .branch, .today_active, .today_project_active, .project_total_active, .timeline]
        | @tsv
    "
    local tl_width=${TIMELINE_WIDTH:-20}
    local all_formats="${STATUSLINE_FORMAT}${STATUSLINE_FORMAT_2:-}${STATUSLINE_FORMAT_3:-}"
    [[ "$all_formats" != *"{timeline}"* ]] && tl_width=0
    local _jq_args=(--argjson pause "$PAUSE_THRESHOLD" --argjson since "$today_start" --arg sid "$sid" --argjson now "$now" --argjson width "$tl_width")

    # Fast path: direct read. Fallback: skip corrupt lines.
    all_info=$(jq -sr "${_jq_args[@]}" "$_jq_query" "$LOGFILE" 2>/dev/null) \
        || all_info=$(_safe_log "$LOGFILE" | jq -sr "${_jq_args[@]}" "$_jq_query")

    local session_active session_first session_last last_e last_break since_break today_first project branch today_active today_project_active project_total_active tok_timeline
    IFS=$'\t' read -r session_active session_first session_last last_e last_break since_break today_first project branch today_active today_project_active project_total_active tok_timeline <<< "$all_info"

    local session_wall=$(( now - session_first ))
    local gap=$(( now - session_last ))


    # Build tokens
    local proj_short; proj_short=$(_short_project "$project")
    local tok_session tok_session_wall tok_today tok_today_project tok_project_total tok_project tok_branch tok_last_break tok_since_break tok_git
    tok_session=$(_fmt_short "$session_active")
    tok_session_wall=$(_fmt_short "$session_wall")
    tok_today=$(_fmt_short "$today_active")
    tok_today_project=$(_fmt_short "$today_project_active")
    tok_project_total=$(_fmt_short "$project_total_active")
    tok_project="$proj_short"
    tok_branch="$branch"
    # Only show if there was an actual break (over threshold) this session
    tok_last_break=""
    tok_since_break=""
    local lb=${last_break:-0}
    local sb=${since_break:-0}
    if [ "$lb" -gt 0 ]; then
        tok_last_break="⏸ $(_fmt_short "$lb")"
        tok_since_break="▶$(_fmt_short "$sb")"
    fi


    # Git status — only compute if {git} is in any format string
    tok_git=""
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
            (.rate_limits.five_hour.used_percentage // "_"),
            (.rate_limits.five_hour.resets_at // "_"),
            (.rate_limits.seven_day.used_percentage // "_"),
            (.rate_limits.seven_day.resets_at // "_"),
            (.context_window.used_percentage // "_"),
            (.context_window.current_usage.cache_creation_input_tokens // "_"),
            (.context_window.current_usage.cache_read_input_tokens // "_"),
            (.cost.total_cost_usd // "_"),
            (.model.display_name // "_")
        ] | join("\t")' 2>/dev/null || true)

        local r5h r5h_reset r7d r7d_reset ctx cache_create cache_read cst mdl
        IFS=$'\t' read -r r5h r5h_reset r7d r7d_reset ctx cache_create cache_read cst mdl <<< "$stdin_parsed"
        # Replace placeholder with empty
        [ "$r5h" = "_" ] && r5h=""
        [ "$r5h_reset" = "_" ] && r5h_reset=""
        [ "$r7d" = "_" ] && r7d=""
        [ "$r7d_reset" = "_" ] && r7d_reset=""
        [ "$ctx" = "_" ] && ctx=""
        [ "$cache_create" = "_" ] && cache_create=""
        [ "$cache_read" = "_" ] && cache_read=""
        [ "$cst" = "_" ] && cst=""
        [ "$mdl" = "_" ] && mdl=""

        # Merge cache hit rate into context token: "77%·99%"
        if [ -n "$ctx" ] && [ -n "$cache_create" ] && [ -n "$cache_read" ]; then
            local cc=${cache_create%.*} cr=${cache_read%.*}
            local total=$(( ${cc:-0} + ${cr:-0} ))
            if [ "$total" -gt 0 ]; then
                local cache_pct=$(( ${cr:-0} * 100 / total ))
                tok_context="$(printf "%.0f" "$ctx")%·${cache_pct}%"
            else
                tok_context=$(printf "%.0f%%" "$ctx")
            fi
        elif [ -n "$ctx" ]; then
            tok_context=$(printf "%.0f%%" "$ctx")
        fi

        if [ -n "$r5h" ]; then
            local r5h_int; r5h_int=$(printf "%.0f" "$r5h")
            local r5h_icon="○"
            [ "$r5h_int" -ge 10 ] && r5h_icon="◔"
            [ "$r5h_int" -ge 25 ] && r5h_icon="◑"
            [ "$r5h_int" -ge 50 ] && r5h_icon="◕"
            [ "$r5h_int" -ge 75 ] && r5h_icon="●"
            tok_rate_5h="${r5h_icon}${r5h_int}%"
        fi
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

    # Log cost snapshot if enabled and cost changed
    if $LOG_COST && [ -n "${cst:-}" ]; then
        local last_cost
        last_cost=$(jq -r '[.[] | select(.type == "cost") | .cost] | last // 0' <(jq -Rc 'fromjson? // empty' "$LOGFILE") 2>/dev/null || echo 0)
        if [ "$last_cost" != "$cst" ]; then
            jq -nc --argjson t "$now" --arg p "$project" --arg s "$sid" \
                --argjson cost "$cst" --arg b "${branch:-}" \
                'if $b == "" then {type:"cost",t:$t,p:$p,s:$s,cost:$cost}
                 else {type:"cost",t:$t,p:$p,b:$b,s:$s,cost:$cost} end' >> "$LOGFILE"
        fi
    fi

    local tok_status="⏱"
    local color="$COLOR_NORMAL"

    # Colorize timeline blocks if colors are configured
    # Uses \033 escapes that printf '%b' will interpret in the final output
    if [ -n "${tok_timeline:-}" ]; then
        [ -n "$COLOR_TIMELINE_WORK" ] && tok_timeline="${tok_timeline//▮/${COLOR_TIMELINE_WORK}▮${COLOR_RESET}${color}}"
        [ -n "$COLOR_TIMELINE_BREAK" ] && tok_timeline="${tok_timeline//▯/${COLOR_TIMELINE_BREAK}▯${COLOR_RESET}${color}}"
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
        output="${output//\{status\}/$tok_status}"
        output="${output//\{git\}/$tok_git}"
        output="${output//\{timeline\}/$tok_timeline}"
        # Optional tokens: replace if set, remove entire · segment if empty
        local -a opt_tokens=( '{last_break}' '{since_break}' '{rate_5h}' '{rate_5h_reset}' '{rate_5h_proj}' '{rate_7d}' '{rate_7d_reset}' '{rate_7d_day}' '{rate_7d_proj}' '{context}' '{cost}' '{model}' )
        local -a opt_values=( "$tok_last_break" "$tok_since_break" "$tok_rate_5h" "$tok_rate_5h_reset" "$tok_rate_5h_proj" "$tok_rate_7d" "$tok_rate_7d_reset" "$tok_rate_7d_day" "$tok_rate_7d_proj" "$tok_context" "$tok_cost" "$tok_model" )
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

    local fmt1="$STATUSLINE_FORMAT"
    local fmt2="${STATUSLINE_FORMAT_2:-}"
    local fmt3="${STATUSLINE_FORMAT_3:-}"

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
    local raw=$1 since=$2 filter=$3 branch_filter=$4 session_filter=${5:-}
    local entries; entries=$(_entries "$since" "$filter" "$branch_filter" "$session_filter")

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
    local parsed
    parsed=$(echo "$info" | jq -r '[.active, .first, .project, .branch, (.session_id // "")] | @tsv')
    IFS=$'\t' read -r active first_ts project branch session_id <<< "$parsed"

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
    local raw=$1 since=$2 filter=$3 branch_filter=$4 session_filter=${5:-}
    local entries; entries=$(_entries "$since" "$filter" "$branch_filter" "$session_filter")

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

    local claude_time user_time breaks break_count downtime downtime_count active
    local bd_parsed
    bd_parsed=$(echo "$result" | jq -r '[.breakdown.claude, .breakdown.user, .breakdown.breaks, .breakdown.break_count, .breakdown.downtime, .breakdown.downtime_count, .active] | @tsv')
    IFS=$'\t' read -r claude_time user_time breaks break_count downtime downtime_count active <<< "$bd_parsed"

    if $raw; then
        echo "$result" | jq '{claude: .breakdown.claude, user: .breakdown.user, breaks: .breakdown.breaks, break_count: .breakdown.break_count, downtime: .breakdown.downtime, downtime_count: .breakdown.downtime_count, active: .active}'
    else
        local pct_claude=0 pct_user=0
        if [ "$active" -gt 0 ]; then
            pct_claude=$(( claude_time * 100 / active ))
            pct_user=$(( user_time * 100 / active ))
        fi

        printf "  Claude:     %-12s %d%%\n" "$(_fmt $claude_time)" "$pct_claude"
        printf "  You:        %-12s %d%%\n" "$(_fmt $user_time)" "$pct_user"
        echo "  ─────────────────────────"
        printf "  Active:     %s\n" "$(_fmt $active)"
        if [ "$breaks" -gt 0 ]; then
            printf "  Breaks:     %-12s (%d)\n" "$(_fmt $breaks)" "$break_count"
        fi
        if [ "$downtime" -gt 0 ]; then
            printf "  Downtime:   %-12s (%d)\n" "$(_fmt $downtime)" "$downtime_count"
        fi
    fi
}

mode_summary() {
    local raw=$1 since=$2 filter=$3 branch_filter=$4 session_filter=${5:-}
    local entries; entries=$(_entries "$since" "$filter" "$branch_filter" "$session_filter")

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

mode_cost() {
    local raw=$1 since=$2 filter=$3 branch_filter=$4 session_filter=${5:-}

    # Get cost entries from all relevant log files
    local files
    mapfile -t files < <(_log_files "$since")
    local cost_filter='. | select(.type == "cost")'
    [ "$since" -gt 0 ] && cost_filter="$cost_filter | select(.t >= $since)"
    [ -n "$filter" ] && cost_filter="$cost_filter | select(.p | test(\"$filter\"))"
    [ -n "$branch_filter" ] && cost_filter="$cost_filter | select(.b // \"\" | test(\"$branch_filter\"))"

    local cost_entries
    cost_entries=$(cat "${files[@]}" 2>/dev/null | jq -Rc 'fromjson? // empty' 2>/dev/null | jq -c "$cost_filter" 2>/dev/null || true)

    if [ -z "$cost_entries" ]; then
        if $raw; then echo '{"total":0,"sessions":{}}'
        else echo "No cost data recorded. Enable with LOG_COST=true in config."; fi
        return
    fi

    if $raw; then
        echo "$cost_entries" | jq -s '
            group_by(.s) | map({
                session: .[0].s,
                project: ([.[] | .p] | last | split("/") | if length >= 2 then [.[-2], .[-1]] | join("/") else last end),
                branch: ([.[] | .b // empty] | if length > 0 then last else "" end),
                cost: (if length > 1 then (.[-1].cost - .[0].cost) else .[-1].cost end)
            }) | {
                total: (map(.cost) | add // 0),
                by_project: (group_by(.project) | map({project: .[0].project, cost: ([.[].cost] | add)}) | sort_by(-.cost))
            }'
    else
        # Per-session cost (diff of first and last cost entry per session)
        local result
        result=$(echo "$cost_entries" | jq -s '
            group_by(.s) | map({
                session: .[0].s[:12],
                project: ([.[] | .p] | last | split("/") | if length >= 2 then [.[-2], .[-1]] | join("/") else last end),
                branch: ([.[] | .b // empty] | if length > 0 then last else "" end),
                cost: (if length > 1 then (.[-1].cost - .[0].cost) else .[-1].cost end),
                cost_abs: .[-1].cost
            }) | sort_by(-.cost)
        ')

        local total
        total=$(echo "$result" | jq '[.[].cost] | add // 0')

        # Per-project summary
        echo "Cost by project:"
        echo "$result" | jq -r '
            group_by(.project) | map({
                project: .[0].project,
                cost: ([.[].cost] | add)
            }) | sort_by(-.cost) | .[]
            | "  \(.project)  $\(.cost | . * 100 | round / 100)"
        '

        echo ""
        printf "  Total: $%.2f\n" "$total"
    fi
}

mode_csv() {
    local since=$1 filter=$2 branch_filter=$3 session_filter=${4:-}
    local entries; entries=$(_entries "$since" "$filter" "$branch_filter" "$session_filter")

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

mode_gaps() {
    local raw=$1 since=$2 filter=$3 branch_filter=$4 session_filter=${5:-}
    local entries; entries=$(_entries "$since" "$filter" "$branch_filter" "$session_filter")

    if [ -z "$entries" ]; then
        if $raw; then echo '{}'; else echo "No activity recorded"; fi; return; fi

    local buckets_jq="[${GAP_BUCKETS}]"

    local result
    result=$(echo "$entries" | jq -sr --argjson pause "$PAUSE_THRESHOLD" --argjson buckets "$buckets_jq" '
        def bucket_gaps($gaps; $bounds; $pause):
            [range(0; $bounds | length) as $i |
                (if $i == 0 then 0 else $bounds[$i-1] end) as $lo | $bounds[$i] as $hi
                | {
                    label: (if $i == 0 then "< \($bounds[0] / 60 | floor)min"
                            elif $i == ($bounds | length) - 1 then "> \($bounds[$i-1] / 60 | floor)min"
                            else "\($lo / 60 | floor)-\($hi / 60 | floor)min" end),
                    count: ([$gaps[] | select(. >= $lo and . < $hi)] | length),
                    total: ([$gaps[] | select(. >= $lo and . < $hi)] | add // 0),
                    is_active: ($lo < $pause)
                }];
        sort_by(.t) | . as $a
        | ($buckets + [99999999]) as $bounds
        # Separate breaks (response→prompt, no start between) from downtime (→start)
        | [range(1; length)
            | select($a[.-1].e == "response" or $a[.-1].e == "start")
            | {gap: ($a[.].t - $a[.-1].t), is_downtime: ($a[.].e == "start")}]
        | {
            breaks: bucket_gaps([.[] | select(.is_downtime | not) | .gap]; $bounds; $pause),
            downtime: [.[] | select(.is_downtime) | .gap],
            near_threshold: ([.[] | select(.is_downtime | not) | .gap | select(. >= ($pause * 0.67) and . < $pause)] | length),
            threshold: $pause
          }
    ')

    if $raw; then
        echo "$result"
    else
        local thresh_min=$(( PAUSE_THRESHOLD / 60 ))

        echo "Within sessions (threshold: ${thresh_min}min):"
        echo ""
        echo "$result" | jq -r '
            .breaks[] | select(.count > 0)
            | "  \(if .is_active then "✓" else "⏸" end) \(.label | . + " " * (12 - length))  \(.count | tostring | . + " " * (4 - length)) \(.total / 60 | floor)min"
        '

        local dt_count dt_total
        dt_count=$(echo "$result" | jq '[.downtime[]] | length')
        dt_total=$(echo "$result" | jq '[.downtime[]] | add // 0')
        if [ "$dt_count" -gt 0 ]; then
            echo ""
            echo "Between sessions (downtime):"
            echo "  $dt_count gaps  $(_fmt $dt_total)"
        fi

        echo ""
        local near; near=$(echo "$result" | jq -r '.near_threshold')
        echo "  $near gaps within 2/3 of threshold"
        if [ "$near" -gt 3 ]; then
            echo "  ⚠ Many gaps near threshold — consider lowering PAUSE_THRESHOLD"
        fi
    fi
}

# Compute the cutoff timestamp and archive suffix for the current rotation interval
_rotate_boundaries() {
    case "$ROTATE_INTERVAL" in
        daily)
            ROTATE_CUTOFF=$(date -d "today 00:00" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$(date +%Y-%m-%d)" +%s 2>/dev/null)
            ROTATE_SUFFIX=$(date -d "yesterday" +%Y-%m-%d 2>/dev/null || date -j -v-1d +%Y-%m-%d 2>/dev/null)
            ;;
        weekly)
            local dow; dow=$(date +%u)
            if [ "$dow" = "1" ]; then
                ROTATE_CUTOFF=$(date -d "today 00:00" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$(date +%Y-%m-%d)" +%s 2>/dev/null)
            else
                ROTATE_CUTOFF=$(date -d "last monday" +%s 2>/dev/null || date -j -v-monday +%s 2>/dev/null)
            fi
            ROTATE_SUFFIX=$(date -d "@$((ROTATE_CUTOFF - 1))" +%Y-W%V 2>/dev/null || date -r "$((ROTATE_CUTOFF - 1))" +%Y-W%V 2>/dev/null)
            ;;
        monthly|*)
            ROTATE_CUTOFF=$(date -d "$(date +%Y-%m-01)" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$(date +%Y-%m-01)" +%s 2>/dev/null)
            ROTATE_SUFFIX=$(date -d "last month" +%Y-%m 2>/dev/null || date -j -v-1m +%Y-%m 2>/dev/null)
            ;;
    esac
}

_do_rotate() {
    local quiet=${1:-false}
    [ ! -f "$LOGFILE" ] && return

    _rotate_boundaries

    # Check if there are old event entries (skip summaries)
    local first_event_ts
    first_event_ts=$(jq -r 'select((.type // null) == null) | .t' "$LOGFILE" 2>/dev/null | head -1 || true)
    [ -z "$first_event_ts" ] || [ "$first_event_ts" -ge "$ROTATE_CUTOFF" ] && return

    # Write per-project summaries before archiving
    local summaries
    summaries=$(jq -sc --argjson since "$ROTATE_CUTOFF" --argjson pause "$PAUSE_THRESHOLD" "
        ${JQ_CALC}
        [.[] | select(.t < \$since)] | group_by(.p) | map({
            type: \"summary\",
            p: .[0].p,
            active: (sort_by(.t) | calc_active(\$pause)),
            period: \"$ROTATE_SUFFIX\"
        }) | .[]
    " "$LOGFILE" 2>/dev/null || true)

    # Archive old event entries (not summaries)
    local old_entries
    old_entries=$(jq -c --argjson since "$ROTATE_CUTOFF" 'select((.type // null) == null and .t < $since)' "$LOGFILE" 2>/dev/null || true)
    [ -z "$old_entries" ] && return

    local archive="${LOGDIR}/activity-${ROTATE_SUFFIX}.jsonl"
    echo "$old_entries" >> "$archive"

    # Keep: existing summaries + new summaries + current event entries
    local existing_summaries current_entries
    existing_summaries=$(jq -c 'select(.type == "summary")' "$LOGFILE" 2>/dev/null || true)
    current_entries=$(jq -c --argjson since "$ROTATE_CUTOFF" 'select((.type // null) == null and .t >= $since)' "$LOGFILE" 2>/dev/null || true)

    { [ -n "$existing_summaries" ] && echo "$existing_summaries"
      [ -n "$summaries" ] && echo "$summaries"
      [ -n "$current_entries" ] && echo "$current_entries"
    } > "${LOGFILE}.tmp" && mv "${LOGFILE}.tmp" "$LOGFILE"

    if ! $quiet; then
        local old_count
        old_count=$(echo "$old_entries" | wc -l)
        echo "Rotated $old_count entries to $archive"
    fi
}

mode_rotate() {
    [ ! -f "$LOGFILE" ] && { echo "No log file to rotate"; return; }
    _rotate_boundaries
    local first_event_ts
    first_event_ts=$(jq -r 'select((.type // null) == null) | .t' "$LOGFILE" 2>/dev/null | head -1 || true)
    if [ -z "$first_event_ts" ] || [ "$first_event_ts" -ge "$ROTATE_CUTOFF" ]; then
        echo "Nothing to rotate (all entries are from current $ROTATE_INTERVAL period)"
        return
    fi
    _do_rotate false
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
    --check) cmd_check; exit $? ;;
    --debug) cmd_debug; exit $? ;;
    --repair)
        [ ! -f "$LOGFILE" ] && { echo "No log file"; exit 0; }
        _before=$(wc -l < "$LOGFILE")
        _safe_log "$LOGFILE" > "${LOGFILE}.tmp" && mv "${LOGFILE}.tmp" "$LOGFILE"
        _after=$(wc -l < "$LOGFILE")
        echo "Removed $((_before - _after)) corrupt lines ($_before → $_after)"
        exit 0
        ;;
esac

_require_jq

MODE="session"
RAW=false
FILTER_PATH=""
FILTER_BRANCH=""
FILTER_SESSION=""
SINCE_TS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --raw) RAW=true ;;
        --summary) MODE="summary" ;;
        --breakdown) MODE="breakdown" ;;
        --gaps) MODE="gaps" ;;
        --cost) MODE="cost" ;;
        --csv) MODE="csv" ;;
        --statusline) MODE="statusline" ;;
        --rotate) MODE="rotate" ;;
        --filter) shift; FILTER_PATH="${1:-}"; [ "$MODE" = "session" ] && MODE="range" ;;
        --branch) shift; FILTER_BRANCH="${1:-}"; [ "$MODE" = "session" ] && MODE="range" ;;
        --session) shift; FILTER_SESSION="${1:-}"; [ "$MODE" = "session" ] && MODE="range" ;;
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
    range)      mode_range "$RAW" "$SINCE_TS" "$FILTER_PATH" "$FILTER_BRANCH" "$FILTER_SESSION" ;;
    breakdown)  mode_breakdown "$RAW" "$SINCE_TS" "$FILTER_PATH" "$FILTER_BRANCH" "$FILTER_SESSION" ;;
    gaps)       mode_gaps "$RAW" "$SINCE_TS" "$FILTER_PATH" "$FILTER_BRANCH" "$FILTER_SESSION" ;;
    cost)       mode_cost "$RAW" "$SINCE_TS" "$FILTER_PATH" "$FILTER_BRANCH" "$FILTER_SESSION" ;;
    summary)    mode_summary "$RAW" "$SINCE_TS" "$FILTER_PATH" "$FILTER_BRANCH" "$FILTER_SESSION" ;;
    csv)        mode_csv "$SINCE_TS" "$FILTER_PATH" "$FILTER_BRANCH" "$FILTER_SESSION" ;;
    statusline) mode_statusline ;;
    rotate)     mode_rotate ;;
esac
