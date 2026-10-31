# Phase 1b final fix wave: report

Status: DONE_WITH_CONCERNS (all findings fixed; concerns at the end).
Baseline before the wave: 1087 specs green, luacheck 0/0. After: **1133 successes / 0 failures / 0 errors**, `luacheck .` **0 warnings / 0 errors in 91 files**. Both outputs are clean: no stray prints in `busted` and no warnings in `luacheck`.

Commits (on `feat/fabricationstation`, not pushed):

| SHA | Subject | Findings |
|---|---|---|
| 2d69b72 | fix: cost required spark slots, estimate unweighted ranked slots, guard empty concentration curves | I2, M2, M3 |
| 1c11fae | fix: stop recalibration and re-evaluation churn on unrelated data changes | I3 |
| 479f152 | fix: use held reagents first in Craft Next and the queue's missing reagents | I4 |
| 6480efe | fix: never cost or restock a quality the crafter cannot reach | I1 (logic), M1 (tooltip) |
| f317c99 | fix: show unreachable, estimate and price-age markers in the panel, tabs and row labels | I1 (markers), M1, M6 |
| 4db806d | fix: guard a missing ProfessionsFrame in the panel, say "1 item", restore link-hook globals | M4, M5 |
| cfa067f | docs: record phase 1b final fixes in the contract and add the 1b in-game checklist | I5, I6 |
| a86071d | docs: reflow the Queue tab header comment | (comment tidy) |

Before every commit I ran `busted` and `luacheck .` (full suite, from the repo root). RED/GREEN captures are in the scratchpad (`fw-*-red.txt`, `fw-*-green.txt`). The reviewer's scratch repros (`unreach_spec.lua`, `churn_spec.lua`) were run from a copy in the scratchpad and were not added to the repo. Their results after the fixes are below.

---

## I1. flags.unreachableTarget ignored by consumers

**Change**
- `UI/Tooltips.lua`: `analyse` drops any result with `flags.unreachableTarget` as a candidate. It records whether any result exists and whether any is reachable. When every result falls short, the craft-cost line reads `quality not reachable`, and it never shows a lower quality's cost.
- `Modules/Queue.lua` `restock_entry`: a crafter whose result is unreachable is skipped. With no reaching crafter there is no restock entry, so Craft Next cannot keep crafting a lower quality whose count never rises.
- Markers: `UI/ProfessionPanel.lua` and `UI/Tabs/Recipes.lua` flag text gains `quality unreachable` (after `estimate`, before `unknown recipe`). The Queue tab name cell gains `[quality unreachable]` (WARN colour), read from the new `Queue:GetEntryResult(id)`.

**Tests**
- `tests/ui/tooltips_spec.lua`: "skips a crafter who cannot reach the item's quality, however cheap"; "says the quality cannot be reached when no crafter reaches it, and never shows a lower quality's cost" (real evaluation, skill 100).
- `tests/queue/queue_spec.lua`: "skips a crafter who cannot reach the target quality, however profitable"; "lists nothing when no crafter can reach the quality, so a lower quality is never crafted forever".
- `tests/queue/craft_spec.lua` "restock of a quality nobody reaches, real evaluation": no restock entry, `CraftNext()` returns `"empty"`, and `CraftRecipe` is not called (the no-loop case).
- `tests/ui/profession_panel_spec.lua` "says when the target quality cannot be reached"; `tests/ui/recipes_tab_spec.lua` "joins every flag in the fixed order" (extended); `tests/ui/queue_tab_spec.lua` "marks an entry whose target quality cannot be reached".

**Evidence**
- RED: `busted tests/ui/tooltips_spec.lua tests/queue` → `108 successes / 15 failures` (the 12 tooltip failures include the M1 cost-line format change; queue_spec @249/@259 and craft_spec @292 are I1).
- GREEN: `busted` → `1122 successes / 0 failures`.
- Reviewer repro `unreach_spec.lua` after the fix: `tooltip 5002 Craft cost quality not reachable`, `tooltip 5001 Craft cost 30s 0c (Alt, estimate, 1d old)`, and no `restock entry` line. Before the fix it printed `Craft cost 30s 0c (Alt)` for 5002 and a restock entry.

## I2. Required non-basic reagent slots dropped

**Change**
- `Modules/CraftingData.lua`: new `CraftingData.IsAllocated(slot)`. It is true for basic slots and for `required` optional/finishing slots, and false for a slot with an empty `reagents` list.
- `BuildInput` turns required non-basic slots into Math slots with `weight = 0` (fixed: the optimiser picks the cheapest usable item) and `noResourcefulness = true`. Their items are no longer offered as optional candidates.
- `AllocationFromReagentInfo` maps a required spark back into the allocation instead of `optionalItemIDs`.
- `Math/Profit.lua`: `makePlan` subtracts the `noResourcefulness` slots' allocated cost (`Optimizer.AllocationCost`) from the resourcefulness saving base. The spark is costed, but resourcefulness does not "refund" it (see concerns).
- `Modules/SelfCheck.lua` `game_allocation` now adds only non-allocated optional rows, so a required spark is sent to the game once.
- Effect: the spark is in `reagentCost` and `profit`, in `allocation`, and so in missing reagents, the shopping list and Craft Next's `CraftRecipe` reagents (through the unchanged `Scanner:ToCraftingReagentInfo`, ModifiedReagent data slots). An unpriced spark leaves the result unpriced.

**Tests**
- `tests/crafting/crafting_data_spec.lua`: "maps a required modifying slot's reagent to an allocation row…"; "IsAllocated: …".
- `tests/crafting/build_input_spec.lua` "required non-basic slots (sparks)" (4 specs: slot shape, Evaluate cost/profit/resourcefulness, not an optional candidate, an unpriced spark is never free).
- `tests/math/profit_spec.lua` "costs a fixed slot marked noResourcefulness but saves nothing on it" (EvaluateCraft and EvaluateAllocation).
- Through Evaluate: `tests/recipes/evaluate_spec.lua` "required modifying reagents (sparks)" (cost 8800 / profit 116010 / allocation, unpriced spark, live mapping and PredictLive).
- Through Queue: `tests/queue/queue_spec.lua` "lists the spark among the missing reagents and costs it".
- Through QueueCraft: `tests/queue/craft_spec.lua` "sends the spark to CraftRecipe" and "reports a missing spark and puts it on the shopping list".
- `tests/recipes/selfcheck_spec.lua` "sends a required spark once, as part of the allocation".

**Evidence**
- RED (unit, before implementation): `busted tests/crafting tests/math` → `101 successes / 11 failures / 1 error` (this run includes M2/M3).
- RED (integration, checked by stashing the three source files): `busted tests/recipes/evaluate_spec.lua tests/queue tests/recipes/selfcheck_spec.lua` → `174 successes / 7 failures`. The SelfCheck spec passes on the old code and failed after the CraftingData change, which led to the `game_allocation` fix.
- GREEN: `busted` → `1106 successes / 0 failures`; `luacheck .` → `0 warnings / 0 errors`.

## I3. Recalibration and re-evaluation churn

**Change**
- `Modules/Recipes.lua` `on_data_changed`: `"concentration"` returns early. There is no stamp bump, since Evaluate never reads the amount.
- `Recipes:Calibrate` always stores the new record (with the fresh `time`). It bumps the stamp only when no record existed, when a stored value changed (`same_values` compares baseSkill, baseDifficulty, maxReagentSkill, craftingDataID and stats), or when the old record was older than `staleCalibrationDays`, so `staleData` can clear.
- `Modules/RecipeScan.lua` `on_data_changed`: `"concentration"` starts no rescan, and `calibrated` is cleared only on `"spec"`/`"professions"` for the current character. A newly learned recipe ("recipes") is not in `calibrated`, so it still gets calibrated.

**Tests**
- `tests/recipes/evaluate_spec.lua`: the stamp test now covers professions/recipes/spec; new spec "keeps cached results on a concentration change" (same table).
- `tests/recipes/calibration_spec.lua` "re-calibration": an unchanged re-calibration keeps the stamp and the cached result (same table) and refreshes `time`; each changed value bumps; a stale old record bumps and clears `staleData`.
- `tests/recipes/scan_spec.lua`:
  - "does not recalibrate or re-evaluate after a concentration change": no live calls, same result table.
  - "recalibrates after a spec change, and only newly learned recipes after a recipes change".
  - "a scan after an unchanged recalibration reuses every cached result".

**Evidence**
- RED: `busted tests/recipes` → `191 successes / 5 failures`.
- GREEN: `busted` → `1113 successes / 0 failures`.
- Reviewer repro `churn_spec.lua` after the fix: `after concentration msg 1..3 : live calls 0 EvaluateCraft 0` and `after one Calibrate: EvaluateCraft for all 50 again: 0`. Before the fix: 100 live calls and 50 evaluations per message, and 50 after one Calibrate.

## I4. Craft Next reports "missing" when held reagents would do

**Change**
- `Modules/QueueCraft.lua` `one_craft` evaluates with `ownedReagentsFree = true`, so the allocation uses held reagents first.
- Beyond the finding, `Modules/Queue.lua` `per_craft` (missing reagents, shopping list) does the same. Without it, the Queue tab and the shopping list would still ask to buy the market mix that Craft Next no longer uses. Entry costs (`GetEntryCost`) stay at market prices.

**Tests** (`tests/queue/craft_spec.lua` "held reagents, real evaluation": only top ranks are held; the market Q2 plan buys 3×1001 + 1×2001)
- "crafts with the reagents held instead of reporting the market mix as missing" (asserts the CraftRecipe reagents are 10×1002, 5×2002).
- "puts nothing on the shopping list that the held reagents cover".
- "still costs the entry at market prices unless owned reagents are free" (4800).

**Evidence**
- RED: `busted tests/queue` → `85 successes / 2 failures`. The craft spec got `'missing'`; missing reagents were `{ [1001] = 3, [2001] = 1 }`.
- GREEN: `busted` → `1116 successes / 0 failures`.

## I5. Contract drift

**Change** (`docs/superpowers/plans/2026-10-30-fs-interface-contract.md`)
- `Recipes.DEFAULTS.applyWritesBlizzardSlots = false`, which stays off until the in-game taint check passes.
- Added `ns.FS:CancelDebounce(key)`, `ProfessionPanel:SetCheckLine(text|nil, tone?)`, the `ApplyAllocation` return reasons and `SetStatus(text, tone?)`.
- Added `Queue:GetEntryResult(id)`, and noted that missing reagents and Craft Next are evaluated owned-free.
- Phase 3 Task 11 note: `full_opts` keeps only 4 keys, so `extraStats` must be read before `full_opts`, must bypass the cache there, and must be threaded through `evaluate` to the built `input`. The same note is added to Step 4 of `docs/superpowers/plans/2026-10-30-fs-phase3-alts-planner.md`.
- `flags.unreachableTarget` consumer behaviour: tooltip, restock, panel/tab markers.
- Required non-basic slot handling: `IsAllocated`, the weight-0 `noResourcefulness` slot, `AllocationFromReagentInfo`, SelfCheck. Also `RecipeInput.missingWeights` and the `ReagentAllocation` wording.
- `Concentration.Cost` may return nil, plus the new `IsUsable`. `CraftingData.Curve` is nil without difficulty points.
- Data stamp and calibration rules (concentration, Calibrate bumps, recalibration triggers).
- Tooltip cost-line format and cache messages; RecipeListLabels display rules.

**Tests**: docs only. Full suite and luacheck were run before the commit: `1133 successes / 0 failures`; `0 warnings / 0 errors in 91 files`.

## I6. In-game checklist

**Change**: `docs/in-game-checklist.md` has a new "Phase 1b (crafting)" section with all 15 checks (1b-1 … 1b-15), each with concrete steps and the expected result. They are grouped as taint and events, queue and shopping list, performance and layout, and self-check and data. The title and intro now mention 1b.
- 1b-1 also asks whether Apply fills a spark slot.
- 1b-6 also asks to confirm that resourcefulness never refunds a spark (the I2 assumption).
- 1b-14 lists the new "~" markers.

**Tests**: docs only (same verification run as I5).

## M1. Missing markers

**Change**
- Tooltip craft cost: `"<money> (<char>[, estimate][, <age> old])"`, where the candidate carries `priceAgeDays` (commit 6480efe).
- Queue tab: the cost cell gets a `~` prefix when estimated and the price age after it (DIM, or BAD when stale), from `Queue:GetEntryResult`. `Tab.BuildRows` takes an optional 6th `results` argument. The cost column is widened from 104 to 128.
- Recipe-list labels: a `~` prefix when estimated.

**Tests**
- `tests/ui/tooltips_spec.lua` "says when the cheapest cost is an estimate, and how old its prices are". All real-evaluation cost lines now expect `1d old`; the `cost_line` helper takes a note.
- `tests/ui/queue_tab_spec.lua`: "marks an estimated cost with a tilde and shows its price age, red when stale"; "an unknown cost stays no price even when estimated"; view test "shows the estimate marker and price age of the entry's evaluation".
- `tests/queue/queue_spec.lua` "entry results".
- `tests/ui/recipe_list_labels_spec.lua` "an estimated profit starts with a tilde".

**Evidence**
- RED: `busted tests/ui tests/queue` → `399 successes / 8 failures / 1 error` (the error is the missing `GetEntryResult`).
- GREEN: `busted` → `1131 successes / 0 failures`.

## M2. Ranked basic slot with weight 0 → estimated

**Change**: `BuildInput` sets `missingWeights = true` for a basic slot with ≥ 2 ranks and weight ≤ 0. Single-rank slots and spark slots are not counted. `Recipes` evaluate adds `or input.missingWeights == true` to `flags.estimated`, which also makes SelfCheck skip such results.

**Tests**
- `tests/crafting/build_input_spec.lua` "missing reagent weights" (2 specs).
- `tests/recipes/evaluate_spec.lua` "flags a calibrated result as estimated when a ranked slot has no GameData weight".

**Evidence**: RED in the I2 runs above (build_input @121/@126; evaluate @165). GREEN `1106 / 0`.

## M3. Concentration.Cost throws on an empty point list

**Change**
- `CraftingData.Curve` returns nil when the difficulty points are empty or missing, as well as when the skill points are.
- `Concentration.IsUsable(curve)` is new. `Concentration.Cost` returns nil (no error) for a curve whose lists are empty.
- `Profit.prepare` treats an unusable curve as no curve, so the concentration numbers are nil and never 0.

**Tests**
- `tests/math/concentration_spec.lua` "a curve without points has an unknown cost instead of raising".
- `tests/math/profit_spec.lua` "a curve without points gives unknown concentration numbers instead of an error".
- `tests/crafting/crafting_data_spec.lua` "curve is nil when the difficulty curve or the skill points are empty". This replaces the old spec that expected `{ constant = {} }`.

**Evidence**
- RED: concentration @20 and profit @107 raise `attempt to index local 'p0' (a nil value)`; crafting_data @39.
- GREEN `1106 / 0`.
- Reviewer `conc.lua` repro: `Cost(...)` now returns nil instead of raising.

## M4. "1 items" and the ProfessionsFrame nil guard

**Change**
- `UI/Tabs/Queue.lua` `ShoppingText` uses a `count_items(n)` helper (singular for 1).
- `UI/ProfessionPanel.lua` `sync_visibility` reads `ProfessionsFrame` into a local and hides the panel when it is nil.

**Tests**
- `tests/ui/queue_tab_spec.lua` "says item, not items, for one". The existing view spec "says how many items were skipped" had encoded the bug; it now expects `1 item skipped`.
- `tests/ui/profession_panel_spec.lua` "hides instead of erroring when ProfessionsFrame is gone at a show hook". The module stays enabled and no error is logged.

**Evidence**: RED `busted tests/ui/profession_panel_spec.lua tests/ui/queue_tab_spec.lua` → `110 successes / 2 failures`. Before the fix, SafeCall turned the panel module off. GREEN `1133 / 0`.

## M5. Queue tab link-hook test hygiene

**Change** (test only): the spec is in its own `describe("link hook")`. `before_each` saves `_G.hooksecurefunc` and `_G.ChatFrameUtil`, and `after_each` restores them, so a failing assertion cannot leak fakes. The spec also asserts that `ChatFrameUtil.InsertLink` is still the original function and that `_G.ChatFrameUtil` is the same table, which would catch the addon replacing it instead of hooking.

**Evidence**: there is no RED for a test-hygiene change. It passes against the current code; GREEN `1133 / 0`.

## M6. RecipeListLabels: ±inf and unknown recipes

**Change**: `LabelText` returns `"?"` / grey for ±`math.huge`. `label_row` hides the label when `flags.unknownRecipe`.

**Tests**: `tests/ui/recipe_list_labels_spec.lua` "an infinite profit is a question mark"; "hides the label of a recipe the character does not know".

**Evidence**: RED in the M1 run (labels @54, @140). GREEN `1131 / 0`.

---

## Files changed (source)

Math/Concentration.lua, Math/Profit.lua, Modules/CraftingData.lua, Modules/Recipes.lua, Modules/RecipeScan.lua, Modules/Queue.lua, Modules/QueueCraft.lua, Modules/SelfCheck.lua, UI/ProfessionPanel.lua, UI/RecipeListLabels.lua, UI/Tabs/Queue.lua, UI/Tabs/Recipes.lua, UI/Tooltips.lua. Docs: the interface contract, the phase 3 plan (one note), docs/in-game-checklist.md. Tests: 14 spec files (see each finding).

## Self-review

- Contract names and shapes are kept; there are only additions: `CraftingData.IsAllocated`, `Concentration.IsUsable`, `Queue:GetEntryResult`, the `MathSlot.noResourcefulness` and `RecipeInput.missingWeights` fields, and the optional 6th argument of `QueueTab.BuildRows`. `Concentration.Cost` can now return nil, but only for a malformed curve (documented).
- No taint: no new writes on Blizzard frames. The panel guard only reads `ProfessionsFrame`.
- Craft Next stays click-only; the structural spec still passes.
- No db writes while `dbIsNewer`: `Calibrate` keeps its early `writable()` return, and nothing new writes saved data.
- Core modules still log only: no new SafeCall sources. The RecipeScan handlers are unchanged apart from their filters.
- Math and CraftingData still reference no WoW globals or `ns.FS`. luacheck's path-specific std still passes.

## Concerns

1. **Spark resourcefulness (I2)**: I assumed resourcefulness never refunds a required modifying reagent (as I understand CraftSim's model). If that is wrong, drop `noResourcefulness` in `BuildInput`. In-game check 1b-6 asks to verify it. Spark items' own stats (if any) are not applied.
2. **Owned-free missing reagents (I4 extension)**: each entry is optimised with all of the character's held reagents free. Two entries of one character may both plan on the same held top-rank stock, and the shortfall then shows that rank (dearer) rather than a cheaper alternative. This is a rare, conservative over-estimate.
3. **Unreachable only without concentration**: the tooltip and restock evaluate without concentration. A quality reachable only with concentration reads as "quality not reachable" and gets no restock entry.
4. **Apply and spark slots**: Apply now also writes a spark row with the same Clear/Allocate calls it uses for basic slots. It is off by default; in-game check 1b-1 asks whether this behaves.
5. The integration specs for I2 (Evaluate, Queue, QueueCraft) were written right after the CraftingData change rather than before it. Their RED was shown afterwards by stashing the source changes (`174 successes / 7 failures`).
