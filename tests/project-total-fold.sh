#!/usr/bin/env bash
# {project_total} must count the time the clock actually ran in this project —
# not every second the session spent elsewhere between two of its own events.
#
# WHY THIS EXISTS
# Until 2026-08-08 the statusline computed a project total by walking a per-
# project SLICE (`$all | map(select(.p == $proj)) | calc_active`). Two events
# adjacent IN THE SLICE are not adjacent in time: the interval between them is
# every second the session spent in OTHER repos. is_idle suppresses a gap only
# when its predecessor is `response` or `start`, and `tool_start`/`tool_end`/
# `prompt` can never be idle by construction — so a session that moves away
# mid-tool billed its entire absence to the project it had left. On the
# operator's log this read `total 2204h44m` for dotfiles, 97.9% of it a single
# 90-day gap (session 00e18b84, last dotfiles event 2026-04-28 14:08:49, next
# one 2026-07-27 13:40:52) during which that session demonstrably worked on
# three other repos. It did not crash; the two events were simply adjacent in
# the slice.
#
# The SECOND defect, independent and in the opposite direction: `.p` is logged
# as the raw cwd while {project} is displayed through PROJECT_GIT_ANCHOR, so
# the label said "dotfiles" over a total that matched one exact path and
# treated every subdirectory and every agent worktree of the same repo as a
# separate project.
#
# WHAT IS PINNED
# One number discriminates both defects, which is why the fixture is shaped the
# way it is. The session logs 8 one-minute gaps that belong to the repo (some at
# the root, some in a subdirectory, some inside a linked worktree) and spends
# two hours in another project in between, leaving mid-tool and returning:
#
#   what shipped                            ->    1m   (measured, not predicted)
#   full stream, no folding                 ->    5m   subdir/worktree time lost
#   full stream + folding (the rule)        ->    8m
#
# So `8m` can only be produced by BOTH halves of the fix, and the 5m row is
# asserted below rather than asserted here — with PROJECT_GIT_ANCHOR off, which
# doubles as the control proving the option still gates.
#
# The 1m is worth a sentence, because it is not the shape one predicts. The
# shipped code took the project from the SESSION's last logged event and never
# consulted the cwd at all, so every render in this fixture reports the last
# path the session touched. The 90-day inflation on the real log came from the
# same slice rule meeting a session that did return to the project later.
#
# THE RULE, for the next reader: walk the full sorted stream and credit a gap to
# the project of its EARLIER endpoint — the project the clock was running in
# when the gap opened. A gap straddling a project switch goes to the
# predecessor (operator decision 2026-08-08; dropping such gaps was rejected as
# under-counting a session that interleaves repos, splitting them as inventing
# a boundary the log does not record).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${CW_SCRIPT:-$HERE/../claude-worktime.sh}"
TMP="$(mktemp -d)" || exit 1
cleanup() {
  [ -n "${WT:-}" ] && git -C "$REPO" worktree remove --force "$WT" 2>/dev/null
  [ -n "${WT_OUT:-}" ] && git -C "$REPO" worktree remove --force "$WT_OUT" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

# Sandbox BOTH XDG roots and drop the direct overrides, or a real config.sh —
# or CLAUDE_WORKTIME_DATA in the environment — points this at the operator's
# live log.
unset CLAUDE_WORKTIME_DATA CLAUDE_WORKTIME_CONFIG
export XDG_DATA_HOME="$TMP/data" XDG_CONFIG_HOME="$TMP/config"
LOGDIR="$XDG_DATA_HOME/claude-worktime"
CFGDIR="$XDG_CONFIG_HOME/claude-worktime"
mkdir -p "$LOGDIR" "$CFGDIR"
LOG="$LOGDIR/activity.jsonl"

cat > "$CFGDIR/config.sh" <<'EOF'
PAUSE_THRESHOLD=900
PROJECT_GIT_ANCHOR=true
HOME_ORG=""
AUTO_ROTATE=false
STATUSLINE_1="PROJECT TOTAL"
STATUSLINE_2=""
STATUSLINE_3=""
EOF

fails=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then
    printf '  ok   %-46s -> %s\n' "$1" "$3"
  else
    printf '  FAIL %-46s -> %s (expected %s)\n' "$1" "$3" "$2"
    fails=$((fails + 1))
  fi
}

# A throwaway repo with a linked worktree. Never point this at a real
# repository: it creates and removes worktrees.
mkdir -p "$TMP/wsp"
REPO="$TMP/wsp/demo-project"
mkdir -p "$REPO/sub"
git -C "$REPO" init -q
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
# Agent lanes live UNDER the repo root — `<repo>/.claude/worktrees/agent-<id>`
# is where the harness puts them, and it is the layout the folding rule is
# written for (see OUT-OF-TREE below for the boundary).
WT="$REPO/.claude/worktrees/agent-probe"
git -C "$REPO" worktree add -q "$WT" -b probe 2>/dev/null
# `sub` is untracked in the fixture, so it does not exist inside the linked
# worktree: git -C on a missing directory fails and the anchor never runs, so
# the case would silently test the non-git fallback instead.
mkdir -p "$WT/sub"
# A worktree OUTSIDE the repo root. Its label anchors to the repo, but folding
# is a path-containment test, so its time does NOT merge — see the assertion
# near the end, which pins this as the known boundary of the rule.
WT_OUT="$TMP/wsp/detached-worktree"
git -C "$REPO" worktree add -q "$WT_OUT" -b probe-out 2>/dev/null
OTHER="$TMP/wsp/other-project"
mkdir -p "$OTHER"

# Everything lands YESTERDAY, so the "today" groups stay empty and only the
# all-time total is under test. A gap to `now` is never counted — calc walks
# logged events only — so the numbers do not move with the clock.
T=$(( $(date -d "today 00:00" +%s) - 86400 + 3600 ))
ev() { printf '{"t":%d,"p":"%s","b":"main","s":"s1","e":"%s"}\n' "$1" "$2" "$3" >> "$LOG"; }
build_log() {
: > "$LOG"
ev $(( T +    0 )) "$REPO"   start        # +60 user   -> repo
ev $(( T +   60 )) "$REPO"   prompt       # +60 claude -> repo
ev $(( T +  120 )) "$REPO"   tool_start   # +60 claude -> repo   (leaves mid-tool)
ev $(( T +  180 )) "$OTHER"  prompt       # +7020      -> other
ev $(( T + 7200 )) "$OTHER"  tool_end     # +60        -> other
ev $(( T + 7260 )) "$REPO"   prompt       # +60 claude -> repo
ev $(( T + 7320 )) "$REPO"   response     # +60 user   -> repo
ev $(( T + 7380 )) "$REPO/sub" prompt     # +60 claude -> repo   (folds)
ev $(( T + 7440 )) "$REPO/sub" response   # +60 user   -> repo   (folds)
ev $(( T + 7500 )) "$WT"     prompt       # +60 claude -> repo   (folds)
ev $(( T + 7560 )) "$WT"     response     # last event, no gap after it
}
build_log

# Guard the guard: a sandbox that did not take makes every assertion below
# meaningless, and an empty log would let "0m" read as a pass.
if [ ! -s "$LOG" ]; then
  echo "FAIL: sandbox log missing or empty — refusing to interpret the rest"; exit 1
fi

render() { # cwd -> rendered statusline, ANSI stripped
  # The trailing newline is load-bearing: _read_hook_stdin gates on `read`
  # succeeding, and read returns false at EOF on an unterminated line — the
  # hook JSON would parse to nothing and the statusline would silently fall
  # back to $(pwd), i.e. to whatever directory the suite happens to run from.
  printf '{"session_id":"s1","cwd":"%s"}\n' "$1" \
    | "$SCRIPT" --statusline 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g'
}

out="$(render "$REPO")"
echo "  rendered: $out"

total="$(printf '%s' "$out" | sed -n 's/.*total \([0-9hm]*\).*/\1/p')"
label="$(printf '%s' "$out" | sed -n 's/^\([^ ]*\) .*/\1/p')"

check "total counts only this project's own gaps" "8m" "$total"
check "label is the anchored root the total used" "wsp/demo-project" "$label"

# The same number must come out from inside the subdirectory and from inside
# the worktree: all three cwds resolve to one aggregation key. Without the
# anchor half of the fix these render three different projects with three
# different totals — which is what the operator saw when agent lanes ran.
check "from a subdirectory"      "8m" "$(render "$REPO/sub" | sed -n 's/.*total \([0-9hm]*\).*/\1/p')"
check "from inside the worktree" "8m" "$(render "$WT"       | sed -n 's/.*total \([0-9hm]*\).*/\1/p')"

# The time is not lost, only re-attributed: the other project keeps the two
# hours the repo used to claim.
check "the absence is billed to the project that owned it" "1h58m" \
  "$(render "$OTHER" | sed -n 's/.*total \([0-9hm]*\).*/\1/p')"

# A summary record carrying no .p must not take the display down with it. The
# folding predicate calls startswith(), which raises on null, and a raised
# error inside the statusline query blanks the whole line — the one thing the
# mode promises never to do. Rotation writes .p on every summary today, so this
# is the guard for the day it does not.
printf '{"type":"summary","active":600,"claude":300,"user":300,"period":"x"}\n' >> "$LOG"
check "a summary without .p does not blank the statusline" "8m" \
  "$(render "$REPO" | sed -n 's/.*total \([0-9hm]*\).*/\1/p')"
build_log

# The option must still gate. With PROJECT_GIT_ANCHOR off the key is the raw
# cwd and folding is off with it, so the subdirectory and worktree minutes drop
# out and only the five root gaps remain. Without this control a "fix" that
# folded unconditionally would pass everything above while quietly ignoring the
# operator's setting — the same control that keeps label-git-anchor.sh honest.
sed -i 's/^PROJECT_GIT_ANCHOR=true$/PROJECT_GIT_ANCHOR=false/' "$CFGDIR/config.sh"
check "with the anchor OFF, nothing folds" "5m" \
  "$(render "$REPO" | sed -n 's/.*total \([0-9hm]*\).*/\1/p')"
sed -i 's/^PROJECT_GIT_ANCHOR=false$/PROJECT_GIT_ANCHOR=true/' "$CFGDIR/config.sh"

# OUT-OF-TREE WORKTREE — the known boundary, pinned so it cannot change
# silently. Folding asks whether a logged path lies UNDER the anchored root,
# which is a string question and therefore answerable for paths that no longer
# exist (a removed agent lane still merges). The price is that a worktree
# placed outside the repo root anchors its LABEL to the repo while its time
# stays in its own bucket. Nothing in the operator's layout hits this — agent
# lanes are created under <repo>/.claude/worktrees — but the day one is placed
# elsewhere, this assertion is the thing that says so out loud. If read-time
# git resolution ever replaces containment, this expectation changes to 8m
# deliberately, not by accident.
: > "$LOG"
ev $(( T +   0 )) "$WT_OUT" prompt
ev $(( T +  60 )) "$WT_OUT" response
out_lbl="$(render "$WT_OUT")"
check "an out-of-tree worktree labels as the repo" "wsp/demo-project" \
  "$(printf '%s' "$out_lbl" | sed -n 's/^\([^ ]*\) .*/\1/p')"
check "...but its time does NOT fold in (known boundary)" "0m" \
  "$(printf '%s' "$out_lbl" | sed -n 's/.*total \([0-9hm]*\).*/\1/p')"

# _project_root_v carries a second copy of _project_label_v's git resolution
# (see the comment at its definition: label-git-anchor.sh extracts the label
# function verbatim and sources it alone, so it cannot delegate). Two copies
# drift silently; this pins them against each other on the same cases.
LBL="$TMP/fns.sh"
awk '/^_short_project_v\(\)/,/^}/' "$SCRIPT" >  "$LBL"
awk '/^_project_label_v\(\)/,/^}/'  "$SCRIPT" >> "$LBL"
awk '/^_project_root_v\(\)/,/^}/'   "$SCRIPT" >> "$LBL"
if ! grep -q '_project_root_v' "$LBL"; then
  echo "FAIL: could not extract the path functions from $SCRIPT"; exit $(( fails + 1 ))
fi
# shellcheck source=/dev/null
source "$LBL"
HOME_ORG=""
PROJECT_GIT_ANCHOR=true
for p in "$WT" "$WT/sub" "$REPO/sub" "$REPO" "$TMP/wsp"; do
  _project_label_v "$p"; want="$_V"
  _project_root_v  "$p"; _short_project_v "$_V"; got="$_V"
  check "key and label agree for ${p#"$TMP/"}" "$want" "$got"
done

if [ "$fails" -eq 0 ]; then
  echo "PASS: project totals walk the full stream and fold to the anchored root"
fi
exit "$fails"
