# BACKLOG — claude-worktime

Two grades: **ready** (decision-complete: design decided, verifier
named, done-criterion stated) and **parked** (carries its named missing
evidence). Items leave by commit ref or are dropped with a one-line
reason.

## Ready

Both entries below were found by the cache-fix fork while walking live
busts, and were booked THERE until 2026-08-06 — in a backlog no
claude-worktime session reads, while this file said "(empty)". They
moved here under that repo's standing rule ("the backlog closes
dispatchable": every open entry executable by someone who is not you,
in the repo where the work happens, without asking a question). Cross-
references below name cache-fix artifacts as EVIDENCE, never as work:
nothing here requires touching that repo.

- **READY — `previous_message_not_found` booked a hit, which the
  2026-07-31 resume-split fix's own contract says never happens.**
  Measured 2026-08-06 23:59:10Z. The Departed entry below shipped the
  split, and the cache-fix threat matrix records its contract in one
  line: `previous_message_not_found` never books a hit. That day it
  booked `k:"hit"` with cause `idle`, `cc` 215,873, `gap` 22,702 s
  (6h18m) against a 1h TTL, `mtok` 0 — an ordinary idle expiry rendered
  to the operator as a ❄ bust and a prevention target.
  **The fix held on the route it was built for and missed a second
  one.** The late-bind `other`-cause duplicate at 23:59:15Z WAS
  retracted by a `hit-retract` at 23:59:47Z — the machinery fired
  correctly and took the wrong duplicate. So this is not a regression
  of that fix; it is an entry path it never covered: the `idle` cause
  reaches the hit-booking path without passing the resume-split.
  Design: apply the split on CAUSE as well as on the late-bind route —
  a cold event whose transcript diagnostic is
  `previous_message_not_found`, or whose `gap` exceeds the TTL in force
  with `mtok == 0`, is a controlled cost and never a hit. Read the TTL
  from the session's own traffic where available rather than assuming
  3600.
  Verifier, red-first and two-sided: this event must book as a
  controlled cost and produce no ❄ bust; and a genuine mid-history bust
  in the same session window (2026-08-06 18:08:32Z, `mtok` 267,780,
  sub-minute gap) must STILL book as a hit. A guard that silences both
  is worse than none — it would hide the class this ledger exists to
  show.

- **READY — one event is booked TWICE with CONTRADICTORY classes, so
  every cost total derived from this ledger is inflated by an unknown
  factor.** Two measurements, one class:
  (1) 2026-08-06 17:39:59 / 17:40:08 / 17:40:16Z — the 204,513-token
  event appears as three `k:"hit"` rows whose transcript rows all carry
  the SAME `msgId` and `reqId`: one assistant message split across
  three transcript rows, booked once per row, none retracted. Total is
  204,513, not 613k.
  (2) 2026-08-06 23:59:10 / 23:59:47Z — the same 215,873 booked as
  `k:"hit"` cause `idle` (class BUST, a prevention target) and as
  `k:"cost"` cause `resume` (class CONTROLLED, explicitly not
  triageable). 431,746 attributed for 215,873 spent.
  Case (2) is why the dedupe is not just arithmetic: the duplicates
  disagree about WHAT KIND of event it was, so collapsing on
  (`msgId`, `reqId`) alone must silently pick a class.
  **DECIDED (operator, 2026-08-06) — NEITHER CLASS WINS.** Dedupe the
  COST so it counts once; keep both classifications; surface the
  disagreement as its own state rather than resolving it. Rejected,
  with reasons: "controlled wins" silently exempts a real bust that
  happens to coincide with a resume — silent under-reporting, the worst
  failure mode for this ledger; "bust wins" turns a controlled cost into
  a prevention target — loud, wasteful, and self-correcting on
  inspection, so strictly better than the first but still a guess. The
  chosen option is the three-answer rule applied to classification: a
  genuine ambiguity is its own answer, not a coin flip.
  Design: dedupe on (`msgId`, `reqId`), which is present in both
  sources; the surviving row carries every class seen for that key, and
  a row with more than one is rendered as a disagreement rather than as
  either class.
  Verifier: case (1) must count once and `--cold` must lose exactly
  those two duplicate rows while every genuinely distinct bust
  survives; case (2) must count 215,873 once and render as a
  disagreement, NOT as a bust and NOT as a controlled cost; and the
  23:59:15Z retraction must still apply.
  **Why this outranks its size: this ledger is where the cache-fix
  repo's cost numbers come from.** Its build-order ranking opens with a
  1,200,000-token figure derived from these counts. That figure is not
  re-derived here on one instance, but it now rests on a counter with
  two known duplication modes.

## Parked

(empty)

## Departed

- 2026-07-31: both founding items — zero-usage write skip and
  late-bind resume-split retract — built same day they were booked,
  red-first from the measured s-f94e53ce sequence (commit ref in this
  entry's own commit; `tests/replay-cold-detect.sh` 17/17; live ledger
  and the session's ❄ state retro-corrected with the shipped
  `hit-retract` mechanism).
