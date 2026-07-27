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
- **A `cache-fix-proxy` restart while the session was live** — measured
  at 225k (2026-07-27 00:15), surfacing as `tools_changed`: the fresh
  process sends a different tools array than the old one. Check
  `systemctl --user show cache-fix-proxy -p ActiveEnterTimestamp`
  against the hit's timestamp before investigating further. **Don't
  restart the proxy to investigate a bust — that causes one.** The
  `<key>-events.jsonl` ledger is append-only so post-mortems need no
  live intervention.
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

**`cause: "other"` does not mean "unknown" — it means Claude Code sent
no diagnostics** for that request, so worktime had nothing to classify.
Step 2 below usually still names the culprit; `other` is a gap in the
API's reporting, not in the evidence.

An `other` in the statusline does not even mean the diagnostics are
missing from the TRANSCRIPT. The classifier reads `cache_miss_reason`
from the LAST assistant entry (`claude-worktime.sh:1662`), which is not
the busting turn, so it degrades to `other` while the real cause sits in
the transcript. Always grep the transcript for the busting timestamp
before concluding the cause is unavailable — a 2026-07-27 event showed
`other` in the statusline and `tools_changed` in the transcript.

**Scope: main sessions only.** State files are keyed by main-session id
(`.cold_<session-id>`); every one maps to a main transcript, and
subagents produce none. So these counts EXCLUDE subagent cache spend —
dispatching work moves tokens somewhere this counter cannot see. Don't
read a session's `❄` total as the cost of everything it did.

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

Each `prefix-diff` line reports which windows changed (`head=X,
markers=Y, tail=Z`) plus a **`cause=`** field naming the culprit
directly. Read `cause=` first — it is usually the whole answer:

| `cause=` | Meaning |
|---|---|
| `params:model` | a top-level param changed (model switch, thinking config, temperature) — invalidates everything |
| `system[2:env@1847]` | system block 2, labelled `env`, first differs at char 1847 |
| `tools[Bash:schema]` | the Bash tool's schema changed (not the tool list — the definition) |
| `messages@311(system)` | first divergent message index 311, a system-role entry |

`system[...]` and `params:...` invalidate from the front, so they cost
the whole context. A `messages@N` near the end is the ordinary cost of
the conversation advancing.

Byte-level detail lives in two files per session:

```sh
ls ~/.claude/cache-fix-snapshots/
# <key>-diff.json    latest diff, full detail — OVERWRITTEN each time
# <key>-events.jsonl append-only ledger, one bounded record per diff
```

**Read the `.jsonl`, not the `.json`,** for anything older than the
last few minutes: the detail file is rewritten on every diff, so in an
active session it is gone within minutes. Each ledger record carries
the changed system block's label, char offset, and a 120-char window
from both sides — enough to identify the culprit months later.

```sh
jq -c 'select(.causes|length>0) | {ts, causes}' \
    ~/.claude/cache-fix-snapshots/s-*-events.jsonl | tail -20
```

Keys prefixed `s-` are derived from the session-id header; a bare hex
key means the request had no session header and fell back to a content
hash.

**Finding YOUR session's key.** The `s-` key is a hash of the session
id, not the id itself — `ls | grep <session-id>` finds nothing, and the
mapping is recorded nowhere. Don't hunt by name; select by TIME. Given
the bust timestamp from step 1:

```sh
python3 - <<'PY'
import json, glob, os
WINDOW = "2026-07-27T17:17"          # UTC, minute precision
for p in glob.glob(os.path.expanduser("~/.claude/cache-fix-snapshots/*-events.jsonl")):
    if "insertion" in p or "ladder" in p: continue   # per-extension ledgers
    rows = [json.loads(l) for l in open(p) if l.strip()]
    hits = [r for r in rows if str(r.get("ts", "")).startswith(WINDOW)]
    if hits: print(os.path.basename(p), len(hits))
PY
```

Confirm the match by reading a hit's `params`: the `model` there must be
the one your session runs. Note these ledgers timestamp in **UTC** while
`claude-worktime` and `journalctl` print local time — convert before
comparing, or the window looks empty and you conclude "no diagnostics"
when the record is right there.

**One key can carry several conversations — and this WILL fool you.**
The key follows the session header, so a main session, every subagent it
dispatches, and Claude Code's own small background calls land on ONE
key. The ledger compares each request to whichever request preceded it
on that key, regardless of which conversation it came from, so co-tenant
traffic renders as violent prefix churn:

```
17:10:03 msgs: 80->82    (main advancing)
17:10:03 msgs: 82->40    model: opus-5 -> sonnet-5   <- subagent's turn
17:10:14 msgs: 40->43    (subagent advancing)
17:10:34 msgs: 43->2     (a third, tiny call)
17:10:34 msgs: 2->84     model: sonnet-5 -> opus-5   <- back to main
```

Nothing is wrong here. Two conversations are each advancing normally;
only the interleaving makes it look like the prefix is thrashing. This
is a **diagnostic-only artifact** — the upstream proxy tracks it as
"prefix-diff sidecar sub-keying, diagnostic-only residual"
(claude-code-cache-fix commit `1906e94`).

**Refute it before you attribute a bust to it:** read `cache_read` across
the same turns in the transcript. If `cr` keeps climbing (e.g.
129587 → 132861 → 133283 → 135247), nothing was evicted and the churn
cost nothing — whatever busted the cache, it was not the interleaving.
Only a COLLAPSE in `cr` indicates real eviction. Attributing a bust to
subagent interleaving on the strength of the `msgs:` oscillation alone
is a known wrong turn; it has been made and corrected (2026-07-27).

If this service isn't installed or isn't running, skip this step — it's
a bonus signal, not a requirement for the other three steps.

**Never restart the proxy to improve the evidence mid-session** — the
restart is itself a 225k-class bust (see Controlled causes above). The
ledger is append-only so no live intervention is needed.

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

## Recorded pattern datapoints (append-only)

- 2026-07-27 12:44:41 + 12:44:50 UTC (session f4d154fc, fable-5,
  ~153k cc each): identical `mtok` 126,243 on both — same divergence
  index hit twice, 9s apart. `flight=true`, `pblk=["tool_use"]`; the
  window immediately follows a Skill launch (19.7KB injected) plus a
  burst of PARALLEL Read results (3 arriving within 2s). Reading:
  in-flight history reordering — two successive requests both saw the
  history diverge at the same mid-history message.
- 2026-07-27 12:47:56 UTC (same session, 175k cc): `flight=false`,
  `ubytes=1263`; a teammate-message idle-notification (829B envelope)
  was injected as a user turn 7s earlier (12:47:49), mid-working-turn.
  Reading: injected-message class.
- Aggregate: all three same-day `messages_changed` threshold hits
  coincide with mid-flight injections (parallel tool-result races or
  teammate notifications); the 6-event no-correlation note above
  predates these. Still correlation, not proven cause — but the
  sample now leans injection/reorder for the `flight=true` +
  identical-`mtok` signature.
- 2026-07-27 14:05:06 UTC (same session, **580k cc**, `mtok` 504,607,
  `flight=false`, `ubytes=3935`): queued operator message (`queued_command` attachment) + a harness
  `task_reminder` attachment inserted mid-turn; transcript shows
  out-of-order `queue-operation`/`attachment` timestamps around the
  divergence. Largest recorded instance of the injection class.
  Mitigation directive: claude-code-cache-fix
  `docs/directives/proxy-mid-history-breakpoint-ladder.md`
  (fork branch feature/mid-history-breakpoint-ladder).

(Cost context for any event you investigate here: `token-cost-model.md`, same directory — what warm turns, busts, and pings actually bill.)

- 2026-07-27 15:36:55 UTC (same session, **766k cc**, `mtok` 666,929,
  cause `tools_changed`, gap 21s): a previously ToolSearch-loaded
  deferred tool (`CronCreate`, loaded 13:30) was REMOVED from tools[]
  plus sibling schema/reorder diffs (`CronCreate:removed,
  DeferredToolPlaceholder:reordered, …:schema`), coinciding with a
  harness `system` transcript event at 15:36:34/15:36:54 (a
  skills-availability update landed in this window). No ToolSearch
  call near the bust — the harness re-derived the tools array itself.
  Class-6 variant: deferred-tool UNLOAD/re-serialization, not load.
  Same mitigation family (tools[] must stay byte-stable;
  deferred-tool-rewrite Phase A covers additions — REMOVALS need the
  same treatment: candidate extension of the rewrite to hold removed
  tools in place until session end, they cost nothing inert).
  Day total now ~1.83M uncontrolled write-tokens across 5 events.
