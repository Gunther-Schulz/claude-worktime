# Cache-bust investigation runbook

Audience: a **fresh** Claude session with no prior context, told something
like "hey, investigate this cache miss" or "check the last ❄ event." This
doc is self-contained — it does not assume you've read any other file
first. Follow the four steps in order; total time is a couple of minutes.

## What's normal vs. what's an event

A **partial cache miss** fires on nearly every turn — the API's own
`cache_miss_reason: messages_changed` diagnostic shows up dozens of times
per session with a typical ~70% average invalidation of the prior context.
That is normal, expected, and not worth investigating on its own.

What IS worth investigating is a **magnitude-threshold hit**: a turn where
the cache write (`cc`, cache-creation tokens) covers most of the prior
context (≥60%) while almost nothing is read back from cache (`cr` ≤20% of
prior context). That's a full-context rewrite paid at the cache-write
premium — the ❄ token in the statusline, and the event this runbook is
for. `claude-worktime` already does this discrimination for you; you don't
need to re-derive it from raw token counts.

## Controlled causes — no investigation needed

If `claude-worktime --cold` shows one of these as the `cause`, the bust is
expected and you can stop here:

- **`idle`** — the session sat open past the prompt-cache TTL (~1h on
  Claude Code's main thread). The cache expired naturally.
- **`model`** — the model changed since the previous turn (e.g. a
  fable-5 → opus-4.8 switch). A model change is a cache-key change; a
  full rewrite is unavoidable.
- A **deliberate opt-in config flip** made mid-session (each toggle busts
  the cache exactly once — expected, not a bug).
- **`/rc` (rewind/compact) mid-session** — a known, avoidable cache-buster;
  if it shows up here, note it, but there's nothing further to trace.

Everything else — an API `cause` like `messages_changed`,
`tools_changed`, `previous_message_not_found`, `unavailable`, or the
plain fallback `other` (no diagnostics field available) — crossed the
magnitude threshold with no idle gap and no model switch. That's the
case worth running the full procedure below.

## The four-step procedure

### 1. Magnitude + API cause + forensic fields

```
claude-worktime --cold
```

This is the entry point — the 90-day-retained ledger of every hit this
tool has recorded. Each row shows the event's size (`cc`, tokens
re-written at the write premium), its `cause` (the API's own
`cache_miss_reason.type` when idle/model don't explain it), the idle gap,
and the model. Add `--today` / `--week` / `--since` / `--session <id>` to
widen beyond the current session, or `--raw` to get the full JSON
including the per-hit forensic fields worktime also logs for every hit:

- `mtok` — `cache_missed_input_tokens` as reported by the API itself.
- `pblk` — content-block types of the assistant turn immediately
  preceding the bust (e.g. `["tool_use"]`, `["thinking","text"]`).
- `flight` — `true` if that preceding turn's `stop_reason` was
  `tool_use` (i.e. it was still mid-flight, awaiting a tool result, when
  the busting turn landed) vs. `false` for a clean `end_turn` boundary.
- `ubytes` — byte size of the newest user-role transcript entry before
  the busting turn (a large injected message is one candidate cause).
- `concur` — how many other transcript files in the same project
  directory were touched in the 5 minutes around the bust — a proxy for
  concurrent subagents/sessions that might have mutated shared state.

None of these fields have been shown to correlate with a bust on their
own (checked against a 6-event sample); they exist so each new event is
self-analyzing instead of requiring a fresh forensic pass from scratch.
Read them, but don't over-interpret a single event's fields as proof —
look for a pattern across multiple recorded hits first.

### 2. Where the prefix diverged (wire-level)

**Precondition:** requires the `claude-code-cache-fix` proxy with
prefix-diff + session-mirror enabled; without it, skip steps 2-3 —
steps 1 and 4 stand alone. `claude-worktime` itself has no dependency
on this proxy; it's an optional evidence amplifier for whoever's
environment happens to have it running.

If a `cache-fix-proxy` systemd user service is running (check with
`systemctl --user status cache-fix-proxy`), it can log where in the
outgoing request the token prefix diverged from the previous request —
which is the actual mechanism of a cache miss (the API keys the cache off
byte-identical prefixes).

```
journalctl --user -u cache-fix-proxy --since "-30min" --no-pager | grep prefix-diff
```

Each `prefix-diff` line for a request reports which windows of the
request changed: `head=X, markers=Y, tail=Z, marker_count=M`, plus the
message indices where `cache_control` markers sit. A line showing
`head=0` but nonzero `markers`/`tail` means the divergence is in the
middle or end of the conversation, not the system prompt — useful for
ruling out "did my CLAUDE.md / system prompt change" as the cause.

If this service isn't installed or isn't running, skip this step — it's
a bonus signal, not a requirement for the other three steps.

### 3. The exact mutated bytes (ground truth, replayable)

If request mirroring is enabled, the actual JSON bodies sent to the API
are captured per session:

```
ls ~/.claude/session-mirrors/<session-id>/
```

Diff the request captured at (or nearest to) the hit's timestamp against
its immediate predecessor. The diff shows the literal bytes that changed
— this is the most concrete evidence available, since it's exactly what
went over the wire, not an inference from token counts. If this directory
doesn't exist for the session in question, request mirroring wasn't
enabled at the time and this step has nothing to check — move on.

### 4. Conversation context

```
~/.claude/projects/<path-hash>/<session-id>.jsonl
```

(`<path-hash>` is the working-directory path with slashes replaced by
dashes — list `~/.claude/projects/` to find the right one, or use the
`transcript_path` value the statusline hook already receives.) This is
the actual Claude Code transcript: read the turns around the bust
timestamp to understand what the conversation was doing — a long tool
result landing, a subagent report being injected, a `/compact` or
`/clear`, cross-session message delivery, etc. This is where "why did
the conversation content change enough to bust the cache" gets answered
in human terms, after steps 1-3 have established the mechanical facts.

## Coverage note

Each question a post-mortem needs answered has a source above: *did it
happen and how big* → step 1; *what does the API say caused it* → step 1;
*where in the request did it diverge* → step 2; *what exact bytes changed*
→ step 3; *what was the conversation doing* → step 4. Steps 2 and 3
depend on optional infrastructure (the cache-fix proxy, request
mirroring) that may not be present in every environment — when they're
missing, steps 1 and 4 alone still answer "did this happen, how big was
it, and what was going on," just without wire-level byte-level proof.
