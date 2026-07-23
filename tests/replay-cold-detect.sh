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
        | CLAUDE_WORKTIME_DATA="$d" CLAUDE_WORKTIME_CONFIG="$d" bash "$SCRIPT" --statusline >/dev/null 2>&1
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
        | CLAUDE_WORKTIME_DATA="$d" CLAUDE_WORKTIME_CONFIG="$d" bash "$SCRIPT" --statusline >/dev/null 2>&1
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
if [ "$fail" -eq 0 ]; then
    printf '  \033[32mall %d cases pass\033[0m\n' "$pass"; exit 0
else
    printf '  \033[31m%d of %d failed\033[0m\n' "$fail" "$((pass+fail))"; exit 1
fi
