#!/usr/bin/env bash
# `--summary --raw` must not LOSE time when two projects share a label.
#
# The map is built with `reduce .[] as $x ({}; . + {($x.project): $x.active})`,
# keyed on the two-segment label `.../<parent>/<name>`. Two distinct raw paths
# can produce one label — `/one/dev/proj` and `/two/dev/proj` both render
# `dev/proj` — and `+` on an object OVERWRITES the earlier key. One project's
# whole total silently disappears from the output.
#
# Measured on the live log 2026-08-08: 190 keys for 197 distinct raw paths, the
# sum reading 958h20m against a true 967h31m. Pre-existing; `f40e104` did not
# introduce it.
#
# The non-raw branch never had the bug — it prints one row per raw path, so two
# same-labelled projects appear as two lines and no time is lost. Only the
# object-keyed `--raw` map collapses them.
#
# THE FIX IS TO SUM, NOT TO RE-KEY. Summing keeps the contract `--raw` already
# published ({label: seconds}) and makes its total agree with the non-raw
# branch's. Re-keying on the raw path would change the key space under every
# existing consumer to fix a total — a larger change than the defect.
#
# Consumer worth knowing about: tests/project-totals-plausibility.sh sums this
# map. While collisions overwrote, that sum was a LOWER bound and the suite is
# documented as conservative in consequence; with the total conserved it is
# exact, and the invariant it checks (sum <= wall span) holds either way.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../claude-worktime.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

DATA="$TMP/data"; CONF="$TMP/config"
mkdir -p "$DATA" "$CONF"
LOG="$DATA/activity.jsonl"

cw() { CLAUDE_WORKTIME_DATA="$DATA" CLAUDE_WORKTIME_CONFIG="$CONF" bash "$SCRIPT" "$@"; }

now=$(date +%s)
a=$(( now - 20000 ))          # session A
b=$(( a + 3600 ))             # session B, an hour after A's last event

# Two raw paths, one label. Sessions are separated by 3600s and A's last event
# is a `response`, so the crossing gap is idle (> the 900s default) and is
# suppressed — each project's total is its own events only.
#   A: /one/dev/proj  start +60 prompt +60 response         -> 120s
#   B: /two/dev/proj  start +60 prompt +60 response +60 prompt -> 180s
{
  printf '{"t":%d,"p":"/one/dev/proj","b":"main","s":"sA","e":"start"}\n'    "$(( a ))"
  printf '{"t":%d,"p":"/one/dev/proj","b":"main","s":"sA","e":"prompt"}\n'   "$(( a + 60 ))"
  printf '{"t":%d,"p":"/one/dev/proj","b":"main","s":"sA","e":"response"}\n' "$(( a + 120 ))"
  printf '{"t":%d,"p":"/two/dev/proj","b":"main","s":"sB","e":"start"}\n'    "$(( b ))"
  printf '{"t":%d,"p":"/two/dev/proj","b":"main","s":"sB","e":"prompt"}\n'   "$(( b + 60 ))"
  printf '{"t":%d,"p":"/two/dev/proj","b":"main","s":"sB","e":"response"}\n' "$(( b + 120 ))"
  printf '{"t":%d,"p":"/two/dev/proj","b":"main","s":"sB","e":"prompt"}\n'   "$(( b + 180 ))"
} > "$LOG"

EXPECTED=300                  # 120 + 180, derived from the rule, not read off the output

fail=0
raw=$(cw --summary --raw 2>/dev/null)

# Guard the guard: an empty or unparseable map makes every assertion below
# vacuous, and "0 == 0" is what a broken read looks like.
if [ -z "$raw" ] || ! printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1; then
  echo "FAIL: COULD NOT VERIFY — --summary --raw returned no usable object"
  echo "      got: ${raw:-<empty>}"
  exit 1
fi

total=$(printf '%s' "$raw" | jq -r '[.[]] | add // 0' 2>/dev/null)
if [ "${total:-0}" -ne "$EXPECTED" ]; then
  echo "FAIL: --summary --raw totals ${total:-0}s, expected ${EXPECTED}s"
  echo "      two projects share the label 'dev/proj' and one overwrote the other"
  echo "      map: $raw"
  fail=1
fi

# The collision itself is real and stays visible: one key, both totals in it.
keys=$(printf '%s' "$raw" | jq -r 'length' 2>/dev/null)
if [ "${keys:-0}" -ne 1 ]; then
  echo "FAIL: expected the two paths to share 1 label key, found ${keys:-0}"
  echo "      map: $raw"
  fail=1
fi

# The non-raw branch keeps one row per raw path — it never lost the time, and
# this fix must not change it. Two rows, both labelled dev/proj.
rows=$(cw --summary 2>/dev/null | grep -c 'dev/proj' || true)
if [ "${rows:-0}" -ne 2 ]; then
  echo "FAIL: expected 2 rows labelled dev/proj in the non-raw output, found ${rows:-0}"
  cw --summary 2>&1 | sed 's/^/        /'
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: --summary --raw conserves total time when two projects share a label"
fi
exit "$fail"
