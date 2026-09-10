#!/usr/bin/env bash
# A cost record is logged when THIS session's cost changed — never because a
# different session rendered in between.
#
# WHY THIS EXISTS
# The statusline appends {"type":"cost"} to the activity log whenever the cost
# it was handed differs from the last one it saw. "The last one it saw" was a
# single GLOBAL state file (.last_cost), while every open session renders its
# own statusline. So two sessions rendering alternately flip that file on each
# render, and every flip appends a record although neither session's cost
# moved. Measured on the operator's live log 2026-09-10: 4365 cost records
# that day, 2110 of them following a record from a different session; in the
# last hour 293 of 491, across 5 sessions. The duplicates are silent — the log
# just grows, and every query that reads it gets slower.
#
# It stopped being a slow leak the moment the statusline could be re-run on a
# timer (Claude Code's statusLine.refreshInterval): idle sessions then render
# in round-robin every few seconds, and nearly every render is a flip.
#
# The fix keys the state per session, the way .cold_<sid> and
# .token_prev_<sid> already are.
#
# THE CASES, and why each is there:
#   0. One render logs exactly one record. The instrument's known-positive:
#      without it, "no new records" in case 1 is satisfied by a render that
#      never logs anything at all (a dead cost block, or a sandbox that did
#      not take).
#   1. The defect: alternating renders with unchanged costs add nothing.
#      Red on the global state file.
#   2. The discriminator for the fix: a real cost change still logs, exactly
#      once, and a repeat of the same cost does not. A "fix" that stops
#      logging cost altogether passes case 1 and fails here.
#
# All session ids here are SYNTHESIZED. This repo is public.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

SCRIPT="${CW_SCRIPT:-./claude-worktime.sh}"
[ -f "$SCRIPT" ] || { echo "missing script: $SCRIPT" >&2; exit 2; }

TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT

# Sandbox BOTH XDG roots and drop the direct overrides, or a real config.sh —
# or CLAUDE_WORKTIME_DATA in the environment — points this at the live log.
unset CLAUDE_WORKTIME_DATA CLAUDE_WORKTIME_CONFIG CLAUDE_SESSIONS_DIR
export XDG_DATA_HOME="$TMP/data" XDG_CONFIG_HOME="$TMP/config"
LOGDIR="$XDG_DATA_HOME/claude-worktime"
CFGDIR="$XDG_CONFIG_HOME/claude-worktime"
mkdir -p "$LOGDIR" "$CFGDIR"
LOG="$LOGDIR/activity.jsonl"

SID_A="synthetic-session-id-alpha"
SID_B="synthetic-session-id-bravo"

# A non-git cwd, so nothing in the render depends on a repository.
CWD="$TMP/wsp/demo-project"
mkdir -p "$CWD"

cat > "$CFGDIR/config.sh" <<EOF
AUTO_ROTATE=false
COLD_NOTIFY=false
PROJECT_GIT_ANCHOR=false
HOME_ORG=""
USAGE_FETCH_INTERVAL=0
STATUSLINE_1="PROJECT"
STATUSLINE_2=""
STATUSLINE_3=""
EOF

# One event, yesterday, so the log exists and nothing moves with the clock.
T=$(( $(date -d "today 00:00" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$(date +%Y-%m-%d) 00:00:00" +%s) - 3600 ))
printf '{"t":%d,"p":"%s","b":"","s":"%s","e":"prompt"}\n' "$T" "$CWD" "$SID_A" > "$LOG"

render() { # session-id cost
  # The trailing newline is load-bearing: _read_hook_stdin gates on `read`
  # succeeding, and read returns false at EOF on an unterminated line.
  printf '{"session_id":"%s","cwd":"%s","cost":{"total_cost_usd":%s}}\n' "$1" "$CWD" "$2" \
    | "$SCRIPT" --statusline >/dev/null 2>&1
}

# Counted over PARSED records, never a substring match on the raw log line.
records() { # [session-id] -> number of cost records (for that session)
  jq -c 'select(.type == "cost")' "$LOG" 2>/dev/null \
    | jq -s --arg s "${1:-}" 'map(select($s == "" or .s == $s)) | length'
}

fails=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then
    printf '  ok   %-62s -> %s\n' "$1" "$3"
  else
    printf '  FAIL %-62s -> %s (expected %s)\n' "$1" "$3" "$2"
    fails=$((fails + 1))
  fi
}

# 0. known-positive
render "$SID_A" 1.25
check "0. first render of a session logs one record" 1 "$(records "$SID_A")"
if [ "$(records)" != 1 ]; then
  echo "FAIL: the known-positive did not hold — every later case would be vacuous"
  exit 1
fi

# 1. the defect: another session in between must not re-log an unchanged cost
render "$SID_B" 2.50
check "1a. a second session's first render logs its own record" 1 "$(records "$SID_B")"
for _ in 1 2 3; do
  render "$SID_A" 1.25
  render "$SID_B" 2.50
done
check "1b. alternating renders, unchanged costs: no new records" 2 "$(records)"

# 2. the discriminator: a real change still logs, once
render "$SID_A" 1.75
render "$SID_A" 1.75
check "2a. a changed cost logs exactly one new record" 2 "$(records "$SID_A")"
last_a=$(jq -c 'select(.type == "cost")' "$LOG" | jq -rs --arg s "$SID_A" 'map(select(.s == $s)) | last | .cost')
check "2b. that record carries the new cost" 1.75 "$last_a"
check "2c. the other session is untouched" 1 "$(records "$SID_B")"

[ "$fails" -eq 0 ] && echo "PASS: cost records are deduplicated per session" \
                   || echo "FAIL: $fails case(s)"
exit "$fails"
