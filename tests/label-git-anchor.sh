#!/usr/bin/env bash
# PROJECT_GIT_ANCHOR must reach a linked WORKTREE, not just a subdirectory.
#
# WHY THIS EXISTS
# The option's own comment says it anchors "{project} to the git repo root so
# subdirs/worktrees show the repo". It did that for subdirectories and never for
# worktrees, because it asked `git rev-parse --show-toplevel`, which is
# WORKTREE-SCOPED: inside a linked worktree it returns that worktree's own root
# — the very thing the anchor exists to escape. The question that reaches the
# shared repo is `--git-common-dir`.
#
# The defect was invisible for as long as nobody used worktrees. It surfaced on
# 2026-08-07, when three agent lanes ran in parallel and the operator watched
# their statusline switch to `worktrees/agent-<id>` with its own running total:
# every lane silently booked its time under a separate "project" that ceases to
# exist when the worktree is removed. Per-project totals are a measurement
# surface, so this was quiet data loss rather than a cosmetic slip.
#
# WHAT IS PINNED, and the controls matter as much as the case:
#   1. a path inside a linked worktree labels as the REPO      (was broken)
#   2. a plain subdirectory labels as the REPO                 (must not regress)
#   3. the repo root labels as the REPO                        (must not regress)
#   4. a NON-git path falls back to the short path             (must not regress)
#   5. with the anchor OFF, every one of them is unchanged     (the option still gates)
#
# Control 5 is the one that keeps this honest: without it, a "fix" that anchored
# unconditionally would pass 1-4 and silently ignore the operator's setting.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

SCRIPT="claude-worktime.sh"
TMP=$(mktemp -d) || exit 1
cleanup() {
    [ -n "${WT:-}" ] && git -C "$REPO" worktree remove --force "$WT" 2>/dev/null
    [ -n "${REPO:-}" ] && rm -rf "$REPO"
    rm -rf "$TMP"
}
trap cleanup EXIT

fails=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then
        printf '  ok   %-52s -> %s\n' "$1" "$3"
    else
        printf '  FAIL %-52s -> %s (expected %s)\n' "$1" "$3" "$2"
        fails=$((fails + 1))
    fi
}

# A throwaway repo with a linked worktree. Never point this at a real
# repository: it creates and removes worktrees.
# The label renders the last TWO path segments (parent/name), so the fixture
# fixes the PARENT name too — an expectation guessed from the basename alone
# fails for a reason that has nothing to do with the anchor.
mkdir -p "$TMP/wsp"
REPO="$TMP/wsp/demo-project"
mkdir -p "$REPO/sub/deeper"
git -C "$REPO" init -q
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
WT="$TMP/wsp/linked-worktree"
git -C "$REPO" worktree add -q "$WT" -b probe 2>/dev/null
# `sub/deeper` is untracked in the fixture repo, so it does not exist in the
# linked worktree: git -C on a missing directory fails and the anchor never
# runs. Create it, or the case silently tests nothing.
mkdir -p "$WT/sub"

# The functions under test, extracted verbatim from the shipped script rather
# than restated here — a copied implementation would test itself.
LBL="$TMP/label.sh"
awk '/^_short_project_v\(\)/,/^}/' "$SCRIPT" >  "$LBL"
awk '/^_project_label_v\(\)/,/^}/'  "$SCRIPT" >> "$LBL"
grep -q '_project_label_v' "$LBL" || { echo "could not extract the label functions"; exit 1; }
# shellcheck source=/dev/null
source "$LBL"

HOME_ORG=""
PROJECT_GIT_ANCHOR=true
echo "PROJECT_GIT_ANCHOR=true"
_project_label_v "$WT";               check "a linked worktree"      "wsp/demo-project" "$_V"
_project_label_v "$WT/sub";           check "inside a worktree"      "wsp/demo-project" "$_V"
_project_label_v "$REPO/sub/deeper";  check "a plain subdirectory"   "wsp/demo-project" "$_V"
_project_label_v "$REPO";             check "the repo root"          "wsp/demo-project" "$_V"
_project_label_v "$TMP/wsp";          check "a non-git path"         "$(basename "$TMP")/wsp" "$_V"

# The option must still gate: anchoring unconditionally would pass everything
# above while ignoring the operator's configuration.
PROJECT_GIT_ANCHOR=false
echo "PROJECT_GIT_ANCHOR=false — the anchor must not fire"
_project_label_v "$WT";              check "a linked worktree, unanchored" "wsp/linked-worktree" "$_V"
_project_label_v "$REPO/sub/deeper"; check "a subdirectory, unanchored"    "sub/deeper"      "$_V"

if [ "$fails" -eq 0 ]; then
    echo "label-git-anchor: all checks passed"
    exit 0
fi
echo "label-git-anchor: $fails check(s) failed"
exit 1
