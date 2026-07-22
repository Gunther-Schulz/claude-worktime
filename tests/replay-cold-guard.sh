#!/usr/bin/env bash
# Replay the cold-cache guard against recorded activity and score it.
#
# WHY THIS EXISTS
# The guard shipped working-but-silent: its logic was sound and a synthetic
# test would have passed, because the bug was in the *signal* it measured
# (transcript mtime), not in the branching. Claude Code appends the user
# message to the transcript before running the UserPromptSubmit hook, so the
# mtime is always fresh at hook time and the idle gap read as ~0. Seven cold
# rewrites went unwarned.
#
# So this harness does not re-implement the guard's decision — it drives the
# real `log --prompt` code path and observes what it emits. A test that
# paraphrases the logic can be green while the shipped code is wrong; that is
# the exact failure being tested for.
#
# HOW IT WORKS
# The fixture holds real recorded prompt/tokens/cold events. For each replayed
# prompt at time T, the harness shifts every fixture event that happened at or
# before T forward by (now - T), so that prompt becomes "now" and the script's
# own `date +%s` needs no override — no test seam in production code. The
# transcript file's mtime is set to now, reproducing what Claude Code actually
# leaves behind at hook time.
#
# SCORING
# Positive case: a prompt within 300s before a recorded cold rewrite — the
# guard should have warned. Negative case: every other prompt — it should stay
# silent. A miss is not automatically a defect: some cold rewrites follow no
# idle gap at all (compaction, resume) and are unreachable by an idle-based
# guard. The numbers below encode what is actually achievable, not perfection.
#
# EXPECTED TO FAIL until the guard reads its idle gap from the activity log
# instead of the transcript mtime. Red here is the finding, not a broken test.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
SCRIPT="${CW_SCRIPT:-../claude-worktime.sh}"   # override to score a candidate fix
FIXTURE="fixtures/cold-guard-log.jsonl"

# Achievable against this fixture, established by replaying the recorded log:
# 3 of the 7 cold rewrites follow an idle gap long enough and a context large
# enough to be caught. Of the remaining 4: two have no tokens entry for the
# session (a coverage gap in what gets logged), one expired after 33min
# (shorter than the assumed TTL), one had no idle gap at all.
EXPECT_CATCHES=3
EXPECT_FALSE_POSITIVES=0

command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }
[ -f "$FIXTURE" ] || { echo "missing fixture: $FIXTURE" >&2; exit 2; }
[ -f "$SCRIPT" ]  || { echo "missing script: $SCRIPT" >&2; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/cfg"        # empty config -> script defaults, ignores user config

now=$(date +%s)

# One line per recorded cold rewrite: its time, session, and every prompt in
# the 300s window before it. Scoring is per rewrite, not per prompt — a gap
# can hold several prompts, and in production the one-shot marker means only
# the first of them warns. Each replay case runs in a fresh sandbox (no marker
# carries over), so counting prompts would score the later ones as spurious.
windows=$(jq -s -r '
    (map(select(.type == "cold" and .k == "hit"))) as $colds
    | (map(select(.e == "prompt"))) as $prompts
    | $colds[]
    | . as $c
    | ($prompts | map(select(.s == $c.s and .t <= $c.t and .t >= ($c.t - 300))) | map(.t))
    | "\($c.t)\t\($c.s)\t\(join(","))"
  ' "$FIXTURE")

# Prompts inside no window at all — these must stay silent.
negatives=$(jq -s -r '
    (map(select(.type == "cold" and .k == "hit"))) as $colds
    | map(select(.e == "prompt"))
    | map(. as $p
          | select([$colds[] | select(.s == $p.s and $p.t <= .t and $p.t >= (.t - 300))]
                   | length == 0))
    | .[] | "\(.t)\t\(.s)"
  ' "$FIXTURE")

# Run one replayed prompt through the real hook. Echoes "FIRED" or "SILENT".
replay_one() {
    local at="$1" sid="$2"
    local dir="$WORK/case" delta=$(( now - at ))
    rm -rf "$dir"; mkdir -p "$dir"

    # Only what the guard could have seen: events at or before this prompt,
    # shifted so this prompt lands on "now".
    jq -c --argjson at "$at" --argjson d "$delta" '
        select(.t <= $at) | .t += $d
      ' "$FIXTURE" > "$dir/activity.jsonl"

    # Claude Code has already appended the user message, so the transcript is
    # fresh when the hook runs. Reproduce that.
    local tp="$dir/transcript.jsonl"
    printf '{}\n' > "$tp"
    touch "$tp"

    local out
    out=$(printf '{"session_id":"%s","transcript_path":"%s"}\n' "$sid" "$tp" \
        | CLAUDE_WORKTIME_DATA="$dir" CLAUDE_WORKTIME_CONFIG="$WORK/cfg" \
          bash "$SCRIPT" log --prompt 2>/dev/null)

    case "$out" in
        *'"decision":"block"'*) echo FIRED ;;
        *)                      echo SILENT ;;
    esac
}

stamp() { date -d "@$1" '+%m-%d %H:%M' 2>/dev/null || date -r "$1" '+%m-%d %H:%M'; }

printf '\nReplaying %s cold rewrites and %s unrelated prompts against the real hook\n\n' \
    "$(printf '%s\n' "$windows"   | grep -c .)" \
    "$(printf '%s\n' "$negatives" | grep -c .)"

catches=0 missed=0
printf 'Cold rewrites (guard should warn):\n'
while IFS=$'\t' read -r cold_at sid prompt_list; do
    [ -n "$cold_at" ] || continue
    fired=""
    IFS=, read -ra prompts <<< "$prompt_list"
    for at in "${prompts[@]}"; do
        [ -n "$at" ] || continue
        [ "$(replay_one "$at" "$sid")" = FIRED ] && { fired="$at"; break; }
    done
    if [ -n "$fired" ]; then
        printf '  %s  %s  ✓ warned\n' "$(stamp "$cold_at")" "$sid"
        catches=$((catches + 1))
    else
        why="silent"
        [ -z "$prompt_list" ] && why="no prompt in the 300s before it (tool loop or resume)"
        printf '  %s  %s  ✗ %s\n' "$(stamp "$cold_at")" "$sid" "$why"
        missed=$((missed + 1))
    fi
done <<< "$windows"

false_pos=0
while IFS=$'\t' read -r at sid; do
    [ -n "$at" ] || continue
    [ "$(replay_one "$at" "$sid")" = FIRED ] || continue
    [ "$false_pos" -eq 0 ] && printf '\nWarned with no cold rewrite following:\n'
    printf '  %s  %s  ✗ false positive\n' "$(stamp "$at")" "$sid"
    false_pos=$((false_pos + 1))
done <<< "$negatives"

printf '\n  caught %d of %d   false positives %d\n' \
    "$catches" "$((catches + missed))" "$false_pos"

rc=0
if [ "$catches" -lt "$EXPECT_CATCHES" ]; then
    printf '  ✗ expected to catch at least %d\n' "$EXPECT_CATCHES"; rc=1
fi
if [ "$false_pos" -gt "$EXPECT_FALSE_POSITIVES" ]; then
    printf '  ✗ expected at most %d false positives\n' "$EXPECT_FALSE_POSITIVES"; rc=1
fi
[ "$rc" -eq 0 ] && printf '  ✓ within expectations\n'
printf '\n'
exit "$rc"
