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

1. **Our weighted token calculation perfectly tracks billing cost.** Ratio of cost/weighted = 5.0 ($5/MTok), constant across all sample points. Our API price weights are correct: cache_read ×0.10, cache_creation ×1.25, input ×1.00, output ×5.00.

2. **Billing cost ≠ rate limit metering.** On subscription plans (Pro/Max), cost is informational. The rate limit percentage uses a different internal formula.

3. **Budget estimate drifts upward consistently.** As context grows (cache_read increases per request), each percentage point "costs" more in billing dollars. Observed: cost_per_pct goes from $1.26 at 62% (avg cr=723K) to $1.29 at 64% (avg cr=741K).

4. **Integer percentage causes ±0.5% rounding.** At low percentages this is significant, at high percentages negligible. This is noise on top of the structural drift.

5. **Budget recomputes only on percentage ticks.** Between ticks, the display is stable. The drift is only visible across ticks.

### Current logging

Each token entry logs: `t`, `s`, `cr`, `cc`, `ui`, `out`, `pct`, `cst`, `ctx`

This gives us paired (cost, percentage, context_size) data at every statusline refresh.

## Hypothesis

Anthropic's rate limit metering weights cache_read tokens lower than billing does (or doesn't count them at all). As context grows, cache_read dominates our cost but not Anthropic's percentage — making our cost/percentage ratio increase.

If we find the correct weight for cache_read in rate limit terms, we can adjust our weighted sum to match Anthropic's metering and get a stable budget.

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

1. `claude-worktime --tokens-usage` (if implemented) or query the log:
   ```bash
   jq -Rc 'fromjson? // empty' ~/.local/share/claude-worktime/activity.jsonl | \
     jq -sr '[.[] | select(.type == "tokens" and .pct != null)] | group_by(.pct) | .[] | {pct: .[0].pct, entries: length, avg_cr: ((map(.cr)|add)/length|round), cost_per_pct: ((last.cst - .[0].cst) / .[0].pct | . * 100 | round / 100)}'
   ```

2. Check if multiple windows have data: look at distinct `resets_at` values in entries

3. Compare cost_per_pct at similar context sizes across different windows

## Current status

- Logging in place (pct, cst, ctx fields added 2026-03-30)
- Three ticks collected in current window (62%, 63%, 64%)
- Drift confirmed at ~0.8% per tick, correlating with context growth
- Need fresh window data to complete analysis
