#!/usr/bin/env bash
# The statusline must name OTHER sessions on this machine that are waiting for
# the operator, and must add nothing at all when there are none.
#
# WHY THIS EXISTS
# A session blocked on an approval is invisible from every other terminal. A
# desktop toast is a moment, not a state, and for at least one waiting class no
# hook event fires at all — so nothing in the terminal you are looking at tells
# you another one is stuck. Measured incident: a session sat >30 min holding a
# prompt and was never noticed. Claude Code publishes the answer in the same
# registry {peer_name} already reads: `~/.claude/sessions/<pid>.json`, one file
# per live session, carrying `status` and `statusUpdatedAt`.
#
# THE HAZARD, and why the negative cases outnumber the positive ones: that
# registry is an UNDOCUMENTED internal format. It may move, change shape, or
# vanish under any CLI update. A statusline that errors or leaks a stray
# divider when the read fails would trade a missing convenience for a broken
# display on every refresh. So the contract is: on a qualifying wait, one extra
# segment; on ANYTHING else — no dir, no files, no waiter, unparseable file,
# missing field, dead pid, wait too short — the output is byte-identical to a
# line configured without the group, and the exit status is unchanged.
#
# Byte-identical against WHAT: each fail-soft case is compared to the same
# render with ATTENTION removed from the line, not to a remembered string. An
# empty group that still emitted its ` · ` divider would pass a
# contains-no-name check and fail this one.
#
# Case 1 is the instrument's known-positive: without it, every fail-soft case
# below is satisfied by a lookup that can never fire. Case 2 (under threshold)
# and case 4 (dead pid) are its discriminators — an implementation that shows
# every `waiting` entry regardless passes case 1 alone.
#
# THE THRESHOLD IS NOT DECORATION: routine approvals resolve in seconds
# (measured: 4s, 16s and 12s waits during ordinary cross-session traffic). A
# line that fires on those flickers constantly, and a line that usually says
# nothing is one the operator stops reading — precisely on the day it matters.
#
# All session ids and names here are SYNTHESIZED. This repo is public and
# nothing from the live registry belongs in it.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

SCRIPT="./claude-worktime.sh"
[ -f "$SCRIPT" ] || { echo "missing script: $SCRIPT" >&2; exit 2; }

TMP="$(mktemp -d)" || exit 1

# A live process that is NOT an ancestor of the render: the token deliberately
# skips this session's own pid, and the test script's own $$ IS an ancestor of
# the statusline it spawns — using it for the positive case would test the
# exclusion, not the display.
sleep 300 &
LIVE_PID=$!
sleep 300 &
LIVE_PID2=$!
sleep 300 &
LIVE_PID3=$!
sleep 300 &
LIVE_PID4=$!

# A pid that is reliably dead: started, killed, and reaped here.
sleep 300 &
DEAD_PID=$!
kill "$DEAD_PID" 2>/dev/null
wait "$DEAD_PID" 2>/dev/null

cleanup() {
  kill "$LIVE_PID" "$LIVE_PID2" "$LIVE_PID3" "$LIVE_PID4" 2>/dev/null
  wait "$LIVE_PID" "$LIVE_PID2" "$LIVE_PID3" "$LIVE_PID4" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

# Sandbox BOTH XDG roots and drop the direct overrides, or a real config.sh —
# or CLAUDE_WORKTIME_DATA in the environment — points this at the operator's
# live log. CLAUDE_SESSIONS_DIR is unset for the same reason: inherited, it
# would point every case at the live registry and make results depend on
# whatever the operator's machine happens to be doing.
unset CLAUDE_WORKTIME_DATA CLAUDE_WORKTIME_CONFIG CLAUDE_SESSIONS_DIR
export XDG_DATA_HOME="$TMP/data" XDG_CONFIG_HOME="$TMP/config"
LOGDIR="$XDG_DATA_HOME/claude-worktime"
CFGDIR="$XDG_CONFIG_HOME/claude-worktime"
mkdir -p "$LOGDIR" "$CFGDIR"
LOG="$LOGDIR/activity.jsonl"

SID="synthetic-session-id-alpha"
NAME_A="example-session-aa"
NAME_B="example-session-bb"
NAME_C="example-session-cc"
NAME_D="example-session-dd"

# A non-git cwd, so {git} renders the same in every run below and cannot make
# two otherwise-identical renders differ.
CWD="$TMP/wsp/demo-project"
mkdir -p "$CWD"

# One event, yesterday, so nothing in the rendered groups moves with the clock.
T=$(( $(date -d "today 00:00" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$(date +%Y-%m-%d) 00:00:00" +%s) - 3600 ))
printf '{"t":%d,"p":"%s","b":"","s":"%s","e":"prompt"}\n' "$T" "$CWD" "$SID" > "$LOG"

NOW_MS=$(( $(date +%s) * 1000 ))

fails=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then
    printf '  ok   %-58s -> %s\n' "$1" "$3"
  else
    printf '  FAIL %-58s -> %s (expected %s)\n' "$1" "$3" "$2"
    fails=$((fails + 1))
  fi
}

write_config() { # line-1 group list
  cat > "$CFGDIR/config.sh" <<EOF
AUTO_ROTATE=false
COLD_NOTIFY=false
PROJECT_GIT_ANCHOR=false
HOME_ORG=""
USAGE_FETCH_INTERVAL=0
STATUSLINE_1="$1"
STATUSLINE_2=""
STATUSLINE_3=""
EOF
}

render() { # sessions-dir -> rendered statusline (RAW bytes, ANSI kept)
  printf '{"session_id":"%s","cwd":"%s"}\n' "$SID" "$CWD" \
    | CLAUDE_SESSIONS_DIR="$1" "$SCRIPT" --statusline 2>/dev/null
}

plain_of() { printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g'; }

# pid name status age-seconds dir
waiter() {
  mkdir -p "$5"
  printf '{"pid":%d,"sessionId":"synthetic-%d","name":"%s","nameSource":"cwd","status":"%s","cwd":"/tmp/x","updatedAt":%d,"statusUpdatedAt":%d,"peerProtocol":1}' \
    "$1" "$1" "$2" "$3" "$(( NOW_MS - $4 * 1000 ))" "$(( NOW_MS - $4 * 1000 ))" \
    > "$5/$1.json"
}

# ---------------------------------------------------------------------------
# The baseline: the same render with the attention group absent from the line.
# Every fail-soft case below must equal this, byte for byte.
# ---------------------------------------------------------------------------
write_config "PROJECT"
BASE="$(render "$TMP/does-not-exist")"
if [ -z "$BASE" ]; then
  echo "FAIL: the baseline render is empty — the sandbox did not take, and an"
  echo "      empty string would let every byte-identity check below pass vacuously"
  exit 1
fi
printf '  baseline: %s\n' "$(plain_of "$BASE")"

write_config "PROJECT ATTENTION"

# ---------------------------------------------------------------------------
# 1. THE POSITIVE (known-positive for every absence check below): a live
#    session waiting longer than the threshold is named, with its age.
# ---------------------------------------------------------------------------
D1="$TMP/s1"; waiter "$LIVE_PID" "$NAME_A" "waiting" 900 "$D1"
out="$(render "$D1")"; rc=$?
plain="$(plain_of "$out")"
case "$plain" in
  *"$NAME_A"*) check "a live session waiting 15m is named" "0" "0" ;;
  *) printf '  FAIL %-58s -> %s\n' "a live session waiting 15m is named" "$plain"
     fails=$((fails + 1)) ;;
esac
case "$plain" in
  *"waiting on you"*) check "the line says what it wants" "0" "0" ;;
  *) printf '  FAIL %-58s -> %s\n' "the line says what it wants" "$plain"
     fails=$((fails + 1)) ;;
esac
case "$plain" in
  *"15m"*) check "the age is rendered" "0" "0" ;;
  *) printf '  FAIL %-58s -> %s\n' "the age is rendered (expected 15m)" "$plain"
     fails=$((fails + 1)) ;;
esac
check "exit status with a waiter present" "0" "$rc"

# ---------------------------------------------------------------------------
# 2. DISCRIMINATOR — under the threshold. An implementation that shows every
#    `waiting` entry passes case 1 and fails here. This is the case that keeps
#    the line from flickering on routine approvals.
# ---------------------------------------------------------------------------
D2="$TMP/s2"; waiter "$LIVE_PID" "$NAME_A" "waiting" 5 "$D2"
out="$(render "$D2")"; rc=$?
check "waiting only 5s: output unchanged, byte for byte" "$BASE" "$out"
check "waiting only 5s: exit status" "0" "$rc"

# ---------------------------------------------------------------------------
# 3. Not waiting at all — busy and idle are not attention.
# ---------------------------------------------------------------------------
D3="$TMP/s3"; waiter "$LIVE_PID" "$NAME_A" "busy" 900 "$D3"
waiter "$LIVE_PID2" "$NAME_B" "idle" 900 "$D3"
out="$(render "$D3")"; rc=$?
check "busy and idle sessions are not listed" "$BASE" "$out"
check "busy/idle: exit status" "0" "$rc"

# ---------------------------------------------------------------------------
# 4. DISCRIMINATOR — the staleness contract. A registry file outlives its
#    process, so a crashed session must not show as waiting forever.
# ---------------------------------------------------------------------------
D4="$TMP/s4"; waiter "$DEAD_PID" "$NAME_A" "waiting" 900 "$D4"
out="$(render "$D4")"; rc=$?
check "waiting but pid is dead: output unchanged" "$BASE" "$out"
check "dead pid: exit status" "0" "$rc"

# ---------------------------------------------------------------------------
# 5. This session is never listed. Our own session's pid is an ancestor of the
#    statusline process; $$ is this test, which is exactly that ancestor.
# ---------------------------------------------------------------------------
D5="$TMP/s5"; waiter "$$" "$NAME_A" "waiting" 900 "$D5"
out="$(render "$D5")"; rc=$?
check "our own session is not listed" "$BASE" "$out"
check "own session: exit status" "0" "$rc"

# ---------------------------------------------------------------------------
# 6. Fail-soft arms: every shape of unreadable registry.
# ---------------------------------------------------------------------------
D6="$TMP/s6"; mkdir -p "$D6"
printf '{"pid":4242,"status":' > "$D6/4242.json"      # truncated mid-object
out="$(render "$D6")"; rc=$?
check "unparseable registry file: output unchanged" "$BASE" "$out"
check "unparseable registry file: exit status" "0" "$rc"

D7="$TMP/s7"; mkdir -p "$D7"                          # exists, holds no *.json
printf 'x' > "$D7/4242.key"
out="$(render "$D7")"; rc=$?
check "registry dir with no session files: output unchanged" "$BASE" "$out"

out="$(render "$TMP/no-such-dir")"; rc=$?
check "registry dir missing entirely: output unchanged" "$BASE" "$out"
check "registry dir missing entirely: exit status" "0" "$rc"

# A file with NO status field at all — observed live: a session file exists for
# a moment before the field is populated.
D8="$TMP/s8"; mkdir -p "$D8"
printf '{"pid":%d,"sessionId":"x","name":"%s","peerProtocol":1}' \
  "$LIVE_PID" "$NAME_A" > "$D8/$LIVE_PID.json"
out="$(render "$D8")"; rc=$?
check "session file with no status field: output unchanged" "$BASE" "$out"
check "no status field: exit status" "0" "$rc"

# Waiting, live, old enough — but no `name` to show.
D9="$TMP/s9"; mkdir -p "$D9"
printf '{"pid":%d,"status":"waiting","statusUpdatedAt":%d,"peerProtocol":1}' \
  "$LIVE_PID" "$(( NOW_MS - 900000 ))" > "$D9/$LIVE_PID.json"
out="$(render "$D9")"; rc=$?
check "waiting but nameless: output unchanged" "$BASE" "$out"

# ---------------------------------------------------------------------------
# 7. THE KEY-PREFIX HAZARD. `statusUpdatedAt` CONTAINS the string `status`.
#    An unanchored key match would read the timestamp as the state — and a
#    numeric timestamp is not "waiting", so the visible symptom would be a
#    token that silently never fires. Here the file has statusUpdatedAt but no
#    status: nothing may be shown, and nothing may error.
# ---------------------------------------------------------------------------
DA="$TMP/sa"; mkdir -p "$DA"
printf '{"pid":%d,"name":"%s","statusUpdatedAt":%d,"peerProtocol":1}' \
  "$LIVE_PID" "$NAME_A" "$(( NOW_MS - 900000 ))" > "$DA/$LIVE_PID.json"
out="$(render "$DA")"; rc=$?
check "statusUpdatedAt is not read as status" "$BASE" "$out"

# The mirror: a real status field must still be found when statusUpdatedAt
# precedes it in the object, so the anchoring is not order-dependent.
DB="$TMP/sb"; mkdir -p "$DB"
printf '{"pid":%d,"statusUpdatedAt":%d,"status":"waiting","name":"%s","peerProtocol":1}' \
  "$LIVE_PID" "$(( NOW_MS - 900000 ))" "$NAME_A" > "$DB/$LIVE_PID.json"
out="$(render "$DB")"
plain="$(plain_of "$out")"
case "$plain" in
  *"$NAME_A"*) check "status found when statusUpdatedAt precedes it" "0" "0" ;;
  *) printf '  FAIL %-58s -> %s\n' "status found when statusUpdatedAt precedes it" "$plain"
     fails=$((fails + 1)) ;;
esac

# ---------------------------------------------------------------------------
# 8. ORDER AND CAP: longest wait first — that is the one most likely
#    forgotten — and at most ATTENTION_MAX_SHOWN named, the rest counted.
# ---------------------------------------------------------------------------
DC="$TMP/sc"
waiter "$LIVE_PID"  "$NAME_A" "waiting" 120  "$DC"
waiter "$LIVE_PID2" "$NAME_B" "waiting" 3600 "$DC"
waiter "$LIVE_PID3" "$NAME_C" "waiting" 600  "$DC"
waiter "$LIVE_PID4" "$NAME_D" "waiting" 300  "$DC"
out="$(render "$DC")"
plain="$(plain_of "$out")"
# B (1h) > C (10m) > D (5m) > A (2m); cap 3 names + "+1 more"
first_named="${plain#*waiting on you: }"; first_named="${first_named%% *}"
check "longest wait is named first" "$NAME_B" "$first_named"
case "$plain" in
  *"+1 more"*) check "the fourth waiter is counted, not named" "0" "0" ;;
  *) printf '  FAIL %-58s -> %s\n' "the fourth waiter is counted, not named" "$plain"
     fails=$((fails + 1)) ;;
esac
case "$plain" in
  *"$NAME_A"*) printf '  FAIL %-58s -> %s\n' "the shortest waiter must not be named" "$plain"
               fails=$((fails + 1)) ;;
  *) check "the shortest waiter must not be named" "0" "0" ;;
esac

if [ "$fails" -eq 0 ]; then
  echo "statusline-attention-line: all checks passed"
  exit 0
fi
echo "statusline-attention-line: $fails check(s) failed"
exit 1
