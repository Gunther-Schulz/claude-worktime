#!/usr/bin/env bash
# Run shellcheck over this repo's shell, at --severity=warning.
#
# A checker has THREE answers, not two, and the third is the one that lies:
#
#   findings    — shellcheck's own output, exit 1 (its exit code, passed through)
#   clean       — no findings, exit 0
#   CANNOT VERIFY — shellcheck is not installed. Exits 0 so it never becomes a
#                   hard failure on a machine that simply lacks the tool, and
#                   says "could not verify" in those words so the skip is never
#                   read as a clean run. A silent exit 0 here would be a green
#                   light that checked nothing.
#
# Suppressions live in .shellcheckrc at the repo root, each with its reason.
# Style nits are deliberately out of scope: --severity=warning is the floor.
#
# `--baseline [file]` extends the same three-answer contract with a fourth
# comparison: instead of "clean" meaning zero findings, it means every (file,
# SC code) tuple's live COUNT is at or below its count in a pinned baseline
# (docs/lint-baseline-*.txt) — a per-tuple presence check would let a second
# same-code finding land in an already-flagged file invisibly, since one
# known finding there would vouch for any number more. It reports NEW
# findings (fail the run), FIXED findings (info only, printed so the
# baseline can be honestly re-pinned), and a count of unchanged/known
# findings. Absent a file argument it picks the newest
# docs/lint-baseline-*.txt by filename (the date is embedded, so a plain
# sort orders it correctly). A missing or unreadable baseline is its own
# COULD NOT VERIFY, never read as clean.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# Run from the repo root so .shellcheckrc is picked up regardless of the caller's
# working directory, and so paths in the output are repo-relative.
cd "$ROOT" || { echo "lint.sh: cannot cd to $ROOT" >&2; exit 2; }

usage() {
  cat <<'EOF'
usage: tools/lint.sh [shellcheck args...]
       tools/lint.sh --baseline [baseline-file]

Runs shellcheck at --severity=warning over the repo's shell scripts.
Extra arguments are passed through to shellcheck (e.g. --format=gcc).

Exits 0 when clean AND when shellcheck is absent (with a "could not verify"
message); non-zero only when shellcheck itself reports findings.

--baseline diffs the live run against a pinned docs/lint-baseline-*.txt
(newest by filename when no file is given) on the PER-TUPLE COUNT of
(file path, SC code) — never line numbers or message text, both of which
drift on unrelated edits, and never mere presence, which would let a
second same-code finding in an already-flagged file pass silently.
Reports NEW findings (exit non-zero), FIXED findings (info only), and a
count of known findings. A missing or unreadable baseline is COULD NOT
VERIFY, never "clean".
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

baseline_mode=0
baseline_file=""
if [ "${1:-}" = "--baseline" ]; then
  baseline_mode=1
  shift
  # An optional following argument that isn't itself a flag is the baseline
  # file path; absent, it defaults to the newest docs/lint-baseline-*.txt.
  if [ $# -ge 1 ] && [ "${1#-}" = "$1" ]; then
    baseline_file="$1"
    shift
  fi
fi

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck not installed — skipping (install: pacman -S shellcheck," \
       "apt install shellcheck, or brew install shellcheck)"
  echo "COULD NOT VERIFY: no lint ran, so this is not a clean result."
  exit 0
fi

# Explicit top-level scripts, plus the tools/ and tests/ globs so a new script
# in either directory is linted without editing this list.
shopt -s nullglob
targets=( claude-worktime.sh config.sh install.sh uninstall.sh tools/*.sh tests/*.sh )
shopt -u nullglob

if [ "${#targets[@]}" -eq 0 ]; then
  echo "lint.sh: COULD NOT VERIFY — no shell scripts matched in $ROOT" >&2
  exit 2
fi

if [ "$baseline_mode" -eq 1 ]; then
  if [ -z "$baseline_file" ]; then
    shopt -s nullglob
    baseline_candidates=( "$ROOT"/docs/lint-baseline-*.txt )
    shopt -u nullglob
    if [ "${#baseline_candidates[@]}" -eq 0 ]; then
      echo "lint.sh --baseline: COULD NOT VERIFY — no docs/lint-baseline-*.txt found in $ROOT/docs" >&2
      exit 2
    fi
    # Newest by filename: the date is embedded (YYYY-MM-DD), so a plain sort
    # orders correctly without parsing anything.
    baseline_file="$(printf '%s\n' "${baseline_candidates[@]}" | sort | tail -n1)"
  fi

  if [ ! -r "$baseline_file" ]; then
    echo "lint.sh --baseline: COULD NOT VERIFY — cannot read baseline file: $baseline_file" >&2
    exit 2
  fi

  # Baseline comparison GRAIN, decided (BACKLOG.md, this entry; corrected
  # 2026-08-14 after being measured against this repo's own baseline): (file
  # path, SC code) COUNTS, not presence — never line numbers (they move on
  # any edit above them, so an unrelated change would look like a new
  # finding) and never message text (carries variable content, e.g. the
  # variable name in SC2034's message). Presence-only collapsed 24 distinct
  # claude-worktime.sh SC2034 findings into one "known" tuple, so a
  # genuinely new SC2034 anywhere in that file — the most-edited script,
  # carrying the most common code — went unreported: a check reading clean
  # while exercising less than it claimed. Counting per tuple closes that: a
  # tuple's live count exceeding baseline is NEW for the excess, below is
  # FIXED for the shortfall, equal is unchanged. A finding moving from one
  # file to another therefore reads as one FIXED plus one NEW — correct, and
  # deliberately not special-cased.
  #
  # Both sides are parsed from the SAME verbatim `--format=gcc` shape (the
  # baseline file carries real shellcheck output — see
  # docs/lint-baseline-2026-08-08.txt) with the SAME pattern, so a parsing
  # drift between them cannot silently misalign the comparison. Prose lines
  # in the header do not match and are skipped, not misread.
  gcc_line_pattern='^([^:]+):[0-9]+:[0-9]+: [a-z]+: .*\[(SC[0-9]+)\]$'

  declare -A baseline_count=()
  total_baseline=0
  # Process substitution, not a pipe: a pipe would run this loop in a
  # subshell, and every baseline_count/total_baseline update would vanish
  # the moment the loop exits.
  while IFS= read -r tuple; do
    [ -z "$tuple" ] && continue
    baseline_count["$tuple"]=$(( ${baseline_count[$tuple]:-0} + 1 ))
    total_baseline=$(( total_baseline + 1 ))
  done < <(sed -nE "s/${gcc_line_pattern}/\\1:\\2/p" "$baseline_file")

  if [ "$total_baseline" -eq 0 ]; then
    echo "lint.sh --baseline: COULD NOT VERIFY — $baseline_file has no parseable" \
         "shellcheck findings lines (expected verbatim --format=gcc output)" >&2
    exit 2
  fi

  live_output="$(shellcheck --severity=warning --format=gcc "${targets[@]}")"

  declare -A live_count=()
  total_live=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if [[ "$line" =~ $gcc_line_pattern ]]; then
      tuple="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
      live_count["$tuple"]=$(( ${live_count[$tuple]:-0} + 1 ))
      total_live=$(( total_live + 1 ))
    fi
  done <<< "$live_output"

  # Union of every tuple seen on either side, sorted for deterministic output.
  all_tuples="$( { printf '%s\n' "${!baseline_count[@]}"; printf '%s\n' "${!live_count[@]}"; } | sort -u )"

  new_report=""
  fixed_report=""
  new_delta_total=0
  fixed_delta_total=0
  while IFS= read -r tuple; do
    [ -z "$tuple" ] && continue
    b=${baseline_count[$tuple]:-0}
    l=${live_count[$tuple]:-0}
    if [ "$l" -gt "$b" ]; then
      d=$(( l - b ))
      new_delta_total=$(( new_delta_total + d ))
      new_report="${new_report}${tuple}: ${l} live vs ${b} baseline (+${d})"$'\n'
    elif [ "$l" -lt "$b" ]; then
      d=$(( b - l ))
      fixed_delta_total=$(( fixed_delta_total + d ))
      fixed_report="${fixed_report}${tuple}: ${l} live vs ${b} baseline (-${d})"$'\n'
    fi
  done <<< "$all_tuples"

  known_count=$(( total_live - new_delta_total ))

  echo "lint.sh --baseline: comparing live run against $baseline_file"
  echo

  if [ "$new_delta_total" -gt 0 ]; then
    echo "NEW findings (live count exceeds baseline count for the tuple):"
    printf '%s' "$new_report"
    echo
  fi

  if [ "$fixed_delta_total" -gt 0 ]; then
    echo "FIXED findings (live count below baseline count for the tuple — info only):"
    printf '%s' "$fixed_report"
    echo
  fi

  echo "known findings (unchanged, present in both): $known_count"

  if [ "$new_delta_total" -eq 0 ] && [ "$fixed_delta_total" -eq 0 ]; then
    echo "shellcheck --baseline: clean ($known_count known findings, 0 new, 0 fixed)"
  fi

  if [ "$new_delta_total" -gt 0 ]; then
    exit 1
  fi
  exit 0
fi

shellcheck --severity=warning "$@" "${targets[@]}"
rc=$?

if [ "$rc" -eq 0 ]; then
  echo "shellcheck: clean (${#targets[@]} files, --severity=warning)"
fi
exit "$rc"
