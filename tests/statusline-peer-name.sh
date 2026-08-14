#!/usr/bin/env bash
# The statusline must show THIS session's own peer name — the address other
# sessions see it by — and must add nothing at all when it cannot.
#
# WHY THIS EXISTS
# Claude Code's UI shows every OTHER session's peer address (a peer's
# ListAgents) and never the one you are typing into, so an operator cannot
# deliberately target their own session for cross-session messaging. The
# harness does publish the answer: `~/.claude/sessions/<pid>.json`, one file
# per live session, carrying `sessionId` and `name`. The statusline's own
# stdin JSON already carries `session_id`, so the display is a lookup.
#
# THE HAZARD, and why the negative cases outnumber the positive one: that
# registry is an UNDOCUMENTED internal format (schema observed at CC 2.1.229,
# `peerProtocol: 1`). It may move, change shape, or vanish under any CLI
# update. A statusline that errors, half-renders, or leaks a stray divider
# when the lookup fails would trade a missing convenience for a broken
# display on every refresh. So the contract is: on a match, one extra
# segment; on ANYTHING else — no dir, no files, no match, unparseable file,
# missing `name` — the output is byte-identical to a line configured without
# the group at all, and the exit status is unchanged.
#
# Byte-identical against WHAT: each fail-soft case is compared to the same
# render with PEER removed from the line, not to a remembered string. That is
# what makes "adds nothing" checkable rather than asserted — an empty group
# that still emitted its ` · ` divider would pass a contains-no-name check
# and fail this one.
#
# The positive case is the instrument's known-positive: without it, every
# fail-soft case below is satisfied by a lookup that can never fire.
# Case 2 is its discriminator — a matcher that returns the FIRST file rather
# than the MATCHING one passes case 1 alone.
#
# All session ids and names here are SYNTHESIZED. This repo is public and
# nothing from the live registry belongs in it.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

SCRIPT="./claude-worktime.sh"
[ -f "$SCRIPT" ] || { echo "missing script: $SCRIPT" >&2; exit 2; }

TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT

# Sandbox BOTH XDG roots and drop the direct overrides, or a real config.sh —
# or CLAUDE_WORKTIME_DATA in the environment — points this at the operator's
# live log. CLAUDE_SESSIONS_DIR is unset for the same reason: inherited, it
# would point every case at the live registry.
unset CLAUDE_WORKTIME_DATA CLAUDE_WORKTIME_CONFIG CLAUDE_SESSIONS_DIR
export XDG_DATA_HOME="$TMP/data" XDG_CONFIG_HOME="$TMP/config"
LOGDIR="$XDG_DATA_HOME/claude-worktime"
CFGDIR="$XDG_CONFIG_HOME/claude-worktime"
mkdir -p "$LOGDIR" "$CFGDIR"
LOG="$LOGDIR/activity.jsonl"

SID="synthetic-session-id-alpha"
NAME="example-project-ab"
OTHER_SID="synthetic-session-id-beta"
OTHER_NAME="other-project-cd"

# A non-git cwd, so {git} renders the same in every run below and cannot make
# two otherwise-identical renders differ.
CWD="$TMP/wsp/demo-project"
mkdir -p "$CWD"

# One event, yesterday, so nothing in the rendered groups moves with the clock.
T=$(( $(date -d "today 00:00" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$(date +%Y-%m-%d) 00:00:00" +%s) - 3600 ))
printf '{"t":%d,"p":"%s","b":"","s":"%s","e":"prompt"}\n' "$T" "$CWD" "$SID" > "$LOG"

fails=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then
    printf '  ok   %-56s -> %s\n' "$1" "$3"
  else
    printf '  FAIL %-56s -> %s (expected %s)\n' "$1" "$3" "$2"
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
  # The trailing newline is load-bearing: _read_hook_stdin gates on `read`
  # succeeding, and read returns false at EOF on an unterminated line.
  printf '{"session_id":"%s","cwd":"%s"}\n' "$SID" "$CWD" \
    | CLAUDE_SESSIONS_DIR="$1" "$SCRIPT" --statusline 2>/dev/null
}

sess_file() { # dir sessionId name -> writes <dir>/<pid>.json
  mkdir -p "$1"
  printf '{"pid":4242,"sessionId":"%s","name":"%s","nameSource":"cwd","status":"idle","cwd":"/tmp/x","peerProtocol":1}' \
    "$2" "$3" > "$1/4242.json"
}

# ---------------------------------------------------------------------------
# The baseline: the same render with the peer group absent from the line.
# Every fail-soft case below must equal this, byte for byte.
# ---------------------------------------------------------------------------
write_config "PROJECT"
BASE="$(render "$TMP/does-not-exist")"
if [ -z "$BASE" ]; then
  echo "FAIL: the baseline render is empty — the sandbox did not take, and an"
  echo "      empty string would let every byte-identity check below pass vacuously"
  exit 1
fi
printf '  baseline: %s\n' "$(printf '%s' "$BASE" | sed 's/\x1b\[[0-9;]*m//g')"

write_config "PROJECT PEER"

# ---------------------------------------------------------------------------
# 1. The positive: a registry file whose sessionId is ours renders its name.
# ---------------------------------------------------------------------------
D1="$TMP/s1"; sess_file "$D1" "$SID" "$NAME"
out="$(render "$D1")"; rc=$?
plain="$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')"
case "$plain" in
  *"@$NAME"*) check "a matching registry file shows its name" "0" "0" ;;
  *)         printf '  FAIL %-56s -> %s\n' "a matching registry file shows its name" "$plain"
             fails=$((fails + 1)) ;;
esac
check "the name is the LAST segment on the line" "@$NAME" "${plain##* }"
check "exit status on a match" "0" "$rc"

# The `.key` siblings the harness writes into the same directory must not be
# read as registry files.
printf 'not json at all' > "$D1/4242.deadbeef.key"
out="$(render "$D1")"
plain="$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')"
check "a sibling .key file does not disturb the match" "@$NAME" "${plain##* }"

# ---------------------------------------------------------------------------
# 2. The discriminator: with a non-matching file present too, the name shown
#    must be the MATCHING one. A lookup that returns the first file it reads
#    passes case 1 and fails here.
# ---------------------------------------------------------------------------
D2="$TMP/s2"; mkdir -p "$D2"
printf '{"pid":1111,"sessionId":"%s","name":"%s","peerProtocol":1}' \
  "$OTHER_SID" "$OTHER_NAME" > "$D2/1111.json"
printf '{"pid":2222,"sessionId":"%s","name":"%s","peerProtocol":1}' \
  "$SID" "$NAME" > "$D2/2222.json"
out="$(render "$D2")"
plain="$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')"
check "the matching file's name wins over a sibling's" "@$NAME" "${plain##* }"
case "$plain" in
  *"$OTHER_NAME"*) printf '  FAIL %-56s -> %s\n' "another session's name must never appear" "$plain"
                   fails=$((fails + 1)) ;;
  *)               check "another session's name must never appear" "0" "0" ;;
esac

# ---------------------------------------------------------------------------
# 3-7. The fail-soft arms. Each must be byte-identical to the baseline.
# ---------------------------------------------------------------------------
D3="$TMP/s3"; mkdir -p "$D3"
printf '{"pid":1111,"sessionId":"%s","name":"%s","peerProtocol":1}' \
  "$OTHER_SID" "$OTHER_NAME" > "$D3/1111.json"
out="$(render "$D3")"; rc=$?
check "no matching session: output unchanged, byte for byte" "$BASE" "$out"
check "no matching session: exit status" "0" "$rc"

D4="$TMP/s4"; mkdir -p "$D4"
printf '{"pid":1111,"sessionId":' > "$D4/1111.json"   # truncated mid-object
out="$(render "$D4")"; rc=$?
check "unparseable registry file: output unchanged" "$BASE" "$out"
check "unparseable registry file: exit status" "0" "$rc"

D5="$TMP/s5"; mkdir -p "$D5"                          # exists, holds no *.json
printf 'x' > "$D5/1111.key"
out="$(render "$D5")"; rc=$?
check "registry dir with no session files: output unchanged" "$BASE" "$out"
check "registry dir with no session files: exit status" "0" "$rc"

out="$(render "$TMP/no-such-dir")"; rc=$?
check "registry dir missing entirely: output unchanged" "$BASE" "$out"
check "registry dir missing entirely: exit status" "0" "$rc"

D6="$TMP/s6"; mkdir -p "$D6"                          # matches, but no `name`
printf '{"pid":1111,"sessionId":"%s","status":"idle","peerProtocol":1}' \
  "$SID" > "$D6/1111.json"
out="$(render "$D6")"; rc=$?
check "match without a name field: output unchanged" "$BASE" "$out"
check "match without a name field: exit status" "0" "$rc"

# `nameSource` sits beside `name` in the real schema: a key-prefix match would
# read its value as the name.
D7="$TMP/s7"; mkdir -p "$D7"
printf '{"pid":1111,"sessionId":"%s","nameSource":"cwd","peerProtocol":1}' \
  "$SID" > "$D7/1111.json"
out="$(render "$D7")"; rc=$?
check "nameSource is not read as the name" "$BASE" "$out"

if [ "$fails" -eq 0 ]; then
  echo "statusline-peer-name: all checks passed"
  exit 0
fi
echo "statusline-peer-name: $fails check(s) failed"
exit 1
