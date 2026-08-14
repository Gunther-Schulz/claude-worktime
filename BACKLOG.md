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

- **READY — `other` splits cleanly into TWO classes and the ledger already
  carries the discriminator: a TOTAL miss (`cr == 0`) is genuinely causeless,
  while every event that had a real `cache_miss_reason` was a PARTIAL miss.
  Name the first class instead of calling it `other`.** Requested by the
  operator 2026-08-13 ("if we can ever name some classes of `other` better
  do update the claude-worktime repo as well"); measured the same day.
  **This QUALIFIES the raced-read entry directly below, which is why it sits
  here rather than in a corner.** That entry's measurement stands — four
  events, four real causes sitting in the transcript — but its
  generalization ("`other` is a raced read, not a missing cause") does not
  hold as a universal, and the counter-population is larger than the
  population that established it.
  **The measurement, 2026-08-13, one session's transcript, ten cold rows.**
  Perfect separation, no overlap in either direction:

      cr == 0  (total miss)     7 rows   apiCause = null on ALL 7
      cr >  0  (partial miss)   3 rows   apiCause present on ALL 3
                                         (messages_changed,
                                          previous_message_not_found x2)

  The seven causeless rows carry `cc` = 63988 / 246636 / 247105 / 248327 /
  248889 / 249130 / 270001, six of them inside one 3.5-minute burst
  (2026-08-13T11:33:46Z-11:37:09Z, ~1.51 M tokens re-billed).
  **The absence is REAL, not a reader failure, and the control is built into
  the same run** — the identical reader over the identical file returns
  three populated causes. A query that could not find a cause would have
  returned ten nulls. So this is not the raced-read class with a wider
  window: there is nothing in the transcript to race with.
  **Structural signature, computable from fields every ledger row already
  carries:** on all seven, `cc` equals `ctx` minus `input` exactly (e.g.
  246636 = 246638 - 2). Nothing was read; the whole context was re-written.
  That is a different event from a partial miss where a prefix hit and only
  the remainder was re-billed — and today both render as the same `other`.
  **Design, decided.** Classify at render and in the ledger from
  `cr`/`cc`/`ctx`, all already present — no new capture, no transcript read,
  no new field:
  - `cr == 0` -> name it (proposed: `no-prefix`; the WORD is the operator's
    call, the CLASS is what this entry fixes). Means: the API matched no
    cached prefix at all.
  - `cr > 0` and no cause -> keep `other`, which then means exactly what its
    own code comment already says — "no cause available" — now honestly
    scoped to the population where a cause could have existed.
  Leave the existing late-cause upgrade path untouched: it is correct for
  the partial class and this change must not disturb it.
  **Red-first arrangement, and the two must DIFFER:** a synthetic ledger row
  with `cr=0, cc=246636, ctx=246638` renders the new name; one with
  `cr=141672, cc=3228` and no cause still renders `other`. A change that
  renders both the same has renamed `other` rather than split it.
  **Do NOT infer a mechanism from the name.** WHY a total miss happens is
  unsettled and under investigation in the cache-fix fork, where the leading
  desk hypothesis (breakpoint collapse) was measured and REFUTED on
  2026-08-13. This entry names an OBSERVABLE and nothing more; a name
  implying a cause would be the label-over-body drift the corpus warns
  about.
  Done: both bites above pass; a `--cold` listing over the 2026-08-13 rows
  shows the six burst events under the new name and the three caused events
  unchanged; this entry leaves with its commit ref.
  Verifier: the two synthetic rows above, plus `claude-worktime --cold` over
  the real 2026-08-13 ledger.
  Anchor: claude-worktime.sh (the `cs_lastcause` / `other` default path)

- **READY — `other` in the ledger is a RACED READ of the transcript, not a
  missing cause: every one of four measured events had a real
  `cache_miss_reason` sitting in its transcript.** Measured 2026-08-08
  afternoon across four events (three post-`8bfc385`, one pre-fix control),
  with a zero-instrument check run FIRST so the absence claim could not be
  vacuous: the anchor query against a deliberately wrong session returns empty
  while the same query against the correct session and against the control
  returns real matches.

      11:58:22Z  353k  session 1e04119a   system_changed   (cache_missed 318,507)
      11:46:13Z  553k  session 6130449c   system_changed   (cache_missed 494,335)
      09:59:54Z  141k  session 6130449c   messages_changed (cache_missed 124,331)
      control 2026-08-07 09:52:42Z 212k   previous_message_not_found

  All four present, all four matched. The 120 s late-bind window
  (`k:"hit-cause"`) is the mechanism meant to catch exactly this and it DID
  fire for a fourth event — 12:06:02Z was upgraded `other` -> `messages_changed`
  74 s later, visible in the ledger — while 11:46:13Z and 11:58:22Z were not.
  So the window works and its REACH is the defect: a fixed timeout racing a
  transcript write whose latency nobody has characterised.
  **Why this matters beyond a cosmetic label:** `other` is a DEFAULT meaning
  "no cause available", and the standing runbook rule
  (`docs/cachebust-runbook.md:151-157`) already tells a human to grep the
  transcript before concluding the cause is unavailable — a manual step
  compensating for a mechanical gap, on every bust, forever. It also poisons
  the parked Layer-3a entry: an `other` SHARE computed over raced reads
  measures the race, not the residue.
  Design, and the open question is which of three: widen the late-bind window
  (needs the measured transcript-write latency distribution first — a fixed
  number chosen by feel re-creates the same race further out); or retry-until-
  found on a bounded budget; or re-derive cause lazily at READ time in `--cold`
  rather than binding it at write time. The third is the most robust and the
  largest change.
  Verifier, red-first, available on committed history: replay 11:46:13Z and
  11:58:22Z — both must resolve to their real transcript cause
  (`system_changed`) — while 12:06:02Z must stay `messages_changed`, the
  control that already works today so the fix cannot pass by changing
  everything. Done when a ledger `other` means the transcript genuinely has no
  cause, and the runbook's manual grep step can be DELETED rather than
  documented.

### Five gaps the 2026-08-07 README audit found in the CODE (docs were repaired; these are not)

The audit repaired the README and left the script and config untouched by
design. Five claims turned out to be defects in the code or its configuration
rather than in the prose, and two of them need a decision before anyone builds.

- **READY (small) — `--info` is printed at users and is not a handled flag.**
  `claude-worktime.sh:2850` tells a user with a corrupt log to
  "run: claude-worktime --info". Executed: it falls through the `*) ;;` arm and
  silently runs the default session mode, so the hint sends people to a no-op at
  exactly the moment they have a broken log. Fix is a real arm; `--repair` or
  `--debug` looks like the intent, and the hint text moves with whatever it
  becomes. Verifier, red-first: `claude-worktime --info` today prints the
  session summary — that is the red — and after the fix prints what the corrupt
  path promised. This is a decision only in the sense of naming the flag; the
  defect is not in doubt.

- **PARKED — the `:msg`/`:hook` cause suffix is documented twice and produced
  nowhere.** `config.sh:108-112` and `--tokens` (`claude-worktime.sh:2966`)
  both describe it; no code path emits it. The cause literals the script
  actually produces are `idle`, `model`, `other`, `compact`, `auto-compact`,
  `resume`, `-`, plus the API diagnostic type verbatim. The README was RIGHT to
  omit it and the audit deliberately did not add it. **Missing evidence: which
  of the two histories this is** — a feature removed while two docs kept it, or
  one never built. That decides whether the fix is deleting two doc lines or
  building the suffix, and it is not derivable from the current tree.

- **READY (small) — `config.sh`'s token list omits 8 tokens the script
  substitutes.** The README's table is the complete one (35: 17 always + 18
  optional, verified as a set difference in both directions against the two
  substitution arrays at `claude-worktime.sh:2211-2214`). A user reading the
  config file to discover tokens sees an incomplete list. Verifier: the same set
  difference, run against `config.sh`, must come back empty.

- **PARKED — `CLAUDE_WORKTIME_PAUSE` was documented as an env override and does
  not exist.** Removed from the README 2026-08-07 (`c5f9a9a`), proven by
  execution with a positive control: setting it changed nothing while
  `PAUSE_THRESHOLD` via the config file moved the same number from
  "Away 5h18m (1)" to "Away 11h16m (74)". `claude-worktime.sh:154` is a bare
  assignment with no env fallback. **Missing evidence: whether the env override
  was INTENDED.** Every other knob is config-file-only, so the doc row may
  simply have been wrong — but if env overrides are wanted, this is a code fix
  and probably a whole class rather than one variable.

- **PARKED — `PROJECT_GIT_ANCHOR` merges the LABEL but not the TOTALS.**
  Measured 2026-08-07 while documenting it: the anchor rewrites the displayed
  project name only (`claude-worktime.sh:1206` is its sole caller), while
  aggregation still selects on the raw logged path
  (`select(.p == $proj)`, `:1104-1108`). So a git worktree displays the repo's
  name and totals separately from it — which is strictly better than before
  (the label was wrong AND the totals were split) and is still two answers to
  one question. **Missing evidence: whether totals SHOULD merge across
  worktrees.** It is a product decision, not a bug: an agent worktree's time
  arguably belongs to the repo, and arguably is worth seeing apart.

- **READY (small) — the README's `❄` colour cannot be shown in a code block.**
  The headline example carries a fresh `❄ 428k resume (5m)` and a sentence
  saying it renders cyan, because a markdown fence is monochrome. If the colour
  is worth showing, the artifact is an SVG or an ANSI-rendered asset committed
  beside the README and referenced from it. Done-criterion: the example shows
  the cyan/gray distinction without a reader having to take prose for it.

- **PARKED — the tool carries no VERSION and `--version` is not a flag.**
  Measured 2026-08-07: no version constant in `claude-worktime.sh`,
  `install.sh` or `config.sh`, and `--version` falls through to the default
  summary mode rather than erroring. Since `install.sh` COPIES the script into
  `~/.local/bin`, there is no way to tell which build is installed — which bit
  during a same-day fix, where the only check available was grepping the
  installed copy for a function body. **Missing evidence: the operator's
  decision** on whether this repo wants a version at all; a single-user tool
  legitimately may not. If yes, the shape is a `VERSION=` constant, a real
  `--version` arm, and `install.sh` printing it on completion.


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
Frozen to `~/.local/share/claude-worktime/cold-design-evidence-2026-08-07/` (machine-local,
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

- **DROPPED 2026-08-08 — see Departed; design retained below should a real consumer appear.** ~~READY~~ — `--rows`: a line-robust ledger query mode.** There is no
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

- **SHIPPED 2026-08-08 (`8bfc385`, pushed) — per-session `token_prev`.**
  Landed as `local token_prev="${LOGDIR}/.token_prev_${sid}"`, keyed like the
  existing `.cold_${sid}` state file. Red-first proven and INDEPENDENTLY
  re-run by the dispatcher, not booked on the lane's word: the new test
  `tests/replay-token-prev-session.sh` exits **1** against base `5487ec6`'s
  script (md5 `acf2cec1220a51e470e5e6f206ec350a`, cross-checked by the
  dispatcher against `git show 5487ec6:claude-worktime.sh`) and **0** against
  the fix; the unmutated baseline was run first and stated green. Against the
  old script the duplicate render books `hits=1 cc=335933` — the measured
  01:00:55Z false ❄; against the fix, `hits=0`. Full suite 17/17 on the
  dispatcher's own run and again in the pre-push hook.
  **Confirming evidence gathered the same morning, worth keeping**: TWO live
  busts, both double-booked, 2 for 2 under concurrent sessions — 638k at
  09:48:53Z/09:49:20Z (one `message.id`, `cr=15,530 cc=638,186` on both rows)
  and 141k at 09:59:53Z/10:00:00Z (one `message.id`, `cr=15,195 cc=140,878`).
  Both are the predicted signature: identical `(cr,cc)` within one session,
  let through by cross-session interleave. The operator saw the phantom render
  as ordinal `#2` in the statusline, live, which is the nuisance this closes.
  Residual, NOT closed by this fix and deliberately not widened into it: the
  guard is an identity PROXY ("same `(cr,cc)` within a session"), not identity.
  The real identity is the API call id, which `tools/cold-events.mjs` in the
  cache-fix fork uses (`requestId`) and which is not available at the
  statusline tap — sixteen fields extracted, none an identifier. If a duplicate
  ever appears with genuinely differing `(cr,cc)` for one call, this proxy will
  not catch it and the transcript-reading route is the fallback.
  Original entry follows unchanged: Scanned 2026-08-08 over all 105
  recorded hits: **20 pairs sit less than 60 s apart within the SAME session**,
  several with an identical `cc` on both sides (119664 -> 119664,
  81917 -> 81917) — the same API call booked twice, which is exactly the
  signature this item predicts. One pair disagrees with itself about class
  (`other` / `messages_changed`), the "two duplicates that cannot even be
  recognised as one event" case. And 44 of 105 hits (42%) sit in the degraded
  `other` bucket.
  It is also the only item here attached to a LIVE operator-facing nuisance:
  the ❄ notifications still fire (operator-confirmed 2026-08-08), so a share
  of them are false, and a checker that fires on a non-defect trains its
  reader to discount the real one. **Bundle with the diagnostic-ordering item
  (A) below** — same code region, and (A) attacks that same 42% `other`
  bucket; splitting them buys nothing but a second round.
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

- **SHIPPED 2026-08-08 (`8bfc385`, pushed, bundled with the item above) — (A):
  consult the diagnostic BEFORE the idle short-circuit.** The `_cw_diag` read
  now runs whenever the hit predicate matches, ahead of the idle/model ladder;
  `previous_message_not_found` wins outright over gap and model.
  **The struck `gap > TTL` leg was NOT implemented**, per this entry's own
  `[vet]` blocking note — the diagnostic leg alone catches the named cases, and
  the leg would have silenced the whole idle class.
  Verifier ran THREE-sided as this entry specified, red-first
  (`tests/replay-diag-before-idle.sh`, dispatcher-re-run: exit **1** against
  base `5487ec6`, **0** against the fix): against OLD, the 23:59:10Z and
  03:32:02Z shapes failed as expected (`got hit/idle, want cost/resume`) while
  BOTH over-firing controls already passed on OLD — the 18:08:32Z genuine
  mid-history bust (`gap=7`, `messages_changed`) still books as a hit, and a
  constructed idle expiry with `gap > TTL` and no resume diagnostic still books
  as a hit. Those two passing on the old code is the point: it shows the red
  came from the diagnostic-precedence cases only, not from a check that fires
  on everything.
  Sequencing note from this entry HELD: (A) shipped before 3b's fixture was
  captured, so 3b's verifier has not dissolved.
  Original entry follows unchanged: Measured 2026-08-06 23:59:10Z: `previous_message_
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

- **PARKED 2026-08-08 (was READY) — Layer 3a: a fourth answer, "the cache
  was fine."** Design below is intact and unchallenged; what changed is the
  SEQUENCING. Its motivating population is false fires forced to render as
  unknown-cause busts — and the per-session `token_prev` item is the fix for
  the false fires themselves. Building the honest fourth answer first means
  building it for a population that item is about to remove.
  **Named missing evidence: the `other`-cause hit count after `token_prev`
  ships.** Today 44 of 105 recorded hits (42%) are `other`. If that collapses,
  this item shrinks to a genuine could-not-verify answer for a rare residue
  and may not earn a ladder rung; if it holds near 42%, the false fires were
  not the driver and this becomes READY again on stronger grounds than it has
  now. Either outcome flips the verdict, which is what makes this a park
  rather than a deferral.
  **MEASURED 2026-08-08 afternoon — NOT DECIDABLE YET, n=4. The park STANDS,
  with its trigger now carrying a real baseline instead of a remembered one.**
  Run against the installed binary itself
  (`claude-worktime --cold --since …`, retract- and cause-aware, cross-checked
  against a hand-rolled jq replicating the same correction logic — both give
  108 rewrites / 35 `other`):

      window                      total hits   other   share
      BEFORE (< 10:52:27Z)            104        33     31.7%
      AFTER  (>= 10:52:27Z)             4         2     50.0%

  Neither named outcome is selected. One more or fewer `other` in the after
  window swings it between 25% and 75%, so the 50% is noise, and the honest
  read is that the fix has not yet been given enough traffic to judge. Re-run
  the same command once the after-window reaches a usable n; the corrected
  BEFORE baseline is **31.7%**, not the 42% this entry quoted from raw
  `k:"hit"` records — that figure predates the retract/cause corrections
  `--cold` itself applies.
  **Deploy instant, and it is a methodological point worth keeping:** the split
  is at **10:52:27Z**, the mtime of `/home/g/.local/bin/claude-worktime` — the
  INSTALLED copy the statusline actually runs, byte-identical to the repo copy
  at `8bfc385`. Not the commit time (10:10:11Z). The installed copy landed 42
  minutes after the commit, and using commit time instead misclassifies one
  event. A before/after split on a deployed tool anchors to the deploy, never
  to the commit.
  **And the `other` label itself is a RACED READ, not an absence** — measured
  the same afternoon and this is the sharper finding, booked separately below.

  Original entry follows unchanged: The
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
  **RE-SCOPED 2026-08-08, and the first verdict is now named.** The argument
  below (nothing asks whether the ledger is SOUND) is right and its inventory
  stands. What it lacked was a proven blind spot to aim at first, and one
  arrived: rotation failed **1,052 consecutive times over 129 days** and
  nothing noticed — `.rotation_errors` grew all the while and is printed only
  by `--info`, which nobody runs unprompted. That is this item's thesis with
  an execution attached, so build THAT verdict first: rotation staleness.
  Computable, near-zero false fires — `AUTO_ROTATE` is true AND the newest
  `activity-*.jsonl` archive is older than N rotation periods AND the live log
  holds records older than the cutoff. Note the deliberate `AUTO_ROTATE` guard:
  without it the check fires on every machine that has rotation switched off
  on purpose, which is the guard-fires-on-a-non-defect shape.
  Red-first is free and needs no fixture: the live state was red for 129 days
  and the archives on disk still prove it (newest `activity-2026-03-31.jsonl`).
  The broader ledger-health verdicts below stay in scope after it.
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
  `~/.local/share/claude-worktime/cold-design-evidence-2026-08-07/`: (a) goes red at 43;
  (b) red at 1,022; (c) red on the 17:40 triple and both contradictory
  pairs; (d) red on the 23:59 and 03:32 idle rows. Each must go GREEN
  on a hand-built clean fixture, so a check that can never pass is
  caught before it ships.
  Done when all five have been shown red on real data and green on the
  clean fixture, and `--doctor` is wired into whatever runs daily.

- **OBSOLETE 2026-08-08 — see Departed; diagnosis refuted, artifact gone.** ~~READY~~ — the torn-line writer.** `--cold` reporting `43 unreadable
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

### `{project_total}` is inflated ~55x — two independent defects, found 2026-08-08 by operator disbelief at a statusline number

The dotfiles statusline read `total 2204h44m`. Recomputed independently
(Python reimplementation of `is_idle`/`calc_active`, `PAUSE_THRESHOLD=900`):
`2204h46m` — reproduced, so the arithmetic is not in doubt. **97.9% of it is
one gap of 2159h32m** (89.98 days). Both defects below are live, and neither
is visible from reading the statusline.

- **BUILT 2026-08-08 (f40e104, deployed) — see Departed.** ~~READY~~ — (A) `calc_active` walks a per-project SLICE and treats
  adjacent-in-slice events as adjacent in time.** `claude-worktime.sh:1106-1109`
  computes `project_total_active` as
  `$all | map(select(.p == $proj)) | calc_active($pause)`. The gap between two
  events adjacent *in that slice* is not a real gap — it is every second the
  session spent elsewhere. `is_idle` (≈280) suppresses a gap only when the
  PREDECESSOR is `response` or `start`, so the slice mostly ends on a suppressed
  pair and the bug stays hidden. The event kinds `tool_start`, `tool_end` and
  `prompt` can never be idle by construction — so when a session `cd`s away
  mid-tool the slice ends on a `tool_start` and the whole interval until the
  project is next visited is billed as attended Claude work.
  Traced to the record: session `00e18b84` emitted its last dotfiles event
  (`tool_start`, 2026-04-28 14:08:49) then worked on in pbs-bureau /
  mcp-server / skill-craft until 20:03:09 the same day — it did **not** crash.
  The next dotfiles event is a `start` on 2026-07-27 13:40:52. Those two are
  adjacent in the slice, so 90 days entered the total.
  Fix: a gap counts for `$proj` only when BOTH endpoints carry `.p == $proj` —
  i.e. walk the full sorted stream, not the slice. Same shape binds
  `today_project_active` and `today_project_split` (1104-1105), which use the
  identical `map(select(.p == $proj))` idiom.
  Verifier, red-first: against the live log, `{project_total}` for dotfiles
  reads 2204h47m today (the red); under the both-endpoints rule it reads
  18h43m. Do NOT book 18h43m as the answer — it is depressed by (B) below, and
  (B) must land with (A) or the fix trades a 55x overstatement for an
  understatement. With (B) applied too (all cwds under the repo root folded to
  the root — which surfaces `claude/hooks`, `claude/` and six
  `.claude/worktrees/agent-*` lanes as dotfiles time), it reads **19h06m**.
  **Sub-decision SETTLED (operator decision, on the recommendation below):**
  a gap straddling a project switch is attributed to the PREDECESSOR's
  project — the one the clock was running in when the gap opened. Rejected:
  dropping such gaps (the both-endpoints rule alone), which under-counts a
  session that interleaves repos rapidly and makes 19h06m a floor rather than
  an answer; and splitting the gap, which invents a boundary the log does not
  record. State the chosen rule in the docstring so the next reader does not
  re-derive it.
  So the rule is: walk the FULL sorted stream; a gap counts for the project of
  its EARLIER endpoint, subject to the existing `is_idle` suppression. This
  supersedes the both-endpoints phrasing above wherever they differ.
  **Target values, computed against the repaired log on the day the rule was
  settled** (recompute rather than assert these — the log grows): dotfiles
  `28h59m` (vs `2204h47m` shipped, and `19h06m` under the rejected
  both-endpoints variant — the ~10h delta IS the straddling gaps, which is
  what makes the attribution choice load-bearing rather than cosmetic).
  Cross-check that ties (A), (B) and (C) together: under the settled rule the
  all-projects sum is `967h25m` against a `3104h48m` wall span — the (C)
  invariant PASSES at 0.31x, where the shipped code gives 6.6x. So (C) is the
  acceptance test for (A)+(B), not merely a watchdog: it is red before and
  green after, on real data, with no fixture.

- **BUILT 2026-08-08 (f40e104, deployed) — see Departed.** ~~READY~~ — (B) `.p` is written RAW but `{project}` is displayed ANCHORED, so
  the label sits over a body it does not describe.** The log writer
  (≈986-995) uses `HOOK_CWD`/`$(pwd)` verbatim; `PROJECT_GIT_ANCHOR`
  (≈728, `_project_label_v`) anchors to the git common dir for the DISPLAY
  token only. So a statusline reading `dotfiles` shows a total computed by
  exact-string match on one cwd, and every subdirectory of the same repo is a
  separate "project". Visible in the live data: `beat-the-books`,
  `.../src/beat_the_books`, `.../docs` and `.../dictionaries/dictionaries` are
  four rows. Fix: anchor at WRITE time (or normalize `$proj` at read time with
  the same function the label uses) so the aggregation key and the rendered
  label are the same value. Historical records keep raw cwds either way —
  a read-time normalization repairs history, a write-time one does not; that
  is the design call.
  Verifier, red-first: today `{project}` renders `beat-the-books` while four
  distinct `.p` values feed four different totals — assert label and
  aggregation key are equal for every rendered row.

- **BUILT 2026-08-08 (tests/project-totals-plausibility.sh) — see Departed.** ~~READY~~ — (C) the plausibility invariant that would have caught this, as a
  `--test` check.** The manual probe is the prototype; the mechanism is the
  deliverable. **Invariant: the SUM of all projects' active time cannot exceed
  the log's own first..last wall span.** Measured today: sum `20565h43m` vs
  wall span `3104h19m` = **6.6x wall clock** — red, on real data, no injection
  needed. Near-zero false-fire risk: it is arithmetic on the log, and a human
  cannot work 6.6x real time.
  **Rejected, having been tested:** the per-project variant ("a project's
  active time cannot exceed its own first..last span") — run against the live
  log it yields **0 violations** even with the 90-day gap present, because the
  gap is bounded by the span it sits inside. It is unfalsifiable for this
  defect class and must not be built as a substitute.
  Done-criterion: the check ships in `--test`, goes red on today's log, and
  goes green once (A) and (B) land.

### `mode_rotate` keeps its own plain-jq copy of the guard `_do_rotate` just had fixed (found 2026-08-08 by the executing agent, outside its write boundary)

- **READY (small) — `claude-worktime.sh:2931`.** `_do_rotate`'s first-event
  guard is now `_safe_log "$LOGFILE" | jq -r … | head -1` (`:2655`, commit
  `7a949ab`). `mode_rotate` has a second, untouched copy:
  `first_event_ts=$(jq -r 'select((.type // null) == null) | .t' "$LOGFILE" … | head -1 || true)`.
  It is tolerant BY ACCIDENT — streaming jq emits the first valid record before
  dying — and fails exactly where the corrupt line PRECEDES every valid event
  record: the read yields empty and `--rotate` prints "Nothing to rotate" over
  a log full of rotatable entries. That is the could-not-verify answer wearing
  a pass-shaped costume, the same shape `docs/` warns about.
  Fix: route it through `_safe_log`, identically to `:2655`.
  Verifier, red-first: a fixture whose FIRST line is malformed and whose
  remaining lines are all pre-cutoff events — `--rotate` prints "Nothing to
  rotate" today (the red); after the fix it rotates them. Note the ordinary
  fixture (corrupt line in the middle) does NOT go red here, which is why the
  ordering is part of the spec, not an incidental fixture detail.
  Not covered by `tests/rotation-corrupt-log.sh` or
  `tests/rotation-no-silent-truncation.sh` — both drive `_do_rotate`.

- **BUILT 2026-08-08 (2b3f553) — and the entry's premise was REFUTED, which is
  the part worth keeping.** This entry called the branch fixture-unreachable
  ("needs `:2655` to succeed while `:2662` fails — OOM, file vanishing") and
  offered only two exits: a fault-injection seam, or a note recording it as
  untestable. A third existed and cost neither. `_safe_log` is
  `jq -Rc 'fromjson? // empty'`, which passes through any valid JSON including
  a NON-OBJECT; the collect read then evaluates `.type` on it and raises. jq
  skips the bad input, keeps going, and takes its exit status from the LAST
  input — so a bare scalar on the final line makes the reader emit a valid
  prefix AND exit non-zero, which is exactly the property the branch defends.
  The first-event guard survives the same file because it ends in
  `head -1 || true`. Lesson booked rather than the fix: **"unreachable by
  fixture" is a load-bearing claim and earns the same refutation probe as any
  other** — a five-minute probe overturned it, and was cheap precisely because
  the claim named what would falsify it.
  ~~READY~~ — the item-(2) refusal branch has no black-box test.
  `7a949ab` added a hard-error guard at the collect read (`:2662-2672`) that
  refuses to archive on a read failure. After the `_safe_log` routing it is
  unreachable by fixture — it needs `:2655` to succeed while `:2662` fails
  (OOM, file vanishing mid-run). Proven by injection only (executor bite 2,
  2026-08-08), never by a suite test. Decide: either a fault-injection seam the
  suite can drive, or an explicit note in the test file that this branch is
  injection-proven. Silently untested is the one option ruled out.

### Rotation's first run after the 2026-08-08 repair is a one-time 12-25 s stall — DECISION PENDING

- **SETTLED 2026-08-08, superseded by the summary-writer hold — see Departed.** ~~READY~~ — operator decision, evidence gathered. With the live log repaired
  (46 lines, 2026-08-08) rotation is unjammed for the first time in 129 days,
  and `:1003` runs it SYNCHRONOUSLY on the session-start hook. Measured on an
  83 MB synthetic corrupt log: **24.2 s wall**, `Rotated 1073862 entries
  (24 projects)`. The synthetic carries ~1.9x the real log's line count and the
  cost looks per-record, so the real figure is plausibly ~12 s — same order.
  One-time; afterwards the live log is small.
  Currently NEUTRALISED by `AUTO_ROTATE=false` in dotfiles'
  `claude-worktime/config.sh` (hold set 2026-08-08, reason and removal
  condition in the comment there). The hold exists for a different reason —
  rotation would bake inflated `calc_active` totals into permanent summary
  records — so BOTH must clear before it lifts.
  When it lifts: prefer `claude-worktime --rotate` run manually, once, before
  the next session start, over paying the stall on a hook. Recommendation, not
  yet decided.

### Two findings from the runner/lint dispatch, both outside its write boundary (2026-08-08)

- **READY (small) — one suite's sandbox rests on an environment variable
  happening to be unset.** `tests/replay-cold-corrupt-log.sh` sets
  `XDG_DATA_HOME` and stops there. But `CLAUDE_WORKTIME_DATA` takes precedence
  over XDG (`claude-worktime.sh:151`), so on a machine exporting it that suite
  reads and writes the operator's REAL log. It holds today only because
  nothing exports it — a sandbox whose correctness is a property of the
  ambient environment, not of the test.
  **Audit completed by the dispatcher — the hazard is confined to this ONE
  suite**, which is worth recording because the executing agent could only
  report the gap as unaudited: `rotation-corrupt-log.sh` and
  `rotation-no-silent-truncation.sh` set XDG *and* `unset
  CLAUDE_WORKTIME_DATA CLAUDE_WORKTIME_CONFIG`; `replay-cold-detect.sh`,
  `replay-cold-guard.sh`, `replay-cold-guard-compact.sh` and
  `test-cold-guard-clipboard.sh` pass `CLAUDE_WORKTIME_DATA=` explicitly on
  every invocation, which is stronger than the XDG route and immune to the
  ambient value; `label-git-anchor.sh` awk-extracts two functions and never
  runs the script at all.
  Fix: give `replay-cold-corrupt-log.sh` the same `unset` line the rotation
  suites carry. Verifier, red-first: `CLAUDE_WORKTIME_DATA=/tmp/decoy
  bash tests/replay-cold-corrupt-log.sh` — today the suite escapes its sandbox
  into that path (assert against a decoy, never the real log); after the fix
  it stays in its own. Do NOT red-test this against the real log.
  Generalisable: prefer the per-invocation `CLAUDE_WORKTIME_DATA=` form over
  `XDG_DATA_HOME`, since it cannot be overridden by a higher-precedence
  variable the test never mentions.

- **READY (trivial) — `install.sh:101` `MARKER_END` is assigned and never
  read.** The `awk` two lines below hardcodes the literal
  `/^<!-- claude-worktime:end -->/`, so the variable and the string it stands
  for can drift apart silently; `uninstall.sh` does not define it at all. The
  one shellcheck finding of the 33 that is a real defect rather than an
  indirect-expansion false positive. It sits inside the legacy "Remove old
  CLAUDE.md section (no longer used)" block, so severity is low — fix is
  either to use the variable in the awk or drop it.

### Residue from the dotfiles-drift sweep and the install/gate lane (2026-08-08)

- **READY (trivial) — the lint baseline drifts and nothing says so.**
  `docs/lint-baseline-2026-08-08.txt` records 33 warnings at `cf1c126`; the
  live run is 34 (27 SC2034, was 26), the extra one from test files added
  after that commit. The file is commit-pinned and says it records the state
  as found, so it is not wrong — but a reader comparing today's run against it
  has no way to tell expected drift from a new finding.
  Fix, either: regenerate it and re-pin (a `tools/lint.sh --format=gcc`
  redirect plus the header's commit/date), or teach `tools/lint.sh` a
  `--baseline` mode that diffs against the file and reports only NEW codes.
  The second is the one worth building — it makes the baseline a check rather
  than a document. Verifier, red-first: plant one new finding in a scratch
  copy, assert the diff names it and stays silent on the 33 known ones.

- **READY (small) — the suite gate is machine-local, so a fresh clone starts
  ungated.** `tools/git-pre-push.sh` only runs once `.git/hooks/pre-push`
  links to it, and `.git/hooks/` is not tracked — the README carries the
  one-line setup, which means it holds exactly as long as someone reads it.
  Fix belongs in dotfiles, not here: a `DEPLOYED_COPIES`-style entry in
  `bootstrap/manifest.py` that creates the symlink for this clone, so
  `./dot apply` restores the gate the way it restores everything else.
  Pointer entry — the body of the work is in the dotfiles repo. Done when a
  deliberately unlinked `.git/hooks/pre-push` is restored by `./dot apply`.

### The argument loop still swallows any unknown flag silently (2026-08-08, half-closed by design)

- **READY (small) — `claude-worktime.sh`'s top-level `*) ;;` arm.** The
  `--info` fix closed the SYMPTOM (a printed flag with no arm) and
  `tests/printed-flags-are-handled.sh` keeps that class shut mechanically —
  every `claude-worktime --flag` the script PRINTS must have a real arm. But
  the general defect is untouched: any unrecognised flag still falls through
  to the default session summary, so a typo runs the wrong mode and says
  nothing. The executing agent stopped there deliberately, because making it
  error changes behaviour the brief did not name — correct call, and the
  remainder is this entry.
  Decision needed before building: erroring on unknown flags is a
  behaviour change for anyone (or any script) passing extra arguments today.
  Verifier, red-first: `claude-worktime --nonsense` prints the session
  summary and exits 0 today; after, it names the flag and exits non-zero.
  Check the hook call sites first — the six harness hooks pass real flags,
  and this must not break them.

- **READY — a guard that catches a test fixture seeding a state filename the
  code never reads.** Found 2026-08-14 while fixing the warm-compact defect:
  three sites in `tests/replay-cold-detect.sh` wrote `"$d/.token_prev"`, the
  pre-split GLOBAL name, while the detector has read `.token_prev_<sid>` since
  the per-session split (`claude-worktime.sh:1800`). All three read as pinned
  premises and pinned nothing. One was not merely decorative: the zero-usage
  case's own comment says "token_prev differs from (0,0) so only the zero-total
  rule can skip it" — with the seed landing on a dead name, `tp` read (0,0), the
  unchanged-pair gate skipped the render too, and the case would have passed
  with the zero-total rule DELETED. A green check exercising less than it
  claims, byte-identical to health.
  **Design, decided.** A check in `tools/` that (a) derives, from
  `claude-worktime.sh`, the set of `${LOGDIR}/.<name>` state files the script
  actually reads or writes — derived from the source, never a restated list,
  since a restated one cannot age loudly — and (b) asserts every `"$d/.<name>"`
  a file under `tests/` writes resolves to a member of that set, allowing the
  `_<sid>` suffix. Wire it into `tools/run-tests.sh`.
  **Red-first arrangement:** revert one of today's three renames back to
  `.token_prev` and the guard goes red naming that line; the unreverted tree is
  green. Baseline is green today (suite 18/18, 2026-08-14) — state that before
  claiming the red, since a permanently-red guard is indistinguishable from a
  working one.
  **Done-criterion:** guard red on the reverted site, green on the tree,
  `tools/run-tests.sh` still 18/18 (19 suites with the guard).
  **Write boundary:** `tools/` (new check) + `tools/run-tests.sh`.

## Parked

- **PARKED — `_cw_compact_boundary_info` picks the newest compact boundary by
  FILE ORDER, not by timestamp, and it is not settled which is right.**
  `claude-worktime.sh:3057` selects every `compact_boundary` record and takes
  `tail -n 1` — last in the file. Measured 2026-08-14 on a real 4,845-line
  transcript carrying two manual compacts: file order and chronological
  order AGREE for the two boundary records, so today's behaviour is correct and
  the warm-compact fix rests on it safely. But timestamps and file order do
  diverge in that transcript's compact region — the `isCompactSummary` record
  sits AFTER its boundary record in the file while carrying a timestamp five to
  seven seconds EARLIER (11:05:17 after 11:05:22; 15:42:03 after 15:42:10),
  reported by the session that observed the defect. The divergence is proven
  for neighbouring records; it is unproven for two boundary records.
  **Named missing evidence:** one transcript in which two `compact_boundary`
  records appear in a file order that disagrees with their timestamp order —
  the plausible producer is a fork or resume that replays a parent session's
  records after later ones. Absent that, `tail -n 1` and max-by-timestamp are
  indistinguishable and switching would be a change with no evidence behind it.
  **Which way it unparks matters and is NOT decided:** if the divergence comes
  from replayed parent records, FILE ORDER is the causal order and the current
  code is right; if it comes from out-of-order writes within one session,
  max-by-timestamp is right. The evidence above must say which before either is
  built — a fix chosen now would be a coin flip wearing a design's costume.

- **PARKED — the `-ef` guard and the settings `cp` are Linux-tested only.**
  `install.sh:82` uses `[ src -ef dst ]` and `:135`/`:145` write through a
  symlinked destination with `cp`. Both were proven on Linux by executing the
  real installer against a sandbox `CLAUDE_DIR`; the macOS path targets bash
  3.2 with BSD utilities, where `-ef` is documented as a bash test builtin and
  BSD `cp` follows a destination symlink the same way — neither claim was
  exercised.
  **Named missing evidence:** one run of `install.sh` and `uninstall.sh` on a
  macOS machine, with `~/.claude/settings.json` symlinked, asserting the link
  survives. Unparks the moment a macOS machine is available; there is no
  reasoning path that settles it from here.

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

- 2026-08-14: **the statusline shows the session's OWN peer name — SHIPPED
  `8821afb` (implementation, tests, install) + `1dd961c` (README,
  .shellcheckrc), live-verified.** Booked and dispatched the same day
  (opus lane, dispatcher-verified: suite 18/18 run independently, installed
  binary cmp-identical, live render positive for a live id, negative control
  clean on the same registry). The done-criterion's live half needed one word
  outside the repo — ` PEER` appended to the operator's
  `~/.config/claude-worktime/config.sh:291`, made by the dispatcher, since
  install.sh keeps an existing config by design and a shipped default
  therefore never reaches a standing user config (candidate lesson recorded
  in the lane report). Fail-soft arms tested against a fixture registry
  (synthesized ids only); `CLAUDE_SESSIONS_DIR` overridable; registry schema
  is a CC-internal binding (2.1.229) — on schema drift the segment silently
  vanishes, which is the designed failure mode.

- 2026-08-08: **the rotation summary WRITER — BUILT, and the hold it gated is
  lifted.** The item said the `summaries=` jq inside `_do_rotate` still ran
  `group_by(.p)` with a raw `p:` key, reproducing the slice defect and the
  unfolded key in the one place whose output is permanent. Both halves are
  answered. (A) is BUILT: the writer routes through `split_by_project($pause)`
  — `claude-worktime.sh:2836`, the same rule every read path uses — landed by
  `b25625f`. (B) was DECIDED the other way and correctly so: the raw `.p` key
  is kept deliberately, because the read path folds by containment (`:1203`)
  and folding at write time would destroy subdirectory detail permanently, so
  raw key plus folding reader preserves strictly more information. The item's
  own "also decide" tail is settled too — the 12 legacy summary records were
  RECOMPUTED from the archives rather than dropped (`41b1917`), two
  independently-built implementations agreeing to the second. The
  `AUTO_ROTATE` hold this item gated was lifted the same day (dotfiles
  `f1241e5`), verified by rotating a copy of the real log rather than by
  reading the fix.

- 2026-08-08: **`--summary --raw` label collisions — BUILT** (`c1a9159`,
  with `tests/summary-raw-label-collision.sh`). Colliding labels now SUM
  instead of overwriting, so the raw total is exact rather than the lower
  bound the item described. Consequence the item did not anticipate: the (C)
  plausibility suite's rationale still called the total a lower bound
  "because collisions overwrote", which stopped being true — the invariant
  got stricter, not looser, and that comment was corrected in `41b1917`.

- 2026-08-08: **the torn-line writer — OBSOLETE, its diagnosis refuted.**
  The item asked to classify the unreadable lines and then fix the writer
  producing them. Both halves are answered, neither the way it expected.
  All 46 were classified (commit a3ec941): each is a valid event record whose
  closing brace was consumed by a spliced `,"cst":{"<k>":"<v>"` fragment. Its
  named first suspect — "a rotation that REWRITES the live file" — is
  REFUTED: rotation had not succeeded once since 2026-04-01, so it never
  rewrote anything; the corrupt lines were what JAMMED rotation, i.e. the item
  had cause and effect inverted. All three of its shape hypotheses (truncated
  prefix / two records concatenated / interleaved bytes from two writers) are
  wrong, and with them the premise that this was a CONCURRENCY defect — so its
  verifier ("a concurrency probe adds zero new unreadable lines against the
  fixed writer") would have exercised a mechanism that was never the cause.
  The writer was already fixed on 2026-04-01 by 910a6c4, seventeen minutes
  after 6f91aa5 introduced it; no corrupt line exists after that date. The
  artifact it was written about is gone: unreadable lines 0, down from 43-46.
  Lesson worth keeping: this item carried a DIAGNOSIS rather than a symptom,
  and a diagnosis rots while the entry stays plausible — it survived a
  fresh-context vet with the wrong hypothesis intact, because the vet checked
  the reasoning and not the world.

- 2026-08-08: **`--rows` — DROPPED on re-reading its own grounding.** Its
  evidence was that an ad-hoc scan "was killed at 120 s having answered
  nothing". But that scan ran one `jq` process per line over an 81 MB file:
  it proves the scan was written badly, not that a query surface is missing.
  Half a dozen equivalent queries were run against the same log in Python in
  under a second each during the 2026-08-08 investigation. Outside the cold
  cluster the mode has no consumer, and it is cheaper to write when something
  actually needs it than to carry as standing scope.

- 2026-08-08: **(A), (B) and (C) of the `{project_total}` inflation item —
  BUILT.** commit f40e104, deployed via dotfiles `dot apply` the same day.
  The statusline reads `total 29h14m` where it read `2204h44m`; verified
  against an independent reimplementation of the settled rule, agreeing to the
  minute, and at the deployed-binary altitude rather than from the repo. (C)
  went red->green on the real log with no fixture: 5.36x wall-clock before,
  0.31x after, 190 projects. Full suite 10 passed / 0 failed.

- 2026-08-08: **the rotation-stall decision — SETTLED, superseded.** The
  12-25 s first-rotation stall is real but is no longer the binding
  constraint: `AUTO_ROTATE` is held for the summary-writer defect instead, and
  the same measurement pass showed the stall's own cause (an 83 MB log) is
  what the writer fix removes. Recommendation preserved in the writer item:
  when the hold lifts, rotate once by hand rather than on a hook.

- 2026-07-31: both founding items — zero-usage write skip and
  late-bind resume-split retract — built same day they were booked,
  red-first from the measured 2026-07-31 sequence (commit ref in this
  entry's own commit; `tests/replay-cold-detect.sh` 17/17; live ledger
  and the session's ❄ state retro-corrected with the shipped
  `hit-retract` mechanism).
