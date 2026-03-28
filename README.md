# claude-worktime

Track active working time in [Claude Code](https://claude.com/claude-code) sessions.

```
my-org/my-project (main ✓) · ⏱  today 2h32m · total 12h30m
▮▯▯▮▮▮▮▮▮▮▮▮▮▮▮▯▯▮▮▮ 5h02m · ▶1h12m ⏸ 20m · ◑30% ↻3h21m →51% · ctx 77% ⟳99% · 5% 7d ↻Sat
```

Time tracking, break detection, rate limit projections, git status, cost analysis — all in a configurable multi-line statusline. Event-aware idle detection ensures long-running tools are never misclassified as breaks.

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

The installer verifies dependencies automatically. Then **restart Claude Code** to activate.

## Uninstall

```bash
./uninstall.sh
```

Removes hooks, statusline config, and the script. Logs are preserved in the data directory.

## Statusline

Up to 3 configurable lines in Claude Code's status bar. Every element is a configurable token — mix and match to show what matters to you.

**Default (two lines — project-scoped + cross-session personal):**
```
my-org/my-project (main ✓) · ⏱  today 2h32m · total 12h30m
▮▯▯▮▮▮▮▮▮▮▮▮▮▮▮▯▯▮▮▮ 5h02m · ▶1h12m ⏸ 20m · ◑30% ↻3h21m →51% · ctx 77% ⟳99% · 5% 7d ↻Sat
```
Line 1: project name, git status, project time (scoped to this project)
Line 2: day timeline, global today, break rhythm, rate limits (cross-session)

The timeline adapts its width to your day length, configurable via `TIMELINE_WIDTH` (default: 20 blocks).

**Compact single line:**
```
my-org/my-project · ⏱  45m (2h10m) · ◑20%
```

**Note:** The statusline is not real-time. Claude Code only refreshes it after each assistant response — not when you send a prompt, not during tool execution, and not on a timer. The display stays frozen until Claude finishes responding. The underlying time tracking is accurate regardless; only the display is event-driven.

## Configuration

Config file: `~/.config/claude-worktime/config.sh` — plain bash key-value pairs with comments.

A default config with examples is created on install.

### Format tokens

**Time tokens** (computed from activity log):

| Token | Description |
|-------|-------------|
| `{status}` | ⏱ icon |
| `{session}` | Active time in current session (by session ID) |
| `{session_wall}` | Wall clock time since session started |
| `{today}` | Today's total active time (all sessions, all projects) |
| `{today_project}` | Today's total for current project only |
| `{project_total}` | All-time total for current project |
| `{since_break}` | ▶2h40m — continuous work time since most recent break |
| `{last_break}` | ⏸ 41m — duration of most recent break |
| `{timeline}` | ▮▯▯▮▮▮▮▮▮▯▯▮▮▮ — day sparkline (▮=work ▯=break) |

`{since_break}`, `{last_break}`, and `{timeline}` are **cross-session** — they reflect your whole day across all projects and sessions, not just the current one. This gives an accurate picture of your personal work/break rhythm even when switching between multiple sessions.

All three auto-hide when no data is available.

**Project tokens:**

| Token | Description |
|-------|-------------|
| `{project}` | Project name (last 2 path segments) |
| `{branch}` | Git branch name |
| `{git}` | Branch + state: `main ✓` `main ✗` `main +` `main ?` `main ↑2` `main ↓1` |

**Claude Code tokens** (from statusline stdin JSON):

| Token | Description |
|-------|-------------|
| `{rate_5h}` | 5-hour rate limit with pie icon: `○5%` `◔15%` `◑35%` `◕60%` `●80%` |
| `{rate_5h_reset}` | Time until 5h window resets (e.g. `3h21m`) |
| `{rate_5h_proj}` | Projected 5h usage at reset (e.g. `→51%`) |
| `{rate_7d}` | 7-day rate limit usage (e.g. `5%`) |
| `{rate_7d_reset}` | Time until 7d window resets |
| `{rate_7d_day}` | Reset weekday (e.g. `Sat`) |
| `{rate_7d_proj}` | Projected 7d usage (daily average) |
| `{context}` | `77% ⟳93%` — context window usage + cache hit ratio. **77%** = how full your context window is (Claude auto-compacts at ~95%). **⟳93%** = KV cache hit ratio — how much of your conversation the API served from its server-side cache vs had to reprocess from scratch. High (>95%) in steady conversation; drops during tool-heavy work (each new tool output is new content that must be processed for the first time) or after long breaks (the server-side cache expires after ~5 minutes of inactivity). Accumulates across the 5h rate limit window and resets with it. |
| `{cost}` | Session cost (e.g. `$1.23`) |
| `{model}` | Model name (e.g. `Opus 4.6`) |

Empty tokens are automatically removed along with their surrounding separators.

### Multi-line statusline

Up to 3 lines. Set `STATUSLINE_FORMAT_2` and `_3` for additional rows:

```bash
STATUSLINE_FORMAT="{status}  today {today_project} · total {project_total} · {project} ({git})"
STATUSLINE_FORMAT_2="{rate_5h} ↻{rate_5h_reset} {rate_5h_proj} · {rate_7d} 7d ↻{rate_7d_day} {rate_7d_proj}"
```

### Rate limit projections

The `{rate_5h_proj}` token projects your usage at window reset based on current burn rate. Projection color is configurable via `COLOR_RATE_WARNING` (default: yellow at ≥90%) and `COLOR_RATE_CRITICAL` (default: red at ≥100%). Set to `""` to disable.

The 7d projection uses daily averages and requires `RATE_7D_PROJ_MIN_DAYS` (default: 0.5 days) of data before showing.

### Auto-rotation

Old log entries are automatically archived on session start. Configure in `config.sh`:

```bash
AUTO_ROTATE=true
ROTATE_INTERVAL=monthly    # monthly, weekly, daily
```

Archive filenames adapt to the interval:
- `monthly` → `activity-2026-03.jsonl`
- `weekly` → `activity-2026-W13.jsonl`
- `daily` → `activity-2026-03-28.jsonl`

Per-project summary entries are preserved in the active log so `{project_total}` survives rotation. CLI queries (`--since`, `--summary`, `--csv`, etc.) automatically search archived logs for historical data.

Manual rotation: `claude-worktime --rotate`

### Colors

```bash
COLOR_NORMAL="\033[32m"           # green — working
COLOR_RATE_WARNING="\033[33m"     # yellow — projected rate ≥90%
COLOR_RATE_CRITICAL="\033[31m"    # red — projected rate ≥100%
```

Set any color to `""` to disable it.

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
```

All filters (`--today`, `--week`, `--since`, `--filter`, `--branch`, `--session`) can be combined with any mode.

### Phase breakdown

`--breakdown` shows how time splits between Claude, you, breaks, and downtime:

```
  Claude:     1h 39min     51%
  You:        1h 32min     48%
  ─────────────────────────
  Active:     3h 13min
  Breaks:     20min        (1)
  Downtime:   12h 15min
```

- **Claude** — time from `prompt` until `response` (thinking, tools, output)
- **You** — time from `response` until next `prompt` (reading, thinking, typing)
- **Breaks** — `response` → `prompt` gaps over threshold within a session (you paused but didn't quit)
- **Downtime** — `response` → `start` gaps (you quit the CLI and came back)

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

Only one type of gap can be idle: **`response` → `prompt`** — the moment between Claude finishing its response and the user sending the next message. If this gap exceeds `PAUSE_THRESHOLD` (default: 15 minutes), it's counted as idle.

All other gaps are always active work:
- `tool_start` → `tool_end` — tool running (even if it takes 20 minutes)
- `prompt` → `tool_start` — Claude thinking before using a tool
- `tool_end` → `response` — Claude generating output after tools
- `prompt` → `response` — Claude thinking (text-only, no tools)

This means long-running tools never get misclassified as idle time.

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
| **jq** | 1.6 | yes | JSONL parsing, `@tsv`, `def` functions |
| **git** | 2.22 | no | `{git}` status token, branch logging |
| **date** | GNU coreutils or BSD | yes | timestamp conversion |

Run `claude-worktime --check` to verify.

No python, no node, no extra runtimes.

## Known limitations

**Hook reliability (~93%).** Claude Code hooks occasionally don't fire — in our testing, about 7% of events are missed (typically `response` or `prompt` events). This does **not** affect total active time, breaks, or downtime — those are calculated from the gaps between events that *do* fire, and the totals remain accurate. The only impact is on the Claude/You split in `--breakdown`, which may shift by a few percent in either direction. Missed `response` events attribute your reading time to Claude; missed `prompt` events do the opposite. These errors partially cancel out.

**Statusline is not real-time.** Claude Code only refreshes the statusline after each assistant response. The display freezes during tool execution and while you're typing. Time tracking continues accurately in the background; only the display is delayed.

## License

MIT
