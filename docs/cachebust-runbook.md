# Cache-bust investigation runbook

Audience: a **fresh** Claude session with no prior context, told something
like "hey, investigate this cache miss" or "check the last ❄ event." This
doc is self-contained — it does not assume you've read any other file
first. Follow the four steps in order; total time is a couple of minutes.

> **Different task? Read a different file.** This one is for INVESTIGATING a
> bust that already happened. If you are about to CHANGE the proxy —
> extensions, normalization, anything under `proxy/` — read
> `~/dev/vendor/claude-code-cache-fix/docs/dev-loop.md` first: the replay
> gates that must pass, the standing rules, and the check-design lessons.
> Six self-inflicted defects shipped and stayed live for months because that
> procedure did not exist; every one was found the day it did.
>
> Worth knowing before you attribute anything here: a divergence present in
> `~/.claude/cache-fix-captures/` is Claude Code's, one absent there is OURS
> (captures are recorded pre-pipeline). On 2026-07-28 five of six defects
> that looked like CC turned out to be ours.

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
- **A `cache-fix-proxy` restart while the session was live** — one
  measured incident at 225k (2026-07-27 00:15), surfacing as
  `tools_changed`. Check `systemctl --user show cache-fix-proxy -p
  ActiveEnterTimestamp` against the hit's timestamp before investigating
  further. **Status: no longer reliably a bust.** A restart at
  2026-07-27 19:01 produced none — `cache_read` climbed straight
  through it (35990 → 42475) and the first post-restart prefix-diff
  logged `tools=match, system=match`. The mechanism once given for the
  225k incident ("the fresh process sends a different tools array") was
  never demonstrated against wire bytes; the diagnostics that could have
  shown it postdate it.

  **SETTLED 2026-07-28: a restart alone costs NOTHING — stop treating it
  as a suspect.** Two independent lines agree. Offline, `replay.mjs
  --restart-at N` (fresh module registry, state directory intact — what
  a real restart is) is byte-identical to no restart, while
  `--wipe-state-at N` (state directory GONE — a different event) costs
  one violation; conflating the two measures a disaster and calls it a
  restart. Live, a restart at 19:38 on a ~805k-deep session showed
  `cache_read` 805,801 → 809,920 with `cc=383`, climbing straight
  through, and no `--cold` hit. The reason is structural: every
  cache-relevant decision (insertion-normalization's canonical,
  deferred-tool-rewrite's tool baseline) is persisted and re-read per
  request, so a fresh process reproduces byte-identical output.

  **The trap is a CONFIG change flipped in the same restart.** A restart
  at 17:08 the same day did bust — 678k — but that was
  `CACHE_FIX_VOLATILE_PIN` being switched on, whose canon identity
  scheme differs and costs one documented reset per conversation. Two
  variables changed, and attributing the result to the restart would
  have been wrong. When a bust brackets a restart, check whether the
  UNIT changed too before blaming the process.
- **`/rc` (rewind/compact) mid-session** — a known, avoidable cache-buster;
  if it shows up here, note it, but there's nothing further to trace.
- **`compact` / `auto-compact` / `resume` ❄ labels** — controlled-cost
  classes, expected by construction (since 2026-07-31): the ❄ token is a
  cost meter, not just a bug alarm, so the real miss a `/compact`, an
  auto-compact at the context ceiling, or a resume/fork causes displays
  with its honest label instead of hiding. These are logged `k:"cost"`,
  never `k:"hit"` — they don't advance the `#N` bust index, don't fire the
  desktop notification, and don't appear in `--cold` unless `--all` is
  given. Nothing to investigate: the label already names the user action
  that caused the cost.
- **A ❄ token showing `previous_message_not_found`** — should no longer
  occur (fixed 2026-07-31, same day it was measured on s-f94e53ce: a
  post-`/compact` first write — 51k, unavoidable, cache healthy —
  displayed as a 51k bust). Two defects conspired: a zero-usage tokens
  entry logged at compact completion reset the idle clock and zeroed
  prev-ctx (defeating the idle classifier and the compact-skip), and
  the late-bind cause upgrade pasted the resume-class cause into the ❄
  display without the resume-split, leaving a false `k:"hit"` booked.
  Now: zero-usage renders are never persisted, a late-found
  `previous_message_not_found` retracts the booked hit (`k:"hit-retract"`
  marker; `--cold` and the guard tally drop retracted hits). If this
  cause ever shows in ❄ again, that is a regression — check the
  transcript for a `compact_boundary` or resume near the hit timestamp,
  then the detector tests (`tests/replay-cold-detect.sh`).

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
journalctl --user -u cache-fix-proxy --utc --since "-30min" --no-pager | grep prefix-diff
```

An empty grep here while the proxy is active is expected on current
builds — prefix-diff writes to the snapshot ledgers only (below), not
to the journal (observed 2026-07-30: journal empty across a window
whose ledgers carried every diff). Go straight to the ledger files.

**Always pass `--utc`** (and `TZ=UTC` to `systemctl show`, `date`, and any
ad-hoc script): the snapshot ledgers and transcripts timestamp in UTC, and
one 2026-07-28 session burned time hunting a "00:13 local" bust in the
22:13Z ledger rows. The convention for this whole procedure is: every
command that prints a timestamp prints UTC. The one exception you cannot
flip is `claude-worktime` itself, which prints local — convert its bust
time to UTC (`date -u -d '<local time>'`) before touching any other
source.

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
the one your session runs. These ledgers timestamp in **UTC**; if you
followed the `--utc` convention above, everything already matches. The
trap only reopens through `claude-worktime`'s local-time output — convert
that one value at the boundary and stay in UTC everywhere else, or the
window looks empty and you conclude "no diagnostics" when the record is
right there.

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
  (directive on fork main; no implementation branch exists as of
  2026-07-30 — an earlier note here named one that was never cut).

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

- 2026-07-28 09:47:31 + 09:53:21 UTC (session 35d72503, opus-5[1m],
  252,905 + 266,422 cc = **519k**; `mtok` 205,814 / 217,025; cause
  `messages_changed`, `flight=true`, `pblk=["tool_use"]`, `concur=0`
  on both). **New class: hook-reminder re-anchoring.** Both diverge at
  a user message carrying an Agent-dispatch `tool_result`
  (prefix-diff `messages@465(user)` / `messages@503(user)`,
  `systemMatch=true`, `toolsMatch=true` — so nothing in system or
  tools moved).

  Mechanism, from the wire bytes
  (`~/.claude/cache-fix-captures/s-<sid>-requests.jsonl`): the
  `PreToolUse:Agent` and `PostToolUse:Agent` hook reminders are first
  sent as two extra `text` blocks appended INSIDE the Agent
  `tool_result` user message; on a later request the harness
  re-serializes them as their own standalone message. The blocks are
  stripped from the tool_result and everything after it shifts by one
  index — 26 messages "differ" positionally though the conversation
  only advanced. Confirmed by content: `[503] prev
  list[tool_result,SYSREM(387),SYSREM(313)] → now list[tool_result]`,
  and `[504] prev list[thinking,text,tool_use:Read] → now
  str('PreToolUse:Agent hook additional context…')`, with every
  subsequent pair showing prev[i] == now[i+1].

  Trigger, all three same-day instances: a user-role message landing
  mid-flight (09:47:31 an operator interrupt, 09:53:21 an operator
  pushback, 09:03:09 a teammate-message delivery). The
  re-serialization rides the request that carries the new user turn.

  Refutation probes run (both passed): eviction is real — `cache_read`
  collapses 275,152 → 23,077 and 287,492 → 23,077 in the transcript,
  not the diagnostic-only interleaving artifact. And a scan of all 342
  main-chain requests that day found exactly THREE mid-history
  divergences; the two that dropped Agent hook blocks are exactly the
  two busts. The third (09:03:09, same insertion class from a Stop-hook
  reminder) cost only 2,663 cc and did NOT bust — divergence index 95
  of 133 while `cache_read` climbed 100,247 → 101,234. So position and
  the surviving cached prefix, not the insertion alone, set the
  magnitude; why 23,077 was the floor on both busts (rather than a
  prefix ending near index 464) is NOT established — the breakpoint
  ledger shows a single tail `cache_control` marker per request
  (`[491]`, `[531]`), so there may be no intermediate boundary to fall
  back to, but that was not proven against wire bytes.

  **Attribution: CC's, not ours** — the standing rule from HANDOFF
  §10.3b (classify every divergence pre vs post) is satisfied here.
  These bytes come from `request-capture` (order 60); the only
  extension ahead of it is `bootstrap-defense` (order 45), which
  deletes top-level prompt keys and never touches `messages[]`
  (`bootstrap-defense.mjs:262-268`), and `runOnRequest` awaits each
  extension in sequence (`pipeline.mjs:105-113`) while capture
  `JSON.stringify`s inside its own hook (`request-capture.mjs:136-142`),
  so no later extension can alias into the captured bytes. The flip is
  in what Claude Code sent.

  **This is the same class as HANDOFF §10.2/§10.2b (2026-07-27, 135k +
  182k), with a new shape.** There the reminder alternated
  present/absent INSIDE a user message. Here it MIGRATES: stripped from
  the user `tool_result` and re-emitted as a standalone `system`-role
  message with STRING content. That shape escapes the phase-3 pin,
  whose volatile classifier is scoped to user-role block arrays
  (`isVolatileBlock` returns false for a string-content system message —
  verified by running the real classifier against these captured bytes).

  **RESOLVED same day — this class is closed, and closing it exposed
  five more defects that were OURS.** `CACHE_FIX_VOLATILE_PIN=1` is
  live as of 2026-07-28 17:08 along with `CACHE_FIX_TOOL_REWRITE=1`
  and `CACHE_FIX_UPSTREAM_DETECTION=1`. Both corpora now replay with
  0 stability, 0 safety, 0 sequence and 0 canonical-order violations.

  The pin alone was NOT enough, and the first assessment above (half
  the damage) was right to doubt it. What the rest turned out to be:

  - `thinking-block-sanitize` forwarded a byte-identical message one
    way while it was the tail and another once a turn landed after it
    (133 + 76 violations across the two corpora) — OURS;
  - `insertion-normalization` keyed canonical state on
    (session-id, system-prompt), which every subagent shares, so 72 of
    83 resets were a keying artifact — OURS;
  - its canonical filed new entries in ARRIVAL order while they sat
    mid-history on the wire, and phase 2 relocated a system message
    past three real turns: a live conversation CORRUPTION — OURS;
  - `edit-shaped` fired on any drop plus any splice, so an operator
    interrupt pruning the tail while a reminder migrated 24 indices
    away read as an edit — OURS;
  - `deferred-tool-rewrite` keyed on the bare session-id, so enabling
    it RAISED tools[] churn — OURS.

  The two 2026-07-28 busts above remain genuinely CC's (proven
  pre-pipeline). Almost everything else that looked like CC was not.
  Procedure that found them: `docs/dev-loop.md` in the cache-fix fork.

  Two corrections to the paragraph above, kept because the reasoning
  errors matter more than the conclusions: `tools/cache-sim.mjs` is
  now streaming + `--pipeline` + conversation-grouped, but its
  absolute totals are STILL not trustworthy (it models one-request
  cache memory; the API keeps every entry in the TTL window). And
  "restarts are byte-free" — offline-verified, live-UNTESTED: the one
  live restart flipped three gates simultaneously and paid the pin's
  documented one-time canon mode change (678k), so it proves nothing
  either way.
  Day total ~519k uncontrolled write-tokens across 2 events.

- 2026-07-30 16:57:14 UTC (session 0d6f38ba, fable-5, **221k cc**,
  `mtok` 201,434, cause `messages_changed`, gap 9s, `flight=false`,
  `ubytes=4248`, `concur=1`): first measured OSCILLATION of the
  block-migration class — the Agent hook-reminder pair flipped
  inline->standalone->inline->standalone across four consecutive
  main-thread requests in 11 s (census: n=102->104, 104->105,
  105->108, each edit@86, anchor -10..-14, ~31-37 kB per flip).
  Trigger window: a ~4.2 kB teammate report landing at a clean turn
  boundary amid mid-turn operator messages. Attribution CC's
  (pre-pipeline capture; pipeline 0 violations, three clean
  edit-shaped resets). The standalone legs are TWO SEPARATE
  system-role string messages — NOT absorbed by the join-hash fix
  (cache-fix 78940a0, serving since 08:41Z), whose match is the two
  blocks JOINED into one; census running that code still lists the
  flap pairs unabsorbed. Occurrence-side successor (per-block
  standalone match) booked in the fork backlog; magnitude (85% of
  ctx missed from edit@86) consistent with the open
  breakpoint-sparsity question, still unproven against wire bytes.
  Full record: cache-fix threat-matrix Row 4 datapoint 2026-07-30
  (commit 8cd4e1c).
  CORRECTION (same day, builder-measured; cache-fix fixture 090a110):
  the census over-reported the migrations 2x — a blockUnits phantom
  (any message shrunk to one block reads as standalone), only 92->94
  is real; the flap stands as ONE reminder block flipping. And the
  suppression-coverage reading was wrong: both matchable standalones
  already hash-match — the escape is an edit-shaped reset firing
  BEFORE suppression, triggered by a novel cross-message join. The
  "per-block standalone match" successor named above is withdrawn
  (already built since #76606); the real mitigation is a design
  decision, parked with its safety questions in the fork BACKLOG.
  Corrected record: threat-matrix Row 4 correction (cache-fix
  cd29e34).
