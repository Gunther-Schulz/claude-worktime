#!/usr/bin/env bash
# The statusline's {session_name} token renders THIS session's slug beside
# the model name, and adds nothing at all when the field cannot be shown.
#
# WHY THIS EXISTS
# Operator ask, relayed via the dotfiles judgment desk: the session slug
# should appear in the statusline. Measured before booking (BACKLOG.md,
# 2026-09-13): the statusline stdin JSON carries a top-level `session_name`
# string field — the schema was read from one raw dump of a real render,
# never assumed from memory or docs. There is no key literally named "slug".
#
# THE HAZARD is the same shape as {model}/{peer_name}: an OLDER harness or a
# subagent context may send a payload with no `session_name` key at all, and
# Claude Code may in principle send the key with an empty string. Either must
# render the segment OUT — no empty separator, no literal "null", no empty
# brackets — never break the rest of the line.
#
# Byte-identical against WHAT: each fail-soft case is compared to the same
# render with SESSION_NAME removed from the line entirely, not to a
# remembered string — the same method statusline-peer-name.sh uses, and for
# the same reason: an empty group that still emits its " · " divider would
# pass a contains-no-name check and fail this one.
#
# All session ids and names here are SYNTHESIZED by hand. This repo is
# public and the machine-wide push-side leak scan does not reach it
# (BACKLOG.md, file head) — a slug is session-identifying, so nothing here
# is a captured real session's payload or a real session name.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

SCRIPT="./claude-worktime.sh"
[ -f "$SCRIPT" ] || { echo "missing script: $SCRIPT" >&2; exit 2; }

TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT

# Sandbox BOTH XDG roots, or a real config.sh / CLAUDE_WORKTIME_DATA in the
# environment would point this at the operator's live log.
unset CLAUDE_WORKTIME_DATA CLAUDE_WORKTIME_CONFIG CLAUDE_SESSIONS_DIR
export XDG_DATA_HOME="$TMP/data" XDG_CONFIG_HOME="$TMP/config"
LOGDIR="$XDG_DATA_HOME/claude-worktime"
CFGDIR="$XDG_CONFIG_HOME/claude-worktime"
mkdir -p "$LOGDIR" "$CFGDIR"
LOG="$LOGDIR/activity.jsonl"

SID="synthetic-session-id-alpha"
NAME="example-ab12"

# A non-git cwd, so {git} renders the same in every run below and cannot make
# two otherwise-identical renders differ.
CWD="$TMP/wsp/demo-project"
mkdir -p "$CWD"

# One event, yesterday, so nothing else on the line moves with the clock, and
# mode_statusline has a log to find (an entirely missing log file short-
# circuits statusline mode before the {session_name} logic ever runs).
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

write_config() { # line-3 group list
  cat > "$CFGDIR/config.sh" <<EOF
AUTO_ROTATE=false
COLD_NOTIFY=false
PROJECT_GIT_ANCHOR=false
HOME_ORG=""
USAGE_FETCH_INTERVAL=0
STATUSLINE_1="PROJECT"
STATUSLINE_2=""
STATUSLINE_3="$1"
EOF
}

render() { # stdin-json -> rendered statusline (RAW bytes, ANSI kept)
  printf '%s' "$1" | "$SCRIPT" --statusline 2>/dev/null
}

json() { # session_name-field(may be empty) -> stdin JSON
  printf '{"session_id":"%s","cwd":"%s","model":{"display_name":"Sonnet 5"}%s}' \
    "$SID" "$CWD" "$1"
}

# ---------------------------------------------------------------------------
# The baseline: MODEL only, SESSION_NAME group absent from the line entirely.
# Every fail-soft case below must equal this, byte for byte.
# ---------------------------------------------------------------------------
write_config "MODEL"
BASE="$(render "$(json "")")"
if [ -z "$BASE" ]; then
  echo "FAIL: the baseline render is empty — the sandbox did not take, and an"
  echo "      empty string would let every byte-identity check below pass vacuously"
  exit 1
fi
printf '  baseline: %s\n' "$(printf '%s' "$BASE" | sed 's/\x1b\[[0-9;]*m//g')"

write_config "MODEL SESSION_NAME"

# ---------------------------------------------------------------------------
# 1. The positive: session_name present renders it beside the model name.
# ---------------------------------------------------------------------------
out="$(render "$(json ",\"session_name\":\"$NAME\"")")"; rc=$?
plain="$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')"
case "$plain" in
  *"$NAME"*) check "session_name present renders it" "0" "0" ;;
  *)         printf '  FAIL %-56s -> %s\n' "session_name present renders it" "$plain"
             fails=$((fails + 1)) ;;
esac
check "exit status on a match" "0" "$rc"
BASE_PLAIN="$(printf '%s' "$BASE" | sed 's/\x1b\[[0-9;]*m//g')"
if [ "$plain" = "$BASE_PLAIN" ]; then
  printf '  FAIL %-56s -> %s\n' "present case must differ from the baseline" "$plain"
  fails=$((fails + 1))
else
  check "present case must differ from the baseline" "0" "0"
fi

# ---------------------------------------------------------------------------
# 2. Key absent (no session_name field at all — older harness, subagent
#    contexts): output byte-identical to the baseline, no empty separator.
# ---------------------------------------------------------------------------
out="$(render "$(json "")")"; rc=$?
check "no session_name key: output unchanged, byte for byte" "$BASE" "$out"
check "no session_name key: exit status" "0" "$rc"

# ---------------------------------------------------------------------------
# 3. Empty-string value: same treatment as absent.
# ---------------------------------------------------------------------------
out="$(render "$(json ",\"session_name\":\"\"")")"; rc=$?
check "empty-string session_name: output unchanged, byte for byte" "$BASE" "$out"
check "empty-string session_name: exit status" "0" "$rc"

# Neither fail-soft case may leak the literal word "null" or a bare "()" —
# the artifact a naive substitution or an unset-but-present template leaves
# behind. Checked directly against the un-cleaned output, not only against
# byte-identity with the baseline, so a regression that changes the baseline
# too cannot hide behind it.
for label_out in "no-key:$(render "$(json "")")" "empty:$(render "$(json ",\"session_name\":\"\"")")"; do
  lbl="${label_out%%:*}"
  val="${label_out#*:}"
  plain="$(printf '%s' "$val" | sed 's/\x1b\[[0-9;]*m//g')"
  case "$plain" in
    *null*) printf '  FAIL %-56s -> %s\n' "$lbl: no literal null" "$plain"
            fails=$((fails + 1)) ;;
    *)      check "$lbl: no literal null" "0" "0" ;;
  esac
  case "$plain" in
    *"()"*) printf '  FAIL %-56s -> %s\n' "$lbl: no empty brackets" "$plain"
            fails=$((fails + 1)) ;;
    *)      check "$lbl: no empty brackets" "0" "0" ;;
  esac
done

if [ "$fails" -eq 0 ]; then
  echo "statusline-session-name: all checks passed"
  exit 0
fi
echo "statusline-session-name: $fails check(s) failed"
exit 1
