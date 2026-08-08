#!/usr/bin/env bash
# Repo-local pre-push gate: tools/run-tests.sh must pass before anything leaves
# this repo. Exit code = number of failed suites, which is what git keys on, so
# a red suite blocks the push.
#
# HOW IT IS REACHED. core.hooksPath points at dotfiles' machine-wide pre-push
# dispatcher, which shadows .git/hooks/pre-push for every repo on this machine.
# That dispatcher chains to the repo-local hook of the same name and returns its
# exit code, so this file runs as a CHAINED hook, not as git's direct one.
# Activation is therefore a symlink, created once per clone:
#
#   ln -s ../../tools/git-pre-push.sh .git/hooks/pre-push
#
# .git/hooks/ is not tracked, so the symlink does not survive a fresh clone —
# the tracked file is this one, the symlink is the machine-local activation.
#
# TWO LIMITS, both inherited from the dispatcher's chaining contract:
#   - it kills a chained hook at 120s and lets the push CONTINUE (fail-open).
#     The suite runs in ~9s, so the margin is wide, but a suite that grew past
#     two minutes would stop gating silently rather than loudly.
#   - `git push --no-verify` skips hooks entirely, this one included.
#
# Deliberately NOT wired in: tools/lint.sh. It reports 34 open findings, so
# gating on it would block every push from the first day and train the override
# habit that makes a gate worthless.

set -uo pipefail

root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$root" || exit 0

[ -x tools/run-tests.sh ] || exit 0

echo "[pre-push] running the suite before push (tools/run-tests.sh)…"
tools/run-tests.sh --quiet
rc=$?

if [ "$rc" -ne 0 ]; then
    echo "[pre-push] BLOCKED: $rc suite(s) failing — push refused." >&2
    echo "[pre-push] Run tools/run-tests.sh for the failing suite's output," >&2
    echo "[pre-push] or push with --no-verify if you know why that is right." >&2
fi

exit "$rc"
