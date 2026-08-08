#!/usr/bin/env bash
# Consult the transcript diagnostic BEFORE the idle/model cause is assumed.
#
# WHY THIS EXISTS
# BACKLOG.md "(A): consult the diagnostic BEFORE the idle short-circuit".
# The idle branch used to decide cs_lastcause="idle" straight from the gap,
# without ever reading the transcript diagnostic — that read only happened
# in the residual ("other") branch, reached only when idle and model were
# both already ruled out. A genuine resume/fork/compact artifact (API
# diagnostic cache_miss_reason.type == previous_message_not_found) landing
# on top of a long idle gap therefore booked as an ordinary idle BUST, not
# the controlled cost it actually is. Measured twice: 2026-08-06T23:59:10Z
# (cc 215,873, gap 22,702s) and recurred 2026-08-07T03:32:02Z (cc 427,535,
# gap 4,741s).
#
# The fix moves the diagnostic read ahead of the idle/model ladder so a
# previous_message_not_found diagnostic wins outright, regardless of gap.
# BACKLOG.md is explicit that the "gap > TTL with no diagnostic" leg is
# STRUCK — it must NOT also silence idle expiries that have no matching
# diagnostic, since idle cache expiry is the canonical preventable bust.
# This suite is three-sided per the backlog's own verifier: the two
# controlled-cost cases, PLUS two "must still book as a hit" controls that
# would catch the leg being over-broadened (the over-firing control the
# backlog calls out by name).
#
# RED-FIRST for the two controlled-cost cases: against the pre-fix script
# both must book as a bust (k:"hit" cause:"idle"); against the fix, a
# controlled cost (k:"cost" cause:"resume") with no hit. The two "must still
# hit" controls are asserted against the fix only — they were never broken,
# and exist to prove the fix does not silence them.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
SCRIPT="${CW_SCRIPT:-../claude-worktime.sh}"
command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }
[ -f "$SCRIPT" ] || { echo "missing script: $SCRIPT" >&2; exit 2; }

pass=0 fail=0
NOW=$(date +%s)

# $1 label  $2 sid  $3 state-line  $4 transcript-body  $5 cc  $6 want-kind (hit|cost)  $7 want-cause
case_run() {
    local label=$1 sid=$2 state=$3 tbody=$4 cc=$5 want_kind=$6 want_cause=$7
    local d; d=$(mktemp -d)
    local now; now=$(date +%s)
    printf '{"t":%d,"p":"/tmp/p","s":"%s","e":"prompt"}\n' "$now" "$sid" > "$d/activity.jsonl"
    : > "$d/config.sh"
    printf '%s\n' "$state" > "$d/.cold_$sid"
    local tp="$d/transcript.jsonl"
    printf '%s\n' "$tbody" > "$tp"
    printf '{"session_id":"%s","transcript_path":"%s","model":{"id":"claude-fable-5"},"workspace":{"current_dir":"/tmp/p"},"context_window":{"used_percentage":30,"current_usage":{"cache_read_input_tokens":0,"cache_creation_input_tokens":%d,"input_tokens":100,"output_tokens":10}}}\n' \
        "$sid" "$tp" "$cc" \
        | COLD_NOTIFY=false CLAUDE_WORKTIME_DATA="$d" CLAUDE_WORKTIME_CONFIG="$d" bash "$SCRIPT" --statusline >/dev/null 2>&1
    local got_kind got_cause
    if grep -q '"k":"hit"' "$d/activity.jsonl" 2>/dev/null; then
        got_kind=hit; got_cause=$(grep '"k":"hit"' "$d/activity.jsonl" | jq -r '.cause' | tail -1)
    elif grep -q '"k":"cost"' "$d/activity.jsonl" 2>/dev/null; then
        got_kind=cost; got_cause=$(grep '"k":"cost"' "$d/activity.jsonl" | jq -r '.cause' | tail -1)
    else
        got_kind=none; got_cause=none
    fi
    rm -rf "$d"
    if [ "$got_kind" = "$want_kind" ] && [ "$got_cause" = "$want_cause" ]; then
        printf '  \033[32m✓\033[0m %s\n' "$label"; pass=$(( pass + 1 ))
    else
        printf '  \033[31m✗\033[0m %s (got %s/%s, want %s/%s)\n' "$label" "$got_kind" "$got_cause" "$want_kind" "$want_cause"; fail=$(( fail + 1 ))
    fi
}

echo "consult the diagnostic before the idle short-circuit ($SCRIPT):"

# Case 1 — 2026-08-06T23:59:10Z shape: idle-range gap (22,702s), diagnostic
# previous_message_not_found. Fixed script: controlled cost, no bust.
case_run "23:59:10Z shape: idle gap + resume diagnostic -> cost/resume, no hit" \
    "case2359" "3 300000 $((NOW-22702)) 200000 0 - claude-fable-5" \
    '{"type":"assistant","message":{"usage":{"cache_creation_input_tokens":215873},"content":[{"type":"text"}],"stop_reason":"end_turn","diagnostics":{"cache_miss_reason":{"type":"previous_message_not_found"}}}}' \
    215873 cost resume

# Case 2 — 2026-08-07T03:32:02Z shape: idle-range gap (4,741s), same
# diagnostic. Fixed script: controlled cost, no bust.
case_run "03:32:02Z shape: idle gap + resume diagnostic -> cost/resume, no hit" \
    "case0332" "3 500000 $((NOW-4741)) 400000 0 - claude-fable-5" \
    '{"type":"assistant","message":{"usage":{"cache_creation_input_tokens":427535},"content":[{"type":"text"}],"stop_reason":"end_turn","diagnostics":{"cache_miss_reason":{"type":"previous_message_not_found"}}}}' \
    427535 cost resume

# Control A (over-firing control, [vet]-named) — genuine idle expiry, gap
# past TTL, NO resume diagnostic anywhere in the transcript. The struck
# gap>TTL leg would have silenced this; the diagnostic-only leg must not.
case_run "control: idle gap, no resume diagnostic -> still a hit/idle" \
    "casectrlA" "3 300000 $((NOW-22702)) 200000 0 - claude-fable-5" \
    '{"type":"assistant","message":{"usage":{"cache_creation_input_tokens":100},"content":[{"type":"text"}],"stop_reason":"end_turn"}}' \
    215873 hit idle

# Control B — the genuine mid-history bust, 2026-08-06T18:08:32Z shape:
# gap=7 (structurally cannot exercise a gap-based leg), same model,
# diagnostic messages_changed, mtok 267,780. Must still book as a hit.
case_run "18:08:32Z shape: gap=7, messages_changed -> still a hit/messages_changed" \
    "casectrlB" "3 300000 $((NOW-7)) 200000 0 - claude-fable-5" \
    '{"type":"assistant","message":{"usage":{"cache_creation_input_tokens":267780},"content":[{"type":"text"}],"stop_reason":"end_turn","diagnostics":{"cache_miss_reason":{"type":"messages_changed","cache_missed_input_tokens":267780}}}}' \
    267780 hit messages_changed

echo
if [ "$fail" -eq 0 ]; then
    printf '  \033[32mall %d cases pass\033[0m\n' "$pass"; exit 0
else
    printf '  \033[31m%d of %d failed\033[0m\n' "$fail" "$((pass+fail))"; exit 1
fi
