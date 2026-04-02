---
description: Show session time, rate limits, and work breakdown. Use when the user asks about session time, worktime, how long we've been working, time tracking, cost, or rate limits.
allowed-tools: Bash
disable-model-invocation: true
argument-hint: [--today|--breakdown|--summary|--cost|--gaps|--week|--tokens]
---

Run `claude-worktime $ARGUMENTS` and display the output.

If no arguments given, run `claude-worktime` (current session stats).

Common options:
- `--today` — today's total across all sessions
- `--breakdown --today` — Claude vs You time split
- `--summary` — per-project breakdown
- `--cost --today` — cost analysis
- `--tokens` — explain statusline tokens
- `--week` — this week's total
- `--gaps --today` — gap distribution (tune idle threshold)
