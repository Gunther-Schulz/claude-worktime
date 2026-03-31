# Token Budget Research

## Goal

Derive a stable 5h rate limit budget from available data. Currently the budget estimate drifts upward (~1% per percentage tick) as the conversation context grows.

## What we know

### Data available per statusline refresh (from Claude Code stdin JSON)

- `rate_limits.five_hour.used_percentage` — integer (0-100), rate limit usage
- `rate_limits.five_hour.resets_at` — unix timestamp, when 5h window ends
- `context_window.used_percentage` — context window fullness
- `context_window.current_usage.cache_read_input_tokens` — per-request, ≈ context size
- `context_window.current_usage.cache_creation_input_tokens` — per-request, new content cached
- `context_window.current_usage.input_tokens` — per-request, uncached input
- `context_window.current_usage.output_tokens` — per-request, Claude's output
- `cost.total_cost_usd` — cumulative per session

### Verified facts

1. **~~Our weighted token calculation perfectly tracks billing cost.~~ DISPROVED.** The original claim (ratio = 5.0, constant) was tested on a limited sample. Full-window analysis (2026-03-31) shows the ratio varies dramatically by session: 1.12x for light sessions, 2.36x for agent-heavy sessions. The discrepancy is caused by `context_window.current_usage` only reporting main conversation tokens — subagent API calls (claude-code-guide, Explore, etc.) are included in `cost.total_cost_usd` but not in per-request token counts.

2. **Billing cost ≠ rate limit metering.** On subscription plans (Pro/Max), cost is informational. The rate limit percentage uses a different internal formula.

3. **~~Budget estimate drifts upward consistently.~~ DISPROVED.** The observed drift was an artifact of using cumulative session cost (`cst`) from a resumed session that spanned multiple 5h windows. Properly computed per-window cost (session cost deltas) gives a stable budget: $34.50 ±5%, oscillating with no directional trend.

4. **Integer percentage causes ±0.5% rounding.** At low percentages this is significant, at high percentages negligible. This is noise on top of the structural drift.

5. **Budget recomputes only on percentage ticks.** Between ticks, the display is stable.

6. **Actual session cost (`cost.total_cost_usd`) is the correct metric for budget.** It includes all API calls (main conversation, subagents, tools). Per-request token sums underestimate by 1.1-2.4x depending on agent usage. The `{cost_budget}` token now uses session cost deltas instead of weighted tokens.

### Current logging

Each token entry logs: `t`, `s`, `cr`, `cc`, `ui`, `out`, `pct`, `cst`, `ctx`, `ci`, `co`, `w`

- `cr/cc/ui/out` = per-request token counts by type
- `pct` = rate limit percentage (integer, from Anthropic)
- `cst` = cumulative session cost (from Claude Code)
- `ctx` = context window usage percentage
- `ci` = cumulative uncached input tokens (session total, from `context_window.total_input_tokens`)
- `co` = cumulative output tokens (session total, from `context_window.total_output_tokens`)
- `w` = window reset timestamp (`r5h_reset`) — enables `group_by(.w)` for multi-window analysis

### Additional data in stdin JSON (not currently logged)

- `cost.total_duration_ms` — total session duration
- `cost.total_api_duration_ms` — API time only
- `cost.total_lines_added/removed` — code changes
- `context_window.context_window_size` — 1M (fixed)

## Hypotheses tested

### Hypothesis 1: cache_read weight is wrong (REJECTED)
Changing cache_read weight (0.10 → 0.05 → 0.00) produces the same drift percentage (-13%). The drift is proportional regardless of weight.

### Hypothesis 2: rate limit tracks compute tokens only (PARTIALLY REJECTED)
`ci+co` (cumulative uncached input + output from Claude Code) was tested. The ci_co_budget drifts **downward** while cost_budget drifts **upward**. Neither is stable alone.

Data from 3 ticks with ci/co:
| pct | cost_budget | ci_co_budget | ci_co delta |
|-----|------------|-------------|-------------|
| 66% | $139 | 674,815 | — |
| 67% | $141 | 666,658 | +1,283 |
| 68% | $141 | 657,924 | +727 |

Cost and compute tokens drift in **opposite directions** — suggests rate limit uses a blend.

### Hypothesis 3: rate limit is a blend of cost and compute (CURRENT)
Neither pure billing cost nor pure compute tokens track the percentage linearly. The rate limit formula likely combines both, possibly with different weights than billing uses. This cannot be fully resolved without either:
- Anthropic publishing the formula
- Enough multi-window data to reverse-engineer the blend ratio

## Data collection plan

### Phase 1: Collect across windows (current)

Just work normally. Token entries with pct/cst/ctx accumulate automatically. Need:

- **At least one fresh session in a fresh window** — gives small-to-large context range
- **Multiple windows** — confirms pattern consistency
- **Both resumed and fresh sessions** — compares high-context-start vs low-context-start

### Phase 2: Analyze

For each 5h window that has data from window start:

1. Group token entries by `pct` (each tick)
2. At each tick, compute:
   - `cost_delta` = last cst - first cst in window (per session, summed)
   - `avg_cr` = average cache_read per request up to this tick
   - `cost_per_pct` = cost_delta / pct
   - `budget` = cost_delta * 100 / pct

3. Check: does `cost_per_pct` correlate with `avg_cr`?
   - If linear: derive correction factor
   - If non-linear but consistent across windows: derive curve
   - If inconsistent across windows: drift is unpredictable, accept approximation

### Phase 3: Derive correction (if pattern found)

If `cost_per_pct = base_rate + slope * avg_cr`:

- Solve for `base_rate` and `slope` from multi-window data
- Adjusted budget = cost_delta / (pct/100 + correction_for_context)
- Or: find the cache_read weight that makes budget constant within a window

### Verification

- Compute adjusted budget at each tick within a window — should be constant (±1%)
- Compare across windows — should give same budget (if Anthropic hasn't changed limits)
- If budget changes between windows, we've detected an Anthropic limit change

## What to check in a new session

1. Check how many windows have data:
   ```bash
   jq -Rc 'fromjson? // empty' ~/.local/share/claude-worktime/activity.jsonl | \
     jq -sr '[.[] | select(.type == "tokens" and .w != null) | .w] | unique | map(strftime("%Y-%m-%d %H:%M"))'
   ```

2. Analyze per-window tick data (group by window, then by pct):
   ```bash
   jq -Rc 'fromjson? // empty' ~/.local/share/claude-worktime/activity.jsonl | \
     jq -sr '[.[] | select(.type == "tokens" and .w != null)] | group_by(.w) | .[] | {
       window: (.[0].w | strftime("%Y-%m-%d %H:%M")),
       ticks: (group_by(.pct) | map({
         pct: .[0].pct,
         avg_cr: ((map(.cr)|add)/length|round),
         ci_co: (last.ci + last.co),
         cost_delta: ((last.cst - first.cst) * 100 | round / 100)
       }))
     }'
   ```

3. Compare cost_per_pct and ci_co_per_pct at similar context sizes across windows

4. Test: does any weighted blend of cost and ci_co produce a stable budget?

## Observed data

### 2026-03-30 (single window, resumed session) — INVALIDATED

This data was computed manually using cumulative session `cst` (cost.total_cost_usd), which includes pre-window costs for resumed sessions. The $126-$141 budget range was **inflated by pre-window cost contamination** — the session started before this 5h window and its cumulative cost included work from the previous window.

| pct | avg_cr(K) | cost_budget | ci_co_budget | notes |
|-----|-----------|------------|-------------|-------|
| 62% | 723 | $126 | — | **INVALID** — includes pre-window session cost |
| 63% | 732 | $128 | — | |
| 64% | 742 | $132 | — | |
| 65% | 746 | $135 | — | |
| 66% | 753 | $139 | 674,815 | ci/co logging started |
| 67% | — | $141 | 666,658 | |
| 68% | — | $139-141 | 657,924 | |

The script's budget calculation (sum of per-request tokens from log, filtered by `t >= window_start`) does NOT have this bug. Only this manual analysis was wrong.

### 2026-03-31 (fresh window, 4 sessions, 0-50%)

First complete window with token logging from the start. Budget computed by summing per-session cost deltas across all sessions, divided by pct.

| pct | cost($) | cost_budget | cico | cico_budget | ctx% |
|-----|---------|------------|------|------------|------|
| 2 | 0.77 | $38.65 | 7,387 | 369K | 5 |
| 22 | 8.63 | $39.23 | 481K | 2.2M | 7 |
| 25 | 8.92 | $35.68 | 484K | 1.9M | 8 |
| 26 | 9.45 | $36.34 | 488K | 1.9M | 8 |
| 27 | 9.68 | $35.86 | 488K | 1.8M | 46 |
| 30 | 10.50 | $34.98 | 511K | 1.7M | 46 |
| 32 | 10.60 | $33.14 | 514K | 1.6M | 10 |
| 34 | 11.12 | $32.70 | 519K | 1.5M | 56 |
| 35 | 11.55 | $33.01 | 527K | 1.5M | 14 |
| 36 | 12.08 | $33.55 | 536K | 1.5M | 61 |
| 37 | 13.22 | $35.73 | 553K | 1.5M | 63 |
| 39 | 12.97 | $33.27 | 549K | 1.4M | 24 |
| 40 | 13.58 | $33.94 | 559K | 1.4M | 63 |
| 41 | 13.58 | $33.11 | 559K | 1.4M | 28 |
| 42 | 13.64 | $32.48 | 559K | 1.3M | 28 |
| 44 | 13.67 | $31.07 | 559K | 1.3M | 28 |
| 45 | 13.81 | $30.68 | 560K | 1.2M | 29 |
| 46 | 13.95 | $30.33 | 560K | 1.2M | 30 |
| 47 | 16.44 | $34.97 | 619K | 1.3M | 30 |
| 48 | 16.59 | $34.56 | 628K | 1.3M | 72 |
| 49 | 16.99 | $34.66 | 633K | 1.3M | 35 |
| 50 | 17.07 | $34.15 | 634K | 1.3M | 38 |

**Key findings:**

1. **Cost budget ≈ $34 ±12%** from pct=25 onwards (oscillates $30-$39, no directional drift)
2. **ci_co budget drifts DOWN 40%** (2.2M → 1.3M) — confirms ci+co is not the rate limit metric
3. **No directional drift:** first 5 ticks avg $34.82, last 5 ticks avg $34.97 — essentially identical. Mid-window dips/spikes are noise from session mixing and variable request sizes
4. **The 5h budget for Max/Opus is approximately $34** (74% of ticks within ±5%, all within ±12%)

## Conclusions

### Budget accuracy

The cost-based budget (session cost deltas × 100/pct) is a reasonable approximation:
- Oscillates within ±12% for pct ≥ 25%, no directional drift (74% of ticks within ±5%)
- Noisy at low percentages due to integer rounding (±0.5% at pct=1 is ±50% error)
- Mid-window dips/spikes are caused by session mixing and variable request sizes (agent-heavy vs light requests), not systematic error

### What the rate limit tracks

- NOT cumulative ci+co (drifts 40%)
- Correlated with billing cost but with ±12% variance
- ±12% exceeds what integer rounding can explain (at pct=50, rounding causes at most ±2%) — something else is in the formula
- The unexplained variance source has NOT been identified yet

### Open questions

- **What causes the ±12% variance in cost_budget?** Integer rounding is insufficient. Possible factors: rate limit meters agent calls differently than billing, lag between token consumption and pct update, or a fundamentally different weighting formula. This is the primary unsolved problem.
- Does the budget change across windows? (need multi-window comparison)
- Is the budget the same for Sonnet vs Opus? (need model comparison)
- Does the budget vary by subscription tier (Pro vs Max)?

## Current state (2026-03-31)

### What was done this session
- Switched `{cost_budget}` from weighted-token-derived cost to actual session cost deltas (`cost.total_cost_usd`) — fixes the 1.1-2.4x underestimate caused by missing agent/tool costs
- Budget display now shows `$used/≈$budget` (no cents on budget, ≈ prefix since it oscillates)
- Collected full fresh window data (pct 0-56%, 4 sessions, ~200 entries)

### Next steps
1. **Investigate the ±12% variance.** This is the main open problem. The cost-based budget oscillates more than integer rounding can explain. Need to analyze what differs between high-budget ticks (~$38) and low-budget ticks (~$30) — is it request type, agent usage, timing, or something else? Look at per-tick cost deltas (cost jump between consecutive ticks) vs pct jump to see if some ticks are "cheap" and others "expensive."
2. **Collect more window data.** Need at least one more full window to compare budget stability across windows.
3. **Archive bug.** The log query only reads current LOGFILE. If auto-rotation happens mid-window, early entries are lost. Low priority but should be fixed eventually.

## Implementation notes

- Budget state file: `~/.local/share/claude-worktime/.budget`
- Format: `reset_ts pct token_budget cost_budget`
- Recomputes only on percentage tick (stable between ticks)
- `{cost_budget}` uses actual session cost (`cost.total_cost_usd`) summed via per-session deltas — includes all API calls (agents, tools, etc.)
- `{token_budget}` uses weighted per-request tokens — only main conversation, underestimates by 1.1-2.4x
- Token log query from LOGFILE for current window sums
- Both are opt-in tokens (not in default statusline)
- **Known limitation:** log query only reads current LOGFILE, not archives — if auto-rotation happens mid-window, early entries are missed
