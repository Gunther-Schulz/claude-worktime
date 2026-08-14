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
# comparison: instead of "clean" meaning zero findings, it means the live run
# is a subset of a pinned baseline (docs/lint-baseline-*.txt). It reports NEW
# findings (fail the run), FIXED findings (info only, printed so the baseline
# can be honestly re-pinned), and a count of unchanged/known findings. Absent
# a file argument it picks the newest docs/lint-baseline-*.txt by filename
# (the date is embedded, so a plain sort orders it correctly). A missing or
# unreadable baseline is its own COULD NOT VERIFY, never read as clean.
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
(newest by filename when no file is given) on the tuple (file path, SC
code) — never line numbers or message text, both of which drift on
unrelated edits. Reports NEW findings (exit non-zero), FIXED findings
(info only), and a count of known findings. A missing or unreadable
baseline is COULD NOT VERIFY, never "clean".
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

  known_tuples_file="$(mktemp)"
  trap 'rm -f "$known_tuples_file"' EXIT

  # Baseline comparison GRAIN, decided (BACKLOG.md, this entry): (file path,
  # SC code), never line numbers (they move on any edit above them, so an
  # unrelated change would look like a new finding) and never message text
  # (carries variable content, e.g. the variable name in SC2034's message).
  # The tradeoff: multiple same-code findings within one file collapse to one
  # known tuple, so a genuinely new SC2034 in an already-SC2034-flagged file
  # will not be flagged NEW.
  #
  # The tuple is pulled straight out of the baseline file's verbatim
  # `--format=gcc` findings block (the same lines shellcheck itself prints —
  # see the existing docs/lint-baseline-2026-08-08.txt) with the SAME pattern
  # used below on the live run, so both sides read the identical shape and
  # a parsing drift between them cannot silently misalign the comparison.
  # Prose lines in the header do not match and are skipped, not misread.
  gcc_line_pattern='^([^:]+):[0-9]+:[0-9]+: [a-z]+: .*\[(SC[0-9]+)\]$'
  sed -nE "s/${gcc_line_pattern}/\\1:\\2/p" "$baseline_file" | sort -u > "$known_tuples_file"

  if [ ! -s "$known_tuples_file" ]; then
    echo "lint.sh --baseline: COULD NOT VERIFY — $baseline_file has no parseable" \
         "shellcheck findings lines (expected verbatim --format=gcc output)" >&2
    exit 2
  fi

  declare -A known_tuples=()
  while IFS= read -r t; do
    known_tuples["$t"]=1
  done < "$known_tuples_file"

  live_output="$(shellcheck --severity=warning --format=gcc "${targets[@]}")"

  declare -A live_seen=()
  total_live=0
  new_count=0
  new_report=""
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if [[ "$line" =~ $gcc_line_pattern ]]; then
      total_live=$(( total_live + 1 ))
      tuple="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
      live_seen["$tuple"]=1
      if [ -z "${known_tuples[$tuple]:-}" ]; then
        new_count=$(( new_count + 1 ))
        new_report="${new_report}${line}"$'\n'
      fi
    fi
  done <<< "$live_output"

  fixed_report=""
  fixed_count=0
  for tuple in "${!known_tuples[@]}"; do
    if [ -z "${live_seen[$tuple]:-}" ]; then
      fixed_count=$(( fixed_count + 1 ))
      fixed_report="${fixed_report}${tuple}"$'\n'
    fi
  done
  fixed_report="$(printf '%s' "$fixed_report" | sort)"

  known_count=$(( total_live - new_count ))

  echo "lint.sh --baseline: comparing live run against $baseline_file"
  echo

  if [ "$new_count" -gt 0 ]; then
    echo "NEW findings (not in baseline):"
    printf '%s' "$new_report"
    echo
  fi

  if [ "$fixed_count" -gt 0 ]; then
    echo "FIXED findings (in baseline, not live anymore — info only):"
    printf '%s\n' "$fixed_report"
    echo
  fi

  echo "known findings (unchanged, present in both): $known_count"

  if [ "$new_count" -eq 0 ] && [ "$fixed_count" -eq 0 ]; then
    echo "shellcheck --baseline: clean ($known_count known findings, 0 new, 0 fixed)"
  fi

  if [ "$new_count" -gt 0 ]; then
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
