#!/usr/bin/env bash
# Drive the real ❄ cold-rewrite detector and score what it flags.
#
# WHY THIS EXISTS
# The detector lives in the --statusline token-logger path and, unlike the
# guard, had no test. Its correctness turns on one distinction that is easy to
# get wrong: a session's FIRST write (nothing cached yet, whole context
# written) is mechanically identical to a cold rewrite (cache expired, whole
# context re-written). The old code told them apart with a 25k magnitude floor
# — a proxy that also hid genuine small rewrites and could not distinguish a
# fresh start from a resume-after-expiry. The current code asks the real
# question: has a prior turn been logged this session? These four cases pin
# that behaviour down.
#
# HOW IT WORKS
# No fixture: each case seeds the per-session cold-state file (.cold_<sid>) to
# stand in for "what happened before", then feeds one crafted statusline stdin
# JSON through the real script and checks whether a {"k":"hit"} was appended.
# The detector reads token usage straight from that stdin, so no transcript is
# needed and the production code runs unmodified.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
SCRIPT="${CW_SCRIPT:-../claude-worktime.sh}"   # override to score a candidate fix
command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }
[ -f "$SCRIPT" ] || { echo "missing script: $SCRIPT" >&2; exit 2; }

SID="detect-sim"
pass=0 fail=0

# Run one statusline turn; echo 1 if it logged a cold hit, else 0.
# $1 dir  $2 cr  $3 cc  $4 ui
turn() {
    local d=$1 cr=$2 cc=$3 ui=$4
    printf '{"session_id":"%s","workspace":{"current_dir":"/tmp/p"},"context_window":{"used_percentage":30,"current_usage":{"cache_read_input_tokens":%d,"cache_creation_input_tokens":%d,"input_tokens":%d,"output_tokens":10}}}\n' \
        "$SID" "$cr" "$cc" "$ui" \
        | COLD_NOTIFY=false CLAUDE_WORKTIME_DATA="$d" CLAUDE_WORKTIME_CONFIG="$d" bash "$SCRIPT" --statusline >/dev/null 2>&1
    # grep -c prints the count (0 included) and exits 1 when it's 0 — swallow
    # that exit, don't append a second 0.
    grep -c '"k":"hit"' "$d/activity.jsonl" 2>/dev/null || true
}

# Run one turn WITH a model id and echo the logged cause of the resulting hit
# (empty if no hit). $1 dir  $2 model-id  $3 cr  $4 cc  $5 ui
turn_model() {
    local d=$1 mdl=$2 cr=$3 cc=$4 ui=$5
    printf '{"session_id":"%s","model":{"id":"%s"},"workspace":{"current_dir":"/tmp/p"},"context_window":{"used_percentage":30,"current_usage":{"cache_read_input_tokens":%d,"cache_creation_input_tokens":%d,"input_tokens":%d,"output_tokens":10}}}\n' \
        "$SID" "$mdl" "$cr" "$cc" "$ui" \
        | COLD_NOTIFY=false CLAUDE_WORKTIME_DATA="$d" CLAUDE_WORKTIME_CONFIG="$d" bash "$SCRIPT" --statusline >/dev/null 2>&1
    grep '"k":"hit"' "$d/activity.jsonl" 2>/dev/null | jq -r '.cause' 2>/dev/null | tail -1
}

# $1 label  $2 expected-cause  $3 prior-state-line  $4 model  $5 cr $6 cc $7 ui
checkcause() {
    local label=$1 want=$2 state=$3 mdl=$4 cr=$5 cc=$6 ui=$7
    local d; d=$(mktemp -d)
    local now; now=$(date +%s)
    printf '{"t":%d,"p":"/tmp/p","s":"%s","e":"prompt"}\n' "$now" "$SID" > "$d/activity.jsonl"
    : > "$d/config.sh"
    [ -n "$state" ] && printf '%s\n' "$state" > "$d/.cold_$SID"
    local got; got=$(turn_model "$d" "$mdl" "$cr" "$cc" "$ui")
    if [ "$got" = "$want" ]; then
        printf '  \033[32m✓\033[0m %s\n' "$label"; pass=$(( pass + 1 ))
    else
        printf '  \033[31m✗\033[0m %s (wanted cause=%s, got %s)\n' "$label" "$want" "${got:-none}"; fail=$(( fail + 1 ))
    fi
    rm -rf "$d"
}

# Like checkcause but also drops a transcript file and passes its path on
# stdin, so the "other" residual can be subdivided by transcript co-occurrence.
# $1 label $2 want-cause $3 state $4 model $5 cr $6 cc $7 ui $8 transcript-body
checkcause_tp() {
    local label=$1 want=$2 state=$3 mdl=$4 cr=$5 cc=$6 ui=$7 tbody=$8
    local d; d=$(mktemp -d)
    local now; now=$(date +%s)
    printf '{"t":%d,"p":"/tmp/p","s":"%s","e":"prompt"}\n' "$now" "$SID" > "$d/activity.jsonl"
    : > "$d/config.sh"
    [ -n "$state" ] && printf '%s\n' "$state" > "$d/.cold_$SID"
    local tp="$d/transcript.jsonl"; printf '%s\n' "$tbody" > "$tp"
    local got
    printf '{"session_id":"%s","transcript_path":"%s","model":{"id":"%s"},"workspace":{"current_dir":"/tmp/p"},"context_window":{"used_percentage":30,"current_usage":{"cache_read_input_tokens":%d,"cache_creation_input_tokens":%d,"input_tokens":%d,"output_tokens":10}}}\n' \
        "$SID" "$tp" "$mdl" "$cr" "$cc" "$ui" \
        | COLD_NOTIFY=false CLAUDE_WORKTIME_DATA="$d" CLAUDE_WORKTIME_CONFIG="$d" bash "$SCRIPT" --statusline >/dev/null 2>&1
    got=$(grep '"k":"hit"' "$d/activity.jsonl" 2>/dev/null | jq -r '.cause' 2>/dev/null | tail -1)
    if [ "$got" = "$want" ]; then
        printf '  \033[32m✓\033[0m %s\n' "$label"; pass=$(( pass + 1 ))
    else
        printf '  \033[31m✗\033[0m %s (wanted cause=%s, got %s)\n' "$label" "$want" "${got:-none}"; fail=$(( fail + 1 ))
    fi
    rm -rf "$d"
}

# $1 label  $2 expected(0/1)  $3 prior-state-file-line(or "")  $4 cr $5 cc $6 ui
check() {
    local label=$1 want=$2 state=$3 cr=$4 cc=$5 ui=$6
    local d; d=$(mktemp -d)
    local now; now=$(date +%s)
    printf '{"t":%d,"p":"/tmp/p","s":"%s","e":"prompt"}\n' "$now" "$SID" > "$d/activity.jsonl"
    # Empty config -> the script's built-in defaults govern, so this scores the
    # shipped default COLD_MIN_CTX too (not an override). Under the old 25k
    # default, case 3's 15k rewrite stays hidden — the regression this catches.
    : > "$d/config.sh"
    [ -n "$state" ] && printf '%s\n' "$state" > "$d/.cold_$SID"
    local got; got=$(turn "$d" "$cr" "$cc" "$ui")
    if [ "$got" = "$want" ]; then
        printf '  \033[32m✓\033[0m %s\n' "$label"; pass=$(( pass + 1 ))
    else
        printf '  \033[31m✗\033[0m %s (wanted %s hit(s), got %s)\n' "$label" "$want" "$got"; fail=$(( fail + 1 ))
    fi
    rm -rf "$d"
}

NOW=$(date +%s)

echo "❄ cold-rewrite detection:"
# 1. Brand-new session, first write: cr=0, cc=whole initial context. No prior
#    state file -> no prior turn -> must NOT flag (this is the false positive
#    the magnitude floor used to guard against, now handled structurally).
check "new session, first write is not a rewrite" 0 "" 0 12000 500

# 2. Resume after the cache expired: a prior turn exists (big context), the
#    cache is gone (cr=0) and the whole prefix is re-written. MUST flag.
check "resume after cache expiry flags" 1 "3 130000 $((NOW-8000)) 128000" 0 130000 500

# 3. Genuine small rewrite: prior context only 15k, then cold. The old 25k
#    floor hid this; with the size shown it should be visible. MUST flag.
check "small real rewrite (15k) is visible" 1 "0 15000 $((NOW-4000)) 0" 1000 14000 300

# 4. /clear mid-session: prior context large, then a tiny fresh write. cc is
#    small relative to the prior context, so the cc>=0.6*prev gate rejects it.
check "/clear (tiny fresh write) does not flag" 0 "5 130000 $((NOW-30)) 120000" 0 3000 400

echo
echo "❄ cause classification (state: count ctx now lastcc lasthit_t lastcause prevmodel):"
# Prior context 130k, gap set via the 'now' field. Same-model + small gap =
# other; model changed = model; gap past 0.9×TTL = idle (idle wins over model).
checkcause "same model, short gap -> other" other \
    "3 130000 $((NOW-49)) 128000 0 - claude-fable-5"  claude-fable-5   0 130000 100
checkcause "model changed -> model" model \
    "3 130000 $((NOW-49)) 128000 0 - claude-fable-5"  claude-opus-4-8  0 130000 100
checkcause "gap past 0.9xTTL -> idle" idle \
    "3 130000 $((NOW-7200)) 128000 0 - claude-fable-5"  claude-fable-5 0 130000 100
# idle takes precedence even if the model also changed
checkcause "long gap + model change -> idle" idle \
    "3 130000 $((NOW-7200)) 128000 0 - claude-fable-5"  claude-opus-4-8 0 130000 100

echo
echo "❄ 'other' residual classified via API cache_miss_reason diagnostics:"
# Same-model, short-gap residual — the transcript's last assistant entry
# carries message.diagnostics.cache_miss_reason.type straight from the API;
# that type becomes the cause verbatim (replaces the old tail-grep tags).
checkcause_tp "messages_changed -> cause=messages_changed" messages_changed \
    "3 130000 $((NOW-49)) 128000 0 - claude-fable-5"  claude-fable-5 0 130000 100 \
    '{"type":"assistant","message":{"content":[{"type":"text"}],"stop_reason":"end_turn","diagnostics":{"cache_miss_reason":{"type":"messages_changed","cache_missed_input_tokens":128000}}}}'
checkcause_tp "tools_changed -> cause=tools_changed" tools_changed \
    "3 130000 $((NOW-49)) 128000 0 - claude-fable-5"  claude-fable-5 0 130000 100 \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}],"stop_reason":"tool_use","diagnostics":{"cache_miss_reason":{"type":"tools_changed","cache_missed_input_tokens":128000}}}}'
checkcause_tp "unavailable -> cause=unavailable" unavailable \
    "3 130000 $((NOW-49)) 128000 0 - claude-fable-5"  claude-fable-5 0 130000 100 \
    '{"type":"assistant","message":{"content":[{"type":"text"}],"stop_reason":"end_turn","diagnostics":{"cache_miss_reason":{"type":"unavailable"}}}}'
# Graceful degradation: an older-CC transcript with no diagnostics field at
# all (or no transcript entry matching) must fall back to plain "other" —
# never crash, never block the statusline.
checkcause_tp "no diagnostics field -> falls back to other" other \
    "3 130000 $((NOW-49)) 128000 0 - claude-fable-5"  claude-fable-5 0 130000 100 \
    '{"type":"assistant","message":{"content":[{"type":"text"}],"stop_reason":"end_turn"}}'

echo
echo "❄ previous_message_not_found is a COST class: labeled, displayed, never a hit:"
# A resume/fork/compact artifact is a REAL cache miss the user should see
# (feedback: this action cost this much) — but never a bust: no k:"hit",
# no bust-count advance. It books k:"cost" with an honest cause label and
# advances the ❄ display fields so the token shows e.g. "❄ 130k resume".
# The label is "compact" when a compact_boundary transcript entry explains
# it, else "resume".
resume_check() {
    local label=$1 tbody=$2 want_cause=$3
    local d; d=$(mktemp -d)
    local now; now=$(date +%s)
    printf '{"t":%d,"p":"/tmp/p","s":"%s","e":"prompt"}\n' "$now" "$SID" > "$d/activity.jsonl"
    : > "$d/config.sh"
    printf '%s\n' "3 130000 $((NOW-49)) 128000 0 - claude-fable-5" > "$d/.cold_$SID"
    local tp="$d/transcript.jsonl"
    printf '%s\n' "$tbody" > "$tp"
    printf '{"session_id":"%s","transcript_path":"%s","model":{"id":"claude-fable-5"},"workspace":{"current_dir":"/tmp/p"},"context_window":{"used_percentage":30,"current_usage":{"cache_read_input_tokens":0,"cache_creation_input_tokens":130000,"input_tokens":100,"output_tokens":10}}}\n' \
        "$SID" "$tp" \
        | COLD_NOTIFY=false CLAUDE_WORKTIME_DATA="$d" CLAUDE_WORKTIME_CONFIG="$d" bash "$SCRIPT" --statusline >/dev/null 2>&1
    local hit_count cost_cause st_count st_lastcc st_cause
    hit_count=$(grep -c '"k":"hit"' "$d/activity.jsonl" 2>/dev/null) || hit_count=0
    cost_cause=$(grep '"k":"cost"' "$d/activity.jsonl" 2>/dev/null | jq -r '.cause' | tail -1)
    read -r st_count _ _ st_lastcc _ st_cause _ < "$d/.cold_$SID" 2>/dev/null
    if [ "$hit_count" -eq 0 ] && [ "$cost_cause" = "$want_cause" ] \
        && [ "$st_count" = "3" ] && [ "$st_lastcc" = "130000" ] && [ "$st_cause" = "$want_cause" ]; then
        printf '  \033[32m✓\033[0m %s\n' "$label"; pass=$(( pass + 1 ))
    else
        printf '  \033[31m✗\033[0m %s (hit=%s cost_cause=%s state=%s/%s/%s; want 0/%s/3/130000/%s)\n' \
            "$label" "$hit_count" "${cost_cause:-none}" "$st_count" "$st_lastcc" "$st_cause" "$want_cause" "$want_cause"; fail=$(( fail + 1 ))
    fi
    rm -rf "$d"
}
resume_check "no boundary -> k:cost cause=resume, display advances, count does not" \
    '{"type":"assistant","message":{"content":[{"type":"text"}],"stop_reason":"end_turn","diagnostics":{"cache_miss_reason":{"type":"previous_message_not_found"}}}}' \
    resume
resume_check "compact_boundary present -> k:cost cause=compact" \
    "{\"type\":\"system\",\"subtype\":\"compact_boundary\",\"timestamp\":\"$(date -u -d @$((NOW-20)) +%Y-%m-%dT%H:%M:%S.100Z)\",\"compactMetadata\":{\"trigger\":\"manual\"}}
{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\"}],\"stop_reason\":\"end_turn\",\"diagnostics\":{\"cache_miss_reason\":{\"type\":\"previous_message_not_found\"}}}}" \
    compact
# CC's compactMetadata.trigger distinguishes the operator's /compact from an
# auto-compact at the context ceiling — different feedback (a command's cost
# vs "you hit the limit"), so different labels.
resume_check "trigger=auto -> k:cost cause=auto-compact" \
    "{\"type\":\"system\",\"subtype\":\"compact_boundary\",\"timestamp\":\"$(date -u -d @$((NOW-20)) +%Y-%m-%dT%H:%M:%S.100Z)\",\"compactMetadata\":{\"trigger\":\"auto\"}}
{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\"}],\"stop_reason\":\"end_turn\",\"diagnostics\":{\"cache_miss_reason\":{\"type\":\"previous_message_not_found\"}}}}" \
    auto-compact

echo
echo "❄ post-compact first write (hit predicate not met) displays as compact cost:"
# The state-preserved case: prev ctx 355k, compact to ~51k; the 51k first
# write is far under 0.6*prev so no hit fires — but it is a real 51k miss
# the user acted to cause. With a compact_boundary newer than the last real
# turn, it books k:"cost" cause=compact and shows in ❄; without the
# boundary evidence, it stays silent (nothing speculative).
compact_display_check() {
    local label=$1 with_boundary=$2 want_cost=$3 want_cause=$4
    local d; d=$(mktemp -d)
    local now; now=$(date +%s)
    printf '{"t":%d,"p":"/tmp/p","s":"%s","e":"prompt"}\n' "$now" "$SID" > "$d/activity.jsonl"
    : > "$d/config.sh"
    printf '%s\n' "0 355000 $((now-36000)) 0 0 - claude-fable-5" > "$d/.cold_$SID"
    printf '350000 5000\n' > "$d/.token_prev"
    local tp="$d/transcript.jsonl"
    if [ "$with_boundary" = "yes" ]; then
        printf '{"type":"system","subtype":"compact_boundary","timestamp":"%s","compactMetadata":{"trigger":"manual"}}\n' \
            "$(date -u -d @$((now-120)) +%Y-%m-%dT%H:%M:%S.500Z)" > "$tp"
    elif [ "$with_boundary" = "auto" ]; then
        printf '{"type":"system","subtype":"compact_boundary","timestamp":"%s","compactMetadata":{"trigger":"auto"}}\n' \
            "$(date -u -d @$((now-120)) +%Y-%m-%dT%H:%M:%S.500Z)" > "$tp"
    else
        : > "$tp"
    fi
    printf '{"session_id":"%s","transcript_path":"%s","model":{"id":"claude-fable-5"},"workspace":{"current_dir":"/tmp/p"},"context_window":{"used_percentage":10,"current_usage":{"cache_read_input_tokens":0,"cache_creation_input_tokens":51000,"input_tokens":100,"output_tokens":10}}}\n' \
        "$SID" "$tp" \
        | COLD_NOTIFY=false CLAUDE_WORKTIME_DATA="$d" CLAUDE_WORKTIME_CONFIG="$d" bash "$SCRIPT" --statusline >/dev/null 2>&1
    local hit_count cost_count cost_cause st_cause
    hit_count=$(grep -c '"k":"hit"' "$d/activity.jsonl" 2>/dev/null) || hit_count=0
    cost_count=$(grep -c '"k":"cost"' "$d/activity.jsonl" 2>/dev/null) || cost_count=0
    cost_cause=$(grep '"k":"cost"' "$d/activity.jsonl" 2>/dev/null | jq -r '.cause' | tail -1)
    read -r _ _ _ _ _ st_cause _ < "$d/.cold_$SID" 2>/dev/null
    local ok=1
    [ "$hit_count" -eq 0 ] || ok=0
    [ "$cost_count" -eq "$want_cost" ] || ok=0
    if [ "$want_cost" -gt 0 ]; then
        { [ "$cost_cause" = "$want_cause" ] && [ "$st_cause" = "$want_cause" ]; } || ok=0
    fi
    if [ "$ok" -eq 1 ]; then
        printf '  \033[32m✓\033[0m %s\n' "$label"; pass=$(( pass + 1 ))
    else
        printf '  \033[31m✗\033[0m %s (hit=%s cost=%s cause=%s state_cause=%s)\n' \
            "$label" "$hit_count" "$cost_count" "${cost_cause:-none}" "${st_cause:-none}"; fail=$(( fail + 1 ))
    fi
    rm -rf "$d"
}
compact_display_check "boundary evidence -> k:cost cause=compact" yes 1 compact
compact_display_check "auto trigger -> k:cost cause=auto-compact" auto 1 auto-compact
compact_display_check "no boundary -> silent (no speculation)" no 0 -

echo
echo "❄ render: cost classes show without the #N bust index:"
render_check() {
    local label=$1 cause=$2 want=$3 notwant=$4
    local d; d=$(mktemp -d)
    local now; now=$(date +%s)
    printf '{"t":%d,"p":"/tmp/p","s":"%s","e":"prompt"}\n' "$now" "$SID" > "$d/activity.jsonl"
    : > "$d/config.sh"
    printf '%s\n' "3 120000 $now 51000 $now $cause claude-fable-5" > "$d/.cold_$SID"
    printf '100000 200\n' > "$d/.token_prev"      # matches the turn -> logger skips
    local out
    out=$(printf '{"session_id":"%s","workspace":{"current_dir":"/tmp/p"},"context_window":{"used_percentage":30,"current_usage":{"cache_read_input_tokens":100000,"cache_creation_input_tokens":200,"input_tokens":1,"output_tokens":10}}}\n' "$SID" \
        | COLD_NOTIFY=false CLAUDE_WORKTIME_DATA="$d" CLAUDE_WORKTIME_CONFIG="$d" bash "$SCRIPT" --statusline 2>/dev/null)
    if printf '%s' "$out" | grep -qF "$want" && ! printf '%s' "$out" | grep -qF "$notwant"; then
        printf '  \033[32m✓\033[0m %s\n' "$label"; pass=$(( pass + 1 ))
    else
        printf '  \033[31m✗\033[0m %s (output: %s)\n' "$label" "$(printf '%s' "$out" | grep -o '❄[^·]*' | head -1)"; fail=$(( fail + 1 ))
    fi
    rm -rf "$d"
}
render_check "cause=compact renders '❄ 51k compact', no #3" compact "51k compact" "#3"
render_check "cause=auto-compact suppresses #3 too" auto-compact "51k auto-compact" "#3"
render_check "cause=idle keeps the '#3' bust index" idle "#3 51k idle" "NEVERMATCHES"

echo
echo "❄ zero-usage render (compact completion) must not poison state or log:"
# Measured 2026-07-31 (s-f94e53ce): a 355k session sat idle ~10h, the operator
# resumed and ran /compact first; the compact-completion statusline render
# reported cr=cc=ui=0, and its logged tokens entry (a) reset the idle clock —
# the post-compact first write measured a 32min gap, not 10h — and (b) zeroed
# the state's prev-ctx, so the compact-skip predicate (cc >= 0.6*prev) fired
# against prev=0 and booked the unavoidable 51k first write as a false hit.
# A zero-total render carries no API usage (no response bills zero tokens
# everywhere) and must be treated as "no data": nothing logged, state kept.
zero_render_check() {
    local d; d=$(mktemp -d)
    local now; now=$(date +%s)
    printf '{"t":%d,"p":"/tmp/p","s":"%s","e":"prompt"}\n' "$now" "$SID" > "$d/activity.jsonl"
    : > "$d/config.sh"
    printf '%s\n' "0 355000 $((now-36000)) 0 0 - claude-fable-5" > "$d/.cold_$SID"
    # token_prev differs from (0,0) so only the zero-total rule can skip it
    printf '350000 5000\n' > "$d/.token_prev"
    turn "$d" 0 0 0 >/dev/null                      # the compact-completion render
    local ztok; ztok=$(grep -c '"type":"tokens"' "$d/activity.jsonl" 2>/dev/null) || ztok=0
    local st_ctx st_t
    read -r _ st_ctx st_t _ < "$d/.cold_$SID" 2>/dev/null
    local hits; hits=$(turn "$d" 0 51000 100)       # post-compact first write
    if [ "$ztok" -eq 0 ] && [ "$st_ctx" = "355000" ] && [ "$hits" -eq 0 ]; then
        printf '  \033[32m✓\033[0m %s\n' "zero render logs nothing, keeps state; 51k compact write books no hit"; pass=$(( pass + 1 ))
    else
        printf '  \033[31m✗\033[0m zero render poisons (tokens=%s prev_ctx=%s hits=%s; want 0/355000/0)\n' "$ztok" "$st_ctx" "$hits"; fail=$(( fail + 1 ))
    fi
    rm -rf "$d"
}
zero_render_check

echo
echo "❄ late-bind upgrade honors the resume-split (retract, never adopt):"
# Same event, second defect: at detection the busting turn's transcript entry
# was not yet flushed -> cause "other" -> the resume-split could not fire and
# a hit was booked; the late-bind window then read the flushed entry and wrote
# previous_message_not_found straight into the display state — a cause the
# split's contract says the ❄ token never renders. The fix retracts: count
# un-inflates, ❄ state zeroes, and k:"resume" + k:"hit-retract" records land.
late_bind_check() {
    local label=$1 tentry=$2 want_count=$3 want_cause=$4 want_retract=$5 hit_gap=${6:-49}
    local d; d=$(mktemp -d)
    local now; now=$(date +%s)
    printf '{"t":%d,"p":"/tmp/p","s":"%s","e":"prompt"}\n' "$now" "$SID" > "$d/activity.jsonl"
    printf '{"type":"cold","t":%d,"s":"%s","k":"hit","gap":%d,"ctx":130000,"cc":130000,"cause":"other","mdl":"claude-fable-5","mtok":0,"pblk":[],"flight":null,"ubytes":0,"concur":0}\n' \
        "$((now-30))" "$SID" "$hit_gap" >> "$d/activity.jsonl"
    : > "$d/config.sh"
    printf '%s\n' "1 130000 $((now-30)) 130000 $((now-30)) other claude-fable-5" > "$d/.cold_$SID"
    local tp="$d/transcript.jsonl"
    printf '%s\n' "$tentry" > "$tp"
    printf '{"session_id":"%s","transcript_path":"%s","model":{"id":"claude-fable-5"},"workspace":{"current_dir":"/tmp/p"},"context_window":{"used_percentage":30,"current_usage":{"cache_read_input_tokens":130000,"cache_creation_input_tokens":500,"input_tokens":100,"output_tokens":10}}}\n' \
        "$SID" "$tp" \
        | COLD_NOTIFY=false CLAUDE_WORKTIME_DATA="$d" CLAUDE_WORKTIME_CONFIG="$d" bash "$SCRIPT" --statusline >/dev/null 2>&1
    local got_count got_lastcc got_cause got_retract
    read -r got_count _ _ got_lastcc _ got_cause _ < "$d/.cold_$SID" 2>/dev/null
    got_retract=$(grep -c '"k":"hit-retract"' "$d/activity.jsonl" 2>/dev/null) || got_retract=0
    if [ "$got_count" = "$want_count" ] && [ "$got_cause" = "$want_cause" ] && [ "$got_retract" -eq "$want_retract" ] \
        && [ "$got_lastcc" = "130000" ]; then
        printf '  \033[32m✓\033[0m %s\n' "$label"; pass=$(( pass + 1 ))
    else
        printf '  \033[31m✗\033[0m %s (count=%s lastcc=%s cause=%s retract=%s; want %s/130000/%s/%s)\n' \
            "$label" "$got_count" "$got_lastcc" "$got_cause" "$got_retract" "$want_count" "$want_cause" "$want_retract"; fail=$(( fail + 1 ))
    fi
    rm -rf "$d"
}
# Retraction un-books the hit but KEEPS the display (lastcc/lasthit_t): the
# event was a real miss the user should still see, relabeled as its cost
# class (resume — no compact_boundary in these transcripts).
late_bind_check "previous_message_not_found late -> retracted, relabeled resume" \
    '{"type":"assistant","message":{"usage":{"cache_creation_input_tokens":130000},"content":[{"type":"text"}],"stop_reason":"end_turn","diagnostics":{"cache_miss_reason":{"type":"previous_message_not_found"}}}}' \
    0 resume 1
late_bind_check "real cause late (messages_changed) still adopted" \
    '{"type":"assistant","message":{"usage":{"cache_creation_input_tokens":130000},"content":[{"type":"text"}],"stop_reason":"end_turn","diagnostics":{"cache_miss_reason":{"type":"messages_changed"}}}}' \
    1 messages_changed 0
# Retraction is destructive (state decrement) and must demand PROOF: the
# anchor also admits entries with no usage block (kept loose for cause
# adoption), but an entry that cannot prove it is the booked turn must not
# retract — and must not adopt the resume cause either (the split forbids
# displaying it). No action: cause stays "other", re-checkable in-window.
late_bind_check "usage-less resume entry -> no retract, no adopt" \
    '{"type":"assistant","message":{"content":[{"type":"text"}],"stop_reason":"end_turn","diagnostics":{"cache_miss_reason":{"type":"previous_message_not_found"}}}}' \
    1 other 0
# The compact label at retract time anchors to the booked hit's OWN idle gap
# (read from its ledger record): a boundary OUTSIDE that gap belongs to an
# earlier, unrelated compact and must not relabel a resume as compact.
NOW_LB=$(date +%s)
late_bind_check "boundary outside the hit's 49s gap -> resume, not compact" \
    "{\"type\":\"system\",\"subtype\":\"compact_boundary\",\"timestamp\":\"$(date -u -d @$((NOW_LB-3630)) +%Y-%m-%dT%H:%M:%S.100Z)\",\"compactMetadata\":{\"trigger\":\"manual\"}}
{\"type\":\"assistant\",\"message\":{\"usage\":{\"cache_creation_input_tokens\":130000},\"content\":[{\"type\":\"text\"}],\"stop_reason\":\"end_turn\",\"diagnostics\":{\"cache_miss_reason\":{\"type\":\"previous_message_not_found\"}}}}" \
    0 resume 1 49
late_bind_check "boundary inside the hit's 5000s gap -> compact" \
    "{\"type\":\"system\",\"subtype\":\"compact_boundary\",\"timestamp\":\"$(date -u -d @$((NOW_LB-3030)) +%Y-%m-%dT%H:%M:%S.100Z)\",\"compactMetadata\":{\"trigger\":\"manual\"}}
{\"type\":\"assistant\",\"message\":{\"usage\":{\"cache_creation_input_tokens\":130000},\"content\":[{\"type\":\"text\"}],\"stop_reason\":\"end_turn\",\"diagnostics\":{\"cache_miss_reason\":{\"type\":\"previous_message_not_found\"}}}}" \
    0 compact 1 5000

echo
echo "❄ --cold readers drop retracted hits:"
cold_reader_check() {
    local d; d=$(mktemp -d)
    local now; now=$(date +%s)
    {
        printf '{"type":"cold","t":%d,"s":"%s","k":"hit","gap":10,"ctx":51000,"cc":51000,"cause":"other","mdl":"m"}\n' "$((now-600))" "$SID"
        printf '{"type":"cold","t":%d,"s":"%s","k":"hit-retract","hit_t":%d,"cc":51000}\n' "$((now-500))" "$SID" "$((now-600))"
        printf '{"type":"cold","t":%d,"s":"%s","k":"hit","gap":10,"ctx":90000,"cc":90000,"cause":"idle","mdl":"m"}\n' "$((now-300))" "$SID"
        printf '{"type":"cold","t":%d,"s":"%s","k":"cost","gap":0,"ctx":45000,"cc":45000,"cause":"compact","mdl":"m"}\n' "$((now-100))" "$SID"
    } > "$d/activity.jsonl"
    : > "$d/config.sh"
    local n first_cc n_all
    n=$(CLAUDE_WORKTIME_DATA="$d" CLAUDE_WORKTIME_CONFIG="$d" bash "$SCRIPT" --cold --raw --session "$SID" 2>/dev/null | jq 'length' 2>/dev/null)
    first_cc=$(CLAUDE_WORKTIME_DATA="$d" CLAUDE_WORKTIME_CONFIG="$d" bash "$SCRIPT" --cold --raw --session "$SID" 2>/dev/null | jq '.[0].cc' 2>/dev/null)
    n_all=$(CLAUDE_WORKTIME_DATA="$d" CLAUDE_WORKTIME_CONFIG="$d" bash "$SCRIPT" --cold --raw --all --session "$SID" 2>/dev/null | jq 'length' 2>/dev/null)
    if [ "$n" = "1" ] && [ "$first_cc" = "90000" ] && [ "$n_all" = "2" ]; then
        printf '  \033[32m✓\033[0m %s\n' "--cold: busts only by default (retracted dropped); --all adds cost rows"; pass=$(( pass + 1 ))
    else
        printf '  \033[31m✗\033[0m --cold retract/all filter (rows=%s first_cc=%s all=%s; want 1/90000/2)\n' "$n" "$first_cc" "$n_all"; fail=$(( fail + 1 ))
    fi
    rm -rf "$d"
}
cold_reader_check

echo
if [ "$fail" -eq 0 ]; then
    printf '  \033[32mall %d cases pass\033[0m\n' "$pass"; exit 0
else
    printf '  \033[31m%d of %d failed\033[0m\n' "$fail" "$((pass+fail))"; exit 1
fi
