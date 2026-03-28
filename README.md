# claude-worktime

Track active working time in [Claude Code](https://claude.com/claude-code) sessions.

Hooks into Claude Code's event lifecycle to log timestamps with session IDs, then computes active time using event-aware idle detection. Includes a fully configurable multi-line statusline with rate limit projections and git status.

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
- `--force` — overwrite existing hooks

Then **restart Claude Code** to activate.

## Uninstall

```bash
./uninstall.sh
```

Removes hooks, statusline config, and the script. Logs are preserved at `~/.claude/worktime/`.

## Usage

### Statusline

Up to 3 configurable lines in Claude Code's status bar. Default:

```
⏱ session 45m · today 2h10m · my-org/my-project
```

With rate limits and git (via config):

```
⏱  today 45m · total 12h30m · my-org/my-project (main ✓)
20% ↻3h21m →51% · 5% 7d ↻Sat →35%
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

# Phase breakdown
claude-worktime --breakdown
claude-worktime --breakdown --today

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

`--breakdown` shows how time splits between Claude and you:

```
  Claude:   9min         60%
  You:      6min         39%
  ───────────────────────
  Active:   15min
```

- **Claude** — time from `prompt` until `response` (thinking, tools, output)
- **You** — time from `response` until next `prompt` (reading, thinking, typing)
- **Idle** — `response` → `prompt` gaps over threshold (excluded from active)

## Configuration

Config file: `~/.claude/worktime/config.sh` — plain bash key-value pairs with comments.

A default config with examples is created on install.

### Format tokens

**Time tokens** (computed from activity log):

| Token | Description |
|-------|-------------|
| `{status}` | ⏱ when working, ⏸ when idle |
| `{session}` | Active time in current session (by session ID) |
| `{session_wall}` | Wall clock time since session started |
| `{today}` | Today's total active time (all sessions, all projects) |
| `{today_project}` | Today's total for current project only |
| `{project_total}` | All-time total for current project |
| `{idle}` | Idle duration |

**Project tokens:**

| Token | Description |
|-------|-------------|
| `{project}` | Project name (last 2 path segments) |
| `{branch}` | Git branch name |
| `{git}` | Branch + state: `main ✓` `main ✗` `main +` `main ?` `main ↑2` `main ↓1` |

**Claude Code tokens** (from statusline stdin JSON):

| Token | Description |
|-------|-------------|
| `{rate_5h}` | 5-hour rate limit usage (e.g. `23%`) |
| `{rate_5h_reset}` | Time until 5h window resets (e.g. `3h21m`) |
| `{rate_5h_proj}` | Projected 5h usage at reset (e.g. `→51%`) |
| `{rate_7d}` | 7-day rate limit usage (e.g. `5%`) |
| `{rate_7d_reset}` | Time until 7d window resets |
| `{rate_7d_day}` | Reset weekday (e.g. `Sat`) |
| `{rate_7d_proj}` | Projected 7d usage (daily average) |
| `{context}` | Context window usage (e.g. `45%`) |
| `{cost}` | Session cost (e.g. `$1.23`) |
| `{model}` | Model name (e.g. `Opus 4.6`) |

Empty tokens are automatically removed along with their surrounding separators.

### Multi-line statusline

Up to 3 lines. Set `STATUSLINE_FORMAT_2` and `_3` for additional rows:

```bash
STATUSLINE_FORMAT="{status}  today {today_project} · total {project_total} · {project} ({git})"
STATUSLINE_FORMAT_2="{rate_5h} ↻{rate_5h_reset} {rate_5h_proj} · {rate_7d} 7d ↻{rate_7d_day} {rate_7d_proj}"
```

Idle variants (`STATUSLINE_IDLE_FORMAT_2`, `_3`) fall back to the normal format if unset.

### Rate limit projections

The `{rate_5h_proj}` token projects your usage at window reset based on current burn rate. Colors change at thresholds:
- Green — on pace, won't hit limit
- Yellow (`COLOR_RATE_WARNING`) — projected ≥90%
- Red (`COLOR_RATE_CRITICAL`) — projected ≥100%, will hit limit

The 7d projection uses daily averages and requires `RATE_7D_PROJ_MIN_DAYS` (default: 0.5 days) of data before showing.

### Colors

```bash
COLOR_NORMAL="\033[32m"           # green — working
COLOR_IDLE="\033[90m"             # gray — idle
COLOR_RATE_WARNING="\033[33m"     # yellow — projected rate ≥90%
COLOR_RATE_CRITICAL="\033[31m"    # red — projected rate ≥100%
```

Set any color to `""` to disable it.

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_WORKTIME_DIR` | `~/.claude/worktime` | Directory for logs and config |
| `CLAUDE_WORKTIME_PAUSE` | `900` | Idle threshold in seconds (overrides config) |

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
| `e` | Event type |

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
