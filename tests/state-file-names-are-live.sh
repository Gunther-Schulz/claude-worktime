#!/usr/bin/env bash
# Every state file a TEST seeds must be one the SCRIPT actually reads.
#
# WHY THIS EXISTS
# Measured 2026-08-14: three fixtures in tests/replay-cold-detect.sh seeded
# "$d/.token_prev" — the pre-split GLOBAL name the detector stopped reading when
# it moved to .token_prev_<sid> (claude-worktime.sh:1800). All three read as
# pinned premises and pinned nothing. One was load-bearing: the zero-usage case
# asserts in its own comment that "token_prev differs from (0,0) so only the
# zero-total rule can skip it", but with the seed landing on a dead name the
# read came back (0,0), the unchanged-pair gate skipped the render anyway, and
# the case would have passed with the zero-total rule DELETED. A green check
# exercising less than it claims, byte-identical to health.
#
# A fixture seeding a name nothing reads cannot fail loudly — that is the whole
# problem, and it is why this is a guard rather than a lesson.
#
# THE DERIVATION IS FROM SOURCE, NEVER A RESTATED LIST. A hardcoded roster of
# state files beside the script it mirrors cannot age loudly: the script gains a
# state file and the roster stays green, byte-identical to health. So the
# allow-set is read out of claude-worktime.sh on every run.
#
# COMMENTS ARE STRIPPED FIRST, and that is load-bearing rather than tidy. The
# dead name ".token_prev" still appears in claude-worktime.sh — at :1788, inside
# the comment explaining why it was ABANDONED. A derivation that scanned the raw
# file would admit it to the allow-set and pass on the exact defect this guard
# exists to catch. Residual, stated rather than hidden: only whole-line comments
# are stripped, so a state path mentioned in a TRAILING inline comment would
# still widen the allow-set. That direction is a false green; if one ever
# appears, this is where it gets fixed.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
SCRIPT="${CW_SCRIPT:-claude-worktime.sh}"
[ -f "$SCRIPT" ] || { echo "missing script: $SCRIPT" >&2; exit 2; }

# Collapse a session-keyed suffix to one token so the two sides compare on a
# shared coordinate: the script writes .cold_${sid}, a test writes .cold_$SID.
norm() { sed -E 's/_(\$\{?(sid|SID)\}?)$/_<sid>/'; }

# --- the allow-set, derived from the script with whole-line comments stripped
allow=$(grep -vE '^[[:space:]]*#' "$SCRIPT" \
        | grep -oE '\$\{(LOGDIR|DATADIR)\}/\.[A-Za-z0-9_]+(_\$\{?(sid|SID)\}?)?' \
        | sed -E 's#.*/##' | norm | sort -u)

# Instrument positive: a derivation that silently returned nothing would pass
# every test file vacuously. Assert the set is populated AND contains a member
# known to be live, before any verdict rests on it.
if [ -z "$allow" ]; then
    echo "state-file guard: derived an EMPTY allow-set from $SCRIPT — the" >&2
    echo "  derivation is broken, not the tests. Refusing to report clean." >&2
    exit 2
fi
if ! printf '%s\n' "$allow" | grep -qx '\.cold_<sid>'; then
    echo "state-file guard: allow-set lacks the known-live '.cold_<sid>' —" >&2
    echo "  the derivation no longer reads this script. Refusing a verdict." >&2
    printf '  derived: %s\n' "$(printf '%s\n' "$allow" | tr '\n' ' ')" >&2
    exit 2
fi
# Negative control on the same derivation, from the same run: the abandoned
# global name must NOT be admitted. If it is, comment-stripping has stopped
# working and the guard would go green on its own founding defect.
if printf '%s\n' "$allow" | grep -qx '\.token_prev'; then
    echo "state-file guard: allow-set admits the abandoned '.token_prev'," >&2
    echo "  which lives only in a comment — comment-stripping is broken." >&2
    exit 2
fi

rc=0
seen=0
while IFS= read -r hit; do
    file=${hit%%:*}; rest=${hit#*:}
    line=${rest%%:*}; text=${rest#*:}
    name=$(printf '%s' "$text" | grep -oE '/\.[A-Za-z0-9_]+(_\$\{?(sid|SID)\}?)?' \
           | sed -E 's#^/##' | norm | head -1)
    [ -n "$name" ] || continue
    seen=$(( seen + 1 ))
    if printf '%s\n' "$allow" | grep -qx -- "$(printf '%s' "$name" | sed 's/[.[\*^$]/\\&/g')"; then
        continue
    fi
    printf '  \033[31m✗\033[0m %s:%s seeds "%s" — no such state file is read by %s\n' \
        "$file" "$line" "$name" "$SCRIPT"
    rc=1
# TWO PREDICATE CORRECTIONS BELOW, both from false fires this guard produced on
# legitimate work during its own build. Neither is a softening: each narrows the
# scan to what the guard always claimed to check, and a guard that fires on a
# non-defect trains the override reflex that kills it.
#   1. The dotname must be the LAST path segment (hence the closing quote in the
#      pattern). project-total-fold.sh:103 writes "$REPO/.claude/worktrees/
#      agent-probe" — a worktree DIRECTORY, not a seeded state file.
#   2. Whole-line comments are stripped on THIS side too, symmetrically with the
#      allow-set derivation above: a state name inside a comment is prose on
#      either side, never a seed. Without it the guard fires on its OWN WHY-block,
#      which names ".token_prev" to explain the defect it exists to catch.
# `grep -n` runs BEFORE the strip so reported line numbers stay the file's real
# ones; a trailing inline comment on a real seed line (there is one, in
# replay-cold-detect.sh) survives, because only leading-# lines are dropped.
done < <(grep -nE '"\$[A-Za-z_][A-Za-z0-9_]*/\.[A-Za-z0-9_]+(_\$\{?(sid|SID)\}?)?"' tests/*.sh 2>/dev/null \
         | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)

printf '\nstate-file names seeded by tests are read by the script:\n'
printf '  allow-set (derived from %s): %s\n' "$SCRIPT" "$(printf '%s\n' "$allow" | tr '\n' ' ')"
printf '  fixture seeds checked: %d\n' "$seen"
if [ "$seen" -eq 0 ]; then
    echo "  ✗ no fixture seeds found at all — the scan pattern is dead, not the tree." >&2
    exit 2
fi
[ "$rc" -eq 0 ] && printf '  \033[32m✓\033[0m all %d seeds resolve\n' "$seen"
printf '\n'
exit "$rc"
