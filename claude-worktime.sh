#!/usr/bin/env bash
# claude-worktime — track active working time in Claude Code sessions
#
# Platform support: Linux is the primary target (GNU coreutils, bash 4+).
# macOS is supported as a second-class target with vanilla system bash 3.2;
# bash 4+ idioms (mapfile, ${var,,}) are polyfilled in the macOS compat
# layer below. All OS-conditional code lives there; the rest of the file
# is pure Linux bash 4.
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
#   claude-worktime --cold [--today] [--all]  # cold-cache rewrites (❄ history;
#                                             # --all adds compact/resume cost)
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

# ============================================================
# macOS compatibility layer — Linux is the canonical target.
#
# The rest of this file is pure Linux code: bash 4+ syntax,
# GNU coreutils, no OS branches. Linux runtime path never
# touches the macOS conditionals — the check fires once at
# load time and locks the function bodies.
#
# macOS default target: vanilla system bash 3.2 + BSD utilities.
# All compatibility work for macOS lives in this section only.
# Anywhere else in the file, write canonical Linux bash 4.
# ============================================================
if [[ ${OSTYPE:-} == darwin* ]]; then
    _CW_IS_DARWIN=1

    # In-place sed: GNU takes no arg, BSD requires an explicit ''.
    _sedi() { sed -i '' "$@"; }

    # Reverse line order: GNU has tac; BSD ships tail -r.
    _tac() { tail -r; }

    # Lowercase: bash 4's ${var,,} doesn't exist in 3.2; tr fallback.
    _lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
    _lower_v() { _V=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]'); }

    # File mtime as epoch seconds: BSD stat syntax.
    _mtime_v() { _V=$(stat -f %m "$1" 2>/dev/null || echo 0); }

    # Millisecond epoch: BSD date lacks %N. Use python3 if present,
    # else seconds-resolution. Only used for --debug perf timer.
    if command -v python3 &>/dev/null; then
        _epoch_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
    else
        _epoch_ms() { echo $(( $(date +%s) * 1000 )); }
    fi

    # bash 3.2 polyfill for `mapfile -t VAR < <(cmd)`. Defined as a
    # function literally named `mapfile` so call sites stay literal;
    # bash resolves functions before built-ins. On Linux this function
    # is not defined and the bash 4 built-in is used directly — zero
    # cost to the Linux path.
    if ! type -t mapfile &>/dev/null; then
        mapfile() {
            local _name _line _arr=()
            # Consume flags; we only need to honor -t (strip trailing newline,
            # which `read -r` already does). Accept and ignore other -X flags.
            while [[ ${1:-} == -* ]]; do
                case $1 in
                    --) shift; break ;;
                    *) shift ;;
                esac
            done
            _name=${1:?mapfile: variable name required}
            # `|| [ -n "$_line" ]` catches the final line when input lacks a
            # trailing newline (read returns non-zero but $_line is set).
            while IFS= read -r _line || [ -n "$_line" ]; do _arr+=("$_line"); done
            eval "$_name=(\"\${_arr[@]}\")"
        }
    fi
else
    _CW_IS_DARWIN=0
    _sedi() { sed -i "$@"; }
    _tac() { tac; }
    # `eval` defers parsing of bash 4's ${v,,} so bash 3.2 (macOS) never
    # encounters it at script-load time — even though only the Darwin
    # branch executes there.
    eval '_lower() { local v=$1; printf "%s" "${v,,}"; }'
    # Variable-setting lowercase — no subshell on the statusline hot path.
    eval '_lower_v() { _V=${1,,}; }'

    # File mtime as epoch seconds (GNU stat).
    _mtime_v() { _V=$(stat -c %Y "$1" 2>/dev/null || echo 0); }

    # bash 5 has $EPOCHREALTIME (seconds.microseconds, no fork).
    # Older bash 4 falls back to GNU date +%s%N.
    if [[ ${EPOCHREALTIME:-} == *.* ]]; then
        _epoch_ms() { local r=${EPOCHREALTIME%.*}${EPOCHREALTIME#*.}; echo "${r:0:13}"; }
    else
        _epoch_ms() { echo $(( $(date +%s%N) / 1000000 )); }
    fi

fi
# ============================================================
# End of macOS compatibility layer.
# ============================================================

# Rate-limit group glyphs (platform-independent).
#   5h: U+29D7 ⧗ BLACK HOURGLASS — a short-window "time" mark, EAW=Neutral
#       (one cell everywhere) so it sits tight against the digit with no
#       de-crowding space: "⧗30%".
#   7d: U+2790 ➐ DINGBAT-7. Was U+2466 ⑦, which renders as tofu in several
#       common macOS monospace fonts; ➐ renders cleanly on both Linux and
#       macOS, so it replaces the old per-platform ⑦/➐ split with one glyph.
#       Trailing space de-crowds the digit.
_CW_GLYPH_5H="⧗"
_CW_GLYPH_7D="➐ "

# Paths: env vars > XDG spec > defaults
CONFIGDIR="${CLAUDE_WORKTIME_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-worktime}"
CONFIGFILE="${CONFIGDIR}/config.sh"
DATADIR="${CLAUDE_WORKTIME_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/claude-worktime}"

# --- Defaults (overridden by config.sh) ---
PAUSE_THRESHOLD=900
CLAUDE_CREDIT=0          # seconds of Claude response time credited as "user watching"
                         # 0 = auto (PAUSE_THRESHOLD / 3, ~5min at default 15min threshold)
HOME_ORG=""              # drop this leading "org/" from {project} (e.g. your code-host user dir); empty = keep full label
PROJECT_GIT_ANCHOR=false # anchor {project} to the git repo root so subdirs/worktrees show the repo
GROUP_PROJECT="{project} ({git})"
GROUP_TODAY="{status} today {today_project} 🤖{today_claude} 👤{today_you}"
GROUP_TOTAL="total {project_total}"
GROUP_TIMELINE="{today_start} {timeline} {today_now}"
GROUP_BREAKS="{since_break} {last_break}"
GROUP_RATE_5H="${_CW_GLYPH_5H}{rate_5h} ↻{rate_5h_reset} {rate_5h_proj}"
GROUP_RATE_7D="${_CW_GLYPH_7D}{rate_7d} ↻{rate_7d_day} {rate_7d_proj}"
GROUP_RATE_SCOPED="{rate_7d_scoped_name} {rate_7d_scoped} {rate_7d_scoped_proj}"
GROUP_CONTEXT="ctx {context}"
GROUP_COLD="{cold}"
GROUP_MODEL="{model}"
GROUP_EFFORT="{effort}"
# token_budget removed: weighted tokens only tracked main conversation,
# missing subagent costs (1.1-2.4x underestimate). Use {cost_budget} instead.
GROUP_TOKENS=""
GROUP_RATE_7D_COLOR="dark-gray"
GROUP_RATE_SCOPED_COLOR="dark-gray"
GROUP_CONTEXT_COLOR="dark-gray"
GROUP_BUDGET_COLOR="dark-gray"
# ❄ self-colours (cyan fresh / gray stale) — "none" stops the group wrapper
# from repainting it, and its own group means the ` · ` divider is inserted
# automatically only when a cold rewrite exists.
GROUP_COLD_COLOR="none"
GROUP_DIVIDER=" · "
STATUSLINE_1="PROJECT TODAY TOTAL"
STATUSLINE_2="TIMELINE BREAKS"
STATUSLINE_3="MODEL RATE_5H RATE_7D RATE_SCOPED CONTEXT COLD"
# Per-model colors for {model}: comma list of "substring=color" pairs,
# matched case-insensitively against the model id and display name.
# First match wins; unmatched models keep the group color.
MODEL_COLORS="fable=pink,opus=cyan"
# Model-scoped weekly limit (e.g. Fable on Max plans) is NOT in the
# statusline stdin — it's fetched from the OAuth usage endpoint in the
# background and cached. Seconds between fetches; 0 disables entirely.
USAGE_FETCH_INTERVAL=60
# Max age of a CACHED usage figure that may still be displayed. Past this,
# the percentage renders as "?" instead of a number: a fetch that keeps
# failing (expired token, no network, API change) must never leave a stale
# number on screen looking current. Generous vs USAGE_FETCH_INTERVAL so a
# brief offline blip doesn't blank the display.
USAGE_STALE_MAX=900
COLOR_NORMAL="green"
COLOR_RATE_WARNING="yellow"
COLOR_RATE_CRITICAL="red"
STREAK_WARNING=5400    # 1.5h — work streak turns yellow
STREAK_CRITICAL=9000   # 2.5h — work streak turns red
# Context % color ramp: smooth gradient from green → yellow → orange → red
# Starts shifting at CTX_RAMP_START%, fully red at CTX_RAMP_END%
# Below start: default color. Set to "" to disable ramp.
CTX_RAMP_START=20      # start shifting color from green
CTX_RAMP_END=90        # fully red at this %
COLOR_TIMELINE_WORK="green"    # color for present slots
COLOR_TIMELINE_BREAK="green"   # color for away slots
# Timeline glyphs — single characters, must differ. Use non-ASCII block
# glyphs: the colorizer substitutes them inside an already-escaped string,
# so an ASCII glyph could match inside an ANSI sequence.
#   ■ □ square    ▪ ▫ small square (default)    █ ░ full cell    ▮ ▯ vertical bar
TIMELINE_CHAR_WORK="▪"
TIMELINE_CHAR_AWAY="·"
TIMELINE_SLOT=1200  # seconds per timeline block (1200=20min, 1800=30min, 3600=1h)
COLOR_DEFAULT="dark-gray"
RATE_7D_PROJ_MIN_DAYS=1
AUTO_ROTATE=true
ROTATE_INTERVAL=daily  # daily, weekly, monthly
GAP_BUCKETS="60,300,600,900,1800"  # seconds: 1m, 5m, 10m, 15m, 30m
# Cold-cache tracking: ❄<size> statusline token (last rewrite) + prompt guard.
# TTL basis: Claude Code requests a 1h prompt-cache TTL for main-thread
# requests and detects expiry itself by clock math — both hardcoded in the
# CLI, no API to query (see docs/cache-ttl-verification.md; re-verify after
# CLI updates).
CACHE_GUARD_TTL=0         # cold-guard warning: OFF by default (0). Set to the
                          # prompt-cache TTL in seconds (e.g. 3600) to enable —
                          # then it warns at 0.9× that, mirroring the CLI's own
                          # warmth test. The ❄ display is unaffected either way.
CACHE_GUARD_MIN_CTX=50000 # don't warn below this context size (tokens)
CACHE_GUARD_CLIPBOARD=true # on a block, copy the prompt to the system clipboard
                          # (wl-copy/pbcopy/xclip/xsel) so resending is paste +
                          # submit. Set false to leave the clipboard untouched.
COLD_MIN_CTX=0            # optional cosmetic floor: hide rewrites whose prior
                          # context was below this (0 = show all). Session-start
                          # is excluded structurally, not by this — see below.
COLD_FRESH_SECS=900      # the ❄ token shows in cyan for this long after a
                          # rewrite, then dims to gray so an old value recedes

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
      end);

# --- Per-project active time ------------------------------------------------
#
# THE RULE, settled 2026-08-08: walk the FULL sorted event stream and credit
# each gap to the project of its EARLIER endpoint — the project the clock was
# running in when the gap opened — subject to the same is_idle suppression
# calc_active uses. Every gap is therefore credited exactly once, which is what
# makes the sum over all projects bounded by the log wall span.
#
# Do NOT go back to walking a per-project SLICE (`map(select(.p == $proj))`).
# Two events adjacent IN THE SLICE are not adjacent in time: the interval
# between them is every second the session spent in OTHER repos, and slicing
# bills all of it here. The bug hides because is_idle only suppresses a gap
# whose predecessor is `response` or `start`, and `tool_start`/`tool_end`/
# `prompt` can never be idle by construction — so a session that moves away
# mid-tool bills its whole absence to the project it left. Measured on the
# live log 2026-08-08: dotfiles read 2205h24m, of which a single 90-day
# gap (session 00e18b84, 2026-04-28 -> 2026-07-27) was 97.9%. Under this rule
# the same data reads 29h01m, and the all-projects sum falls from 6.6x the wall
# span to 0.31x.
#
# A gap that STRADDLES a project switch goes to the PREDECESSOR. Rejected:
# requiring BOTH endpoints to match, which drops straddling gaps entirely and
# under-counts a session interleaving repos rapidly — 19h11m on the same data,
# a floor rather than an answer; and splitting the gap, which would invent a
# boundary the log does not record.
#
# $root is the aggregation key. $fold additionally claims every path BELOW the
# root, which is what makes the key equal the label PROJECT_GIT_ANCHOR renders:
# the anchor folds subdirectories and linked worktrees into the repo root for
# the DISPLAY token, so the total must fold the same way or the label sits over
# a body it does not describe. $fold is only ever true for a resolved repo root
# (see _project_root_v) — an empty root must never fold, since "" + "/" is a
# prefix of every absolute path.
# The `// ""` is not decoration: startswith() raises on a null input, and this
# predicate is applied to summary records straight off disk. One summary
# without a .p would abort the whole statusline query and blank the display,
# which the mode goes out of its way never to do. The exact-match form it
# replaces was null-safe by accident; this one is null-safe on purpose.
def in_project($root; $fold):
  (.p // "") as $p
  | ($p == $root) or ($fold and ($p | startswith($root + "/")));

# Returns {claude, user, active} for $root in one pass — active is the sum, so
# this replaces a calc_active and a calc_split walk with a single traversal.
def active_in($pause; $root; $fold):
  . as $a | reduce range(1; $a|length) as $i (
    {claude: 0, user: 0};
    ($a[$i].t - $a[$i-1].t) as $gap
    | if $gap <= 0 then .
      elif is_idle($a; $i; $pause) then .
      elif (($a[$i-1] | in_project($root; $fold)) | not) then .
      elif is_user_turn($a; $i) then .user += $gap
      else .claude += $gap
      end)
  | .active = (.claude + .user);

# Same rule, every project at once, with the Claude/You split:
# {path: {claude, user, active}}. Seeded with zeros for every path present, so a
# project that is never a gap predecessor still gets a row — dropping it would
# silently change what --summary lists.
#
# This is the ONE implementation of the rule for the all-projects case. The
# rotation summary WRITER (_do_rotate) needs the split, the statusline and
# --summary need the totals, and a second walk written for the writer is how the
# read and write paths diverged in the first place: `f40e104` fixed every read
# path while the writer kept a per-project-SLICE calc_active — and a summary
# record REPLACES the events it summarises, so a reader cannot repair a value
# that was mis-computed at write time.
def split_by_project($pause):
  . as $a | reduce range(1; $a|length) as $i (
    (reduce $a[] as $e ({}; .[$e.p] = {claude: 0, user: 0}));
    ($a[$i-1].p) as $proj
    | ($a[$i].t - $a[$i-1].t) as $gap
    | if $gap <= 0 then .
      elif is_idle($a; $i; $pause) then .
      elif is_user_turn($a; $i) then .[$proj].user += $gap
      else .[$proj].claude += $gap
      end)
  | map_values(. + {active: (.claude + .user)});

# Totals only: {path: seconds}. Shape kept for its existing callers.
def active_by_project($pause):
  split_by_project($pause) | map_values(.active);'

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
# BSD `date -j -f "%Y-%m-%d" "$d"` inherits current time-of-day for unspecified
# fields, so parsing a date alone returns ~now rather than midnight. We force
# midnight with an explicit 00:00:00 in both format and value on the BSD branch.
_today_start() { date -d "today 00:00" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$(date +%Y-%m-%d) 00:00:00" +%s 2>/dev/null; }
_week_start() {
    local dow; dow=$(date +%u)
    if [ "$dow" = "1" ]; then _today_start
    else date -d "last monday" +%s 2>/dev/null || date -j -v-monday -v0H -v0M -v0S +%s 2>/dev/null; fi
}
_date_parse() { date -d "$1" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$1 00:00:00" +%s 2>/dev/null || echo 0; }

# --- Dependency check ---
_require_jq() { command -v jq &>/dev/null || { echo "Error: jq is required." >&2; exit 1; }; }

# Read log file safely — single pass, skips corrupt lines
_safe_log() {
    local file="${1:-$LOGFILE}"
    jq -Rc 'fromjson? // empty' "$file" 2>/dev/null
}

# Minimum versions: bash 3.2 (macOS vanilla) / 4.0 preferred, jq 1.6, git 2.22
cmd_check() {
    local ok=true

    # bash — Linux uses bash 4 idioms directly; macOS uses polyfills on bash 3.2
    local bash_ver="${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"
    if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
        printf "  bash %s  ✓\n" "$bash_ver"
    elif [ "${BASH_VERSINFO[0]}" -eq 3 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; then
        if (( _CW_IS_DARWIN )); then
            printf "  bash %s  ✓  (macOS, polyfills active)\n" "$bash_ver"
        else
            printf "  bash %s  ⚠  (works via polyfills; bash 4+ preferred on Linux)\n" "$bash_ver"
        fi
    else
        printf "  bash %s  ✗  (need ≥3.2)\n" "$bash_ver"
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

    # curl (optional — model-scoped weekly limit fetch)
    if command -v curl &>/dev/null; then
        printf "  curl  ✓  (optional, for {rate_7d_scoped} tokens)\n"
    else
        printf "  curl  —  (not installed, {rate_7d_scoped} tokens unavailable)\n"
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
    echo "  USAGE_FETCH_INTERVAL: ${USAGE_FETCH_INTERVAL}s"
    echo "  USAGE_STALE_MAX: ${USAGE_STALE_MAX}s"
    echo "  MODEL_COLORS:       ${MODEL_COLORS:-none}"
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
    t0=$(_epoch_ms)
    "$0" --statusline >/dev/null 2>&1
    t1=$(_epoch_ms)
    echo "  Statusline: $(( t1 - t0 ))ms"

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
# Uses [ -t 0 ] to skip immediately when invoked without a pipe (the common
# direct-CLI case). When a pipe is present, `read -t 1` is enough: hook
# stdin is buffered before the hook runs, so the read returns instantly on
# real data — the timeout only kicks in for the empty-pipe edge case.
# Integer timeout keeps this compatible with bash 3.2 (vanilla macOS).
_read_hook_stdin() {
    HOOK_SESSION_ID=""
    HOOK_CWD=""
    HOOK_TRANSCRIPT=""
    _STDIN_JSON=""
    [ -t 0 ] && return
    if read -t 1 -r _STDIN_JSON 2>/dev/null && [ -n "$_STDIN_JSON" ]; then
        # Fast bash parsing — avoid jq on the hot path
        # Extract "session_id":"VALUE" and "cwd":"VALUE" with parameter expansion
        local tmp="${_STDIN_JSON#*\"session_id\":\"}"
        HOOK_SESSION_ID="${tmp%%\"*}"
        [ "$HOOK_SESSION_ID" = "$_STDIN_JSON" ] && HOOK_SESSION_ID=""
        tmp="${_STDIN_JSON#*\"cwd\":\"}"
        HOOK_CWD="${tmp%%\"*}"
        [ "$HOOK_CWD" = "$_STDIN_JSON" ] && HOOK_CWD=""
        tmp="${_STDIN_JSON#*\"transcript_path\":\"}"
        HOOK_TRANSCRIPT="${tmp%%\"*}"
        [ "$HOOK_TRANSCRIPT" = "$_STDIN_JSON" ] && HOOK_TRANSCRIPT=""
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
    local label
    if [ -n "$second" ] && [ "$second" != "$last" ]; then
        label="$second/$last"
    else
        label="$last"
    fi
    [ -n "$HOME_ORG" ] && label="${label#"$HOME_ORG"/}"
    echo "$label"
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
    [ -n "$HOME_ORG" ] && _V="${_V#"$HOME_ORG"/}"
}
# Statusline project label: optionally anchor to the git repo root (so subdirs and
# worktrees show the repo), then shorten + drop HOME_ORG. Sets _V.
_project_label_v() {
    local path="$1"
    if [ -n "$path" ] && [ "${PROJECT_GIT_ANCHOR:-false}" = true ] && command -v git &>/dev/null; then
        # --show-toplevel is WORKTREE-scoped: inside a linked worktree it returns
        # that worktree's own root, i.e. it anchors to the very thing this option
        # exists to escape. The shared repo is --git-common-dir. Measured
        # 2026-08-07 with agent worktrees live: --show-toplevel gave
        # <repo>/.claude/worktrees/agent-<id> while --git-common-dir gave
        # <repo>/.git, so every agent lane silently booked its time under a
        # separate "project" that vanishes with the worktree.
        local common; common=$(git -C "$path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
        if [ -n "$common" ] && [ "${common##*/}" = ".git" ]; then
            path="${common%/.git}"
        else
            # --path-format needs git >= 2.31, and a non-standard layout may put
            # the common dir somewhere that is not <repo>/.git. Falling back to
            # the old behaviour is right: it is correct for subdirectories, which
            # is the common case, and wrong only where it was always wrong.
            local top; top=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)
            [ -n "$top" ] && path="$top"
        fi
    fi
    _short_project_v "$path"
}
# Statusline AGGREGATION KEY: the path a project's time is counted under.
# Sets _V (the root path) and _V_ANCHORED (true when the git anchor actually
# resolved — which is what licenses folding the paths BELOW the root into it).
#
# The git resolution is a deliberate second copy of _project_label_v's, not a
# shared call: tests/label-git-anchor.sh extracts _project_label_v verbatim with
# awk and sources it on its own, so delegating from there would leave the
# extracted function calling a name that is not in the extract. The copy is
# pinned against the original on the same cases by tests/project-total-fold.sh,
# so a divergence goes red rather than drifting quietly.
_project_root_v() {
    local path="$1"
    _V_ANCHORED=false
    if [ -n "$path" ] && [ "${PROJECT_GIT_ANCHOR:-false}" = true ] && command -v git &>/dev/null; then
        local common; common=$(git -C "$path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
        if [ -n "$common" ] && [ "${common##*/}" = ".git" ]; then
            path="${common%/.git}"; _V_ANCHORED=true
        else
            local top; top=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)
            [ -n "$top" ] && { path="$top"; _V_ANCHORED=true; }
        fi
    fi
    _V="$path"
}

# ============================================================
# Cold-cache guard — runs on UserPromptSubmit (log --prompt)
# ============================================================
# After an idle gap past the prompt-cache TTL, the next request silently
# re-writes the entire conversation prefix at the cache-write premium.
# Claude Code warns about this on resume-from-closed but not in an open idle
# session — its own check is the same clock math used here (idle time vs the
# TTL it requested; see docs/cache-ttl-verification.md). This guard blocks
# the first prompt after such a gap — once — so the user can /compact or
# /clear at the only moment that's cheap; resubmitting proceeds normally
# (the blocked prompt is copied to the clipboard to make that resend cheap).
# Every failure path returns silently: the guard must never block on error.
_cold_guard() {
    [ "${CACHE_GUARD_TTL:-0}" -gt 0 ] 2>/dev/null || return 0
    local sid="${HOOK_SESSION_ID:-}"
    [ -n "$sid" ] || return 0

    local now gap
    now=$(date +%s)

    # Both the context size and the idle gap come from the last logged token
    # entry for this session.
    #
    # NOT the transcript mtime, which is what this guard measured until
    # 2026-07-22 and why it never fired once across seven cold rewrites:
    # Claude Code appends the user message to the transcript *before* running
    # the UserPromptSubmit hook, so by the time we look, the file was written
    # milliseconds ago and the gap reads ~0. A token entry is only written
    # when a new API response arrives, which is precisely the event that last
    # warmed the cache — so its age is the idle gap we actually want.
    local line tmp last_tok=""
    while IFS= read -r line; do
        case "$line" in
            *'"type":"tokens"'*'"s":"'"$sid"'"'*) last_tok="$line" ;;
        esac
    done < <(tail -n 2000 "$LOGFILE" 2>/dev/null)
    [ -n "$last_tok" ] || return 0
    local cr cc ui
    # Trailing `}` strip: these fields are mid-record in every entry the
    # writer emits, so `%%,*` is enough today. If one ever lands last, the
    # captured value would carry the closing brace, fail the digit check
    # below, and silently switch this guard off — the failure mode it exists
    # to prevent. One substitution buys immunity to that.
    tmp="${last_tok#*\"cr\":}"; cr="${tmp%%,*}"; cr="${cr%\}}"
    tmp="${last_tok#*\"cc\":}"; cc="${tmp%%,*}"; cc="${cc%\}}"
    tmp="${last_tok#*\"ui\":}"; ui="${tmp%%,*}"; ui="${ui%\}}"
    tmp="${last_tok#*\"t\":}"; local last_ts="${tmp%%,*}"
    [ -n "$cr" ] && [ -n "$cc" ] && [ -n "$ui" ] && [ -n "$last_ts" ] || return 0
    case "${cr}${cc}${ui}${last_ts}" in *[!0-9]*) return 0 ;; esac
    local ctx_tok=$(( cr + cc + ui ))
    gap=$(( now - last_ts ))

    # Warn at 0.9×TTL, mirroring Claude Code's own warmth test
    # (`elapsed < TTL×0.9 ⟺ warm`, see docs/cache-ttl-verification.md): it
    # treats the cache as cold once 90% of the TTL has passed, giving a safety
    # margin so the warning lands just before — not after — the cache is gone.
    # CACHE_GUARD_TTL is the cache TTL itself; the warn point is derived.
    local warn_after=$(( CACHE_GUARD_TTL * 9 / 10 ))
    local met=0
    [ "$gap" -ge "$warn_after" ] \
        && [ "$ctx_tok" -ge "${CACHE_GUARD_MIN_CTX:-50000}" ] && met=1

    # Shadow entry on every evaluation, including the silent ones. A guard
    # that only records its hits cannot be told apart from a guard that never
    # runs — which is exactly how the transcript-mtime bug stayed invisible.
    # These make the miss rate measurable instead of assumed; tests/ replays
    # them. Kept 90 days by rotation, same as the hit entries.
    #
    # `met` is "both thresholds cleared", NOT "the user saw a warning": the
    # one-shot marker below still suppresses repeats within a single gap. The
    # k="warn" entries are the record of warnings actually delivered.
    (
        flock -w 2 9 2>/dev/null || true
        printf '{"type":"cold","t":%d,"s":"%s","k":"gauge","met":%d,"gap":%d,"ctx":%d}\n' \
            "$now" "$sid" "$met" "$gap" "$ctx_tok" >> "$LOGFILE"
    ) 9>"${LOGFILE}.lock"

    [ "$met" -eq 1 ] || return 0

    # A compact boundary NEWER than the last tokens entry means the context
    # that entry describes no longer exists: compaction writes no tokens
    # entry, so ctx_tok and gap above are pre-compact numbers. The old prefix
    # is already discarded — the next send writes the new (small) context
    # fresh no matter what the user does — and "compact now" was just done.
    # Observed 2026-08-05: warned "~422k context" sixty seconds after a
    # /compact that left ~57k. The boundary lives only in the transcript.
    # jq is fine here — this path is only reached past both thresholds, not
    # on every prompt (same reasoning as the clipboard block below).
    if [ -n "${HOOK_TRANSCRIPT:-}" ] && [ -f "$HOOK_TRANSCRIPT" ]; then
        local _bnd_info _bnd
        _bnd_info=$(_cw_compact_boundary_info "$HOOK_TRANSCRIPT")
        _bnd=${_bnd_info%% *}
        if [ "$_bnd" -gt "$last_ts" ] 2>/dev/null; then
            # Shadow entry, same rationale as the gauge one: a silent
            # suppression must be distinguishable from a guard that never ran.
            (
                flock -w 2 9 2>/dev/null || true
                printf '{"type":"cold","t":%d,"s":"%s","k":"stale-ctx","gap":%d,"ctx":%d,"bnd":%d}\n' \
                    "$now" "$sid" "$gap" "$ctx_tok" "$_bnd" >> "$LOGFILE"
            ) 9>"${LOGFILE}.lock"
            return 0
        fi
    fi

    # One-shot per idle gap: a marker newer than the last API response means
    # we already warned about this gap and the user chose to resubmit.
    local marker="${LOGDIR}/.cold_guard_last"
    if [ -f "$marker" ]; then
        local m_sid=""
        read -r m_sid < "$marker" 2>/dev/null
        _mtime_v "$marker"
        [ "$m_sid" = "$sid" ] && [ "${_V:-0}" -gt "$last_ts" ] && return 0
    fi
    echo "$sid" > "$marker" 2>/dev/null

    # Persist the event for longitudinal analysis (kept 90 days by rotation)
    (
        flock -w 2 9 2>/dev/null || true
        printf '{"type":"cold","t":%d,"s":"%s","k":"warn","gap":%d,"ctx":%d}\n' \
            "$now" "$sid" "$gap" "$ctx_tok" >> "$LOGFILE"
    ) 9>"${LOGFILE}.lock"

    # Copy the blocked prompt to the system clipboard so resending is
    # paste-and-submit, not a hand-select from scrollback — the whole point
    # of the guard is to make the cheap moment cheap, and re-typing a large
    # prompt is its own tax. Best-effort across platforms (wl-copy Wayland,
    # pbcopy macOS, xclip/xsel X11); backgrounded and output-swallowed so a
    # missing tool or a dead clipboard daemon never hangs or fails the hook
    # (line 837's prime directive). Opt out with CACHE_GUARD_CLIPBOARD=false.
    # jq is fine here — the block path is rare, unlike the log hot path.
    local copied=0
    if [ "${CACHE_GUARD_CLIPBOARD:-true}" != "false" ]; then
        local _prompt; _prompt=$(printf '%s' "$_STDIN_JSON" | jq -r '.prompt // empty' 2>/dev/null)
        if [ -n "$_prompt" ]; then
            local _clip=""
            if command -v wl-copy >/dev/null 2>&1;   then _clip="wl-copy"
            elif command -v pbcopy >/dev/null 2>&1;  then _clip="pbcopy"
            elif command -v xclip >/dev/null 2>&1;   then _clip="xclip -selection clipboard"
            elif command -v xsel >/dev/null 2>&1;    then _clip="xsel --clipboard --input"
            fi
            if [ -n "$_clip" ]; then
                ( printf '%s' "$_prompt" | $_clip >/dev/null 2>&1 & ) 2>/dev/null
                copied=1
            fi
        fi
    fi

    local gap_h=$(( gap / 3600 )) gap_m=$(( (gap % 3600) / 60 ))

    # Session-to-date rewrite tally. The ❄ statusline token shows only the
    # LAST hit, and shows it at whatever age it had when the statusline was
    # last rendered — an idle CLI never re-renders, so a hours-old event can
    # sit there reading "(7m)" and be mistaken for something that just
    # happened (observed 2026-07-27). This block is generated at read time,
    # by definition: whatever it says is true right now. A running total is
    # also the number that answers "is this costing me anything", which a
    # single most-recent event never does.
    local _tally=""
    if [ -f "$LOGFILE" ]; then
        local _hits _hitcc
        _hits=$(grep -c "\"k\":\"hit\".*\"s\":\"${sid}\"\|\"s\":\"${sid}\".*\"k\":\"hit\"" \
            "$LOGFILE" 2>/dev/null) || _hits=0
        case "${_hits:-}" in ''|*[!0-9]*) _hits=0 ;; esac
        # k:"hit-retract" markers cancel their matching hits (late-bind
        # resume-split); the tally must not report a retracted hit as cost.
        local _rt
        _rt=$(grep -c "\"k\":\"hit-retract\".*\"s\":\"${sid}\"\|\"s\":\"${sid}\".*\"k\":\"hit-retract\"" \
            "$LOGFILE" 2>/dev/null) || _rt=0
        case "${_rt:-}" in ''|*[!0-9]*) _rt=0 ;; esac
        _hits=$(( _hits - _rt )); [ "$_hits" -lt 0 ] && _hits=0
        if [ "$_hits" -gt 0 ]; then
            # Sum cc (tokens re-written at the write premium) across this
            # session's hits — the felt cost, not an event count — minus the
            # cc carried on each retract marker.
            _hitcc=$(grep "\"s\":\"${sid}\"" "$LOGFILE" 2>/dev/null \
                | grep "\"k\":\"hit\"" \
                | sed -n 's/.*"cc":\([0-9]*\).*/\1/p' \
                | awk '{s+=$1} END {print s+0}') || _hitcc=0
            case "${_hitcc:-}" in ''|*[!0-9]*) _hitcc=0 ;; esac
            local _rtcc
            _rtcc=$(grep "\"s\":\"${sid}\"" "$LOGFILE" 2>/dev/null \
                | grep "\"k\":\"hit-retract\"" \
                | sed -n 's/.*"cc":\([0-9]*\).*/\1/p' \
                | awk '{s+=$1} END {print s+0}') || _rtcc=0
            case "${_rtcc:-}" in ''|*[!0-9]*) _rtcc=0 ;; esac
            _hitcc=$(( _hitcc - _rtcc )); [ "$_hitcc" -lt 0 ] && _hitcc=0
            _tally=" Session so far: ${_hits} rewrite(s), ~$(( _hitcc / 1000 ))k."
        fi
    fi

    local _resend
    if [ "$copied" -eq 1 ]; then
        # "prompt text" not "prompt": the UserPromptSubmit payload carries only
        # the .prompt string — no image/attachment field exists (verified against
        # the hooks doc), so a pasted image can't be copied and must be
        # re-attached by hand. The word "text" signals that boundary without a
        # clutter line the hook can't scope (it can't detect whether an image
        # was pasted, so any explicit caveat would fire on every text-only block).
        _resend="Your prompt text is on the clipboard — paste and submit to send anyway (also echoed below)."
    else
        _resend="To send anyway, submit the prompt again — it is echoed below."
    fi
    printf '{"decision":"block","reason":"❄ Prompt cache likely cold: idle %dh%02dm (TTL %dmin) with ~%dk context. Sending now re-writes the whole context at the cache-write premium — cheapest moment to /compact or /clear is now.%s %s Warns once per gap."}' \
        "$gap_h" "$gap_m" "$(( CACHE_GUARD_TTL / 60 ))" "$(( ctx_tok / 1000 ))" "$_tally" "$_resend"
}

# ============================================================
# Subcommand: log — append a JSONL entry (called by hooks)
# ============================================================
cmd_log() {
    exec 2>/dev/null  # Claude Code treats any stderr as hook error (#34859)
    set +e  # hooks must not fail — a missed entry is better than blocking Claude Code

    # Skip logging when set by subprocesses (e.g. claude -p calls from hooks)
    # Prevents short-lived subprocess sessions from inflating Claude time
    [ "${CLAUDE_WORKTIME_SKIP_LOG:-}" = "1" ] && return 0

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
    # flock: serialize log writes with rotation to prevent lost entries
    (
        flock -w 2 9 2>/dev/null || true  # best-effort lock — don't block hooks
        if [ -n "$branch" ]; then
            printf '{"t":%d,"p":"%s","b":"%s","s":"%s","e":"%s"}\n' "$ts" "$jp" "$jb" "$js" "$event" >> "$LOGFILE"
        else
            printf '{"t":%d,"p":"%s","s":"%s","e":"%s"}\n' "$ts" "$jp" "$js" "$event" >> "$LOGFILE"
        fi
    ) 9>"${LOGFILE}.lock"

    if [ "$event" = "start" ]; then
        # Auto-rotate on session start
        $AUTO_ROTATE && [ -f "$LOGFILE" ] && _do_rotate true
        printf '{"systemMessage":"Session timer started at %s"}' "$(date +%H:%M)"
    elif [ "$event" = "prompt" ]; then
        # May block this prompt (one-shot) if the cache expired while idle
        _cold_guard
    fi
    return 0
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
    done < <(tail -50 "$LOGFILE" 2>/dev/null | _tac || true)
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
        | (\$all | sort_by(.t)) as \$stream
        | (\$today | active_in(\$pause; \$proot; \$pfold)) as \$tp
        | (\$stream | active_in(\$pause; \$proot; \$pfold)) as \$tot
        | [\$raw[] | select(.type == \"summary\") | select(in_project(\$proot; \$pfold))] as \$sums
        | (\$today | away_spans(\$pause; \$credit)) as \$away
        | {
            session_active: (\$session | calc_active(\$pause)),
            first_t: (\$session | if length > 0 then .[0].t else 0 end),
            last_break: (\$away | if length > 0 then last | (.to_t - .from_t) else 0 end),
            since_break: (if (\$away | length) > 0 then \$today[\$away[-1].return_idx:] | calc_active(\$pause)
                  else \$today | calc_active(\$pause) end),
            project: \$proot,
            branch: (\$session | [.[] | .b // empty] | if length > 0 then last else \"\" end),
            today_first_t: (\$today | if length > 0 then .[0].t else 0 end),
            today_active: (\$today | calc_active(\$pause)),
            today_project_active: \$tp.active,
            today_project_split: {claude: \$tp.claude, user: \$tp.user},
            project_total_active: (\$tot.active + ([\$sums[] | .active] | add // 0)),
            project_total_split: {
                claude: (\$tot.claude + ([\$sums[] | .claude // 0] | add // 0)),
                user: (\$tot.user + ([\$sums[] | .user // 0] | add // 0))
            },
            timeline: (if (\$today | length) > 0 then
                # One character per time slot (configurable via TIMELINE_SLOT)
                # \$tlwork = present (worked more than half the slot), \$tlaway = away
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
                    | if \$slot_len > 0 and (\$away_in_slot < (\$slot_len / 2)) then \$tlwork else \$tlaway end
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
    local _tl_work="${TIMELINE_CHAR_WORK:-▪}" _tl_away="${TIMELINE_CHAR_AWAY:-·}"
    # A glyph pair that collides would make every slot read as "present" and
    # break the leading-away trim below; fall back rather than lie.
    [ "$_tl_work" = "$_tl_away" ] && { _tl_work="▪"; _tl_away="·"; }
    # The AGGREGATION KEY for every per-project number below, resolved from the
    # same expression the log writer stamps into .p (see cmd_log), through the
    # same git anchor the label uses. That is the point: before 2026-08-08 the
    # key was the RAW logged cwd while the label was the ANCHORED one, so the
    # statusline showed "dotfiles" over a total that counted one exact cwd and
    # treated every subdirectory and agent worktree of the same repo as a
    # separate project. Deriving both from one value makes them equal by
    # construction rather than by convention.
    local _proot _pfold
    _project_root_v "${HOOK_CWD:-$(pwd)}"; _proot="$_V"; _pfold="$_V_ANCHORED"
    # Folding claims every path BELOW the root, which is only meaningful once a
    # real repo root resolved. With the anchor off the root is the raw cwd and
    # exact match is the whole rule; an empty root must never fold, since
    # "" + "/" is a prefix of every absolute path.
    [ -n "$_proot" ] || _pfold=false
    local _jq_args=(--argjson pause "$PAUSE_THRESHOLD" --argjson credit "$_credit" --argjson since "$today_start" --arg sid "$sid" --argjson now "$now" --argjson slot "${TIMELINE_SLOT:-1800}" --arg tlwork "$_tl_work" --arg tlaway "$_tl_away" --arg proot "$_proot" --argjson pfold "$_pfold")

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
    # Trim leading away-slots from timeline and adjust start time
    if [ -n "$tok_timeline" ]; then
        local trimmed="${tok_timeline#"${tok_timeline%%"$_tl_work"*}"}"
        if [ -n "$trimmed" ]; then
            # Count leading away-slots as GLYPHS, not bytes. LC_ALL=C is forced
            # (see top of file), so ${#…} counts bytes and · is 2 bytes — a byte
            # delta would double the count and push today_start hours forward.
            local _away="${tok_timeline%%"$_tl_work"*}" trimmed_count=0
            while [ -n "$_away" ]; do _away="${_away#"$_tl_away"}"; trimmed_count=$(( trimmed_count + 1 )); done
            local slot_secs="${TIMELINE_SLOT:-1800}"
            local adjusted_start=$(( (today_first / slot_secs + trimmed_count) * slot_secs ))
            tok_timeline="$trimmed"
            tok_today_start=$(date -d "@$adjusted_start" +%H:%M 2>/dev/null || date -r "$adjusted_start" +%H:%M 2>/dev/null)
        else
            [ "${today_first:-0}" -gt 0 ] && tok_today_start=$(date -d "@$today_first" +%H:%M 2>/dev/null || date -r "$today_first" +%H:%M 2>/dev/null)
        fi
    else
        [ "${today_first:-0}" -gt 0 ] && tok_today_start=$(date -d "@$today_first" +%H:%M 2>/dev/null || date -r "$today_first" +%H:%M 2>/dev/null)
    fi
    tok_today_now=$(date +%H:%M)
    _fmt_short_v "$today_project_active"; tok_today_project="$_V"
    _fmt_short_v "${today_claude_active:-0}"; tok_today_claude="$_V"
    _fmt_short_v "${today_you_active:-0}"; tok_today_you="$_V"
    _fmt_short_v "$project_total_active"; tok_project_total="$_V"
    _fmt_short_v "${total_claude_active:-0}"; local tok_total_claude="$_V"
    _fmt_short_v "${total_you_active:-0}"; local tok_total_you="$_V"
    # $project is already the anchored root (jq echoes back $proot), so only the
    # shortening is left — anchoring it twice would be the same work, and going
    # through _project_label_v here would let the label drift from the key the
    # totals were computed under.
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
        tok_since_break="${streak_color}▶ $_V${COLOR_DEFAULT}"
    else
        tok_since_break="▶ $_V"
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

    # Tokens from Claude Code stdin JSON (rate limits, context, cost, model, effort)
    local tok_rate_5h="" tok_rate_5h_reset="" tok_rate_5h_proj="" tok_rate_7d="" tok_rate_7d_reset="" tok_rate_7d_day="" tok_rate_7d_proj="" tok_context="" tok_cold="" tok_cost_budget="" tok_cost="" tok_model="" tok_effort=""
    local tok_rate_7d_scoped="" tok_rate_7d_scoped_name="" tok_rate_7d_scoped_proj=""
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
            (.model.id // "_"),
            (.effort.level // "_"),
            (.transcript_path // "_")
        ] | join("\t")' <<< "$_STDIN_JSON" 2>/dev/null || true)

        local r5h r5h_reset r7d r7d_reset ctx cache_create cache_read uncached_input output_tokens cum_input cum_output cst mdl mdl_id eff tp_path
        IFS=$'\t' read -r r5h r5h_reset r7d r7d_reset ctx cache_create cache_read uncached_input output_tokens cum_input cum_output cst mdl mdl_id eff tp_path <<< "$stdin_parsed"
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
        # Strip the context-window suffix (e.g. " (1M context)") from the
        # display name — redundant in the statusline.
        [[ "$mdl" == *" ("*"context)" ]] && mdl="${mdl% (*context)}"
        # Persist the current model for external consumers (e.g. commit hooks
        # comparing a hand-typed attribution trailer against the live runtime:
        # the model can change MID-session, so any snapshot taken at session
        # start goes stale silently). File mtime doubles as the freshness
        # signal. Last-writer-wins across concurrent sessions — consumers
        # must treat this as advisory, never as a hard gate.
        [ -n "$mdl" ] && printf '%s\n' "$mdl" > "${LOGDIR}/.current_model" 2>/dev/null
        [ "$eff" = "_" ] && eff=""
        [ -n "$eff" ] && tok_effort="$eff"
        [ "$tp_path" = "_" ] && tp_path=""

        # Context token: fullness % with color ramp, plus ❄<size> for the
        # most recent cold rewrite. No hit-ratio metric: it pins at 95-99% in steady state
        # (cached prefix dwarfs each turn's new tokens). Instead the token
        # logger below counts actual cold rewrites — rare events where an
        # idle gap expired the cache and the full context was re-written
        # at the cache-write premium.
        if [ -n "$ctx" ]; then
            local ctx_int="${ctx%%.*}"
            local ctx_color=""
            # Smooth color ramp: green → yellow → orange → red (8-step ANSI 256)
            # Compressed green range so 50% is clearly yellow, not green
            # 46(green) 118 190 226(yellow) 214(orange) 208 202 196(red)
            if [ -n "${CTX_RAMP_START:-}" ] && [ "$ctx_int" -ge "${CTX_RAMP_START}" ]; then
                local -a _ctx_ramp=(46 118 190 226 214 208 202 196)
                local ramp_range=$(( ${CTX_RAMP_END:-90} - CTX_RAMP_START ))
                local ramp_pos=$(( ctx_int - CTX_RAMP_START ))
                [ "$ramp_pos" -gt "$ramp_range" ] && ramp_pos=$ramp_range
                local idx=$(( ramp_pos * 7 / ramp_range ))
                [ "$idx" -gt 7 ] && idx=7
                ctx_color=$'\033[38;5;'"${_ctx_ramp[$idx]}m"
            fi
            local ctx_str="${ctx_int}%"
            [ -n "$ctx_color" ] && ctx_str="${ctx_color}${ctx_int}%${COLOR_DEFAULT}"
            tok_context="${ctx_str}"

            # ❄ shows the SIZE of the most recent cold rewrite this session
            # (4th state field), not a count: 130k re-written at the write
            # premium is the felt cost; a bare tally flattens a 504k event and
            # a 25k one into the same "2". Both maintained by the token logger
            # below (reads the previous render's value — fine, it only grows).
            # Gate on the size, not the count: a pre-existing state file with
            # no size stays hidden until its next rewrite instead of ❄0k.
            # Renders SIZE CAUSE (AGE), e.g. "❄ 397k other (2m)": what / why /
            # when. Space-separated so the group divider's ` · ` stays the only
            # ` · ` on the line; the age is parenthesised so it reads plainly as
            # "how long ago" rather than an arbitrary duration. Its own {cold}
            # token (GROUP_COLD), self-coloured cyan when fresh and dimming to
            # gray past COLD_FRESH_SECS so a ghost value visually recedes — the
            # age answers what a static value can't: did this just happen?
            local cold_lastcc=0 cold_lasthit_t=0 cold_lastcause="-" cold_count=0
            [ -f "${LOGDIR}/.cold_${sid}" ] && read -r cold_count _ _ cold_lastcc cold_lasthit_t cold_lastcause _ < "${LOGDIR}/.cold_${sid}" 2>/dev/null
            case "${cold_lastcc:-}" in ''|*[!0-9]*) cold_lastcc=0 ;; esac
            case "${cold_lasthit_t:-}" in ''|*[!0-9]*) cold_lasthit_t=0 ;; esac
            case "${cold_count:-}" in ''|*[!0-9]*) cold_count=0 ;; esac
            if [ "$cold_lastcc" -gt 0 ]; then
                # Round to nearest k so 130098 → 130k, 54344 → 54k
                local _cold_k=$(( (cold_lastcc + 500) / 1000 ))
                # Session index, PREFIXED. A suffixed count (`… idle (17m) ×3`)
                # reads as a multiplier on the event it follows — "this 263k
                # idle bust, three times" — which is the opposite of the truth.
                # As a leading ordinal it frames what follows: "bust #3 this
                # session; the latest was 263k, idle, 17m ago". Omitted at N=1.
                # The index is also the only part of the token that stays honest
                # on a frozen statusline: an idle CLI never re-renders, so the
                # age can sit at "(4m)" for hours (observed 2026-07-27), but a
                # monotonic count can only under-report, never mislead.
                local _cold_txt="❄ "
                # #N counts BUSTS; when the displayed event is a controlled
                # cost class (compact/resume) the index would misread as that
                # class's count, so it shows only on bust-class causes.
                case "$cold_lastcause" in
                    compact|auto-compact|resume) ;;
                    *) [ "$cold_count" -gt 1 ] && _cold_txt="❄ #${cold_count} " ;;
                esac
                _cold_txt="${_cold_txt}${_cold_k}k"
                # Cause (skip the legacy "-" placeholder)
                [ -n "$cold_lastcause" ] && [ "$cold_lastcause" != "-" ] && _cold_txt="${_cold_txt} ${cold_lastcause}"
                # Age since the rewrite, parenthesised (2m, 1h3m); omit if unknown
                local _cold_color=$'\033[38;5;81m'   # cyan = fresh
                if [ "$cold_lasthit_t" -gt 0 ]; then
                    local _cold_age=$(( now - cold_lasthit_t ))
                    [ "$_cold_age" -lt 0 ] && _cold_age=0
                    local _cold_agestr
                    if [ "$_cold_age" -lt 3600 ]; then _cold_agestr="$(( _cold_age / 60 ))m"
                    else _cold_agestr="$(( _cold_age / 3600 ))h$(( (_cold_age % 3600) / 60 ))m"; fi
                    _cold_txt="${_cold_txt} (${_cold_agestr})"
                    # Dim once it's no longer "just now"
                    [ "$_cold_age" -ge "${COLD_FRESH_SECS:-900}" ] && _cold_color=$'\033[38;5;246m'
                fi
                tok_cold="${_cold_color}${_cold_txt}${COLOR_DEFAULT}"
            fi
        fi

        if [ -n "$r5h" ]; then
            # Just the percentage — the ⧗ hourglass label lives in
            # GROUP_RATE_5H (like ➐ for 7d), not baked into the token, so a
            # near-empty limit still reads plainly and the glyph never
            # depends on the value.
            tok_rate_5h="${r5h%%.*}%"
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
                    "$HOME/.claude/settings.json") _ms_src="global" ;;
                    *settings.local.json) _ms_src="local" ;;
                    *) _ms_src="project" ;;
                esac
                # Normalize before matching: settings values may carry a
                # context-window suffix ("claude-fable-5[1m]") that model.id
                # never has — strip any trailing [..] from both sides.
                _ms_val="${_ms_val%%\[*}"
                local _id_lc _val_lc
                _lower_v "${mdl_id%%\[*}"; _id_lc="$_V"
                _lower_v "$_ms_val"; _val_lc="$_V"
                # Check if settings value matches model.id (substring match)
                # e.g. "opus" matches "claude-opus-4-6", "claude-opus-4-6" matches exactly
                if [ "$_val_lc" = "default" ]; then
                    # Explicit "default" = account default, not a session override
                    _model_source="$_ms_src"
                elif [ "$_val_lc" = "opusplan" ]; then
                    # opusplan runs Opus for planning, Sonnet otherwise —
                    # both are the configured model, not a session override
                    case "$_id_lc" in
                        *opus*|*sonnet*) _model_source="$_ms_src" ;;
                        *) _model_source="session" ;;
                    esac
                elif [ -n "$_id_lc" ] && [[ "$_id_lc" == *"$_val_lc"* ]]; then
                    _model_source="$_ms_src"
                else
                    _model_source="session"
                fi
                break
            done
            if [ "$_model_source" = "default" ] || [ "$_model_source" = "global" ]; then
                tok_model="$mdl"
            else
                tok_model="$mdl ($_model_source)"
            fi

            # Per-model color: first matching "substring=color" pair wins.
            # COLOR_DEFAULT is rewritten to the group color at render time,
            # so the rest of the group keeps its own color.
            if [ -n "${MODEL_COLORS:-}" ]; then
                local _mc_pair _mc_pat _mc_col _mc_hay _saveIFS
                _lower_v "$mdl_id $mdl"; _mc_hay="$_V"
                _saveIFS="$IFS"; IFS=','
                for _mc_pair in $MODEL_COLORS; do
                    _mc_pat="${_mc_pair%%=*}"
                    _mc_col="${_mc_pair#*=}"
                    [ -z "$_mc_pat" ] || [ "$_mc_pat" = "$_mc_pair" ] && continue
                    _lower_v "$_mc_pat"
                    if [[ "$_mc_hay" == *"$_V"* ]]; then
                        _resolve_color_v "$_mc_col"
                        [ -n "$_V" ] && tok_model="${_V}${tok_model}${COLOR_DEFAULT}"
                        break
                    fi
                done
                IFS="$_saveIFS"
            fi
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
            else
                tok_rate_7d_proj="→…"
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

        # Model-scoped weekly limit (e.g. the Fable bucket on Max plans) —
        # Claude Code does NOT include it in the statusline stdin, only the
        # all-models 5h/7d buckets. It lives in the `limits` array of
        # GET /api/oauth/usage as kind="weekly_scoped" with a model scope.
        # Fetched in the background and cached; the statusline never blocks
        # on the network — it renders the cache and kicks off a refresh
        # when the cache is older than USAGE_FETCH_INTERVAL.
        #
        # The fetch interval is keyed on a SEPARATE lock file, never on the
        # cache itself: the cache's mtime is the age of the last SUCCESSFUL
        # response, which is what the USAGE_STALE_MAX gate below reads.
        # Touching the cache to rate-limit would forge that freshness and a
        # permanently failing fetch would display its last number forever.
        if [[ "$all_formats" == *"{rate_7d_scoped"* ]] && [ "${USAGE_FETCH_INTERVAL:-0}" -gt 0 ] 2>/dev/null; then
            local usage_cache="${LOGDIR}/.usage_cache"
            local usage_lock="${LOGDIR}/.usage_fetch"
            local _ul_mtime; _mtime_v "$usage_lock"; _ul_mtime="$_V"
            if [ $(( now - _ul_mtime )) -ge "$USAGE_FETCH_INTERVAL" ]; then
                # Touch first: acts as a lock so overlapping statusline runs
                # don't stack up fetches while this one is in flight.
                touch "$usage_lock" 2>/dev/null
                (
                    _tok=$(jq -r '.claudeAiOauth.accessToken // empty' \
                        "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" 2>/dev/null)
                    # macOS stores credentials in the Keychain, not a file
                    [ -z "$_tok" ] && command -v security &>/dev/null && \
                        _tok=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
                            | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
                    if [ -n "$_tok" ]; then
                        _resp=$(curl -sf --max-time 10 "https://api.anthropic.com/api/oauth/usage" \
                            -H "Authorization: Bearer $_tok" \
                            -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null)
                        # TLS-intercepting proxies (claude-code-cache-fix,
                        # corporate MITM) re-sign with a CA that node trusts
                        # via NODE_EXTRA_CA_CERTS but curl does not — retry
                        # once bypassing the proxy before giving up.
                        [ -z "$_resp" ] && [ -n "${HTTPS_PROXY:-${https_proxy:-}}" ] && \
                            _resp=$(curl -sf --max-time 10 --noproxy '*' \
                                "https://api.anthropic.com/api/oauth/usage" \
                                -H "Authorization: Bearer $_tok" \
                                -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null)
                        # Only overwrite the cache with a well-formed response
                        [ -n "$_resp" ] && jq -e '.limits' <<< "$_resp" >/dev/null 2>&1 \
                            && printf '%s\n' "$_resp" > "$usage_cache" 2>/dev/null
                    fi
                ) >/dev/null 2>&1 </dev/null &
            fi
            if [ -s "$usage_cache" ]; then
                local scoped_parsed
                scoped_parsed=$(jq -r '
                    [.limits[]? | select(.kind == "weekly_scoped" and .scope.model != null)][0] // empty
                    | [
                        (.scope.model.display_name // "model"),
                        ((.percent // "_") | tostring),
                        (((.resets_at // "" | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z")) | try fromdateiso8601 catch "_") | tostring)
                      ] | join("\t")
                ' "$usage_cache" 2>/dev/null || true)
                if [ -n "$scoped_parsed" ]; then
                    local sc_name sc_pct sc_reset
                    IFS=$'\t' read -r sc_name sc_pct sc_reset <<< "$scoped_parsed"
                    # Staleness gate: the cache mtime is the age of the last
                    # successful fetch. Past USAGE_STALE_MAX the number is no
                    # longer evidence of anything — show "?" so a silently
                    # broken fetch reads as unknown, never as current.
                    local _uc_mtime; _mtime_v "$usage_cache"; _uc_mtime="$_V"
                    local sc_stale=0
                    [ $(( now - _uc_mtime )) -ge "${USAGE_STALE_MAX:-900}" ] && sc_stale=1
                    if [ "$sc_stale" = 1 ]; then
                        tok_rate_7d_scoped_name="${sc_name:-model}"
                        tok_rate_7d_scoped="?%"
                    elif [ -n "$sc_pct" ] && [ "$sc_pct" != "_" ]; then
                        tok_rate_7d_scoped_name="$sc_name"
                        tok_rate_7d_scoped="${sc_pct%%.*}%"
                        # Projection at week's end — same math and coloring as {rate_7d_proj}
                        if [ "$sc_reset" != "_" ] && [ "$sc_reset" -gt "$now" ] 2>/dev/null; then
                            local sc_elapsed=$(( 7 * 86400 - (sc_reset - now) ))
                            [ "$sc_elapsed" -lt 60 ] && sc_elapsed=60
                            if [ "$sc_elapsed" -ge "$RATE_7D_PROJ_MIN_SECONDS" ]; then
                                local sc_proj=$(( ${sc_pct%%.*} * 7 * 86400 / sc_elapsed ))
                                local sc_proj_color=""
                                if [ "$sc_proj" -ge 100 ] && [ -n "${COLOR_RATE_CRITICAL:-}" ]; then
                                    sc_proj_color="$COLOR_RATE_CRITICAL"
                                elif [ "$sc_proj" -ge 90 ] && [ -n "${COLOR_RATE_WARNING:-}" ]; then
                                    sc_proj_color="$COLOR_RATE_WARNING"
                                fi
                                if [ -n "$sc_proj_color" ]; then
                                    tok_rate_7d_scoped_proj="${sc_proj_color}→${sc_proj}%${COLOR_DEFAULT}"
                                else
                                    tok_rate_7d_scoped_proj="→${sc_proj}%"
                                fi
                            else
                                tok_rate_7d_scoped_proj="→…"
                            fi
                        fi
                    fi
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
            # cr+cc+ui == 0 is "no usage data yet", never a measurement — no
            # API response bills zero tokens everywhere. Compact/clear
            # completion renders report exactly that, and persisting one as a
            # real turn resets the idle clock and zeroes prev-ctx, defeating
            # both the idle classifier and the /compact skip (measured
            # 2026-07-31 (capture since rotated): a post-compact 51k first write booked as
            # a false hit against prev=0 with a 10h idle gap read as 32min).
            if [ -n "${sid:-}" ] && [ "${sid:-}" != "" ] \
                && [ $(( ${t_cr:-0} + ${t_cc:-0} + ${t_ui:-0} )) -gt 0 ] \
                && ([ "${t_cr:-0}" != "$tp_cr" ] || [ "${t_cc:-0}" != "$tp_cc" ]); then
                echo "${t_cr:-0} ${t_cc:-0}" > "$token_prev" 2>/dev/null
                # Cold-rewrite detection for the ❄ token: this request wrote
                # (cc) most of the previous context while reading (cr) almost
                # none of it back from cache — the cache expired and the full
                # prefix was re-written at the write premium. Ratios instead of
                # cr==0 so a surviving global system-prompt cache entry can't
                # mask a cold conversation, and /compact (small cc relative to
                # the previous context) doesn't false-positive.
                # State fields (space-delimited):
                #   count ctx now lastcc lasthit_t lastcause prevmodel
                # The first four are numeric; ctx/now/prevmodel update every
                # turn (they describe THIS turn, read as "previous" next turn),
                # while lastcc/lasthit_t/lastcause change only on a hit and are
                # carried forward otherwise. lasthit_t + lastcause feed the ❄
                # token's age and cause; prevmodel lets a hit tell a model
                # switch from an idle expiry. Old 4-field files: the three new
                # fields read empty and default cleanly.
                local cold_state="${LOGDIR}/.cold_${sid}"
                local cs_count=0 cs_prev=0 cs_prev_t=0 cs_lastcc=0 cs_lasthit_t=0 cs_lastcause="-" cs_prevmodel="-" cold_hit="" cold_cost="" cold_gap=0
                local _cw_cause="" _cw_miss_tok=0 _cw_prev_blocks="[]" _cw_prev_stop="" _cw_user_bytes=0 _cw_concur=0
                [ -f "$cold_state" ] && read -r cs_count cs_prev cs_prev_t cs_lastcc cs_lasthit_t cs_lastcause cs_prevmodel < "$cold_state" 2>/dev/null
                # Validate the numeric fields only; strings default below.
                case "${cs_count:-}${cs_prev:-}${cs_prev_t:-}${cs_lastcc:-}${cs_lasthit_t:-}" in
                    ''|*[!0-9]*) cs_count=0; cs_prev=0; cs_prev_t=0; cs_lastcc=0; cs_lasthit_t=0 ;;
                esac
                cs_count=${cs_count:-0}; cs_prev=${cs_prev:-0}; cs_prev_t=${cs_prev_t:-0}
                cs_lastcc=${cs_lastcc:-0}; cs_lasthit_t=${cs_lasthit_t:-0}
                [ -n "$cs_lastcause" ] || cs_lastcause="-"
                [ -n "$cs_prevmodel" ] || cs_prevmodel="-"
                # Current model id, sanitized for the space-delimited state file.
                local cur_model="${mdl_id:-}"
                [ -n "$cur_model" ] || cur_model="-"
                cur_model="${cur_model// /_}"
                local ctx_tok=$(( ${t_cr:-0} + ${t_cc:-0} + ${t_ui:-0} ))
                # Skip the session's first write: cr=0 / cc=whole-initial-context
                # is mechanically identical to a cold rewrite, so telling them
                # apart used to need a 25k magnitude floor. cs_prev_t>0 asks the
                # real question — has a prior turn been logged this session? — so
                # a brand-new session is skipped while a resume after cache expiry
                # (prior turn exists, cache gone) still flags. COLD_MIN_CTX is now
                # just an optional cosmetic floor (default 0, shows everything).
                if [ "$cs_prev_t" -gt 0 ] && [ "$cs_prev" -ge "${COLD_MIN_CTX:-0}" ] \
                    && [ "${t_cc:-0}" -ge $(( cs_prev * 6 / 10 )) ] \
                    && [ "${t_cr:-0}" -le $(( cs_prev / 5 )) ]; then
                    [ "$cs_prev_t" -gt 0 ] && cold_gap=$(( now - cs_prev_t ))
                    # Classify the cause. idle first: a gap past the cache TTL
                    # kills the cache regardless of model. Else a model change
                    # since the previous turn is a cache-key switch. Else
                    # "other" — same model, no idle: an injection/eviction/race
                    # not visible in the usage numbers alone.
                    local cause_ttl=${CACHE_GUARD_TTL:-3600}
                    [ "$cause_ttl" -gt 0 ] 2>/dev/null || cause_ttl=3600
                    if [ "$cold_gap" -ge $(( cause_ttl * 9 / 10 )) ]; then
                        cs_lastcause="idle"
                    elif [ "$cs_prevmodel" != "-" ] && [ "$cs_prevmodel" != "$cur_model" ]; then
                        cs_lastcause="model"
                    else
                        # Residual: idle-TTL and model-switch are already ruled
                        # out above (both are visible from the state file alone
                        # and cheaper to check than a transcript read). For what's
                        # left, ask the API itself instead of tail-grepping for
                        # co-occurrence strings: every assistant transcript entry
                        # carries message.diagnostics.cache_miss_reason
                        # {type, cache_missed_input_tokens} straight from the
                        # provider. Observed types (1,137 events, 2026-07-31):
                        # messages_changed / tools_changed / system_changed /
                        # previous_message_not_found / unavailable — the last two
                        # arrive BARE, with no cache_missed_input_tokens key, so
                        # the // 0 default below is what makes them read as 0
                        # rather than null. The list is observed, not exhaustive,
                        # and the read below passes .type through verbatim: an
                        # unlisted value logs correctly without a code change.
                        # (model_changed was listed here until 2026-07-31 and
                        # occurs in none of the 1,137 — assumed, never observed.)
                        # previous_message_not_found means the
                        # transcript resumed/forked (see below — routed out of
                        # the hit ledger, not a live bust). Read only on a hit
                        # (rare) so the statusline stays cheap; missing/older
                        # transcripts (no diagnostics field) degrade to "other"
                        # rather than blocking or crashing the statusline.
                        cs_lastcause="other"
                        if [ -n "${tp_path:-}" ] && [ -r "$tp_path" ]; then
                            local _cw_diag
                            # ANCHOR THE READ TO THE BUSTING TURN.
                            #
                            # This used to be `tail -n 1` over all assistant
                            # entries — "the newest entry is the turn that just
                            # busted". It frequently is not: CC writes the entry
                            # AFTER the response returns while this hook fires ON
                            # that response, so the newest entry on disk is often
                            # the PREVIOUS turn. That silently copied a foreign
                            # turn's diagnostics onto this bust.
                            #
                            # Measured 2026-07-27, ❄ #9: recorded
                            # cause=unavailable for a cc=245997 bust. The 245997
                            # turn's own diagnostic was messages_changed;
                            # "unavailable" belonged to an earlier, HEALTHY turn
                            # (cc=5386, cr=260636) that was merely the last one
                            # written at read time. A plausible-but-wrong cause is
                            # worse than "other" — "other" at least announces that
                            # it knows nothing.
                            #
                            # cache_creation_input_tokens identifies the turn: it
                            # is exactly the t_cc this bust was detected on. No
                            # match means the busting entry has not been flushed
                            # yet, which is the honest "other" — and the
                            # late-binding re-read below upgrades it once it lands.
                            # Entries with no usage block cannot be matched or
                            # excluded on cc, so they stay eligible: an entry
                            # that carries usage must MATCH this bust's cc,
                            # while one that carries none is accepted as before.
                            # That keeps the anchor strict exactly where the
                            # evidence to be strict exists.
                            _cw_diag=$(jq -c --argjson cc "${t_cc:-0}" \
                                'select(.type == "assistant")
                                 | select((.message.usage | not)
                                          or (.message.usage.cache_creation_input_tokens == $cc))' \
                                "$tp_path" 2>/dev/null | tail -n 1)
                            if [ -n "$_cw_diag" ]; then
                                _cw_cause=$(jq -r '.message.diagnostics.cache_miss_reason.type // empty' <<< "$_cw_diag" 2>/dev/null)
                                _cw_miss_tok=$(jq -r '.message.diagnostics.cache_miss_reason.cache_missed_input_tokens // 0' <<< "$_cw_diag" 2>/dev/null)
                                case "$_cw_miss_tok" in ''|*[!0-9]*) _cw_miss_tok=0 ;; esac
                                [ -n "$_cw_cause" ] && cs_lastcause="$_cw_cause"
                                # Forensic fields (change 3): content-block types
                                # of the preceding assistant turn, its stop_reason
                                # (tool_use = the turn before the busting one was
                                # still mid-flight), byte size of the newest
                                # user-role entry before the bust, and how many
                                # other transcripts in this project dir were
                                # touched within the last 5 minutes (concurrent
                                # subagent proxy). All cheap jq/stat, all gated
                                # behind the hit branch so the non-hit path never
                                # pays for them.
                                _cw_prev_blocks=$(jq -c '[.message.content[]?.type] // []' <<< "$_cw_diag" 2>/dev/null)
                                [ -n "$_cw_prev_blocks" ] || _cw_prev_blocks="[]"
                                _cw_prev_stop=$(jq -r '.message.stop_reason // empty' <<< "$_cw_diag" 2>/dev/null)
                                local _cw_last_user
                                _cw_last_user=$(jq -c 'select(.type == "user")' "$tp_path" 2>/dev/null | tail -n 1)
                                _cw_user_bytes=${#_cw_last_user}
                                if [ -n "${tp_path:-}" ]; then
                                    local _cw_pdir; _cw_pdir=$(dirname "$tp_path")
                                    _cw_concur=$(find "$_cw_pdir" -maxdepth 1 -name '*.jsonl' -newermt "@$(( now - 300 ))" 2>/dev/null | wc -l | tr -d ' ')
                                    case "$_cw_concur" in ''|*[!0-9]*) _cw_concur=0 ;; esac
                                    [ "$_cw_concur" -gt 0 ] && _cw_concur=$(( _cw_concur - 1 ))
                                fi
                            fi
                        fi
                    fi
                    # previous_message_not_found is a resume/fork/compact
                    # artifact — a REAL miss the user should see (feedback:
                    # what did my action cost?), but never a bust. It books
                    # k:"cost" below with an honest label (compact when a
                    # compact_boundary newer than the last real turn explains
                    # it, else resume) and advances the ❄ display, while the
                    # bust count and `--cold`'s default hit history stay a
                    # record of prevention targets only.
                    if [ "$cs_lastcause" = "previous_message_not_found" ]; then
                        cold_cost=1
                        cs_lastcause="resume"
                        if [ -n "${tp_path:-}" ] && [ -r "$tp_path" ]; then
                            local _cw_bi _cw_bep _cw_btr
                            _cw_bi=$(_cw_compact_boundary_info "$tp_path")
                            _cw_bep=${_cw_bi%% *}; _cw_btr=${_cw_bi##* }
                            if [ "$_cw_bep" -gt "$cs_prev_t" ]; then
                                cs_lastcause="compact"
                                [ "$_cw_btr" = "auto" ] && cs_lastcause="auto-compact"
                            fi
                        fi
                        cs_lastcc=${t_cc:-0}
                        cs_lasthit_t=$now
                    else
                        cs_count=$(( cs_count + 1 ))
                        cold_hit=1
                        cs_lastcc=${t_cc:-0}
                        cs_lasthit_t=$now
                    fi
                elif [ "$cs_prev_t" -gt 0 ] && [ "${ctx_tok:-0}" -gt 0 ] \
                    && [ "${t_cc:-0}" -ge $(( ctx_tok * 6 / 10 )) ] \
                    && [ "${t_cr:-0}" -le $(( ctx_tok / 5 )) ] \
                    && [ -n "${tp_path:-}" ] && [ -r "$tp_path" ]; then
                    # Post-compact first write with the hit predicate NOT met
                    # (prev ctx much larger than the compacted context): a
                    # full fresh write of the CURRENT context, evidenced by a
                    # compact_boundary newer than the last real turn. A real
                    # miss the user (or the auto-compact ceiling) caused —
                    # displayed as compact/auto-compact cost, never booked as
                    # a hit. Without the boundary evidence this shape stays
                    # silent (no speculation).
                    local _cw_bi2 _cw_bep2 _cw_btr2
                    _cw_bi2=$(_cw_compact_boundary_info "$tp_path")
                    _cw_bep2=${_cw_bi2%% *}; _cw_btr2=${_cw_bi2##* }
                    if [ "$_cw_bep2" -gt "$cs_prev_t" ]; then
                        cold_cost=1
                        cold_gap=$(( now - cs_prev_t ))
                        cs_lastcause="compact"
                        [ "$_cw_btr2" = "auto" ] && cs_lastcause="auto-compact"
                        cs_lastcc=${t_cc:-0}
                        cs_lasthit_t=$now
                    fi
                fi
                # Late-binding upgrade for a raced read.
                #
                # CC writes the assistant transcript entry AFTER the API
                # response returns, and this hook fires on that same response,
                # so the entry carrying cache_miss_reason routinely lands
                # milliseconds later. Measured 2026-07-27: a bust at
                # 19:04:57.321 persisted cause=other at 19:04:57 while the
                # transcript held tools_changed(49153) all along — a knowable
                # cause frozen as "unknown", which then misled an
                # investigation and put a wrong claim in a threat matrix.
                #
                # A genuine no-diagnostics bust and a raced read are
                # indistinguishable at write time, so this does not guess:
                # "other" simply stays re-checkable for a bounded window, and
                # a cause found later replaces it. A settled cause is never
                # rewritten. Genuinely causeless busts stay "other" forever,
                # which is correct — no sentinel promises an upgrade that
                # cannot come.
                #
                # Window-bounded (COLD_LATE_BIND_SECS, default 120s) because
                # the diagnostics reads are otherwise gated behind the hit
                # branch so the common path never pays for them; the race
                # closes in seconds, so a couple of minutes covers it without
                # putting a jq on every render for the rest of the session.
                local _cw_lb=${COLD_LATE_BIND_SECS:-120}
                if [ "$cs_lastcause" = "other" ] && [ -z "$cold_hit" ] \
                    && [ "$cs_lasthit_t" -gt 0 ] \
                    && [ $(( now - cs_lasthit_t )) -le "$_cw_lb" ] \
                    && [ -n "${tp_path:-}" ] && [ -r "$tp_path" ]; then
                    local _cw_late
                    # Anchored to the busting turn by its cache-creation count
                    # (cs_lastcc, persisted when the hit was booked) — same
                    # reason as the read above: the newest assistant entry is
                    # frequently a DIFFERENT turn, and copying its cause is how
                    # ❄ #9 came to read "unavailable" for a messages_changed
                    # bust. Waiting for the right entry is correct; adopting the
                    # wrong one is not.
                    _cw_late=$(jq -c --argjson cc "${cs_lastcc:-0}" \
                        'select(.type == "assistant")
                         | select((.message.usage | not)
                                  or (.message.usage.cache_creation_input_tokens == $cc))' \
                        "$tp_path" 2>/dev/null | tail -n 1)
                    if [ -n "$_cw_late" ]; then
                        local _cw_late_cause
                        _cw_late_cause=$(jq -r '.message.diagnostics.cache_miss_reason.type // empty' <<< "$_cw_late" 2>/dev/null)
                        # Retraction is destructive (the one state decrement
                        # in this path), so it demands PROOF the entry IS the
                        # booked turn: usage matching cs_lastcc. The anchor
                        # above also admits usage-less entries — kept loose
                        # for cause adoption — but an unproven resume cause
                        # takes no action at all: no retract, and no adoption
                        # either (the split forbids displaying it). Cause
                        # stays "other", re-checkable within the window.
                        local _cw_late_cc
                        _cw_late_cc=$(jq -r '.message.usage.cache_creation_input_tokens // empty' <<< "$_cw_late" 2>/dev/null)
                        if [ "$_cw_late_cause" = "previous_message_not_found" ] \
                            && [ "$_cw_late_cc" != "${cs_lastcc:-0}" ]; then
                            :   # unproven resume cause — leave "other" standing
                        elif [ "$_cw_late_cause" = "previous_message_not_found" ]; then
                            # The resume-split, applied late. The booking-time
                            # split (change 2) only sees causes available at
                            # write time; a raced read books the hit as "other"
                            # first, and adopting this cause here would render
                            # it in the ❄ token — the exact display the split
                            # forbids (measured 2026-07-31, capture since rotated: a
                            # post-/compact first write shown as a 51k bust).
                            # Retract instead: un-inflate the count, and
                            # append a k:"cost" record for the audit trail
                            # plus a k:"hit-retract" marker keyed (s, hit_t)
                            # so the append-only ledger self-corrects and
                            # every k:"hit" reader can drop the matching
                            # record. The DISPLAY stays (lastcc/lasthit_t
                            # kept): the event was a real miss the user should
                            # still see — relabeled as its cost class. compact
                            # only when the boundary sits inside the booked
                            # hit's OWN idle gap (read from its ledger record;
                            # a boundary outside that gap belongs to an
                            # earlier, unrelated compact), else resume. Gap
                            # unreadable -> 2h fallback window.
                            local _cw_rt_t=$cs_lasthit_t _cw_rt_cc=$cs_lastcc
                            [ "$cs_count" -gt 0 ] && cs_count=$(( cs_count - 1 ))
                            cs_lastcause="resume"
                            local _cw_hit_gap
                            _cw_hit_gap=$(grep "\"s\":\"${sid}\"" "$LOGFILE" 2>/dev/null \
                                | grep '"k":"hit"' \
                                | jq -r --argjson ht "$_cw_rt_t" 'select(.t == $ht) | .gap // empty' 2>/dev/null | tail -n 1)
                            case "${_cw_hit_gap:-}" in ''|*[!0-9]*) _cw_hit_gap=7200 ;; esac
                            local _cw_bi3 _cw_bnd _cw_btr3
                            _cw_bi3=$(_cw_compact_boundary_info "$tp_path")
                            _cw_bnd=${_cw_bi3%% *}; _cw_btr3=${_cw_bi3##* }
                            if [ "$_cw_bnd" -gt $(( _cw_rt_t - _cw_hit_gap - 60 )) ] && [ "$_cw_bnd" -le $(( now + 60 )) ]; then
                                cs_lastcause="compact"
                                [ "$_cw_btr3" = "auto" ] && cs_lastcause="auto-compact"
                            fi
                            (
                                flock -w 2 9 2>/dev/null || true
                                printf '{"type":"cold","t":%d,"s":"%s","k":"cost","gap":0,"ctx":%d,"cc":%d,"cause":"%s","mdl":"%s"}\n' \
                                    "$now" "$sid" "${ctx_tok:-0}" "$_cw_rt_cc" "$cs_lastcause" "$cur_model" >> "$LOGFILE"
                                printf '{"type":"cold","t":%d,"s":"%s","k":"hit-retract","hit_t":%d,"cc":%d}\n' \
                                    "$now" "$sid" "$_cw_rt_t" "$_cw_rt_cc" >> "$LOGFILE"
                            ) 9>"${LOGFILE}.lock"
                        elif [ -n "$_cw_late_cause" ]; then
                            cs_lastcause="$_cw_late_cause"
                            # The upgrade must reach the LEDGER, not only the
                            # display state written below. Until it did, the
                            # raced-read cause was corrected on screen while the
                            # record kept "other" forever — and the record is
                            # the artifact every later analysis reads (measured:
                            # a messages_changed bust displayed correctly and
                            # booked as "other", the ❄ token and `--cold`
                            # disagreeing about the same event). "other" is a
                            # degraded default meaning "no cause available";
                            # left standing it reads as a genuinely causeless
                            # bust and silently under-reports every knowable
                            # class. Append-only, same shape as the retract
                            # marker above: k:"hit-cause" keyed (s, hit_t) so
                            # k:"hit" readers apply it without the ledger ever
                            # being rewritten in place. The outer guard
                            # (cs_lastcause = "other") is what makes this fire
                            # exactly once — the next render sees the adopted
                            # cause and skips the whole branch.
                            local _cw_late_mtok
                            _cw_late_mtok=$(jq -r '.message.diagnostics.cache_miss_reason.cache_missed_input_tokens // 0' <<< "$_cw_late" 2>/dev/null)
                            case "${_cw_late_mtok:-}" in ''|*[!0-9]*) _cw_late_mtok=0 ;; esac
                            (
                                flock -w 2 9 2>/dev/null || true
                                printf '{"type":"cold","t":%d,"s":"%s","k":"hit-cause","hit_t":%d,"cc":%d,"cause":"%s","mtok":%d}\n' \
                                    "$now" "$sid" "$cs_lasthit_t" "${cs_lastcc:-0}" "$_cw_late_cause" "$_cw_late_mtok" >> "$LOGFILE"
                            ) 9>"${LOGFILE}.lock"
                        fi
                    fi
                fi
                echo "${cs_count} ${ctx_tok} ${now} ${cs_lastcc} ${cs_lasthit_t} ${cs_lastcause} ${cur_model}" > "$cold_state" 2>/dev/null
                # The hit record is written inside the lock below; the desktop
                # notification is then derived FROM that record rather than
                # re-rendered from live variables. Single source: if the append
                # doesn't land, no notification fires, so a popup can never
                # describe an event the ledger lacks (they were previously two
                # independent renderings that could silently disagree — the
                # ledger being the one nobody checks). The subshell reports the
                # bytes it committed on stdout; empty means nothing was logged.
                local _cw_committed=""
                _cw_committed=$(
                    flock -w 2 9 2>/dev/null || true
                    printf '{"type":"tokens","t":%d,"s":"%s","cr":%d,"cc":%d,"ui":%d,"out":%d,"pct":%s,"cst":%s,"ctx":%s,"ci":%s,"co":%s,"w":%s}\n' \
                        "$now" "$sid" "$t_cr" "$t_cc" "$t_ui" "$t_out" "${r5h:-0}" "${cst:-0}" "${ctx:-0}" "${cum_input:-0}" "${cum_output:-0}" "${r5h_reset:-0}" >> "$LOGFILE"
                    # Cold events persist 90 days across rotation (tokens don't)
                    # cc = tokens actually re-written this event (the reactivation
                    # size); ctx = full context after it. On a hit cc dominates
                    # ctx, but logging it explicitly avoids the cr+ui overcount.
                    # cause = idle|model|<API cache_miss_reason.type>|other; mdl =
                    # model id at the rewrite — together they let `--cold` and
                    # later analysis separate the knowable causes from the
                    # residual. mtok = cache_missed_input_tokens as reported by
                    # the API (0 when no diagnostics were available). Forensic
                    # fields (additive, self-analyzing rather than requiring a
                    # fresh forensic pass next time): pblk = content-block types
                    # of the preceding assistant turn; flight = true when that
                    # turn's stop_reason was tool_use (still mid-flight when the
                    # bust landed); ubytes = byte size of the newest user-role
                    # transcript entry before the busting turn; concur = other
                    # transcript files in the same project dir touched in the
                    # last 5 minutes (concurrent-subagent proxy). None of these
                    # correlated in the n=6 2026-07-26 sample; logged so the next
                    # occurrences are self-analyzing.
                    if [ -n "$cold_hit" ]; then
                        local _cw_flight="null"
                        case "$_cw_prev_stop" in
                            tool_use) _cw_flight="true" ;;
                            end_turn) _cw_flight="false" ;;
                        esac
                        local _cw_rec
                        _cw_rec=$(printf '{"type":"cold","t":%d,"s":"%s","k":"hit","gap":%d,"ctx":%d,"cc":%d,"cause":"%s","mdl":"%s","mtok":%d,"pblk":%s,"flight":%s,"ubytes":%d,"concur":%d}' \
                            "$now" "$sid" "$cold_gap" "$ctx_tok" "${t_cc:-0}" "$cs_lastcause" "$cur_model" \
                            "${_cw_miss_tok:-0}" "$_cw_prev_blocks" "$_cw_flight" "${_cw_user_bytes:-0}" "${_cw_concur:-0}")
                        # Emit on stdout ONLY if the append succeeded — this is
                        # what the parent notifies from.
                        printf '%s\n' "$_cw_rec" >> "$LOGFILE" && printf '%s' "$_cw_rec"
                    fi
                    # Controlled-cost classes (compact/resume): real misses,
                    # never busts — logged under k:"cost" so `--cold` keeps a
                    # bust-only default history; `--cold --all` includes them.
                    [ -n "$cold_cost" ] && printf '{"type":"cold","t":%d,"s":"%s","k":"cost","gap":%d,"ctx":%d,"cc":%d,"cause":"%s","mdl":"%s"}\n' \
                        "$now" "$sid" "$cold_gap" "$ctx_tok" "${t_cc:-0}" "$cs_lastcause" "$cur_model" >> "$LOGFILE"
                    :
                ) 9>"${LOGFILE}.lock"

                # Desktop notification on a real hit only (never on a resume
                # artifact) — pointer to the runbook, not the forensics
                # themselves; keeping the message static means it works
                # whether or not the runbook has been installed yet. Outside
                # the flock (fire-and-forget must never hold the log lock
                # open), backgrounded so a slow/hung notification daemon can't
                # delay the statusline, and silently skipped when notify-send
                # isn't installed — this must never block or fail the render.
                # Gated on _cw_committed (the record the ledger actually took),
                # NOT on cold_hit: a notification that isn't backed by a log
                # line is a claim nobody can audit, and the audit trail is the
                # point. Numbers are parsed back out of that record so popup and
                # ledger cannot drift.
                # COLD_NOTIFY=false suppresses the popup entirely. The test
                # suites drive this same code path with synthetic fixtures,
                # and without an opt-out they fire REAL desktop
                # notifications indistinguishable from live busts — two
                # were mistaken for unexplained production events on
                # 2026-07-27 and sent an investigation after a phantom
                # "160k bust" that was only ever a fixture value.
                if [ "${COLD_NOTIFY:-true}" != "false" ] \
                   && [ -n "$_cw_committed" ] && command -v notify-send >/dev/null 2>&1; then
                    local _cw_n_cc _cw_n_cause _cw_n_sid
                    _cw_n_cc=${_cw_committed##*\"cc\":}; _cw_n_cc=${_cw_n_cc%%,*}
                    case "${_cw_n_cc:-}" in ''|*[!0-9]*) _cw_n_cc=0 ;; esac
                    _cw_n_cause=${_cw_committed##*\"cause\":\"}; _cw_n_cause=${_cw_n_cause%%\"*}
                    _cw_n_sid=${_cw_committed##*\"s\":\"}; _cw_n_sid=${_cw_n_sid%%\"*}
                    # Session tag: three concurrent sessions produced three
                    # popups reading 40k/47k/263k with no way to tell two of
                    # them belonged elsewhere (2026-07-27). The short id is what
                    # `--cold` and the snapshot filenames key on, so the popup
                    # now joins up with the forensics instead of floating free.
                    local _cw_notify_k=$(( (_cw_n_cc + 500) / 1000 ))
                    ( notify-send --expire-time=10000 \
                        "Cache bust: ${_cw_notify_k}k re-cached (${_cw_n_cause})" \
                        "Session ${_cw_n_sid%%-*} — see ~/.claude/cachebust-runbook.md or run: claude-worktime --cold" \
                        >/dev/null 2>&1 & ) 2>/dev/null
                fi
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
        # Colorize timeline: work glyph = present, away glyph = break
        [ -n "$COLOR_TIMELINE_WORK" ] && tok_timeline="${tok_timeline//"$_tl_work"/${COLOR_TIMELINE_WORK}${_tl_work}${COLOR_DEFAULT}}"
        [ -n "$COLOR_TIMELINE_BREAK" ] && tok_timeline="${tok_timeline//"$_tl_away"/${COLOR_TIMELINE_BREAK}${_tl_away}${COLOR_DEFAULT}}"
    fi

    # Token arrays (constant per statusline refresh, shared by all groups)
    local -a _atokens=( '{session}' '{session_wall}' '{today}' '{today_wall}' '{today_start}' '{today_now}' '{today_project}' '{today_claude}' '{today_you}' '{project_total}' '{total_claude}' '{total_you}' '{project}' '{branch}' '{status}' '{git}' '{timeline}' )
    local -a _avalues=( "$tok_session" "$tok_session_wall" "$tok_today" "$tok_today_wall" "$tok_today_start" "$tok_today_now" "$tok_today_project" "$tok_today_claude" "$tok_today_you" "$tok_project_total" "$tok_total_claude" "$tok_total_you" "$tok_project" "$tok_branch" "$tok_status" "$tok_git" "$tok_timeline" )
    local -a opt_tokens=( '{last_break}' '{since_break}' '{rate_5h}' '{rate_5h_reset}' '{rate_5h_proj}' '{rate_7d}' '{rate_7d_reset}' '{rate_7d_day}' '{rate_7d_proj}' '{rate_7d_scoped_name}' '{rate_7d_scoped_proj}' '{rate_7d_scoped}' '{context}' '{cold}' '{cost_budget}' '{cost}' '{model}' '{effort}' )
    local -a opt_values=( "$tok_last_break" "$tok_since_break" "$tok_rate_5h" "$tok_rate_5h_reset" "$tok_rate_5h_proj" "$tok_rate_7d" "$tok_rate_7d_reset" "$tok_rate_7d_day" "$tok_rate_7d_proj" "$tok_rate_7d_scoped_name" "$tok_rate_7d_scoped_proj" "$tok_rate_7d_scoped" "$tok_context" "$tok_cold" "$tok_cost_budget" "$tok_cost" "$tok_model" "$tok_effort" )

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
                # "none" = no wrapping (for groups with inline ANSI codes)
                color_var_name="GROUP_${name}_COLOR"
                if [ -n "${!color_var_name+set}" ]; then
                    _resolve_color_v "${!color_var_name}"; grp_color="$_V"
                else
                    grp_color="$color"
                fi
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
        sort_by(.t) | active_by_project(\$pause) | to_entries | map({
            project: (.key | split(\"/\") | if length >= 2 then [.[-2], .[-1]] | join(\"/\") else last end),
            active: .value
        }) | sort_by(-.active)
    ")

    if $raw; then
        # `+=`, not `. + {…}`: the key is a TWO-SEGMENT LABEL, so two distinct
        # raw paths can share one — /one/dev/proj and /two/dev/proj both render
        # dev/proj — and object `+` overwrites, dropping one project's whole
        # total. Measured on the live log 2026-08-08: 190 keys for 197 distinct
        # raw paths, the sum reading 958h20m against a true 967h31m.
        # Pre-existing; the non-raw branch below never lost it, since it prints
        # one row per raw path.
        echo "$result" | jq 'reduce .[] as $x ({}; .[$x.project] += $x.active)'
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
            ROTATE_CUTOFF=$(date -d "today 00:00" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$(date +%Y-%m-%d) 00:00:00" +%s 2>/dev/null)
            ROTATE_SUFFIX=$(date -d "yesterday" +%Y-%m-%d 2>/dev/null || date -j -v-1d +%Y-%m-%d 2>/dev/null)
            ;;
        weekly)
            local dow; dow=$(date +%u)
            if [ "$dow" = "1" ]; then
                ROTATE_CUTOFF=$(date -d "today 00:00" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$(date +%Y-%m-%d) 00:00:00" +%s 2>/dev/null)
            else
                ROTATE_CUTOFF=$(date -d "last monday" +%s 2>/dev/null || date -j -v-monday -v0H -v0M -v0S +%s 2>/dev/null)
            fi
            ROTATE_SUFFIX=$(date -d "@$((ROTATE_CUTOFF - 1))" +%Y-W%V 2>/dev/null || date -r "$((ROTATE_CUTOFF - 1))" +%Y-W%V 2>/dev/null)
            ;;
        monthly|*)
            ROTATE_CUTOFF=$(date -d "$(date +%Y-%m-01)" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$(date +%Y-%m-01) 00:00:00" +%s 2>/dev/null)
            ROTATE_SUFFIX=$(date -d "last month" +%Y-%m 2>/dev/null || date -j -v-1m +%Y-%m 2>/dev/null)
            ;;
    esac
}

_do_rotate() {
    local quiet=${1:-false}
    [ ! -f "$LOGFILE" ] && return

    _rotate_boundaries

    # Every read below goes through _safe_log. The log is append-only from
    # concurrent hooks, so a malformed line is expected, not exceptional — and a
    # plain `jq` over the whole file turns one bad line into a dead rotation.
    # Measured 2026-08-08: 46 malformed lines from one 13-minute window on
    # 2026-04-01 had jammed every rotation since (1,052 identical entries in
    # .rotation_errors, last archive activity-2026-03-31.jsonl, live log 83 MB).
    # Unconditional rather than the read path's fast-path-then-fall-back shape
    # (:1159): the first read here ends in `head -1`, and under `pipefail` the
    # resulting SIGPIPE makes jq exit 141 on a CLEAN file too, so a failure
    # signal there cannot be told from normal operation.

    # Check if there are old event entries (skip summaries)
    local first_event_ts
    first_event_ts=$(_safe_log "$LOGFILE" | jq -r 'select((.type // null) == null) | .t' 2>/dev/null | head -1 || true)
    [ -z "$first_event_ts" ] || [ "$first_event_ts" -ge "$ROTATE_CUTOFF" ] && return

    # Collect old event entries to archive
    local old_entries collect_error=""
    old_entries=$(_safe_log "$LOGFILE" | jq -c --argjson since "$ROTATE_CUTOFF" 'select((.type // null) == null and .t < $since)' 2>/dev/null) || collect_error="true"

    if [ -n "$collect_error" ]; then
        # This read used to end in `|| true`. A dying reader emits everything up
        # to the failure and then exits non-zero; `|| true` discarded that, the
        # emptiness guard below accepted the prefix as the whole set, and the
        # append at the archive step would have written it. Measured against the
        # real log: 3,964 records against 351,753 valid ones. A read failure is
        # now a refusal to archive, not a silent partial.
        echo "WARNING: rotation could not read the entries to archive, skipping archive" >> "${LOGDIR}/.rotation_errors" 2>/dev/null
        ! $quiet && echo "Warning: failed to read entries to archive, rotation skipped (data preserved)"
        return
    fi
    [ -z "$old_entries" ] && return

    # Generate per-project summaries BEFORE archiving.
    #
    # Through split_by_project — the SAME rule every read path uses (:404) —
    # never a per-project slice. This shape used to be
    # `group_by(.p) | map(sort_by(.t) | calc_active)`, which walks each
    # project's own events as if they were adjacent in time: the interval
    # between two of them is every second the session spent in other repos, and
    # the slice bills all of it here. is_idle suppresses a gap only when its
    # predecessor is `response` or `start`, so a session that moves away
    # mid-tool bills its whole absence to the project it left.
    #
    # It is worse here than on any read path, which is why the writer is the
    # gate on AUTO_ROTATE rather than hygiene: a summary record REPLACES the
    # events it summarises, so the inflated number is permanent — `f40e104`
    # fixed the readers, and a reader cannot repair a value mis-computed at
    # write time.
    #
    # The `select(.t < $since)` prefix is a TIME prefix, not a slice: every
    # excluded event is later than every included one, so events adjacent in
    # the prefix are still adjacent in time. Only per-project slicing breaks
    # the rule.
    #
    # The key stays the raw `.p`, exactly as the event records carry it — the
    # read path folds keys by path containment at read time (in_project, :1187)
    # and must keep answering for summaries the same way it answers for events.
    local summaries summary_error=""
    summaries=$(_safe_log "$LOGFILE" | jq -sc --argjson since "$ROTATE_CUTOFF" --argjson pause "$PAUSE_THRESHOLD" "
        ${JQ_CALC}
        [.[] | select((.type // null) == null) | select(.t < \$since)]
        | sort_by(.t)
        | split_by_project(\$pause)
        | to_entries[]
        | {
            type: \"summary\",
            p: .key,
            active: .value.active,
            claude: .value.claude,
            user: .value.user,
            period: \"$ROTATE_SUFFIX\"
        }
    " 2>/dev/null) || summary_error="true"

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
    local existing_summaries current_entries token_entries cold_entries rewrite_error=""
    existing_summaries=$(_safe_log "$LOGFILE" | jq -c 'select(.type == "summary")' 2>/dev/null) || rewrite_error="summaries"
    current_entries=$(_safe_log "$LOGFILE" | jq -c --argjson since "$ROTATE_CUTOFF" 'select((.type // null) == null and .t >= $since)' 2>/dev/null) || rewrite_error="current entries"
    token_entries=$(_safe_log "$LOGFILE" | jq -c --argjson since "$token_cutoff" 'select(.type == "tokens" and .t >= $since)' 2>/dev/null) || rewrite_error="token entries"
    # Cold-cache events: rare, kept 90 days for longitudinal TTL analysis
    cold_entries=$(_safe_log "$LOGFILE" | jq -c --argjson since "$(( ROTATE_CUTOFF - 7776000 ))" 'select(.type == "cold" and .t >= $since)' 2>/dev/null) || rewrite_error="cold entries"

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
          [ -n "$cold_entries" ] && echo "$cold_entries"
          :  # group must exit 0 — an empty last entry class would skip the mv
        } > "${LOGFILE}.tmp" && mv "${LOGFILE}.tmp" "$LOGFILE"
    ) 9>"${LOGFILE}.lock"

    # Prune cold-counter state files of sessions idle for over a week
    find "$LOGDIR" -maxdepth 1 -name '.cold_*' -mtime +7 -delete 2>/dev/null

    # Prune archives past the retention horizon. The active log is bounded by
    # the rewrite above, but archives were appended and never removed — growth
    # was linear and unbounded by construction (~15MB over the first two
    # months). Default 730 days: long enough that year-over-year comparison
    # still works, finite so the directory cannot grow forever. Set
    # ARCHIVE_RETAIN_DAYS=0 to keep everything.
    if [ "${ARCHIVE_RETAIN_DAYS:-730}" -gt 0 ] 2>/dev/null; then
        find "$LOGDIR" -maxdepth 1 -name 'activity-*.jsonl' \
            -mtime "+${ARCHIVE_RETAIN_DAYS:-730}" -delete 2>/dev/null
    fi

    if ! $quiet; then
        local old_count
        old_count=$(echo "$old_entries" | wc -l)
        echo "Rotated $old_count entries ($summary_count projects) to $archive"
    fi
}

# List cold-cache rewrites (type=cold, k=hit) — the history behind the ❄
# statusline token, which only shows the most recent one. Defaults to the
# current session; --today/--week/--since/--session widen or retarget.
# Read the activity log LINE-TOLERANTLY.
#
# `jq FILTER file` parses the whole file as one stream: a single malformed
# line aborts it and every later record is lost. The log is append-only from
# concurrent hooks, so partial writes happen — 46 of 423,106 lines were
# corrupt on 2026-07-28.
#
# That is not a hypothetical. `--cold` used the whole-file form with stderr
# sent to /dev/null, so a parse error at line 6326 produced an empty result
# and it printed "No cold rewrites recorded" while 26 real cold-rewrite
# records sat in the file — including the 484k event being investigated at
# that very moment. Absence of evidence rendered as evidence of absence, in
# the instrument used to check everything else.
#
# `-R` reads raw lines and `fromjson? // empty` drops only the lines that
# fail, so one bad line costs one record instead of the rest of the file.
# The idiom was already used in seven other places in this file; the readers
# that mattered most did not have it.
_log_json() {
    jq -Rc 'fromjson? // empty' "$LOGFILE" 2>/dev/null
}

# "epoch trigger" of the newest compact_boundary entry in a transcript
# ("0 -" if none). CC writes {"type":"system","subtype":"compact_boundary",
# "timestamp":ISO,"compactMetadata":{"trigger":"manual"|"auto",…}} at each
# compaction; a boundary newer than the last real turn is the evidence that
# a following full fresh write is compaction cost, not a bust, and the
# trigger tells the operator's /compact from an auto-compact at the context
# ceiling — different feedback, different label.
_cw_compact_boundary_info() {
    local _l _e
    _l=$(jq -r 'select(.type == "system" and .subtype == "compact_boundary")
                | ((.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdate | tostring)
                   + " " + (.compactMetadata.trigger // "manual"))' \
        "$1" 2>/dev/null | tail -n 1)
    _e=${_l%% *}
    case "${_e:-}" in ''|*[!0-9]*) _l="0 -" ;; esac
    printf '%s' "$_l"
}

# How many lines the reader had to skip. Callers that report a "none" result
# use this to say "none, and N lines were unreadable" rather than a bare none.
_log_corrupt_count() {
    local total valid
    [ -f "$LOGFILE" ] || { echo 0; return; }
    total=$(wc -l < "$LOGFILE")
    valid=$(_log_json | wc -l)
    echo $(( total - valid ))
}

mode_cold() {
    local raw=$1 since=$2 session_filter=${3:-} include_cost=${4:-false}
    local _all_json=false
    [ "$include_cost" = "true" ] && _all_json=true
    # Scope: an explicit --session wins; otherwise, with no time filter, the
    # current session; a time filter alone means "all sessions since then".
    local scope_sid=""
    if [ -n "$session_filter" ]; then scope_sid="$session_filter"
    elif [ "$since" -eq 0 ]; then scope_sid="$(_current_session_id)"; fi

    # Retract-aware: a k:"hit-retract" record (keyed s + hit_t, appended when
    # the late-bind read finds previous_message_not_found after the hit was
    # already booked from a raced "other") cancels its matching k:"hit" —
    # the append-only ledger self-corrects, so readers must honor it.
    # Cause-aware, same principle: a k:"hit-cause" record (also keyed
    # s + hit_t) carries the cause the late-bind read recovered after the hit
    # was booked "other", and overrides it here. Without this the display and
    # the ledger disagreed about the same event — the screen showing the real
    # cause, the record keeping the degraded default that every later analysis
    # reads. Last marker wins, so a repeated append is harmless.
    # --all additionally lists controlled-cost events (k:"cost", plus legacy
    # k:"resume" records) — the full cost picture; default stays busts-only.
    local rows
    rows=$(_log_json | jq -src --argjson since "$since" --arg sid "$scope_sid" --argjson all "$_all_json" '
        ([.[] | select((.type // "") == "cold" and .k == "hit-retract") | "\(.s)#\(.hit_t)"]) as $rt
        | (reduce (.[] | select((.type // "") == "cold" and .k == "hit-cause"))
             as $c ({}; .["\($c.s)#\($c.hit_t)"] = $c.cause)) as $cu
        | .[]
        | select((.type // "") == "cold"
                 and (.k == "hit" or ($all and (.k == "cost" or .k == "resume"))))
        | select("\(.s)#\(.t)" as $key | ($rt | index($key)) | not)
        | select($since == 0 or .t >= $since)
        | select($sid == "" or .s == $sid)
        | [.t, (.cc // .ctx // 0), ($cu["\(.s)#\(.t)"] // .cause // "-"), (.gap // 0), (.mdl // "-"), (.s[0:8])]
        | @tsv' 2>/dev/null | sort -n) || rows=""

    if [ -z "$rows" ]; then
        # "none" must be distinguishable from "could not read". A silent empty
        # result is what hid 26 real records on 2026-07-28.
        #
        # --debug, not --info: there is no --info arm, so that hint fell through
        # the argument loop's `*) ;;` and ran the default session mode — a no-op
        # aimed at a user who has just been told their log is unreadable.
        # --debug prints the count of corrupt lines and chains on to --repair,
        # which is the right order: --repair rewrites the log, and nobody should
        # be sent to a mutation before they have seen what is wrong.
        # tests/printed-flags-are-handled.sh keeps the class shut.
        local _corrupt; _corrupt=$(_log_corrupt_count)
        local _note=""
        [ "${_corrupt:-0}" -gt 0 ] && _note=" (${_corrupt} unreadable line(s) skipped — run: claude-worktime --debug)"
        if $raw; then echo '[]'
        elif [ -n "$scope_sid" ]; then echo "No cold rewrites recorded for this session${_note}"
        else echo "No cold rewrites recorded${_note}"; fi
        return
    fi

    if $raw; then
        # Emit a JSON array of the filtered events straight from the log
        # Same tolerant read as the table branch — a --raw consumer must not
        # get [] because of one malformed line elsewhere in the file.
        _log_json | jq -sc --argjson since "$since" --arg sid "$scope_sid" --argjson all "$_all_json" '
            ([.[] | select((.type // "") == "cold" and .k == "hit-retract") | "\(.s)#\(.hit_t)"]) as $rt
            | (reduce (.[] | select((.type // "") == "cold" and .k == "hit-cause"))
                 as $c ({}; .["\($c.s)#\($c.hit_t)"] = {cause: $c.cause, mtok: $c.mtok})) as $cu
            | map(select((.type // "") == "cold"
                         and (.k == "hit" or ($all and (.k == "cost" or .k == "resume"))))
                | select("\(.s)#\(.t)" as $key | ($rt | index($key)) | not)
                | select($since == 0 or .t >= $since)
                | select($sid == "" or .s == $sid)
                | ("\(.s)#\(.t)") as $key
                | if $cu[$key] then .cause = $cu[$key].cause | .mtok = ($cu[$key].mtok // .mtok) else . end)
            | sort_by(.t)' 2>/dev/null
        return
    fi

    # cause is idle|model (worktime's own pre-classification) or, for the
    # residual, the API's cache_miss_reason.type verbatim (messages_changed /
    # tools_changed / system_changed / unavailable / other when no diagnostics
    # were available) — widened to 17 to fit "messages_changed" unquoted.
    # UTC on purpose: every downstream forensic source (snapshot ledgers,
    # transcripts, journalctl --utc per the runbook) timestamps in UTC, and
    # a local-time column here forces an error-prone conversion at exactly
    # the moment someone is hunting a bust (2026-07-28: a "00:13 local"
    # bust was hunted in the 22:13Z ledger rows).
    printf '%-19s %8s  %-17s %8s  %s\n' "when (UTC)" "size" "cause" "idle" "model"
    local t cc cause gap mdl s total=0 sum=0
    while IFS=$'\t' read -r t cc cause gap mdl s; do
        [ -z "$t" ] && continue
        local when; when=$(date -u -d "@$t" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -u -r "$t" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
        local k=$(( (cc + 500) / 1000 ))
        # Idle gap as compact duration
        local gtxt
        if [ "$gap" -lt 60 ]; then gtxt="${gap}s"
        elif [ "$gap" -lt 3600 ]; then gtxt="$(( gap / 60 ))m"
        else gtxt="$(( gap / 3600 ))h$(( (gap % 3600) / 60 ))m"; fi
        # Trim the "claude-" prefix from the model id for width
        local mshort="${mdl#claude-}"
        printf '%-19s %7dk  %-17s %8s  %s\n' "$when" "$k" "$cause" "$gtxt" "$mshort"
        total=$(( total + 1 )); sum=$(( sum + k ))
    done <<< "$rows"
    printf '%-19s %7dk  (%d rewrite%s)\n' "total" "$sum" "$total" "$([ "$total" -eq 1 ] || echo s)"
}

mode_rotate() {
    [ ! -f "$LOGFILE" ] && { echo "No log file to rotate"; return; }
    _rotate_boundaries
    # Through _safe_log, identically to _do_rotate's copy of this guard. A plain
    # `jq FILTER "$LOGFILE"` parses the whole file as one stream and dies on the
    # first malformed line — and the log is append-only from concurrent hooks,
    # so a malformed line is expected, not exceptional.
    #
    # It was tolerant BY ACCIDENT: streaming jq emits every record it parsed
    # before dying, so a corrupt line in the MIDDLE still yields a first
    # timestamp. It failed only where the corrupt line PRECEDES every valid
    # event record — nothing is emitted, the read comes back empty, and the
    # guard below reads that as "the log holds no events" and prints "Nothing to
    # rotate" over a log full of rotatable entries. An unreadable log rendered
    # as an empty one: the could-not-verify answer in a pass's clothes.
    local first_event_ts
    first_event_ts=$(_safe_log "$LOGFILE" | jq -r 'select((.type // null) == null) | .t' 2>/dev/null | head -1 || true)
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
    08:22 ▪▪··▪▪ 17:30  day timeline (▪=present ·=away) between today's
                   first event and the {today_now} render stamp
    17:30          clock time at the last statusline render — the staleness
                   anchor. The statusline only re-renders on activity, so an
                   idle CLI freezes every duration on the line; how far this
                   lags your actual clock is how old the rest of it is.
                   Ships inside TIMELINE; give it GROUP_NOW="{today_now}"
                   to place it elsewhere (e.g. line 3, beside ❄ and ctx)
    ▶1h12m         presence streak since last break (yellow >1.5h, red >2.5h)
    ⏸ 20m          last break duration (after first break)
    45m            current session active time

  Rate limits (from Claude Code)
    ⧗50%           5h rate limit usage (⧗ = short/hourly window)
    ↻3h21m         time until 5h window resets
    →51%           projected 5h usage at reset (yellow ≥90%, red ≥100%)
    ➐5%            7-day rate limit usage
    ↻Sat           7-day reset weekday
    →12%           projected 7d usage at reset (→… while insufficient data)

  Context (from Claude Code)
    ctx 77%        context window fullness (auto-compacts at ~95%)
    ❄ 397k other (2m) size, cause and (age) of the most recent cold rewrite
                   this session (the {cold} token, hidden until the first):
                   that many tokens were re-written at the cache-write premium.
                   cause = idle (cache TTL passed), model (model switch), or
                   other (same model, no idle; +:msg / :hook when a cross-session
                   message or Stop-hook summary co-occurred). Cyan when recent,
                   grey once older than COLD_FRESH_SECS

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
    high              reasoning effort level (low/medium/high/xhigh/max).
                      Reflects live session value, including /effort changes.
                      Hidden when the active model doesn't support effort.

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
COLD_ALL=false

while [ $# -gt 0 ]; do
    case "$1" in
        --raw) RAW=true ;;
        --all) COLD_ALL=true ;;
        --summary) MODE="summary" ;;
        --breakdown) MODE="breakdown" ;;
        --gaps) MODE="gaps" ;;
        --cost) MODE="cost" ;;
        --cold) MODE="cold" ;;
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
    cold)       mode_cold "$RAW" "$SINCE_TS" "$FILTER_SESSION" "$COLD_ALL" ;;
    summary)    mode_summary "$RAW" "$SINCE_TS" "$FILTER_PATH" "$FILTER_BRANCH" "$FILTER_SESSION" ;;
    csv)        mode_csv "$SINCE_TS" "$FILTER_PATH" "$FILTER_BRANCH" "$FILTER_SESSION" ;;
    statusline) mode_statusline ;;
    rotate)     mode_rotate ;;
esac
