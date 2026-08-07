# BACKLOG — claude-worktime

Two grades: **ready** (decision-complete: design decided, verifier
named, done-criterion stated) and **parked** (carries its named missing
evidence). Items leave by commit ref or are dropped with a one-line
reason.

Events are named by UTC timestamp, never by session id: this repo is
public and the machine-wide push-side leak scan does not reach it
(known gap, booked in the cache-fix fork's BACKLOG as a pointer to the
dotfiles design). Any fixture added here is synthesized or scrubbed by
hand for the same reason.

## Ready

### The cold detector — one root cause behind three entries (designed 2026-08-07, corrected same day by a fresh-context vet)

The three entries below were booked separately, on separate days, from
separate symptoms. Designing them together showed they are one defect:

**The cold detector has no notion of an API CALL.** It has a tap, a
state file and a ledger, and not one of the three carries the identity
of the call it is describing. Everything else follows mechanically:

- the same call is measured several times → sometimes the "previous
  turn" baseline IS the same call (the 2026-08-07 01:00:55Z false ❄),
  and the ledger books one event repeatedly (17:40, 23:59, 03:32);
- no call identity in the ledger → duplicates cannot be collapsed
  afterwards, and two duplicates that disagree about CLASS cannot even
  be recognised as one event;
- no "nothing was lost" outcome in the cause ladder → a false fire is
  forced to render as an unknown-cause bust, so the label becomes a
  consequence of the bug rather than evidence about it.

**A fresh-context vet re-derived every fact and verifier below on
2026-08-07 and overturned the build order.** Its corrections are folded
in and marked `[vet]`. The headline reversal: the identity work is NOT
the prerequisite it was written as, because identity is null on exactly
the renders that duplicate. The cheap per-session fix does the work.

**Facts, each read rather than reasoned:**

- **F1 — the live tap is the statusline stdin payload, not transcript
  rows.** `claude-worktime.sh:1259-1276` extracts sixteen fields from
  `_STDIN_JSON`, among them
  `.context_window.current_usage.{cache_creation_input_tokens,
  cache_read_input_tokens,input_tokens}`. **None of the sixteen is a
  CALL identity** — `[vet]` corrected from an earlier "none is an
  identifier", which was false: `.model.id` and `.transcript_path` are
  identifiers, just not of the call. The detector runs once per
  statusline RENDER, and CC renders many times per call.
  **OPEN, and it decides whether Layer 1 exists at all:** does the RAW
  payload contain a call id that simply is not extracted? One live
  `_STDIN_JSON` dump answers it; no dump exists on disk and the script
  keeps none. Operator decision — it needs a one-shot statusline
  wrapper.
- **F2 — a dedupe guard already exists here, value-keyed and GLOBAL.**
  `claude-worktime.sh:1640-1652`: `token_prev="${LOGDIR}/.token_prev"`
  — one file for every session (verified on disk beside the
  per-session `.cold_<sid>` files). The block runs only when `(cr,cc)`
  differs from the last pair written there. `[vet]` **Triple-confirmed
  live**: a foreign session's write sits between the two identical
  renders of the 01:00 pair, inside the 17:40 triple, and inside the
  03:32 pair. In EVERY observed duplicate the `(cr,cc)` values are
  identical within the session — so the global file is the only reason
  any of them got through.
- **F3 — ledger rows carry no message or request identity.** Keys on a
  cold hit row: `cause, cc, concur, ctx, flight, gap, k, mdl, mtok,
  pblk, s, t, type, ubytes`. No `msgId`, no `reqId`. `[vet]` The
  writer emits DIFFERENT key sets per row kind — `k:"cost"` (≈2035),
  `hit-retract` (≈1951) and `hit-cause` (≈1979) each differ — so any
  "every hit|cost|hit-retract row gains X" must be written per kind.
- **F4 — the contradictory-class pair RECURRED, and the retraction did
  not fire.** 2026-08-07 03:32:02Z books `k:"hit" cause:"idle"
  cc:427535 ctx:427537 mtok:0 gap:4741`; 03:32:05Z books `k:"cost"
  cause:"resume" cc:427535 gap:3`. No `hit-retract` in the window
  (positive control: the 23:59:47Z retract at `t:1786060787`).
  `[vet]` Two additions, both load-bearing:
  (a) **why** no retract — the late-bind branch requires
  `cs_lastcause = "other"` (≈1878), and the first row set it to
  `"idle"`, so it can never fire;
  (b) **decisive** — the transcript rows for that event at 03:31:59Z
  and 03:32:01Z, both BEFORE the ledger's idle booking, already
  carried `cache_miss_reason.type = previous_message_not_found`. The
  idle short-circuit at ≈1705 decided without reading a diagnostic
  that was already on disk. This narrows (A)'s correct fix.
- **F5 — `mtok` is a degraded default.** Whole-ledger histogram
  `[vet]`: `other` 43 / `idle` 9 / `model` 3 all `mtok:0`;
  `messages_changed` 30 / `tools_changed` 4 / `system_changed` 4 /
  `model_changed` 4 all non-zero. TRUE **by sample, not by
  construction** — the code's own comment (≈1720-1723) says
  `unavailable` and `previous_message_not_found` arrive BARE, so a
  RESOLVED cause can legitimately land `mtok:0`; none has yet. The
  conclusion (never key on `mtok == 0`) holds either way. Aside: the
  comment at ≈1726 still says `model_changed` was "never observed";
  four rows now exist — stale comment in the code.
- **F6 — CORRECTED `[vet]`: the ledger is NOT append-only, and the
  count moves.** `--cold` prints **43** unreadable lines today, not 45,
  because `AUTO_ROTATE` (≈221, `_do_rotate` ≈987) REWRITES the live
  file daily. The earliest cold row is 2026-07-28, not March. An
  earlier version of this section said "ledger rows are safe
  (append-only, back to March)" — **wrong on both halves, and it was
  the basis for not freezing evidence.**
  **NEW LEAD, untested:** `.rotation_errors` holds 1,022 identical
  `WARNING: rotation summary generation failed, skipping archive`
  lines. A rewriting rotation that has failed a thousand times is the
  first suspect for the torn lines. The vet did NOT test this and did
  NOT classify the 43 lines.

**Evidence — PARTIALLY FROZEN 2026-08-07, and the gap is named.**
Frozen to `~/.claude/cold-design-evidence-2026-08-07/` (machine-local,
mode 0700, untracked, holds raw ids by design): all 125 cold rows, the
four event windows, `.rotation_errors`, and a 3.6 MB archive of the 24
candidate transcripts. **NOT frozen, and required:** the replay
verifiers need STDIN PAYLOAD SEQUENCES, which no artifact on disk
carries and which cannot be reconstructed from ledger rows or
transcripts `[vet]`. Capturing them is a prerequisite for every replay
verifier below and is not yet designed.

**Build order — REVISED `[vet]`.**

1. **`--rows` first** (last entry below). Clean, smallest, and it is
   the tool every other verifier here needs.
2. **Per-session `token_prev`, standalone.** Was filed as Layer 2's
   degraded fallback; it is in fact the whole fix for every observed
   case (F2). No prerequisite.
3. **(A), with its gap leg struck.**
4. **Layer 3a**, after 2.
5. **Layer 1 / (B)** — re-justified on what remains, or dropped.

---

- **READY — `--rows`: a line-robust ledger query mode.** There is no
  query surface, so every investigation hand-rolls one and re-earns
  the two hazards this repo already solved: the unreadable lines (F6)
  and the 81 MB size. Measured 2026-08-07: an ad-hoc scan written
  during this design pass did both wrong at once — one `jq` process
  per line over the whole file — and was killed at 120 s having
  answered nothing.
  Design: one `--rows` mode taking a time window and an optional kind
  filter, emitting matching records as JSONL through the SAME
  line-robust reader `--cold` already uses, so unreadable lines are
  skipped AND counted rather than fatal.
  Verifier: `--rows` over the 03:32 window returns the hit and cost
  rows and reports the unreadable count; the same window through a
  naive whole-file `jq` still dies. `[vet]` reviewed: clean,
  red-first, two-sided, no objection.

- **READY — per-session `token_prev` (the actual false-❄ fix).**
  Root cause, 2026-08-07 01:00:55Z: the predicate
  (`cc >= 0.6 x prev_ctx` AND `cr <= prev_ctx / 5`, ≈1694) compared a
  render against another render of the SAME call. `[vet]` verified the
  arithmetic from the tokens rows: `t=1786064427` cr=0 cc=39,711
  (ctx 39,713); `t=1786064440` and `t=1786064455` both cr=39,711
  cc=335,933 (ctx 375,646). The :440 render wrote `cs_prev=375,646`;
  at :455 the predicate passed by wide margins (335,933 ≥ 225,388;
  39,711 ≤ 75,129). **The threshold is fine; the baseline was not.**
  Design: move the `(cr,cc)` guard from the global
  `${LOGDIR}/.token_prev` to `.token_prev_<sid>`. That alone closes
  every observed duplicate, because all four sets carry identical
  `(cr,cc)` within their session and were let through only by a
  cross-session interleave (F2).
  Verifier, red-first: replaying the 01:00 render sequence with a
  foreign session's write interleaved must produce NO event against
  the new code and one 336k hit against the old. Sibling control —
  the cache-fix fork's `tools/cold-events.mjs` reports no event at
  01:00:55Z on the same transcript. **`[vet]` warning: that sibling
  reading has already drifted** — it reported 13 calls / 0 events
  yesterday and 49 calls / 1 event today, because the transcript grew.
  The load-bearing half (no event at 01:00:55Z) still reproduces; cite
  only that half, and cite it against the frozen transcript archive,
  not the live file.
  **Closure criterion, corrected `[vet]`:** "the two instruments agree"
  is ill-defined — `cold-events.mjs` classes the 03:32 event as an
  idle bust while (A) will class it a controlled cost, so they must
  DISAGREE there by design. Closure ranges over the 01:00 event only.

- **READY — (A): consult the diagnostic BEFORE the idle
  short-circuit.** Measured 2026-08-06 23:59:10Z: `previous_message_
  not_found` booked a `k:"hit"` with cause `idle`, `cc` 215,873,
  `gap` 22,702 s — an ordinary idle expiry rendered as a ❄ bust and a
  prevention target, which the 2026-07-31 resume-split's own contract
  says never happens. The split held on the route it was built for and
  missed this one: the `idle` cause reaches hit-booking without
  passing it.
  Design: the residual branch's `_cw_diag` read (≈1766-1770) moves
  AHEAD of the idle/model short-circuit, so a transcript diagnostic
  that is already on disk is consulted before a cause is assumed. A
  cold event whose diagnostic is `previous_message_not_found` is a
  controlled cost, never a hit. Basis: F4(b) — the diagnostic WAS on
  disk before the booking, at both named events.
  **The `gap > TTL` leg is STRUCK `[vet]`, and this is blocking-grade.**
  It would silence the entire idle class (9 rows), and idle cache
  expiry is the canonical PREVENTABLE bust — the very thing the cold
  guard warns about before it happens. The named case does not need
  the leg: all three `cc=215873` transcript rows carry
  `previous_message_not_found`, so the diagnostic leg alone catches
  it. (Struck for OVER-FIRING, unlike the `mtok == 0` leg struck
  earlier for being a degraded default. Also moot now: "read the TTL
  from the session's own traffic" names a mechanism that does not
  exist — `CACHE_GUARD_TTL` is 0 by default with a 3600 fallback.)
  Verifier, red-first and THREE-sided `[vet]`: the 23:59 and 03:32
  events must book as controlled costs with no ❄; the genuine
  mid-history bust at 2026-08-06 18:08:32Z (`mtok` 267,780, gap 7,
  `messages_changed`) must STILL book as a hit; and — the control the
  earlier version lacked — a genuine idle expiry with `gap > TTL` and
  no resume diagnostic must ALSO still book as a hit. The 18:08 case
  cannot serve as that control: its gap is 7 s, so it structurally
  cannot detect over-firing of a gap-based leg.
  **Correction `[vet]`:** an earlier version called 18:08:32Z the
  "same session window" as the 23:59 event. It is a different session.
  **Sequencing `[vet]`:** (A) converts the 23:59 and 03:32 idle rows
  into controlled costs — exactly the rows 3b's verifier names as
  "must render as a disagreement". Ship (A) before 3b's fixture is
  captured and 3b's verifier dissolves. The freeze above covers the
  ledger rows; the stdin sequences it needs are still missing.

- **READY — Layer 3a: a fourth answer, "the cache was fine."** The
  ladder runs idle → model → residual, assuming a cold rewrite
  happened and only asking why; the residual names a real cause only
  when `cache_miss_reason` is readable, and at 01:00:55Z the
  transcript contains none, because there was no miss. So a false fire
  can only ever be labelled `other` — the label is a CONSEQUENCE of
  the false fire, not evidence about it.
  Design: before asking WHY, ask WHETHER. The discriminator is the
  surviving read, `ctx - cc`, compared against **the predecessor's
  `ctx`** — `[vet]` CORRECTED from "the predecessor's `cc`", which
  coincides at 01:00 only because that predecessor's `cr` was 0.
  Implemented literally against `cc`, any healthy cached predecessor
  (cr 200k, cc 5k) makes a growth event fail the growth test and fall
  through to the bust ladder.
  `[vet]` Second consequence: the predecessor's `ctx` is not in the
  state file — `cs_lastcc` (≈1662/1985) is the last HIT's `cc`, not the
  previous turn's context — so this needs a new state field plus
  old-format migration, which the earlier version did not mention.
  Arithmetic verified `[vet]`: 39,713 vs 39,711 → GROWTH;
  427,537−427,535 = 2 → total loss; 315,821−300,597 = 15,224 → real
  bust.
  This ships as a distinct outcome, not a silent suppression: after
  the per-session fix a growth event should not reach the ladder at
  all, so a `no-miss` verdict appearing in the ledger signals a
  remaining hole — which is its value.

- **READY — a DOCTOR verdict over the ledger's own health. There is
  none, and that is the emptiest cell in the instrument matrix.**
  Measured 2026-08-07 by an inventory across all three repos: 100
  instruments, and `worktime_ledger` is read by 14 of them — the most
  of any data source — of which 10 are QUERY and **0 are DOCTOR**.
  Every instrument asks the ledger questions; nothing asks whether the
  ledger is sound. Compare `filesystem_state` (16 DOCTOR) and `config`
  (7).
  What that blindness has cost, all of it found by accident in one
  night: 1,022 consecutive rotation failures in `.rotation_errors`
  against a rotation that REWRITES the live file; 43 torn lines nobody
  has classified; one event booked three times; two events booked
  under contradictory classes; and a `hit-retract` mechanism with an
  entry path it silently misses. Not one of these announced itself.
  Design: a `--doctor` mode emitting three-answer verdicts (verified
  clean / verified broken / COULD NOT VERIFY, never silence), one per
  check: (a) unreadable-line count is 0, else broken with the count;
  (b) `.rotation_errors` is empty or its newest line predates the last
  successful rotation, else broken; (c) no two cold rows share
  `(t, cc)` with different `k` or `cause` — the contradictory-class
  detector; (d) no `k:"hit"` row whose transcript diagnostic at that
  stamp reads `previous_message_not_found` — the (A) class, as a
  standing check rather than a one-time fix; (e) state files
  `.cold_<sid>` parse and carry 7 fields.
  Verifier, red-first against the FROZEN ledger copy at
  `~/.claude/cold-design-evidence-2026-08-07/`: (a) goes red at 43;
  (b) red at 1,022; (c) red on the 17:40 triple and both contradictory
  pairs; (d) red on the 23:59 and 03:32 idle rows. Each must go GREEN
  on a hand-built clean fixture, so a check that can never pass is
  caught before it ships.
  Done when all five have been shown red on real data and green on the
  clean fixture, and `--doctor` is wired into whatever runs daily.

- **READY — the torn-line writer.** `--cold` reporting `43 unreadable
  line(s) skipped` is the 2026-07-28 three-answer fix working: the
  READER is fine. But the count is wallpaper, nothing classifies what
  is unreadable, and `.rotation_errors` shows 1,022 consecutive
  rotation failures against a rotation that REWRITES the live file
  (F6) — the first suspect, untested.
  Design: one classifier pass reporting, per unreadable line, its byte
  length and whether it is a truncated prefix of a valid record, two
  records concatenated, or interleaved bytes from two writers — then
  fix the writer producing the dominant shape. Read once, line by
  line, never a process per line.
  Verifier `[vet]` corrected: anchor to a FROZEN copy of the ledger,
  not the live file — "names all 45" was already false (43 today)
  because the anchor mutates. Against the frozen copy: every
  unreadable line carries a shape with no unclassified remainder; and
  a concurrency probe (N renders racing one append) adds zero new
  unreadable lines against the fixed writer where it adds at least one
  against the old.

## Parked

- **PARKED — Layer 1 (call identity on every cold record) and (B) (the
  contradictory-class dedupe). Named missing evidence and design,
  both.** Booked READY on 2026-08-07 and demoted the same day by the
  vet, which found the scheme inoperative on all three cases it was
  written for.
  **Why (B) cannot pass as written:** in every named case the
  duplicate rows ARE the identity-null rows — case (1) 2 of 3 null,
  case (2) only the retract row carries identity, case (3) the idle
  row null. Dedupe on `(mid,rid)` collapses none of them, and legacy
  rows never gain identity retroactively. The shared-identity claim
  itself IS verified (case (1)'s three rows share one pair; case (2)'s
  three share another) — it is the ROWS that lack it, not the calls.
  **Why Layer 1 cannot supply it as written:**
  - `_cw_diag` lives only in the else/residual branch (≈1710-1734), so
    it never runs on an `idle` or `model` hit — false for 12 of the
    ledger's hit rows, including F4's own. "The transcript entry is
    already being read on a hit" is wrong.
  - Layer 2's polluted baseline is written by a NON-hit render
    (`t=1786064440`), so identity would be needed on EVERY render,
    which contradicts the script's own cost discipline about putting
    `jq` on the common path.
  - UNDIAGNOSED: the matching transcript entry for the 17:40 event was
    on disk from 17:39:59.053Z, yet the anchored read returned empty
    at both 17:39:59 and 17:40:08. That is not "not yet flushed", and
    nobody knows what it is.
  **Named missing pieces, each a spec:** (1) the raw `_STDIN_JSON`
  dump that says whether a call id is already in the payload — if it
  is, Layer 1 collapses to a field extraction and this un-parks
  immediately; (2) a diagnosis of the empty anchored read; (3) a
  chosen mechanism for retroactive identity (a late-bind `k:"hit-id"`
  marker analogous to `hit-cause`, a legacy fallback key, or a
  replay-from-fixture verifier) — none chosen; (4) the stdin payload
  capture format, without which no replay verifier can exist; (5) 3b's
  output representation — `mode_cold` (≈2816-2827) emits a fixed
  tsv/raw shape with no slot for "every class seen", and the ❄
  token's rendering of a disagreement is undefined.
  The operator decision in (1) is the cheapest and unblocks the most.

## Departed

- 2026-07-31: both founding items — zero-usage write skip and
  late-bind resume-split retract — built same day they were booked,
  red-first from the measured 2026-07-31 sequence (commit ref in this
  entry's own commit; `tests/replay-cold-detect.sh` 17/17; live ledger
  and the session's ❄ state retro-corrected with the shipped
  `hit-retract` mechanism).
