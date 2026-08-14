#!/usr/bin/env bash
# An unrecognised flag must be NAMED and exit non-zero — never run a different
# mode in silence.
#
# WHY THIS EXISTS
# The top-level argument loop ended in `*) ;;`, so any flag it did not know was
# discarded and the tool ran its DEFAULT session summary instead. A typo did not
# fail; it answered a different question, confidently. `claude-worktime --tody`
# printed a session summary and exited 0, and nothing distinguished that from
# the run the user meant.
#
# The `--info` fix (BACKLOG, Departed) closed the narrower class — every flag the
# script PRINTS must have a real arm, kept shut by
# tests/printed-flags-are-handled.sh. This suite closes the general one.
#
# THE FALSE-FIRE CONTROLS ARE THE POINT, not the red. Making unknown flags error
# is a behaviour change, and the way it goes wrong is by rejecting something
# legitimate — so every real entry point is exercised here: the six harness hook
# call sites (`log --*` and `--statusline`), the value-taking filters whose
# ARGUMENT must not be mistaken for a flag, and the bare default run.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
SCRIPT="${CW_SCRIPT:-./claude-worktime.sh}"
[ -f "$SCRIPT" ] || { echo "missing script: $SCRIPT" >&2; exit 2; }

command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/data" "$WORK/cfg"; : > "$WORK/cfg/config.sh"
printf '{"t":%d,"p":"/tmp/p","b":"main","s":"sess","e":"prompt"}\n' "$(date +%s)" \
    > "$WORK/data/activity.jsonl"

run() {  # echoes "<exit>|<output>"
    local out rc
    out=$(CLAUDE_WORKTIME_DATA="$WORK/data" CLAUDE_WORKTIME_CONFIG="$WORK/cfg" \
          COLD_NOTIFY=false bash "$SCRIPT" "$@" 2>&1)
    rc=$?
    printf '%s|%s' "$rc" "$out"
}

pass=0; fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$(( pass + 1 )); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$(( fail + 1 )); }

echo "unknown flags are named and rejected:"

# --- the red: an unknown flag must not run the default mode silently
r=$(run --nonsense); rc=${r%%|*}; out=${r#*|}
if [ "$rc" -eq 0 ]; then
    bad "--nonsense must exit non-zero (got 0; output began: ${out%%$'\n'*})"
elif ! printf '%s' "$out" | grep -q -- "--nonsense"; then
    bad "--nonsense must NAME the offending flag (exit $rc, output: ${out%%$'\n'*})"
else
    ok "--nonsense: exit $rc and the flag is named"
fi

# A near-miss typo of a real flag is the case this actually protects against.
r=$(run --tody); rc=${r%%|*}
[ "$rc" -ne 0 ] && ok "--tody (typo of --today) rejected, exit $rc" \
                || bad "--tody silently ran a mode, exit 0"

echo
echo "false-fire controls — every legitimate entry point must still work:"

# The bare default run.
r=$(run); rc=${r%%|*}
[ "$rc" -eq 0 ] && ok "no arguments: session summary, exit 0" \
                || bad "no arguments must exit 0 (got $rc)"

# Real filters, including the value-taking ones whose ARGUMENT must not be read
# as an unknown flag.
for args in "--today" "--week" "--breakdown --today" "--summary --today" \
            "--since 2026-01-01" "--filter /tmp/p" "--branch main" \
            "--session sess" "--cold" "--cold --all" "--csv --today" "--raw --today"; do
    # shellcheck disable=SC2086
    r=$(run $args); rc=${r%%|*}
    [ "$rc" -eq 0 ] && ok "\`$args\` accepted, exit 0" \
                    || bad "\`$args\` was rejected, exit $rc: $(printf '%s' "${r#*|}" | head -1)"
done

echo
echo "the six harness hook call sites must be untouched:"
# These reach the top-level dispatch, not the argument loop — `log` shifts and
# exits, `--statusline` sets a mode. If the unknown-flag rule ever moved ahead
# of that dispatch, these are what would break, silently and in the operator's
# own hooks.
for sub in --start --prompt --response --tool-start --tool-end; do
    r=$(printf '{"session_id":"sess","cwd":"/tmp/p"}\n' | \
        CLAUDE_WORKTIME_DATA="$WORK/data" CLAUDE_WORKTIME_CONFIG="$WORK/cfg" \
        COLD_NOTIFY=false bash "$SCRIPT" log "$sub" 2>&1; echo "|$?")
    rc=${r##*|}
    [ "$rc" -eq 0 ] && ok "log $sub: exit 0" || bad "log $sub broke, exit $rc"
done
# --statusline is asserted on the property AT STAKE — that it is not rejected as
# an unknown flag — not on its exit code. Its exit code is a separate, flaky
# signal here: with a populated data dir this suite's minimal synthetic event
# produced exit 1 and a literal "{" in the render on one run and exit 0 on the
# next, against an UNMODIFIED script. That intermittency is booked in BACKLOG.md
# and is not this suite's subject; keying a control on it would import a flake
# into a check about argument parsing, and a flaky control is worse than none
# because it trains the override reflex.
r=$(printf '{"session_id":"sess","workspace":{"current_dir":"/tmp/p"}}\n' | \
    CLAUDE_WORKTIME_DATA="$WORK/data" CLAUDE_WORKTIME_CONFIG="$WORK/cfg" \
    COLD_NOTIFY=false bash "$SCRIPT" --statusline 2>&1)
if printf '%s' "$r" | grep -qi "unknown\|unrecognis\|unrecogniz"; then
    bad "--statusline was rejected as an unknown flag: $(printf '%s' "$r" | head -1)"
else
    ok "--statusline: not rejected as an unknown flag"
fi

echo
printf '  %d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
