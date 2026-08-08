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
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# Run from the repo root so .shellcheckrc is picked up regardless of the caller's
# working directory, and so paths in the output are repo-relative.
cd "$ROOT" || { echo "lint.sh: cannot cd to $ROOT" >&2; exit 2; }

usage() {
  cat <<'EOF'
usage: tools/lint.sh [shellcheck args...]

Runs shellcheck at --severity=warning over the repo's shell scripts.
Extra arguments are passed through to shellcheck (e.g. --format=gcc).

Exits 0 when clean AND when shellcheck is absent (with a "could not verify"
message); non-zero only when shellcheck itself reports findings.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

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

shellcheck --severity=warning "$@" "${targets[@]}"
rc=$?

if [ "$rc" -eq 0 ]; then
  echo "shellcheck: clean (${#targets[@]} files, --severity=warning)"
fi
exit "$rc"
