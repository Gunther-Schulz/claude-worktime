# BACKLOG — claude-worktime

Two grades: **ready** (decision-complete: design decided, verifier
named, done-criterion stated) and **parked** (carries its named missing
evidence). Items leave by commit ref or are dropped with a one-line
reason — and LEAVING MEANS THE BODY MOVES: the closed entry's body
goes to `## Departed` with its evidence, never graded closed in
place. A struck-through or SHIPPED-marked entry left sitting in
Ready or Parked is a closure without an exit, and the carrier then
grows without bound while formally compliant (measured 2026-08-14:
nine such entries holding 272 of this file's 1008 lines).

**Last retirement pass: 2026-08-14** — 1008 lines / 21 open entries in,
748 lines / 14 open entries out (9 closed-in-place bodies exited, 7 open
entries closed as already-resolved, 1 built, 1 new booking). The next
pass measures its growth against those numbers, not against a feeling.
The method that found the 7: re-check each entry's premise against the
tree by EXECUTED command, never by re-reading the entry's own reasoning —
six of the seven had been silently resolved by repairs aimed at something
else, and every one of them still read as perfectly plausible.

Events are named by UTC timestamp, never by session id: this repo is
public and the machine-wide push-side leak scan does not reach it
(known gap, booked in the cache-fix fork's BACKLOG as a pointer to the
dotfiles design). Any fixture added here is synthesized or scrubbed by
hand for the same reason.

## Ready

- **READY — generic fourth statusline line from a user-supplied
  command (`LINE4_CMD`): the statusline gains an extension point
  instead of a domain feature.** Motivation (2026-08-18): the
  operator wants per-repo work-queue counts on the statusline; that
  vocabulary is site-specific and belongs to the site's own tooling
  (the supplier is booked in the operator's dotfiles BACKLOG as
  `tools/backlog-census`), so what THIS repo ships is domain-free:
  a `LINE4_CMD` option in `config.sh` — when set, the command runs
  per render in the session's cwd and its first stdout line renders
  as line 4. Fail-open by design: unset config, empty stdout,
  nonzero exit, or timeout (hard cap ~1s, killed) → exactly the
  current three lines, no error text on the statusline ever.
  Caching is the supplier's job, not this repo's — the contract is
  "run command, print line", nothing more. Done-criterion: with
  `LINE4_CMD='printf …'` a fourth line renders; unset/failing
  reproduces today's output byte-identically. Verifier: tests in
  `tests/` covering set/unset/empty/nonzero/timeout, plus README's
  Configuration table gaining the option (docs are part of done —
  this repo is public). Write boundary: this repo
  (`claude-worktime.sh`, `config.sh`, `tests/`, `README.md`).

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

- **PARKED — the `:msg`/`:hook` cause suffix is documented twice and produced
  nowhere.** `config.sh:108-112` and `--tokens` (`claude-worktime.sh:2966`)
  both describe it; no code path emits it. The cause literals the script
  actually produces are `idle`, `model`, `other`, `compact`, `auto-compact`,
  `resume`, `-`, plus the API diagnostic type verbatim. The README was RIGHT to
  omit it and the audit deliberately did not add it. **Missing evidence: which
  of the two histories this is** — a feature removed while two docs kept it, or
  one never built. That decides whether the fix is deleting two doc lines or
  building the suffix, and it is not derivable from the current tree.

- **PARKED — `CLAUDE_WORKTIME_PAUSE` was documented as an env override and does
  not exist.** Removed from the README 2026-08-07 (`c5f9a9a`), proven by
  execution with a positive control: setting it changed nothing while
  `PAUSE_THRESHOLD` via the config file moved the same number from
  "Away 5h18m (1)" to "Away 11h16m (74)". `claude-worktime.sh:154` is a bare
  assignment with no env fallback. **Missing evidence: whether the env override
  was INTENDED.** Every other knob is config-file-only, so the doc row may
  simply have been wrong — but if env overrides are wanted, this is a code fix
  and probably a whole class rather than one variable.

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
  **PARTIALLY SHIPPED 2026-08-14 — the MODE and the FIRST verdict exist
  (`67cfa9b` + `f7938fc`); the remaining five checks are what keeps this entry
  open.** `--doctor` emits three-answer verdicts (verified clean / verified
  broken / COULD NOT VERIFY, exit 2 for the third so it can never read as
  clean), and the rotation-staleness verdict is live: run read-only against the
  real ledger it reports "verified broken — newest archive
  activity-2026-03-31.jsonl (period 2026-03-31) predates the staleness
  threshold, live log holds entries from 2026-04-01". So the 129-day blind spot
  that motivated this entry is now instrumented. Still to build: (a)
  unreadable-line count, (b) `.rotation_errors` freshness, (c) the
  contradictory-class detector, (d) the standing `previous_message_not_found`
  check, (e) cold state-file shape — all five as described below, against the
  frozen ledger copy the verifier names (confirmed present 2026-08-14).
  Two lessons the first verdict paid for, both worth applying to the remaining
  five: the check first anchored archive age to MTIME, which is mutable — a
  copied or restored data dir made a never-rotating system read clean, caught
  by a dispatcher probe and repaired to compare the archive's own filename
  SUFFIX; and its `(g)` residue surfaced a real ISO week-year defect in the
  suffix format itself (Departed, `5e40c1c`). A health check's failure mode is
  going quiet, not firing falsely, so each remaining verdict earns a false-fire
  control alongside its red.
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

### `{project_total}` is inflated ~55x — two independent defects, found 2026-08-08 by operator disbelief at a statusline number

The dotfiles statusline read `total 2204h44m`. Recomputed independently
(Python reimplementation of `is_idle`/`calc_active`, `PAUSE_THRESHOLD=900`):
`2204h46m` — reproduced, so the arithmetic is not in doubt. **97.9% of it is
one gap of 2159h32m** (89.98 days). Both defects below are live, and neither
is visible from reading the statusline.

### `mode_rotate` keeps its own plain-jq copy of the guard `_do_rotate` just had fixed (found 2026-08-08 by the executing agent, outside its write boundary)

### Rotation's first run after the 2026-08-08 repair is a one-time 12-25 s stall — DECISION PENDING

### Two findings from the runner/lint dispatch, both outside its write boundary (2026-08-08)

### Residue from the dotfiles-drift sweep and the install/gate lane (2026-08-08)

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

- **PARKED — the duplicate-render guard is an identity PROXY, not identity.**
  Residual of the per-session `token_prev` fix (SHIPPED 2026-08-08 `8bfc385`,
  see Departed), deliberately not widened into it at the time. The guard's
  test for "same API call rendered twice" is "same `(cr,cc)` within one
  session". The real identity is the API call id, which `tools/cold-events.mjs`
  in the cache-fix fork uses (`requestId`) and which is NOT available at the
  statusline tap — sixteen fields are extracted there, none an identifier.
  **Named missing evidence:** one observed duplicate render of a single API
  call whose `(cr,cc)` pair DIFFERS between the two renders. Until such a case
  exists the proxy and true identity are indistinguishable in practice, and the
  fallback (reading identity from the transcript) would be paid for nothing.
  Unparks the moment such a pair is seen in the ledger; the scan is the same
  same-session near-duplicate query that found the original 20 pairs.

- **PARKED — should the six historical `other` burst rows be relabelled
  `no-prefix`?** The split (SHIPPED 2026-08-14 `841f493`) classifies at WRITE
  time, so rows logged before it keep the label they were recorded with. The
  entry's own done-criterion wanted `--cold` over the 2026-08-13 rows to show
  the six burst events under the new name, and that half is NOT met.
  **Why it was not done anyway:** stored cold rows carry neither `cr` nor `ui`
  (verified 2026-08-14 via `--cold --raw`: the fields are absent), so a
  read-time reclassification would have to key on `ctx - cc`. The separation in
  the real data is stark — 1 or 2 for the six total misses, ~18,000 for the
  three partial ones — but picking a cutoff between them invents a magnitude
  threshold, which is the exact shape this repo already replaced once with a
  real question (the old 25k floor in the cold detector).
  **Named missing evidence / decision:** either (a) an operator decision to
  accept a stated `ctx - cc` threshold for READ-time relabelling of legacy
  rows, or (b) a decision to start storing `cr` (or `ui`) on new cold rows,
  which makes future rows exact but still leaves these six needing (a), or
  (c) a decision that history stays as recorded and the done-criterion is
  amended. Nothing here is blocked on evidence the repo lacks — it is blocked
  on a choice, which is why this is parked and not ready.

- **PARKED — `--statusline` renders a literal `{` for the project group when
  invoked from the CLI, and once exited 1.** Two observations, kept together
  because they surfaced together; they may be one defect or two.
  **The `{` is DETERMINISTIC and sharply bounded** (re-probed 2026-08-14 after
  the manual rotation): the first token renders as a bare `{` under EVERY
  variable held so far — the operator's real config, a config dir with an empty
  `config.sh`, a config dir with none at all; a real session id, an unknown one;
  a cwd with events and one without; before and after rotation. Exit 0 in all of
  those.
  **And it does NOT reproduce in the real harness.** The operator's own
  statusline renders project and branch correctly (screenshots 2026-08-14:
  `25-06 PV Georgendorf/intern`, `vendor/claude-code-cache-fix (main ×?)`).
  So the discriminator is not config, session, cwd or ledger state — it is
  something in the stdin Claude Code actually sends that a hand-written payload
  lacks. `GROUP_PROJECT` is `"{project} ({git})"`, and one bare `{` is not that
  group failing wholesale, which is the detail any fix should explain.
  **Named missing evidence, now specific:** a captured copy of the REAL stdin
  Claude Code passes to the statusline command. That is one hook-side dump, and
  it converts this from a hunt into a diff against the synthetic payload above.
  **Second, separate observation:** on one run against a minimal synthetic log
  the command exited 1; it has not reproduced since, including in the sweep
  above. Recorded rather than dropped, but the `{` is the tractable half and the
  exit-1 half has no reproduction at all.
  **Why it is parked and not chased:** it surfaced twice inside unrelated work
  (the unknown-flag suite, then the post-rotation verification) and consumed
  several probes each time without converging. No check depends on it —
  `tests/unknown-flags-error.sh` asserts only that `--statusline` is not
  rejected as an unknown flag, never its exit code or output.

## Departed

- 2026-08-14: **unknown flags are named and rejected — SHIPPED `1964d3c`**
  (with `06f1255`, a repair to the guard that this change tripped). The
  argument loop's `*) ;;` discarded anything unrecognised and fell through to
  the default session summary, exit 0 — a typo answered a different question
  confidently. Now: the flag is named on stderr with the --help pointer,
  exit 2. The operator's behaviour-change decision was delegated to the desk
  and taken with the six hook call sites checked FIRST: they pass `log --*`
  (caught by the top-level dispatch, which shifts and exits before the loop)
  and `--statusline` (its own arm), so none reach the new branch.
  **The false-fire controls outnumber the red 19 to 2**, deliberately: the risk
  in this change is rejecting something legitimate, so every mode, every filter
  — including the value-taking ones whose ARGUMENT must not be read as a flag —
  the bare default run, and all six hook sites are pinned in
  `tests/unknown-flags-error.sh`.
  **It also exposed two predicate errors in the older printed-flags guard**
  (`06f1255`), both found by that guard firing on legitimate work: its matcher
  rejected any case pattern containing `|`, so alternation arms like
  `-h|--help|help)` were invisible and `--help` read as unhandled though it has
  always been handled; and it scanned commentary, so it fired on a comment
  naming `--tody` as an example of a typo. Both repaired by narrowing the
  predicate to what the guard always claimed to check, and re-proven in BOTH
  directions — green on the real tree, still red by name on a planted printed
  flag with no arm.

- 2026-08-14: **the residual `other` bucket SPLIT — SHIPPED `841f493`.**
  `cr == 0` now books `no-prefix`, `cr > 0` with no diagnostic keeps `other`.
  Operator-requested 2026-08-13; the name was delegated to the desk and settled
  the same day, with `total-miss` and `cold-start` rejected in the entry before
  it left. Placed BELOW the diagnostic leg so a row with a real
  cache_miss_reason keeps it, and the late-bind upgrade path is untouched by
  construction — it gates on `other`, so a `no-prefix` row is never upgraded,
  which is right: there was no cause to arrive late. Red-first with the pair
  that must DIFFER (cr=0 red-then-green, cr>0 green throughout). One
  pre-existing case went red unplanted — the graceful-degradation case, written
  under a two-valued predicate — and became two cases rather than a flipped
  expectation, which would have kept one path covered and dropped the other.
  FORWARD-ONLY, deliberately; the historical half is parked below.

- 2026-08-14: **`tools/lint.sh --baseline` — SHIPPED `783a35c` + `d3676e9`,
  and the drifted baseline re-pinned.** Diffs a live run against
  `docs/lint-baseline-2026-08-14.txt` and reports NEW / FIXED / unchanged;
  COULD NOT VERIFY when shellcheck or the baseline is missing, never "clean".
  The first cut compared tuple PRESENCE at the (file, SC code) grain the desk
  specified — and the desk's grain was wrong, measured against the lane's own
  new baseline: 38 findings collapsed to 11 tuples, with
  `claude-worktime.sh:SC2034` absorbing 24, so any new unused-variable finding
  in the main script was invisible and the check reported clean. Corrected to
  per-tuple COUNTS in `d3676e9`; dispatcher-probed after, planting a 25th
  SC2034 modelled on the 24 known positives → "25 live vs 24 baseline (+1)",
  exit 1. **The dispatcher's first probe was DEAD** — an appended assignment
  shellcheck never flagged, so the count never moved and the check correctly
  said 0 new, which read exactly like the fix failing. A failure to reproduce
  and a genuine refutation return identical output; the setup is the
  instrument and earns its own positive control first.

- 2026-08-14: **the weekly rotation suffix paired an ISO week number with a
  calendar year — FIXED `5e40c1c`.** Not a booked entry: it surfaced in the
  `(g)` "what was NOT verified" slot of the --doctor lane's report, flagged as
  inherited and out of that lane's scope rather than quietly fixed or quietly
  dropped. `%V` is the ISO week number and its companion year is `%G`;
  2027-01-01 rendered `2027-W53`, a period that does not exist. The severe half
  is ordering: this repo sorts archive suffixes lexicographically as
  chronological, and `2027-W53` sorts after `2027-W01`, so a New Year archive
  would read as newer than every archive for the rest of that year and the
  staleness verdict would report clean for twelve months. Both sites fixed and
  kept byte-identical, since one is compared against the other. Latent —
  `daily` is the shipped default. `tests/rotate-suffix-iso-week.sh` derives the
  formats FROM the script, asserts the ordering property rather than the name,
  and carries a control proving the machine's date(1) reproduces the defect.

- 2026-08-14: **seven entries CLOSED by a retirement pass — each had already
  been resolved by other work, and nobody had closed them.** Found by a
  read-only audit lane that re-checked every open entry's premise against the
  tree by executed command rather than by re-reading the entry's reasoning;
  every verdict below was then independently re-run by the dispatcher before
  the entry left. This is the capture-dominance the session-start banner had
  been reporting (booked ~7 vs closed ~0): the bookings were fine, the closing
  was not happening.
  - `--info` printed at users, not a handled flag — resolved under a DIFFERENT
    name than proposed: the hint now reads `--debug`, which has a real dispatch
    arm (`claude-worktime.sh:3217`) and `tests/printed-flags-are-handled.sh`
    keeping the class shut. The entry's own naming question was answered by the
    fix.
  - `config.sh`'s token list omits 8 tokens — the entry's OWN verifier now
    comes back empty in both directions (set difference over config.sh's
    `{token}` list vs the script's substitution arrays, 36 each, `{peer_name}`
    added since filing).
  - `PROJECT_GIT_ANCHOR` merges the LABEL but not the TOTALS — closed as a side
    effect of the `{project_total}` inflation repair. `in_project($root; $fold)`
    (`claude-worktime.sh:389`) folds the aggregation key on exactly the
    condition that drives the display anchor, so label and total now fold
    identically.
  - the README's `❄` colour cannot be shown in a code block — done-criterion met
    exactly: `assets/cold-fresh-stale.svg` exists and README embeds it.
  - `mode_rotate` kept a second plain-`jq` copy of the first-event guard — it now
    routes through `_safe_log`, identically to `_do_rotate`'s copy.
  - one suite's sandbox rested on an unset ambient env var —
    `tests/replay-cold-corrupt-log.sh:27` now carries the
    `unset CLAUDE_WORKTIME_DATA CLAUDE_WORKTIME_CONFIG` line the rotation suites
    carry.
  - `install.sh:101` `MARKER_END` assigned and never read — resolved via the
    entry's own named "drop it" option; zero hits in install.sh and uninstall.sh,
    both awk blocks using the literal directly.
  **The lesson this pass paid for, worth more than the seven closures:** an
  entry rots by being SILENTLY FIXED elsewhere, and it stays perfectly plausible
  while it does. Six of these seven were closed by repairs aimed at something
  else. A review that reads an entry's reasoning confirms it intact; only
  executing its premise against the tree finds it dead — which is why the audit
  brief forbade verdicts drawn from the entry's own prose.

- 2026-08-14: **a fixture seeding a state filename nothing reads — GUARD BUILT**
  (`tests/state-file-names-are-live.sh`). Booked and built the same day, out of
  the warm-compact repair: three fixtures in `tests/replay-cold-detect.sh` were
  seeding `"$d/.token_prev"`, the pre-split GLOBAL name the detector stopped
  reading at `claude-worktime.sh:1800`. All three read as pinned premises and
  pinned nothing; one was load-bearing, since the zero-usage case's own comment
  claims "only the zero-total rule can skip it" while the dead seed let the
  unchanged-pair gate skip the render too — it would have passed with the rule
  it guards DELETED.
  The guard derives its allow-set from `claude-worktime.sh` on every run rather
  than restating one, so a new state file cannot age it into a silent green.
  Red-first, baseline stated green first: reverting one rename returns exit 1
  naming the file and line, restoring returns 0.
  **Two false fires were found and fixed by predicate, never by softening** —
  both are the reason the guard is trustworthy rather than merely present.
  (1) It fired on `tests/project-total-fold.sh:103`, which names a worktree
  DIRECTORY (`$REPO/.claude/worktrees/...`); the dotname must be the last path
  segment. (2) It fired on its OWN explanatory comment, which names the dead
  file to explain itself; whole-line comments are now stripped on both sides.
  That second one is load-bearing in the other direction too: the abandoned
  `.token_prev` still appears in `claude-worktime.sh:1788` inside the comment
  explaining its abandonment, so a derivation over the raw file would have
  admitted it to the allow-set and passed on the founding defect. The guard
  asserts that negative control on itself and refuses a verdict if it fails.
  **Deviation from the entry as booked:** it landed in `tests/`, not `tools/`.
  The runner discovers suites by glob and advertises that a new `tests/*.sh`
  needs no runner edit; the guard's subject IS the fixtures, so `tests/` is both
  the honest placement and the one that keeps the runner's idiom. Suite 19/19.

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

- 2026-08-08: **per-session `token_prev` — SHIPPED** (`8bfc385`, pushed).
  Landed as `local token_prev="${LOGDIR}/.token_prev_${sid}"`, keyed like the
  existing `.cold_${sid}` state file, so a foreign session's write can no
  longer sit between two renders of the same call and let a duplicate book
  itself as a fresh bust. Red-first proven and INDEPENDENTLY re-run by the
  dispatcher, not booked on the lane's word: `tests/replay-token-prev-session.sh`
  exits 1 against base `5487ec6`'s script and 0 against the fix, with the
  unmutated baseline run first and stated green. Against the old script the
  duplicate render books `hits=1 cc=335933` — the measured 01:00:55Z false ❄;
  against the fix, `hits=0`. Confirming live evidence the same morning: two
  busts, both double-booked, each one `message.id` with identical `(cr,cc)` on
  both rows (638k at 09:48:53Z/09:49:20Z, 141k at 09:59:53Z/10:00:00Z). The
  residual — the guard is an identity PROXY, not identity — did not close with
  it and is carried as its own parked entry.

- 2026-08-08: **consult the diagnostic BEFORE the idle short-circuit —
  SHIPPED** (`8bfc385`, bundled with the item above: same code region, one
  edit). The `_cw_diag` read now runs whenever the hit predicate matches, ahead
  of the idle/model ladder, and `previous_message_not_found` wins outright over
  gap and model — so a genuine resume/fork/compact landing on a long idle gap
  no longer books as an idle bust. The struck `gap > TTL` leg was deliberately
  NOT implemented, per the entry's own blocking vet note: the diagnostic leg
  alone catches the named cases, and that leg would have silenced the whole
  idle class. Verifier ran three-sided, red-first
  (`tests/replay-diag-before-idle.sh`, dispatcher-re-run: exit 1 against base
  `5487ec6`, 0 against the fix): the 23:59:10Z and 03:32:02Z shapes failed as
  expected against OLD while BOTH over-firing controls already PASSED on OLD —
  a genuine mid-history bust and a constructed idle expiry both still book as
  hits. The controls passing on the old code is the point: the red came from
  the diagnostic-precedence cases only, not from a check that fires on
  everything.

- 2026-08-08: **the refusal branch's missing black-box test — BUILT
  (`2b3f553`), and the entry's own premise was REFUTED, which is the part
  worth keeping.** The entry called the branch fixture-unreachable (it "needs
  `:2655` to succeed while `:2662` fails — OOM, file vanishing") and offered
  only two exits: a fault-injection seam, or a note recording it untestable. A
  third existed and cost neither. `_safe_log` is `jq -Rc 'fromjson? // empty'`,
  which passes through any valid JSON including a NON-OBJECT; the collect read
  then evaluates `.type` on it and raises. jq skips the bad input, keeps going,
  and takes its exit status from the LAST input — so a bare scalar on the final
  line makes the reader emit a valid prefix AND exit non-zero, which is exactly
  the property the branch defends. Lesson booked rather than the fix:
  **"unreachable by fixture" is a load-bearing claim and earns the same
  refutation probe as any other** — a five-minute probe overturned it, and was
  cheap precisely because the claim named what would falsify it.

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
