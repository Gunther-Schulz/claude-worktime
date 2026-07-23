# claude-worktime

Track active working time in [Claude Code](https://claude.com/claude-code) sessions.

```
my-org/my-project (main ✓) · ⏱  today 2h32m 🤖55m 👤1h37m · total 12h30m
08:22 ▪▪▪···▪▪▪▪··▪▪▪ 17:30 · ▶1h12m ⏸ 20m
Opus 4.6 (local) · ◑30% ↻3h21m →51% · ⑦5% ↻Sat · ctx 77%
```

Three lines, three perspectives on the same data:
- **Line 1** — work done: project time with Claude/You split
- **Line 2** — your day: presence timeline, break rhythm
- **Line 3** — model, rate limits, token budget, context

**Platform:** Linux is the primary target (developed and tested on it). macOS is supported as a second-class target with vanilla system bash 3.2 — no Homebrew bash or coreutils required, just `jq`. Windows is not supported.

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
- Appends event hooks to `~/.claude/settings.json` (SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop, StopFailure) — preserves hooks from other tools
- Installs `/worktime` slash command to `~/.claude/commands/worktime.md`
- Removes old CLAUDE.md section if present (replaced by the slash command)
- Verifies dependencies

</details>

## Uninstall

```bash
./uninstall.sh
```

Removes hooks, statusline config, the `/worktime` command, and the script. Logs and config are preserved.

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
08:22 ▪▪▪···▪▪▪▪··▪▪▪ 17:30 · ▶1h12m ⏸ 20m
```

| Element | Meaning |
|---------|---------|
| `▪▪··▪▪▪` | Day timeline — ▪ = present, · = away |
| `08:22` | Start time (first event today) |
| `17:30` | Current time |
| `▶1h12m` | Presence streak since last break (yellow >1.5h, red >2.5h) |
| `⏸ 20m` | Duration of most recent break |

**Line 3 — Model & limits**:
```
Opus 4.6 (local) · ◑30% ↻3h21m →51% · ⑦5% ↻Sat · ctx 77%
```

| Element | Meaning |
|---------|---------|
| `Opus 4.6 (local)` | Active model + config source (local/project/global/session/default) |
| `◑30% ↻3h21m →51%` | 5h rate limit: used, time to reset, projected at reset |
| `⑦5% ↻Sat` | 7d rate limit: used, reset day |
| `ctx 77%` | Context window fullness |
| `❄397k other (2m)` | Last cold-cache rewrite — size, cause, and (age); cyan when recent, gray once old. Its own `{cold}` token / `COLD` group, so it sits after `ctx` behind a normal ` · ` divider |

One character per time slot (`TIMELINE_SLOT`, default: 1200 seconds / 20 minutes). Set to `1800` for 30-minute, `3600` for hourly, or `900` for 15-minute resolution. The glyphs are `TIMELINE_CHAR_WORK` / `TIMELINE_CHAR_AWAY` — how heavy the bar reads depends on the terminal font, so `▪ ■ █ ▮ ▬` are all worth a try.

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
claude-worktime --cold                # cold-cache rewrites this session (❄ history)
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

### Cold-cache history

`--cold` lists the cold-cache rewrites the `❄` token only shows one of — the current session by default, or widened with `--today` / `--week` / `--since` / `--session`:

```
when                    size  cause      idle  model
2026-07-23 04:34:32     130k  idle       2h0m  opus-4-8
2026-07-23 05:23:03     397k  other       49s  fable-5
total                   527k  (2 rewrites)
```

Each row is one full-context rewrite paid at the cache-write premium: its size, cause (`idle` / `model` / `other`), the idle gap before it, and the model in play. Add `--raw` for JSON. Cause and model are blank for events logged before that field existed.

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
| `{timeline}` | ▪▪··▪▪▪ — day timeline (▪=present ·=away), one char per `TIMELINE_SLOT` |

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
| `{rate_7d_proj}` | Projected 7d usage (`→…` while insufficient data) |
| `{rate_7d_scoped}` | Model-scoped weekly limit (e.g. the Fable bucket on Max plans) |
| `{rate_7d_scoped_name}` | Name of the scoped model (e.g. `Fable`) |
| `{rate_7d_scoped_proj}` | Projected scoped usage at week's end |
| `{context}` | Context window usage (e.g. `77%`) |
| `{cold}` | Most recent cold-cache rewrite as `❄397k other (2m)` — size, cause, and (age); cyan when recent, gray after `COLD_FRESH_SECS`; empty until the first. Its own `GROUP_COLD` group so the ` · ` divider is inserted automatically |
| `{cost_budget}` | Actual cost / inferred 5h budget (e.g. `$19.65/≈$40`) — includes agent costs. The `≈` value is estimated; see below. |
| `{cost}` | Session cost (e.g. `$1.23`) |
| `{model}` | Model name + source when overridden (e.g. `Opus 4.6 (local)`) |
| `{effort}` | Reasoning effort level (`low` / `medium` / `high` / `xhigh` / `max`). Hidden when the active model doesn't support effort. |

Empty tokens are automatically removed along with their surrounding separators.

**Model source detection:** The `{model}` token shows where the active model setting comes from. The source label is only shown when the model is overridden: `local` (`.claude/settings.local.json`), `project` (`.claude/settings.json`), or `session` (`/model` or `--model` override). When the model comes from the global default (`~/.claude/settings.json`) or no setting is found, just the model name is shown without a label. The source is inferred by comparing the running model against settings files — it may be inaccurate if settings files are changed mid-session without restarting Claude Code. Context-window suffixes are stripped on both sides: `Opus 4.7 (1M context)` displays as `Opus 4.7`, and a settings value like `claude-fable-5[1m]` still matches the running `claude-fable-5`.

**Per-model colors:** `MODEL_COLORS` colors the `{model}` token by model — a comma-separated list of `substring=color` pairs matched case-insensitively against the model id and display name; first match wins, unmatched models keep the group color. Default: `fable=pink`. Example pinning all families: `MODEL_COLORS="fable=pink,opus=purple,sonnet=cyan,haiku=blue"`.

**Cold-cache counter & guard:** After an idle gap longer than the prompt-cache TTL (~1h for Claude Code's main thread), the next request silently re-writes the entire conversation prefix at the cache-write premium. Claude Code warns about this when *resuming a closed session*, but not when a session sits open and idle in a terminal — that gap is covered here, twice. The `❄397k other (2m)` marker — its own `{cold}` token, rendered as a `COLD` group so a ` · ` divider sets it off from `ctx` — shows the size, cause, and age of the most recent cold rewrite this session: the tokens re-written at the write premium (the felt cost; a bare count would flatten a 500k event and a 25k one into the same number), why it went cold, and how long ago, parenthesised so it reads plainly as elapsed time (the age answers what a static value can't: did this just happen, or is it old news?). It renders cyan while recent and dims to gray after `COLD_FRESH_SECS` (default 15min) so a ghost value recedes. Cold rewrites are detected from usage: a request that wrote most of the previous context while reading almost none of it back from cache — so `/compact`, which writes only a small summary, doesn't trigger it, and an idle gap or a model switch that changes the cache key does. A session's *first* write looks identical (nothing cached yet, whole context written) but is skipped structurally — it's flagged only when a prior turn already exists this session, so a fresh start is never mistaken for a rewrite while a resume after the cache expired still counts. `COLD_MIN_CTX` is an optional cosmetic floor on top (default 0 — shows everything; raise it to hide small rewrites). Every event is also logged with its exact size and a cause classification (`{"type":"cold",…,"cc":130000,"cause":"idle","mdl":"claude-…"}`): `idle` (gap past the cache TTL), `model` (the model changed since the previous turn — a cache-key switch), or `other` (same model, no idle — an injection/eviction/assembly race not observable from the usage numbers alone). On a hit the `other` residual is subdivided by what co-occurred in the transcript at that turn: `other:msg` (a cross-session message was being delivered) or `other:hook` (our own Stop-hook summary landed on that turn), falling back to plain `other` when neither is present. These suffixes are **co-occurrence flags, not proven causes** — they were the two factors that lined up when a real bust was traced by hand, and logging them turns each future `other` into a self-documenting sample so that, over many events, their rate against baseline can confirm or rule out the cross-session-message theory. The `❄` display above is always on and passive — it never blocks. Separately, an opt-in **cold guard** can warn you *before* a rewrite: it runs inside the `UserPromptSubmit` hook (`claude-worktime log --prompt`, already installed) and is **off by default** (`CACHE_GUARD_TTL=0`). Set `CACHE_GUARD_TTL` to the cache TTL in seconds (e.g. `3600`) to enable it; the first prompt after an idle gap past `0.9 × CACHE_GUARD_TTL` (→ 54min at a 3600s TTL, mirroring the CLI's own `elapsed < TTL×0.9` warmth test) with at least `CACHE_GUARD_MIN_CTX` context (default 50k tokens) is then blocked with a warning — the cheapest time to `/compact` or `/clear`, since the cache is lost either way. Submitting the prompt a second time proceeds normally — Claude Code echoes the blocked text back under the warning, and the guard warns only once per gap. Every cold event is logged (`{"type":"cold",...}`, kept 90 days) so the effective TTL can be verified empirically. The TTL itself is hardcoded in the Claude Code CLI with no API to query it — the reverse-engineering record and re-verification commands live in [`docs/cache-ttl-verification.md`](docs/cache-ttl-verification.md).

**Model-scoped weekly limit:** Claude Code's statusline stdin only carries the all-models 5h and 7d buckets. The per-model weekly bucket shown at claude.ai (e.g. "Fable — 36% used" on Max plans, where Fable is capped separately from the overall weekly limit) is fetched from `api.anthropic.com/api/oauth/usage` using the OAuth token Claude Code already stores (`~/.claude/.credentials.json`, or the Keychain on macOS), cached in the data dir, and refreshed in the background every `USAGE_FETCH_INTERVAL` seconds (default 60, `0` disables). The statusline never waits on the network — it renders the cached value. If the account has no scoped limit, the tokens stay empty and the group is hidden.

A cached value is only displayed while it is fresh: once the cache is older than `USAGE_STALE_MAX` seconds (default 900) the percentage renders as `?%` and the projection is dropped. The fetch interval is tracked on a separate lock file, so the cache's own timestamp always reflects the last *successful* response — a fetch that keeps failing (expired token, no network, API change) degrades to `?%` instead of showing its last number forever.

### Groups and layout

Define named groups, then compose lines by listing group names. The divider (`GROUP_DIVIDER`, default ` · `) is inserted between non-empty groups. Empty groups are hidden.

```bash
# Groups
GROUP_PROJECT="{project} ({git})"
GROUP_TODAY="{status} today {today_project} 🤖{today_claude} 👤{today_you}"
GROUP_TOTAL="total {project_total}"
GROUP_TIMELINE="{today_start} {timeline} {today_now}"
GROUP_BREAKS="{since_break} {last_break}"
GROUP_RATE_5H="{rate_5h} ↻{rate_5h_reset} {rate_5h_proj}"
GROUP_RATE_7D="⑦{rate_7d} ↻{rate_7d_day} {rate_7d_proj}"
GROUP_RATE_SCOPED="{rate_7d_scoped_name} {rate_7d_scoped} {rate_7d_scoped_proj}"
GROUP_CONTEXT="ctx {context}"
GROUP_MODEL="{model}"
GROUP_EFFORT="{effort}"

# Lines (space-separated group names)
STATUSLINE_1="PROJECT TODAY TOTAL"
STATUSLINE_2="TIMELINE BREAKS"
STATUSLINE_3="MODEL RATE_5H RATE_7D RATE_SCOPED CONTEXT"
GROUP_DIVIDER=" · "
```

**Examples:**

```bash
# Add cost budget to line 3 (opt-in — stabilises after ~65% window usage)
GROUP_BUDGET="{cost_budget}"
STATUSLINE_3="MODEL RATE_5H BUDGET RATE_7D CONTEXT"

# Show reasoning effort next to the model
STATUSLINE_3="MODEL EFFORT RATE_5H RATE_7D CONTEXT"

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

A "break" is any period where you weren't actively engaged — whether idle, quit and came back, or Claude was running a long autonomous job. Short Claude turns (up to ~5 minutes at the default 15-minute threshold) are credited as "user might be watching," but longer autonomous runs count toward absence. Set thresholds to `0` to disable.

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
Prompt-to-prompt spans with capped Claude credit. Claude response time up to threshold/3 (~5 minutes at the default 15-minute threshold) is subtracted — "the user might be watching." Beyond that, excess counts toward absence. This means normal Claude turns don't produce false break dots, while long autonomous runs (overnight jobs etc.) correctly show as breaks for well-being tracking.

The two models agree in normal conversation and only diverge during long autonomous Claude turns. A 25-minute agent job where the user returns immediately shows as a break in line 2 (25 - 5 credit = 20 > 15 threshold), while line 1 counts all 25 minutes as productive Claude work.

**Presence model notes:** The prompt-to-prompt measurement is approximate — return reading time, short work blips between long breaks, and the exact moment you stepped away are not precisely captured. This is fine for its purpose: the break reminder is a health nudge, not a timesheet. Active time (line 1) is always precise.

### Tracking dimensions

Each entry records **session ID**, **project path**, and **git branch**:

- **Session** (`{session}`, `--session`) — tied to Claude Code's session ID, persists across resume
- **Project** (`{today_project}`, `--filter`) — based on working directory
- **Branch** (`{git}`, `--branch`) — git branch at event time

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
| **bash** | 4.0 Linux / 3.2 macOS | yes | `mapfile`, `read -t`, arrays (macOS uses polyfills for bash 3.2) |
| **jq** | 1.6 | yes | JSONL parsing, aggregation |
| **git** | 2.22 | no | `{git}` status token, branch logging |
| **date** | GNU coreutils or BSD | yes | timestamp conversion |

Run `claude-worktime --check` to verify. No python, no node, no extra runtimes.

**Platform notes.** Linux uses GNU coreutils and bash 4+ directly; this is the canonical code path. macOS runs against vanilla system bash 3.2 and BSD utilities via a thin compatibility layer in `claude-worktime.sh` (bracketed near the top of the file). No `brew install bash` or `brew install coreutils` required — just `brew install jq`. The 7-day rate-limit glyph is `⑦` on Linux and `➐` on macOS (the latter renders cleanly in common macOS monospace fonts where `⑦` does not).

## Known limitations

**Hook reliability (~93%).** Claude Code hooks occasionally don't fire — about 7% of events are missed. Total active time is unaffected. The Claude/You split may shift by a few percent. A missed prompt event merges two prompt-to-prompt spans into one, which may create a false away span or extend an existing one.

**Statusline refresh.** Refreshes after each assistant response and tool use, but not while you're typing. Rate limit and context tokens require the first API round-trip before appearing.

**Exit display glitch.** When exiting Claude Code, the "Resume this session with..." message and the statusline's final refresh can race and overlap, producing garbled output. This is a Claude Code rendering issue — the statusline has no way to detect an imminent exit.

**Directory changes mid-session.** If Claude changes the working directory during a session (e.g. `cd` into a subproject or different repo), subsequent hook events are logged with the new directory as the project path — not the original project you started the session in. That time won't appear under the main project's totals. This is a known gap — not yet addressed.

**Cost budget estimate (`≈` value).** The budget is inferred by extrapolating current session cost (`cost.total_cost_usd`, which includes agents and tools) against rate-limit usage: if you've spent $4 at 10% of the window, that implies a ~$40 budget. However, early in a window (below ~65% usage) the reported cost lags behind actual usage — in-flight agent calls register against the rate limit before their cost is reported — making raw extrapolation unreliable. To keep the display stable, the estimate uses a two-phase approach: below 65% it holds the prior window's final estimate unchanged; above 65% it gradually blends new evidence in (weighted 30% new, 70% prior). The final converged value at the end of each window becomes the starting estimate for the next, so the display is immediately meaningful after a reset and only adjusts toward real values from mid-window onward.

## License

MIT
