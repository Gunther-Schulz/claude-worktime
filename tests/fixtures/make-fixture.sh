#!/usr/bin/env bash
# Regenerate cold-guard-log.jsonl from a live activity log.
#
# The fixture is committed, so this script is not run by the test — it exists
# so the fixture is reproducible and its provenance is auditable rather than a
# blob someone pasted in once.
#
# What it keeps: only the fields the cold-guard replay reads — timestamps,
# session, event/entry kind, and the three token counters. What it drops:
# `p` (working directory) and `b` (git branch). Those name real projects and
# this repository is public; the replay never reads them.
#
# Session IDs are mapped to s1..sN in first-appearance order. The mapping is
# stable for a given input log, so regenerating after new activity appends
# rather than reshuffles.
#
# Usage: make-fixture.sh [logdir] > cold-guard-log.jsonl
set -euo pipefail

LOGDIR="${1:-${XDG_DATA_HOME:-$HOME/.local/share}/claude-worktime}"
[ -d "$LOGDIR" ] || { echo "no such logdir: $LOGDIR" >&2; exit 1; }

# Sessions worth keeping: those that produced a cold rewrite. Their full
# history supplies both the positive cases and the negative ones (every other
# prompt in the same session that must NOT fire).
sessions=$(cat "$LOGDIR"/activity*.jsonl 2>/dev/null \
    | jq -r 'select(type == "object" and .type == "cold" and .s) | .s' \
    | sort -u)
[ -n "$sessions" ] || { echo "no cold events found in $LOGDIR" >&2; exit 1; }

# shellcheck disable=SC2086  # deliberate word-splitting into a jq array
cat "$LOGDIR"/activity*.jsonl 2>/dev/null \
    | jq -c --argjson keep "$(printf '%s\n' $sessions | jq -R . | jq -s .)" '
        select(type == "object" and (.t | type) == "number")
        | select(.s != null and (.s | IN($keep[])))
        | select(.e == "prompt" or .type == "tokens" or .type == "cold")
        # Field order is load-bearing: the guard locates a session token entry
        # with the glob *"type":"tokens"*"s":"<sid>"*, so `type` must precede
        # `s` exactly as the live writer emits it. Reordering here silently
        # stops the fixture from matching and the replay scores a false zero.
        | {type, t, s, e, cr, cc, ui, k, ctx}
        | with_entries(select(.value != null))
      ' \
    | jq -c -s '
        sort_by(.t)
        | . as $events
        | (reduce $events[] as $e ([];
              if index($e.s) then . else . + [$e.s] end)) as $ids
        | $events
        | map(.s as $sid | .s = "s\(($ids | index($sid)) + 1)")[]
      '
