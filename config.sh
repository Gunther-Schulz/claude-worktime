# claude-worktime configuration
# Uncomment and modify only the settings you want to change.
# All values shown are the built-in defaults from the script.
#
# Format tokens for statusline:
#
#   Time tokens (computed from activity log):
#   {status}      — ⏱ icon
#   {session}        — active time in current session (by session ID)
#   {session_wall}   — wall clock time since session started
#   {today}          — today's total active time (all sessions, all projects)
#   {today_project}  — today's total for current project (Claude + You)
#   {today_claude}   — today's Claude work time for current project
#   {today_you}      — today's your active time for current project
#   {project_total}  — all-time total for current project (across all days)
#   {total_claude}   — all-time Claude work time for current project
#   {total_you}      — all-time your active time for current project
#   {last_break}     — last break duration with ⏸ icon (empty if none)
#   {since_break}    — presence time since last break with ▶ icon
#   {timeline}       — ▮▮··▮▮▮ day timeline (▮=present, ·=away)
#
#   Project tokens:
#   {project}        — project name (last 2 path segments)
#   {branch}         — git branch name
#   {git}            — branch + state: "main ✓" clean, "main ✗" dirty,
#                      "main +" staged, "main ?" untracked, "main ↑2" ahead,
#                      "main ↓1" behind (combines: "main +✗↑2")
#
#   Claude Code tokens (from statusline stdin JSON):
#   {rate_5h}        — 5-hour rate limit usage (e.g. "23%")
#   {rate_7d}        — 7-day rate limit usage (e.g. "5%")
#   {context}        — context window usage (e.g. "45%")
#   {cost}           — session cost (e.g. "$1.23")
#   {cost_budget}    — actual cost / inferred 5h budget (e.g. "$19.65/≈$40")
#   {model}          — model name + source (e.g. "Opus 4.6 (local)")

# ---------------------------------------------------------------------------
# Idle detection
# ---------------------------------------------------------------------------
# A gap is idle ONLY when: Claude finished responding (response event) and the
# user hasn't sent the next prompt within this threshold. All other gaps
# (tool execution, Claude thinking) are always counted as active work.
#PAUSE_THRESHOLD=900  # 15 minutes
#CLAUDE_CREDIT=0      # 0 = auto (PAUSE_THRESHOLD / 3, ~5min at default)
                      # How long to assume you'd watch Claude work before
                      # stepping away. Beyond this, time counts toward absence.

# ---------------------------------------------------------------------------
# Statusline format — group-based
# ---------------------------------------------------------------------------
# Define named groups, then compose lines by listing group names.
# Divider (GROUP_DIVIDER) is inserted automatically between non-empty groups.
# Empty groups (all tokens unavailable) are hidden automatically.

#GROUP_PROJECT="{project} ({git})"
#GROUP_TODAY="{status} today {today_project} 🤖{today_claude} 👤{today_you}"
#GROUP_TOTAL="total {project_total}"
#GROUP_TIMELINE="{today_start} {timeline} {today_now}"
#GROUP_BREAKS="{since_break} {last_break}"
#GROUP_RATE_5H="{rate_5h} ↻{rate_5h_reset} {rate_5h_proj}"
#GROUP_RATE_7D="⑦{rate_7d} ↻{rate_7d_day} {rate_7d_proj}"
#GROUP_CONTEXT="ctx {context}"
#GROUP_MODEL="{model}"
# GROUP_TOKENS removed — weighted tokens missed subagent costs; use {cost_budget} instead

#STATUSLINE_1="PROJECT TODAY TOTAL"
#STATUSLINE_2="TIMELINE BREAKS"
#STATUSLINE_3="MODEL RATE_5H RATE_7D CONTEXT"
#GROUP_DIVIDER=" · "

# Per-group colors (optional, falls back to COLOR_NORMAL)
# Mute secondary info for visual hierarchy
#GROUP_RATE_7D_COLOR="dark-gray"
#GROUP_CONTEXT_COLOR="dark-gray"
#GROUP_BUDGET_COLOR="dark-gray"

# ---------------------------------------------------------------------------
# Colors — use preset names or raw ANSI codes
# ---------------------------------------------------------------------------
# Presets: black, red, green, yellow, blue, magenta, cyan, white, gray,
#          dark-gray, light-gray, orange, pink, purple, bright-green,
#          bright-red, bright-yellow, bright-blue, bright-white, dim, none
# Raw:     "\033[32m", "\033[38;5;208m", etc.
#COLOR_NORMAL="green"
#COLOR_RATE_WARNING="yellow"
#COLOR_RATE_CRITICAL="red"
#COLOR_TIMELINE_WORK="green"
#COLOR_TIMELINE_BREAK="green"
#COLOR_DEFAULT="dark-gray"

# ---------------------------------------------------------------------------
# Break reminder — work streak color warning
# ---------------------------------------------------------------------------
# The ▶ work streak indicator changes color when you've been working
# too long without a break (response→prompt gap > PAUSE_THRESHOLD).
#STREAK_WARNING=5400    # 1.5h — turns yellow
#STREAK_CRITICAL=9000   # 2.5h — turns red

# Example: green work blocks, orange break blocks
#COLOR_TIMELINE_WORK="green"
#COLOR_TIMELINE_BREAK="green"

# ---------------------------------------------------------------------------
# Auto-rotation — archive old log entries on session start
# ---------------------------------------------------------------------------
#AUTO_ROTATE=true
#ROTATE_INTERVAL=daily    # daily, weekly, monthly

# ---------------------------------------------------------------------------
# Projections
# ---------------------------------------------------------------------------
# Minimum days elapsed before showing 7d rate limit projection.
# Below this threshold, the projection is hidden (not enough data).
#RATE_7D_PROJ_MIN_DAYS=1  # 1 day (needs a full work/sleep cycle)

# ---------------------------------------------------------------------------
# Gap analysis (--gaps)
# ---------------------------------------------------------------------------
# Bucket boundaries in seconds for response→prompt gap distribution.
# Helps you tune PAUSE_THRESHOLD by seeing where your gaps cluster.
#GAP_BUCKETS="60,300,600,900,1800"  # 1m, 5m, 10m, 15m, 30m
#TIMELINE_SLOT=1200  # seconds per timeline block (1200=20min, 1800=30min, 3600=1h)

# ============================= EXAMPLES ====================================
#
# --- Reorder groups (just move names around) ---
# STATUSLINE_2="TIMELINE BREAKS CONTEXT RATE_5H RATE_7D"
#
# --- Add cost budget to line 3 (stabilises after ~65% window usage) ---
# GROUP_BUDGET="{cost_budget}"
# STATUSLINE_3="MODEL RATE_5H BUDGET RATE_7D CONTEXT"
#
# --- Single-line compact ---
# GROUP_COMPACT="{project} · {status} {session} ({today}) · {rate_5h}"
# STATUSLINE_1="COMPACT"
# STATUSLINE_2=""
#
# --- Show Claude/You split ---
# GROUP_TODAY="{status} today {today_project} 🤖{today_claude} 👤{today_you}"
# GROUP_TOTAL="total {project_total} 🤖{total_claude} 👤{total_you}"
#
# --- Custom group with session wall time ---
# GROUP_WALL="{session}/{session_wall}"
# STATUSLINE_1="PROJECT TODAY TOTAL WALL"
#
# ===========================================================================
