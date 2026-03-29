# claude-worktime

Track active working time in [Claude Code](https://claude.com/claude-code) sessions.

```
my-org/my-project (main ✓) · ⏱  today 2h32m 🤖55m 👤1h37m · total 12h30m
▮▯▯▮▮▮▮▮▮▮▮▮▮▮▮▯▯▮▮▮ 8h30m · ▶1h12m ⏸ 20m · ◑30% ↻3h21m →51% · ⑦5% ↻Sat · ctx 77% ⟳93%
```

Time tracking with Claude/You split, presence-aware break detection, rate limit projections, git status, cost analysis — all in a configurable multi-line statusline.

## Install

```bash
git clone https://github.com/Gunther-Schulz/claude-worktime.git
cd claude-worktime
./install.sh --statusline
```

Or with curl:

```bash
curl -fsSL https://raw.githubusercontent.com/Gunther-Schulz/claude-worktime/main/install.sh | bash -s -- --statusline
```

Options:
- `--statusline` — enable the status bar display
- `--force` — overwrite existing hooks

The installer:
- Copies the script to `~/.local/bin/claude-worktime`
- Creates default config at `~/.config/claude-worktime/config.sh` (preserved on reinstall)
- Adds event hooks to `~/.claude/settings.json` (SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop, StopFailure)
- Adds a fenced section to `~/.claude/CLAUDE.md` so Claude knows about the tool (auto-updated on reinstall)
- Verifies dependencies

Then **restart Claude Code** to activate.

## Uninstall

```bash
./uninstall.sh
```

Removes hooks, statusline config, the script, and the CLAUDE.md section. Logs and config are preserved in the data directory.

## Statusline

Up to 3 configurable lines in Claude Code's status bar. Every element is a configurable token — mix and match to show what matters to you.

**Default (two lines — project-scoped + cross-session personal):**
```
my-org/my-project (main ✓) · ⏱  today 2h32m 🤖55m 👤1h37m · total 12h30m
▮▯▯▮▮▮▮▮▮▮▮▮▮▮▮▯▯▮▮▮ 8h30m · ▶1h12m ⏸ 20m · ◑30% ↻3h21m →51% · ⑦5% ↻Sat · ctx 77% ⟳93%
```
Line 1: project name, git status, work done split (total 🤖Claude 👤You)
Line 2: your presence — day timeline, break rhythm, rate limits (cross-session)

The timeline adapts its width to your day length, configurable via `TIMELINE_WIDTH` (default: 20 blocks).

**Compact single line:**
```
my-org/my-project · ⏱  45m (2h10m) · ◑20%
```

**Note:** The statusline refreshes after each assistant response and after each tool use, but not while you're typing or on a timer. During tool-heavy work it updates frequently; during long text responses it stays frozen until Claude finishes. The underlying time tracking is accurate regardless; only the display is event-driven.

**First-message warm-up:** Rate limits, context usage, cache ratio, and cost data come from Claude Code's stdin JSON, which is only available after the first API round-trip. On a fresh session start, the statusline shows time tracking and project info but omits these tokens until you submit your first message. This is expected — the data simply doesn't exist yet.

## Configuration

Config file: `~/.config/claude-worktime/config.sh` — plain bash, sourced at startup. All defaults are built into the script; the config file only needs to contain settings you want to override. Uncomment and modify what you need.

A commented-out template with all options is created on install.

### Format tokens

**Time tokens** (computed from activity log):

| Token | Description |
|-------|-------------|
| `{status}` | ⏱ icon |
| `{session}` | Active time in current session (by session ID) |
| `{session_wall}` | Wall clock time since session started |
| `{today}` | Today's total active time (all sessions, all projects) |
| `{today_wall}` | Wall clock span of today's timeline (first event to now) |
| `{today_project}` | Today's total for current project (Claude + You) |
| `{today_claude}` | Today's Claude work time for current project (prompt→response spans) |
| `{today_you}` | Today's your active time for current project (response→prompt within threshold) |
| `{project_total}` | All-time total for current project |
| `{total_claude}` | All-time Claude work time for current project |
| `{total_you}` | All-time your active time for current project |
| `{since_break}` | ▶2h40m — time you were present since most recent break (always visible) |
| `{last_break}` | ⏸ 41m — duration of most recent break (hidden until first break) |
| `{timeline}` | ▮▯▯▮▮▮▮▮▮▯▯▮▮▮ — day sparkline (▮=present ▯=away) |

`{today_project}` counts all productive time — both your turns and Claude's. `{today_claude}` and `{today_you}` split this into who was working. All three are scoped to the current project.

`{since_break}`, `{last_break}`, and `{timeline}` are **cross-session** and track your **presence** — they reflect when you were personally engaged. A long Claude turn exceeding `PAUSE_THRESHOLD` counts as a break (you were probably away). This means the streak/timeline may differ from active time when Claude runs long autonomous jobs.

`{since_break}` is always visible — it shows your current presence streak even before the first break. `{last_break}` appears only after the first break exceeding `PAUSE_THRESHOLD`. `{timeline}` auto-hides when no data is available.

**Project tokens:**

| Token | Description |
|-------|-------------|
| `{project}` | Project name (last 2 path segments) |
| `{branch}` | Git branch name |
| `{git}` | Branch + state: `main ✓` `main ✗` `main +` `main ?` `main ↑2` `main ↓1` |

**Claude Code tokens** (from statusline stdin JSON):

| Token | Description |
|-------|-------------|
| `{rate_5h}` | 5-hour rate limit with pie icon: `○5%` `◔25%` `◑50%` `◕75%` `●95%` |
| `{rate_5h_reset}` | Time until 5h window resets (e.g. `3h21m`) |
| `{rate_5h_proj}` | Projected 5h usage at reset (e.g. `→51%`) |
| `{rate_7d}` | 7-day rate limit usage (e.g. `5%`) |
| `{rate_7d_reset}` | Time until 7d window resets |
| `{rate_7d_day}` | Reset weekday (e.g. `Sat`) |
| `{rate_7d_proj}` | Projected 7d usage (daily average) |
| `{context}` | `77% ⟳93%` — context window usage + cache hit ratio from the most recent API response. **77%** = how full your context window is (Claude auto-compacts at ~95%). **⟳93%** = KV cache hit ratio — how much of the input was served from the server-side cache vs had to be processed from scratch. High (>95%) in steady conversation; drops during tool-heavy work (each new tool output is new content), after long breaks (the server-side cache expires after a period of inactivity), or at the start of a new conversation (nothing cached yet). Stateless — no accumulation, always reflects the current state. |
| `{cost}` | Session cost (e.g. `$1.23`) |
| `{model}` | Model name (e.g. `Opus 4.6`) |

Empty tokens are automatically removed along with their surrounding separators.

### Group-based layout (default)

Define named groups, then compose lines by listing group names. The divider (`GROUP_DIVIDER`, default ` · `) is inserted automatically between non-empty groups. Empty groups are hidden entirely.

```bash
# Groups
GROUP_PROJECT="{project} ({git})"
GROUP_TODAY="{status} today {today_project}"
GROUP_TOTAL="total {project_total}"
GROUP_TIMELINE="{timeline} {today_wall}"
GROUP_BREAKS="{since_break} {last_break}"
GROUP_RATE_5H="{rate_5h} ↻{rate_5h_reset} {rate_5h_proj}"
GROUP_RATE_7D="⑦{rate_7d} ↻{rate_7d_day} {rate_7d_proj}"
GROUP_CONTEXT="ctx {context}"

# Lines (space-separated group names)
STATUSLINE_1="PROJECT TODAY TOTAL"
STATUSLINE_2="TIMELINE BREAKS RATE_5H RATE_7D CONTEXT"
GROUP_DIVIDER=" · "
```

Reorder groups by moving names. Add `🤖{today_claude} 👤{today_you}` to `GROUP_TODAY` to show the Claude/You breakdown. Add a third line with `STATUSLINE_3="MODEL"` and `GROUP_MODEL="{model} · {cost}"`. Create custom groups with any mix of tokens.

**Per-group colors:** Set `GROUP_<NAME>_COLOR` to give a group its own color. Falls back to `COLOR_NORMAL`. Item-level colors (rate projections, timeline blocks) still apply and correctly restore to the group's color.

```bash
GROUP_RATE_7D_COLOR="dark-gray"    # muted 7d info
GROUP_CONTEXT_COLOR="dark-gray"    # muted context info
```

### Rate limit projections

The `{rate_5h_proj}` token projects your usage at window reset based on current burn rate. Projection color is configurable via `COLOR_RATE_WARNING` (default: yellow at ≥90%) and `COLOR_RATE_CRITICAL` (default: red at ≥100%). Set to `""` to disable.

The 7d tokens (`{rate_7d}`, `{rate_7d_day}`, `{rate_7d_proj}`) depend on Claude Code providing 7-day rate limit data. In practice, the entire 7d group may not appear until some time after the weekly window resets — all tokens auto-hide when data is unavailable. The 7d projection additionally requires `RATE_7D_PROJ_MIN_DAYS` (default: 0.5 days) of data before showing.

### Break reminder

The `{since_break}` work streak indicator (`▶2h15m`) changes color when you've been working too long without a break:

- **Yellow** at `STREAK_WARNING` (default: 1.5 hours) — time to think about a break
- **Red** at `STREAK_CRITICAL` (default: 2.5 hours) — you really should stop

A "break" is any period exceeding `PAUSE_THRESHOLD` (default: 15 minutes) where you weren't actively engaged — whether you were idle in the CLI (`response → prompt`), quit and came back (`response → start`), or Claude ran a long autonomous job (`prompt → response`). The warning clears automatically when you take a break. Set either threshold to `0` to disable.

```bash
STREAK_WARNING=5400    # 1.5h — yellow
STREAK_CRITICAL=9000   # 2.5h — red
```

### Auto-rotation

Old log entries are automatically archived on session start. Daily rotation is recommended — it keeps the active log small (faster jq queries) without affecting long-term stats. Shorter intervals are purely a performance choice, not a data retention trade-off.

```bash
AUTO_ROTATE=true
ROTATE_INTERVAL=daily    # daily, weekly, monthly
```

Archive filenames adapt to the interval:
- `daily` → `activity-2026-03-28.jsonl`
- `weekly` → `activity-2026-W13.jsonl`
- `monthly` → `activity-2026-03.jsonl`

When entries are rotated out, per-project summary records are written to the active log so `{project_total}` remains accurate across rotations. CLI queries (`--since`, `--summary`, `--csv`, etc.) automatically search archived logs for historical data.

Manual rotation: `claude-worktime --rotate`

### Colors

```bash
COLOR_NORMAL="green"              # working normally
COLOR_RATE_WARNING="yellow"       # projected rate ≥90%
COLOR_RATE_CRITICAL="red"         # projected rate ≥100%
COLOR_RESET="reset"               # reset to terminal default
```

Presets: `black`, `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`, `white`, `gray`, `dark-gray`, `light-gray`, `orange`, `pink`, `purple`, `bright-green`, `bright-red`, `bright-yellow`, `bright-blue`, `bright-white`, `dim`, `reset`, `none`. Raw ANSI codes (e.g. `"\033[38;5;208m"`) also work. Set to `""` or `"none"` to disable.

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_WORKTIME_CONFIG` | `~/.config/claude-worktime` | Config directory |
| `CLAUDE_WORKTIME_DATA` | `~/.local/share/claude-worktime` | Data directory (logs, archives) |
| `CLAUDE_WORKTIME_PAUSE` | `900` | Idle threshold in seconds (overrides config) |

Paths follow the [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir-spec/latest/). You can also set `DATADIR` in `config.sh` to override the data location.

## CLI queries

```bash
# Current session
claude-worktime

# Time ranges
claude-worktime --today
claude-worktime --week
claude-worktime --since 2026-03-25

# Filter by project path, git branch, or session ID
claude-worktime --today --filter Todenbuettel
claude-worktime --today --branch feature/auth
claude-worktime --session 3954c82f            # partial ID match

# Phase breakdown (Claude vs You, breaks, downtime)
claude-worktime --breakdown
claude-worktime --breakdown --today

# Gap analysis (tune your idle threshold)
claude-worktime --gaps
claude-worktime --gaps --today

# Per-project summary
claude-worktime --summary
claude-worktime --summary --today

# CSV export
claude-worktime --csv
claude-worktime --csv --today

# JSON output (works with any mode)
claude-worktime --raw
claude-worktime --breakdown --raw

# Cost analysis (needs LOG_COST=true)
claude-worktime --cost
claude-worktime --cost --today
claude-worktime --cost --filter Todenbuettel

# Log rotation
claude-worktime --rotate

# Statusline token legend
claude-worktime --tokens
```

All filters (`--today`, `--week`, `--since`, `--filter`, `--branch`, `--session`) can be combined with any mode.

### Phase breakdown

`--breakdown` shows how time splits between Claude, you, breaks, and downtime:

```
  Claude:     1h 39min     51%
  You:        1h 32min     48%
  Unattended: 45min        (1)
  ─────────────────────────
  Active:     3h 13min
  Breaks:     20min        (1)
  Downtime:   12h 15min
```

- **Claude** — Claude's turns within threshold (`prompt` → `response`)
- **You** — your turns within threshold (`response` → `prompt`)
- **Unattended** — long Claude turns exceeding threshold (you probably walked away)
- **Breaks** — idle gaps where you stayed in the CLI (`response` → `prompt` over threshold)
- **Downtime** — idle gaps where you quit the CLI (`response` → `start` over threshold)

Note: Unattended time is still counted in Active — the work happened, Claude was productive. It appears separately to show that you weren't present for that portion.

### Gap analysis

`--gaps` shows the distribution of your response→prompt pauses, separated by type:

```
Within sessions (threshold: 15min):

  ✓ < 1min        99   47min
  ✓ 1-5min        24   39min
  ⏸ 15-30min      1    20min

Between sessions (downtime):
  2 gaps  12h15min

  0 gaps within 2/3 of threshold
```

Use this to tune `PAUSE_THRESHOLD` — if many gaps cluster just under the threshold, they might be breaks that are being counted as active time. The bucket boundaries are configurable via `GAP_BUCKETS`.

### Cost analysis

`--cost` shows API-equivalent cost per project (requires `LOG_COST=true` in config):

```
Cost by project:
  Hendrik/26-05 Todenbuettel  $3.46

  Total: $3.46
```

This shows what your session would cost at API rates ($15/$75 per MTok for Opus 4.6). On subscription plans (Pro/Max), this is **informational** — not your actual bill. Your real budget constraint is the rate limit windows. Useful for understanding compute consumption and comparing session intensity.

## Diagnostics

```bash
# Verify dependencies
claude-worktime --check

# Full diagnostic dump (log stats, hooks, config, performance)
claude-worktime --debug

# Remove corrupt lines from the log
claude-worktime --repair
```

`--debug` output includes:
- Log file stats (size, entry count, corrupt lines, event breakdown)
- Current session ID and project list
- Archive inventory
- Config values
- Hook status (which hooks are installed)
- Statusline performance timing
- Dependency versions

## How it works

Six hooks log events to a JSONL file:

| Hook | Event | Meaning |
|------|-------|---------|
| SessionStart | `start` | CLI starts or resumes |
| UserPromptSubmit | `prompt` | User sends a message |
| PreToolUse | `tool_start` | Tool about to execute |
| PostToolUse | `tool_end` | Tool finished executing |
| Stop | `response` | Claude finished responding |
| StopFailure | `response` | API error (still counts as work) |

### Idle detection

A gap is **idle** when the user had the ball (previous event was `response` or `start`) and the gap exceeds `PAUSE_THRESHOLD` (default: 15 minutes). This covers both staying idle in the CLI (`response → prompt`) and quitting and coming back (`response → start`).

For active time tracking (`{today_project}`, `--breakdown`), all Claude turns count as productive work regardless of duration.

For presence tracking (`{since_break}`, `{last_break}`, `{timeline}`), a long Claude turn (`prompt → response` span exceeding the threshold) is treated as an absence — you probably walked away during a long agent job. This means the streak and timeline may differ from active time when Claude runs long autonomous tasks.

Long-running tools are never misclassified as idle in active time tracking.

### Tracking dimensions

Each log entry records three dimensions: **session ID**, **project path**, and **git branch**. You can view and filter time by any of these:

- **Session** (`{session}`, `--session`) — tied to the Claude Code session ID. Persists across `--resume` and `/resume`. A new CLI start without resume creates a new ID.
- **Project** (`{today_project}`, `{project_total}`, `--filter`) — based on the working directory path. Tracks time per project regardless of which session.
- **Branch** (`{branch}`, `{git}`, `--branch`) — git branch at the time of each event. Track time per feature branch.

The statusline tokens and CLI filters can be combined freely. For example, `{today_project}` shows today's time for the current project across all sessions, while `{session}` shows the current session across all projects.

## Log format

JSONL at `~/.local/share/claude-worktime/activity.jsonl`:

```jsonl
{"t":1774632641,"p":"/path/to/project","b":"main","s":"session-uuid","e":"start"}
{"t":1774632642,"p":"/path/to/project","b":"main","s":"session-uuid","e":"prompt"}
{"t":1774632643,"p":"/path/to/project","b":"main","s":"session-uuid","e":"tool_start"}
{"t":1774632650,"p":"/path/to/project","b":"main","s":"session-uuid","e":"tool_end"}
{"t":1774632655,"p":"/path/to/project","b":"main","s":"session-uuid","e":"response"}
```

| Field | Description |
|-------|-------------|
| `t` | Unix timestamp |
| `p` | Project path (from cwd) |
| `b` | Git branch (omitted if not in a git repo) |
| `s` | Session ID (persists across `--resume`) |
| `e` | Event type |

Corrupt lines are tolerated — all readers skip invalid JSON entries gracefully.

**Important:** The log stores raw events only. Concepts like "break" and "downtime" are **derived at query time** based on your current `PAUSE_THRESHOLD`. If you change the threshold, all historical data is reinterpreted retroactively — gaps that were "active" may become "breaks" and vice versa. This is intentional: the raw events are the source of truth, and the interpretation is configurable.

### Files

| Path | Purpose |
|------|---------|
| `~/.config/claude-worktime/config.sh` | Configuration |
| `~/.local/share/claude-worktime/activity.jsonl` | Active log (JSONL) |
| `~/.local/share/claude-worktime/activity-*.jsonl` | Rotated archives |
| `~/.local/bin/claude-worktime` | The script |

## Dependencies

| Tool | Min version | Required | Used for |
|------|-------------|----------|----------|
| **bash** | 4.0 | yes | `mapfile`, `read -t 0.1`, arrays |
| **jq** | 1.6 | yes | JSONL parsing, aggregation, `def` functions |
| **git** | 2.22 | no | `{git}` status token, branch logging |
| **date** | GNU coreutils or BSD | yes | timestamp conversion |

Run `claude-worktime --check` to verify.

No python, no node, no extra runtimes.

## Known limitations

**Hook reliability (~93%).** Claude Code hooks occasionally don't fire — in our testing, about 7% of events are missed (typically `response` or `prompt` events). This does **not** affect total active time, breaks, or downtime — those are calculated from the gaps between events that *do* fire, and the totals remain accurate. The only impact is on the Claude/You split in `--breakdown`, which may shift by a few percent in either direction. Missed `response` events attribute your reading time to Claude; missed `prompt` events do the opposite. These errors partially cancel out.

**Statusline is not real-time.** Claude Code refreshes the statusline after each assistant response and tool use, but not while you're typing or on a timer. Time tracking continues accurately in the background; only the display is event-driven.

**Incomplete statusline on session start.** Rate limit, context, and cache tokens require data from Claude Code's stdin JSON, which isn't available until the first API call completes. The statusline populates fully after your first message.

**Break splitting.** Any work between two idle gaps — regardless of how short — splits them into separate breaks. `{last_break}` shows only the most recent gap, which may appear shorter than expected when the timeline shows a longer break period. The timeline is unaffected since all idle gaps appear as break blocks.

## License

MIT
