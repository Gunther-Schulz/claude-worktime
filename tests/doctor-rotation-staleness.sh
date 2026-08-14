#!/usr/bin/env bash
# --doctor's rotation-staleness verdict: broken when AUTO_ROTATE is on, the
# newest archive is older than 2 rotation periods (or missing entirely), and
# the live log holds entries from before the current period.
#
# Motivating incident (BACKLOG.md): rotation failed 1,052 consecutive times
# over 129 days and nothing noticed — .rotation_errors only prints under
# --debug, which nobody runs unprompted. --doctor is the standing check that
# would have caught it the moment it started, not 129 days later by accident.
#
# Four cases, each rebuilding its own fixture so they cannot bleed into one
# another:
#   1. RED  — stale archive + AUTO_ROTATE=true          -> verified broken
#   2. GREEN — fresh archive + AUTO_ROTATE=true          -> verified clean
#   3. false-fire control — stale archive + AUTO_ROTATE=false -> verified clean
#   4. absent data dir                                   -> COULD NOT VERIFY
#
# Case 1 before case 2 is deliberate: a check proven red on a real defect
# first, then proven green on a clean fixture, is the pair that rules out
# "always red" and "always green" in one pass (see tools/lint.sh, Fixing
# rules on instrument proof).
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

# ---------------------------------------------------------------------------
# Case 1 — RED FIRST. Baseline stated explicitly: --doctor did not exist
# before this suite, so there is no prior green run to protect — this run
# IS the first-contact proof that the check fires on the real defect shape
# (stale archive, live log carrying old entries, AUTO_ROTATE on).
# ---------------------------------------------------------------------------
reset_fixture
LOG="$DATADIR/activity.jsonl"
# One event 5 days old — well before "today 00:00", the daily ROTATE_CUTOFF.
printf '{"t":%d,"p":"%s","b":"main","s":"%s","e":"start"}\n' \
    "$((NOW - 5 * DAY))" "$PROJECT" "$SID" > "$LOG"
# An archive that exists but is stale: 200 days old, well past the 2-day
# (N=2 x daily) threshold.
ARCHIVE="$DATADIR/activity-2025-old.jsonl"
printf '{"t":%d,"p":"%s","b":"main","s":"%s","e":"start"}\n' \
    "$((NOW - 200 * DAY))" "$PROJECT" "$SID" > "$ARCHIVE"
touch -d "@$((NOW - 200 * DAY))" "$ARCHIVE" 2>/dev/null || touch -t "$(date -r "$((NOW - 200 * DAY))" +%Y%m%d%H%M.%S 2>/dev/null)" "$ARCHIVE"

out=$("$SCRIPT" --doctor 2>&1); rc=$?
echo "--- case 1 (stale, AUTO_ROTATE=true) ---"
echo "$out"
echo "(exit $rc)"

if ! grep -q "verified broken" <<<"$out"; then
    echo "FAIL: case 1 expected 'verified broken', got:"; echo "$out"; fail=1
fi
if ! grep -qE '[0-9]+d old' <<<"$out"; then
    echo "FAIL: case 1 expected the archive age in days in the verdict"; echo "$out"; fail=1
fi
if [ "$rc" -eq 0 ]; then
    echo "FAIL: case 1 must exit non-zero on a broken verdict (got 0)"; fail=1
fi

# ---------------------------------------------------------------------------
# Case 2 — GREEN on a hand-built clean fixture: same stale live-log entry
# (so the check does not short-circuit before reaching the archive check),
# but the newest archive is fresh (from today), so it reads as clean.
# ---------------------------------------------------------------------------
reset_fixture
LOG="$DATADIR/activity.jsonl"
printf '{"t":%d,"p":"%s","b":"main","s":"%s","e":"start"}\n' \
    "$((NOW - 5 * DAY))" "$PROJECT" "$SID" > "$LOG"
ARCHIVE="$DATADIR/activity-fresh.jsonl"
printf '{"t":%d,"p":"%s","b":"main","s":"%s","e":"start"}\n' \
    "$((NOW - 5 * DAY))" "$PROJECT" "$SID" > "$ARCHIVE"
# mtime = now (freshly written above) — no touch needed.

out=$("$SCRIPT" --doctor 2>&1); rc=$?
echo "--- case 2 (fresh archive, AUTO_ROTATE=true) ---"
echo "$out"
echo "(exit $rc)"

if ! grep -q "verified clean" <<<"$out"; then
    echo "FAIL: case 2 expected 'verified clean', got:"; echo "$out"; fail=1
fi
if grep -q "verified broken" <<<"$out"; then
    echo "FAIL: case 2 must not report broken over a fresh archive"; echo "$out"; fail=1
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
printf '{"t":%d,"p":"%s","b":"main","s":"%s","e":"start"}\n' \
    "$((NOW - 5 * DAY))" "$PROJECT" "$SID" > "$LOG"
ARCHIVE="$DATADIR/activity-2025-old.jsonl"
printf '{"t":%d,"p":"%s","b":"main","s":"%s","e":"start"}\n' \
    "$((NOW - 200 * DAY))" "$PROJECT" "$SID" > "$ARCHIVE"
touch -d "@$((NOW - 200 * DAY))" "$ARCHIVE" 2>/dev/null || touch -t "$(date -r "$((NOW - 200 * DAY))" +%Y%m%d%H%M.%S 2>/dev/null)" "$ARCHIVE"
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
rm -rf "$DATADIR" "$CONFIGDIR"
mkdir -p "$CONFIGDIR"
# DATADIR intentionally left absent.

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

if [ "$fail" -eq 0 ]; then
    echo "PASS: --doctor rotation staleness verdict — broken/clean/false-fire-control/could-not-verify"
fi
exit "$fail"
