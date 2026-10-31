# Task 6 report: Math.Profit (EvaluateCraft, EvaluateAllocation) + Optimizer weight rounding

Status: DONE

## Commits
- `1de62f4` fix: round optimizer slot weights to integers before the GCD (controller extra item, separate commit)
- `987ed47` feat: add Math.Profit expected profit and concentration evaluation

## What I built

### Math/Optimizer.lua (extra item)
Positive slot weights are rounded half-up to integers, with a floor of 1 (`math.max(1, Math.Round(w))`), before the GCD and the unit scaling. The floor stops a weight like 0.3 from turning a weighted slot unweighted. Weight 0 or missing stays 0. GameData weights are integers, so this is a guard. Header comment updated.

### Math/Profit.lua (new; in the TOC after Math\Optimizer.lua)
- `Profit.AH_CUT = 0.95`.
- `Profit.ExpectedSale(qualityChances, outputPrices, expectedYield)` = Round(Σ chance_q·price_q · yield · AH_CUT). Returns nil when a quality with a positive chance has no price. A zero-chance quality needs no price.
- `prepare` (shared by both entry points):
  - Calls `Stats.ApplyOptionals` to get `skill = baseSkill + skillBonus` and `difficulty = baseDifficulty + difficultyBonus`.
  - `maxReagentSkill` defaults to 0.40 × the ORIGINAL baseDifficulty.
  - `optionalCost` is nil when any applied optional has no price.
  - `less` = input.concentration.lessFactors plus the optionals' reduceconcentrationcost factors.
  - `baseYield = (min+max)/2`, and `expectedYield = Stats.ExpectedYield(baseYield, multicraft, multicraftExtra)`.
- Plans:
  - Plain plans come from `Optimizer.CheapestByQuality`. It gets a copy of the input with total difficulty, adjusted baseSkill and the resolved maxReagentSkill, per the Task 5 ruling.
  - For each plan q < maxQuality there is a concentration plan for q+1, using plan q's reagents at `Concentration.Cost(curve, skill_q, difficulty, less)`.
  - Per plan:
    - reagentCost = required + optional cost.
    - resourcefulness saving = `ResourcefulnessSaving(requiredCost, …)`.
    - expectedSale = `ExpectedSale({[q]=1}, …)`.
    - profit = Round(sale − (reagentCost − saving)).
    - multicraftValue = Round(price_q·(yield − baseYield)·AH_CUT).
  - A nil requiredCost (Optimizer `missingPrice`) gives nil reagentCost, profit and resourcefulnessValue.
- Choosing a plan:
  - Comparator: a priced plan beats an unpriced one, then higher profit wins, then higher quality, then a plan that spends no concentration.
  - targetQuality with useConcentration: the concentration plan for that quality, or the plain plan for it when none exists (target 1, or the top quality already reached by skill).
  - targetQuality without useConcentration: the plain plan for that quality.
  - targetQuality that no plan reaches: the best plan at the highest reachable quality, with `flags.unreachableTarget = true`. Concentration plans count only when useConcentration is set.
  - No target: the best concentration plan when useConcentration (the best plain plan if nothing can be concentrated), otherwise the best plain plan.
- Concentration fields:
  - They describe the chosen plan when it is a concentration plan, otherwise the best concentration plan.
  - `goldPerConcentration = GoldPerPoint(concPlan.profit, bestPlain.profit, Expected(cost, ingenuity, 0.5 + ingenuityExtra))`. It is called only when both profits are non-nil (the GoldPerPoint throw is guarded).
  - `ingenuityValue = cost × ingenuity × (0.5 + extra)`.
  - Without a curve (`curve == nil`), all of these are nil, as ruled.
  - With a curve but no concentration plan, they are 0 (goldPerConcentration nil).
- `concentrationCostForAllocation` is nil without a curve, 0 when the allocation's skill already predicts maxQuality, and otherwise `Concentration.Cost(curve, skill, difficulty, less)`.
- `missingPrice` (and `flags.noPrice`, always a boolean) is true when any of these holds:
  - a required slot has no priced option
  - an optional has no price
  - a quality reachable without concentration has no output price
  - the chosen plan's own output price or reagent cost is nil
- MathResult fields:
  - expectedQuality, qualityChances, skill, difficulty, thresholds
  - lowerThreshold and nextThreshold (from `Quality.Predict` at the chosen allocation's skill)
  - allocation, reagentCost, requiredCost, expectedSale, profit
  - concentrationCost, expectedConcentrationCost, goldPerConcentration, ingenuityValue, concentrationCostForAllocation
  - multicraftValue, resourcefulnessValue, expectedYield
  - perQuality[q] = {allocation, reagentCost, skill, profit} for the plain plans
  - missingPrice, flags
- `EvaluateAllocation(input, allocation, optionalItemIDs|nil)`:
  - `optionalItemIDs` selects from `input.optionals` (nil = all of them; IDs not in the list are ignored).
  - skill = adjusted base + `Quality.ReagentSkill`, and cost = `Optimizer.AllocationCost`.
  - With `useConcentration`, the result is the allocation's concentration plan (quality + 1, capped). skill and thresholds still describe the allocation.
  - The concentration fields describe concentrating this allocation, compared with not concentrating it.
  - perQuality holds one entry: the allocation's own quality.

## Tests
- `tests/math/profit_spec.lua` has 21 specs: the brief's 6 verbatim, plus these:
  - ExpectedSale: AH cut, weighted chances, a nil price, a zero chance
  - Result fields describe the returned allocation (thresholds, lower/next, requiredCost, perQuality)
  - A concentration plan reports its own skill and thresholds
  - `unreachable_target_returns_best_with_flag`: skill too low, target above max, and a target reached only by concentration (no flag)
  - targetQuality combined with useConcentration, including target 1
  - A slot with no priced option: profit nil, flags.noPrice, no goldPerConcentration
  - Unpriced plans never beat priced ones, including one that sells at a loss
  - No curve, so concentration fields are nil (with and without useConcentration)
  - No concentration plan because the top quality is already reached, so the fields are 0; maxQuality 1
  - Optionals add skill, difficulty, multicraft rating, cost and a less-concentration factor (309 = round(343.75 × 0.9)). The maxReagentSkill default comes from base difficulty.
  - An unpriced optional makes reagentCost and profit nil but leaves requiredCost
  - EvaluateAllocation with optionalItemIDs given as a list, as nil and as {}
  - EvaluateAllocation with and without concentration (gold per point 176 = (121675 − 71895)/282.6)
  - EvaluateAllocation with an unknown item gives cost nil
- `tests/math/optimizer_spec.lua` +1 spec: "fractional weights are rounded to integers and stay fast"
  - 6 three-rank slots with weights {10.4, 20.2, 30.1, 40.3, 50.2, 59.6} must finish in under 0.25 s and give a result `same` as weights {10, …, 60}.
  - A weight of 0.3 must give the same result as 1.

### TDD evidence
Optimizer RED: `busted tests/math/optimizer_spec.lua`
```
25 successes / 1 failure / 0 errors / 0 pending : 1.209943 seconds
Failure -> tests/math/optimizer_spec.lua @ 165
Math.Optimizer fractional weights are rounded to integers and stay fast
tests/math/optimizer_spec.lua:176: took 1.180522 s
```
(Before the fix, the scratch run also gave a different q4 cost: 13990 with fractional weights vs 13984 with integer weights.)
Optimizer GREEN: `26 successes / 0 failures / 0 errors / 0 pending : 0.014083 seconds`.

Profit RED: `busted tests/math/profit_spec.lua`
```
0 successes / 0 failures / 1 error / 0 pending
tests/math/profit_spec.lua:1: failed to load Math/Profit.lua: cannot open Math/Profit.lua: No such file or directory
```
Profit GREEN: `21 successes / 0 failures / 0 errors / 0 pending : 0.018993 seconds`.

Final verification:
- `busted tests/math`: 68 successes / 0 failures
- `busted`: 560 successes / 0 failures / 0 errors / 0 pending
- `luacheck .`: 0 warnings / 0 errors in 64 files
- `grep -nE "C_[A-Za-z]+|ns\.FS|_G\b|GetServerTime" Math/*.lua`: matches only the pre-existing header comment "no WoW globals, no ns.FS" in every Math file; there is no code use.

## Files changed
- `Math/Optimizer.lua` (weight rounding)
- `tests/math/optimizer_spec.lua` (+1 spec)
- `Math/Profit.lua` (new)
- `tests/math/profit_spec.lua` (new)
- `FabricationStation.toc` (+`Math\Profit.lua` after `Math\Optimizer.lua`)

## Self-review findings
- I fixed a luacheck "unused value" warning and a leftover `local _ = quality` before committing.
- The `if not chosen` fallback in EvaluateCraft (an empty, unpriced quality-1 plan) is defensive. CheapestByQuality always returns at least one plan, because every slot gets a composition or a fallback composition. It is untested on purpose.
- `Quality.ReagentSkill`, used by EvaluateAllocation, uses raw weights, while the Optimizer now uses rounded ones. The two match for integer weights, which is all GameData has. With fractional weights they differ slightly; that is accepted per the ruling.

## Decisions and concerns for the controller
1. Where the concentration fields come from: they describe the chosen plan when it uses concentration, otherwise the most profitable concentration plan. goldPerConcentration always compares against the most profitable plain plan, even when targetQuality is set. This matches the brief's literal "best concentration-plan profit, best plain-plan profit".
2. `missingPrice` from output prices counts only qualities reachable without concentration, plus the chosen plan's own quality. Example: a 2-quality recipe where q2 is reachable only by concentration and q2 has no price. It is not flagged noPrice unless that plan is chosen, so it is not dropped from profit sorting.
3. `flags`: MathResult always carries `flags = { noPrice = <bool> }`, plus `unreachableTarget = true` when it applies; otherwise that key is absent, not false. Task 8's `assert.same({ noPrice=false, stalePrice=false, … }, r.flags)` builds its own flags table. If Task 8 copies Math's flags, it should copy only `unreachableTarget` when set.
4. EvaluateAllocation's `optionalItemIDs` filters `input.optionals`. For golden fixtures and live prediction with optionals, Task 8's `BuildInput` must therefore put the candidate optionals' stats into `input.optionals`. Otherwise selected optionals have no stats and are silently ignored. Task 9's fixture test calls `BuildInput` without `optionalItemIDs`.
5. Without a curve and with useConcentration, concentration plans still exist (quality + 1, profit priced) and their concentration cost is nil. The quality gain does not depend on knowing the cost.

---

## Fix report, round 1

Commits:
- `cac1107` fix: flag unknown optionals and compare targeted concentration with that quality
- `4eda661` fix: qualify optimizer skill parity and loosen fractional-weight timing check

Changes:
1. **Unknown optionals (Math/Profit.lua `prepare`).** An ID in `optionalItemIDs` that `input.optionals` does not list now sets `unknownOptional`. That makes `optionalCost = nil`, so `reagentCost`/`profit` are nil and `missingPrice`/`flags.noPrice` are true. `result` sets `flags.unknownOptional = true`. Known optionals in the same list are still applied (their skill and difficulty count).
2. **Gold per concentration with a target (Math/Profit.lua `EvaluateCraft`).** The comparison plan is now `target and plain[target] or plainBest`. When targetQuality is set and a plain plan lands on it, goldPerConcentration compares against that plan. Otherwise it compares against the best plain plan, as before. The doc comment is updated.
3. **Optimizer header.** The comment now says the reagent skill equals `Quality.ReagentSkill` for integer weights (what game data has) and can differ slightly for non-integer weights, because only the optimizer rounds them.
4. **Fractional-weight spec.** The bound is loosened from 0.25 s to 2 s and is only a backstop. The deterministic check is the `assert.same` against the rounded-weight result: unrounded, these weights gave a different q4 plan (13990 vs 13984 copper). A comment explains this. Knapsack state counts are not observable without changing the API, so I did not add a state-count check.

Covering tests (new):
- `EvaluateAllocation flags an optional it does not know`:
  - `{9999}` gives reagentCost nil, profit nil, missingPrice true, flags.noPrice and flags.unknownOptional true.
  - `{7001, 9999}` still gives skill 550 (the known optional applies), with cost nil and the flag set.
  - `{7001}` alone gives no unknownOptional flag.
- `with targetQuality, gold per concentration compares against that quality's plain plan`:
  - Setup: 5-quality recipe, baseSkill 100, targetQuality 2, useConcentration.
  - The concentration plan (q1 to q2) has profit 17000 at cost 463, expected 416.7.
  - Plain q2 has profit 16700; plain q3 (the best plain plan) has 52700.
  - goldPerConcentration = 1. Before the fix it was −86, from (17000 − 52700) / 416.7.
  - targetQuality 5 (no plain plan there) gives the unreachable flag and expected quality 4.

RED: `busted tests/math/profit_spec.lua`
```
Failure -> tests/math/profit_spec.lua @ 145
Math.Profit EvaluateAllocation flags an optional it does not know
tests/math/profit_spec.lua:148: Expected objects to be the same.
Passed in:
(number) 3000
Expected:
type nil
Failure -> tests/math/profit_spec.lua @ 154
Math.Profit with targetQuality, gold per concentration compares against that quality's plain plan
tests/math/profit_spec.lua:164: Expected objects to be equal.
Passed in:
(number) -86
Expected:
(number) 1
21 successes / 2 failures / 0 errors / 0 pending
```

GREEN:
- `busted tests/math`: 70 successes / 0 failures / 0 errors / 0 pending
- `busted`: 562 successes / 0 failures / 0 errors / 0 pending
- `luacheck .`: 0 warnings / 0 errors in 64 files
