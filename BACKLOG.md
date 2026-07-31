# BACKLOG — claude-worktime

Two grades: **ready** (decision-complete: design decided, verifier
named, done-criterion stated) and **parked** (carries its named missing
evidence). Items leave by commit ref or are dropped with a one-line
reason.

## Ready

- **Skip zero-usage tokens/state writes.** Evidence (2026-07-31,
  s-f94e53ce): the compact-completion statusline render logged a
  `"type":"tokens"` entry with `cr=0,cc=0,ui=0` and rewrote the cold
  state with ctx=0. That single record (a) reset the idle-gap clock —
  a ~10h idle resume measured as a 32min gap, so the idle classifier
  missed, and (b) zeroed `cs_prev`, so the compact-skip predicate
  (`cc ≥ 0.6×prev && cr ≤ prev/5`) fired on prev=0 and booked the
  post-compact first write (cc=51061) as a false `k:"hit"`
  (cause "other"). Design: `cr+cc+ui == 0` means "no API usage data",
  never a real measurement (no API response has zero total) — skip
  both the tokens append and the cold-state rewrite on that
  condition; the idle clock and prev-ctx then keep the last real
  turn's values. Verifier: regression test replaying the measured
  sequence (355k session → zero render → 51k first write) asserting
  no hit is booked and the gap reads from the last NONZERO entry;
  existing suites stay green. Done when the replayed sequence books
  nothing.
- **Apply the resume-split at the late-bind cause upgrade.** Evidence
  (same event): at detection the busting turn's transcript entry was
  not yet flushed → cause "other" → the `previous_message_not_found`
  split (change 2) never ran and a hit was booked; the late-bind
  window (`COLD_LATE_BIND_SECS`) then read the flushed entry and
  wrote `previous_message_not_found` straight into `cs_lastcause` —
  the ❄ token displayed a resume-class cause the split's contract
  says never renders there. Design: when the late-bind read returns
  `previous_message_not_found`, retract the booked hit instead of
  adopting the cause — decrement `cs_count`, zero
  `cs_lastcc`/`cs_lasthit_t` (accepting loss of an older hit's ❄
  display; the count only ever un-inflates), and append a
  `k:"resume"` record plus a `k:"hit-retract"` marker so the
  append-only ledger self-corrects and `--cold` readers can drop the
  matching hit. Verifier: regression test driving the race (hit
  booked as "other", late entry carries previous_message_not_found)
  asserting retraction + both records; done when the ❄ token never
  renders that cause. Note: the 2026-07-31T08:29:04Z `k:"hit"`
  record for s-f94e53ce in the live ledger is the known false
  positive this item retracts the class of — fire-rate reads before
  the fix land should exclude it by hand.

## Parked

(none)
