#!/usr/bin/env bash
# LINE4_CMD: an extension point, not a token — a user-supplied command whose
# first stdout line renders as a fourth statusline line. The contract
# (BACKLOG.md, READY entry "generic fourth statusline line") is fail-open,
# unconditionally: unset, empty stdout, nonzero exit, or a timeout must all
# reproduce today's three lines byte-for-byte, never leak error text.
#
# THE SHARP EDGE this suite exists to catch: a command substitution captures
# whatever was written to stdout regardless of the command's exit status. A
# command that prints a line and THEN fails (`echo oops; exit 1`) would leak
# "oops" onto the statusline unless the exit code is checked before the
# captured text is trusted — the first implementation attempt did exactly
# that, caught only by testing this exact shape rather than a bare `exit 1`
# with no prior output. Case 4 below is that shape; it is the discriminator,
# not a redundant arm — a check that only tries `false` (no output at all)
# would pass a build with this bug still in it.
#
# All session ids, names and paths here are SYNTHESIZED. This repo is public.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

SCRIPT="./claude-worktime.sh"
[ -f "$SCRIPT" ] || { echo "missing script: $SCRIPT" >&2; exit 2; }

TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT

# Sandbox both XDG roots and drop the direct overrides, or a real config.sh —
# or CLAUDE_WORKTIME_DATA in the environment — points this at the operator's
# live log.
unset CLAUDE_WORKTIME_DATA CLAUDE_WORKTIME_CONFIG CLAUDE_SESSIONS_DIR
export XDG_DATA_HOME="$TMP/data" XDG_CONFIG_HOME="$TMP/config"
LOGDIR="$XDG_DATA_HOME/claude-worktime"
CFGDIR="$XDG_CONFIG_HOME/claude-worktime"
mkdir -p "$LOGDIR" "$CFGDIR"
LOG="$LOGDIR/activity.jsonl"

SID="synthetic-session-id-l4"
CWD="$TMP/wsp/demo-project"
mkdir -p "$CWD"

# One event, an hour ago, so nothing rendered depends on real-time activity.
T=$(( $(date -d "today 00:00" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$(date +%Y-%m-%d) 00:00:00" +%s) - 3600 ))
printf '{"t":%d,"p":"%s","b":"","s":"%s","e":"prompt"}\n' "$T" "$CWD" "$SID" > "$LOG"

fails=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then
    printf '  ok   %-56s -> %s\n' "$1" "$3"
  else
    printf '  FAIL %-56s -> %s (expected %s)\n' "$1" "$3" "$2"
    fails=$((fails + 1))
  fi
}

COMMON_CFG='AUTO_ROTATE=false
COLD_NOTIFY=false
USAGE_FETCH_INTERVAL=0'

render() { # -> rendered statusline (RAW bytes, ANSI kept)
  # The trailing newline is load-bearing: _read_hook_stdin gates on `read`
  # succeeding, and read returns false at EOF on an unterminated line.
  printf '{"session_id":"%s","cwd":"%s"}\n' "$SID" "$CWD" \
    | "$SCRIPT" --statusline 2>/dev/null
}

line_count() { printf '%s' "$1" | wc -l; }
last_line_plain() { printf '%s' "$1" | tail -1 | sed 's/\x1b\[[0-9;]*m//g'; }

# ---------------------------------------------------------------------------
# Baseline: LINE4_CMD unset entirely — the pre-existing three-line output.
# ---------------------------------------------------------------------------
printf '%s\n' "$COMMON_CFG" > "$CFGDIR/config.sh"
BASE="$(render)"
if [ -z "$BASE" ]; then
  echo "FAIL: the baseline render is empty — the sandbox did not take, and an"
  echo "      empty string would let every byte-identity check below pass vacuously"
  exit 1
fi
# The synthetic stdin JSON carries no rate-limit/context/model fields, so
# STATUSLINE_3's groups all resolve empty and the line is suppressed
# entirely (empty groups hide, per the render loop) — the live baseline is
# whatever groups actually produced non-empty output, not a count assumed
# from the default STATUSLINE_1/2/3 template. Every check below is phrased
# relative to this observed baseline for that reason, never against a
# hardcoded line count.
BASE_LINES="$(line_count "$BASE")"
printf '  baseline (%s newlines):\n' "$BASE_LINES"
printf '%s\n' "$BASE" | sed 's/\x1b\[[0-9;]*m//g' | sed 's/^/    /'

# ---------------------------------------------------------------------------
# 1. Set: a fourth line renders, from the command's own stdout.
# ---------------------------------------------------------------------------
cat > "$CFGDIR/config.sh" <<EOF
$COMMON_CFG
LINE4_CMD='printf demo-line-4'
EOF
out="$(render)"
check "set: line count grows by exactly one" "$((BASE_LINES + 1))" "$(line_count "$out")"
check "set: fourth line is the command's stdout" "demo-line-4" "$(last_line_plain "$out")"
check "set: everything before the new line is untouched" "$BASE" "${out%$'\n'demo-line-4}"

# ---------------------------------------------------------------------------
# 2. Unset: byte-identical to baseline (already established above, restated
#    here as an explicit case so the suite output enumerates it).
# ---------------------------------------------------------------------------
printf '%s\n' "$COMMON_CFG" > "$CFGDIR/config.sh"
out="$(render)"; rc=$?
check "unset: output byte-identical to baseline" "$BASE" "$out"
check "unset: script exit 0" "0" "$rc"

# ---------------------------------------------------------------------------
# 3. Empty stdout: fails open, byte-identical to baseline.
# ---------------------------------------------------------------------------
cat > "$CFGDIR/config.sh" <<EOF
$COMMON_CFG
LINE4_CMD='true'
EOF
out="$(render)"; rc=$?
check "empty stdout: output byte-identical to baseline" "$BASE" "$out"
# THE EXIT STATUS IS PART OF THE CONTRACT, learned live (2026-08-19): a
# command that SUCCEEDS but prints nothing left `[ -n ] && printf` as the
# script's last statement, so the whole script exited 1 — and Claude Code
# hides the entire statusline on a nonzero exit. Byte-identical output with
# a nonzero exit is therefore a total outage wearing a passing test.
check "empty stdout: script exit 0 (nonzero hides the WHOLE statusline)" "0" "$rc"

# ---------------------------------------------------------------------------
# 4. THE DISCRIMINATOR: nonzero exit AFTER printing output. A check that only
#    tries a silently-failing command would pass even with the captured-
#    regardless-of-exit-status bug still present — this is what proves the
#    exit status, not just stdout emptiness, gates the line.
# ---------------------------------------------------------------------------
cat > "$CFGDIR/config.sh" <<EOF
$COMMON_CFG
LINE4_CMD='echo oops; exit 1'
EOF
out="$(render)"; rc=$?
check "nonzero exit with prior stdout: output byte-identical to baseline" "$BASE" "$out"
check "nonzero exit: script exit 0" "0" "$rc"
case "$out" in
  *oops*) printf '  FAIL %-56s -> leaked\n' "nonzero exit: failed command text never appears"
          fails=$((fails + 1)) ;;
  *)      check "nonzero exit: failed command text never appears" "0" "0" ;;
esac

# ---------------------------------------------------------------------------
# 5. Only the first stdout line renders.
# ---------------------------------------------------------------------------
cat > "$CFGDIR/config.sh" <<'EOF'
AUTO_ROTATE=false
COLD_NOTIFY=false
USAGE_FETCH_INTERVAL=0
LINE4_CMD='printf "first line\nsecond line\n"'
EOF
out="$(render)"
check "multi-line stdout: only the first line renders" "first line" "$(last_line_plain "$out")"

# ---------------------------------------------------------------------------
# 6. Runs in the session's project directory (the same cwd {project}
#    resolves from), not wherever the script happens to be invoked from.
# ---------------------------------------------------------------------------
cat > "$CFGDIR/config.sh" <<EOF
$COMMON_CFG
LINE4_CMD='pwd'
EOF
out="$(render)"
check "cwd: command runs in the session's project directory" "$CWD" "$(last_line_plain "$out")"

# ---------------------------------------------------------------------------
# 7. Timeout: only tested when the `timeout` binary exists (stock macOS
#    lacks it, and the contract runs unguarded there — README-documented).
# ---------------------------------------------------------------------------
if command -v timeout &>/dev/null; then
  cat > "$CFGDIR/config.sh" <<EOF
$COMMON_CFG
LINE4_CMD='echo partial; sleep 5'
EOF
  start_ns=$(date +%s%N)
  out="$(render)"
  end_ns=$(date +%s%N)
  elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
  check "timeout: killed command's output byte-identical to baseline" "$BASE" "$out"
  case "$out" in
    *partial*) printf '  FAIL %-56s -> leaked\n' "timeout: partial output before the kill never appears"
               fails=$((fails + 1)) ;;
    *)         check "timeout: partial output before the kill never appears" "0" "0" ;;
  esac
  # Generous upper bound: the 1s hard cap plus render overhead, well under
  # the 5s sleep the command asked for — proves the cap is real, not merely
  # that fail-open eventually happened some other way.
  if [ "$elapsed_ms" -lt 4000 ]; then
    printf '  ok   %-56s -> %sms\n' "timeout: capped near 1s, not the command's 5s" "$elapsed_ms"
  else
    printf '  FAIL %-56s -> %sms\n' "timeout: capped near 1s, not the command's 5s" "$elapsed_ms"
    fails=$((fails + 1))
  fi
else
  echo "  SKIP timeout case: no 'timeout' binary on this host (unguarded-mode contract, not exercised here)"
fi

if [ "$fails" -eq 0 ]; then
  echo "statusline-line4-cmd: all checks passed"
  exit 0
fi
echo "statusline-line4-cmd: $fails check(s) failed"
exit 1
