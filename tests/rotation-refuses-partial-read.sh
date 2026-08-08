#!/usr/bin/env bash
# Rotation must REFUSE to archive when the collect read fails part-way, and the
# refusal must come from the COLLECT guard rather than from a later backstop.
#
# `7a949ab` made the collect read in _do_rotate a hard error:
#
#   old_entries=$(_safe_log … | jq -c 'select(…)') || collect_error="true"
#
# It used to end in `|| true`. A dying reader emits everything up to the failure
# and then exits non-zero; `|| true` discarded that status, the emptiness guard
# accepted the PREFIX as the whole set, and the archive step wrote it — measured
# against the real log at 3,964 records against 351,753 valid ones.
#
# THE SEAM — and it needs no fault-injection hook in the script. `_safe_log` is
# `jq -Rc 'fromjson? // empty'`, which passes through any valid JSON, including
# a value that is not an OBJECT. The collect read then evaluates `.type` on it
# and raises "Cannot index number with string". jq reports the error, skips that
# input, continues, and takes its EXIT STATUS FROM THE LAST INPUT — so the bad
# value must be the LAST line. The reader then does precisely what the branch
# defends against: emits a valid partial prefix AND exits 5. The first-event
# guard survives the same file because that one ends in `head -1 || true`.
#
# This corrects the backlog entry that commissioned the test, which recorded the
# branch as reachable by hand-injection only ("it needs :2655 to succeed while
# :2662 fails (OOM, file vanishing mid-run)"). A trailing non-object value does
# exactly that, from data alone — and a bare scalar on its own line is a
# realistic partial-write artifact.
#
# WHY THE BRANCH-IDENTITY ASSERTION CARRIES THE TEST. The summary read two steps
# later is `jq -sc`, which SLURPS: one input, so any bad value anywhere in the
# file fails it. It is therefore strictly more fragile than the streaming
# collect read, and it backstops "no archive" and "log preserved" all by itself
# — those assertions pass even with the collect guard reverted to `|| true`. No
# fixture can make the collect read fail while the summary read succeeds (bad
# value last: both fail; bad value mid-file: only the summary read fails). So
# the assertion that discriminates is WHICH guard wrote to .rotation_errors, and
# it is the one that goes red against the reverted implementation.
#
# WHAT THIS DOES NOT REPRODUCE: OOM, or the file vanishing mid-run. It
# reproduces the PROPERTY the branch exists for — a reader returning a usable
# prefix together with a failure status — not every cause of it.
#
# Set CW_SCRIPT to score a candidate; against a copy whose `|| collect_error`
# is reverted to `|| true`, assertion 4 goes red.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${CW_SCRIPT:-$HERE/../claude-worktime.sh}"
[ -f "$SCRIPT" ] || { echo "missing script: $SCRIPT" >&2; exit 2; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

DATA="$TMP/data"; CONF="$TMP/config"
mkdir -p "$DATA" "$CONF"
LOG="$DATA/activity.jsonl"

cutoff=$(date -d "today 00:00" +%s)          # ROTATE_INTERVAL=daily (the default)
suffix=$(date -d "yesterday" +%Y-%m-%d)
ARCHIVE="$DATA/activity-${suffix}.jsonl"
old=$(( cutoff - 7200 ))                     # yesterday, 22:00

{
  printf '{"t":%d,"p":"projA","b":"main","s":"s1","e":"start"}\n'    "$(( old ))"
  printf '{"t":%d,"p":"projA","b":"main","s":"s1","e":"prompt"}\n'   "$(( old + 60 ))"
  printf '{"t":%d,"p":"projA","b":"main","s":"s1","e":"response"}\n' "$(( old + 120 ))"
  printf '12345\n'                           # valid JSON, not an object, LAST
} > "$LOG"

before_sum=$(md5sum < "$LOG")

fail=0
out=$(CLAUDE_WORKTIME_DATA="$DATA" CLAUDE_WORKTIME_CONFIG="$CONF" \
      bash "$SCRIPT" --rotate 2>&1)

# Guard the guard: the seam holds only if rotation got past its own first-event
# check. Had it stopped at "Nothing to rotate", the collect read would never
# have run and every assertion below would pass for the wrong reason.
if printf '%s' "$out" | grep -q "Nothing to rotate"; then
  echo "FAIL: COULD NOT VERIFY — rotation stopped at the first-event guard, so the"
  echo "      collect read was never exercised; the fixture no longer reaches it"
  echo "      output: $out"
  exit 1
fi

# 1. It must say so, rather than failing silently.
if ! printf '%s' "$out" | grep -q "rotation skipped (data preserved)"; then
  echo "FAIL: rotation did not report a skipped archive on a failed read"
  echo "      output: $out"
  fail=1
fi

# 2. No archive: a partial prefix must never be written as the whole set.
#    (Backstopped by the summary guard — true even with the collect guard gone.)
if [ -f "$ARCHIVE" ]; then
  n=$(jq -Rc 'fromjson? // empty' "$ARCHIVE" 2>/dev/null | jq -s 'length' 2>/dev/null)
  echo "FAIL: an archive was written from a FAILED read — ${n:-?} records at $ARCHIVE"
  fail=1
fi

# 3. Data preserved: the refusal returns before the rewrite, so the live log
#    must be byte-identical. (Also backstopped.)
if [ "$before_sum" != "$(md5sum < "$LOG")" ]; then
  echo "FAIL: the live log was modified despite the refusal — data not preserved"
  fail=1
fi

# 4. THE DISCRIMINATING ASSERTION: the COLLECT guard is what refused, not the
#    summary backstop behind it. This is the one that goes red on `|| true`.
errs=$(cat "$DATA/.rotation_errors" 2>/dev/null || true)
if ! printf '%s' "$errs" | grep -q "could not read the entries to archive"; then
  echo "FAIL: the collect-read guard did not fire. Rotation refused, but a later"
  echo "      guard caught it — the collect read accepted a partial prefix."
  echo "      .rotation_errors: ${errs:-<absent>}"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: the collect-read guard refuses a partial read and preserves the log"
fi
exit "$fail"
