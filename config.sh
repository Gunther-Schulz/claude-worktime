# claude-worktime configuration
# Copy to ~/.claude/worktime/config.sh and customize
#
# Format tokens for statusline:
#   {status}         — ⏱ when working, ⏸ when idle
#   {session}        — active time in current session (by session ID)
#   {session_wall}   — wall clock time since session started
#   {today}          — today's total active time (all sessions, all projects)
#   {today_project}  — today's total for current project only
#   {project_total}  — all-time total for current project (across all days)
#   {project}        — project name (last 2 path segments)
#   {branch}         — git branch name
#   {idle}           — idle duration (only meaningful when idle)

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
# STATUSLINE_FORMAT="{status} · today {today_project} · total {project_total} · {project}"
# STATUSLINE_IDLE_FORMAT="{status} · idle {idle} · today {today_project} · total {project_total} · {project}"
# Result: ⏱ · today 45m · total 12h30m · my-org/my-project
#
# --- Compact, no labels ---
# STATUSLINE_FORMAT="{status} {session} ({today}) · {project}"
# STATUSLINE_IDLE_FORMAT="{status} idle {idle} · {session} ({today}) · {project}"
# Result: ⏱ 45m (2h10m) · my-org/my-project
#
# --- Branch-aware ---
# STATUSLINE_FORMAT="{status} {session} · {project} ({branch}) · today {today}"
# STATUSLINE_IDLE_FORMAT="{status} idle · {project} ({branch}) · today {today}"
# Result: ⏱ 45m · my-org/my-project (feature-auth) · today 2h10m
#
# --- Wall clock: active vs elapsed ---
# STATUSLINE_FORMAT="{status} active {session} · wall {session_wall} · {project}"
# STATUSLINE_IDLE_FORMAT="{status} idle {idle} · active {session} · wall {session_wall} · {project}"
# Result: ⏱ active 45m · wall 1h23m · my-org/my-project
#
# ===========================================================================
