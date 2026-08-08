#!/usr/bin/env bash
# The archive is complete or it is not written — never a prefix.
#
# `_do_rotate` collected the entries to archive with
#
#     old_entries=$(jq -c … "$LOGFILE" 2>/dev/null || true)
#
# Streaming jq emits every record BEFORE a malformed line, then dies; `|| true`
# discards the exit code, and the `[ -z "$old_entries" ] && return` guard is
# happy with the truncated prefix. Measured against the operator's real log
# 2026-08-08: 3,964 records emitted against 351,753 valid ones — a 1.1% prefix
# that read as the whole set.
#
# Today the damage is masked: the summary pass two lines later aborts first, so
# rotation returns before `echo "$old_entries" >> "$archive"` at :2691. That
# append sits BEFORE the rewrite guard, so fixing the summary pass alone would
# start writing the 1.1% prefix to the archive on every rotation. This test is
# what stands between those two repairs.
#
# The fixture is DIRTY on purpose. An "archive is complete or absent" assertion
# over a clean log passes against code that ignores corruption entirely — and so
# does it over a dirty log whenever rotation simply skips. So the in-scope case
# must be shown to FIRE in the dirty state: the archive must exist AND hold every
# valid old record. That composite is what goes red before the fix.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../claude-worktime.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Sandbox BOTH XDG roots and drop the direct overrides: this test rotates, and a
# real config.sh setting DATADIR — or CLAUDE_WORKTIME_DATA in the environment —
# would point it at the operator's live 83 MB log.
unset CLAUDE_WORKTIME_DATA CLAUDE_WORKTIME_CONFIG
export XDG_DATA_HOME="$TMP/data" XDG_CONFIG_HOME="$TMP/config"
LOGDIR="$XDG_DATA_HOME/claude-worktime"
mkdir -p "$LOGDIR" "$XDG_CONFIG_HOME"
LOG="$LOGDIR/activity.jsonl"

# Valid EVENT records in a file (summaries and other typed records excluded).
# Tolerant read, so a corrupt line costs one record here too — and a missing or
# unreadable file answers 0 rather than an empty string.
count_events() {
  local f="$1" n=""
  [ -f "$f" ] || { echo 0; return; }
  n=$(jq -Rc 'fromjson? // empty' "$f" 2>/dev/null \
      | jq -s 'map(select((.type // null) == null)) | length' 2>/dev/null) || n=""
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  echo "$n"
}

cutoff=$(date -d "today 00:00" +%s)          # ROTATE_INTERVAL=daily (the default)
suffix=$(date -d "yesterday" +%Y-%m-%d)
ARCHIVE="$LOGDIR/activity-${suffix}.jsonl"
old=$(( cutoff - 7200 ))                     # yesterday, 22:00
cur=$(( cutoff + 3600 ))                     # today, 01:00

# One valid old record, then the corrupt line, then MANY more valid old records.
# A prefix-truncating reader keeps exactly the first one, so the shortfall is
# unmissable rather than marginal.
TAIL_COUNT=40
{
  printf '{"t":%d,"p":"projA","b":"main","s":"s1","e":"start"}\n' "$(( old ))"
  printf '{"t":%d,"p":"projA","b":"main","s":"s1","e":"prompt","cst":{"session_id":"s1"\n' "$(( old + 10 ))"
  for i in $(seq 1 "$TAIL_COUNT"); do
    if [ $(( i % 2 )) -eq 0 ]; then e="response"; else e="prompt"; fi
    printf '{"t":%d,"p":"projA","b":"main","s":"s1","e":"%s"}\n' "$(( old + 20 + i * 30 ))" "$e"
  done
  printf '{"t":%d,"p":"projA","b":"main","s":"s2","e":"start"}\n'  "$(( cur ))"
  printf '{"t":%d,"p":"projA","b":"main","s":"s2","e":"prompt"}\n' "$(( cur + 60 ))"
} > "$LOG"

EXPECT_OLD=$(( TAIL_COUNT + 1 ))             # 41 valid records before the cutoff

fail=0
out=$("$SCRIPT" --rotate 2>&1)

if [ ! -e "$LOG" ]; then
  echo "FAIL: sandbox log vanished — refusing to interpret the rest"; exit 1
fi

if [ ! -f "$ARCHIVE" ]; then
  echo "FAIL: rotation was skipped over a dirty log — no archive written, so the"
  echo "      completeness assertion below never gets to run. A corrupt line must"
  echo "      cost one record, not the rotation."
  echo "$out"
  echo "  .rotation_errors: $(cat "$LOGDIR/.rotation_errors" 2>/dev/null || echo none)"
  fail=1
else
  n=$(count_events "$ARCHIVE")
  if [ "$n" -ne "$EXPECT_OLD" ]; then
    echo "FAIL: archive holds $n of $EXPECT_OLD valid old records — a PREFIX, not"
    echo "      the whole set. This is what a repair of the summary pass alone"
    echo "      produces: streaming jq stops at the corrupt line and \`|| true\`"
    echo "      hides the exit code."
    fail=1
  fi
  # Spot the specific boundary: the record right after the corrupt line, and the
  # last one in the file. A prefix keeps neither.
  for ts in "$(( old + 50 ))" "$(( old + 20 + TAIL_COUNT * 30 ))"; do
    if ! grep -q "\"t\":${ts}," "$ARCHIVE" 2>/dev/null; then
      echo "FAIL: archive is missing the old record t=$ts (after the corrupt line)"
      fail=1
    fi
  done
fi

# No valid record may be lost: the archive plus what stays in the live log must
# still account for every event record in the fixture.
live_n=$(count_events "$LOG")
arch_n=$(count_events "$ARCHIVE")
total=$(( arch_n + live_n ))
if [ "$total" -ne $(( EXPECT_OLD + 2 )) ]; then
  echo "FAIL: expected $(( EXPECT_OLD + 2 )) valid event records across archive+live log, found $total"
  echo "      (archive $arch_n, live $live_n)"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: the archive is complete, not a prefix, over a corrupt log"
fi
exit "$fail"
