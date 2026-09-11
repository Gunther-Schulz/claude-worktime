#!/usr/bin/env bash
# The statusline's {agents} token shows this session's subagents that are
# WORKING right now — by name, with how long each has been quiet — and a count
# of teammates sitting idle; and it adds nothing at all when there is nothing
# to show or nothing it can read.
#
# WHY THIS EXISTS
# Claude Code's statusline stdin carries no task list, so a session running
# several subagents (Agent-tool dispatches, in-process teammates) gives no
# at-a-glance answer to "what is still working, and is anything stuck?". The
# harness does write the answer to disk: every subagent keeps its own log at
# <transcript dir>/<session id>/subagents/agent-<id>.jsonl with a sibling
# agent-<id>.meta.json (name, description, agentType, taskKind). The
# statusline's stdin already carries transcript_path, so the display is a scan.
#
# THE STATE RULE, and where it comes from. Busy vs idle is read off the LAST
# conversation record (user/assistant) of each log — attachment records are
# skipped. Measured 2026-09-11 over 1179 real agent logs:
#   - an assistant record carrying tool_use, or thinking and nothing else, is
#     mid-turn: BUSY;
#   - a user record (a tool_result, a prompt) means the model is generating
#     its reply: BUSY;
#   - an assistant record with text and no tool_use ends a turn. For a
#     TEAMMATE (meta taskKind "in_process_teammate") that is IDLE — it waits
#     for its next message (960 of 960 teammate logs carry a name; 922 of
#     them end this way). For an Agent-tool agent it is DONE: its result has
#     already reached the parent, so it is not shown;
#   - a user record whose text starts "[Request interrupted" is STOPPED (3 of
#     219 Agent-tool logs), not shown — without this arm an interrupted agent
#     would read as busy until the window expired.
# The quiet time is "now minus the newest record timestamp in the tail", so an
# agent blocked on one long tool call reads as busy-and-quiet, which is the
# true observable. Past AGENTS_QUIET_WARN_SECS it is flagged ⚠. Nothing older
# than AGENTS_WINDOW_SECS is shown at all: a log is never marked finished when
# its agent is killed, and a ghost must age out.
#
# THE HAZARD. The subagent log format is an UNDOCUMENTED internal format, like
# the live-session registry behind {peer_name}. So every failure is silent —
# no transcript_path, no subagents dir, no logs, unparseable lines — and the
# output then equals, byte for byte, the same render with AGENTS removed from
# the line. Descriptions are prompt-derived text, so control characters are
# stripped: a log must not be able to write escape sequences onto the
# terminal.
#
# Case 1 is the instrument's known-positive: without it every fail-soft case
# below is satisfied by a scan that never fires. Cases 2 and 3 are its
# discriminators — the same last-record shape rendered differently by agent
# kind, and each busy shape named, so a rule that shows EVERY recent log, or
# none of the idle ones, fails.
#
# All session ids, agent ids, names and descriptions here are SYNTHESIZED.
# This repo is public and nothing from a real session belongs in it.

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

SID="synthetic-session-id-alpha"

# A non-git cwd, so nothing in the render depends on a repository.
CWD="$TMP/wsp/demo-project"
mkdir -p "$CWD"

# One event, yesterday, so the log exists and nothing moves with the clock.
T=$(( $(date -d "today 00:00" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$(date +%Y-%m-%d) 00:00:00" +%s) - 3600 ))
printf '{"t":%d,"p":"%s","b":"","s":"%s","e":"prompt"}\n' "$T" "$CWD" "$SID" > "$LOG"

fails=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then
    printf '  ok   %-60s -> %s\n' "$1" "$3"
  else
    printf '  FAIL %-60s -> %s (expected %s)\n' "$1" "$3" "$2"
    fails=$((fails + 1))
  fi
}
check_match() { # name pattern actual — a shell `case` pattern over the WHOLE line
  # shellcheck disable=SC2254
  case "$3" in
    $2) printf '  ok   %-60s -> %s\n' "$1" "$3" ;;
    *)  printf '  FAIL %-60s -> %s (expected to match %s)\n' "$1" "$3" "$2"
        fails=$((fails + 1)) ;;
  esac
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

# Each case gets its own session tree, so no fixture leaks into another case.
new_session() { # name -> sets TP (transcript path) and SUB (subagents dir)
  local root="$TMP/projects/$1"
  TP="$root/$SID.jsonl"
  SUB="$root/$SID/subagents"
  mkdir -p "$SUB"
  : > "$TP"
}

render() { # [transcript-path] -> rendered statusline (RAW bytes, ANSI kept)
  # The trailing newline is load-bearing: _read_hook_stdin gates on `read`
  # succeeding, and read returns false at EOF on an unterminated line.
  if [ -n "${1:-}" ]; then
    printf '{"session_id":"%s","cwd":"%s","transcript_path":"%s"}\n' "$SID" "$CWD" "$1"
  else
    printf '{"session_id":"%s","cwd":"%s"}\n' "$SID" "$CWD"
  fi | "$SCRIPT" --statusline 2>/dev/null
}
plain() { printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g'; }

# ISO-8601 UTC timestamp N seconds ago, in the harness's millisecond form.
iso_ago() {
  local t=$(( $(date +%s) - $1 ))
  date -u -d "@$t" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -r "$t" +%Y-%m-%dT%H:%M:%S.000Z
}

# Record writers — the shapes of real log lines, reduced to the fields read.
r_tool_use()  { printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_x","name":"Bash","input":{}}]}}\n' "$(iso_ago "$1")"; }
r_thinking()  { printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","content":[{"type":"thinking","thinking":"…"}]}}\n' "$(iso_ago "$1")"; }
r_text()      { printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","content":[{"type":"text","text":"Done."}]}}\n' "$(iso_ago "$1")"; }
r_result()    { printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_x","content":"ok"}]}}\n' "$(iso_ago "$1")"; }
r_interrupt() { printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}\n' "$(iso_ago "$1")"; }
r_attach()    { printf '{"type":"attachment","timestamp":"%s","attachment":{"type":"hook_success"}}\n' "$(iso_ago "$1")"; }

# meta name-or-empty description-or-empty agentType [teammate]
meta() {
  local m='{"agentType":"'"$3"'"'
  [ -n "$1" ] && m="$m"',"name":"'"$1"'"'
  [ -n "$2" ] && m="$m"',"description":"'"$2"'"'
  [ "${4:-}" = teammate ] && m="$m"',"taskKind":"in_process_teammate"'
  printf '%s}\n' "$m"
}
agent() { # id meta-json record-lines...  (records in file order)
  local id="$1" m="$2"; shift 2
  printf '%s' "$m" > "$SUB/agent-$id.meta.json"
  : > "$SUB/agent-$id.jsonl"
  local r; for r in "$@"; do printf '%s\n' "$r" >> "$SUB/agent-$id.jsonl"; done
}

# ---------------------------------------------------------------------------
# The baseline: the same render with the agents group absent from the line.
# ---------------------------------------------------------------------------
write_config "PROJECT"
new_session base
BASE="$(render "$TP")"
if [ -z "$BASE" ]; then
  echo "FAIL: the baseline render is empty — the sandbox did not take, and an"
  echo "      empty string would let every byte-identity check below pass vacuously"
  exit 1
fi
printf '  baseline: %s\n' "$(plain "$BASE")"
BASE_PLAIN="$(plain "$BASE")"

write_config "PROJECT AGENTS"

# ---------------------------------------------------------------------------
# 1. The known-positive: one busy agent, named, with its quiet time.
# ---------------------------------------------------------------------------
new_session c1
agent a1 "$(meta lane-alpha "sonnet: fixture lane" general-purpose)" \
  "$(r_result 40)" "$(r_tool_use 30)"
out="$(render "$TP")"; rc=$?
check_match "busy agent: named, with quiet time" "$BASE_PLAIN · agents lane-alpha 3[0-4]s" "$(plain "$out")"
check "busy agent: exit status" "0" "$rc"
if [ "$(plain "$out")" = "$BASE_PLAIN" ]; then
  echo "FAIL: the known-positive rendered nothing — every fail-soft case below would be vacuous"
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Same last-record shape (assistant text), different kind: a teammate is
#    IDLE and counted, an Agent-tool agent is DONE and not shown.
# ---------------------------------------------------------------------------
new_session c2
agent t2 "$(meta mate-idle "sonnet: fixture mate" mate-idle teammate)" "$(r_tool_use 90)" "$(r_text 60)"
agent a2 "$(meta lane-done "sonnet: fixture done" general-purpose)"      "$(r_tool_use 90)" "$(r_text 60)"
check "idle teammate counted, finished agent not shown" "$BASE_PLAIN · agents 1 idle" "$(plain "$(render "$TP")")"

# ---------------------------------------------------------------------------
# 3. Every busy shape reads busy; the attachment after a tool_use does not
#    hide it and does move its quiet time; an interrupted agent is not shown.
#    Sorted longest-quiet first.
# ---------------------------------------------------------------------------
new_session c3
agent b1 "$(meta busy-result "" general-purpose)"   "$(r_tool_use 300)" "$(r_result 200)"
agent b2 "$(meta busy-think "" general-purpose)"    "$(r_result 150)" "$(r_thinking 100)"
agent b3 "$(meta busy-attach "" general-purpose)"   "$(r_tool_use 500)" "$(r_attach 50)"
agent b4 "$(meta stopped "" general-purpose)"       "$(r_tool_use 30)" "$(r_interrupt 20)"
check_match "tool_result, thinking-only, trailing attachment: busy; interrupted: hidden" \
  "$BASE_PLAIN · agents busy-result 3m, busy-think 1m, busy-attach 5[0-4]s" "$(plain "$(render "$TP")")"

# ---------------------------------------------------------------------------
# 4. Quiet past the warning threshold is flagged; past the window, hidden.
# ---------------------------------------------------------------------------
new_session c4
agent w1 "$(meta slow-lane "" general-purpose)" "$(r_tool_use 900)"
agent w2 "$(meta ghost-lane "" general-purpose)" "$(r_tool_use 7200)"
old=$(( $(date +%s) - 7200 ))
touch -t "$(date -d "@$old" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$old" +%Y%m%d%H%M.%S)" "$SUB/agent-w2.jsonl"
check "quiet 15m: flagged; quiet 2h: hidden" "$BASE_PLAIN · agents slow-lane ⚠15m" "$(plain "$(render "$TP")")"

# A recent file mtime must not resurrect an old agent: the window is decided on
# the records themselves, the mtime only bounds what gets read.
agent w3 "$(meta ghost-touched "" general-purpose)" "$(r_tool_use 7200)"
check "old records in a freshly touched file: hidden" "$BASE_PLAIN · agents slow-lane ⚠15m" "$(plain "$(render "$TP")")"

# ---------------------------------------------------------------------------
# 5. More busy agents than AGENTS_MAX_SHOWN (3): the rest are counted.
#    Idle teammates are counted after them.
# ---------------------------------------------------------------------------
new_session c5
agent m1 "$(meta m-one "" general-purpose)"   "$(r_tool_use 400)"
agent m2 "$(meta m-two "" general-purpose)"   "$(r_tool_use 300)"
agent m3 "$(meta m-three "" general-purpose)" "$(r_tool_use 200)"
agent m4 "$(meta m-four "" general-purpose)"  "$(r_tool_use 100)"
agent m5 "$(meta m-five "" general-purpose)"  "$(r_tool_use 90)"
agent m6 "$(meta m-idle "" m-idle teammate)"  "$(r_text 80)"
check "overflow counted, idle counted last" "$BASE_PLAIN · agents m-one 6m, m-two 5m, m-three 3m +2 more, 1 idle" "$(plain "$(render "$TP")")"

# ---------------------------------------------------------------------------
# 6. Labels: name, else description, else agentType; long labels are cut;
#    control characters from the (prompt-derived) description never reach
#    the terminal.
# ---------------------------------------------------------------------------
new_session c6
agent l1 "$(meta "" "desc-label" general-purpose)" "$(r_tool_use 300)"
agent l2 "$(meta "" "" Explore)"                   "$(r_tool_use 200)"
agent l3 "$(meta "a-very-long-agent-name-that-goes-on" "" general-purpose)" "$(r_tool_use 100)"
check "label fallback and truncation" "$BASE_PLAIN · agents desc-label 5m, Explore 3m, a-very-long-agent-n… 1m" "$(plain "$(render "$TP")")"

new_session c6b
# The escape below is JSON-ENCODED in the meta file (the six characters of a
# \u escape), as the harness writes it. A raw control byte would make the meta
# invalid JSON and exercise the parser's fail-soft arm instead of the stripping.
agent e1 "$(meta "" 'evil\u001b[2Jlabel' general-purpose)" "$(r_tool_use 300)"
out="$(render "$TP")"
check "description escapes are stripped" "$BASE_PLAIN · agents evil[2Jlabel 5m" "$(plain "$out")"
case "$out" in
  *$'\e[2J'*) printf '  FAIL %-60s\n' "no clear-screen sequence reaches the output"; fails=$((fails + 1)) ;;
  *)          check "no clear-screen sequence reaches the output" 0 0 ;;
esac

# Descriptions are prose, and prose has ampersands. Bash 5.2+ reads an unquoted
# `&` in a ${var//pattern/replacement} replacement as "the matched text", so
# the token substitution turned "fix & test" into "fix {agents} test"
# (measured 2026-09-11, bash 5.3.15).
new_session c6c
agent amp1 "$(meta "" "fix & test" general-purpose)" "$(r_tool_use 300)"
check "an ampersand in a label renders literally" "$BASE_PLAIN · agents fix & test 5m" "$(plain "$(render "$TP")")"

# ---------------------------------------------------------------------------
# 7-11. Fail-soft arms: each byte-identical to the baseline, exit status 0.
# ---------------------------------------------------------------------------
out="$(render)"; rc=$?
check "no transcript_path: output unchanged" "$BASE" "$out"
check "no transcript_path: exit status" "0" "$rc"

new_session c8; rmdir "$SUB"
out="$(render "$TP")"; rc=$?
check "no subagents dir: output unchanged" "$BASE" "$out"
check "no subagents dir: exit status" "0" "$rc"

new_session c9
out="$(render "$TP")"; rc=$?
check "empty subagents dir: output unchanged" "$BASE" "$out"

new_session c10
printf 'not json at all\n{"type":"assistant","timest' > "$SUB/agent-g1.jsonl"
printf '{"agentType":' > "$SUB/agent-g1.meta.json"
out="$(render "$TP")"; rc=$?
check "unparseable log and meta: output unchanged" "$BASE" "$out"
check "unparseable log and meta: exit status" "0" "$rc"

new_session c11
agent n1 "$(meta lane-done "" general-purpose)" "$(r_text 60)"
out="$(render "$TP")"; rc=$?
check "only finished agents: output unchanged" "$BASE" "$out"

if [ "$fails" -eq 0 ]; then
  echo "statusline-agents: all checks passed"
  exit 0
fi
echo "statusline-agents: $fails check(s) failed"
exit 1
