#!/usr/bin/env bash
# tools/lint.sh --baseline diffs a live shellcheck run against a pinned
# docs/lint-baseline-*.txt on the tuple (file path, SC code) — never line
# numbers (they move on any unrelated edit above them) or message text
# (carries variable content). This suite pins its OWN fixture repo and
# baseline rather than counting on the real repo's live finding count
# (38 as of 2026-08-14) staying put — the day someone fixes a warning this
# suite must not silently start testing less than it claims.
#
# House idiom (tests/replay-cold-corrupt-log.sh and siblings): standalone
# bash, self-sandboxed via a throwaway directory, PASS:/FAIL: lines on
# stdout, exit with the failure count.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT_SH="$HERE/../tools/lint.sh"

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "SKIP: shellcheck not installed — tools/lint.sh --baseline cannot be exercised"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0

# --- fixture repo: just enough structure for tools/lint.sh to find its
# targets (tools/*.sh glob) and its baseline (docs/lint-baseline-*.txt glob)
# under a ROOT of its own, computed from the copied script's own location.
build_fixture() {
  local repo="$1"
  mkdir -p "$repo/tools" "$repo/docs"
  cp "$LINT_SH" "$repo/tools/lint.sh"

  # Two pinned, known findings, each the ONLY finding of its code in its
  # file — chosen so the FIXED case (below) can remove one cleanly without
  # disturbing the other's tuple.
  cat > "$repo/tools/fixture-a.sh" <<'EOF'
#!/usr/bin/env bash
# SC2034: an assigned-but-unread variable.
known_unused_var=1
echo "fixture-a"
EOF
  cat > "$repo/tools/fixture-b.sh" <<'EOF'
#!/usr/bin/env bash
# SC2164: cd without a failure check.
cd /tmp
echo "fixture-b"
EOF

  # The baseline's grain is (file, SC code) only — line, column and message
  # are parsed off but never compared, so hand-writing plausible-shaped gcc
  # lines here (rather than running shellcheck to discover the real ones)
  # is a correct baseline, not a shortcut around one.
  cat > "$repo/docs/lint-baseline-2020-01-01.txt" <<'EOF'
shellcheck baseline — fixture

Generated: 2020-01-01 by tools/lint.sh --format=gcc
Commit:    0000000000000000000000000000000000000000
shellcheck: 0.11.0  (severity=warning, fixture)
lint.sh exit code: 1

Total findings: 2

---- findings (verbatim tools/lint.sh --format=gcc output) ----
tools/fixture-a.sh:3:1: warning: known_unused_var appears unused. Verify use (or export if used externally). [SC2034]
tools/fixture-b.sh:3:1: warning: Use 'cd ... || exit' or 'cd ... || return' in case cd fails. [SC2164]
EOF
}

check() {
  local desc="$1" cond="$2"
  if [ "$cond" -eq 0 ]; then
    echo "  ok: $desc"
  else
    echo "  FAIL: $desc"
    fail=$(( fail + 1 ))
  fi
}

# --- Case 1: unmodified fixture vs its own baseline — zero NEW, exit 0.
# This is the BASELINE result, established before any red plant, so the
# red case below is provably a diff from a known-clean starting point.
repo1="$TMP/case1"
build_fixture "$repo1"
out1="$(cd "$repo1" && bash tools/lint.sh --baseline 2>&1)"
rc1=$?
echo "$out1" | grep -q 'known findings (unchanged, present in both): 2'
check "clean fixture: 2 known findings counted" $?
! echo "$out1" | grep -q 'NEW findings'
check "clean fixture: no NEW findings section" $?
# A bare "[ ... ]; check ... $?" reads as SC2319 (this $? refers to a
# condition, not a command) — the arithmetic form below sidesteps it while
# staying the same check: cond is 0 (ok) exactly when rc1 is 0.
check "clean fixture: exit 0" "$(( rc1 != 0 ))"

# --- Case 2: RED — plant one new finding, must be named exactly, the two
# known ones must stay silent (not re-listed as new).
repo2="$TMP/case2"
build_fixture "$repo2"
cat > "$repo2/tools/fixture-c.sh" <<'EOF'
#!/usr/bin/env bash
# SC2128: expanding an array without an index — a code neither fixture
# above triggers and the pinned baseline does not know about.
my_arr=(a b c)
echo "$my_arr"
EOF
out2="$(cd "$repo2" && bash tools/lint.sh --baseline 2>&1)"
rc2=$?
echo "$out2" | grep -q 'NEW findings'
check "planted finding: NEW findings section present" $?
echo "$out2" | grep -qE 'fixture-c\.sh:SC2128: 1 live vs 0 baseline \(\+1\)'
check "planted finding: fixture-c.sh SC2128 named with its delta" $?
! echo "$out2" | grep -qE 'fixture-a\.sh:SC2034|fixture-b\.sh:SC2164'
check "planted finding: the 2 known tuples stay out of the NEW section" $?
echo "$out2" | grep -q 'known findings (unchanged, present in both): 2'
check "planted finding: known count still 2 (the new one is not counted as known)" $?
check "planted finding: exit non-zero" "$(( rc2 == 0 ))"

# --- Case 2b: RED, count-increase in an ALREADY-known tuple. This is the
# case a presence-only grain misses: fixture-a.sh already carries one
# SC2034, so a presence check would let a second SC2034 in the same file
# pass as "known" — exactly the failure this comparison exists to close
# (measured on the real repo: 24 distinct claude-worktime.sh SC2034
# findings collapsed to one presence-tuple, so a 25th went unreported).
repo2b="$TMP/case2b"
build_fixture "$repo2b"
cat >> "$repo2b/tools/fixture-a.sh" <<'EOF'
another_unused_var=2
EOF
out2b="$(cd "$repo2b" && bash tools/lint.sh --baseline 2>&1)"
rc2b=$?
echo "$out2b" | grep -qE 'fixture-a\.sh:SC2034: 2 live vs 1 baseline \(\+1\)'
check "count-increase: fixture-a.sh SC2034 named with its delta (2 vs 1)" $?
! echo "$out2b" | grep -q 'fixture-b.sh:SC2164'
check "count-increase: the untouched fixture-b.sh tuple stays out of the NEW section" $?
echo "$out2b" | grep -q 'known findings (unchanged, present in both): 2'
check "count-increase: known count is 2 (1 from the still-covered fixture-a finding + 1 from fixture-b)" $?
check "count-increase: exit non-zero" "$(( rc2b == 0 ))"

# --- Case 3: FIXED direction — remove a known finding, it must be
# reported as FIXED, and a FIXED-only diff must not fail the run.
repo3="$TMP/case3"
build_fixture "$repo3"
cat > "$repo3/tools/fixture-b.sh" <<'EOF'
#!/usr/bin/env bash
cd /tmp || exit 1
echo "fixture-b, fixed"
EOF
out3="$(cd "$repo3" && bash tools/lint.sh --baseline 2>&1)"
rc3=$?
echo "$out3" | grep -q 'FIXED findings'
check "fixed finding: FIXED findings section present" $?
echo "$out3" | grep -qF 'tools/fixture-b.sh:SC2164'
check "fixed finding: fixture-b.sh:SC2164 named as fixed" $?
! echo "$out3" | grep -q 'NEW findings'
check "fixed finding: no NEW findings section" $?
echo "$out3" | grep -q 'known findings (unchanged, present in both): 1'
check "fixed finding: known count dropped to 1" $?
check "fixed finding: exit 0 (FIXED alone does not fail the run)" "$(( rc3 != 0 ))"

# --- Case 4: COULD NOT VERIFY — a nonexistent baseline file must say so in
# those words and must not exit 0 as if clean.
repo4="$TMP/case4"
build_fixture "$repo4"
out4="$(cd "$repo4" && bash tools/lint.sh --baseline docs/does-not-exist.txt 2>&1)"
rc4=$?
echo "$out4" | grep -q 'COULD NOT VERIFY'
check "missing baseline: says COULD NOT VERIFY" $?
[ "$rc4" -ne 0 ]
check "missing baseline: exit non-zero, never a clean 0" $?

if [ "$fail" -eq 0 ]; then
  echo "PASS: tools/lint.sh --baseline diffs new/fixed/unchanged correctly, and refuses to read a missing baseline as clean"
fi
exit "$fail"
