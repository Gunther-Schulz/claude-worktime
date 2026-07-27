# Token cost model — what a turn actually costs

Reference sheet (operator-facing). Established 2026-07-27 during the
cache-bust forensics session; numbers are Claude API price weights.
Subscription rate-limit weighting is not published — working
assumption (operator, 2026-07-27): it scales the same way even if
the absolute weights differ. Re-check if Anthropic publishes
sub-limit accounting.

## The four price classes (per input-token-equivalent)

| Class | Rate | When |
|---|---|---|
| Cache read | ~0.1× | prefix already cached (the normal warm turn) |
| Uncached input | 1× | content the cache has never seen |
| Cache write | 1.25× (5m TTL) / 2× (1h TTL) | (re)establishing cache over new/busted spans |
| Output | ~5× | every token the model generates |

## The core correction (the intuitive model is wrong)

Past conversation is NOT free. The API is stateless: every request
re-sends the entire session (system prompt, CLAUDE.md, all messages,
all tool results), and the cached prefix is re-billed at ~0.1× on
EVERY turn. Cache = 90% discount on re-reading history, not free
memory.

## Consequences

1. **The history tax.** Every turn pays ~0.1 × (everything that ever
   happened this session). A same-sized question+answer costs ~11×
   more at 600k context than in a fresh session, ~17× at 900k. Turn
   cost grows linearly with session age, forever, warm cache or not.
2. **What a bust costs.** Cache dies at depth D → next turn pays
   ~D × 1.25-2× (write premium) instead of ~D × 0.1×: a 10-20×
   spike on one turn. At 600k context: ~60k-equiv warm vs
   ~750k-1.2M-equiv busted. This is why mid-session cache busts
   dominate every other cost lever (measured 2026-07-27: four
   uncontrolled busts ≈ 1.06M write-tokens — more than a whole day
   of careful prose-tuning saves).
3. **A "tiny ping" isn't tiny.** Any request — however small its new
   content — pays the full prefix re-read (~0.1× × context). A
   keepalive ping at 600k ≈ 60k-equiv. Insurance economics: ~5% of
   the bust it prevents, but a pure loss if the operator doesn't
   return (why keepalive stayed unbuilt, 2026-07-27).
4. **Fresh sessions are the cost reset.** The same work in a new
   session pays a ~30k fixed floor once instead of the deep
   session's per-turn tax. Corpus session-scale rule ("past N
   hundred k, new session unless mid-run") is a COST law, not just
   context hygiene. /compact is the mid-session variant: one paid
   bust that shrinks all future turn floors.
5. **Dispatch-from-deep is doubly right.** A subagent pays its own
   small fresh floor per round; the deep main session pays its big
   floor per round. Ten tool rounds inline at 600k ≈ 600k-equiv of
   pure history tax; the same rounds in a subagent ≈ tens of k.
6. **Output is the priciest class (~5×)** — but it's small (hundreds
   to low thousands per turn); the history tax dominates in deep
   sessions. Trimming verbosity saves real but second-order money;
   avoiding busts and capping session depth saves first-order.

## Related

- `cachebust-runbook.md` (same dir) — investigating individual bust
  events; the ❄ ledger.
- claude-code-cache-fix `docs/directives/robustness-threat-matrix.md`
  — the prevention program per bust class.
