#!/usr/bin/env bash
# --doctor's rotation-staleness verdict: broken when AUTO_ROTATE is on, the
# newest archive's own PERIOD SUFFIX (not its mtime) is older than 2
# rotation periods, and the live log holds entries from before the current
# period. No archive at all also counts as broken.
#
# Motivating incident (BACKLOG.md): rotation failed 1,052 consecutive times
# over 129 days and nothing noticed — .rotation_errors only prints under
# --debug, which nobody runs unprompted. --doctor is the standing check that
# would have caught it the moment it started, not 129 days later by accident.
#
# Repair history: the first shipped version of this check read the newest
# archive's file MTIME. mtime is mutable — a `cp`, an `rsync` without -a, a
# backup restore, or a plain `touch` moves it without the archive having
# rotated, and this repo's own data dir carries exactly that kind of copy
# (`activity.jsonl.pre-repair-2026-08-08`). Verified defect: an archive
# named for a period 135 days in the past, with its mtime touched to today,
# read as "verified clean" — a system that has never rotated, reported
# clean. The fix compares the archive's own FILENAME SUFFIX (immutable —
# _do_rotate never renames an archive after writing it) against a threshold
# suffix in the same format, never filesystem metadata. Cases 5 and 6 below
# are the regression pair for exactly this: mtime lies old, mtime lies new.
#
# Cases, each rebuilding its own fixture so they cannot bleed into one another:
#   1. RED  — stale archive suffix + AUTO_ROTATE=true      -> verified broken
#   2. GREEN — fresh archive suffix + AUTO_ROTATE=true      -> verified clean
#   3. false-fire control — stale suffix + AUTO_ROTATE=false -> verified clean
#   4. absent data dir                                      -> COULD NOT VERIFY
#   5. mtime-lies-fresh — OLD suffix, mtime touched to NOW   -> verified broken
#   6. mtime-lies-stale — FRESH suffix, mtime touched to 200d ago -> verified clean
#   7. weekly interval — old vs. recent week suffix          -> broken / clean
#   8. monthly interval — old vs. recent month suffix         -> broken / clean
#
# Case 1 before case 2 is deliberate: a check proven red on a real defect
# first, then proven green on a clean fixture, is the pair that rules out
# "always red" and "always green" in one pass (see tools/lint.sh, Fixing
# rules on instrument proof). Cases 5/6 are that same pair again, isolated
# to the one axis (mtime) the check must now ignore.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../claude-worktime.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# CLAUDE_WORKTIME_DATA/CLAUDE_WORKTIME_CONFIG take precedence over XDG and
# the real defaults (claude-worktime.sh:149-151), so pointing both at this
# suite's own temp dir sandboxes every case: no fixture here ever reads or
# writes the operator's real ~/.local/share/claude-worktime.
DATADIR="$TMP/data"
CONFIGDIR="$TMP/config"
mkdir -p "$DATADIR" "$CONFIGDIR"
export CLAUDE_WORKTIME_DATA="$DATADIR" CLAUDE_WORKTIME_CONFIG="$CONFIGDIR"

SID="synthetic-doctor-fixture-session"
PROJECT="/synthetic/doctor-fixture-project"
NOW=$(date +%s)
DAY=86400

fail=0

reset_fixture() {
    rm -rf "$DATADIR" "$CONFIGDIR"
    mkdir -p "$DATADIR" "$CONFIGDIR"
}

# Epoch -> archive suffix in the given interval's format. Independent of
# production code: plain `date -d @epoch`, the same tool a human would use
# to hand-build a fixture name — not a call into cmd_doctor or its helpers,
# so this cannot move in lockstep with a mutation there.
suffix_at() {
    local epoch="$1" interval="$2"
    case "$interval" in
        daily)   date -d "@$epoch" +%Y-%m-%d 2>/dev/null || date -r "$epoch" +%Y-%m-%d ;;
        weekly)  date -d "@$epoch" +%Y-W%V 2>/dev/null || date -r "$epoch" +%Y-W%V ;;
        monthly) date -d "@$epoch" +%Y-%m 2>/dev/null || date -r "$epoch" +%Y-%m ;;
    esac
}

# touch a file's mtime to an epoch, GNU or BSD.
touch_at() {
    local epoch="$1" file="$2"
    touch -d "@$epoch" "$file" 2>/dev/null || touch -t "$(date -r "$epoch" +%Y%m%d%H%M.%S)" "$file"
}

write_event() {
    local epoch="$1" file="$2"
    printf '{"t":%d,"p":"%s","b":"main","s":"%s","e":"start"}\n' \
        "$epoch" "$PROJECT" "$SID" >> "$file"
}

# ---------------------------------------------------------------------------
# Case 1 — RED FIRST. Baseline: the shipped mtime-based version of this
# check (commit 67cfa9b) read this exact fixture shape as clean, verified by
# the dispatcher directly against the real data dir. This run is the
# first-contact proof that the SUFFIX-based repair fires on the defect shape.
# ---------------------------------------------------------------------------
reset_fixture
LOG="$DATADIR/activity.jsonl"
write_event "$((NOW - 5 * DAY))" "$LOG"
ARCHIVE="$DATADIR/activity-$(suffix_at "$((NOW - 200 * DAY))" daily).jsonl"
write_event "$((NOW - 200 * DAY))" "$ARCHIVE"

out=$("$SCRIPT" --doctor 2>&1); rc=$?
echo "--- case 1 (stale suffix, AUTO_ROTATE=true) ---"
echo "$out"
echo "(exit $rc)"

if ! grep -q "verified broken" <<<"$out"; then
    echo "FAIL: case 1 expected 'verified broken', got:"; echo "$out"; fail=1
fi
if ! grep -q "predates the staleness threshold" <<<"$out"; then
    echo "FAIL: case 1 expected the threshold reasoning in the verdict"; echo "$out"; fail=1
fi
if [ "$rc" -eq 0 ]; then
    echo "FAIL: case 1 must exit non-zero on a broken verdict (got 0)"; fail=1
fi

# ---------------------------------------------------------------------------
# Case 2 — GREEN on a hand-built clean fixture: same stale live-log entry
# (so the check does not short-circuit before reaching the archive check),
# but the newest archive's suffix is yesterday's — within the 2-day threshold.
# ---------------------------------------------------------------------------
reset_fixture
LOG="$DATADIR/activity.jsonl"
write_event "$((NOW - 5 * DAY))" "$LOG"
ARCHIVE="$DATADIR/activity-$(suffix_at "$((NOW - 1 * DAY))" daily).jsonl"
write_event "$((NOW - 1 * DAY))" "$ARCHIVE"

out=$("$SCRIPT" --doctor 2>&1); rc=$?
echo "--- case 2 (fresh suffix, AUTO_ROTATE=true) ---"
echo "$out"
echo "(exit $rc)"

if ! grep -q "verified clean" <<<"$out"; then
    echo "FAIL: case 2 expected 'verified clean', got:"; echo "$out"; fail=1
fi
if grep -q "verified broken" <<<"$out"; then
    echo "FAIL: case 2 must not report broken over a fresh archive suffix"; echo "$out"; fail=1
fi
if [ "$rc" -ne 0 ]; then
    echo "FAIL: case 2 must exit 0 on an all-clean verdict (got $rc)"; fail=1
fi

# ---------------------------------------------------------------------------
# Case 3 — false-fire control. Identical stale fixture to case 1, but
# AUTO_ROTATE=false: the deliberate guard must keep this clean. Not optional
# — without it the check fires on every machine with rotation off on purpose.
# ---------------------------------------------------------------------------
reset_fixture
LOG="$DATADIR/activity.jsonl"
write_event "$((NOW - 5 * DAY))" "$LOG"
ARCHIVE="$DATADIR/activity-$(suffix_at "$((NOW - 200 * DAY))" daily).jsonl"
write_event "$((NOW - 200 * DAY))" "$ARCHIVE"
printf 'AUTO_ROTATE=false\n' > "$CONFIGDIR/config.sh"

out=$("$SCRIPT" --doctor 2>&1); rc=$?
echo "--- case 3 (stale, AUTO_ROTATE=false control) ---"
echo "$out"
echo "(exit $rc)"

if ! grep -q "verified clean" <<<"$out"; then
    echo "FAIL: case 3 (AUTO_ROTATE=false) expected 'verified clean', got:"; echo "$out"; fail=1
fi
if grep -q "verified broken" <<<"$out"; then
    echo "FAIL: case 3 (AUTO_ROTATE=false) must never report broken — this is the"
    echo "      guard-fires-on-a-non-defect shape the AUTO_ROTATE guard exists to prevent"
    echo "$out"; fail=1
fi
if [ "$rc" -ne 0 ]; then
    echo "FAIL: case 3 must exit 0 (AUTO_ROTATE off is a clean verdict, got $rc)"; fail=1
fi

# ---------------------------------------------------------------------------
# Case 4 — absent data dir must be COULD NOT VERIFY, never clean. A missing
# directory silently reading as "nothing to check" is the same failure shape
# case 1 exists to close, one layer up.
# ---------------------------------------------------------------------------
reset_fixture
rm -rf "$DATADIR"
# DATADIR intentionally left absent; CONFIGDIR stays.

out=$("$SCRIPT" --doctor 2>&1); rc=$?
echo "--- case 4 (absent data dir) ---"
echo "$out"
echo "(exit $rc)"

if ! grep -q "COULD NOT VERIFY" <<<"$out"; then
    echo "FAIL: case 4 (absent data dir) expected 'COULD NOT VERIFY', got:"; echo "$out"; fail=1
fi
if grep -q "verified clean" <<<"$out"; then
    echo "FAIL: case 4 must not read an absent data dir as clean"; echo "$out"; fail=1
fi
if [ "$rc" -eq 0 ]; then
    echo "FAIL: case 4 (COULD NOT VERIFY) must not exit 0 silently (got 0)"; fail=1
fi

# ---------------------------------------------------------------------------
# Case 5 — mtime-lies-fresh: the exact reported defect. Archive named for a
# period well past the threshold, but its mtime is touched to right now
# (mimicking a cp/rsync/backup-restore that preserves nothing or a plain
# touch). Must still read broken — the suffix decides, not the inode.
# ---------------------------------------------------------------------------
reset_fixture
LOG="$DATADIR/activity.jsonl"
write_event "$((NOW - 200 * DAY))" "$LOG"
ARCHIVE="$DATADIR/activity-$(suffix_at "$((NOW - 200 * DAY))" daily).jsonl"
write_event "$((NOW - 200 * DAY))" "$ARCHIVE"
touch_at "$NOW" "$ARCHIVE"   # mtime lies: says "just rotated"

out=$("$SCRIPT" --doctor 2>&1); rc=$?
echo "--- case 5 (mtime-lies-fresh: old suffix, mtime = now) ---"
echo "$out"
echo "(exit $rc)"

if ! grep -q "verified broken" <<<"$out"; then
    echo "FAIL: case 5 (mtime-lies-fresh) expected 'verified broken' — a fresh mtime on a"
    echo "      stale-suffix archive must not read as clean"; echo "$out"; fail=1
fi
if [ "$rc" -eq 0 ]; then
    echo "FAIL: case 5 must exit non-zero (got 0)"; fail=1
fi

# ---------------------------------------------------------------------------
# Case 6 — mtime-lies-stale: the mirror false-fire control on the mtime
# axis. Archive named for a period well within the threshold, but its mtime
# is touched 200 days into the past. Must still read clean — the repair
# must not simply invert which metadata it trusts.
# ---------------------------------------------------------------------------
reset_fixture
LOG="$DATADIR/activity.jsonl"
write_event "$((NOW - 5 * DAY))" "$LOG"
ARCHIVE="$DATADIR/activity-$(suffix_at "$((NOW - 1 * DAY))" daily).jsonl"
write_event "$((NOW - 1 * DAY))" "$ARCHIVE"
touch_at "$((NOW - 200 * DAY))" "$ARCHIVE"   # mtime lies: says "ancient"

out=$("$SCRIPT" --doctor 2>&1); rc=$?
echo "--- case 6 (mtime-lies-stale: fresh suffix, mtime = 200d ago) ---"
echo "$out"
echo "(exit $rc)"

if ! grep -q "verified clean" <<<"$out"; then
    echo "FAIL: case 6 (mtime-lies-stale) expected 'verified clean' — a stale mtime on a"
    echo "      fresh-suffix archive must not read as broken"; echo "$out"; fail=1
fi
if grep -q "verified broken" <<<"$out"; then
    echo "FAIL: case 6 must not report broken purely from an old mtime"; echo "$out"; fail=1
fi
if [ "$rc" -ne 0 ]; then
    echo "FAIL: case 6 must exit 0 (got $rc)"; fail=1
fi

# ---------------------------------------------------------------------------
# Case 7 — weekly interval must not regress: old week suffix -> broken,
# recent week suffix -> clean. Weekly is where a suffix-comparison repair
# would most plausibly break, since %Y-W%V is not the same string shape as
# the daily %Y-%m-%d format the earlier cases exercise.
# ---------------------------------------------------------------------------
reset_fixture
printf 'ROTATE_INTERVAL=weekly\n' > "$CONFIGDIR/config.sh"
LOG="$DATADIR/activity.jsonl"
write_event "$((NOW - 60 * DAY))" "$LOG"
ARCHIVE="$DATADIR/activity-$(suffix_at "$((NOW - 60 * DAY))" weekly).jsonl"
write_event "$((NOW - 60 * DAY))" "$ARCHIVE"

out=$("$SCRIPT" --doctor 2>&1); rc=$?
echo "--- case 7a (weekly, old week suffix) ---"
echo "$out"
echo "(exit $rc)"
if ! grep -q "verified broken" <<<"$out"; then
    echo "FAIL: case 7a (weekly, stale) expected 'verified broken', got:"; echo "$out"; fail=1
fi

reset_fixture
printf 'ROTATE_INTERVAL=weekly\n' > "$CONFIGDIR/config.sh"
LOG="$DATADIR/activity.jsonl"
write_event "$((NOW - 60 * DAY))" "$LOG"
ARCHIVE="$DATADIR/activity-$(suffix_at "$((NOW - 7 * DAY))" weekly).jsonl"
write_event "$((NOW - 7 * DAY))" "$ARCHIVE"

out=$("$SCRIPT" --doctor 2>&1); rc=$?
echo "--- case 7b (weekly, recent week suffix) ---"
echo "$out"
echo "(exit $rc)"
if ! grep -q "verified clean" <<<"$out"; then
    echo "FAIL: case 7b (weekly, fresh) expected 'verified clean', got:"; echo "$out"; fail=1
fi

# ---------------------------------------------------------------------------
# Case 8 — monthly interval must not regress: old month suffix -> broken,
# recent month suffix -> clean.
# ---------------------------------------------------------------------------
reset_fixture
printf 'ROTATE_INTERVAL=monthly\n' > "$CONFIGDIR/config.sh"
LOG="$DATADIR/activity.jsonl"
write_event "$((NOW - 200 * DAY))" "$LOG"
ARCHIVE="$DATADIR/activity-$(suffix_at "$((NOW - 200 * DAY))" monthly).jsonl"
write_event "$((NOW - 200 * DAY))" "$ARCHIVE"

out=$("$SCRIPT" --doctor 2>&1); rc=$?
echo "--- case 8a (monthly, old month suffix) ---"
echo "$out"
echo "(exit $rc)"
if ! grep -q "verified broken" <<<"$out"; then
    echo "FAIL: case 8a (monthly, stale) expected 'verified broken', got:"; echo "$out"; fail=1
fi

reset_fixture
printf 'ROTATE_INTERVAL=monthly\n' > "$CONFIGDIR/config.sh"
LOG="$DATADIR/activity.jsonl"
write_event "$((NOW - 200 * DAY))" "$LOG"
ARCHIVE="$DATADIR/activity-$(suffix_at "$((NOW - 20 * DAY))" monthly).jsonl"
write_event "$((NOW - 20 * DAY))" "$ARCHIVE"

out=$("$SCRIPT" --doctor 2>&1); rc=$?
echo "--- case 8b (monthly, recent month suffix) ---"
echo "$out"
echo "(exit $rc)"
if ! grep -q "verified clean" <<<"$out"; then
    echo "FAIL: case 8b (monthly, fresh) expected 'verified clean', got:"; echo "$out"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "PASS: --doctor rotation staleness — suffix-based verdict across broken/clean/false-fire-control/could-not-verify/mtime-lies (both directions)/weekly/monthly"
fi
exit "$fail"
