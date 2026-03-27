# claude-worktime configuration
# Copy to ~/.claude/worktime/config.sh and customize
#
# Format tokens for statusline:
#   {session}        — active time in current session (by session ID)
#   {session_wall}   — wall clock time since session started
#   {today}          — today's total active time (all sessions, all projects)
#   {today_project}  — today's total for current project only
#   {project}        — project name (last 2 path segments)
#   {branch}         — git branch name
#   {break}          — pomodoro status indicator (display only)
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
STATUSLINE_FORMAT="⏱ session {session} · today {today} · {project}"
STATUSLINE_IDLE_FORMAT="⏸ idle {idle} · session {session} · today {today} · {project}"

# ---------------------------------------------------------------------------
# Pomodoro / break reminders (display only — does NOT affect time tracking)
# ---------------------------------------------------------------------------
# The pomodoro timer is purely a visual reminder in the statusline.
# It counts active work time and nudges you to take breaks.
# It does NOT deduct break time from active time — if you ignore the
# reminder and keep working, your full time is still counted.
POMODORO_ENABLED=false
# POMODORO_WORK=1500         # 25 min — remind to take a break after this
# POMODORO_SHORT_BREAK=300   # 5 min — short break target
# POMODORO_LONG_BREAK=900    # 15 min — long break target
# POMODORO_LONG_EVERY=4      # long break every N work intervals

# ---------------------------------------------------------------------------
# Colors (ANSI escape codes)
# ---------------------------------------------------------------------------
COLOR_NORMAL="\033[32m"       # green — working normally
COLOR_BREAK_DUE="\033[31m"    # red — break overdue
COLOR_ON_BREAK="\033[33m"     # yellow — on break
COLOR_IDLE="\033[90m"         # gray — idle
COLOR_RESET="\033[0m"

# ============================= EXAMPLES ====================================
#
# --- Minimal: just session time, no color ---
# STATUSLINE_FORMAT="{session}"
# STATUSLINE_IDLE_FORMAT="idle {idle}"
# COLOR_NORMAL=""
# COLOR_IDLE=""
# COLOR_RESET=""
#
# --- Project-focused: show project time, branch ---
# STATUSLINE_FORMAT="{today_project} · {project} ({branch})"
# STATUSLINE_IDLE_FORMAT="idle {idle} · {today_project} · {project} ({branch})"
#
# --- Full pomodoro with all the details ---
# POMODORO_ENABLED=true
# POMODORO_WORK=1500
# POMODORO_SHORT_BREAK=300
# POMODORO_LONG_BREAK=900
# POMODORO_LONG_EVERY=4
# STATUSLINE_FORMAT="{break} {session} ({today}) · {project}"
# STATUSLINE_IDLE_FORMAT="{break} idle {idle} · {session} ({today}) · {project}"
#
# --- Short pomodoro (15min work / 3min break) ---
# POMODORO_ENABLED=true
# POMODORO_WORK=900
# POMODORO_SHORT_BREAK=180
# POMODORO_LONG_BREAK=600
# POMODORO_LONG_EVERY=4
#
# --- No idle display, just session + today ---
# STATUSLINE_FORMAT="{session} ({today})"
# STATUSLINE_IDLE_FORMAT="{session} ({today})"
#
# --- Branch-aware for multi-branch workflows ---
# STATUSLINE_FORMAT="{session} · {project}/{branch} ({today})"
# STATUSLINE_IDLE_FORMAT="idle · {project}/{branch} ({today})"
#
# ===========================================================================
