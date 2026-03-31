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

2. **~~Billing cost ≠ rate limit metering.~~ DISPROVED.** `cost.total_cost_usd` IS API-equivalent pricing — confirmed by exact 1:1 match between per-request token cost (at standard API rates) and cst_delta for non-agent requests. The rate limit tracks the same API cost. Least-squares optimal budget: $37.81 with ±4% mean error.

3. **~~Budget estimate drifts upward consistently.~~ DISPROVED.** The original drift observation was an artifact of cross-window session cost contamination. The apparent "drift" at high pct was caused by (a) using $34 as the central estimate instead of the correct ~$38, and (b) agent cost timing delays creating lumpy cost/pct reporting. At the correct $38 estimate, the data oscillates ±10% with no directional trend.

4. **Integer percentage causes ±0.5% rounding.** At low percentages this is significant, at high percentages negligible. This is minor compared to agent timing noise (±10%).

5. **Budget recomputes only on percentage ticks.** Between ticks, the display is stable.

6. **Actual session cost (`cost.total_cost_usd`) is API-equivalent pricing and the correct metric for budget.** It includes all API calls (main conversation, subagents, tools) at standard API rates. Per-request token sums underestimate by 1.8-3.5x depending on agent usage. The `{cost_budget}` token uses session cost deltas with EMA smoothing.

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

### 2026-03-31 (fresh window, 5 sessions, 0-65%)

First complete window with token logging from the start. Budget computed by summing per-session cost deltas across all sessions (carrying forward each session's latest cost at or before each pct tick), divided by pct. 288 token entries total.

| pct | cost($) | cost_budget | cico | cico_budget | ctx% |
|-----|---------|------------|------|------------|------|
| 2 | 0.38 | $19.00 | 5,236 | 262K | 5 |
| 22 | 8.63 | $39.23 | 479K | 2.2M | 7 |
| 25 | 8.92 | $35.68 | 482K | 1.9M | 8 |
| 26 | 9.45 | $36.35 | 485K | 1.9M | 8 |
| 27 | 9.68 | $35.85 | 486K | 1.8M | 46 |
| 30 | 10.40 | $34.67 | 507K | 1.7M | 46 |
| 31 | 10.40 | $33.55 | — | — | 8 |
| 32 | 10.60 | $33.13 | — | — | 10 |
| 34 | 10.99 | $32.32 | 516K | 1.5M | 56 |
| 35 | 11.34 | $32.40 | 524K | 1.5M | 14 |
| 36 | 11.92 | $33.11 | 533K | 1.5M | 61 |
| 37 | 12.40 | $33.51 | 542K | 1.5M | 63 |
| 39 | 12.97 | $33.26 | — | — | 24 |
| 40 | 13.37 | $33.42 | 556K | 1.4M | 63 |
| 41 | 13.44 | $32.78 | 553K | 1.3M | 28 |
| 42 | 13.51 | $32.17 | — | — | 28 |
| 44 | 13.54 | $30.77 | — | — | 28 |
| 45 | 13.68 | $30.40 | — | — | 29 |
| 46 | 13.82 | $30.04 | — | — | 30 |
| 47 | 13.85 | $29.47 | — | — | 30 |
| 48 | 16.59 | $34.56 | 593K | 1.2M | 72 |
| 49 | 16.99 | $34.67 | 631K | 1.3M | 73 |
| 50 | 17.29 | $34.58 | — | — | 40 |
| 51 | 17.38 | $34.08 | 597K | 1.2M | 74 |
| 52 | 18.19 | $34.98 | 648K | 1.2M | 47 |
| 53 | 18.40 | $34.72 | 651K | 1.2M | 47 |
| 54 | 18.85 | $34.91 | 658K | 1.2M | 49 |
| 55 | 19.38 | $35.24 | 664K | 1.2M | 81 |
| 56 | 19.96 | $35.64 | 670K | 1.2M | 82 |
| 57 | 20.25 | $35.53 | — | — | 56 |
| 58 | 20.67 | $35.64 | — | — | 58 |
| 59 | 21.24 | $36.00 | — | — | 61 |
| 60 | 22.53 | $37.55 | 687K | 1.1M | 64 |
| 61 | 23.51 | $38.54 | — | — | 67 |
| 62 | 24.22 | $39.06 | — | — | 70 |
| 63 | 25.28 | $40.13 | — | — | 73 |
| 64 | 26.83 | $41.92 | — | — | 80 |
| 65 | 27.10 | $41.69 | — | — | 12 |

**Key findings:**

1. **`cost.total_cost_usd` IS API-equivalent pricing.** Confirmed by exact 1:1 match between per-request token cost (at API rates) and cst_delta for non-agent requests. Agent calls explain the remainder (1.8-3.5x multiplier per session).
2. **The rate limit IS based on API cost.** Least-squares optimal budget: **$37.81**. At this value, mean absolute gap is ±4%, max gap 10%.
3. **ci_co budget drifts DOWN 45%** (2.2M → 1.1M) — confirms ci+co is not the rate limit metric
4. **Apparent "drift" was from wrong central estimate.** Earlier analysis used $34 (biased low by mid-window session overlap lag). At the correct $38 estimate, the data oscillates ±10% with no directional trend.
5. **Per-tick variance is caused by agent cost timing.** Agent costs arrive in lumps (e.g., $2.74 at pct=48 in 3 seconds). This creates artificial cheap/expensive ticks that average out but make individual ticks noisy.

### Least-squares fit quality

| Budget | Mean gap | Max gap | RMS gap |
|--------|---------|---------|---------|
| $34 | 5.9% | 15% | 7.9% |
| $36 | 4.4% | 11% | 5.4% |
| **$38** | **4.0%** | **11%** | **4.6%** |
| $40 | 4.7% | 12% | 5.6% |

## Conclusions

### Budget accuracy

The cost-based budget (session cost deltas × 100/pct) converges to ~$38 (least-squares optimal: $37.81):
- Mean absolute error: ±4% (±$1.50)
- Max error: 11% (worst single tick)
- Noisy at low percentages due to integer rounding (±0.5% at pct=1 is ±50% error)
- EMA smoothing (α=0.3) in the display reduces tick-to-tick jumps

### What the rate limit tracks

- **API-equivalent cost** — the same pricing as `cost.total_cost_usd`
- NOT cumulative ci+co (drifts down 45% across the window)
- The 5h budget for Max/Opus is **≈$38** (least-squares optimal from 316 entries, pct 0-81%)
- Per-tick variance (±10%) is from agent cost timing delays, not formula differences
- The leaky bucket / decay hypothesis was tested and **rejected** — constant drain model cannot fit the data (produces negative drain rates)

### What causes the per-tick variance

Agent calls (subagents, tools) advance `pct` server-side in real-time but their cost only appears in `cost.total_cost_usd` at the next statusline refresh. This creates:
- **Cheap ticks:** pct advancing from agent work, but cost hasn't caught up yet (e.g., pct 41-47: $0.01-$0.14/tick)
- **Expensive ticks:** cost arrives in a lump (e.g., pct 48: $2.74/tick in 3 seconds)
- **Net effect:** oscillates around $38, no directional drift

Session overlap amplifies this: when two sessions run concurrently, one session's agent work advances shared pct while its cost reporting lags, creating larger dips and spikes.

### Open questions

- Does the budget change across windows? (need multi-window comparison to confirm $38)
- Is the budget the same for Sonnet vs Opus? (need model comparison)
- Does the budget vary by subscription tier (Pro vs Max)?

## Current state (2026-03-31, updated with pct 0-81% data)

### What was done
- Switched `{cost_budget}` from weighted-token-derived cost to actual session cost deltas (`cost.total_cost_usd`) — fixes the 1.1-2.4x underestimate caused by missing agent/tool costs
- Budget display now shows `$used/≈$budget` (≈ prefix since it's smoothed and approximate)
- **Confirmed `cost.total_cost_usd` is API-equivalent pricing** — exact match on non-agent requests
- **Derived optimal budget via least-squares: $37.81** — mean error ±4%, max 11%
- **Added EMA smoothing (α=0.3)** to budget display — reduces tick-to-tick jumps from agent timing noise
- **Rejected leaky bucket hypothesis** — constant drain model produces negative rates, doesn't fit
- Collected full fresh window data (pct 0-81%, 5 sessions, 316 entries)

### Next steps
1. **Collect more window data.** Need at least one more full window to confirm $38 budget and verify the pattern repeats.
2. **Archive bug.** The log query only reads current LOGFILE. If auto-rotation happens mid-window, early entries are lost. Low priority but should be fixed eventually.

## Implementation notes

- Budget state file: `~/.local/share/claude-worktime/.budget`
- Format: `reset_ts pct token_budget cost_budget`
- Recomputes only on percentage tick (stable between ticks)
- `{cost_budget}` uses actual session cost (`cost.total_cost_usd`) summed via per-session deltas — includes all API calls (agents, tools, etc.)
- Budget smoothed via EMA (α=0.3): `new = 0.3 × current_tick + 0.7 × previous`. Reduces agent timing noise while tracking changes.
- `{token_budget}` uses weighted per-request tokens — only main conversation, underestimates by 1.8-3.5x
- Token log query from LOGFILE for current window sums
- Both are opt-in tokens (not in default statusline)
- **Known limitation:** log query only reads current LOGFILE, not archives — if auto-rotation happens mid-window, early entries are missed
