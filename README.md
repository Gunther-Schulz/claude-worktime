# claude-worktime

Track active working time in [Claude Code](https://claude.com/claude-code) sessions.

```
my-org/my-project (main ✓) · ⏱  today 2h32m 🤖55m 👤1h37m · total 12h30m
08:22 ▮▮▮···▮▮▮▮··▮▮▮ 17:30 · ▶1h12m ⏸ 20m · ◑30% ↻3h21m →51% · ⑦5% ↻Sat · ctx 77% ⟳93% · ⊘2.1M/5.8M
```

Two lines, two perspectives on the same data:
- **Line 1** — work done: project time with Claude/You split
- **Line 2** — your day: presence timeline, break rhythm, rate limits

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

Then **restart Claude Code**. That's it — time tracking starts automatically.

Options: `--statusline` enables the status bar, `--force` overwrites existing hooks.

<details>
<summary>What the installer does</summary>

- Copies the script to `~/.local/bin/claude-worktime`
- Creates default config at `~/.config/claude-worktime/config.sh` (preserved on reinstall)
- Adds event hooks to `~/.claude/settings.json` (SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop, StopFailure)
- Adds a fenced section to `~/.claude/CLAUDE.md` so Claude knows about the tool (auto-updated on reinstall)
- Verifies dependencies

</details>

## Uninstall

```bash
./uninstall.sh
```

Removes hooks, statusline config, the script, and the CLAUDE.md section. Logs and config are preserved.

## What you see

### Statusline

Up to 3 configurable lines. Every element is a token — mix and match what matters to you.

**Line 1 — Work done** (project-scoped):
```
my-org/my-project (main ✓) · ⏱  today 2h32m 🤖55m 👤1h37m · total 12h30m
```
Total productive time, split into Claude's work and yours. Scoped to the current project.

**Line 2 — Your day** (cross-session):
```
08:22 ▮▮▮···▮▮▮▮··▮▮▮ 17:30 · ▶1h12m ⏸ 20m · ◑30% ↻3h21m →51% · ⑦5% ↻Sat · ctx 77% ⟳93% · ⊘2.1M/5.8M · ⊘2.1M/5.8M
```

| Element | Meaning |
|---------|---------|
| `▮▮··▮▮▮` | Day timeline — ▮ = present, · = away |
| `08:22` | Start time (first event today) |
| `17:30` | Current time |
| `▶1h12m` | Presence streak since last break (yellow >1.5h, red >2.5h) |
| `⏸ 20m` | Duration of most recent break |
| `◑30% ↻3h21m →51%` | 5h rate limit: used, time to reset, projected at reset |
| `⑦5% ↻Sat` | 7d rate limit: used, reset day |
| `ctx 77% ⟳93%` | Context window fullness + KV cache hit ratio |
| `⊘2.1M/5.8M` | Weighted tokens used / inferred budget (5h window) |

One character per time slot (`TIMELINE_SLOT`, default: 1800 seconds / 30 minutes). Set to `3600` for hourly or `900` for 15-minute resolution.

### CLI queries

```bash
claude-worktime                       # current session
claude-worktime --today               # today's total
claude-worktime --week                # this week
claude-worktime --since 2026-03-25    # since a date
claude-worktime --breakdown --today   # Claude vs You time split
claude-worktime --gaps --today        # gap distribution (tune threshold)
claude-worktime --summary --today     # per-project breakdown
claude-worktime --csv --today         # export as CSV
claude-worktime --cost --today        # cost analysis
claude-worktime --tokens              # statusline token legend
```

All filters (`--today`, `--week`, `--since`, `--filter`, `--branch`, `--session`) combine with any mode. Add `--raw` for JSON output.

### Phase breakdown

`--breakdown` shows how time splits:

```
  Claude:     1h 39min     51%
  You:        1h 32min     48%
  ─────────────────────────
  Active:     3h 13min
  Away:       45min        (1)
  Breaks:     20min        (1)
  Downtime:   12h 15min
```

- **Claude** — attended Claude work time
- **You** — your active time (reading, thinking, typing)
- **Active** — Claude + You (total productive time)
- **Away** — prompt-to-prompt spans exceeding threshold (you weren't at your desk)
- **Breaks** — idle gaps outside away spans (you were in the CLI but inactive)
- **Downtime** — quit and came back outside away spans

### Cost analysis

`--cost` shows API-equivalent cost per project:

```
Cost by project:
  Hendrik/26-05 Todenbuettel  $3.46

  Total: $3.46
```

This shows what your session would cost at API rates. On subscription plans (Pro/Max), this is informational — not your actual bill. Your real budget is the rate limit windows.

## Configuration

Config file: `~/.config/claude-worktime/config.sh` — plain bash, sourced at startup. All defaults are built into the script; the config only needs settings you want to override.

A commented-out template with all options is created on install.

### Tokens

**Time tokens** (from activity log):

| Token | Description |
|-------|-------------|
| `{status}` | ⏱ icon |
| `{session}` | Active time in current session |
| `{session_wall}` | Wall clock time since session started |
| `{today}` | Today's total active time (all sessions, all projects) |
| `{today_wall}` | Wall clock span of today (first event to now) |
| `{today_start}` | Start time today (e.g. `08:22`) |
| `{today_now}` | Current time (e.g. `19:25`) |
| `{today_project}` | Today's total for current project (Claude + You) |
| `{today_claude}` | Today's Claude work time for current project |
| `{today_you}` | Today's your active time for current project |
| `{project_total}` | All-time total for current project |
| `{total_claude}` | All-time Claude work time for current project |
| `{total_you}` | All-time your active time for current project |
| `{since_break}` | ▶2h40m — presence streak since last break |
| `{last_break}` | ⏸ 41m — most recent break duration (hidden until first break) |
| `{timeline}` | ▮▮··▮▮▮ — day timeline (▮=present ·=away), one char per `TIMELINE_SLOT` |

**Project tokens:**

| Token | Description |
|-------|-------------|
| `{project}` | Project name (last 2 path segments) |
| `{branch}` | Git branch name |
| `{git}` | Branch + state: `main ✓` `main ✗` `main +` `main ?` `main ↑2` `main ↓1` |

**Claude Code tokens** (from statusline stdin JSON):

| Token | Description |
|-------|-------------|
| `{rate_5h}` | 5h rate limit with pie icon: `○5%` `◔25%` `◑50%` `◕75%` `●95%` |
| `{rate_5h_reset}` | Time until 5h window resets |
| `{rate_5h_proj}` | Projected 5h usage at reset (yellow ≥90%, red ≥100%) |
| `{rate_7d}` | 7-day rate limit usage |
| `{rate_7d_reset}` | Time until 7d window resets |
| `{rate_7d_day}` | Reset weekday (e.g. `Sat`) |
| `{rate_7d_proj}` | Projected 7d usage |
| `{context}` | Context window + cache ratio (e.g. `77% ⟳93%`) |
| `{token_budget}` | Weighted token usage / inferred budget (e.g. `⊘2.1M/5.8M`) — main conversation only |
| `{cost_budget}` | Actual cost / inferred 5h budget (e.g. `$19.65/≈$40`) — includes agent costs |
| `{cost}` | Session cost (e.g. `$1.23`) |
| `{model}` | Model name + source (e.g. `Opus 4.6 (local)`) |

Empty tokens are automatically removed along with their surrounding separators.

**Model source detection:** The `{model}` token shows where the active model setting comes from: `local` (`.claude/settings.local.json`), `project` (`.claude/settings.json`), `global` (`~/.claude/settings.json`), `session` (`/model` or `--model` override), or `default` (no setting found). The source is inferred by comparing the running model against settings files — it may be inaccurate if settings files are changed mid-session without restarting Claude Code.

### Groups and layout

Define named groups, then compose lines by listing group names. The divider (`GROUP_DIVIDER`, default ` · `) is inserted between non-empty groups. Empty groups are hidden.

```bash
# Groups
GROUP_PROJECT="{project} ({git})"
GROUP_TODAY="{status} today {today_project}"
GROUP_TOTAL="total {project_total}"
GROUP_TIMELINE="{today_start} {timeline} {today_now}"
GROUP_BREAKS="{since_break} {last_break}"
GROUP_RATE_5H="{rate_5h} ↻{rate_5h_reset} {rate_5h_proj}"
GROUP_RATE_7D="⑦{rate_7d} ↻{rate_7d_day} {rate_7d_proj}"
GROUP_CONTEXT="ctx {context}"
GROUP_TOKENS="{token_budget}"

# Lines (space-separated group names)
STATUSLINE_1="PROJECT TODAY TOTAL"
STATUSLINE_2="TIMELINE BREAKS RATE_5H RATE_7D CONTEXT TOKENS"
GROUP_DIVIDER=" · "
```

**Examples:**

```bash
# Add Claude/You split to today
GROUP_TODAY="{status} today {today_project} 🤖{today_claude} 👤{today_you}"

# Add model and cost as a third line
GROUP_MODEL="{model} · {cost}"
STATUSLINE_3="MODEL"

# Compact single line
GROUP_COMPACT="{project} · {status} {session} ({today}) · {rate_5h}"
STATUSLINE_1="COMPACT"
STATUSLINE_2=""
```

**Per-group colors:** `GROUP_<NAME>_COLOR` gives a group its own color, falling back to `COLOR_NORMAL`.

```bash
GROUP_RATE_7D_COLOR="dark-gray"
GROUP_CONTEXT_COLOR="dark-gray"
```

### Colors

```bash
COLOR_NORMAL="green"              # working normally
COLOR_RATE_WARNING="yellow"       # projected rate ≥90%
COLOR_RATE_CRITICAL="red"         # projected rate ≥100%
COLOR_DEFAULT="dark-gray"         # dividers and secondary text
```

Presets: `black`, `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`, `white`, `gray`, `dark-gray`, `light-gray`, `orange`, `pink`, `purple`, `bright-green`, `bright-red`, `bright-yellow`, `bright-blue`, `bright-white`, `dim`, `reset`, `none`. Raw ANSI codes also work.

### Break reminder

`{since_break}` changes color when you've been working too long:

- **Yellow** at `STREAK_WARNING` (default: 1.5 hours)
- **Red** at `STREAK_CRITICAL` (default: 2.5 hours)

A "break" is any period exceeding `PAUSE_THRESHOLD` (default: 15 minutes) since your last prompt — whether you were idle, quit and came back, or Claude was running a long autonomous job. Set thresholds to `0` to disable.

### Auto-rotation

Old log entries are archived on session start. Daily rotation keeps the active log small.

```bash
AUTO_ROTATE=true
ROTATE_INTERVAL=daily    # daily, weekly, monthly
```

Archives: `activity-2026-03-28.jsonl` (daily), `activity-2026-W13.jsonl` (weekly), `activity-2026-03.jsonl` (monthly). Summary records preserve `{project_total}` across rotations.

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_WORKTIME_CONFIG` | `~/.config/claude-worktime` | Config directory |
| `CLAUDE_WORKTIME_DATA` | `~/.local/share/claude-worktime` | Data directory |
| `CLAUDE_WORKTIME_PAUSE` | `900` | Idle threshold in seconds (overrides config) |

Paths follow [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir-spec/latest/).

## How it works

### Events

Six hooks log events to a JSONL file:

| Hook | Event | Meaning |
|------|-------|---------|
| SessionStart | `start` | CLI starts or resumes |
| UserPromptSubmit | `prompt` | User sends a message |
| PreToolUse | `tool_start` | Tool about to execute |
| PostToolUse | `tool_end` | Tool finished |
| Stop | `response` | Claude finished responding |
| StopFailure | `response` | API error (still counts as work) |

The log stores raw events only — concepts like "break" and "idle" are derived at query time based on `PAUSE_THRESHOLD`. Change the threshold and all historical data is reinterpreted.

### Time model

Two models, one fork point — same events, same threshold, same log:

**Active time** (line 1 — "was work happening?"):
Gap-by-gap classification. Each gap between consecutive events is either productive or idle. A user turn (`response → prompt`) exceeding the threshold is idle. All Claude turns count as productive regardless of duration.

**Presence** (line 2 — "was the user at their desk?"):
Prompt-to-prompt spans. If the time between two consecutive user prompts exceeds the threshold, the user was away for that entire period — regardless of what happened in between (Claude working, tools running, idle time). This naturally handles long agent jobs and post-response gaps as one continuous absence.

The two models agree in normal conversation and only diverge during long autonomous Claude turns. A 21-minute agent job followed by 10 minutes before the user returns is one 31-minute away span in line 2, while line 1 counts the 21 minutes of Claude work as productive.

**Presence model notes:** The prompt-to-prompt measurement is approximate by seconds to a few minutes — return reading time, short work blips between long breaks, and the exact moment you stepped away are not precisely captured. This is fine for its purpose: the break reminder is a health nudge, not a timesheet. Active time (line 1) is always precise.

### Tracking dimensions

Each entry records **session ID**, **project path**, and **git branch**:

- **Session** (`{session}`, `--session`) — tied to Claude Code's session ID, persists across resume
- **Project** (`{today_project}`, `--filter`) — based on working directory
- **Branch** (`{git}`, `--branch`) — git branch at event time

### Cache hit ratio

`{context}` shows `77% ⟳93%` — context window fullness + KV cache hit ratio from the most recent API response. High (>95%) in steady conversation; drops during tool-heavy work (new content that hasn't been cached), after breaks (server cache expires), or at conversation start. Stateless — always reflects the current state.

## Diagnostics

```bash
claude-worktime --check     # verify dependencies
claude-worktime --debug     # full diagnostic dump
claude-worktime --repair    # remove corrupt log lines
```

## Log format

JSONL at `~/.local/share/claude-worktime/activity.jsonl`:

```jsonl
{"t":1774632641,"p":"/path/to/project","b":"main","s":"session-uuid","e":"start"}
{"t":1774632642,"p":"/path/to/project","b":"main","s":"session-uuid","e":"prompt"}
{"t":1774632655,"p":"/path/to/project","b":"main","s":"session-uuid","e":"response"}
```

| Field | Description |
|-------|-------------|
| `t` | Unix timestamp |
| `p` | Project path |
| `b` | Git branch (omitted if not in a git repo) |
| `s` | Session ID |
| `e` | Event type |

### Files

| Path | Purpose |
|------|---------|
| `~/.config/claude-worktime/config.sh` | Configuration |
| `~/.local/share/claude-worktime/activity.jsonl` | Active log |
| `~/.local/share/claude-worktime/activity-*.jsonl` | Rotated archives |
| `~/.local/bin/claude-worktime` | The script |

## Dependencies

| Tool | Min version | Required | Used for |
|------|-------------|----------|----------|
| **bash** | 4.0 | yes | `mapfile`, `read -t 0.1`, arrays |
| **jq** | 1.6 | yes | JSONL parsing, aggregation |
| **git** | 2.22 | no | `{git}` status token, branch logging |
| **date** | GNU coreutils or BSD | yes | timestamp conversion |

Run `claude-worktime --check` to verify. No python, no node, no extra runtimes.

## Known limitations

**Hook reliability (~93%).** Claude Code hooks occasionally don't fire — about 7% of events are missed. Total active time is unaffected. The Claude/You split may shift by a few percent. A missed prompt event merges two prompt-to-prompt spans into one, which may create a false away span or extend an existing one.

**Statusline refresh.** Refreshes after each assistant response and tool use, but not while you're typing. Rate limit and context tokens require the first API round-trip before appearing.

**Token budget accuracy.** The `{token_budget}` display tracks tokens per 5-hour rate limit window. The first window after install will be inaccurate because tracking starts mid-window while Anthropic's percentage covers the full window. All subsequent windows are accurate (both counters reset together). If you also use the web app or API, those tokens count toward the percentage but aren't tracked — the inferred budget will be slightly low.

## License

MIT
