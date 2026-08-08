# Brief — a test runner and a shellcheck lint for this repo

Dispatched 2026-08-08. Working copy: `/home/g/dev/Gunther-Schulz/claude-worktime`.
Base check (two reads, both required, run them FIRST):
`git merge-base --is-ancestor a48d190 HEAD` and `git log --oneline a48d190..HEAD`
— expected: base contained, nothing on top. Any other state halts as a gap.
Never rebase. Scratch: your OWN scratchpad.

## Grounding basis — read before building; the report cites what was read

- the executor skill (`dispatch-guards:executor`) — **load FIRST**.
- `tests/replay-cold-corrupt-log.sh` and `tests/rotation-corrupt-log.sh` — the
  house test idiom: standalone bash, `XDG_DATA_HOME` sandbox, `PASS:`/`FAIL:`
  lines on stdout, **exit code = failure count** (0 = pass).
- `README.md` — where a contributor would look for "how do I run the tests";
  that is the pointer you must not leave dangling.

## Background (established; verify it yourself)

Eight test scripts live in `tests/`, each independently runnable, and there is
**no runner** — no Makefile, no justfile, no `tests/run*`, no CI workflow. There
is also **no lint**: no `.shellcheckrc`, no `.github/workflows`, and shellcheck
is not installed on this machine. So "run the tests" today means knowing to
loop over `tests/*.sh` by hand, and nothing checks the 3000-line
`claude-worktime.sh` beyond `bash -n`.

Measured caution for the runner: `tests/replay-cold-detect.sh` is 418 lines and
several suites drive the real script repeatedly — the full set is not instant.
Report the wall time your runner takes; do not add parallelism to hide it.

## The settled design — implement exactly this, do not redesign

**(1) `tools/run-tests.sh`** — runs every `tests/*.sh`, one line per suite
(`PASS`/`FAIL` + name), a final `N passed, M failed` summary, and **exits
non-zero if any suite failed**. That exit code is the whole point: it is what a
hook or CI would key on. Requirements:
  - discovers suites by glob, so a new test file is picked up with no edit here
    (a hardcoded list is exactly the drift this repo's own docs warn about);
  - runs each suite in its own process; one suite's failure never aborts the run;
  - `--quiet` prints only failures and the summary;
  - captures each failing suite's output and prints it under that suite's name.

**(2) `tools/lint.sh`** — runs `shellcheck` over `claude-worktime.sh`,
`config.sh`, `install.sh`, `uninstall.sh`, `tools/*.sh` and `tests/*.sh`.
  - shellcheck is NOT installed here. The script must detect that and exit **0**
    with a clear "shellcheck not installed — skipping (install: …)" message,
    never a hard failure and never a silent pass. This is the could-not-verify
    answer; make it say so in those words.
  - Severity: start at `--severity=warning`. Do NOT chase style nits.
  - `.shellcheckrc` at repo root carries any `disable=` codes you need, and
    **each disabled code gets a one-line comment saying why**. An undocumented
    blanket disable is not acceptable.

**(3) Report the lint findings; do NOT fix them.** `claude-worktime.sh` is
3000 lines of working shell and its `_do_rotate`/`calc_active` regions are under
concurrent work by another dispatch — editing it here would collide. Your write
set is new files plus README. Put the shellcheck output in a DATA file at
`docs/lint-baseline-2026-08-08.txt` and summarise counts by severity and by
SC code in your report.

**(4) README** — a short "Running the tests" section pointing at both scripts.
Match the README's existing voice; do not restructure it.

## Verification (real output pasted in the report)

1. `tools/run-tests.sh` — full run, all 8 suites, wall time stated.
2. **Prove the exit code bites**: temporarily point one suite at a broken
   fixture (or add a throwaway always-failing suite), show the runner reports it
   AND exits non-zero, then remove the injection and show `git status` clean.
   A runner that always exits 0 is the defect this item exists to prevent —
   demonstrate it cannot.
3. `tools/lint.sh` on this machine (shellcheck absent): show the skip path
   exiting 0 with its message.
4. `bash -n` on every file you add.

## Write boundaries

Own: `tools/run-tests.sh`, `tools/lint.sh`, `.shellcheckrc`,
`docs/lint-baseline-2026-08-08.txt`, and the README section. **Do not touch**
`claude-worktime.sh`, anything under `tests/`, `BACKLOG.md`, or
`docs/directives/`. Targeted `git add`, never `-A`. Commit unpushed. Never
amend — always a new commit. Trailer exactly:
`Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`

## STOP signals

A suite that fails on a clean checkout before you change anything (report it,
do not fix it); shellcheck findings that look like real bugs rather than style
(report them as findings, still do not fix); any need to edit
`claude-worktime.sh`.
