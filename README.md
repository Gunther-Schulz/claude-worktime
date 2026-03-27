# claude-worktime

Track **active** working time in [Claude Code](https://claude.ai/claude-code) sessions. Unlike wall-clock timers, this tool detects idle periods and only counts time you're actually working.

## How it works

Two lightweight [Claude Code hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) log timestamps:

- **SessionStart** — records when a session begins (with working directory)
- **UserPromptSubmit** — records each time you send a message
- **Stop** — appends a daily summary when you exit

The `claude-worktime.sh` script reads these timestamps and calculates active time. Any gap longer than 10 minutes (configurable) between prompts is counted as idle/paused time.

```
Active: 47min  |  Wall: 1h 23min  |  Paused: 36min  |  Started: 09:15  |  Project: Projekte/my-app
```

## Install

```bash
# Option 1: Clone and install
git clone https://github.com/Gunther-Schulz/claude-worktime.git
cd claude-worktime
./install.sh

# Option 2: One-liner
curl -fsSL https://raw.githubusercontent.com/Gunther-Schulz/claude-worktime/main/install.sh | bash

# With statusline (shows active time in Claude Code UI)
./install.sh --statusline
```

Requires: `bash`, `jq`

## Usage

Inside Claude Code, type:

```
! ~/.claude/scripts/claude-worktime.sh
```

Or ask Claude to run it for you.

### Commands

```bash
claude-worktime.sh                                  # current session
claude-worktime.sh --today                          # all active time today
claude-worktime.sh --week                           # this week
claude-worktime.sh --since 2026-03-25               # since a specific date
claude-worktime.sh --filter PATH                    # time spent in a project
claude-worktime.sh --today --filter myproject        # combined filters
claude-worktime.sh --summary                        # per-project breakdown
claude-worktime.sh --summary --today                # per-project today
claude-worktime.sh --summary --week                 # per-project this week
claude-worktime.sh --csv                            # export all sessions as CSV
claude-worktime.sh --csv --today                    # export today's sessions
claude-worktime.sh --statusline                     # compact for statusline
claude-worktime.sh --rotate                         # archive old entries (monthly)
claude-worktime.sh --raw                            # JSON output (any mode)
```

### Example output

```
# Current session
Active: 47min  |  Wall: 1h 23min  |  Paused: 36min  |  Started: 09:15  |  Project: Projekte/my-app

# Statusline
⏱ 47m · Projekte/my-app

# Summary
  Projekte/my-app                          47min
  dev/other-project                        12min

# CSV
date,start,end,active_min,wall_min,project
2026-03-27,09:15,12:30,47,195,Projekte/my-app
2026-03-27,14:00,15:10,12,70,dev/other-project

# JSON
{"active":2820,"wall":4980,"paused":2160,"started":"09:15","project":"Projekte/my-app"}
```

## Features

- **Active vs idle detection** — gaps >10min between prompts count as paused
- **Per-project tracking** — logs working directory, filter with `--filter`
- **Time ranges** — `--today`, `--week`, `--since DATE`
- **Project summaries** — `--summary` shows time per project
- **CSV export** — `--csv` for importing into spreadsheets or time tracking tools
- **Statusline** — shows active time in Claude Code UI (install with `--statusline`)
- **Daily log** — `Stop` hook appends daily totals to `~/.claude/worktime/daily.log`
- **Log rotation** — `--rotate` archives entries older than current month
- **Resume-safe** — `/resume` and `claude --resume` both work correctly
- **Persistent log** — stored at `~/.claude/worktime/activity.log`
- **JSON output** — `--raw` for scripting and integration
- **Zero dependencies** — just bash + jq (jq only needed for install)

## Configuration

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_WORKTIME_PAUSE` | `600` | Seconds of inactivity before counting as paused (default: 10 min) |
| `CLAUDE_WORKTIME_DIR` | `~/.claude/worktime` | Directory for activity logs |

## Files

| Path | Purpose |
|------|---------|
| `~/.claude/worktime/activity.log` | Main activity log (timestamps + working directories) |
| `~/.claude/worktime/daily.log` | Daily summaries (appended on session exit) |
| `~/.claude/worktime/activity-YYYY-MM.log` | Monthly archives (created by `--rotate`) |
| `~/.claude/scripts/claude-worktime.sh` | The script itself |

## Uninstall

```bash
cd claude-worktime
./uninstall.sh
```

## How it compares

| | claude-worktime | claude-timer | claude-sessions |
|---|---|---|---|
| Tracks active vs idle | **Yes** | No (wall-clock only) | No (documentation tool) |
| Tracks project/cwd | **Yes** | No | No |
| Time range queries | **Yes** | No | No |
| Per-project summaries | **Yes** | No | No |
| CSV export | **Yes** | No | No |
| Statusline | **Yes** | No | No |
| Daily log | **Yes** | No | No |
| Log rotation | **Yes** | No | No |
| Resume-safe | **Yes** | N/A | N/A |
| Dependencies | bash + jq | Node.js | None |
| Mechanism | Native Claude Code hooks | npm wrapper binary | Slash commands |
| Purpose | Know how long you worked | Billing window alerts | Context preservation |

## License

MIT
