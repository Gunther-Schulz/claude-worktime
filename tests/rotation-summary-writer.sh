#!/usr/bin/env bash
# The rotation summary WRITER must credit gaps by the settled per-project rule.
#
# `f40e104` fixed every READ path: walk the FULL sorted stream and credit each
# gap to the project of its EARLIER endpoint (`active_by_project`, :404). The
# writer inside `_do_rotate` kept the old shape — `group_by(.p)` then
# `sort_by(.t) | calc_active` over each per-project SLICE — and a slice treats
# two events adjacent IN THE SLICE as adjacent in time. The interval between
# them is every second the session spent in other repos, and the slice bills all
# of it to this project.
#
# Why it matters more here than anywhere else: a summary record REPLACES the
# events it summarises. A reader cannot repair a value that was mis-computed at
# write time, so the slice defect becomes permanent at the moment of rotation.
#
# THE FIXTURE is one session that moves between two projects mid-tool, which is
# the exact shape the slice cannot see. is_idle suppresses a gap only when its
# predecessor is `response` or `start`, so a gap opened by `tool_start` is
# always billable — the 3600 s straddling gap below is credited in full, to
# whichever project the rule picks.
#
#   t+0     projA  start        gap 60   -> projA user    (pred start)
#   t+60    projA  prompt       gap 60   -> projA claude
#   t+120   projA  tool_start   gap 3600 -> projA claude  (STRADDLES the switch)
#   t+3720  projB  tool_end     gap 60   -> projB claude
#   t+3780  projB  response     gap 60   -> projB user    (pred response, < pause)
#   t+3840  projB  prompt       gap 60   -> projB claude
#   t+3900  projB  response     gap 60   -> projB user
#   t+3960  projA  tool_start   gap 60   -> projA claude
#   t+4020  projA  tool_end
#
# Expected under the settled rule (derived from the rule text at :345-408,
# before the assertion was written — not read off the implementation):
#   projA  active 3780  claude 3720  user 60
#   projB  active  240  claude  120  user 120
#   sum 4020 = the archived events' own wall span, exactly.
#
# Under the OLD writer the same log yields projA active 4020 (the straddling
# gap plus the whole projB excursion) and projB active 180 — sum 4200, which
# EXCEEDS the 4020 s wall span it sits in. Both halves go red.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../claude-worktime.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Sandbox: pass CLAUDE_WORKTIME_DATA/CONFIG explicitly on the invocation rather
# than relying on XDG_DATA_HOME alone. CLAUDE_WORKTIME_DATA takes precedence
# over XDG (:151), so an XDG-only sandbox is correct only while nothing exports
# it — a property of the ambient environment, not of the test. This test
# rotates, and rotation rewrites the log it is pointed at.
DATA="$TMP/data"
CONF="$TMP/config"
mkdir -p "$DATA" "$CONF"
LOG="$DATA/activity.jsonl"

cw() { CLAUDE_WORKTIME_DATA="$DATA" CLAUDE_WORKTIME_CONFIG="$CONF" bash "$SCRIPT" "$@"; }

cutoff=$(date -d "today 00:00" +%s)          # ROTATE_INTERVAL=daily (the default)
suffix=$(date -d "yesterday" +%Y-%m-%d)
ARCHIVE="$DATA/activity-${suffix}.jsonl"
base=$(( cutoff - 86400 + 3600 ))            # yesterday, 01:00
cur=$(( cutoff + 3600 ))                     # today, 01:00

{
  printf '{"t":%d,"p":"projA","b":"main","s":"s1","e":"start"}\n'      "$(( base ))"
  printf '{"t":%d,"p":"projA","b":"main","s":"s1","e":"prompt"}\n'     "$(( base + 60 ))"
  printf '{"t":%d,"p":"projA","b":"main","s":"s1","e":"tool_start"}\n' "$(( base + 120 ))"
  printf '{"t":%d,"p":"projB","b":"main","s":"s1","e":"tool_end"}\n'   "$(( base + 3720 ))"
  printf '{"t":%d,"p":"projB","b":"main","s":"s1","e":"response"}\n'   "$(( base + 3780 ))"
  printf '{"t":%d,"p":"projB","b":"main","s":"s1","e":"prompt"}\n'     "$(( base + 3840 ))"
  printf '{"t":%d,"p":"projB","b":"main","s":"s1","e":"response"}\n'   "$(( base + 3900 ))"
  printf '{"t":%d,"p":"projA","b":"main","s":"s1","e":"tool_start"}\n' "$(( base + 3960 ))"
  printf '{"t":%d,"p":"projA","b":"main","s":"s1","e":"tool_end"}\n'   "$(( base + 4020 ))"
  printf '{"t":%d,"p":"projA","b":"main","s":"s2","e":"start"}\n'      "$(( cur ))"
  printf '{"t":%d,"p":"projA","b":"main","s":"s2","e":"prompt"}\n'     "$(( cur + 60 ))"
} > "$LOG"

WALL_SPAN=4020                               # first..last of the nine archived events

fail=0
out=$(cw --rotate 2>&1)

# Guard the guard: if the sandbox did not take, nothing below means anything.
if [ ! -e "$LOG" ]; then
  echo "FAIL: sandbox log vanished — refusing to interpret the rest"; exit 1
fi
if [ ! -f "$ARCHIVE" ]; then
  echo "FAIL: no archive written — rotation did not run, so the writer was never exercised"
  echo "$out"
  echo "  .rotation_errors: $(cat "$DATA/.rotation_errors" 2>/dev/null || echo none)"
  exit 1
fi

# Field of the single summary record for project $1; "" when absent.
summary_field() {
  jq -Rc 'fromjson? // empty' "$LOG" 2>/dev/null \
    | jq -r --arg p "$1" --arg f "$2" \
        'select(.type == "summary" and .p == $p) | .[$f] // "null"' 2>/dev/null
}

check() {  # $1 project  $2 field  $3 expected
  local got; got=$(summary_field "$1" "$2")
  if [ "$got" != "$3" ]; then
    echo "FAIL: summary for $1 has $2=${got:-<no summary>}, expected $3"
    fail=1
  fi
}

# The written summary must equal what the settled rule reports for these events.
check projA active 3780
check projA claude 3720
check projA user   60
check projB active 240
check projB claude 120
check projB user   120

# One summary per project — not one per (project, slice) or a lost row.
for p in projA projB; do
  n=$(jq -Rc 'fromjson? // empty' "$LOG" 2>/dev/null \
      | jq -s --arg p "$p" 'map(select(.type == "summary" and .p == $p)) | length' 2>/dev/null)
  if [ "${n:-0}" -ne 1 ]; then
    echo "FAIL: expected exactly 1 summary for $p, found ${n:-0}"; fail=1
  fi
done

# The plausibility invariant, applied at WRITE time: the sum of every project's
# archived active time cannot exceed the wall span of the archived events. This
# is the half that stays true no matter which project a straddling gap goes to,
# so it catches slice inflation without re-stating the crediting rule.
total=$(jq -Rc 'fromjson? // empty' "$LOG" 2>/dev/null \
        | jq -s '[.[] | select(.type == "summary") | .active] | add // 0' 2>/dev/null)
case "${total:-}" in
  ''|*[!0-9]*) echo "FAIL: could not sum the written summaries (got '${total:-}')"; fail=1 ;;
  *)
    if [ "$total" -gt "$WALL_SPAN" ]; then
      echo "FAIL: summaries total ${total}s over a ${WALL_SPAN}s wall span — a project's"
      echo "      slice was billed time the session spent in another project"
      fail=1
    fi
    ;;
esac

# The events themselves must still have been archived: a writer fix must not
# quietly turn rotation into a no-op.
arch_n=$(jq -Rc 'fromjson? // empty' "$ARCHIVE" 2>/dev/null \
         | jq -s 'map(select((.type // null) == null)) | length' 2>/dev/null)
if [ "${arch_n:-0}" -ne 9 ]; then
  echo "FAIL: expected 9 archived event records, found ${arch_n:-0}"; fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: rotation writes per-project summaries under the settled crediting rule"
fi
exit "$fail"
