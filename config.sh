# claude-worktime configuration
# Copy to ~/.claude/worktime/config.sh and customize
#
# Format tokens for statusline:
#
#   Time tokens (computed from activity log):
#   {status}         — ⏱ when working, ⏸ when idle
#   {session}        — active time in current session (by session ID)
#   {session_wall}   — wall clock time since session started
#   {today}          — today's total active time (all sessions, all projects)
#   {today_project}  — today's total for current project only
#   {project_total}  — all-time total for current project (across all days)
#   {idle}           — idle duration (only meaningful when idle)
#
#   Project tokens:
#   {project}        — project name (last 2 path segments)
#   {branch}         — git branch name
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
STATUSLINE_FORMAT="{status} session {session} · today {today} · {project}"
STATUSLINE_IDLE_FORMAT="{status} idle {idle} · session {session} · today {today} · {project}"

# ---------------------------------------------------------------------------
# Colors (ANSI escape codes, set to "" to disable)
# ---------------------------------------------------------------------------
COLOR_NORMAL="\033[32m"       # green — working
COLOR_IDLE="\033[90m"         # gray — idle
COLOR_RESET="\033[0m"

# ============================= EXAMPLES ====================================
#
# --- Project today + all-time total ---
# STATUSLINE_FORMAT="{status}  today {today_project} · total {project_total} · {project}"
# STATUSLINE_IDLE_FORMAT="{status}  idle {idle} · today {today_project} · total {project_total} · {project}"
# Result: ⏱  today 45m · total 12h30m · my-org/my-project
#
# --- With rate limit and context usage ---
# STATUSLINE_FORMAT="{status}  today {today_project} · {rate_5h} used · ctx {context} · {project}"
# STATUSLINE_IDLE_FORMAT="{status}  idle {idle} · today {today_project} · {rate_5h} used · {project}"
# Result: ⏱  today 45m · 23% used · ctx 12% · my-org/my-project
#
# --- With session cost ---
# STATUSLINE_FORMAT="{status} {session} · {cost} · {project}"
# STATUSLINE_IDLE_FORMAT="{status} idle · {cost} · {project}"
# Result: ⏱ 45m · $1.23 · my-org/my-project
#
# --- Compact with rate limit ---
# STATUSLINE_FORMAT="{status} {session} ({today}) · {rate_5h} · {project}"
# STATUSLINE_IDLE_FORMAT="{status} idle {idle} · {rate_5h} · {project}"
# Result: ⏱ 45m (2h10m) · 23% · my-org/my-project
#
# --- Branch-aware ---
# STATUSLINE_FORMAT="{status} {session} · {project} ({branch}) · today {today}"
# STATUSLINE_IDLE_FORMAT="{status} idle · {project} ({branch}) · today {today}"
# Result: ⏱ 45m · my-org/my-project (feature-auth) · today 2h10m
#
# ===========================================================================
