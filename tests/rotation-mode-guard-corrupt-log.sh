#!/usr/bin/env bash
# `--rotate`'s own pre-check must read the log line-tolerantly, like _do_rotate.
#
# `7a949ab` routed _do_rotate's first-event guard through `_safe_log`. mode_rotate
# kept a second, untouched copy of the same guard —
# `jq -r 'select((.type // null) == null) | .t' "$LOGFILE" … | head -1` — which
# parses the whole file as one stream.
#
# THE ORDERING IS THE SPEC, not an incidental fixture detail. Streaming jq emits
# every record it parsed before it dies, so a corrupt line in the MIDDLE still
# yields a first timestamp and the guard is tolerant BY ACCIDENT. It fails only
# where the corrupt line PRECEDES every valid event record: jq dies before
# emitting anything, `first_event_ts` comes back empty, and `--rotate` prints
# "Nothing to rotate (all entries are from current daily period)" over a log
# full of rotatable entries.
#
# That is the could-not-verify answer wearing a pass's clothes — the operator is
# told there is nothing to do, which is indistinguishable from a clean run and
# is exactly the failure `docs/` warns about. Case A is the defect; case B is
# the known positive that shows why case A needed its own fixture.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../claude-worktime.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cutoff=$(date -d "today 00:00" +%s)          # ROTATE_INTERVAL=daily (the default)
suffix=$(date -d "yesterday" +%Y-%m-%d)
old=$(( cutoff - 7200 ))                     # yesterday, 22:00

# The corrupt line's shape is the one the 2026-04-01 writer produced: an
# interpolated fragment whose brace ate the record's own.
CORRUPT='{"t":0,"p":"projA","b":"main","s":"s1","e":"response","cst":{"session_id":"s1"'

fail=0

# $1 case label   $2 "first"|"middle"
run_case() {
  local label=$1 where=$2
  # Sandbox per case: CLAUDE_WORKTIME_DATA/CONFIG passed on the invocation
  # itself, which outranks XDG (:151) and so cannot be defeated by an ambient
  # value the test never mentions. This case rotates.
  local d="$TMP/$where"
  mkdir -p "$d/data" "$d/config"
  local log="$d/data/activity.jsonl"
  local archive="$d/data/activity-${suffix}.jsonl"

  {
    [ "$where" = first ] && printf '%s\n' "$CORRUPT"
    printf '{"t":%d,"p":"projA","b":"main","s":"s1","e":"start"}\n'    "$(( old ))"
    printf '{"t":%d,"p":"projA","b":"main","s":"s1","e":"prompt"}\n'   "$(( old + 60 ))"
    [ "$where" = middle ] && printf '%s\n' "$CORRUPT"
    printf '{"t":%d,"p":"projA","b":"main","s":"s1","e":"response"}\n' "$(( old + 120 ))"
    printf '{"t":%d,"p":"projA","b":"main","s":"s1","e":"prompt"}\n'   "$(( old + 180 ))"
  } > "$log"

  local out
  out=$(CLAUDE_WORKTIME_DATA="$d/data" CLAUDE_WORKTIME_CONFIG="$d/config" \
        bash "$SCRIPT" --rotate 2>&1)

  # Guard the guard: if the sandbox did not take, nothing below means anything.
  if [ ! -e "$log" ]; then
    echo "FAIL [$label]: sandbox log vanished — refusing to interpret the rest"
    fail=1; return
  fi

  if printf '%s' "$out" | grep -q "Nothing to rotate"; then
    echo "FAIL [$label]: --rotate refused with \"Nothing to rotate\" over 4 rotatable"
    echo "       pre-cutoff records — the guard's whole-file jq died on the corrupt"
    echo "       line and its empty result was read as an empty log"
    echo "       output: $out"
    fail=1; return
  fi

  if [ ! -f "$archive" ]; then
    echo "FAIL [$label]: no archive at $archive"
    echo "       output: $out"
    echo "       .rotation_errors: $(cat "$d/data/.rotation_errors" 2>/dev/null || echo none)"
    fail=1; return
  fi

  # All four valid pre-cutoff records must be archived — the guard letting the
  # run START is not the same as the run being correct.
  local n
  n=$(jq -Rc 'fromjson? // empty' "$archive" 2>/dev/null \
      | jq -s 'map(select((.type // null) == null)) | length' 2>/dev/null)
  if [ "${n:-0}" -ne 4 ]; then
    echo "FAIL [$label]: expected 4 archived event records, found ${n:-0}"
    fail=1; return
  fi
}

# Case A — the defect: corrupt line BEFORE every valid event record.
run_case "corrupt line first" first

# Case B — the known positive: same log, corrupt line in the middle. This one
# passes against the OLD code too. It is here so that a green case A cannot be
# mistaken for a fixture that never exercised the ordering.
run_case "corrupt line mid-file" middle

if [ "$fail" -eq 0 ]; then
  echo "PASS: --rotate's pre-check reads the log tolerantly, corrupt line first or mid-file"
fi
exit "$fail"
