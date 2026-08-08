#!/usr/bin/env bash
# Rotation must archive every valid record, not stop at the first bad line.
#
# Same defect class as replay-cold-corrupt-log.sh, second call site. `_do_rotate`
# read the log with plain `jq`: the summary pass at :2654 used `jq -sc`, which
# parses the whole file as one stream and dies (exit 5) at the first malformed
# line. `|| summary_error="true"` then fired and rotation returned without
# archiving.
#
# Measured on the operator's real log 2026-08-08: 46 malformed lines, all from a
# 13-minute window on 2026-04-01 (a since-reverted cost-extraction bug). Every
# rotation since has hit that branch — 1,052 consecutive identical entries in
# .rotation_errors — so the last archive is activity-2026-03-31.jsonl while the
# live log grew to 83 MB / 559k lines. The log is append-only from concurrent
# hooks, so malformed lines are expected, not exceptional.
#
# The assertion that fails against the old code is the one about records
# positioned AFTER the corrupt line: those are what a whole-file parse loses.
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

# Old entries spanning two projects, one corrupt line among them, then current
# entries after the cutoff. The corrupt line is the shape the 2026-04-01 writer
# produced: an interpolated fragment whose brace ate the record's own.
{
  printf '{"t":%d,"p":"projA","b":"main","s":"s1","e":"start"}\n'    "$(( old ))"
  printf '{"t":%d,"p":"projA","b":"main","s":"s1","e":"prompt"}\n'   "$(( old + 60 ))"
  printf '{"t":%d,"p":"projA","b":"main","s":"s1","e":"response","cst":{"session_id":"s1"\n' "$(( old + 90 ))"
  printf '{"t":%d,"p":"projA","b":"main","s":"s1","e":"response"}\n' "$(( old + 120 ))"
  printf '{"t":%d,"p":"projA","b":"main","s":"s1","e":"prompt"}\n'   "$(( old + 200 ))"
  printf '{"t":%d,"p":"projA","b":"main","s":"s1","e":"response"}\n' "$(( old + 260 ))"
  printf '{"t":%d,"p":"projB","b":"main","s":"s2","e":"start"}\n'    "$(( old + 300 ))"
  printf '{"t":%d,"p":"projB","b":"main","s":"s2","e":"prompt"}\n'   "$(( old + 360 ))"
  printf '{"t":%d,"p":"projB","b":"main","s":"s2","e":"response"}\n' "$(( old + 420 ))"
  printf '{"t":%d,"p":"projA","b":"main","s":"s3","e":"start"}\n'    "$(( cur ))"
  printf '{"t":%d,"p":"projA","b":"main","s":"s3","e":"prompt"}\n'   "$(( cur + 60 ))"
} > "$LOG"

# Timestamps of the 8 valid OLD records, in file order. Index 2 onwards sit
# after the corrupt line.
OLD_TS=( "$(( old ))" "$(( old + 60 ))" "$(( old + 120 ))" "$(( old + 200 ))" \
         "$(( old + 260 ))" "$(( old + 300 ))" "$(( old + 360 ))" "$(( old + 420 ))" )
CUR_TS=( "$(( cur ))" "$(( cur + 60 ))" )

fail=0
out=$("$SCRIPT" --rotate 2>&1)

# Guard the guard: if the sandbox did not take, nothing below means anything.
if [ ! -e "$LOG" ]; then
  echo "FAIL: sandbox log vanished — refusing to interpret the rest"; exit 1
fi

if [ ! -f "$ARCHIVE" ]; then
  echo "FAIL: no archive written — rotation skipped over a corrupt log"
  echo "$out"
  echo "  .rotation_errors: $(cat "$LOGDIR/.rotation_errors" 2>/dev/null || echo none)"
  fail=1
fi

# Every valid old record must be archived. The ones after the corrupt line are
# the 2026-08-08 defect; the ones before it a truncating reader would still get.
for i in "${!OLD_TS[@]}"; do
  ts="${OLD_TS[$i]}"
  if ! grep -q "\"t\":${ts}," "$ARCHIVE" 2>/dev/null; then
    if [ "$i" -ge 2 ]; then
      echo "FAIL: archive is missing old record #$((i+1)) (t=$ts), which sits AFTER"
      echo "      the corrupt line — one bad line must not cost the rest of the file"
    else
      echo "FAIL: archive is missing old record #$((i+1)) (t=$ts)"
    fi
    fail=1
  fi
done

# The corrupt line itself is not a record; it must not reach the archive.
if grep -q 'session_id' "$ARCHIVE" 2>/dev/null; then
  echo "FAIL: the malformed line was copied into the archive"; fail=1
fi

# One summary per project, in the live log.
for p in projA projB; do
  n=$(grep -c "\"type\":\"summary\".*\"p\":\"$p\"" "$LOG" 2>/dev/null || true)
  if [ "${n:-0}" -ne 1 ]; then
    echo "FAIL: expected exactly 1 summary for $p in the live log, found ${n:-0}"; fail=1
  fi
done

# Current entries survive the rewrite.
for ts in "${CUR_TS[@]}"; do
  if ! grep -q "\"t\":${ts}," "$LOG" 2>/dev/null; then
    echo "FAIL: current record t=$ts was lost in the rewrite"; fail=1
  fi
done

# Nothing valid disappears: every event record (summaries excluded) must be in
# exactly one of archive or live log.
arch_n=$(count_events "$ARCHIVE")
live_n=$(count_events "$LOG")
total=$(( arch_n + live_n ))
if [ "$total" -ne 10 ]; then
  echo "FAIL: expected 10 valid event records across archive+live log, found $total"
  echo "      (archive $arch_n, live $live_n) — a valid record was lost or duplicated"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: rotation archives every valid record across a corrupt line"
fi
exit "$fail"
