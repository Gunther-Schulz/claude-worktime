#!/bin/bash
# claude-worktime — track active working time in Claude Code sessions
#
# JSONL log: {"t":TS,"p":"/path","b":"branch","s":"session-id","e":"EVENT"}
# Event types: start, prompt, tool_start, tool_end, response
#
# Active time: a gap is idle when the user had the ball (prev event was response/start)
# and the gap exceeds PAUSE_THRESHOLD. All other gaps are active work time.
# Presence: prompt-to-prompt spans exceeding threshold = user was away.
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
#   claude-worktime --cost [--today]        # cost analysis
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
CLAUDE_CREDIT=0          # seconds of Claude response time credited as "user watching"
                         # 0 = auto (PAUSE_THRESHOLD / 3, ~5min at default 15min threshold)
GROUP_PROJECT="{project} ({git})"
GROUP_TODAY="{status} today {today_project} 🤖{today_claude} 👤{today_you}"
GROUP_TOTAL="total {project_total}"
GROUP_TIMELINE="{today_start} {timeline} {today_now}"
GROUP_BREAKS="{since_break} {last_break}"
GROUP_RATE_5H="{rate_5h} ↻{rate_5h_reset} {rate_5h_proj}"
GROUP_RATE_7D="⑦{rate_7d} ↻{rate_7d_day} {rate_7d_proj}"
GROUP_CONTEXT="ctx {context}"
GROUP_MODEL="{model}"
# token_budget removed: weighted tokens only tracked main conversation,
# missing subagent costs (1.1-2.4x underestimate). Use {cost_budget} instead.
GROUP_TOKENS=""
GROUP_RATE_7D_COLOR="dark-gray"
GROUP_CONTEXT_COLOR="dark-gray"
GROUP_BUDGET_COLOR="dark-gray"
GROUP_DIVIDER=" · "
STATUSLINE_1="PROJECT TODAY TOTAL"
STATUSLINE_2="TIMELINE BREAKS"
STATUSLINE_3="MODEL RATE_5H RATE_7D CONTEXT"
COLOR_NORMAL="green"
COLOR_RATE_WARNING="yellow"
COLOR_RATE_CRITICAL="red"
STREAK_WARNING=5400    # 1.5h — work streak turns yellow
STREAK_CRITICAL=9000   # 2.5h — work streak turns red
COLOR_TIMELINE_WORK="green"    # color for ▮ blocks
COLOR_TIMELINE_BREAK="green"   # color for · blocks
TIMELINE_SLOT=1200  # seconds per timeline block (1200=20min, 1800=30min, 3600=1h)
COLOR_DEFAULT="dark-gray"
RATE_7D_PROJ_MIN_DAYS=1
AUTO_ROTATE=true
ROTATE_INTERVAL=daily  # daily, weekly, monthly
GAP_BUCKETS="60,300,600,900,1800"  # seconds: 1m, 5m, 10m, 15m, 30m

[ -f "$CONFIGFILE" ] && source "$CONFIGFILE"

# DATADIR can be overridden in config.sh, so set LOGDIR/LOGFILE after sourcing
LOGDIR="${DATADIR}"
LOGFILE="${LOGDIR}/activity.jsonl"

# Reusable jq definitions for time classification
#
# Two models, one fork point:
#
#   ACTIVE TIME (line 1 — "was work happening?")
#     Gap-by-gap classification. Every gap between consecutive events is either
#     productive (counted) or idle (excluded). Long Claude turns always count.
#     Uses: is_idle
#
#   PRESENCE (line 2 — "was the user at their desk?")
#     Prompt-to-prompt spans with capped Claude credit. Claude response time
#     up to pause/3 is subtracted ("user might be watching"). Beyond that,
#     excess counts toward absence — a 3h overnight autonomous task shows as
#     a break. Credit is a fraction of pause, not equal, because the threshold
#     answers "how long without interaction = away?" while the credit answers
#     "how long would you realistically watch Claude output?" (~5min at 15min).
#     Uses: away_spans
#
# Both share the same events, same threshold, same log. They agree in normal
# conversation and only diverge during long autonomous Claude turns.
#
# Display labels (--breakdown only):
#   claude     — attended Claude work (prompt→response, user present)
#   user       — user's active turns (response→prompt, within threshold)
#   unattended — time within an away span (user wasn't present)
#   breaks     — idle user turn outside away spans (response→prompt over threshold)
#   downtime   — idle + quit CLI outside away spans (response→start over threshold)

# --- Active time predicates (line 1) ---
JQ_PREDICATES='def is_user_turn($a; $i):
  ($a[$i-1].e == "response" or $a[$i-1].e == "start");
def is_idle($a; $i; $pause):
  is_user_turn($a; $i) and ($a[$i].t - $a[$i-1].t) > $pause;'

# --- Presence: away span computation (line 2) ---
# Prompt-to-prompt gaps with capped Claude credit.
# Claude response time (up to pause/3) is subtracted from the gap before the
# threshold check — "how long would you plausibly watch Claude output?"
# With a 15min threshold, credit ≈ 5min, breaks trigger at ~20min of Claude work.
# Returns array of {from_t, to_t, return_idx} objects.
# Input: event array (sorted by time). $pause: threshold.
JQ_AWAY='def away_spans($pause; $credit):
  [to_entries[] | select(.value.e == "response" or .value.e == "start" or .value.e == "prompt")
   | {orig_idx: .key, e: .value.e, t: .value.t}] as $events
  | if ($events | length) < 2 then []
    else reduce range(0; $events | length) as $i (
      {last_prompt_t: null, last_response_t: null, spans: []};
      if $events[$i].e == "prompt" then
        if .last_prompt_t != null then
          ($events[$i].t - .last_prompt_t) as $total
          | (if .last_response_t != null and .last_response_t > .last_prompt_t
             then .last_response_t - .last_prompt_t else 0 end) as $claude
          | ($total - ([$claude, $credit] | min)) as $adjusted
          | if $adjusted > $pause then
              .spans += [{from_t: .last_prompt_t, to_t: $events[$i].t, return_idx: $events[$i].orig_idx}]
            else . end
        else . end
        | .last_prompt_t = $events[$i].t | .last_response_t = null
      elif $events[$i].e == "response" then
        .last_response_t = $events[$i].t
      elif $events[$i].e == "start" then
        # Session start: check gap from last prompt, then reset like a prompt
        if .last_prompt_t != null then
          ($events[$i].t - .last_prompt_t) as $total
          | (if .last_response_t != null and .last_response_t > .last_prompt_t
             then .last_response_t - .last_prompt_t else 0 end) as $claude
          | ($total - ([$claude, $credit] | min)) as $adjusted
          | if $adjusted > $pause then
              .spans += [{from_t: .last_prompt_t, to_t: $events[$i].t, return_idx: $events[$i].orig_idx}]
            else . end
        else . end
        | .last_prompt_t = $events[$i].t | .last_response_t = null
      else . end
    ) | .spans
    end;'

# Compute active seconds: total time minus idle gaps
# Long Claude turns count as productive — uses is_idle, not away_spans.
JQ_CALC="${JQ_PREDICATES}${JQ_AWAY}"'
def calc_active($pause):
  . as $a | reduce range(1; $a|length) as $i (0;
    ($a[$i].t - $a[$i-1].t) as $gap
    | if $gap <= 0 then .
      elif is_idle($a; $i; $pause) then .
      else . + $gap
      end);
def calc_split($pause):
  . as $a | reduce range(1; $a|length) as $i (
    {claude: 0, user: 0};
    ($a[$i].t - $a[$i-1].t) as $gap
    | if $gap <= 0 then .
      elif is_idle($a; $i; $pause) then .
      elif is_user_turn($a; $i) then .user += $gap
      else .claude += $gap
      end);'

# Phase breakdown — five categories
# Pre-computes away spans, then classifies each gap by whether it falls
# within an away span or not.
JQ_BREAKDOWN="${JQ_PREDICATES}${JQ_AWAY}"'
def calc_breakdown($pause; $credit):
  away_spans($pause; $credit) as $away
  | . as $a | reduce range(1; $a|length) as $i (
    {claude: 0, user: 0, away: 0, away_count: 0, away_claude: 0, away_idle: 0, breaks: 0, break_count: 0, downtime: 0, downtime_count: 0};
    ($a[$i].t - $a[$i-1].t) as $gap
    | if $gap <= 0 then .
      else
        ([$away[] | select(.from_t <= $a[$i-1].t and $a[$i].t <= .to_t)] | length > 0) as $in_away
        | if $in_away and ($a[$i].e == "prompt") then
            .away += $gap | .away_count += 1
            | if is_user_turn($a; $i) then .away_idle += $gap else .away_claude += $gap end
          elif $in_away then
            .away += $gap
            | if is_idle($a; $i; $pause) or is_user_turn($a; $i) then .away_idle += $gap else .away_claude += $gap end
          elif is_idle($a; $i; $pause) and ($a[$i].e == "start") then
            .downtime += $gap | .downtime_count += 1
          elif is_idle($a; $i; $pause) then
            .breaks += $gap | .break_count += 1
          elif is_user_turn($a; $i) then .user += $gap
          else .claude += $gap
          end
      end);'

# --- Color name resolver: "red" → actual ANSI escape bytes ---
# Variable-setting variant: sets _V instead of printing (avoids subshell)
_resolve_color_v() {
    case "${1:-}" in
        black)        _V=$'\033[30m' ;;
        red)          _V=$'\033[31m' ;;
        green)        _V=$'\033[32m' ;;
        yellow)       _V=$'\033[33m' ;;
        blue)         _V=$'\033[34m' ;;
        magenta)      _V=$'\033[35m' ;;
        cyan)         _V=$'\033[36m' ;;
        white)        _V=$'\033[37m' ;;
        gray|grey)    _V=$'\033[90m' ;;
        orange)       _V=$'\033[38;5;208m' ;;
        pink)         _V=$'\033[38;5;213m' ;;
        purple)       _V=$'\033[38;5;141m' ;;
        bright-green) _V=$'\033[1;32m' ;;
        bright-red)   _V=$'\033[1;31m' ;;
        bright-yellow) _V=$'\033[1;33m' ;;
        bright-blue)  _V=$'\033[1;34m' ;;
        bright-white) _V=$'\033[1;37m' ;;
        dim)          _V=$'\033[2m' ;;
        dark-gray|dark-grey) _V=$'\033[38;5;246m' ;;
        light-gray|light-grey) _V=$'\033[38;5;248m' ;;
        reset)        _V=$'\033[0m' ;;
        ""|none)      _V='' ;;
        *)            printf -v _V '%b' "$1" ;;  # passthrough raw ANSI codes
    esac
}

# Resolve all color config values (no subshells)
_resolve_color_v "$COLOR_NORMAL"; COLOR_NORMAL="$_V"
_resolve_color_v "$COLOR_RATE_WARNING"; COLOR_RATE_WARNING="$_V"
_resolve_color_v "$COLOR_RATE_CRITICAL"; COLOR_RATE_CRITICAL="$_V"
_resolve_color_v "$COLOR_TIMELINE_WORK"; COLOR_TIMELINE_WORK="$_V"
_resolve_color_v "$COLOR_TIMELINE_BREAK"; COLOR_TIMELINE_BREAK="$_V"
_resolve_color_v "${COLOR_DEFAULT:-reset}"; COLOR_DEFAULT="$_V"

# Precompute derived config values (once, not per statusline call)
# Convert RATE_7D_PROJ_MIN_DAYS (float) to seconds (integer) for bash comparison
RATE_7D_PROJ_MIN_SECONDS=$(awk "BEGIN { printf \"%d\", ${RATE_7D_PROJ_MIN_DAYS:-0.5} * 86400 }")

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

# Read log file safely — single pass, skips corrupt lines
_safe_log() {
    local file="${1:-$LOGFILE}"
    jq -Rc 'fromjson? // empty' "$file" 2>/dev/null
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
    local _eff_credit="${CLAUDE_CREDIT:-0}"
    [ "$_eff_credit" -le 0 ] 2>/dev/null && _eff_credit=$(( PAUSE_THRESHOLD / 3 ))
    echo "  PAUSE_THRESHOLD:    ${PAUSE_THRESHOLD}s ($((PAUSE_THRESHOLD / 60))min)"
    echo "  CLAUDE_CREDIT:      ${_eff_credit}s ($((${_eff_credit} / 60))min) — $([ "${CLAUDE_CREDIT:-0}" -gt 0 ] 2>/dev/null && echo "configured" || echo "auto: threshold/3")"
    echo "  AUTO_ROTATE:        $AUTO_ROTATE"
    echo "  ROTATE_INTERVAL:    $ROTATE_INTERVAL"
    echo "  RATE_7D_PROJ_MIN:   ${RATE_7D_PROJ_MIN_DAYS} days"
    echo "  STATUSLINE_1:       $STATUSLINE_1"
    [ -n "${STATUSLINE_2:-}" ] && echo "  STATUSLINE_2:       $STATUSLINE_2"
    [ -n "${STATUSLINE_3:-}" ] && echo "  STATUSLINE_3:       $STATUSLINE_3"
    echo "  GROUP_DIVIDER:      '${GROUP_DIVIDER}'"
    local _v
    for _v in $(compgen -A variable GROUP_ 2>/dev/null); do
        [[ "$_v" == "GROUP_DIVIDER" ]] && continue
        echo "  ${_v}:$(printf '%*s' $((18 - ${#_v})) '')${!_v}"
    done
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
    "$0" --statusline >/dev/null 2>&1
    t1=$(date +%s%N)
    echo "  Statusline: $(( (t1 - t0) / 1000000 ))ms"

    # Rotation errors
    if [ -f "${LOGDIR}/.rotation_errors" ]; then
        echo ""
        echo "Rotation errors:"
        cat "${LOGDIR}/.rotation_errors"
    fi

    # Dependencies
    echo ""
    echo "Dependencies:"
    cmd_check
}

# --- Read hook stdin JSON ---
_read_hook_stdin() {
    HOOK_SESSION_ID=""
    HOOK_CWD=""
    HOOK_COST=""
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
        # Extract cost.total_cost_usd (numeric, no quotes)
        tmp="${_STDIN_JSON#*\"total_cost_usd\":}"
        HOOK_COST="${tmp%%[,\}]*}"
        [ "$HOOK_COST" = "$_STDIN_JSON" ] && HOOK_COST=""
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
# Variable-setting variant: sets _V instead of printing (avoids subshell)
_fmt_short_v() {
    local s=${1:-0}
    local h=$((s / 3600)) m=$(( (s % 3600) / 60 ))
    if [ "$h" -gt 0 ]; then
        [ "$m" -lt 10 ] && _V="${h}h0${m}m" || _V="${h}h${m}m"
    else
        _V="${m}m"
    fi
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
# Variable-setting variant
_short_project_v() {
    local p="${1%/}"
    local last="${p##*/}"
    local rest="${p%/*}"
    local second="${rest##*/}"
    if [ -n "$second" ] && [ "$second" != "$last" ]; then
        _V="$second/$last"
    else
        _V="$last"
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
    # Cost suffix for prompt/response events (cumulative session cost)
    local cost_field=""
    if [ -n "$HOOK_COST" ] && { [ "$event" = "prompt" ] || [ "$event" = "response" ]; }; then
        cost_field=",\"cst\":$HOOK_COST"
    fi

    # flock: serialize log writes with rotation to prevent lost entries
    (
        flock -w 2 9 2>/dev/null || true  # best-effort lock — don't block hooks
        if [ -n "$branch" ]; then
            printf '{"t":%d,"p":"%s","b":"%s","s":"%s","e":"%s"%s}\n' "$ts" "$jp" "$jb" "$js" "$event" "$cost_field" >> "$LOGFILE"
        else
            printf '{"t":%d,"p":"%s","s":"%s","e":"%s"%s}\n' "$ts" "$jp" "$js" "$event" "$cost_field" >> "$LOGFILE"
        fi
    ) 9>"${LOGFILE}.lock"

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
    # Read last few lines to find session ID — avoids reading entire file
    # tail is safe even on large files; 50 lines covers any reasonable gap
    local line tmp sid
    while IFS= read -r line; do
        tmp="${line#*\"s\":\"}"
        [ "$tmp" = "$line" ] && continue  # no "s" field
        sid="${tmp%%\"*}"
        [ -n "$sid" ] && { echo "$sid"; return; }
    done < <(tail -50 "$LOGFILE" 2>/dev/null | tac || true)
}

# ============================================================
# Statusline
# ============================================================

mode_statusline() {
    # Disable errexit in statusline — a crash should never blank the display
    set +e

    _read_hook_stdin

    local sid="${HOOK_SESSION_ID:-$(_current_session_id)}"
    [ -z "$sid" ] && { printf '%s' "⏱ --"; return; }

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
        | (\$today | away_spans(\$pause; \$credit)) as \$away
        | {
            session_active: (\$session | calc_active(\$pause)),
            first_t: (\$session | if length > 0 then .[0].t else 0 end),
            last_break: (\$away | if length > 0 then last | (.to_t - .from_t) else 0 end),
            since_break: (if (\$away | length) > 0 then \$today[\$away[-1].return_idx:] | calc_active(\$pause)
                  else \$today | calc_active(\$pause) end),
            project: \$proj,
            branch: (\$session | [.[] | .b // empty] | if length > 0 then last else \"\" end),
            today_first_t: (\$today | if length > 0 then .[0].t else 0 end),
            today_active: (\$today | calc_active(\$pause)),
            today_project_active: (\$today | map(select(.p == \$proj)) | sort_by(.t) | calc_active(\$pause)),
            today_project_split: (\$today | map(select(.p == \$proj)) | sort_by(.t) | calc_split(\$pause)),
            project_total_active: (
                (\$all | map(select(.p == \$proj)) | sort_by(.t) | calc_active(\$pause))
                + ([\$raw[] | select(.type == \"summary\" and .p == \$proj) | .active] | add // 0)
            ),
            project_total_split: (
                (\$all | map(select(.p == \$proj)) | sort_by(.t) | calc_split(\$pause)) as \$current
                | {
                    claude: (\$current.claude + ([\$raw[] | select(.type == \"summary\" and .p == \$proj) | .claude // 0] | add // 0)),
                    user: (\$current.user + ([\$raw[] | select(.type == \"summary\" and .p == \$proj) | .user // 0] | add // 0))
                }
            ),
            timeline: (if (\$today | length) > 0 then
                # One character per time slot (configurable via TIMELINE_SLOT)
                # ▮ = present (worked more than half the slot), · = away
                (\$today[0].t) as \$tstart
                | ((\$tstart / \$slot) | floor) as \$first_slot
                | ((\$now / \$slot) | floor) as \$current_slot
                | [\$away[] | {from: .from_t, to: .to_t}] as \$away_intervals
                | [range(\$first_slot; \$current_slot + 1) | . as \$s
                    | (\$s * \$slot) as \$slot_start
                    | ((\$s + 1) * \$slot) as \$slot_end
                    | ([(\$slot_start), \$tstart] | max) as \$eff_start
                    | ([(\$slot_end), \$now] | min) as \$eff_end
                    | (\$eff_end - \$eff_start) as \$slot_len
                    # Skip current slot until at least half has elapsed
                    | select(\$slot_len >= (\$slot / 2) or \$slot_end <= \$now)
                    | ([\$away_intervals[]
                        | ([.from, \$eff_start] | max) as \$os
                        | ([.to, \$eff_end] | min) as \$oe
                        | if \$oe > \$os then (\$oe - \$os) else 0 end
                      ] | add // 0) as \$away_in_slot
                    | if \$slot_len > 0 and (\$away_in_slot < (\$slot_len / 2)) then \"▮\" else \"·\" end
                ] | join(\"\")
              else \"\" end)
        }
        | [.session_active, .first_t, .last_break, .since_break, .project, .branch, .today_first_t, .today_active, .today_project_active, .project_total_active, .today_project_split.claude, .today_project_split.user, .project_total_split.claude, .project_total_split.user, .timeline]
        | map(. // \"\" | tostring) | join(\"\\u001e\")
    "
    local all_formats=""
    local _gname _gvar
    for _gname in ${STATUSLINE_1:-} ${STATUSLINE_2:-} ${STATUSLINE_3:-}; do
        _gvar="GROUP_${_gname}"
        all_formats="${all_formats}${!_gvar:-}"
    done
    local _credit="${CLAUDE_CREDIT:-0}"
    [ "$_credit" -le 0 ] 2>/dev/null && _credit=$(( PAUSE_THRESHOLD / 3 ))
    local _jq_args=(--argjson pause "$PAUSE_THRESHOLD" --argjson credit "$_credit" --argjson since "$today_start" --arg sid "$sid" --argjson now "$now" --argjson slot "${TIMELINE_SLOT:-1800}")

    # Fast path: direct read. Fallback: skip corrupt lines.
    all_info=$(jq -sr "${_jq_args[@]}" "$_jq_query" "$LOGFILE" 2>/dev/null) \
        || all_info=$(_safe_log "$LOGFILE" | jq -sr "${_jq_args[@]}" "$_jq_query" 2>/dev/null)
    # If both paths failed, show minimal display
    [ -z "$all_info" ] && { printf '%s' "${COLOR_NORMAL}⏱ --${COLOR_DEFAULT}"; return; }

    local session_active session_first last_break since_break project branch today_first today_active today_project_active project_total_active today_claude_active today_you_active total_claude_active total_you_active tok_timeline
    IFS=$'\x1e' read -r session_active session_first last_break since_break project branch today_first today_active today_project_active project_total_active today_claude_active today_you_active total_claude_active total_you_active tok_timeline <<< "$all_info"

    local session_wall=$(( now - ${session_first:-$now} ))
    local today_wall=0
    [ "${today_first:-0}" -gt 0 ] && today_wall=$(( now - today_first ))

    local color="$COLOR_NORMAL"

    # Build tokens (using _v variants to avoid subshells)
    local tok_session tok_session_wall tok_today tok_today_wall tok_today_project tok_today_claude tok_today_you tok_project_total tok_project tok_branch tok_last_break tok_since_break tok_git
    _fmt_short_v "$session_active"; tok_session="$_V"
    _fmt_short_v "$session_wall"; tok_session_wall="$_V"
    _fmt_short_v "$today_active"; tok_today="$_V"
    _fmt_short_v "$today_wall"; tok_today_wall="$_V"
    local tok_today_start="" tok_today_now=""
    [ "${today_first:-0}" -gt 0 ] && tok_today_start=$(date -d "@$today_first" +%H:%M 2>/dev/null || date -r "$today_first" +%H:%M 2>/dev/null)
    tok_today_now=$(date +%H:%M)
    _fmt_short_v "$today_project_active"; tok_today_project="$_V"
    _fmt_short_v "${today_claude_active:-0}"; tok_today_claude="$_V"
    _fmt_short_v "${today_you_active:-0}"; tok_today_you="$_V"
    _fmt_short_v "$project_total_active"; tok_project_total="$_V"
    _fmt_short_v "${total_claude_active:-0}"; local tok_total_claude="$_V"
    _fmt_short_v "${total_you_active:-0}"; local tok_total_you="$_V"
    _short_project_v "$project"; tok_project="$_V"
    tok_branch="$branch"
    # since_break always shows (continuous work streak); last_break only after first break
    # Streak color warning: yellow at STREAK_WARNING, red at STREAK_CRITICAL
    tok_last_break=""
    local lb=${last_break:-0}
    local sb=${since_break:-0}
    _fmt_short_v "$sb"
    local streak_color=""
    if [ "$sb" -ge "${STREAK_CRITICAL:-9000}" ] && [ -n "${COLOR_RATE_CRITICAL:-}" ]; then
        streak_color="$COLOR_RATE_CRITICAL"
    elif [ "$sb" -ge "${STREAK_WARNING:-5400}" ] && [ -n "${COLOR_RATE_WARNING:-}" ]; then
        streak_color="$COLOR_RATE_WARNING"
    fi
    if [ -n "$streak_color" ]; then
        tok_since_break="${streak_color}▶$_V${COLOR_DEFAULT}"
    else
        tok_since_break="▶$_V"
    fi
    if [ "$lb" -gt 0 ]; then
        _fmt_short_v "$lb"; tok_last_break="⏸ $_V"
    fi


    # Git status — only compute if {git} is in any format string
    tok_git=""
    if [[ "$all_formats" == *"{git}"* ]] && [ -n "$project" ]; then
        local git_status
        git_status=$(git -C "$project" status --porcelain -b 2>/dev/null || true)
        if [ -n "$git_status" ]; then
            local git_state="" gb="" ahead="" behind=""
            local dirty=false staged=false untracked=false
            local _line _first=true
            while IFS= read -r _line; do
                if $_first; then
                    _first=false
                    # Parse "## branch...tracking [ahead N, behind N]"
                    gb="${_line#\#\# }"; gb="${gb%%...*}"
                    [[ "$_line" =~ ahead\ ([0-9]+) ]] && ahead="${BASH_REMATCH[1]}"
                    [[ "$_line" =~ behind\ ([0-9]+) ]] && behind="${BASH_REMATCH[1]}"
                else
                    case "${_line:0:2}" in
                        '??') untracked=true ;;
                        *)
                            [[ "${_line:0:1}" == [MADRC] ]] && staged=true
                            [[ "${_line:1:1}" == [MDRC] ]] && dirty=true
                            ;;
                    esac
                fi
            done <<< "$git_status"
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
    local tok_rate_5h="" tok_rate_5h_reset="" tok_rate_5h_proj="" tok_rate_7d="" tok_rate_7d_reset="" tok_rate_7d_day="" tok_rate_7d_proj="" tok_context="" tok_cost_budget="" tok_cost="" tok_model=""
    if [ -n "${_STDIN_JSON:-}" ]; then
        # Single jq call to extract all fields
        local stdin_parsed
        stdin_parsed=$(jq -r '[
            (.rate_limits.five_hour.used_percentage // "_"),
            (.rate_limits.five_hour.resets_at // "_"),
            (.rate_limits.seven_day.used_percentage // "_"),
            (.rate_limits.seven_day.resets_at // "_"),
            (.context_window.used_percentage // "_"),
            (.context_window.current_usage.cache_creation_input_tokens // "_"),
            (.context_window.current_usage.cache_read_input_tokens // "_"),
            (.context_window.current_usage.input_tokens // "_"),
            (.context_window.current_usage.output_tokens // "_"),
            (.context_window.total_input_tokens // "_"),
            (.context_window.total_output_tokens // "_"),
            (.cost.total_cost_usd // "_"),
            (.model.display_name // "_"),
            (.model.id // "_")
        ] | join("\t")' <<< "$_STDIN_JSON" 2>/dev/null || true)

        local r5h r5h_reset r7d r7d_reset ctx cache_create cache_read uncached_input output_tokens cum_input cum_output cst mdl mdl_id
        IFS=$'\t' read -r r5h r5h_reset r7d r7d_reset ctx cache_create cache_read uncached_input output_tokens cum_input cum_output cst mdl mdl_id <<< "$stdin_parsed"
        # Replace placeholder with empty
        [ "$r5h" = "_" ] && r5h=""
        [ "$r5h_reset" = "_" ] && r5h_reset=""
        [ "$r7d" = "_" ] && r7d=""
        [ "$r7d_reset" = "_" ] && r7d_reset=""
        [ "$ctx" = "_" ] && ctx=""
        [ "$cache_create" = "_" ] && cache_create=""
        [ "$cache_read" = "_" ] && cache_read=""
        [ "$uncached_input" = "_" ] && uncached_input=""
        [ "$output_tokens" = "_" ] && output_tokens=""
        [ "$cum_input" = "_" ] && cum_input=""
        [ "$cum_output" = "_" ] && cum_output=""
        [ "$cst" = "_" ] && cst=""
        [ "$mdl" = "_" ] && mdl=""
        [ "$mdl_id" = "_" ] && mdl_id=""

        # Merge cache hit rate into context token: "77% ⟳99%"
        # Instantaneous ratio from the most recent API response — no state file needed.
        if [ -n "$ctx" ] && [ -n "$cache_create" ] && [ -n "$cache_read" ]; then
            local cc=${cache_create%.*} cr=${cache_read%.*} ui=${uncached_input%.*}
            [ -z "$ui" ] && ui=0
            local total=$(( cc + cr + ui ))
            if [ "$total" -gt 0 ]; then
                local cache_pct=$(( cr * 100 / total ))
                tok_context="${ctx%%.*}% ⟳${cache_pct}%"
            else
                tok_context="${ctx%%.*}%"
            fi
        elif [ -n "$ctx" ]; then
            tok_context="${ctx%%.*}%"
        fi

        if [ -n "$r5h" ]; then
            local r5h_int="${r5h%%.*}"
            local r5h_icon="○"
            [ "$r5h_int" -ge 13 ] && r5h_icon="◔"
            [ "$r5h_int" -ge 38 ] && r5h_icon="◑"
            [ "$r5h_int" -ge 63 ] && r5h_icon="◕"
            [ "$r5h_int" -ge 88 ] && r5h_icon="●"
            tok_rate_5h="${r5h_icon}${r5h_int}%"
        fi
        if [ -n "$r5h_reset" ]; then _fmt_short_v $(( r5h_reset - now )); tok_rate_5h_reset="$_V"; fi
        [ -n "$r7d" ] && tok_rate_7d="${r7d%%.*}%"
        if [ -n "$r7d_reset" ]; then _fmt_short_v $(( r7d_reset - now )); tok_rate_7d_reset="$_V"; fi
        if [ -n "$r7d_reset" ]; then
            local -a _days=(Thu Fri Sat Sun Mon Tue Wed)
            tok_rate_7d_day="${_days[$(( (r7d_reset / 86400) % 7 ))]}"
        fi
        # tok_context already set above (with cache merge)
        [ -n "$cst" ] && tok_cost=$(printf "$%.2f" "$cst")
        if [ -n "$mdl" ]; then
            # Infer model source by checking settings files in priority order.
            # Uses model.id (e.g. "claude-opus-4-6") for matching against settings
            # values which may be short ("opus") or full IDs ("claude-opus-4-6").
            local _model_source="default"
            local _ms_file _ms_raw _ms_val _ms_src
            for _ms_file in \
                "${HOOK_CWD:-.}/.claude/settings.local.json" \
                "${HOOK_CWD:-.}/.claude/settings.json" \
                "$HOME/.claude/settings.json"; do
                [ -f "$_ms_file" ] || continue
                _ms_raw=$(<"$_ms_file")
                # Match "model": "val" or "model":"val"
                _ms_val="${_ms_raw#*\"model\": \"}"
                if [ "$_ms_val" = "$_ms_raw" ]; then
                    _ms_val="${_ms_raw#*\"model\":\"}"
                fi
                [ "$_ms_val" = "$_ms_raw" ] && continue
                _ms_val="${_ms_val%%\"*}"
                case "$_ms_file" in
                    *settings.local.json) _ms_src="local" ;;
                    */.claude/settings.json) _ms_src="project" ;;
                    *) _ms_src="global" ;;
                esac
                # Check if settings value matches model.id (substring match)
                # e.g. "opus" matches "claude-opus-4-6", "claude-opus-4-6" matches exactly
                if [ -n "$mdl_id" ] && [[ "${mdl_id,,}" == *"${_ms_val,,}"* ]]; then
                    _model_source="$_ms_src"
                else
                    _model_source="session"
                fi
                break
            done
            tok_model="$mdl ($_model_source)"
        fi

        # Projected rate limit usage at window reset (pure bash integer math)
        # proj = used% * window / elapsed  (equivalent to used + burn_rate * remaining)
        _project_rate_v() {
            local used=${1%%.*} reset_at=$2 window=$3
            local remaining=$(( reset_at - now ))
            local elapsed=$(( window - remaining ))
            [ "$elapsed" -le 60 ] && { _V=""; return; }
            local proj=$(( used * window / elapsed ))
            local proj_color=""
            if [ "$proj" -ge 100 ] && [ -n "${COLOR_RATE_CRITICAL:-}" ]; then
                proj_color="$COLOR_RATE_CRITICAL"
            elif [ "$proj" -ge 90 ] && [ -n "${COLOR_RATE_WARNING:-}" ]; then
                proj_color="$COLOR_RATE_WARNING"
            fi
            if [ -n "$proj_color" ]; then
                _V="${proj_color}→${proj}%${COLOR_DEFAULT}"
            else
                _V="→${proj}%"
            fi
        }
        if [ -n "$r5h" ] && [ -n "$r5h_reset" ]; then
            _project_rate_v "$r5h" "$r5h_reset" 18000; tok_rate_5h_proj="$_V"
        fi
        # 7d projection: pure bash integer math
        if [ -n "$r7d" ] && [ -n "$r7d_reset" ]; then
            local elapsed_s=$(( 7 * 86400 - (r7d_reset - now) ))
            [ "$elapsed_s" -lt 60 ] && elapsed_s=60
            local proj=""
            if [ "$elapsed_s" -ge "$RATE_7D_PROJ_MIN_SECONDS" ]; then
                proj=$(( ${r7d%%.*} * 7 * 86400 / elapsed_s ))
            fi
            if [ -n "$proj" ]; then
                local proj_color=""
                if [ "$proj" -ge 100 ] && [ -n "${COLOR_RATE_CRITICAL:-}" ]; then
                    proj_color="$COLOR_RATE_CRITICAL"
                elif [ "$proj" -ge 90 ] && [ -n "${COLOR_RATE_WARNING:-}" ]; then
                    proj_color="$COLOR_RATE_WARNING"
                fi
                if [ -n "$proj_color" ]; then
                    tok_rate_7d_proj="${proj_color}→${proj}%${COLOR_DEFAULT}"
                else
                    tok_rate_7d_proj="→${proj}%"
                fi
            fi
        fi

        # Token tracking: log per request, compute from log for display
        if [ -n "$cache_create" ] && [ -n "$cache_read" ]; then
            local t_cc=${cache_create%.*} t_cr=${cache_read%.*} t_ui=${uncached_input%.*} t_out=${output_tokens%.*}
            [ -z "$t_ui" ] && t_ui=0
            [ -z "$t_out" ] && t_out=0

            # Log token entry (skip if no valid session context)
            local token_prev="${LOGDIR}/.token_prev"
            local tp_cr=0 tp_cc=0
            [ -f "$token_prev" ] && read -r tp_cr tp_cc < "$token_prev" 2>/dev/null
            if [ -n "${sid:-}" ] && [ "${sid:-}" != "" ] && ([ "${t_cr:-0}" != "$tp_cr" ] || [ "${t_cc:-0}" != "$tp_cc" ]); then
                echo "${t_cr:-0} ${t_cc:-0}" > "$token_prev" 2>/dev/null
                (
                    flock -w 2 9 2>/dev/null || true
                    printf '{"type":"tokens","t":%d,"s":"%s","cr":%d,"cc":%d,"ui":%d,"out":%d,"pct":%s,"cst":%s,"ctx":%s,"ci":%s,"co":%s,"w":%s}\n' \
                        "$now" "$sid" "$t_cr" "$t_cc" "$t_ui" "$t_out" "${r5h:-0}" "${cst:-0}" "${ctx:-0}" "${cum_input:-0}" "${cum_output:-0}" "${r5h_reset:-0}" >> "$LOGFILE"
                ) 9>"${LOGFILE}.lock"
            fi

            # Compute token and cost totals from log for current 5h window
            # Source of truth: all token entries from all sessions in this window
            if [ -n "$r5h_reset" ]; then
                local window_start=$(( r5h_reset - 18000 ))
                local token_sums
                # Reads only current LOGFILE. Rotation preserves token entries from
                # the current 5h window (including cross-midnight windows via budget state).
                token_sums=$(jq -Rc 'fromjson? // empty' "$LOGFILE" 2>/dev/null \
                    | jq -sr --argjson since "$window_start" '
                    [.[] | select(.type == "tokens" and .t >= $since)]
                    | {
                        cr: (map(.cr) | add // 0), cc: (map(.cc) | add // 0),
                        ui: (map(.ui) | add // 0), out: (map(.out) | add // 0),
                        cost_cents: ([group_by(.s)[] | ((last.cst) - (first.cst))] | add // 0) * 100 | round
                      }
                    | [.cr, .cc, .ui, .out, .cost_cents] | map(tostring) | join(" ")
                ' 2>/dev/null || true)

                local ts_cr=0 ts_cc=0 ts_ui=0 ts_out=0 ts_cost_cents=0
                [ -n "$token_sums" ] && read -r ts_cr ts_cc ts_ui ts_out ts_cost_cents <<< "$token_sums"

                # token_budget removed: weighted tokens (input-equivalent via API pricing
                # ratios) only tracked main conversation, missing subagent/tool costs
                # (1.1-2.4x underestimate). {cost_budget} uses cost.total_cost_usd which
                # includes everything. Weighted computation and _fmt_tokens_v removed.

                local r5h_int="${r5h%%.*}"

                # Budget inference: two-zone approach for stable display.
                # Raw estimate (window_cost/pct) is a structural lower bound — server-side
                # pct advances ahead of client-visible cost (in-flight agent calls not yet
                # reported). Estimates only become reliable around pct=65.
                # Zone 1 (pct < STABLE_PCT): show prior from last window unchanged.
                # Zone 2 (pct >= STABLE_PCT): EMA(α=0.3) anchored to prior, converges to
                # actual budget. Prior carried across window resets (not zeroed) so the
                # display is immediately meaningful at the start of each new window.
                # cost.total_cost_usd is API-equivalent pricing (~$40 per 5h window on Max/Opus).
                local stable_pct=65  # below this, raw estimates are unreliable (cost lag)
                local budget_state="${LOGDIR}/.budget"
                local bs_reset=0 bs_pct=0 bs_cost_budget=0
                if [ -f "$budget_state" ]; then
                    read -r bs_reset bs_pct bs_cost_budget < "$budget_state" 2>/dev/null || true
                fi
                # Window changed: reset pct counter but carry cost budget as prior
                if [ "${bs_reset:-0}" != "${r5h_reset:-0}" ]; then
                    bs_pct=0
                fi
                # Recompute if percentage ticked and in stable zone
                if [ -n "$r5h_int" ] && [ "$r5h_int" -gt 0 ] && [ "$r5h_int" != "$bs_pct" ]; then
                    local prev_pct="$bs_pct"
                    bs_pct="$r5h_int"
                    # Zone 2: skip on first tick after window reset (prev_pct=0) because
                    # ts_cost_cents may only capture a fraction of actual window cost so far,
                    # causing EMA to drag the budget down from the prior. Next tick is fine.
                    if [ "$r5h_int" -ge "$stable_pct" ] && [ "${prev_pct:-0}" -gt 0 ]; then
                        # Zone 2: update via EMA — estimates now reliable
                        if [ "$ts_cost_cents" -gt 0 ]; then
                            local new_cost_budget=$(( ts_cost_cents * 100 / r5h_int ))
                            if [ "${bs_cost_budget:-0}" -gt 0 ]; then
                                # EMA: 30% new + 70% prior
                                bs_cost_budget=$(( (new_cost_budget * 30 + bs_cost_budget * 70) / 100 ))
                            else
                                bs_cost_budget=$new_cost_budget
                            fi
                        fi
                    fi
                    # Zone 1 (pct < stable_pct) or first tick after reset: prior unchanged
                fi
                echo "${r5h_reset:-0} $bs_pct ${bs_cost_budget:-0}" > "$budget_state" 2>/dev/null

                # {cost_budget} — actual session cost / inferred budget
                # Budget: prior from last window until pct >= stable_pct, then EMA(α=0.3)
                if [ "$ts_cost_cents" -gt 0 ]; then
                    local cost_used_str="$(( ts_cost_cents / 100 )).$(printf '%02d' $(( ts_cost_cents % 100 )))"
                    if [ "${bs_cost_budget:-0}" -gt 0 ]; then
                        local cost_budget_str="≈\$$(( bs_cost_budget / 100 ))"
                        tok_cost_budget="\$${cost_used_str}/${cost_budget_str}"
                    else
                        tok_cost_budget="\$${cost_used_str}"
                    fi
                fi
            fi
        fi
    fi

    # Log cost snapshot when cost changed (skip if no valid session context)
    if [ -n "${cst:-}" ] && [ -n "${project:-}" ] && [ "${sid:-}" != "" ]; then
        local cost_state="${LOGDIR}/.last_cost"
        local last_cost=""
        [ -f "$cost_state" ] && last_cost=$(cat "$cost_state" 2>/dev/null)
        if [ "$last_cost" != "$cst" ]; then
            echo "$cst" > "$cost_state" 2>/dev/null
            (
                flock -w 2 9 2>/dev/null || true
                if [ -n "${branch:-}" ]; then
                    printf '{"type":"cost","t":%d,"p":"%s","b":"%s","s":"%s","cost":%s}\n' \
                        "$now" "$project" "$branch" "$sid" "$cst" >> "$LOGFILE"
                else
                    printf '{"type":"cost","t":%d,"p":"%s","s":"%s","cost":%s}\n' \
                        "$now" "$project" "$sid" "$cst" >> "$LOGFILE"
                fi
            ) 9>"${LOGFILE}.lock"
        fi
    fi

    local tok_status="⏱"

    # Colorize timeline blocks if colors are configured
    # Colorize timeline blocks using actual ANSI escape bytes
    if [ -n "${tok_timeline:-}" ]; then
        # Colorize timeline: ▮ = work, · = away
        [ -n "$COLOR_TIMELINE_WORK" ] && tok_timeline="${tok_timeline//▮/${COLOR_TIMELINE_WORK}▮${COLOR_DEFAULT}}"
        [ -n "$COLOR_TIMELINE_BREAK" ] && tok_timeline="${tok_timeline//·/${COLOR_TIMELINE_BREAK}·${COLOR_DEFAULT}}"
    fi

    # Token arrays (constant per statusline refresh, shared by all groups)
    local -a _atokens=( '{session}' '{session_wall}' '{today}' '{today_wall}' '{today_start}' '{today_now}' '{today_project}' '{today_claude}' '{today_you}' '{project_total}' '{total_claude}' '{total_you}' '{project}' '{branch}' '{status}' '{git}' '{timeline}' )
    local -a _avalues=( "$tok_session" "$tok_session_wall" "$tok_today" "$tok_today_wall" "$tok_today_start" "$tok_today_now" "$tok_today_project" "$tok_today_claude" "$tok_today_you" "$tok_project_total" "$tok_total_claude" "$tok_total_you" "$tok_project" "$tok_branch" "$tok_status" "$tok_git" "$tok_timeline" )
    local -a opt_tokens=( '{last_break}' '{since_break}' '{rate_5h}' '{rate_5h_reset}' '{rate_5h_proj}' '{rate_7d}' '{rate_7d_reset}' '{rate_7d_day}' '{rate_7d_proj}' '{context}' '{cost_budget}' '{cost}' '{model}' )
    local -a opt_values=( "$tok_last_break" "$tok_since_break" "$tok_rate_5h" "$tok_rate_5h_reset" "$tok_rate_5h_proj" "$tok_rate_7d" "$tok_rate_7d_reset" "$tok_rate_7d_day" "$tok_rate_7d_proj" "$tok_context" "$tok_cost_budget" "$tok_cost" "$tok_model" )

    # Substitute all tokens in a group template.
    # Variable-setting: sets _SUBST_NONEMPTY (0/1) and _SUBST_RESULT
    _subst_tokens_v() {
        local output="$1"
        # Fast path: no token placeholders at all
        if [[ "$output" != *"{"* ]]; then
            _SUBST_NONEMPTY=1; _SUBST_RESULT="$output"; return
        fi
        local nonempty=0 i

        # Always-available tokens
        for i in "${!_atokens[@]}"; do
            [[ "$output" != *"${_atokens[$i]}"* ]] && continue
            [ -n "${_avalues[$i]}" ] && nonempty=1
            output="${output//${_atokens[$i]}/${_avalues[$i]}}"
        done

        # Optional tokens
        for i in "${!opt_tokens[@]}"; do
            [[ "$output" != *"${opt_tokens[$i]}"* ]] && continue
            if [ -n "${opt_values[$i]}" ]; then
                nonempty=1
                output="${output//${opt_tokens[$i]}/${opt_values[$i]}}"
            else
                output="${output//${opt_tokens[$i]}/}"
            fi
        done

        # Clean up artifacts (pure bash, no sed/subshell)
        output="${output// ()/}"; output="${output//()/}"
        # Trim leading/trailing whitespace
        output="${output#"${output%%[![:space:]]*}"}"
        output="${output%"${output##*[![:space:]]}"}"
        _SUBST_NONEMPTY="$nonempty"
        _SUBST_RESULT="$output"
    }

    # Render a line from space-separated group names.
    # Variable-setting: sets _RENDER_RESULT
    _render_groups_v() {
        local group_names="$1"
        local divider="${GROUP_DIVIDER:- · }"
        local result="" name var_name color_var_name grp_color template rendered

        for name in $group_names; do
            var_name="GROUP_${name}"
            template="${!var_name:-}"
            [ -z "$template" ] && continue

            _subst_tokens_v "$template"
            if [ "$_SUBST_NONEMPTY" = "1" ] && [ -n "$_SUBST_RESULT" ]; then
                rendered="$_SUBST_RESULT"
                # Per-group color: GROUP_<NAME>_COLOR, falls back to line color
                color_var_name="GROUP_${name}_COLOR"
                grp_color="${!color_var_name:-}"
                if [ -n "$grp_color" ]; then _resolve_color_v "$grp_color"; grp_color="$_V"; fi
                grp_color="${grp_color:-$color}"
                # Replace bare COLOR_DEFAULT with reset+group_color so item colors
                # (projections, timeline) restore to the group color, not default
                rendered="${rendered//${COLOR_DEFAULT}/${COLOR_DEFAULT}${grp_color}}"
                rendered="${grp_color}${rendered}"
                if [ -n "$result" ]; then
                    result="${result}${COLOR_DEFAULT}${divider}${rendered}"
                else
                    result="$rendered"
                fi
            fi
        done
        _RENDER_RESULT="$result"
    }

    # Output (no subshells)
    _render_groups_v "$STATUSLINE_1"
    printf '%s' "${_RENDER_RESULT}${COLOR_DEFAULT}"
    local _sl_extra
    for _sl_extra in "${STATUSLINE_2:-}" "${STATUSLINE_3:-}"; do
        [ -z "$_sl_extra" ] && continue
        _render_groups_v "$_sl_extra"
        [ -n "$_RENDER_RESULT" ] && printf '\n%s' "${_RENDER_RESULT}${COLOR_DEFAULT}"
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
    local wall=$(( now - ${first_ts:-$now} ))
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
        if $raw; then echo '{"claude":0,"user":0,"away":0,"away_count":0,"away_claude":0,"away_idle":0,"breaks":0,"break_count":0,"downtime":0,"downtime_count":0,"active":0}';
        else echo "No activity recorded"; fi; return; fi

    local result
    local _credit="${CLAUDE_CREDIT:-0}"
    [ "$_credit" -le 0 ] 2>/dev/null && _credit=$(( PAUSE_THRESHOLD / 3 ))
    result=$(echo "$entries" | jq -s --argjson pause "$PAUSE_THRESHOLD" --argjson credit "$_credit" "
        ${JQ_CALC}
        ${JQ_BREAKDOWN}
        sort_by(.t) | {
            breakdown: calc_breakdown(\$pause; \$credit),
            active: calc_active(\$pause)
        }
    ")

    local claude_time user_time away away_count breaks break_count downtime downtime_count active
    local bd_parsed
    bd_parsed=$(echo "$result" | jq -r '[.breakdown.claude, .breakdown.user, .breakdown.away, .breakdown.away_count, .breakdown.breaks, .breakdown.break_count, .breakdown.downtime, .breakdown.downtime_count, .active] | @tsv')
    IFS=$'\t' read -r claude_time user_time away away_count breaks break_count downtime downtime_count active <<< "$bd_parsed"

    if $raw; then
        echo "$result" | jq '{claude: .breakdown.claude, user: .breakdown.user, away: .breakdown.away, away_count: .breakdown.away_count, away_claude: .breakdown.away_claude, away_idle: .breakdown.away_idle, breaks: .breakdown.breaks, break_count: .breakdown.break_count, downtime: .breakdown.downtime, downtime_count: .breakdown.downtime_count, active: .active}'
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
        if [ "${away:-0}" -gt 0 ]; then
            printf "  Away:       %-12s (%d)\n" "$(_fmt $away)" "$away_count"
        fi
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
        else echo "No cost data recorded"; fi
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
               is_idle(\$all; \$i; \$pause)
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
    result=$(echo "$entries" | jq -sr --argjson pause "$PAUSE_THRESHOLD" --argjson buckets "$buckets_jq" "
        ${JQ_PREDICATES}
        def bucket_gaps(\$gaps; \$bounds; \$pause):
            [range(0; \$bounds | length) as \$i |
                (if \$i == 0 then 0 else \$bounds[\$i-1] end) as \$lo | \$bounds[\$i] as \$hi
                | {
                    label: (if \$i == 0 then \"< \(\$bounds[0] / 60 | floor)min\"
                            elif \$i == (\$bounds | length) - 1 then \"> \(\$bounds[\$i-1] / 60 | floor)min\"
                            else \"\(\$lo / 60 | floor)-\(\$hi / 60 | floor)min\" end),
                    count: ([\$gaps[] | select(. >= \$lo and . < \$hi)] | length),
                    total: ([\$gaps[] | select(. >= \$lo and . < \$hi)] | add // 0),
                    is_active: (\$lo < \$pause)
                }];
        sort_by(.t) | . as \$a
        | (\$buckets + [99999999]) as \$bounds
        # Collect user-turn gaps, labeled as break or downtime (Layer 3)
        | [range(1; length)
            | select(is_user_turn(\$a; .))
            | {gap: (\$a[.].t - \$a[.-1].t), is_downtime: (\$a[.].e == \"start\")}]
        | {
            breaks: bucket_gaps([.[] | select(.is_downtime | not) | .gap]; \$bounds; \$pause),
            downtime: [.[] | select(.is_downtime) | .gap],
            near_threshold: ([.[] | select(.is_downtime | not) | .gap | select(. >= (\$pause * 0.67) and . < \$pause)] | length),
            threshold: \$pause
          }
    ")

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

    # Collect old event entries to archive
    local old_entries
    old_entries=$(jq -c --argjson since "$ROTATE_CUTOFF" 'select((.type // null) == null and .t < $since)' "$LOGFILE" 2>/dev/null || true)
    [ -z "$old_entries" ] && return

    # Generate per-project summaries BEFORE archiving
    local summaries summary_error=""
    summaries=$(jq -sc --argjson since "$ROTATE_CUTOFF" --argjson pause "$PAUSE_THRESHOLD" "
        ${JQ_CALC}
        [.[] | select((.type // null) == null) | select(.t < \$since)] | group_by(.p) | map(
            (sort_by(.t) | calc_split(\$pause)) as \$split
            | {
                type: \"summary\",
                p: .[0].p,
                active: (sort_by(.t) | calc_active(\$pause)),
                claude: \$split.claude,
                user: \$split.user,
                period: \"$ROTATE_SUFFIX\"
            }
        ) | .[]
    " "$LOGFILE" 2>/dev/null) || summary_error="true"

    # Safety: validate summaries before proceeding
    # Count distinct projects in old entries vs summaries
    local project_count summary_count
    project_count=$(echo "$old_entries" | jq -r '.p' 2>/dev/null | sort -u | wc -l)
    summary_count=$(echo "$summaries" | grep -c '"type":"summary"' 2>/dev/null || echo 0)

    if [ -n "$summary_error" ] || [ -z "$summaries" ]; then
        # Summary generation failed — do NOT archive, data stays in active log
        echo "WARNING: rotation summary generation failed, skipping archive" >> "${LOGDIR}/.rotation_errors" 2>/dev/null
        ! $quiet && echo "Warning: summary generation failed, rotation skipped (data preserved)"
        return
    fi

    if [ "$summary_count" -lt "$project_count" ]; then
        # Fewer summaries than projects — something went wrong
        echo "WARNING: rotation produced $summary_count summaries for $project_count projects" >> "${LOGDIR}/.rotation_errors" 2>/dev/null
        ! $quiet && echo "Warning: summary count mismatch ($summary_count/$project_count), rotation skipped"
        return
    fi

    # Safe to proceed: archive old entries
    local archive="${LOGDIR}/activity-${ROTATE_SUFFIX}.jsonl"
    echo "$old_entries" >> "$archive"

    # Token entry cutoff: normally ROTATE_CUTOFF (midnight), but if the current 5h
    # window started before midnight we must keep those earlier entries too.
    local token_cutoff=$ROTATE_CUTOFF
    local budget_state="${LOGDIR}/.budget"
    if [ -f "$budget_state" ]; then
        local bs_reset
        read -r bs_reset _ _ < "$budget_state" 2>/dev/null || true
        if [ "${bs_reset:-0}" -gt 0 ]; then
            local ws=$(( bs_reset - 18000 ))
            [ "$ws" -lt "$token_cutoff" ] && token_cutoff=$ws
        fi
    fi

    # Rewrite active log: existing summaries + new summaries + current entries + token entries
    # Token entries are not archived (budget state carries the cross-window prior instead).
    local existing_summaries current_entries token_entries rewrite_error=""
    existing_summaries=$(jq -c 'select(.type == "summary")' "$LOGFILE" 2>/dev/null) || rewrite_error="summaries"
    current_entries=$(jq -c --argjson since "$ROTATE_CUTOFF" 'select((.type // null) == null and .t >= $since)' "$LOGFILE" 2>/dev/null) || rewrite_error="current entries"
    token_entries=$(jq -c --argjson since "$token_cutoff" 'select(.type == "tokens" and .t >= $since)' "$LOGFILE" 2>/dev/null) || rewrite_error="token entries"

    if [ -n "$rewrite_error" ]; then
        # jq failed to read existing data — don't rewrite, archive already done
        # The archived entries will be duplicated on next rotation but no data is lost
        echo "WARNING: rotation rewrite failed reading $rewrite_error, log not rewritten" >> "${LOGDIR}/.rotation_errors" 2>/dev/null
        ! $quiet && echo "Warning: failed to read $rewrite_error, log not rewritten (archive saved)"
        return
    fi

    # flock: serialize with log writes to prevent lost entries during rewrite
    (
        flock -w 5 9 2>/dev/null || true
        { [ -n "$existing_summaries" ] && echo "$existing_summaries"
          [ -n "$summaries" ] && echo "$summaries"
          [ -n "$current_entries" ] && echo "$current_entries"
          [ -n "$token_entries" ] && echo "$token_entries"
        } > "${LOGFILE}.tmp" && mv "${LOGFILE}.tmp" "$LOGFILE"
    ) 9>"${LOGFILE}.lock"

    if ! $quiet; then
        local old_count
        old_count=$(echo "$old_entries" | wc -l)
        echo "Rotated $old_count entries ($summary_count projects) to $archive"
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
    --tokens)
        cat << 'TOKENS'
Statusline token reference:

  Time (from activity log)
    ⏱              status icon
    today 2h32m    today's active time for this project (Claude + You)
    🤖55m           today's Claude work time for this project
    👤1h37m         today's your active time for this project
    total 8h30m    all-time total for this project
    🤖 total       all-time Claude work for this project
    👤 total       all-time your work for this project
    08:22 ▮▮··▮▮ 17:30  day timeline with start/end times (▮=present ·=away)
    ▶1h12m         presence streak since last break (yellow >1.5h, red >2.5h)
    ⏸ 20m          last break duration (after first break)
    45m            current session active time

  Rate limits (from Claude Code)
    ◑50%           5h rate limit usage (○◔◑◕● matches visual fill)
    ↻3h21m         time until 5h window resets
    →51%           projected 5h usage at reset (yellow ≥90%, red ≥100%)
    ⑦5%            7-day rate limit usage
    ↻Sat           7-day reset weekday

  Context (from Claude Code)
    ctx 77%        context window fullness (auto-compacts at ~95%)
    ⟳93%           KV cache hit ratio from the last API response.
                   Drops during tool-heavy work (new content) or
                   after breaks (cache expires after inactivity).

  Cost budget (tracked per 5h window)
    $12.34/≈$40   cost used / inferred budget (cost_budget)
                   Uses actual API-equivalent session costs (includes
                   agents, tools). Two-zone: prior from last window
                   until pct=65%, then EMA(α=0.3) converges to actual.
                   Max/Opus ≈ $40 per 5h window.

  Other
    main ✓         git branch + status (✓=clean ✗=dirty +=staged ?=untracked)
    $1.23          session cost
    Opus 4.6 (local)  active model + config source:
                      local  = .claude/settings.local.json
                      project = .claude/settings.json
                      global = ~/.claude/settings.json
                      session = /model override or --model flag
                      default = no model configured anywhere

All tokens auto-hide when data is unavailable.
TOKENS
        exit 0
        ;;
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
    if [ "$MODE" = "statusline" ]; then printf '%s' "${COLOR_NORMAL}⏱ --${COLOR_DEFAULT}"
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
