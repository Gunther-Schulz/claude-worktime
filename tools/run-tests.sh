#!/usr/bin/env bash
# Run every suite in tests/ and exit non-zero if any of them failed.
#
# The exit code is the point: it is what a git hook or a CI job keys on. A
# runner that always exits 0 reports a green wall over a broken tree, which is
# the same "reads exactly like checked and clean" failure the suites themselves
# were written about.
#
# House idiom (tests/replay-cold-corrupt-log.sh and siblings): a suite is
# standalone bash, sandboxes itself via XDG_DATA_HOME, prints PASS:/FAIL: lines
# on stdout and exits with its failure count. This runner treats any non-zero
# exit as a failed suite and does not interpret the number beyond that.
#
# Suites are discovered by glob, so a new tests/*.sh runs with no edit here.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TESTDIR="$ROOT/tests"

usage() {
  cat <<'EOF'
usage: tools/run-tests.sh [--quiet]

Runs every tests/*.sh, each in its own process. Prints one line per suite and
a final "N passed, M failed" summary. Exits with the number of FAILED SUITES
(0 = everything passed), so a hook or CI can key on the exit code alone.

  -q, --quiet   print only failing suites and the summary
  -h, --help    this message
EOF
}

quiet=0
for arg in "$@"; do
  case "$arg" in
    -q|--quiet) quiet=1 ;;
    -h|--help)  usage; exit 0 ;;
    *)
      echo "run-tests.sh: unknown option: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ ! -d "$TESTDIR" ]; then
  echo "run-tests.sh: no tests directory at $TESTDIR" >&2
  exit 2
fi

shopt -s nullglob
suites=( "$TESTDIR"/*.sh )
shopt -u nullglob

# Zero suites is the could-not-verify answer, and it must not wear a pass's
# clothes: "0 passed, 0 failed" followed by exit 0 is indistinguishable from a
# green run, which is precisely how a broken discovery glob hides.
if [ "${#suites[@]}" -eq 0 ]; then
  echo "run-tests.sh: COULD NOT VERIFY — no suites matched $TESTDIR/*.sh" >&2
  echo "              nothing was run; this is not a passing result" >&2
  exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

passed=0
failed=0
started=$SECONDS

for suite in "${suites[@]}"; do
  name="$(basename "$suite")"
  out="$TMP/$name.out"

  # Own process, and the exit status is captured rather than allowed to end the
  # run: one suite's failure must never cost the suites after it.
  "$suite" >"$out" 2>&1
  rc=$?

  if [ "$rc" -eq 0 ]; then
    passed=$(( passed + 1 ))
    [ "$quiet" -eq 1 ] || printf 'PASS  %s\n' "$name"
  else
    failed=$(( failed + 1 ))
    printf 'FAIL  %s (exit %d)\n' "$name" "$rc"
    # The suite's own output is the evidence for the verdict; a summary of it
    # is not. Indented so it reads as belonging to the line above.
    if [ -s "$out" ]; then
      sed 's/^/      /' "$out"
    else
      printf '      (no output)\n'
    fi
  fi
done

elapsed=$(( SECONDS - started ))

noun=suites
[ "${#suites[@]}" -eq 1 ] && noun=suite

printf '\n%d passed, %d failed  (%d %s in %ds)\n' \
  "$passed" "$failed" "${#suites[@]}" "$noun" "$elapsed"

# Exit = number of failed suites, matching the suites' own convention. Capped
# well below the shell's reserved codes so a large failure count can never wrap
# to 0 and read as success.
if [ "$failed" -gt 125 ]; then
  exit 125
fi
exit "$failed"
