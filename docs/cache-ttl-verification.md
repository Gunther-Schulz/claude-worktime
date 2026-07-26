# Prompt-cache TTL — how it was determined, and how to re-verify

The cold-cache features (the `❄N` statusline counter and the
UserPromptSubmit cold guard, `CACHE_GUARD_TTL`) depend on one fact:
**how long the prompt cache lives, and how Claude Code itself decides
the cache has expired.** There is no API to query either — the value
is hardcoded in the Claude Code CLI, so it must be re-verified after
CLI updates. This file records what was found, where, and the exact
commands to check it again.

## Verified facts (Claude Code 2.1.215, Linux, 2026-07-20)

Binary inspected: `/opt/claude-code/bin/claude` (Bun-compiled ELF;
the minified JS is embedded and searchable with `strings`/`grep -a`).

**1. The client picks the TTL itself — 1h for main-thread requests:**

```js
if (i.querySource.startsWith("repl_main_thread") || i.querySource === "sdk")
    soi(ae === "1h" ? 3600000 : 300000);   // ms
...
function soi(e){ kt.lastMainThreadCacheTtlMs = e }
function Ukr(e){ kt.lastApiCompletionTimestamp = e }
```

The TTL (`"1h"` → 3600000 ms, else 300000 ms = the API's 5-minute
default) is sent by the client in `cache_control` and stored locally,
together with the timestamp of the last completed API request.

**2. "Is my cache still warm?" is pure clock math — no server query:**

```js
function Ybs(e = Date.now()){
    ...
    let t = Bkr();                 // lastMainThreadCacheTtlMs
    if (t === null) return !1;
    return e - zbs < t * 0.9;      // warm ⟺ elapsed < TTL × 0.9
}
```

This is what drives the resume-time "conversation is old, consider
compacting" behavior. It works because the API's TTL is a contract:
cache entries live *at least* the TTL and refresh on every use — so
under the TTL the cache is guaranteed warm; past it, assume cold
(occasionally pessimistic, never wrong in the expensive direction).

**3. Cold detection after the fact is usage arithmetic:**

```js
function Hfy(e){
    if (!e) return null;
    let t = e.message.usage,
        r = t.input_tokens ?? 0,
        n = t.cache_creation_input_tokens ?? 0,
        o = t.output_tokens ?? 0;
    return r + n + o > xfy ? "cache_cold" : null;
}
```

The only cache visibility the API exposes is the `usage` block of an
already-completed (already-paid) request — there is no endpoint to ask
"is this cache entry alive?". claude-worktime's `❄` counter uses the
same class of check (big `cache_creation` with near-zero `cache_read`
relative to the previous context).

## How to re-verify after a CLI update

Minified identifiers (`soi`, `Ybs`, `Hfy`, …) change every build.
The stable search anchors are the **string literals and numeric
constants**, which survive minification:

```sh
# Find the real binary: `command -v claude` may point at a wrapper
# *script* (realpath won't resolve it — cat it and follow the exec line).
# Here: /usr/bin/claude execs /opt/claude-code/bin/claude.
BIN=/opt/claude-code/bin/claude

# 1. TTL selection — expect: ==="1h"?3600000:300000
command grep -aoE '.{80}==="1h"\?3600000:300000.{80}' "$BIN"

# 2. Client-side TTL state — expect setter/getter pairs
command grep -aoE '.{60}lastMainThreadCacheTtlMs.{60}' "$BIN" | head -3
command grep -aoE '.{60}lastApiCompletionTimestamp.{60}' "$BIN" | head -3

# 3. The warm check — expect: return <elapsed> < <ttl> * 0.9
command grep -aoE 'return [a-zA-Z$_]+-[a-zA-Z$_]+<[a-zA-Z$_]+\*0\.9' "$BIN"

# 4. Post-hoc cold classifier — expect the usage-sum function
command grep -aoE '.{80}"cache_cold".{200}' "$BIN" | head -2
```

Interpretation guide:

- **All four hit** → nothing changed; `CACHE_GUARD_TTL=3600` stays valid.
- **`3600000:300000` changes** (e.g. new constants) → update
  `CACHE_GUARD_TTL` to the new main-thread value (ms ÷ 1000).
- **Anchors vanish entirely** → the mechanism was rewritten; fall back
  to the empirical check below before trusting the guard's default.

`command grep` bypasses grep aliases (e.g. ugrep, which rejects some
of these patterns).

## Empirical fallback (works regardless of CLI internals)

claude-worktime logs every cold event as
`{"type":"cold","k":"hit"|"warn","gap":<seconds>,"ctx":<tokens>}`
(kept 90 days across rotation). Correlating `gap` on `k=hit` events
(actual cold rewrites) against warm requests reveals the effective TTL
cliff from your own usage — no binary inspection needed:

```sh
jq -s '[.[] | select(.type=="cold" and .k=="hit") | .gap] | sort' \
    ~/.local/share/claude-worktime/activity.jsonl
```

The smallest observed `gap` on a hit approximates the real-world TTL
upper bound; if hits start appearing at gaps well under 3600s, the
CLI (or the API tier) has moved to a shorter TTL and
`CACHE_GUARD_TTL` should be lowered to match.

## Open: elapsed time is not the only thing that busts a resume

**Observation (2026-07-26 23:57).** Quit the CLI, waited ~1 minute,
resumed the session → full 139k rewrite at `gap=45s`, three orders of
magnitude inside the TTL. So the warm check above (`elapsed < TTL×0.9`)
answers a *different* question from "will my next request hit cache":
it is necessary, not sufficient. A resume can be cold while the entry
is provably alive.

The cache-fix proxy's `prefix-diff` caught the mechanism —
`tools=match, system=DIFFER` — meaning the system prompt differed
across the process restart, which invalidates from byte zero. Which
block, and whether it was a genuinely dynamic field (date/time context,
session-scoped identifiers) or something reconstructible, was NOT
determinable: the tooling hashed the system array as one opaque value.

**What changed since.** `prefix-diff` was rebuilt
(`claude-code-cache-fix` @ `fc432bf`) to store per-block system text
with labels, full tool schemas, top-level params, and a per-message
hash chain — and to key snapshots on the session-id header rather than
on a hash of the system prompt (the old key moved when the thing it
indexed changed, so the most important busts wrote no diff at all).
Every diff now also appends to `<key>-events.jsonl`, which is not
overwritten. The summary line names the culprit directly, e.g.
`cause=system[2:env@1847]` or `cause=tools[Bash:schema]`.

**Test to run (not yet done).**

1. Start a session, let it build ≥50k context, note the time.
2. Quit the CLI. Wait ~1 min (far inside the TTL).
3. Resume the same session, send one trivial prompt.
4. Read the verdict:

```sh
claude-worktime --cold --raw | tail -1
journalctl --user -u cache-fix-proxy --since "-5min" --no-pager \
    | grep prefix-diff | tail -3
# byte-level, survives later busts:
ls ~/.claude/cache-fix-snapshots/s-*-events.jsonl
```

Repeat twice more, and once with all MCP servers fully connected
before resuming (a late-connecting server changes the tools array —
`tools_changed` is a confirmed real bust cause, observed 2026-07-27
00:15 as `cause=tools[Bash:schema]`, 225k).

**What the outcomes mean.** Same block every time, dynamic content →
resume is structurally cold and the guard's elapsed-time gate is the
wrong model for resumes; it should warn on resume regardless of gap.
Varying or absent → per-case, and the current design is right but blind
to this class. Either way the answer belongs here, and in
`docs/cachebust-runbook.md` if it yields a new controlled cause.

**Do not restart `cache-fix-proxy` to investigate this while a session
is live** — that is itself a bust (225k, 2026-07-27 00:15). Extension
and config changes wait for a session boundary.
