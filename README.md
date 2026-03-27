# claude-worktime

Track active working time in [Claude Code](https://claude.com/claude-code) sessions.

Hooks into Claude Code's event lifecycle to log timestamps with session IDs, then computes active time using event-aware idle detection. Includes a configurable statusline, phase breakdowns, and an optional pomodoro timer.

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

### Session tracking

Each log entry includes the `session_id` from Claude Code. This ID persists across `--resume` and `/resume`, so resuming a session continues the same time counter. Starting a new CLI session without resume creates a new ID.

## Install

**Requirements:** [jq](https://jqlang.github.io/jq/)

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
- `--pomodoro` — enable pomodoro timer in default config
- `--force` — overwrite existing hooks

Then **restart Claude Code** to activate.

## Uninstall

```bash
./uninstall.sh
```

Removes hooks, statusline config, and the script. Logs are preserved at `~/.claude/worktime/`.

## Usage

### Statusline

Shows in Claude Code's status bar:

```
5m (2h 10m) · Hendrik/26-05 Todenbuettel
│    │         │
│    │         └── project (last 2 path segments)
│    └── today total (all sessions, all projects)
└── current session active time (by session ID)
```

When idle (response→prompt gap > 15min):
```
idle 18m · 5m (2h 10m) · Hendrik/26-05 Todenbuettel
```

### CLI queries

```bash
# Current session
claude-worktime

# Time ranges
claude-worktime --today
claude-worktime --week
claude-worktime --since 2026-03-25

# Filter by project path or git branch
claude-worktime --today --filter Todenbuettel
claude-worktime --today --branch feature/auth

# Phase breakdown — where your time actually goes
claude-worktime --breakdown
claude-worktime --breakdown --today
claude-worktime --breakdown --branch main

# Per-project summary
claude-worktime --summary
claude-worktime --summary --today

# CSV export
claude-worktime --csv
claude-worktime --csv --today

# JSON output (works with any mode)
claude-worktime --raw
claude-worktime --breakdown --raw

# Log rotation (archive entries older than current month)
claude-worktime --rotate
```

All filters (`--today`, `--week`, `--since`, `--filter`, `--branch`) can be combined with any mode.

### Phase breakdown

`--breakdown` shows how time splits across phases:

```
Phase breakdown:
  Tool execution:    12min        35%
  Claude thinking:    8min        24%
  User reading:      14min        41%
  ─────────────────────────────
  Active total:      34min
```

| Phase | What it measures |
|-------|-----------------|
| Tool execution | Time between `tool_start` → `tool_end` |
| Claude thinking | Claude processing: `prompt` → first tool or response |
| User reading | You reading output and typing: `response` → `prompt` (within threshold) |
| Idle | `response` → `prompt` gaps over threshold (excluded from active total) |

### Example output

```
# Current session
Active: 47min  |  Wall: 1h 23min  |  Paused: 36min  |  Started: 09:15  |  Project: Projekte/my-app

# Summary
  Projekte/my-app      47min
  dev/other-project    12min

# JSON
{"active":2820,"wall":4980,"paused":2160,"started":"09:15","project":"Projekte/my-app","session_id":"abc-123"}

# CSV
date,start,end,active_min,wall_min,project,session_id
2026-03-27,09:15,12:30,47,195,Projekte/my-app,abc-123
```

## Configuration

Config file: `~/.claude/worktime/config.sh` — plain bash key-value pairs with comments.

A default config with examples is created on install.

### Defaults

```bash
PAUSE_THRESHOLD=900  # 15 min idle threshold

STATUSLINE_FORMAT="{session} ({today}) · {project}"
STATUSLINE_IDLE_FORMAT="idle {idle} · {session} ({today}) · {project}"
```

### Format tokens

| Token | Description |
|-------|-------------|
| `{session}` | Active time in current session (by session ID) |
| `{session_wall}` | Wall clock time since session started |
| `{today}` | Today's total active time (all sessions, all projects) |
| `{today_project}` | Today's total for current project only |
| `{project}` | Project name (last 2 path segments) |
| `{branch}` | Git branch name |
| `{break}` | Pomodoro status indicator |
| `{idle}` | Idle duration (meaningful in idle format) |

### Colors

ANSI escape codes rendered in the terminal:

```bash
COLOR_NORMAL="\033[32m"       # green — working
COLOR_BREAK_DUE="\033[31m"    # red — break overdue
COLOR_ON_BREAK="\033[33m"     # yellow — on break
COLOR_IDLE="\033[90m"         # gray — idle
```

Set any color to `""` to disable it.

### Example configurations

```bash
# Minimal
STATUSLINE_FORMAT="{session}"
STATUSLINE_IDLE_FORMAT="idle {idle}"

# Branch-aware
STATUSLINE_FORMAT="{session} · {project}/{branch} ({today})"

# Project-focused
STATUSLINE_FORMAT="{today_project} · {project} ({branch})"
```

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_WORKTIME_DIR` | `~/.claude/worktime` | Directory for logs and config |
| `CLAUDE_WORKTIME_PAUSE` | `900` | Idle threshold in seconds (overrides config) |

## Pomodoro timer

The pomodoro is a **display-only** reminder in the statusline. It does not affect time tracking — your full active time is always counted regardless of whether you take breaks. It's up to you to actually take the break.

Enable in config:

```bash
POMODORO_ENABLED=true
POMODORO_WORK=1500         # 25 min work interval
POMODORO_SHORT_BREAK=300   # 5 min short break target
POMODORO_LONG_BREAK=900    # 15 min long break target
POMODORO_LONG_EVERY=4      # long break every 4 intervals
```

Add `{break}` to your statusline format:

```bash
STATUSLINE_FORMAT="{break} {session} ({today}) · {project}"
```

What you'll see:

| State | Display | Color |
|-------|---------|-------|
| Working, 7min left in interval | `🍅7m` | Green |
| 25min of work reached | `☕ break!` | Red |
| On break, 3 of 5min elapsed | `☕3m/5m` | Yellow |

The timer counts active time since your last break (any idle gap exceeding the threshold). When you stop interacting, it shows your idle time counting toward the break target. When you come back, the work counter resets.

## Log format

JSONL at `~/.claude/worktime/activity.log`:

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
| `e` | Event type: `start`, `prompt`, `tool_start`, `tool_end`, `response` |

### Files

| Path | Purpose |
|------|---------|
| `~/.claude/worktime/activity.log` | Active log (JSONL) |
| `~/.claude/worktime/config.sh` | Configuration |
| `~/.claude/worktime/activity-YYYY-MM.log` | Monthly archives (from `--rotate`) |
| `~/.local/bin/claude-worktime` | The script |

### Log rotation

```bash
claude-worktime --rotate
```

Archives entries older than the current month to `activity-YYYY-MM.log`.

## Dependencies

- **jq** — required (log parsing, JSON output)

That's it. No python, no node, no extra runtimes.

## License

MIT
