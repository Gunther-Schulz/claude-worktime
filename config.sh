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
#   {timeline}       — ▪▪··▪▪▪ day timeline (▪=present, ·=away)
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
#   {rate_7d_scoped}      — model-scoped weekly limit usage (e.g. Fable on
#                           Max plans: "36%"); fetched from the usage API
#                           in the background (see USAGE_FETCH_INTERVAL)
#   {rate_7d_scoped_name} — name of the scoped model (e.g. "Fable")
#   {rate_7d_scoped_proj} — projected scoped usage at week's end
#   {context}        — context window usage (e.g. "45%")
#   {cold}           — last cold-cache rewrite as ❄397k other (2m): size, cause,
#                      (age); own group GROUP_COLD, empty until the first rewrite
#   {cost}           — session cost (e.g. "$1.23")
#   {cost_budget}    — actual cost / inferred 5h budget (e.g. "$19.65/≈$40")
#   {model}          — model name + source (e.g. "Opus 4.6 (local)")
#   {effort}         — reasoning effort level: low / medium / high / xhigh / max
#                      (hidden when active model doesn't support effort)

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
# Project label ({project})
# ---------------------------------------------------------------------------
#HOME_ORG=""              # drop a leading "org/" from {project} (e.g. your code-host
                          # user dir, where it's redundant); empty = keep full label
#PROJECT_GIT_ANCHOR=false # anchor {project} to the git repo root, so subdirs and
                          # worktrees show the repo name instead of the cwd's folder

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
#GROUP_RATE_SCOPED="{rate_7d_scoped_name} {rate_7d_scoped} {rate_7d_scoped_proj}"
#GROUP_CONTEXT="ctx {context}"
#GROUP_COLD="{cold}"
#GROUP_MODEL="{model}"
#GROUP_EFFORT="{effort}"
# GROUP_TOKENS removed — weighted tokens missed subagent costs; use {cost_budget} instead

#STATUSLINE_1="PROJECT TODAY TOTAL"
#STATUSLINE_2="TIMELINE BREAKS"
#STATUSLINE_3="MODEL RATE_5H RATE_7D RATE_SCOPED CONTEXT COLD"
#GROUP_DIVIDER=" · "

# Per-group colors (optional, falls back to COLOR_NORMAL)
# Mute secondary info for visual hierarchy
#GROUP_RATE_7D_COLOR="dark-gray"
#GROUP_RATE_SCOPED_COLOR="dark-gray"
#GROUP_CONTEXT_COLOR="dark-gray"
#GROUP_BUDGET_COLOR="dark-gray"
#GROUP_COLD_COLOR="none"    # ❄ self-colours (cyan fresh / gray stale); "none"
                            # keeps the group wrapper from repainting it

# ---------------------------------------------------------------------------
# Cold-cache counter (❄) & prompt-submit guard
# ---------------------------------------------------------------------------
# After an idle gap longer than the prompt-cache TTL (~1h on the main thread),
# the next request silently re-writes the whole conversation prefix at the
# cache-write premium. Two independent features:
#   ❄397k other (2m) — ALWAYS ON. The {cold} token shows the last rewrite:
#                size, cause, (age) — idle = cache TTL passed, model = model
#                switch, other = same model/no idle; cyan when recent, gray once
#                old. The "other" residual gains a :msg / :hook suffix when a
#                cross-session message or our Stop-hook summary co-occurred in
#                the transcript at the rewrite — a co-occurrence flag for later
#                analysis, not a proven cause. Passive display only — never
#                blocks. Tuned by COLD_MIN_CTX below.
#   cold guard — OFF by default (CACHE_GUARD_TTL=0). When enabled, the
#                UserPromptSubmit hook blocks the FIRST prompt after such a gap,
#                once, so you can /compact or /clear at the only moment it's
#                cheap; submitting the prompt a second time proceeds normally
#                (the blocked text is echoed back under the warning).
# The TTL is hardcoded in the Claude Code CLI (no API to query it) — basis
# and re-verification commands: docs/cache-ttl-verification.md.
#CACHE_GUARD_TTL=3600       # cold-guard warning: 0 = off (the default). Set to
                            # the cache TTL in seconds to enable — it then warns
                            # at 0.9× that, the point the CLI treats it as cold.
                            # (The ❄ display stays on regardless of this.)
#CACHE_GUARD_MIN_CTX=50000  # don't warn below this context size (tokens)
# The ❄ marker skips a session's first write structurally (no prior turn to
# re-write), so it never mistakes session-start for a cold rewrite while still
# catching a resume after the cache expired. COLD_MIN_CTX is only an optional
# cosmetic floor on top: raise it to hide small rewrites (0 = show all).
#COLD_MIN_CTX=0             # hide rewrites whose prior context was below this
#COLD_FRESH_SECS=900        # ❄ shows cyan this long after a rewrite, then greys

# ---------------------------------------------------------------------------
# Model-scoped weekly limit (e.g. Fable on Max plans)
# ---------------------------------------------------------------------------
# Claude Code's statusline stdin only carries the all-models 5h/7d buckets.
# The per-model weekly bucket shown at claude.ai (e.g. "Fable — 36% used")
# is fetched from api.anthropic.com/api/oauth/usage using the OAuth token
# Claude Code already stores, cached on disk, and refreshed in the
# background — the statusline never waits on the network.
#USAGE_FETCH_INTERVAL=60   # seconds between fetches; 0 disables the fetch
                           # (and the {rate_7d_scoped*} tokens stay empty)
#USAGE_STALE_MAX=900       # max age of a cached figure that may still be
                           # displayed; past it the percentage renders "?%"
                           # so a fetch that keeps failing never leaves a
                           # stale number on screen looking current

# ---------------------------------------------------------------------------
# Per-model colors for {model}
# ---------------------------------------------------------------------------
# Comma-separated "substring=color" pairs, matched case-insensitively
# against the model id and display name. First match wins; models that
# match nothing keep the group color. Any preset or raw ANSI color works.
#MODEL_COLORS="fable=pink,opus=cyan"
# All families pinned:
#MODEL_COLORS="fable=pink,opus=purple,sonnet=cyan,haiku=blue"

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
# Below this threshold, →… is shown instead of a projected value.
#RATE_7D_PROJ_MIN_DAYS=1  # 1 day (needs a full work/sleep cycle)

# ---------------------------------------------------------------------------
# Gap analysis (--gaps)
# ---------------------------------------------------------------------------
# Bucket boundaries in seconds for response→prompt gap distribution.
# Helps you tune PAUSE_THRESHOLD by seeing where your gaps cluster.
#GAP_BUCKETS="60,300,600,900,1800"  # 1m, 5m, 10m, 15m, 30m
#TIMELINE_SLOT=1200  # seconds per timeline block (1200=20min, 1800=30min, 3600=1h)
# Timeline glyphs — single characters, must differ. Stick to non-ASCII block
# glyphs: the colorizer substitutes them into an already-escaped string, so an
# ASCII glyph could match inside an ANSI sequence. How heavy the bar reads is
# font-dependent — ▪ is a small square, ■ a full one, ▮ a narrow vertical bar.
#TIMELINE_CHAR_WORK="▪"   # alternatives: ■ █ ▮ ▬
#TIMELINE_CHAR_AWAY="·"   # alternatives: □ ▫ ░ ▯ ‧

# ============================= EXAMPLES ====================================
#
# --- Reorder groups (just move names around) ---
# STATUSLINE_2="TIMELINE BREAKS CONTEXT RATE_5H RATE_7D"
#
# --- Add cost budget to line 3 (stabilises after ~65% window usage) ---
# GROUP_BUDGET="{cost_budget}"
# STATUSLINE_3="MODEL RATE_5H BUDGET RATE_7D CONTEXT"
#
# --- Show reasoning effort next to the model ---
# STATUSLINE_3="MODEL EFFORT RATE_5H RATE_7D CONTEXT"
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
