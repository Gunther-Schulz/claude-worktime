#!/usr/bin/env bash
# Test the cold-guard's clipboard rescue by driving the real `log --prompt`
# code path — same discipline as replay-cold-guard.sh: observe what the shipped
# hook emits and does, never re-implement its logic.
#
# THE STUB-CLIPBOARD TRICK
# The guard copies the blocked prompt with the first of wl-copy/pbcopy/xclip/xsel
# found on PATH. We prepend a temp dir holding a fake `wl-copy` that appends its
# stdin to $CLIP_OUT. That shadows the real tool, so the test is deterministic,
# never clobbers the developer's actual clipboard, and needs no live Wayland
# compositor (works headless / in CI). Because the guard backgrounds the copy
# (`... & ` — so a dead clipboard daemon can't hang the hook), each case waits
# briefly for the stub to flush before reading CLIP_OUT.
#
# WHY THESE CASES
# The copy path forks on two independent things: whether a prompt string exists
# (jq '.prompt // empty') and whether the copy is enabled (CACHE_GUARD_CLIPBOARD).
# The image-only case matters specifically: the UserPromptSubmit payload carries
# no image/attachment field (verified against the hooks doc), so an image paste
# arrives as an empty .prompt and must fall back to the echo wording — that is
# the documented "text only" limit, pinned here so a future change can't quietly
# start claiming to rescue something it can't.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
SCRIPT="${CW_SCRIPT:-../claude-worktime.sh}"

command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }
[ -f "$SCRIPT" ] || { echo "missing script: $SCRIPT" >&2; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Stub clipboard tool: a fake `wl-copy` that captures stdin to $CLIP_OUT.
STUBBIN="$WORK/bin"
mkdir -p "$STUBBIN"
cat > "$STUBBIN/wl-copy" <<'STUB'
#!/bin/sh
cat > "$CLIP_OUT"
STUB
chmod +x "$STUBBIN/wl-copy"

now=$(date +%s)
pass=0 fail=0
LAST_CLIP="" LAST_MSG="" LAST_STATUS=""

# Drive one prompt through the real hook. Sets LAST_STATUS (BLOCKED|SILENT),
# LAST_CLIP (what the stub clipboard captured), and LAST_MSG (the block reason).
# Must NOT be called in a $(...) subshell — the parent needs those vars.
# The activity log is seeded with a stale tokens entry (2h old, ~220k context)
# so the guard's idle+context thresholds are met and it blocks — the precondition
# for any clipboard behaviour. A fresh DATA dir per call means no one-shot marker
# carries over between cases.
run_guard() {
    local prompt="$1" clipboard_cfg="$2"   # clipboard_cfg: "" (default) or "false"
    local dir="$WORK/case.$RANDOM"; mkdir -p "$dir/cfg" "$dir/data"

    { echo "CACHE_GUARD_TTL=3600"
      [ -n "$clipboard_cfg" ] && echo "CACHE_GUARD_CLIPBOARD=$clipboard_cfg"
    } > "$dir/cfg/config.sh"

    local old=$(( now - 7200 ))
    printf '{"type":"tokens","t":%d,"s":"sid","cr":100000,"cc":80000,"ui":40000}\n' \
        "$old" > "$dir/data/activity.jsonl"

    CLIP_OUT="$dir/clip.txt"; : > "$CLIP_OUT"
    local tp="$dir/transcript.jsonl"; printf '{}\n' > "$tp"; touch "$tp"

    local stdin out
    stdin=$(jq -cn --arg p "$prompt" \
        '{session_id:"sid",transcript_path:"'"$tp"'",prompt:$p}')
    out=$(printf '%s\n' "$stdin" \
        | CLIP_OUT="$CLIP_OUT" PATH="$STUBBIN:$PATH" \
          CLAUDE_WORKTIME_DATA="$dir/data" CLAUDE_WORKTIME_CONFIG="$dir/cfg" \
          bash "$SCRIPT" log --prompt 2>/dev/null)

    # Wait for the backgrounded copy to flush (bounded — never hang the test).
    local i=0
    while [ ! -s "$CLIP_OUT" ] && [ "$i" -lt 20 ]; do sleep 0.05; i=$((i + 1)); done

    LAST_CLIP=$(cat "$CLIP_OUT" 2>/dev/null)
    LAST_MSG=$(printf '%s' "$out" | jq -r '.reason // empty' 2>/dev/null)
    case "$out" in *'"decision":"block"'*) LAST_STATUS=BLOCKED ;; *) LAST_STATUS=SILENT ;; esac
}

check() {  # check <label> <condition-desc> <0-or-1>
    if [ "$3" -eq 1 ]; then printf '  ✓ %s\n' "$1"; pass=$((pass + 1))
    else printf '  ✗ %s\n' "$1"; fail=$((fail + 1)); fi
}

printf '\nCold-guard clipboard rescue (real hook path, stub clipboard)\n\n'

# 1. Default on: text prompt is copied verbatim, message announces the clipboard.
printf 'Text prompt, clipboard default (on):\n'
P='factorial helper please'
run_guard "$P" ""; [ "$LAST_STATUS" = BLOCKED ] && b=1 || b=0
check "guard blocks"                       "" "$b"
check "clipboard holds the exact prompt"   "" "$([ "$LAST_CLIP" = "$P" ] && echo 1 || echo 0)"
check 'message says "prompt text is on the clipboard"' "" \
      "$(case "$LAST_MSG" in *'prompt text is on the clipboard'*) echo 1;; *) echo 0;; esac)"

# 2. Multiline + quotes + backslash survive the jq extraction and the pipe.
printf '\nMultiline prompt with quotes/backslash:\n'
P=$'line one\nwith "quotes" and a backslash \\ too\nline three'
run_guard "$P" ""
check "clipboard round-trips multiline/special chars exactly" "" \
      "$([ "$LAST_CLIP" = "$P" ] && echo 1 || echo 0)"

# 3. Opt-out: CACHE_GUARD_CLIPBOARD=false still blocks, copies nothing, and
#    falls back to the echo wording. (This same fallback branch is what a
#    missing clipboard tool hits, so it doubles as no-tool coverage.)
printf '\nClipboard disabled (CACHE_GUARD_CLIPBOARD=false):\n'
run_guard "some prompt" "false"; [ "$LAST_STATUS" = BLOCKED ] && b=1 || b=0
check "guard still blocks"                 "" "$b"
check "clipboard left untouched (empty)"   "" "$([ -z "$LAST_CLIP" ] && echo 1 || echo 0)"
check 'message falls back to "submit the prompt again"' "" \
      "$(case "$LAST_MSG" in *'submit the prompt again'*) echo 1;; *) echo 0;; esac)"

# 4. Image-only paste (empty .prompt): blocks, but there is nothing to copy, so
#    it falls back — the documented text-only limit.
printf '\nImage-only paste (empty prompt string):\n'
run_guard "" ""; [ "$LAST_STATUS" = BLOCKED ] && b=1 || b=0
check "guard still blocks"                 "" "$b"
check "nothing copied (no text to rescue)" "" "$([ -z "$LAST_CLIP" ] && echo 1 || echo 0)"
check 'message falls back to "submit the prompt again"' "" \
      "$(case "$LAST_MSG" in *'submit the prompt again'*) echo 1;; *) echo 0;; esac)"

printf '\n  %d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
