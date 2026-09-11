#!/usr/bin/env bash
# No tracked file carries a raw control byte: anything below 0x20 other than
# tab, newline and carriage return, or DEL.
#
# WHY THIS EXISTS
# 2026-09-11, while building {agents}: an editing tool turned escapes typed as
# text into the raw bytes they name. Two landed as jq string markers in
# claude-worktime.sh and one in a test fixture's JSON. The markers still
# worked, which is the hazard: invisible in review, in `git diff` and in most
# editors, and one careless save away from being stripped. The fixture failed
# differently: a raw byte inside a JSON string is invalid JSON, so that case
# silently exercised the parser's fail-soft arm instead of the
# control-character stripping it was written for, and was caught only because
# its expectation went red. Written as text escapes (\036 in printf, the \u
# form in jq), the same bytes are visible and survive any tool.
#
# `tr` rather than grep -P or perl: stock macOS grep has no -P, and the suites
# add no dependency the script itself does not have.
#
# The known pair runs first: a planted file with one raw byte must count 1,
# and a file carrying only what IS allowed (tab, CR, UTF-8 such as ⚠ and …)
# must count 0. Without the first, a detector that never fires passes over
# the tree; without the second, one that fires on UTF-8 becomes the check
# everyone learns to ignore.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# Deleted, i.e. NOT flagged: tab, LF, CR, printable ASCII, and every byte
# >= 0x80 (UTF-8 multibyte sequences). Whatever survives the deletion is.
count_raw() { LC_ALL=C tr -d '\011\012\015\040-\176\200-\377' < "$1" | wc -c | tr -d ' '; }

TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT

fails=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then
    printf '  ok   %-56s -> %s\n' "$1" "$3"
  else
    printf '  FAIL %-56s -> %s (expected %s)\n' "$1" "$3" "$2"
    fails=$((fails + 1))
  fi
}

printf 'if ($l | startswith("\036")) then\n' > "$TMP/planted"
printf 'tab\there\r\nwarn ⚠ cut…\n' > "$TMP/allowed"
check "known-positive: one planted raw byte is counted" 1 "$(count_raw "$TMP/planted")"
check "known-negative: tab, CR and UTF-8 are not" 0 "$(count_raw "$TMP/allowed")"
if [ "$fails" -ne 0 ]; then
  echo "FAIL: the detector itself is broken, so its verdict over the tree would mean nothing"
  exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "SKIP: not a git work tree, so there is no tracked-file list to scan"
  exit 0
fi

scanned=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  scanned=$((scanned + 1))
  c="$(count_raw "$f")"
  if [ "$c" != 0 ]; then
    printf '  FAIL %s carries %s raw control byte(s)\n' "$f" "$c"
    fails=$((fails + 1))
  fi
done < <(git ls-files)

# An empty file list would pass every file it never read.
if [ "$scanned" -eq 0 ]; then
  echo "FAIL: git ls-files listed nothing, so the scan read no file"
  exit 1
fi

if [ "$fails" -eq 0 ]; then
  echo "PASS: $scanned tracked files, no raw control bytes"
  exit 0
fi
echo "FAIL: $fails file(s) carry raw control bytes"
exit 1
