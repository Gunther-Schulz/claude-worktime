# claude-worktime configuration
# Copy to ~/.claude/worktime/config.sh and customize
#
# Format tokens for statusline:
#
#   Time tokens (computed from activity log):
#   {status}      — ⏱ icon
#   {session}        — active time in current session (by session ID)
#   {session_wall}   — wall clock time since session started
#   {today}          — today's total active time (all sessions, all projects)
#   {today_project}  — today's total for current project only
#   {project_total}  — all-time total for current project (across all days)
#   {last_break}     — last break duration with ⏸ icon (empty if none)
#   {since_break}    — work time since last break with ▶ icon (empty if none)
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
#   {model}          — model display name (e.g. "Opus 4.6")

# ---------------------------------------------------------------------------
# Idle detection
# ---------------------------------------------------------------------------
# A gap is idle ONLY when: Claude finished responding (response event) and the
# user hasn't sent the next prompt within this threshold. All other gaps
# (tool execution, Claude thinking) are always counted as active work.
PAUSE_THRESHOLD=900  # 15 minutes

# ---------------------------------------------------------------------------
# Statusline format
# ---------------------------------------------------------------------------
# Up to 3 lines supported. Leave _2 and _3 empty for single-line display.
STATUSLINE_FORMAT="{status}session {session} · today {today} · {project}"
STATUSLINE_FORMAT_2=""
STATUSLINE_FORMAT_3=""

# ---------------------------------------------------------------------------
# Colors (ANSI escape codes, set to "" to disable)
# ---------------------------------------------------------------------------
COLOR_NORMAL="\033[32m"           # green — working
COLOR_IDLE="\033[90m"             # gray — idle
COLOR_RATE_WARNING="\033[33m"     # yellow — projected rate limit ≥90%
COLOR_RATE_CRITICAL="\033[31m"    # red — projected rate limit ≥100%
COLOR_RESET="\033[0m"

# ---------------------------------------------------------------------------
# Auto-rotation — archive old log entries on session start
# ---------------------------------------------------------------------------
AUTO_ROTATE=true
ROTATE_INTERVAL=monthly    # monthly, weekly, daily

# ---------------------------------------------------------------------------
# Projections
# ---------------------------------------------------------------------------
# Minimum days elapsed before showing 7d rate limit projection.
# Below this threshold, the projection is hidden (not enough data).
RATE_7D_PROJ_MIN_DAYS=0.5  # 12 hours

# ---------------------------------------------------------------------------
# Gap analysis (--gaps)
# ---------------------------------------------------------------------------
# Bucket boundaries in seconds for response→prompt gap distribution.
# Helps you tune PAUSE_THRESHOLD by seeing where your gaps cluster.
GAP_BUCKETS="60,300,600,900,1800"  # 1m, 5m, 10m, 15m, 30m

# ---------------------------------------------------------------------------
# Cost tracking
# ---------------------------------------------------------------------------
# Log API-equivalent session cost on each statusline update.
# Shows what your session would cost at API rates ($15/$75 per MTok for Opus).
# On subscription plans (Pro/Max), this is informational — not your actual bill.
# Your real budget is the rate limit windows ({rate_5h}, {rate_7d}).
LOG_COST=false

# ============================= EXAMPLES ====================================
#
# --- Two-line: time + break info + git, rate limits below ---
# STATUSLINE_FORMAT="{status}  today {today_project} · total {project_total} · {project} ({git}) · {since_break} {last_break}"
# STATUSLINE_FORMAT_2="{rate_5h} ↻{rate_5h_reset} {rate_5h_proj} · {rate_7d} 7d ↻{rate_7d_day} {rate_7d_proj}"
# Result: ⏱  today 2h32m · total 12h30m · my-org/my-project (main ✓) · ▶1h12m ⏸ 20m
#         20% ↻3h21m →51% · 5% 7d ↻Sat →35%
#
# --- Session-based with break ---
# STATUSLINE_FORMAT="{status}  session {session} · today {today} · {since_break} {last_break} · {project}"
# STATUSLINE_FORMAT_2="{cost} · {rate_5h} {rate_5h_proj} · {rate_7d} 7d"
# Result: ⏱  session 45m · today 2h10m · ▶25m ⏸ 20m · my-org/my-project
#         $1.23 · 20% →51% · 5% 7d
#
# --- Single-line compact ---
# STATUSLINE_FORMAT="{status}  {session} ({today}) · {rate_5h} · {project}"
# Result: ⏱  45m (2h10m) · 20% · my-org/my-project
#
# --- Three-line: everything separated ---
# STATUSLINE_FORMAT="{status}  today {today_project} · total {project_total} · {project} ({git}) · {since_break} {last_break}"
# STATUSLINE_FORMAT_2="{rate_5h} ↻{rate_5h_reset} {rate_5h_proj} · {rate_7d} 7d ↻{rate_7d_day} {rate_7d_proj}"
# STATUSLINE_FORMAT_3="{model} · ctx {context} · {cost}"
# Result: ⏱  today 2h32m · total 12h30m · my-org/my-project (main ✓) · ▶1h12m ⏸ 20m
#         20% ↻3h21m →51% · 5% 7d ↻Sat →35%
#         Opus 4.6 · ctx 12% · $1.23
#
# ===========================================================================
