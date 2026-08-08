#!/usr/bin/env bash
# Per-session token_prev: a foreign session's write must never let a
# duplicate render of the SAME call re-enter cold-rewrite classification.
#
# WHY THIS EXISTS
# BACKLOG.md "per-session token_prev" — the false ❄ measured 2026-08-07
# 01:00:55Z. CC renders the statusline several times per API call; the
# (cr,cc) dedupe guard that filters duplicate renders lived at a single
# GLOBAL ${LOGDIR}/.token_prev, shared by every session. A foreign session's
# render sitting between two renders of the same call overwrote that global
# file with ITS OWN (cr,cc), so the second render of the ORIGINAL call read
# back someone else's last-seen pair, found it "changed", and re-entered
# cold-rewrite classification — compared against its own prior turn's
# context, which is exactly the shape that produced a 336k false hit.
#
# HOW IT WORKS
# Reproduces the measured shapes from BACKLOG.md's F2/root-cause writeup for
# session A (cr=0/cc=39711 first write, then cr=39711/cc=335933 for a real
# turn that itself is not a hit) via the real --statusline path, interleaves
# a foreign session B's render with DIFFERENT (cr,cc), then replays session
# A's :455 render — an EXACT duplicate of its own :440 (cr=39711/cc=335933,
# the "same API call rendered twice" case named in BACKLOG.md — CC does this
# when a response streams and completes across the same call).
#
# RED-FIRST
# Run with CW_SCRIPT pointing at the pre-fix script: the duplicate must
# produce one ~336k hit (the false ❄). Run with the default (fixed) script:
# it must produce none. Both are asserted below against the same fixture.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
SCRIPT="${CW_SCRIPT:-../claude-worktime.sh}"   # override to score a candidate (or the OLD baseline)
command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }
[ -f "$SCRIPT" ] || { echo "missing script: $SCRIPT" >&2; exit 2; }

SID_A="sesA"
SID_B="sesB"

# One statusline turn for the given session, sharing $d across calls so
# token_prev / .cold_<sid> state persists between them, as it does in
# production across renders of one live process.
turn() {
    local d=$1 sid=$2 cr=$3 cc=$4 ui=$5
    printf '{"session_id":"%s","workspace":{"current_dir":"/tmp/p"},"context_window":{"used_percentage":30,"current_usage":{"cache_read_input_tokens":%d,"cache_creation_input_tokens":%d,"input_tokens":%d,"output_tokens":10}}}\n' \
        "$sid" "$cr" "$cc" "$ui" \
        | COLD_NOTIFY=false CLAUDE_WORKTIME_DATA="$d" CLAUDE_WORKTIME_CONFIG="$d" bash "$SCRIPT" --statusline >/dev/null 2>&1
}

run_sequence() {
    local d; d=$(mktemp -d)
    local now; now=$(date +%s)
    # A pre-existing "prompt" activity row establishes the log/session the
    # statusline read expects — matching the house idiom in
    # replay-cold-detect.sh's check() helper.
    printf '{"t":%d,"p":"/tmp/p","s":"%s","e":"prompt"}\n' "$now" "$SID_A" > "$d/activity.jsonl"
    : > "$d/config.sh"

    # :427 — session A's first write. cs_prev_t is 0 before this (no prior
    # turn), so it never hit-checks; it only establishes cs_prev=39713 for
    # the next comparison, matching BACKLOG.md's F2 arithmetic exactly.
    turn "$d" "$SID_A" 0 39711 2

    # :440 — session A's real next turn: cache fully read back (cr=39711
    # matches the prior cc) with a large write on top (cc=335933). Against
    # cs_prev=39713 the predicate does NOT fire (cr 39711 > 39713/5): this
    # is the healthy, non-hit render BACKLOG.md's arithmetic is built on.
    turn "$d" "$SID_A" 39711 335933 0

    # A foreign session's render sits in between, exactly as F2 requires —
    # own (cr,cc), nothing to do with session A.
    turn "$d" "$SID_B" 1000 2000 5

    # :455 — a SECOND RENDER OF THE SAME CALL as :440: identical (cr,cc).
    # This is the duplicate the token_prev gate exists to filter.
    turn "$d" "$SID_A" 39711 335933 0

    local hit_count hit_cc
    hit_count=$(grep -c '"k":"hit"' "$d/activity.jsonl" 2>/dev/null) || hit_count=0
    hit_cc=$(grep '"k":"hit"' "$d/activity.jsonl" 2>/dev/null | jq -r '.cc' | tail -1)
    rm -rf "$d"
    printf '%s %s\n' "$hit_count" "${hit_cc:-none}"
}

echo "per-session token_prev: duplicate render of one call, foreign session interleaved"
read -r hits cc <<< "$(run_sequence)"
printf '  hits=%s cc=%s   (script: %s)\n' "$hits" "$cc" "$SCRIPT"

if [ "${CW_EXPECT_RED:-0}" = 1 ]; then
    # Scoring the OLD implementation: the duplicate must slip through as a
    # false hit at the SAME cc as the real (non-hit) :440 render — ~336k.
    if [ "$hits" = "1" ] && [ "$cc" = "335933" ]; then
        printf '  \033[32m✓\033[0m red confirmed: OLD code books the duplicate as a 335933 hit\n'
        exit 0
    else
        printf '  \033[31m✗\033[0m expected red (1 hit, cc=335933) against the OLD script; got hits=%s cc=%s\n' "$hits" "$cc"
        exit 1
    fi
fi

if [ "$hits" = "0" ]; then
    printf '  \033[32m✓\033[0m fixed: the duplicate render produced no event\n'
    exit 0
else
    printf '  \033[31m✗\033[0m the duplicate render still booked %s hit(s) (cc=%s)\n' "$hits" "$cc"
    exit 1
fi
