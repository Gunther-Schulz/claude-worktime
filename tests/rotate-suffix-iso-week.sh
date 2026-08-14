#!/usr/bin/env bash
# The weekly rotation suffix must pair an ISO week NUMBER with an ISO week-YEAR.
#
# WHY THIS EXISTS
# Found 2026-08-14 in the (g) residue of the --doctor lane's report, flagged as
# inherited and out of that lane's scope, then measured here:
#
#   2027-01-01   %Y-W%V = 2027-W53      correct %G-W%V = 2026-W53
#   2027-01-03   %Y-W%V = 2027-W53      correct %G-W%V = 2026-W53
#   2027-01-04   %Y-W%V = 2027-W01      correct %G-W%V = 2027-W01
#
# %V is the ISO 8601 week number, whose companion year is %G, not %Y. For the
# first days of a year that belong to the previous year's final ISO week, %Y-W%V
# names a period that DOES NOT EXIST (2027 has no week 53 at its start).
#
# The misnaming is the mild half. The severe half is ORDERING: this repo sorts
# archive suffixes LEXICOGRAPHICALLY and relies on that being chronological —
# cmd_doctor picks "the newest archive" that way and compares it against a
# threshold suffix. "2027-W53" sorts AFTER "2027-W01", so a New Year's Day
# archive would read as newer than every archive produced for the rest of that
# year, and the staleness verdict would be wrong for twelve months while
# reporting clean. That is the quiet direction again.
#
# THE FORMATS ARE DERIVED FROM THE SCRIPT, NOT RESTATED HERE. A hardcoded copy
# of the format string beside the script it mirrors cannot age loudly: a third
# weekly-suffix site could appear with the wrong format and this file would stay
# green, byte-identical to health.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
SCRIPT="${CW_SCRIPT:-claude-worktime.sh}"
[ -f "$SCRIPT" ] || { echo "missing script: $SCRIPT" >&2; exit 2; }

date -d "2027-01-01" +%G >/dev/null 2>&1 || {
    echo "COULD NOT VERIFY: this date(1) does not support -d/%G (BSD?); skipping" >&2
    exit 0
}

fail=0

# Every week-number format the script uses, taken from its own source with
# whole-line comments stripped (a format named in prose is not a format in use).
mapfile -t fmts < <(grep -vE '^[[:space:]]*#' "$SCRIPT" \
    | grep -oE '\+%[A-Za-z]-W%V' | sort -u)

# Instrument positive: a dead scan would pass every assertion below vacuously.
if [ "${#fmts[@]}" -eq 0 ]; then
    echo "FAIL: extracted NO weekly suffix format from $SCRIPT — the scan is dead," >&2
    echo "      not the tree. Refusing to report clean." >&2
    exit 2
fi
echo "weekly suffix formats found in $SCRIPT: ${fmts[*]}"

for f in "${fmts[@]}"; do
    fmt="${f#+}"
    # (1) Correctness at the boundary: the suffix for 2027-01-01 must name the
    #     ISO week-year that day actually belongs to, which is 2026.
    got=$(date -d "2027-01-01" "+$fmt")
    want=$(date -d "2027-01-01" "+%G-W%V")
    if [ "$got" = "$want" ]; then
        printf '  ✓ %s at 2027-01-01 -> %s\n' "$fmt" "$got"
    else
        printf '  ✗ %s at 2027-01-01 -> %s, but that day is in %s\n' "$fmt" "$got" "$want"
        fail=1
    fi

    # (2) The property the code actually depends on: lexicographic order must be
    #     chronological ACROSS the year boundary. This is the assertion that
    #     catches the ordering break even if someone decides the name is
    #     cosmetic.
    early=$(date -d "2027-01-01" "+$fmt")   # chronologically FIRST
    later=$(date -d "2027-01-04" "+$fmt")   # chronologically SECOND
    if [[ "$early" < "$later" ]]; then
        printf '  ✓ %s sorts chronologically across the year boundary (%s < %s)\n' \
            "$fmt" "$early" "$later"
    else
        printf '  ✗ %s BREAKS lexicographic ordering: %s is not < %s, so a\n' \
            "$fmt" "$early" "$later"
        printf '      New Year archive reads as newer than the rest of the year\n'
        fail=1
    fi
done

# Negative control, from the data rather than constructed: the known-bad format
# must FAIL the same assertions this file applies to the real ones. Without it a
# predicate that passes everything would report clean above.
ctl_early=$(date -d "2027-01-01" "+%Y-W%V")
ctl_later=$(date -d "2027-01-04" "+%Y-W%V")
if [[ "$ctl_early" < "$ctl_later" ]]; then
    echo "  ✗ control: %Y-W%V was expected to break ordering here and did not —" >&2
    echo "      this date(1) does not reproduce the defect, so a pass above means nothing" >&2
    fail=1
else
    printf '  ✓ control: the known-bad %%Y-W%%V does break ordering (%s !< %s)\n' \
        "$ctl_early" "$ctl_later"
fi

echo
if [ "$fail" -eq 0 ]; then echo "PASS: weekly suffixes are ISO week-year based and sort chronologically"
else echo "FAIL: weekly suffix defect present"; fi
exit "$fail"
