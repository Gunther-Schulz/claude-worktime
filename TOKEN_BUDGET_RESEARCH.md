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

Each token entry logs: `t`, `s`, `cr`, `cc`, `ui`, `out`, `pct`, `cst`, `ctx`, `ci`, `co`

- `pct` = rate limit percentage (integer)
- `cst` = cumulative session cost (from Claude Code)
- `ctx` = context window usage percentage
- `ci` = cumulative uncached input tokens (session total, from `context_window.total_input_tokens`)
- `co` = cumulative output tokens (session total, from `context_window.total_output_tokens`)

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

1. `claude-worktime --tokens-usage` (if implemented) or query the log:
   ```bash
   jq -Rc 'fromjson? // empty' ~/.local/share/claude-worktime/activity.jsonl | \
     jq -sr '[.[] | select(.type == "tokens" and .pct != null)] | group_by(.pct) | .[] | {pct: .[0].pct, entries: length, avg_cr: ((map(.cr)|add)/length|round), cost_per_pct: ((last.cst - .[0].cst) / .[0].pct | . * 100 | round / 100)}'
   ```

2. Check if multiple windows have data: look at distinct `resets_at` values in entries

3. Compare cost_per_pct at similar context sizes across different windows

## Observed data (2026-03-30, single window, resumed session)

Full tick history (cost_budget = token-derived cost * 100 / pct):

| pct | avg_cr(K) | cost_budget | ci_co_budget | notes |
|-----|-----------|------------|-------------|-------|
| 62% | 723 | $126 | — | no ci/co logging yet |
| 63% | 732 | $128 | — | |
| 64% | 742 | $132 | — | |
| 65% | 746 | $135 | — | |
| 66% | 753 | $139 | 674,815 | ci/co logging started |
| 67% | — | $141 | 666,658 | |
| 68% | — | $139-141 | 657,924 | |

- Cost budget drifts UP ($126 → $141, ~12% over 6 ticks)
- ci_co budget drifts DOWN (675K → 658K, ~2.5% over 2 ticks)
- Drift is not monotonic — budget can dip between ticks

## Current status

- Full logging in place (pct, cst, ctx, ci, co added 2026-03-30)
- 7 ticks collected in current window (62%-68%), 3 with ci/co data
- Confirmed: neither cost nor compute tokens alone track the percentage
- Budget uses tick-based computation (only recomputes when pct changes)
- Display shows `⊘used/budget` with ~10-15% uncertainty over a full window
- Need fresh window data (ideally new session, not resumed) to see full curve from low context

## Implementation notes

- Budget state file: `~/.local/share/claude-worktime/.budget`
- Format: `reset_ts pct token_budget cost_budget`
- Recomputes only on percentage tick (stable between ticks)
- Token-derived cost used for budget (weighted * $5/MTok)
- Token log query from LOGFILE for current window sums
- `{token_budget}` and `{cost_budget}` are opt-in tokens (not in default statusline)
