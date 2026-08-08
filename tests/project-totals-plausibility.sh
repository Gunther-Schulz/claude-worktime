#!/usr/bin/env bash
# THE PLAUSIBILITY INVARIANT: the sum of every project's active time cannot
# exceed the log's own first..last wall span. Nobody works 6.6x real time.
#
# WHY THIS EXISTS
# On 2026-08-08 the statusline read `total 2204h44m` for one repo — 251 days of
# attended work inside a log spanning 129. It was found by an operator not
# believing a number, which is the failure mode this file replaces: every
# mechanical check in the repo was green, because each one asked whether a
# project's own total looked sane on its own terms, and each one said yes.
#
# The manual probe that found it is the prototype; this is the mechanism. It is
# arithmetic over the operator's real log, with no fixture and no injection —
# the defect was already there, at 6.6x, on data the tool had been reporting for
# months.
#
# WHAT THIS DOES NOT DO, stated plainly so nobody reads more into a green run:
#
#   * It is a REGRESSION guard on the implementation, not an anomaly detector
#     in the data. Once every gap is credited to exactly one project (see
#     active_by_project in claude-worktime.sh) the gaps are disjoint intervals
#     of the wall span and the invariant holds by construction. What it catches
#     is the day someone reintroduces per-project SLICING, which is exactly how
#     this defect was born and is not an exotic mistake — the slice idiom reads
#     entirely natural.
#   * The REJECTED variant, having been tested rather than reasoned about: the
#     per-project form ("a project's active time cannot exceed its own
#     first..last span") yields ZERO violations against the very log carrying
#     the 90-day gap, because the gap is bounded by the span it sits inside. It
#     is unfalsifiable for this defect class. Do not substitute it.
#   * `--summary --raw` keys its map by a two-segment label, and a collision
#     OVERWRITES rather than adds. The sum is therefore a LOWER bound on the
#     true total, which makes this check conservative: it can under-fire, never
#     over-fire, so a red here is always a true red.
#
# A missing log is COULD NOT VERIFY, not a pass — this suite exits non-zero and
# says which file it wanted, because "0 <= 0" is exactly what a broken read
# looks like.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${CW_SCRIPT:-$HERE/../claude-worktime.sh}"

# Resolve the operator's real data directory BEFORE sandboxing anything, the
# same way the tool resolves it.
REAL_DIR="${CLAUDE_WORKTIME_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/claude-worktime}"
REAL_LOG="$REAL_DIR/activity.jsonl"

TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT

fmt() { # seconds -> 12h34m
  local s=${1:-0}
  printf '%dh%02dm' $(( s / 3600 )) $(( (s % 3600) / 60 ))
}

fails=0

# --------------------------------------------------------------------------
# STEP 1 — earn the right to point step 2 at production.
#
# Step 2 runs the shipped script against the operator's live log, which running
# sessions are appending to and which must never be written by a test. That is
# safe only if `--summary --raw` is provably read-only, so prove it here on a
# sandbox first rather than assuming it: same flags, same code path, and every
# byte and directory entry compared before and after.
# --------------------------------------------------------------------------
unset CLAUDE_WORKTIME_CONFIG
export XDG_CONFIG_HOME="$TMP/config"
SBOX="$TMP/data/claude-worktime"
mkdir -p "$SBOX" "$XDG_CONFIG_HOME/claude-worktime"
SLOG="$SBOX/activity.jsonl"
t0=$(( $(date +%s) - 86400 ))
{
  printf '{"t":%d,"p":"/w/a","b":"main","s":"s1","e":"start"}\n'    "$(( t0 ))"
  printf '{"t":%d,"p":"/w/a","b":"main","s":"s1","e":"prompt"}\n'   "$(( t0 + 60 ))"
  printf '{"t":%d,"p":"/w/b","b":"main","s":"s1","e":"prompt"}\n'   "$(( t0 + 120 ))"
  printf '{"t":%d,"p":"/w/b","b":"main","s":"s1","e":"response"}\n' "$(( t0 + 180 ))"
} > "$SLOG"

before_sum="$(cd "$SBOX" && find . -type f -exec sha256sum {} + | sort)"
sbox_out="$(CLAUDE_WORKTIME_DATA="$SBOX" "$SCRIPT" --summary --raw 2>/dev/null)"
after_sum="$(cd "$SBOX" && find . -type f -exec sha256sum {} + | sort)"

if [ "$before_sum" != "$after_sum" ]; then
  echo "FAIL: --summary --raw MODIFIED its data directory — refusing to run it"
  echo "      against the live log. Diff:"
  diff <(printf '%s\n' "$before_sum") <(printf '%s\n' "$after_sum") | sed 's/^/      /'
  exit 1
fi
# Guard the guard: an invocation that produced nothing proves nothing about
# whether the code path writes, because it may not have run at all.
if [ -z "$sbox_out" ] || [ "$sbox_out" = "{}" ]; then
  echo "FAIL: COULD NOT VERIFY — --summary --raw returned no projects on the"
  echo "      sandbox fixture, so the read-only proof did not exercise it"
  exit 1
fi
echo "  ok   --summary --raw is read-only (sandbox bytes unchanged)"

# --------------------------------------------------------------------------
# STEP 2 — the invariant, on the real log.
# --------------------------------------------------------------------------
if [ ! -s "$REAL_LOG" ]; then
  echo "COULD NOT VERIFY: no activity log at $REAL_LOG"
  echo "  This suite checks a plausibility invariant against real recorded"
  echo "  activity. There is nothing to check here, which is not a pass."
  exit 2
fi

summary="$(CLAUDE_WORKTIME_DATA="$REAL_DIR" "$SCRIPT" --summary --raw 2>/dev/null)"
sum_active="$(printf '%s' "$summary" | jq -r '[.[]] | add // 0' 2>/dev/null)"

# The wall span comes from the same record set --summary reads: with no --since
# the tool reads the live log only (archives join only for since > 0), and it
# drops typed records. A tolerant read, so one malformed line costs one record
# rather than the file.
wall="$(jq -Rc 'fromjson? // empty' "$REAL_LOG" 2>/dev/null \
        | jq -s '[.[] | select((.type // null) == null) | .t] | if length < 2 then 0 else (max - min) end' 2>/dev/null)"

case "${sum_active:-}" in ''|*[!0-9]*) sum_active="" ;; esac
case "${wall:-}" in ''|*[!0-9]*) wall="" ;; esac

if [ -z "$sum_active" ] || [ -z "$wall" ] || [ "$wall" -eq 0 ]; then
  echo "COULD NOT VERIFY: could not read a project sum and a wall span from"
  echo "  $REAL_LOG (sum='${sum_active:-}' wall='${wall:-}')"
  echo "  Nothing was compared; this is not a pass."
  exit 2
fi

nproj="$(printf '%s' "$summary" | jq -r 'length' 2>/dev/null)"
# The ratio is formatted by awk and printed with %s, never handed to bash
# printf as a number: LC_NUMERIC here is de_DE, so awk writes "0.31" while
# bash printf demands "0,31" and answers a valid ratio with "invalid number"
# followed by a silently truncated 0,00 — which reads exactly like a passing
# ratio.
ratio="$(awk -v a="$sum_active" -v w="$wall" 'BEGIN{printf "%.2f", a/w}')"
printf '  log: %s projects, wall span %s, summed active %s (%sx wall)\n' \
  "$nproj" "$(fmt "$wall")" "$(fmt "$sum_active")" "$ratio"

if [ "$sum_active" -gt "$wall" ]; then
  echo "FAIL: the projects together claim more active time than the log spans."
  echo "      summed active $(fmt "$sum_active") > wall span $(fmt "$wall")"
  echo "      A per-project total is counting time the session spent elsewhere —"
  echo "      the signature of walking a per-project slice instead of the full"
  echo "      sorted stream. See active_by_project in claude-worktime.sh."
  fails=$(( fails + 1 ))
else
  echo "  ok   summed active time fits inside the log's wall span"
fi

if [ "$fails" -eq 0 ]; then
  echo "PASS: project totals are plausible against the real log"
fi
exit "$fails"
