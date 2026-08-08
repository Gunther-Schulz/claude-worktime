# Brief — `_do_rotate` corruption tolerance + the tests that pin it

Dispatched 2026-08-08. Diagnosis in this file is established; verify at the
cited lines rather than re-deriving it.

Working copy: `/home/g/dev/Gunther-Schulz/claude-worktime`.
Base check (two reads, both required):
`git merge-base --is-ancestor a3ec941 HEAD` and
`git log --oneline a3ec941..HEAD` — expected: base contained, nothing on top.

> Corrected 2026-08-08 after execution: this file originally named `3546591`,
> the HEAD from before the dispatcher committed the booking that carries this
> very brief. The executing agent ran the check, got `a3ec941` on top of the
> stated base — the third state, "base contained WITH commits on top" — and
> surfaced it rather than rebasing silently, which is the correct handling.
> The brief's base ref is written AFTER the dispatcher's own commits land, not
> before; writing it from the pre-commit HEAD is the error to avoid.
Any other state halts as a gap (foreign commits on top, dirty tree over a
stale base). Never rebase, never discover a base by guesswork.
Scratch: your OWN scratchpad. Do not write under the dispatcher's.

## Grounding basis — read before building; the report cites what was read

- the executor skill (`dispatch-guards:executor`) — **load FIRST**; conduct,
  under-report principle, report discipline live there.
- `tests/replay-cold-corrupt-log.sh` — the test idiom to copy (standalone
  bash, `XDG_DATA_HOME` sandbox, `printf` fixtures, `PASS:`/`FAIL:` lines,
  exit code = failure count). Its header comment is also the normative
  statement of the defect CLASS you are extending to a second call site.
- `claude-worktime.sh:433` — `_safe_log()`, the existing corruption-tolerant
  reader (`jq -Rc 'fromjson? // empty'`). This already exists; you are
  applying it, not inventing it.
- `claude-worktime.sh:2636-2745` — `_do_rotate()`, the function to change.
- `claude-worktime.sh:1159-1160` — the read path that already does this
  correctly (plain `jq -s` first, `_safe_log` on failure). Precedent for the
  fallback shape.

## Background (established 2026-08-08; verify at the cited lines)

`activity.jsonl` holds 46 malformed lines, all written in a 13-minute window
on 2026-04-01 (23:13:40–23:27:10). Cause: commit `6f91aa5` ("Log cumulative
session cost on prompt/response events", 23:13:22) extracted
`total_cost_usd` with

    tmp="${_STDIN_JSON#*\"total_cost_usd\":}"
    HOOK_COST="${tmp%%[,\}]*}"
    [ "$HOOK_COST" = "$_STDIN_JSON" ] && HOOK_COST=""

When the key is ABSENT, `#*pattern` leaves `tmp` unchanged, `%%[,\}]*` then
cuts at the first `,` or `}` yielding an unbalanced `{"session_id":"…"` —
which the writer interpolated as `,"cst":<fragment>` into a `printf` whose
format ends `%s}\n`. The fragment's opening brace consumed the record's own
closing brace. The absence guard on the third line cannot fire, because it
compares the ALREADY-TRUNCATED value against the full blob. Reverted by
`910a6c4` at 23:30:14. **The writer is fine today — no corrupt line exists
after 2026-04-01.** Do not "fix" the writer; that is not the work.

Consequence, which IS the work: `_do_rotate` reads the log with plain `jq`.

- `:2654` uses `jq -sc` (slurp) for summary generation — must parse the whole
  file, dies at the first bad line (exit 5), `|| summary_error="true"` fires,
  rotation returns without archiving. This has happened **1,052 consecutive
  times** since 2026-04-01 (`.rotation_errors` holds 1,052 identical lines,
  one kind only — the count/mismatch and rewrite branches have never fired).
- Result: last archive is `activity-2026-03-31.jsonl`; the live log's first
  record is 2026-04-01 00:00:04 and it has grown to 83 MB / 559k lines.
- The failure is currently fail-SAFE for data: the rewrite reads at
  `:2709-2713` use `|| rewrite_error=…`, and jq's exit 5 trips that guard, so
  the log is never rewritten. Preserve that property.
- **`:2649` is the exception and the latent hazard.** `old_entries=$(jq -c …
  "$LOGFILE" 2>/dev/null || true)` — streaming jq emits every record BEFORE
  the bad line, then dies; `|| true` discards the exit code. Measured against
  the live log: **3,964 lines emitted against 351,753 valid event records.**
  The `[ -z "$old_entries" ] && return` guard passes on that truncated
  prefix. Today nothing consumes it because `:2654` aborts first — but
  `:2691` (`echo "$old_entries" >> "$archive"`) sits BEFORE the rewrite guard,
  so repairing `:2654` alone would start appending a 1.1% prefix to the
  archive on every rotation.

The class is already known and already fixed ONCE: `tests/replay-cold-corrupt-log.sh`
(2026-07-28) pins exactly this for the `--cold` path. The identical defect in
`_do_rotate` was never covered — that gap is what you are closing.

## The settled design — implement exactly this, do not redesign

**(1) Make every `_do_rotate` read corruption-tolerant.** Route the log reads
at `:2644`, `:2649`, `:2654`, `:2709`, `:2710`, `:2711`, `:2713` through
`_safe_log` (`:433`). Follow the precedent at `:1159-1160`: attempt the plain
`jq` first and fall back to `_safe_log` on non-zero exit, OR read via
`_safe_log` unconditionally — your call between those two shapes ONLY, and
state which you chose and why in the report. Both preserve the existing
semantics of each filter; do not change any filter's logic.

**(2) `:2649` must not silently truncate.** Replace `|| true` with the same
hard-error treatment the rewrite path uses at `:2715-2721`: a read failure
writes a distinct line to `.rotation_errors` and returns WITHOUT archiving.
After (1) this path should no longer fail on corrupt input — (2) is the guard
for every other read failure, and it must not be reachable-but-silent.
Distinct message text, not a reuse of an existing one.

**(3) New test `tests/rotation-corrupt-log.sh`.** Same idiom as
`replay-cold-corrupt-log.sh`. Assert, in ONE fixture that contains old
entries (before the rotate cutoff) spanning at least two projects, one
corrupt line among them, and current entries after the cutoff:
  - the archive file is created and contains EVERY valid old record —
    specifically including records positioned AFTER the corrupt line (this is
    the assertion the current code fails);
  - a `summary` record is written per project;
  - the live log after rotation retains the current entries and the new
    summaries;
  - no valid record is lost across archive + live log combined (count them).

**(4) New test `tests/rotation-no-silent-truncation.sh`.** Construct the
truncation directly: a fixture whose corrupt line sits EARLY with many valid
old records after it. Assert the archive is either complete or absent — never
a prefix. A skip/scope test over a CLEAN fixture would pass against code that
ignores corruption entirely, so the fixture must be dirty and the in-scope
case must be shown to fire in that same state.

**Red-first is mandatory and is the deliverable's proof.** Both tests run
against the CURRENT `_do_rotate` (before your change) and their real output
goes in the report verbatim. If a test does not go red before the fix, that
test is not pinning the defect — say so and stop rather than adjusting the
assertion to match.

## Out of scope — do not touch

- The log writer / `_read_hook_stdin` (already correct since `910a6c4`).
- The operator's live `~/.local/share/claude-worktime/activity.jsonl` — do not
  read-modify-write it, do not repair it, do not rotate it. Tests use their
  own `XDG_DATA_HOME` sandbox. **Never run `claude-worktime.sh` in a way that
  writes the real log.**
- `{project_total}` / `calc_active` / the `.p` label-vs-key split — booked
  separately in `BACKLOG.md`, carries an unresolved design sub-decision.
- `BACKLOG.md` — the dispatcher owns it this turn.
- Any rotation-staleness ALARM or health check — a separate operator decision.

## Verifier (in order; real output pasted in the report)

1. Red-first: both new tests against current `_do_rotate`, verbatim output.
2. Green after: both new tests pass.
3. No regression: every existing test in `tests/` still passes — run each,
   paste the PASS/FAIL line for each. Note `COLD_NOTIFY` handling is internal
   to those suites; do not alter it.
4. `bash -n claude-worktime.sh` clean.

## Write boundaries

Own: `tests/rotation-corrupt-log.sh`, `tests/rotation-no-silent-truncation.sh`,
and `_do_rotate` in `claude-worktime.sh` (lines ~2636-2745 only). Nothing else
in that file. Targeted `git add <those paths>`, never `-A`. Commit unpushed;
pushing is the dispatcher's act. Never amend — always a new commit.

Commit title pattern: lowercase, no prefix tag, describing the change as a
statement (repo idiom — see `git log --oneline`). Trailer, exactly:

    Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>

## STOP signals (halt the item, finish the independent remainder, return the question with its evidence)

- No red demonstrable for either test against the current code.
- The fix would alter rotation behavior this brief did not name.
- A spec gap or contradiction between this brief and the code at the cited
  lines.
