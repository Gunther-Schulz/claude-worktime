#!/usr/bin/env bash
# Every flag the script PRINTS AT A USER must be a flag the script HANDLES.
#
# `--cold` told a user with a corrupt log to "run: claude-worktime --info".
# There is no `--info` arm: it fell through the argument loop's `*) ;;` and
# silently ran the default session mode. So the hint sent people to a no-op at
# exactly the moment they had a broken log and needed the diagnosis.
#
# The one-off repair is a corrected hint string. The MECHANISM is this check,
# because the defect class is structural, not textual: the argument loop
# swallows unknown flags without complaint, so a printed flag name can go stale
# — renamed, or never built — and nothing anywhere fails. The manual reading
# that found `--info` finds it once; this finds the next one.
#
# WHAT IT PROVES AND WHAT IT DOES NOT: it proves every printed flag has a case
# arm in one of the two top-level dispatch blocks. It does not prove the arm
# does something USEFUL for the situation the hint describes — that is a
# judgement no static check makes. It is scoped to the loud, mechanical half.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../claude-worktime.sh"
[ -f "$SCRIPT" ] || { echo "missing script: $SCRIPT" >&2; exit 2; }

# Flags HANDLED: the case patterns of the two top-level dispatch blocks, and
# only those. Anchored at column 0 so inner case statements (which handle their
# own unrelated tokens) cannot make an unhandled flag read as handled.
#   block 1  case "${1:-}" in … esac     — the pre-jq arms (--check, --repair, …)
#   block 2  while [ $# -gt 0 ]; do … done — the mode/filter arms
handled=$(awk '
  /^case "\$\{1:-\}" in$/     { inblock = 1; next }
  /^while \[ \$# -gt 0 \]; do$/ { inblock = 1; next }
  /^esac$/ || /^done$/        { inblock = 0; next }
  # The pattern list may be an ALTERNATION (`-h|--help|help)`), so `|` must be
  # allowed here. It was excluded, which made every alternation arm invisible:
  # `--help` has been handled all along and this extractor could not see it, so
  # the first hint to print `claude-worktime --help` failed the check against a
  # flag that works. The split on "|" below always expected this shape — the
  # matcher just never let those lines through.
  inblock && /^[[:space:]]*[^[:space:])]+\)/ {
    line = $0
    sub(/\).*$/, "", line)              # keep the pattern list, drop the body
    gsub(/^[[:space:]]+/, "", line)
    n = split(line, pats, "|")
    for (i = 1; i <= n; i++) if (pats[i] ~ /^--/) print pats[i]
  }
' "$SCRIPT" | sort -u)

# Guard the guard: a broken extractor yields an empty set, against which every
# printed flag reads as unhandled — loud. The opposite, an extractor that
# somehow matched everything, is the silent direction, so pin a known positive
# and a known negative rather than trusting a count.
if ! printf '%s\n' "$handled" | grep -qx -- '--rotate'; then
  echo "FAIL: extractor is broken — it did not find --rotate, which is handled"
  echo "      handled set was: $(printf '%s' "$handled" | tr '\n' ' ')"
  exit 1
fi
if printf '%s\n' "$handled" | grep -qx -- '--nonexistent-flag'; then
  echo "FAIL: extractor is broken — it reports a flag that is in no case arm"
  exit 1
fi

# Flags PRINTED: every "claude-worktime --flag" the file contains. The header
# comment block counts — `--help` prints it verbatim (`sed -n '2,/^$/…'`), so
# its usage lines are user-facing text, not commentary.
# ...but a comment BELOW that block is commentary, and commentary is not
# printed at anyone. Scanning it made this guard fire on a code comment that
# named `claude-worktime --tody` as an EXAMPLE OF A TYPO — a guard red on
# legitimate work, which is the fire that trains people to override guards.
# So: the header block (lines 2..first blank, printed verbatim by --help) plus
# every non-comment line, and nothing else.
printed=$( { sed -n '2,/^$/p' "$SCRIPT"; grep -vE '^[[:space:]]*#' "$SCRIPT"; } \
          | grep -o -- 'claude-worktime --[a-z][a-z-]*' \
          | sed 's/^claude-worktime //' | sort -u)

if [ -z "$printed" ]; then
  echo "FAIL: found no printed flags at all — the grep cannot have run correctly"
  exit 1
fi

fail=0
for f in $printed; do
  if ! printf '%s\n' "$handled" | grep -qx -- "$f"; then
    echo "FAIL: the script prints \"claude-worktime $f\" but has no $f arm —"
    echo "      it falls through to the default session mode and the hint is a no-op"
    grep -n -- "claude-worktime $f" "$SCRIPT" | sed 's/^/        /'
    fail=1
  fi
done

if [ "$fail" -eq 0 ]; then
  n=$(printf '%s\n' "$printed" | wc -l)
  echo "PASS: all $n flags the script prints at users are handled flags"
fi
exit "$fail"
