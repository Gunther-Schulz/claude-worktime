#!/usr/bin/env bash
# The cold guard vs /compact: a warning built from a pre-compact tokens entry.
#
# WHY THIS EXISTS
# Observed 2026-08-05: a session resumed after 7h idle, the user ran /compact,
# and the first prompt after it was blocked with "idle 7h01m with ~422k
# context — cheapest moment to /compact or /clear is now". The real
# post-compact context was ~57k (7× smaller), and the advice had been taken
# sixty seconds earlier. Mechanism: the guard reads context size and idle gap
# from the last "tokens" entry, and compaction writes no tokens entry — so
# the guard described a context that no longer existed. The compact boundary
# lives only in the transcript; the guard must consult it before warning.
#
# CASES (each drives the real `log --prompt` path, same as replay-cold-guard):
#   A  stale tokens entry + compact boundary NEWER than it  -> SILENT
#      (the observed false fire; red against the pre-fix guard)
#   B  same tokens entry, no compact boundary               -> FIRED
#      (proves this rig can produce the warn — a dead rig passes A vacuously)
#   C  compact boundary OLDER than the tokens entry         -> FIRED
#      (an earlier compact must not suppress warnings forever)
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
SCRIPT="${CW_SCRIPT:-../claude-worktime.sh}"   # override to score a candidate fix

command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }
[ -f "$SCRIPT" ] || { echo "missing script: $SCRIPT" >&2; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/cfg"
echo "CACHE_GUARD_TTL=3600" > "$WORK/cfg/config.sh"

SID="test-compact-guard-0000"

# One case: a tokens entry aged $1 seconds (the 2026-08-05 shape: 422k
# context), optionally a transcript compact_boundary aged $2 seconds
# ("" = none). Echoes FIRED or SILENT.
run_case() {
    local tok_age="$1" bnd_age="$2"
    local dir="$WORK/case" now; now=$(date +%s)
    rm -rf "$dir"; mkdir -p "$dir"

    printf '{"type":"tokens","t":%d,"s":"%s","cr":400000,"cc":22000,"ui":293,"out":100,"pct":50,"cst":1,"ctx":422293,"ci":1,"co":1,"w":0}\n' \
        "$(( now - tok_age ))" "$SID" > "$dir/activity.jsonl"

    local tp="$dir/transcript.jsonl"
    printf '{}\n' > "$tp"
    if [ -n "$bnd_age" ]; then
        printf '{"type":"system","subtype":"compact_boundary","timestamp":"%s","compactMetadata":{"trigger":"manual"}}\n' \
            "$(date -u -d "@$(( now - bnd_age ))" '+%Y-%m-%dT%H:%M:%S.000Z' 2>/dev/null \
               || date -u -r "$(( now - bnd_age ))" '+%Y-%m-%dT%H:%M:%S.000Z')" >> "$tp"
    fi

    local out
    out=$(printf '{"session_id":"%s","transcript_path":"%s"}\n' "$SID" "$tp" \
        | COLD_NOTIFY=false CLAUDE_WORKTIME_DATA="$dir" CLAUDE_WORKTIME_CONFIG="$WORK/cfg" \
          bash "$SCRIPT" log --prompt 2>/dev/null)

    case "$out" in
        *'"decision":"block"'*) echo FIRED ;;
        *)                      echo SILENT ;;
    esac
}

rc=0
check() {  # label, want, got
    if [ "$3" = "$2" ]; then printf '  ✓ %s: %s\n' "$1" "$3"
    else printf '  ✗ %s: got %s, want %s\n' "$1" "$3" "$2"; rc=1; fi
}

printf '\nCold guard vs compact boundary (tokens entry 7h stale, ctx 422k):\n'
check "A compact 60s ago, after the tokens entry — stale ctx" SILENT "$(run_case 25282 60)"
check "B no compact boundary — genuine cold rewrite ahead"    FIRED  "$(run_case 25282 "")"
check "C compact 8h ago, before the tokens entry"             FIRED  "$(run_case 25282 28800)"

[ "$rc" -eq 0 ] && printf '  ✓ all cases\n'
printf '\n'
exit "$rc"
