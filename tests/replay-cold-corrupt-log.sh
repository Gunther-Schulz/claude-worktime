#!/usr/bin/env bash
# A malformed line must cost ONE record, not the rest of the file.
#
# 2026-07-28: `--cold` read the log with `jq FILTER "$LOGFILE"`, which parses
# the whole file as one stream. A partial write at line 6326 aborted the parse,
# stderr went to /dev/null, and the empty result printed as
#
#     No cold rewrites recorded
#
# while 26 genuine cold-rewrite records — 7,293k of re-written tokens that day,
# including the 484k event under investigation at that moment — sat in the
# file. The log is append-only from concurrent hooks, so partial lines are
# expected, not exceptional: 46 of 423,106 lines were corrupt.
#
# This is the failure mode where a broken instrument reports "nothing found",
# which is indistinguishable from a clean result unless something tests it.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../claude-worktime.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Sandbox the XDG root and drop the direct overrides: CLAUDE_WORKTIME_DATA takes
# precedence over XDG (claude-worktime.sh:151), so on a machine exporting it this
# suite would read the operator's REAL log instead of the fixture below.
unset CLAUDE_WORKTIME_DATA CLAUDE_WORKTIME_CONFIG
# XDG_CONFIG_HOME too, matching rotation-corrupt-log.sh: the unset above closes
# the DATA half, but CONFIGDIR would still fall back to ~/.config/claude-worktime,
# and that file is sourced at :243 — AFTER DATADIR is assigned at :151 — so a
# DATADIR= line in the user's real config would re-escape the sandbox. It sets
# none today; this stops the suite depending on that staying true.
export XDG_DATA_HOME="$TMP/data" XDG_CONFIG_HOME="$TMP/config"
LOGDIR="$XDG_DATA_HOME/claude-worktime"
mkdir -p "$LOGDIR" "$XDG_CONFIG_HOME"
LOG="$LOGDIR/activity.jsonl"

SID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
now=$(date +%s)

{
  # A valid cold hit BEFORE the corruption...
  printf '{"type":"cold","t":%d,"s":"%s","k":"hit","gap":30,"ctx":100,"cc":111000,"cause":"messages_changed","mdl":"claude-opus-5"}\n' "$((now - 300))" "$SID"
  # ...a partially-written line, exactly what a concurrent hook produces...
  printf '{"type":"cold","t":%d,"s":"%s","k":"hit","gap":30,"ctx' "$((now - 200))" "$SID"
  printf '\n'
  # ...and a valid one AFTER it. The old whole-file parse lost this one.
  printf '{"type":"cold","t":%d,"s":"%s","k":"hit","gap":30,"ctx":100,"cc":222000,"cause":"tools_changed","mdl":"claude-opus-5"}\n' "$((now - 100))" "$SID"
} > "$LOG"

fail=0

out=$("$SCRIPT" --cold --session "$SID" 2>&1)

# Both valid records must survive; the record AFTER the corrupt line is the
# one the old reader silently dropped.
if ! grep -q "111k" <<<"$out"; then
  echo "FAIL: the record before the corrupt line is missing"; echo "$out"; fail=1
fi
if ! grep -q "222k" <<<"$out"; then
  echo "FAIL: the record AFTER the corrupt line is missing — one bad line must not"
  echo "      cost the rest of the file (this is the 2026-07-28 defect)"
  echo "$out"; fail=1
fi
if ! grep -q "(2 rewrites)" <<<"$out"; then
  echo "FAIL: expected exactly 2 surviving rewrites"; echo "$out"; fail=1
fi

# A genuinely empty result must SAY that lines were unreadable, so "none" is
# never confused with "could not read" — the confusion that hid the 26 records.
EMPTY_SID="99999999-0000-0000-0000-000000000000"
empty_out=$("$SCRIPT" --cold --session "$EMPTY_SID" 2>&1)
if ! grep -q "No cold rewrites recorded" <<<"$empty_out"; then
  echo "FAIL: expected a no-rewrites message"; echo "$empty_out"; fail=1
fi
if ! grep -q "unreadable line" <<<"$empty_out"; then
  echo "FAIL: an empty result over a corrupt log must disclose the skipped lines"
  echo "$empty_out"; fail=1
fi

# --raw must be tolerant too: a JSON consumer getting [] because of an
# unrelated malformed line is the same defect wearing a different hat.
raw_out=$("$SCRIPT" --cold --raw --session "$SID" 2>&1)
if ! grep -q '"cc":222000' <<<"$raw_out"; then
  echo "FAIL: --raw dropped the record after the corrupt line"; echo "$raw_out"; fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: corrupt log lines cost one record each, not the file"
fi
exit "$fail"
