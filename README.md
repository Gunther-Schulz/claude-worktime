# claude-worktime

Track **active** working time in [Claude Code](https://claude.ai/claude-code) sessions. Unlike wall-clock timers, this tool detects idle periods and only counts time you're actually working.

## How it works

Two lightweight [Claude Code hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) log timestamps:

- **SessionStart** — records when a session begins (with working directory)
- **UserPromptSubmit** — records each time you send a message

The `claude-worktime.sh` script reads these timestamps and calculates active time. Any gap longer than 10 minutes (configurable) between prompts is counted as idle/paused time.

```
Active: 47min  |  Wall: 1h 23min  |  Paused: 36min  |  Started: 09:15  |  Project: Projekte/Todenbuettel
```

### Resume-safe

Using `/resume` to continue a previous session starts a new tracking session. Previous session data is preserved in the log but not mixed into the current session's time.

## Install

```bash
# Option 1: Clone and install
git clone https://github.com/Gunther-Schulz/claude-worktime.git
cd claude-worktime
./install.sh

# Option 2: One-liner
curl -fsSL https://raw.githubusercontent.com/Gunther-Schulz/claude-worktime/main/install.sh | bash
```

Requires: `bash`, `jq`

## Usage

Inside Claude Code, type:

```
! ~/.claude/scripts/claude-worktime.sh
```

Or ask Claude to run it for you.

### JSON output (for scripting/statusline)

```bash
~/.claude/scripts/claude-worktime.sh --raw
# {"active":2820,"wall":4980,"paused":2160,"started":"09:15","project":"Projekte/Todenbuettel"}
```

## Configuration

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_WORKTIME_PAUSE` | `600` | Seconds of inactivity before counting as paused (default: 10 min) |
| `CLAUDE_WORKTIME_DIR` | `~/.claude/worktime` | Directory for the activity log |

The activity log is stored at `~/.claude/worktime/activity.log` and persists across reboots.

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
| Resume-safe | **Yes** | N/A | N/A |
| Dependencies | bash + jq | Node.js | None |
| Mechanism | Native Claude Code hooks | npm wrapper binary | Slash commands |
| Purpose | Know how long you worked | Billing window alerts | Context preservation |

## License

MIT
