# Cold-cause classification: replace the tail-grep with API diagnostics

Status: **IMPLEMENTED** (2026-07-26, commit `73d4dd3`, plus the hit
notification + investigation runbook that followed in `54c32dd`). All
four changes below shipped as specified: the classifier reads
`message.diagnostics.cache_miss_reason` via jq, `previous_message_not_found`
is logged as `k:"resume"` instead of `k:"hit"`, the four forensic fields
are logged per hit, and `--cold` displays the API reason type verbatim.
The Finding section below describes the PRE-change state (the tail-grep
classifier) and is kept as the historical record of why the change was
made — it does not describe current behavior. Origin: 2026-07-26 forensic
analysis of 6 same-session full rewrites (~1.78M tokens re-cached);
full analysis in that session's scratchpad
(`cachebust-forensics-report.md`) — key numbers reproduced here so this
item is self-contained.

## Finding

Every assistant turn's transcript entry carries
`message.diagnostics.cache_miss_reason` from the API itself:
`{type: messages_changed | tools_changed | model_changed |
previous_message_not_found | unavailable, cache_missed_input_tokens: N}`.

The current classifier (`claude-worktime` ~lines 1600-1660) instead
tail-greps the last 80 transcript lines for co-occurrence strings
("Another Claude session sent a message" → `other:msg`,
"stop_hook_summary" → `other:hook`). The 2026-07-26 analysis showed
those tags are noise: stop_hook co-occurrence is ~100% (fires every
turn); cross-session-message co-occurrence holds in only ~6 of 33
historical hits; and several old hits are `previous_message_not_found`
(session-resume/fork artifacts) — a DIFFERENT mechanism the ledger
currently conflates with live-session busts under one "hit" definition.

Caveat that keeps this honest: `messages_changed` fired on 464/468
non-idle turns that day (~99%) with ~70% average invalidation — the
diagnostic explains *that* a miss happened, not why THIS turn crossed
the ledger's magnitude threshold (cc ≥ 60% prior ctx AND cr ≤ 20%).
So this change improves attribution and kills false tags; it does not
by itself answer the discrimination question.

## Changes (at the `cs_lastcause="other"` branch, ~1611-1630)

1. Read the last assistant JSONL entry (jq, not string grep):
   `cause = diagnostics.cache_miss_reason.type`, log
   `cache_missed_input_tokens` alongside. Retire the tail-grep tags.
2. Split `previous_message_not_found` OUT of the hit ledger (or tag
   `k:"resume"`) — resume/fork artifacts are not live busts.
3. Log per hit: content-block types of the preceding assistant turn
   (tool_use:<name>/thinking/text); prior line's stop_reason
   (end_turn vs tool_use → true in-flight flag); byte size of the
   newest user-role entry before the busting turn; concurrent-subagent
   count (transcript mtimes straddling now). None of these correlated
   on 2026-07-26 (n=6), but logging them makes the next occurrences
   self-analyzing instead of forensic.
4. `--cold` display: show the API reason type; keep the magnitude
   threshold as the hit definition.

## Non-goal

Root-causing WHY the cache key diverges on the crossing turns —
that analysis lives with the cache-fix proxy's prefix-diff layer
(wire-level view), not here. Worktime's job is honest accounting.
