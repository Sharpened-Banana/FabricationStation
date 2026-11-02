# Task 5 report: Math.Optimizer

Status: DONE_WITH_CONCERNS (two deliberate departures from the brief's pseudo-code, explained below; all brief tests pass verbatim)
Commit: 4b36ca1 feat: add Math.Optimizer cheapest reagent allocation per quality (BASE 5fbd1e9)

## What I built

`Math/Optimizer.lua` (pure Lua 5.1, CraftSim attribution header `Modules/ReagentOptimization/ReagentOptimization.lua`), listed in the TOC after `Math\Stats.lua`.

- `Optimizer.Compositions(slot) -> { [units] = { cost, counts = {[rank] = n} } }`
  - Enumerates every rank mix whose counts sum to exactly `slot.quantity` (2 ranks: q+1 mixes; 3 ranks: O(q²); general k ranks by recursion), keeps the cheapest per unit count.
  - `units = Σ 2·RankFactor(rank, #items)·n` (2-rank {0,2}, 3-rank {0,1,2}); cost `Σ max(0, n − owned − provided) × price`, through `Math.Round`.
  - Item with nil (non-number) price usable only up to `owned + provided`.
  - Weight 0 or single-item slot: one composition (its cheapest) at 0 units.
  - Provided reagents are a per-rank lower bound; when they cover the quantity they fix the slot (taken top rank down, never more than the quantity).
  - Returns `{}` when nothing is usable.
- `Optimizer.CheapestByQuality(input) -> perQuality, missingPrice`
  - Weights ÷ GCD (GCD 0 → 1; a non-integer weight → divisor 1). `Umax = Σ quantity·2·(w/g)` over **all** weight>0 slots, single-item ones included, so the denominator matches `Quality.ReagentSkill`.
  - Knapsack over all slots as in the brief (unweighted/fixed slots have one composition at 0 units, so they ride along with their cost). Keys iterated in sorted order → deterministic allocations.
  - `maxReagentSkill` nil → `DEFAULT_REAGENT_SKILL_FACTOR × baseDifficulty`; thresholds from `Quality.Thresholds(maxQuality, baseDifficulty, thresholdFractions)`; nil thresholds (unsupported maxQuality) → `{}` → quality 1 only (same as `Quality.Predict`).
  - `skill = baseSkill + maxReagentSkill·u/Umax` (unrounded, like `Quality.ReagentSkill`; Umax 0 → baseSkill, no divide-by-zero).
  - `perQuality[q] = { allocation, reagentCost, skill, missingPrice = true|nil }`; allocation rows in slot order then rank order, zero counts omitted, fixed slots included.
- `Optimizer.AllocationCost(slots, allocation) -> copper|nil` — cost of what the allocation buys beyond owned+provided (owned shared across rows of the same item); nil when it must buy an unpriced item or names an item the slot does not list; rows for slots not in `slots` ignored (as `Quality.ReagentSkill` does).

## Departures from the brief (please rule)

1. **Each plan lands exactly on its quality.** The brief's pseudo-code takes "min cost over u >= uNeed". I instead classify every reachable u by `skill >= threshold` (the exact predicate of `Quality.Predict`) and take, per quality, the cheapest u whose predicted quality is exactly q (ties → larger u). Reasons: (a) with "at least" semantics `perQuality[1]` can be an allocation that actually crafts quality 2 (e.g. when rank 2 is cheaper, or base skill ≥ threshold), which Task 6 would then price at the quality-1 output price and, worse, use as `skill_q` for the concentration plan "q → q+1" when it would really give q+2; (b) "unreachable qualities absent" then also covers quality 1 when base skill already passes the threshold; (c) no `ceil(x − 1e-9)` float boundary that could disagree with `Predict`. All 8 brief tests and Task 6's expected numbers (3000/4800 plain, concentration from skill 500 → 314) are unchanged by this. Tests: `each plan lands on its own quality, not a higher one`, `base skill past every threshold leaves only the top quality`, `reported skill matches Quality.ReagentSkill` (also asserts `Predict(plan.skill) == q`).
2. **A slot with no priced option still yields plans, flagged.** The brief only says such a slot sets `missingPrice`. Returning no plans at all would leave Recipes unable to show even predicted quality for a recipe with one unpriced (e.g. soulbound) reagent. So that slot gets one fallback composition (owned/provided first, top rank down, rest at the lowest rank — it never assumes an unpriced higher rank is free), and **every** plan then has `reagentCost = nil` and `missingPrice = true`; `missingPrice` (2nd return) is true. Since the fallback slot is in every plan, unknown-cost plans never compete with priced ones inside one input. A slot that has *some* priced option keeps the brief's behaviour: compositions needing the unpriced rank are excluded (brief test `missing_rank_price`: q2 absent, missing false). Priced plans carry no `missingPrice` field. **Task 6 must handle `reagentCost == nil`** (profit nil, never beats priced plans — Task 6's rules already say "Plans with nil profit never beat priced plans").

## Carried review items

- ReagentSkill over-allocation: every composition sums to exactly `slot.quantity` (provided-fixed slots capped at the quantity). Tests: `every plan allocates exactly each slot's quantity` (incl. unweighted, single-item weighted and 3-rank slots), `every composition sums to the slot quantity, never more`, plus the fallback test checks `{10, 5}`.
- Concentration nil vs 0: the brief's Optimizer interface reports no concentration cost, so the Optimizer does not call `Concentration.Cost`; nothing to return nil for here. Task 6 still has to check `curve == nil` itself for `concentrationCostForAllocation`.
- Unknown prices never beat priced plans and are flagged: see departure 2; tests `missing_rank_price`, `a slot with no priced option yields flagged plans with unknown cost`, `priced plans carry no missingPrice flag`, `an unpriced rank is usable up to what is owned`, `AllocationCost` nil cases.

## Notes for Task 6

- Thresholds come from `input.baseDifficulty` and the default `maxReagentSkill` too. When optionals add difficulty/skill, pass a shallow copy with `baseDifficulty = total difficulty`, `baseSkill = baseSkill + skillBonus` and `maxReagentSkill` already resolved from the original base difficulty (the plan's rule).
- `skill` is unrounded (Task 9 pins reagent-skill rounding).

## Tests

`tests/math/optimizer_spec.lua`: the brief's 8 tests verbatim + 17 more (exact-quantity allocations, composition sums, skill == baseSkill + ReagentSkill and Predict == q, exact-band plans, base skill past threshold, tie → more skill, owned free in plans, unpriced usable up to owned, provided fixes counts (full and partial), unpriced-slot fallback flagged, no flag on priced plans, single-item weighted slot in denominator, default maxReagentSkill + thresholdFractions, no weighted slots / no slots / maxReagentSkill 0, unsupported maxQuality, AllocationCost cases, AllocationCost == plan reagentCost).

TDD:
- RED: `busted tests/math/optimizer_spec.lua` → `0 successes / 0 failures / 1 error` — `failed to load Math/Optimizer.lua: cannot open Math/Optimizer.lua: No such file or directory`.
- First GREEN run: `24 successes / 1 failure` — my own extra test expected skill 780 for the default-maxReagentSkill case; the cheapest quality-2 plan is 8 of rank 2 (skill 724), so the test expectation was wrong, not the code; fixed to `assert.near(724, …)`. (Also corrected three of my extra tests' hand-computed numbers before the first run.)
- GREEN: `busted tests/math/optimizer_spec.lua` → `25 successes / 0 failures / 0 errors`.
- Full: `busted` → `538 successes / 0 failures / 0 errors / 0 pending`; `luacheck .` → `0 warnings / 0 errors in 62 files`; purity grep on `Math/Optimizer.lua` only matches the "no ns.FS" header comment (as in the other Math files).
- Perf sanity (scratch, not committed): 5 slots incl. 3-rank quantities 30/20/15 and a 2-rank 40, maxQuality 5 → 17 ms in plain Lua 5.1.

## Files changed

- `Math/Optimizer.lua` (new)
- `tests/math/optimizer_spec.lua` (new)
- `FabricationStation.toc` (+ `Math\Optimizer.lua` after `Math\Stats.lua`)

## Self-review

- No WoW globals, no `ns.FS`; uses only `Math.Round`, `Quality.RankFactor/Thresholds/DEFAULT_REAGENT_SKILL_FACTOR`.
- Deterministic: DP iterates sorted keys; equal-cost ties per u keep the first composition in sorted unit order.
- Slots with more than 3 ranks give fractional unit values (2·(r−1)/(n−1)); they work as table keys but have no test (Midnight is 2-rank, Dragonflight 3-rank).
- Allocation building calls `rankedItems` again per slot per quality (cheap; left for clarity).
