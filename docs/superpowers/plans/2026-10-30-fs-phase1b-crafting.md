# FabricationStation Phase 1b — Crafting Math, Profit, Queue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace CraftSim for the author: predict quality and concentration cost, pick the cheapest reagents per reachable quality, rank every known recipe on every character by profit and gold per concentration, and run a click-only craft queue with an Auctionator shopping list — in the main window, beside Blizzard's Professions frame, in the recipe list and in item tooltips.

**Architecture:** `ns.Math` is pure Lua (plain tables in, plain tables out) and carries all crafting formulas. `Recipes` joins Scanner snapshots, per-character calibration records (taken from `GetCraftingOperationInfo` while a profession window is open), crafting GameData and Prices into a `RecipeInput`, calls Math, caches results keyed on price version and per-character data stamps, and runs a time-sliced scan. `Queue` consumes only Recipes/Scanner/Prices public functions. UI files expose pure "model" functions that busted tests; frames are thin and verified in game.

**Tech Stack:** WoW retail Lua 5.1 (Midnight 12.x), Ace3 (AceAddon/AceEvent/AceDB/AceConfig), busted, luacheck, Auctionator API v1 (through `Prices:AuctionatorAPI()` only), wago.tools DB2 CSV exports for crafting GameData.

**Spec:** `docs/superpowers/specs/2026-10-30-fabricationstation-design.md` (§5.1 Dashboard/Recipes/Queue tabs, §5.2, §5.4 craft-cost line, §6, §11, §12). Binding names: `docs/superpowers/plans/2026-10-30-fs-interface-contract.md`. Phase 1a (`2026-10-30-fs-phase1a-foundation.md`) is assumed complete: Core, Scanner, Prices, GameData pipeline, MainWindow shell, Settings tab, test harness.

## Global Constraints

- Retail only, Midnight 12.x. Interface number pinned by phase 1a.
- Every addon file begins `local ADDON_NAME, ns = ...`. Modules: `ns.FS:NewModule("<Name>", "AceEvent-3.0")`.
- Math never calls the game: files in `Math/` reference no WoW globals and no `ns.FS` (spec §3 rule 4). Tests load them with a bare `ns = {}`.
- Only the Prices module talks to Auctionator; Queue reaches it only through `Prices:AuctionatorAPI()` with caller ID `"FabricationStation"` and list name `"FabricationStation"`.
- Every protected action is a player click: `C_TradeSkillUI.CraftRecipe` is called only inside `Queue:CraftNext()`, and `Queue:CraftNext()` is called only from `OnClick` handlers. No loops, no timers.
- No taint: own frames plus `hooksecurefunc`, `HookScript`, `EventRegistry:RegisterCallback`, ScrollBox `RegisterCallback`. Never assign fields on Blizzard frames; per-row data lives in addon-owned weak-keyed tables. Never replace, hide or reparent Blizzard frames.
- Missing price → `flags.noPrice = true`, shown as "no price", excluded from profit sorting, never treated as 0. A `PriceResult.value` of `nil` is never coerced to 0.
- Money is integer copper; every copper output of Math is rounded with `ns.Math.Round(x) = math.floor(x + 0.5)`. Time is server seconds via `ns.FS:Now()`.
- Expected sale applies the 5% AH cut: `Profit.AH_CUT = 0.95`.
- Owned reagents are costed at market price by default; setting `ownedReagentsFree` costs them at zero.
- Price age is shown wherever a price is shown.
- Each Blizzard-frame addition (ProfessionPanel, RecipeListLabels, Tooltips craft-cost line) is its own AceModule with its own settings toggle; its hooks run through `ns.FS:SafeCall(moduleName, fn, ...)` so a failure disables only that module.
- New saved tables are created lazily (`db.global.x = db.global.x or {...}`): `db.global.queue` (spec §4.3 shape plus `nextID`), `db.global.recipeCalib[charKey][recipeID]`, `db.global.diagnostics.mismatches`, `db.global.captures.math`, `db.global.settings.crafting`. No schema migration is needed.
- Files whose formula or data mapping comes from CraftSim carry the header comment `-- Formula reference: CraftSim (MIT, github.com/derfloh205/CraftSim) <path>`.
- Each task appends its new files to `FabricationStation.toc` in this order: `Math/Quality.lua, Math/Concentration.lua, Math/Stats.lua, Math/Optimizer.lua, Math/Profit.lua` after `Core/`; `Data/GameData_Crafting.lua` after 1a's `Data/` files; `Modules/Recipes.lua, Modules/RecipeScan.lua, Modules/Queue.lua, Modules/QueueCraft.lua, Modules/SelfCheck.lua` after 1a's modules; `UI/Tabs/Dashboard.lua, UI/Tabs/Recipes.lua, UI/Tabs/Queue.lua, UI/ProfessionPanel.lua, UI/RecipeListLabels.lua, UI/Tooltips.lua` after `UI/MainWindow.lua`.
- Verification for every task: `busted` (all specs green) and `luacheck .` (0 warnings). Commits are conventional (`feat:`, `test:`, `chore:`, `fix:`).

## Verified formulas and their sources

Read from CraftSim `main` @ e15fb18 (2026-10-21, data build 12.1.5.70448) and Blizzard API docs on `Gethe/wow-ui-source` `live`, fetched 2026-10-30. "CraftSim" below means verified against CraftSim's code, not against the game; Task 9 checks them against the game.

| Item | Value | Source |
|---|---|---|
| Quality thresholds (fraction of total difficulty) | maxQ 1: none; 2: {1.0}; 3: {0.5, 1.0}; 5: {0.2, 0.5, 0.8, 1.0}; reached when `skill >= threshold` | CraftSim `Modules/RecipeInfo/RecipeInfo.lua` `GetQualityThresholds` (offset option default off) |
| Quality is deterministic (no inspiration); concentration adds +1 quality, capped at max | | CraftSim `Classes/ResultData.lua` |
| Max reagent skill | measured live = skill(all reagents top rank) − skill(empty allocation); default `0.40 × baseDifficulty` | CraftSim `ReagentData:GetMaxSkillFactor`; 0.40 from `ReagentOptimization.lua` header (Midnight-era text) |
| Reagent skill | `maxReagentSkill × Σ_s w_s·Σ_i f(rank_i)·n_i ÷ Σ_s w_s·q_s` with rank factor 2-rank {0, 1}, 3-rank {0, 0.5, 1}; `w_s` = `ModifiedCraftingCategory.MatQualityWeight` | CraftSim `ReagentOptimization.lua` header + `IsSimplifiedQualityRecipe` |
| Concentration cost | piecewise-linear `curve(skill/difficulty) × constant`, minus `Σ lessFactor × cost`, rounded; skill capped at difficulty | CraftSim `RecipeData:GetConcentrationCostForSkill`, `UTIL:CalculateConcentrationCost`, `UTIL:FindBracketData` |
| Concentration curve data | `CraftingData.CraftingDifficultyID → CraftingDifficulty.{ConcentrationSkillCurveID, ConcentrationDifficultyCurveID} → CurvePoint(Pos_0, Pos_1)`; skill-curve `Pos_0 ÷ 100` | CraftSim `DevTools/DataMining/ConcentrationCurveData/mapper.py` |
| Ingenuity | expected concentration = `cost × (1 − chance × (0.5 + extra))` | CraftSim `RecipeData:GetConcentrationValue` |
| Multicraft | `maxExtra = C(baseYield) × baseYield × (1 + extra)`, extra items on proc `(1 + maxExtra)/2`; `C`: 1→2.1, 2→1.83, 5→1.875, else 2.5 | CraftSim `CALC:GetExpectedItemAmountMulticraft`, `CONST.MULTICRAFT_CONSTANTS` (approximation) |
| Resourcefulness | saving on proc = `requiredCost × 0.30 × (1 + extra)` | CraftSim `CONST.BASE_RESOURCEFULNESS_AVERAGE_SAVE_FACTOR` (CraftSim calls it an approximation) |
| Stat rating → fraction for optional-reagent ratings | multicraft ÷1100, resourcefulness ÷900, ingenuity ÷1000 | CraftSim `CONST.PERCENT_DIVISION_FACTORS[11]` |
| `CraftingOperationInfo` fields | `baseDifficulty, bonusDifficulty, baseSkill, bonusSkill, quality, craftingQuality, craftingDataID, lowerSkillThreshold, upperSkillTreshold` [sic], `bonusStats{bonusStatName, bonusStatValue, ratingPct, bonusRatingPct}, concentrationCost, ingenuityRefund` | `TradeSkillUITypesDocumentation.lua` |
| `CraftingReagentInfo` | `{ reagent = { itemID }, dataSlotIndex, quantity }` (nested `reagent` in Midnight) | same; `Professions.CreateCraftingReagentInfo` |
| `CraftRecipe(recipeSpellID, numCasts, craftingReagents, recipeLevel, orderID, applyConcentration)`; Blizzard passes only `ModifiedReagent` slots (`Enum.TradeskillSlotDataType.ModifiedReagent = 2`) | | `TradeSkillUIDocumentation.lua`, `ProfessionsRecipeTransactionMixin:CraftRecipe` |
| Dock/hook points | `ProfessionsFrame` (LoadOnDemand `Blizzard_Professions`), `.CraftingPage.SchematicForm` (`GetTransaction()`, `UpdateAllSlots()`, `ProfessionsRecipeSchematicFormMixin.Event.AllocationsModified`), `.CraftingPage.RecipeList.ScrollBox` (`ScrollBoxListMixin.Event.OnInitializedFrame`, `ForEachFrame`), `EventRegistry` `"ProfessionsRecipeListMixin.Event.OnRecipeSelected"`, `"Professions.TransactionUpdated"` | `Blizzard_Professions*.xml/lua`, `ScrollBox.lua` |
| Auctionator search term | `{ searchString = name, isExact = true, quantity = n, tier = rank }` → `ConvertToSearchString(callerID, term)` → `CreateShoppingList(callerID, listName, searchStrings)` | CraftSim `Modules/Shopping/Shopping.lua` |

## Review Focus

1. **Alt or recipe with no calibration record** (alt never opened that profession since install, or recipe learned since): `Evaluate` must return an estimate built from Scanner skill and `0.40 × baseDifficulty`, flagged `staleData = true, estimated = true`, shown as "estimate" — never an error, never shown as certain. Test: Task 8 `estimates_without_calibration`.
2. **Item names not yet cached** when exporting the shopping list: skip that item, call `C_Item.RequestLoadItemDataByID`, report "N items skipped, try again", never send an empty search string. Test: Task 12 `skips_uncached_names`.
3. **Craft Next clicked with the wrong window or character** (profession window closed, another profession open, entry belongs to an alt, reagents missing, cooldown not ready): no `CraftRecipe` call, a clear "Open <Profession> on <Character>" / "missing reagents" / "ready at" status. Tests: Task 12 `craft_next_*`.
4. **Reagent slots the optimizer has not seen**: weight 0 or missing from GameData, single-item (non-quality) slots, a missing price on one rank, mixed 2-rank and 3-rank slots in one recipe. No divide-by-zero; unweighted slots are fixed at their cheapest priced rank; a slot with no priced option sets `missingPrice`. Tests: Task 5 `unweighted_slot_fixed`, `missing_rank_price`, `mixed_rank_slots`.
5. **Blizzard frame layout changes or Blizzard_Professions not loaded yet**: ProfessionPanel and RecipeListLabels wait for `ADDON_LOADED("Blizzard_Professions")`; if an expected child frame is missing they disable themselves with one chat message and no Lua error. Test: Task 17 `disables_when_scrollbox_missing`.

**Constants not verified against the game (pinned from golden fixtures in Task 9 before UI work):** reagent-skill rounding (none / floor / round), concentration cost rounding mode (round-half-up assumed), whether `maxReagentSkill` uses base or total difficulty, the 0.40 default factor for Midnight recipes, multicraft constants and the 0.30 resourcefulness factor (CraftSim approximations — checked against craft results, not op info), ingenuity refund fraction vs `ingenuityRefund`, whether `craftingQuality` or `quality` is the rank to compare, and optional-reagent rating conversions.

---

## File Structure

| File | Responsibility |
|---|---|
| `tools/gamedata/fetch_crafting_csv.sh` | Download the wago.tools DB2 CSVs for one build. |
| `tools/gamedata/crafting.lua` | Offline generator: CSVs → `Data/GameData_Crafting.lua`. |
| `Data/GameData_Crafting.lua` | Generated: `ns.GameData.Crafting = { build, concentrationCurves, reagentWeights, optionalReagents }`. |
| `Math/Quality.lua` | `ns.Math.Round`, thresholds, prediction, reagent skill. |
| `Math/Concentration.lua` | Concentration cost curve, ingenuity expectation, gold per point. |
| `Math/Stats.lua` | Multicraft/resourcefulness expectations, bonus-stat parsing, optional-reagent effects. |
| `Math/Optimizer.lua` | Per-slot compositions, knapsack DP, cheapest allocation per reachable quality. |
| `Math/Profit.lua` | Expected sale and `EvaluateCraft` / `EvaluateAllocation` (the pure entry points). |
| `Modules/Recipes.lua` | Settings, calibration, reagent-info conversion, `BuildMathInput`, `Evaluate`, cache, `WhoCanCraft`, `FindRecipesForItem`, mismatch log, fixture recorder. |
| `Modules/RecipeScan.lua` | Time-sliced scan and `GetRanked` (extends the Recipes module). |
| `Modules/Queue.lua` | Entries, restock, missing reagents, costs. |
| `Modules/QueueCraft.lua` | Shopping list export, `CraftNext`, craft-result accounting, cooldown readiness (extends Queue). |
| `Modules/SelfCheck.lua` | Live prediction vs `GetCraftingOperationInfo` comparison and logging. |
| `UI/Tabs/Dashboard.lua` | Dashboard module, tab, `RegisterWidget`, phase-1 widgets. |
| `UI/Tabs/Recipes.lua` | Recipes tab. |
| `UI/Tabs/Queue.lua` | Queue tab and restock editor. |
| `UI/ProfessionPanel.lua` | Panel docked beside `ProfessionsFrame`. |
| `UI/RecipeListLabels.lua` | Profit labels on Blizzard recipe-list rows. |
| `UI/Tooltips.lua` | Tooltip module, `RegisterLineProvider`, craft-cost line. |
| `tools/export_math_fixtures.lua` | SavedVariables → `tests/fixtures/math/*.lua` + `index.lua`. |
| `tests/helpers/crafting_world.lua` | Fake Scanner/Prices modules and a sample recipe world for Recipes/Queue/UI-model specs. |
| `tests/helpers/fake_frames.lua` | Minimal `CreateFrame`/FontString/ScrollBox/`ProfessionsFrame` fakes for hook specs. |

### Shared shapes (defined once, used by every task)

```lua
-- MathSlot: one required reagent slot as Math sees it
{ slotIndex = 1, quantity = 10, weight = 48,          -- weight 0 = gives no skill
  items = { { itemID = 1001, rank = 1, price = 100, owned = 0, provided = 0 },   -- ordered by rank; #items == 1 → non-quality slot
            { itemID = 1002, rank = 2, price = 300, owned = 0, provided = 0 } } } -- price nil = no price

-- Curve (GameData.Crafting.concentrationCurves[craftingDataID])
{ constant = { {0, 200}, {1000, 200} }, curve = { {0, 2.35}, {0.6, 2.2}, {0.8, 1.1}, {0.9999, 1.0}, {1.0, 0} } }  -- sorted {x, y}

-- RecipeInput (Recipes:BuildMathInput → Math.Profit.EvaluateCraft)
{ maxQuality = 2, baseDifficulty = 700, baseSkill = 500, maxReagentSkill = 280|nil,
  slots = { MathSlot... },                       -- required slots only
  optionals = { { itemID, price, stats = {skill=, increasedifficulty=, multicraft=, resourcefulness=, ingenuity=, reduceconcentrationcost=} } },
  stats = { multicraft = 0.2|nil, resourcefulness = 0.25|nil, ingenuity = 0.2|nil, multicraftExtra = 0, resourcefulnessExtra = 0, ingenuityExtra = 0 },
  yield = { min = 1, max = 1 }, outputPrices = { [1] = 60000, [2] = 100000 },
  concentration = { curve = Curve|nil, lessFactors = {} },
  useConcentration = false, targetQuality = nil }

-- MathResult (Math.Profit.EvaluateCraft / EvaluateAllocation)
{ expectedQuality, qualityChances = {[q] = 1}, skill, difficulty, thresholds, lowerThreshold, nextThreshold,
  allocation = ReagentAllocation, reagentCost, requiredCost, expectedSale, profit,
  concentrationCost, expectedConcentrationCost, goldPerConcentration,
  multicraftValue, resourcefulnessValue, ingenuityValue, expectedYield,
  perQuality = { [q] = { allocation, reagentCost, skill, profit } }, missingPrice = bool }

-- CalibRecord (db.global.recipeCalib[charKey][recipeID])
{ time, baseSkill, baseDifficulty, maxReagentSkill|nil, craftingDataID, maxQuality,
  concentrationCost, ingenuityRefund, stats = { multicraft, resourcefulness, ingenuity } }
```

`RecipeResult` (contract) = `MathResult` + `recipeID, charKey, flags`. Additive fields beyond the contract: `skill, difficulty, thresholds, lowerThreshold, nextThreshold, perQuality, expectedYield, expectedConcentrationCost, requiredCost, priceAgeDays` (max age of prices used), `flags.estimated`. `ingenuityValue` is expected concentration points refunded per craft (not copper).

---

### Task 1: Crafting GameData tables

**Files:**
- Create: `tools/gamedata/fetch_crafting_csv.sh`, `tools/gamedata/crafting.lua`, `Data/GameData_Crafting.lua` (generated), `tests/fixtures/wago/*.csv` (hand-made, a few rows each)
- Modify: `FabricationStation.toc`
- Test: `tests/gamedata/crafting_spec.lua`

**Interfaces:**
- Consumes: nothing at runtime.
- Produces: `ns.GameData.Crafting = { build = "12.x.y.z", concentrationCurves = { [craftingDataID] = Curve }, reagentWeights = { [itemID] = weight }, optionalReagents = { [itemID] = { qualityID, kind = "optional"|"finishing"|"spark", stats = {...} } } }`. `tools/gamedata/crafting.lua <csvDir> <build>` writes Lua to stdout. If 1a's `ns.GameData` table does not exist yet when this file loads, create it.

- [ ] **Step 1: Write the failing test**

```lua
describe("crafting gamedata generator", function()
  local gen = dofile("tools/gamedata/crafting.lua")        -- returns module table when run via dofile with no args
  local data = gen.build_tables("tests/fixtures/wago", "12.1.5.70448")
  it("maps craftingDataID to sorted curve points", function()
    assert.same({ {0, 200}, {1000, 200} }, data.concentrationCurves[2588].constant)
    assert.same({ {0, 2.35}, {0.6, 2.2}, {0.8, 1.1}, {0.9999, 1.0}, {1.0, 0} }, data.concentrationCurves[2588].curve)
  end)
  it("maps reagent itemID to MatQualityWeight", function()
    assert.equals(48, data.reagentWeights[189541])
    assert.is_nil(data.reagentWeights[999999])               -- weight 0 rows are dropped
  end)
  it("maps finishing reagent effects scaled by ReagentEffectPct", function()
    assert.equals("finishing", data.optionalReagents[211111].kind)
    assert.equals(30, data.optionalReagents[211111].stats.multicraft)       -- Amount 60 × ReagentEffectPct 50/100
  end)
  it("emits loadable Lua that fills ns.GameData.Crafting", function()
    local ns = {}
    loadstring(gen.emit(data))("FabricationStation", ns)
    assert.equals("12.1.5.70448", ns.GameData.Crafting.build)
  end)
end)
```

Fixture CSVs: `CraftingData.csv` (ID 2588 → CraftingDifficultyID 77), `CraftingDifficulty.csv` (77 → ConcentrationSkillCurveID 5001, ConcentrationDifficultyCurveID 5002), `CurvePoint.csv` (curve 5001 points with Pos_0 in percent: 0, 60, 80, 99.99, 100; curve 5002: (0,200),(1000,200)), `Item.csv`, `ModifiedCraftingReagentItem.csv`, `ModifiedCraftingCategory.csv`, `CraftingReagentQuality.csv`, `CraftingReagentEffect.csv`, `ProfessionEffect.csv`, `ProfessionEffectType.csv` with the rows the asserts need.

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/gamedata/crafting_spec.lua`
Expected: FAIL — cannot open `tools/gamedata/crafting.lua`.

- [ ] **Step 3: Implement the generator and fetch script**

`fetch_crafting_csv.sh <build> <outDir>` runs `curl -fsSL "https://wago.tools/db2/<Table>/csv?build=<build>" -o <outDir>/<Table>.csv` for: `CraftingData CraftingDifficulty CurvePoint Item ModifiedCraftingReagentItem ModifiedCraftingCategory CraftingReagentQuality CraftingReagentEffect ProfessionEffect ProfessionEffectType`.

`crafting.lua` (Lua 5.1, runnable as `lua tools/gamedata/crafting.lua <csvDir> <build>`; returns `{ build_tables, emit }` when loaded with `dofile`): a quoted-field CSV reader, then the joins from the verified-sources table — curves (skill-curve `Pos_0 ÷ 100`), weights (`Item.ModifiedCraftingReagentItemID → ModifiedCraftingReagentItem.ModifiedCraftingCategoryID → ModifiedCraftingCategory.MatQualityWeight`, keep > 0), optional reagents (Item ClassID 7 SubclassID 18 optional / 19 finishing / 11 spark; latest `CraftingReagentQuality` row by ID for the item; `MaxDifficultyAdjustment > 0` → `stats.increasedifficulty`; else `CraftingReagentEffect` by `ModifiedCraftingCategoryID` → `ProfessionEffect.Amount × (finishing and ReagentEffectPct/100 or 1)` keyed by `ProfessionEffectType.Name_lang` lower-cased with spaces and "(DNT...)" removed). Header comment credits CraftSim `DevTools/DataMining/*/mapper.py`. `emit` writes one entry per line, keys sorted, header `local ADDON_NAME, ns = ...` and `-- Generated from wago.tools build <build>; do not edit`.

- [ ] **Step 4: Run test to verify it passes**

Run: `busted tests/gamedata/crafting_spec.lua`
Expected: PASS (4 tests).

- [ ] **Step 5: Generate the real file and add it to the TOC**

Run: `tools/gamedata/fetch_crafting_csv.sh <live build from 1a's GameData stamp> /tmp/fs-wago && lua tools/gamedata/crafting.lua /tmp/fs-wago <build> > Data/GameData_Crafting.lua && luacheck Data/GameData_Crafting.lua`
Expected: file written, luacheck 0 warnings, `grep -c "^\s*\[" Data/GameData_Crafting.lua` > 1000.

- [ ] **Step 6: Commit**

```bash
git add tools/gamedata/ Data/GameData_Crafting.lua tests/gamedata/crafting_spec.lua tests/fixtures/wago/ FabricationStation.toc
git commit -m "feat: generate crafting GameData (concentration curves, reagent weights, optional reagents)"
```

---

### Task 2: Math.Quality

**Files:**
- Create: `Math/Quality.lua`
- Modify: `FabricationStation.toc`
- Test: `tests/math/quality_spec.lua`

**Interfaces:**
- Consumes: nothing.
- Produces: `ns.Math.Round(x) -> integer`; `ns.Math.Quality.THRESHOLD_FRACTIONS = { [1] = {}, [2] = {1.0}, [3] = {0.5, 1.0}, [5] = {0.2, 0.5, 0.8, 1.0} }`; `Quality.DEFAULT_REAGENT_SKILL_FACTOR = 0.40`; `Quality.Thresholds(maxQuality, difficulty) -> {number}|nil` (skill needed for quality 2..max; nil for unsupported maxQuality); `Quality.Predict(skill, difficulty, maxQuality) -> quality, nextThreshold|nil, lowerThreshold`; `Quality.RankFactor(rank, numRanks) -> number`; `Quality.ReagentSkill(slots: {MathSlot}, allocation: ReagentAllocation, maxReagentSkill) -> number` (unrounded).

- [ ] **Step 1: Write the failing test**

```lua
local ns = load_files({}, { "Math/Quality.lua" })
local Q = ns.Math.Quality
local A = { slotIndex = 1, quantity = 10, weight = 48, items = { {itemID=11,rank=1},{itemID=12,rank=2},{itemID=13,rank=3} } }
local B = { slotIndex = 2, quantity = 5,  weight = 32, items = { {itemID=21,rank=1},{itemID=22,rank=2},{itemID=23,rank=3} } }
local A2 = { slotIndex = 1, quantity = 10, weight = 48, items = { {itemID=11,rank=1},{itemID=12,rank=2} } }
local B2 = { slotIndex = 2, quantity = 5,  weight = 32, items = { {itemID=21,rank=1},{itemID=22,rank=2} } }
describe("Math.Quality", function()
  it("thresholds", function()
    assert.same({100, 250, 400, 500}, Q.Thresholds(5, 500))
    assert.same({350, 700}, Q.Thresholds(3, 700))
    assert.same({400}, Q.Thresholds(2, 400))
    assert.same({}, Q.Thresholds(1, 100))
    assert.is_nil(Q.Thresholds(4, 100))
  end)
  it("predict", function()
    assert.same({1, 400, 0},   { Q.Predict(399, 400, 2) })
    assert.same({2, nil, 400}, { Q.Predict(400, 400, 2) })
    assert.same({3, 400, 250}, { Q.Predict(260, 500, 5) })
    assert.same({1, 100, 0},   { Q.Predict(0, 500, 5) })
  end)
  it("rank factors", function()
    assert.equals(0, Q.RankFactor(1, 2)); assert.equals(1, Q.RankFactor(2, 2))
    assert.equals(0.5, Q.RankFactor(2, 3)); assert.equals(1, Q.RankFactor(3, 3))
  end)
  it("reagent skill, 3-rank (CraftSim header example)", function()
    assert.equals(280, Q.ReagentSkill({A, B}, { {slotIndex=1,itemID=13,quantity=10}, {slotIndex=2,itemID=23,quantity=5} }, 280))
    assert.equals(157.5, Q.ReagentSkill({A, B}, { {slotIndex=1,itemID=13,quantity=5}, {slotIndex=1,itemID=12,quantity=5}, {slotIndex=2,itemID=21,quantity=5} }, 280))
  end)
  it("reagent skill, Midnight 2-rank", function()
    assert.equals(196, Q.ReagentSkill({A2, B2}, { {slotIndex=1,itemID=12,quantity=6}, {slotIndex=1,itemID=11,quantity=4}, {slotIndex=2,itemID=22,quantity=5} }, 280))
  end)
  it("all weights zero gives 0, not NaN", function()
    local z = { slotIndex = 1, quantity = 2, weight = 0, items = { {itemID=1,rank=1},{itemID=2,rank=2} } }
    assert.equals(0, Q.ReagentSkill({z}, { {slotIndex=1,itemID=2,quantity=2} }, 100))
  end)
  it("rounds half up", function() assert.equals(263, ns.Math.Round(262.5)); assert.equals(262, ns.Math.Round(262.49)) end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/math/quality_spec.lua`
Expected: FAIL — `Math/Quality.lua` not found.

- [ ] **Step 3: Implement `Math/Quality.lua`**

`Predict` walks `Thresholds` and counts thresholds with `skill >= t`; `lowerThreshold` is the threshold of the reached quality (0 for quality 1). `ReagentSkill` uses `numRanks = #slot.items`, ignores allocation rows whose `slotIndex` is not a weighted slot, and returns `maxReagentSkill × Σ w·f·n ÷ Σ w·quantity` (0 when the denominator is 0). Header credits CraftSim.

- [ ] **Step 4: Run test to verify it passes**

Run: `busted tests/math/quality_spec.lua`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Math/Quality.lua tests/math/quality_spec.lua FabricationStation.toc
git commit -m "feat: add Math.Quality thresholds, prediction and reagent skill"
```

---

### Task 3: Math.Concentration

**Files:**
- Create: `Math/Concentration.lua`
- Modify: `FabricationStation.toc`
- Test: `tests/math/concentration_spec.lua`

**Interfaces:**
- Consumes: `ns.Math.Round`.
- Produces: `ns.Math.Concentration.BASE_INGENUITY_REFUND = 0.5`; `Concentration.Cost(curve: Curve, skill, difficulty, lessFactors: {number}|nil) -> integer`; `Concentration.Expected(cost, ingenuityChance|nil, refundFraction) -> number`; `Concentration.GoldPerPoint(profitWith, profitWithout, expectedCost) -> integer|nil`.

- [ ] **Step 1: Write the failing test**

```lua
local ns = load_files({}, { "Math/Quality.lua", "Math/Concentration.lua" })
local C = ns.Math.Concentration
local MID = { constant = { {0,200},{1000,200} }, curve = { {0,2.35},{0.6,2.2},{0.8,1.1},{0.9999,1.0},{1.0,0} } }
local Q5  = { constant = { {0,150},{1000,150} }, curve = { {0,1.0},{0.1999,0.3},{0.2,1.75},{0.4999,0.7},{0.5,2.5},{0.7999,1.2},{0.8,3.25},{0.9999,1.7},{1.0,0} } }
describe("Math.Concentration", function()
  it("Midnight 2-quality curve, difficulty 400", function()
    for skill, cost in pairs({ [0]=470, [120]=455, [240]=440, [280]=330, [360]=210, [399]=200, [400]=0, [450]=0 }) do
      assert.equals(cost, C.Cost(MID, skill, 400), "skill " .. skill)
    end
  end)
  it("5-quality curve, difficulty 500", function()
    for skill, cost in pairs({ [50]=97, [175]=184, [250]=375, [300]=310, [400]=488, [499]=257, [500]=0 }) do
      assert.equals(cost, C.Cost(Q5, skill, 500), "skill " .. skill)
    end
  end)
  it("subtracts less-concentration factors before rounding", function()
    assert.equals(297, C.Cost(MID, 280, 400, {0.1}))
  end)
  it("ingenuity expectation", function()
    assert.equals(270, C.Expected(300, 0.2, 0.5))
    assert.equals(300, C.Expected(300, nil, 0.5))
  end)
  it("gold per point", function()
    assert.equals(333, C.GoldPerPoint(120000, 30000, 270))
    assert.is_nil(C.GoldPerPoint(120000, 30000, 0))
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/math/concentration_spec.lua`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement `Math/Concentration.lua`**

The bracket search and interpolation decide the curve's edge values, so they are pinned here (CraftSim `FindBracketData` + `CalculateConcentrationCost`):

```lua
local function bracket(x, pts)               -- pts sorted ascending by pts[i][1]
  for i = 1, #pts do
    if x >= pts[i][1] then
      local nxt = pts[i + 1]
      if not nxt then return pts[i], nil end
      if x <= nxt[1] then return pts[i], nxt end
    end
  end
end
function Concentration.Cost(curve, skill, difficulty, lessFactors)
  if not curve or difficulty <= 0 then return 0 end
  skill = math.min(skill, difficulty)
  local s, e = bracket(skill / difficulty, curve.curve)
  local x0, y0 = s and s[1] or 0, s and s[2] or 0
  local x1, y1 = e and e[1] or 1, e and e[2] or 1
  local k = (bracket(difficulty, curve.constant) or curve.constant[1])[2]  -- constants are flat in current data; interpolate by difficulty if the next point differs
  local skillStart, skillEnd = difficulty * x0, difficulty * x1
  local value = (skillEnd == skillStart) and y0 or y0 + (y1 - y0) * (skill - skillStart) / (skillEnd - skillStart)
  local cost = value * k
  local less = 0
  for _, f in ipairs(lessFactors or {}) do less = less + cost * f end
  return ns.Math.Round(cost - less)
end
```

`GoldPerPoint` returns `Round((profitWith - profitWithout) / expectedCost)` or nil when `expectedCost <= 0`. Header credits CraftSim.

- [ ] **Step 4: Run test to verify it passes**

Run: `busted tests/math/concentration_spec.lua`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Math/Concentration.lua tests/math/concentration_spec.lua FabricationStation.toc
git commit -m "feat: add Math.Concentration cost curve, ingenuity and gold per point"
```

---

### Task 4: Math.Stats

**Files:**
- Create: `Math/Stats.lua`
- Modify: `FabricationStation.toc`
- Test: `tests/math/stats_spec.lua`

**Interfaces:**
- Consumes: nothing.
- Produces: `ns.Math.Stats.MULTICRAFT_CONSTANTS = { default = 2.5, [1] = 2.1, [2] = 1.83, [5] = 1.875 }`; `Stats.RESOURCEFULNESS_SAVE_FACTOR = 0.30`; `Stats.RATING_PER_UNIT = { multicraft = 1100, resourcefulness = 900, ingenuity = 1000 }`; `Stats.ExpectedYield(baseYield, mcChance|nil, mcExtra|nil) -> expected, extraOnProc`; `Stats.ResourcefulnessSaving(requiredCost, resChance|nil, resExtra|nil) -> number`; `Stats.ParseBonusStats(bonusStats, names) -> { multicraft?, resourcefulness?, ingenuity? }` (fractions; `names = { multicraft = "Multicraft", resourcefulness = "Resourcefulness", ingenuity = "Ingenuity" }`; a stat with `ratingPct` 0 or absent is nil = unsupported); `Stats.ApplyOptionals(stats, optionals) -> newStats, skillBonus, difficultyBonus, lessConcentrationFactors`.

- [ ] **Step 1: Write the failing test**

```lua
local S = load_files({}, { "Math/Stats.lua" }).Math.Stats
describe("Math.Stats", function()
  it("multicraft expected yield", function()
    assert.same({1.31, 1.55}, { S.ExpectedYield(1, 0.2, 0) })
    assert.same({5.51875, 5.1875}, { S.ExpectedYield(5, 0.1, 0) })
    assert.same({3.425, 4.25}, { S.ExpectedYield(3, 0.1, 0) })      -- default constant 2.5
    assert.near(1.415, (S.ExpectedYield(1, 0.2, 0.5)), 1e-9)
    assert.same({1, 0}, { S.ExpectedYield(1, nil) })
  end)
  it("resourcefulness saving", function()
    assert.equals(3000, S.ResourcefulnessSaving(40000, 0.25, 0))
    assert.near(3300, S.ResourcefulnessSaving(40000, 0.25, 0.1), 1e-9)
    assert.equals(0, S.ResourcefulnessSaving(40000, nil))
  end)
  it("parses bonus stats by localized name", function()
    local names = { multicraft = "Multicraft", resourcefulness = "Resourcefulness", ingenuity = "Ingenuity" }
    assert.same({ multicraft = 0.125, resourcefulness = 0.2, ingenuity = 0.08 }, S.ParseBonusStats({
      { bonusStatName = "Multicraft", ratingPct = 12.5 }, { bonusStatName = "Resourcefulness", ratingPct = 20 },
      { bonusStatName = "Ingenuity", ratingPct = 8 }, { bonusStatName = "Crafting Speed", ratingPct = 30 } }, names))
    assert.same({}, S.ParseBonusStats({ { bonusStatName = "Multicraft", ratingPct = 0 } }, names))
  end)
  it("applies optional reagent effects", function()
    local stats, skill, diff, less = S.ApplyOptionals({ multicraft = 0.2 },
      { { stats = { skill = 10, increasedifficulty = 35, multicraft = 110, reduceconcentrationcost = 10 } } })
    assert.equals(10, skill); assert.equals(35, diff)
    assert.near(0.3, stats.multicraft, 1e-9); assert.same({0.1}, less)
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/math/stats_spec.lua`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement `Math/Stats.lua`**

`ExpectedYield`: `C = MULTICRAFT_CONSTANTS[baseYield] or default`; `maxExtra = C × baseYield × (1 + extra)`; `extraOnProc = (1 + maxExtra) / 2`; `expected = baseYield + chance × extraOnProc` (chance nil → `baseYield, 0`). `ApplyOptionals` copies `stats`, adds rating ÷ `RATING_PER_UNIT` (creates the stat if absent), sums `skill` and `increasedifficulty`, and turns each `reduceconcentrationcost` amount into `amount / 100` in `lessConcentrationFactors`. Header credits CraftSim.

- [ ] **Step 4: Run test to verify it passes**

Run: `busted tests/math/stats_spec.lua`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Math/Stats.lua tests/math/stats_spec.lua FabricationStation.toc
git commit -m "feat: add Math.Stats multicraft, resourcefulness and optional reagent effects"
```

---

### Task 5: Math.Optimizer

**Files:**
- Create: `Math/Optimizer.lua`
- Modify: `FabricationStation.toc`
- Test: `tests/math/optimizer_spec.lua`

**Interfaces:**
- Consumes: `Quality.Thresholds`, `Quality.RankFactor`, `Quality.DEFAULT_REAGENT_SKILL_FACTOR`.
- Produces: `ns.Math.Optimizer.Compositions(slot: MathSlot) -> { [units] = { cost, counts = {[rank] = n} } }` (units are per-slot `Σ 2·f(rank)·n`, before weighting); `Optimizer.CheapestByQuality(input: RecipeInput) -> perQuality: { [q] = { allocation, reagentCost, skill } }, missingPrice: bool` (`reagentCost` covers required slots only; unreachable qualities absent); `Optimizer.AllocationCost(slots, allocation) -> copper|nil`.

- [ ] **Step 1: Write the failing test**

```lua
local ns = load_files({}, { "Math/Quality.lua", "Math/Optimizer.lua" })
local O = ns.Math.Optimizer
local function slot(i, q, w, prices) local items = {}
  for r, p in ipairs(prices) do items[r] = { itemID = i * 1000 + r, rank = r, price = p, owned = 0, provided = 0 } end
  return { slotIndex = i, quantity = q, weight = w, items = items } end
local function input(baseSkill, slots) return { maxQuality = 2, baseDifficulty = 700, baseSkill = baseSkill, maxReagentSkill = 280, slots = slots } end
describe("Math.Optimizer", function()
  it("2-rank compositions", function()
    local c = O.Compositions(slot(1, 10, 48, {100, 300}))
    assert.equals(1000, c[0].cost); assert.equals(1400, c[4].cost); assert.equals(3000, c[20].cost)
  end)
  it("3-rank composition keeps the cheapest mix per unit count", function()
    local c = O.Compositions(slot(1, 4, 10, {10, 30, 45}))
    assert.equals(130, c[5].cost); assert.same({ [1]=1, [2]=1, [3]=2 }, c[5].counts)
  end)
  it("cheapest allocation per reachable quality", function()
    local per = O.CheapestByQuality(input(500, { slot(1, 10, 48, {100, 300}), slot(2, 5, 32, {200, 300}) }))
    assert.equals(2000, per[1].reagentCost)
    assert.equals(3800, per[2].reagentCost); assert.equals(703, per[2].skill)
    assert.same({ {slotIndex=1,itemID=1001,quantity=3}, {slotIndex=1,itemID=1002,quantity=7},
                  {slotIndex=2,itemID=2001,quantity=1}, {slotIndex=2,itemID=2002,quantity=4} }, per[2].allocation)
  end)
  it("unreachable quality is absent", function()
    assert.is_nil(O.CheapestByQuality(input(400, { slot(1, 10, 48, {100, 300}), slot(2, 5, 32, {200, 300}) }))[2])
  end)
  it("unweighted_slot_fixed", function()
    local per = O.CheapestByQuality(input(700, { slot(1, 2, 0, {500, 50}) }))
    assert.equals(100, per[2].reagentCost)                  -- cheapest priced rank, no skill
  end)
  it("missing_rank_price", function()
    local per, missing = O.CheapestByQuality(input(500, { slot(1, 10, 48, {100, nil}), slot(2, 5, 32, {200, 300}) }))
    assert.is_false(missing); assert.is_nil(per[2])         -- rank 2 of slot 1 unusable, 20/80 units not enough
    local _, missing2 = O.CheapestByQuality(input(500, { slot(1, 10, 48, {nil, nil}) }))
    assert.is_true(missing2)
  end)
  it("mixed_rank_slots", function()
    local per = O.CheapestByQuality(input(500, { slot(1, 10, 48, {100, 300}), slot(2, 4, 32, {10, 30, 45}) }))
    assert.is_table(per[2]); assert.is_true(per[2].skill >= 700)
  end)
  it("owned and provided reagents cost nothing up to their count", function()
    local s = slot(1, 10, 48, {100, 300}); s.items[2].owned = 5; s.items[1].provided = 0
    assert.equals(1100, O.Compositions(s)[10].cost)          -- 5 rank2: 5 owned free, 5 rank1 at 100... = 500? see note
  end)
end)
```

Note for the last case: with 5 rank-2 owned, the composition "5×rank2 + 5×rank1" (units 10) costs `0 + 5×100 = 500`; the asserted 1100 is wrong on purpose — fix the expected value to `500` while writing the test so the test states the rule "cost = Σ max(0, n_rank − owned_rank − provided_rank) × price".

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/math/optimizer_spec.lua`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement `Math/Optimizer.lua`**

Compositions: per slot, enumerate rank counts summing to `quantity` (2 ranks: `quantity+1` options; 3 ranks: `O(q²)`), units `= Σ 2·f(rank)·n`, keep the cheapest per units value. An item with `price == nil` may be used only up to `owned + provided`. A slot with `#items == 1` or `weight == 0` gets a single composition (cheapest usable rank) at 0 units. Provided reagents (orders) are forced: their counts are fixed.

Knapsack over all weighted slots (weights reduced by their GCD; guard GCD 0 → 1):

```lua
-- U_s(u) = u * (weight_s / g); Umax = Σ quantity_s * 2 * (weight_s / g)
local best, choice = { [0] = 0 }, {}
for s, sl in ipairs(weighted) do
  local nb, pick = {}, {}
  for u, c in pairs(best) do
    for cu, comp in pairs(sl.comps) do
      local nu, nc = u + cu * sl.w, c + comp.cost
      if nb[nu] == nil or nc < nb[nu] or (nc == nb[nu] and false) then nb[nu], pick[nu] = nc, { prev = u, comp = comp } end
    end
  end
  best, choice[s] = nb, pick
end
for q = 1, maxQuality do
  local need = (q == 1) and 0 or (thresholds[q - 1] - baseSkill)
  local uNeed = need <= 0 and 0 or math.ceil(need * Umax / maxReagentSkill - 1e-9)
  -- answer = min cost over u >= uNeed in best; ties prefer larger u (more skill → cheaper concentration)
  -- walk choice[] backwards from the chosen u to rebuild counts per slot; skill = baseSkill + maxReagentSkill * u / Umax
end
```

`maxReagentSkill` nil → `DEFAULT_REAGENT_SKILL_FACTOR × baseDifficulty`. Allocation rows are emitted in slot order then rank order, omitting zero counts; fixed (unweighted) slots are added with their cost. Header credits CraftSim's knapsack (`Modules/ReagentOptimization/ReagentOptimization.lua`).

- [ ] **Step 4: Run test to verify it passes**

Run: `busted tests/math/optimizer_spec.lua`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add Math/Optimizer.lua tests/math/optimizer_spec.lua FabricationStation.toc
git commit -m "feat: add Math.Optimizer cheapest reagent allocation per quality"
```

---

### Task 6: Math.Profit — EvaluateCraft and EvaluateAllocation

**Files:**
- Create: `Math/Profit.lua`
- Modify: `FabricationStation.toc`
- Test: `tests/math/profit_spec.lua`

**Interfaces:**
- Consumes: Tasks 2–5.
- Produces: `ns.Math.Profit.AH_CUT = 0.95`; `Profit.ExpectedSale(qualityChances, outputPrices, expectedYield) -> number|nil`; `Profit.EvaluateCraft(input: RecipeInput) -> MathResult`; `Profit.EvaluateAllocation(input: RecipeInput, allocation: ReagentAllocation) -> MathResult` (no optimisation; used for live prediction and self-check).

Rules `EvaluateCraft` follows (spec §6.1):
- Optionals: `Stats.ApplyOptionals` → `skill = baseSkill + skillBonus + reagentSkill`, `difficulty = baseDifficulty + difficultyBonus`; thresholds use `difficulty`, reagent skill uses `baseDifficulty`.
- Plans without concentration: one per reachable quality `q` from `Optimizer.CheapestByQuality`. Plans with concentration: for each reachable `q < maxQuality`, quality `q+1` at `Concentration.Cost(curve, skill_q, difficulty, less)`.
- Per plan: `reagentCost = required + optional cost`; `resourcefulnessValue = Stats.ResourcefulnessSaving(requiredCost, ...)`; `expectedSale = ExpectedSale({[q]=1}, outputPrices, ExpectedYield(...))`; `profit = expectedSale − (reagentCost − resourcefulnessValue)`; `multicraftValue = price_q × (expectedYield − baseYield) × AH_CUT`, `baseYield = (min + max) / 2`.
- `targetQuality` set → use that quality's plan (with concentration when `useConcentration`); else the max-profit plan of the requested kind. A plan whose output price is nil has `expectedSale = nil`, `profit = nil`, `missingPrice = true`, and never wins over a priced plan.
- `goldPerConcentration` = `GoldPerPoint(best concentration plan profit, best non-concentration plan profit, Expected(cost, ingenuity, 0.5 + ingenuityExtra))`; `concentrationCost`, `expectedConcentrationCost` and `ingenuityValue = cost × ingenuity × (0.5 + extra)` describe that concentration plan; all 0/nil when no concentration plan exists or `curve` is nil.
- Copper outputs pass through `Round`.

- [ ] **Step 1: Write the failing test**

```lua
local ns = load_files({}, { "Math/Quality.lua","Math/Concentration.lua","Math/Stats.lua","Math/Optimizer.lua","Math/Profit.lua" })
local P = ns.Math.Profit
local MID = { constant = { {0,200},{1000,200} }, curve = { {0,2.35},{0.6,2.2},{0.8,1.1},{0.9999,1.0},{1.0,0} } }
local function slot(i, q, w, prices) local items = {}
  for r, p in ipairs(prices) do items[r] = { itemID = i * 1000 + r, rank = r, price = p, owned = 0, provided = 0 } end
  return { slotIndex = i, quantity = q, weight = w, items = items } end
local function scenario(over) local t = { maxQuality = 2, baseDifficulty = 700, baseSkill = 500, maxReagentSkill = 280,
  slots = { slot(1,10,48,{100,300}), slot(2,5,32,{200,300}), slot(3,2,0,{500}) }, optionals = {},
  stats = { multicraft = 0.2, resourcefulness = 0.25, ingenuity = 0.2 }, yield = { min = 1, max = 1 },
  outputPrices = { [1] = 60000, [2] = 100000 }, concentration = { curve = MID, lessFactors = {} } }
  for k, v in pairs(over or {}) do t[k] = v end; return t end
describe("Math.Profit.EvaluateCraft", function()
  it("picks the most profitable plan without concentration", function()
    local r = P.EvaluateCraft(scenario())
    assert.equals(2, r.expectedQuality); assert.same({ [2] = 1 }, r.qualityChances)
    assert.equals(4800, r.reagentCost); assert.equals(124450, r.expectedSale)
    assert.equals(360, r.resourcefulnessValue); assert.equals(120010, r.profit)
    assert.equals(29450, r.multicraftValue); assert.near(1.31, r.expectedYield, 1e-9)
    assert.equals(71895, r.perQuality[1].profit)
  end)
  it("prices the concentration alternative", function()
    local r = P.EvaluateCraft(scenario())
    assert.equals(314, r.concentrationCost); assert.near(282.6, r.expectedConcentrationCost, 1e-9)
    assert.near(31.4, r.ingenuityValue, 1e-9); assert.equals(6, r.goldPerConcentration)   -- (121675 − 120010) / 282.6
  end)
  it("uses concentration when asked", function()
    local r = P.EvaluateCraft(scenario({ useConcentration = true }))
    assert.equals(2, r.expectedQuality); assert.equals(3000, r.reagentCost); assert.equals(121675, r.profit)
  end)
  it("honours targetQuality", function()
    assert.equals(71895, P.EvaluateCraft(scenario({ targetQuality = 1 })).profit)
  end)
  it("missing output price is flagged, never zero", function()
    local r = P.EvaluateCraft(scenario({ outputPrices = { [1] = 60000 } }))
    assert.equals(1, r.expectedQuality); assert.is_true(r.missingPrice)
    local r2 = P.EvaluateCraft(scenario({ outputPrices = {} }))
    assert.is_nil(r2.profit); assert.is_true(r2.missingPrice)
  end)
  it("EvaluateAllocation predicts a given allocation", function()
    local r = P.EvaluateAllocation(scenario(), { {slotIndex=1,itemID=1002,quantity=10}, {slotIndex=2,itemID=2002,quantity=5}, {slotIndex=3,itemID=3001,quantity=2} })
    assert.equals(780, r.skill); assert.equals(2, r.expectedQuality); assert.equals(5500, r.reagentCost)
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/math/profit_spec.lua`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement `Math/Profit.lua`** following the rules above.

- [ ] **Step 4: Run all math specs**

Run: `busted tests/math && luacheck Math`
Expected: PASS (all math specs); luacheck 0 warnings; `grep -nE "C_[A-Z]|ns\.FS|_G\b" Math/*.lua` prints nothing.

- [ ] **Step 5: Commit**

```bash
git add Math/Profit.lua tests/math/profit_spec.lua FabricationStation.toc
git commit -m "feat: add Math.Profit expected profit and concentration evaluation"
```

---

### Task 7: Recipes — settings, calibration, reagent-info conversion, mismatch log

**Files:**
- Create: `Modules/Recipes.lua`, `tests/helpers/crafting_world.lua`
- Modify: `FabricationStation.toc`
- Test: `tests/recipes/calibration_spec.lua`

**Interfaces:**
- Consumes: `ns.FS:CharKey()`, `ns.FS:Now()`, `ns.FS:RegisterOptions(key, group)`, `Scanner:GetSchematic(recipeID)`, `Scanner:GetLiveOperationInfo(recipeID, allocation: ReagentAllocation, applyConcentration)`, `C_TradeSkillUI.GetRecipeSchematic(recipeID, false)` (live, for `dataSlotIndex`/`dataSlotType`), `Stats.ParseBonusStats`.
- Produces:
  - `Recipes.DEFAULTS = { ownedReagentsFree = false, stalePriceDays = 3, staleCalibrationDays = 14, queueUseWarband = true, professionPanel = true, recipeListLabels = true, tooltipCraftCost = true, applyWritesBlizzardSlots = true, selfCheck = true, recordMathFixtures = false, scanBudgetMs = 4 }`; `Recipes:GetSetting(key)`; options group `"crafting"` with one toggle/range per key.
  - `Recipes.STAT_NAMES = { multicraft = "Multicraft", resourcefulness = "Resourcefulness", ingenuity = "Ingenuity" }` (enUS; other locales later).
  - `Recipes:Calibrate(recipeID) -> CalibRecord|nil` — current character, window open; three live calls: empty allocation, every quality slot at top rank, both with `applyConcentration = false`. Stores under `db.global.recipeCalib[charKey][recipeID]` and bumps that character's data stamp.
  - `Recipes:GetCalibration(charKey, recipeID) -> CalibRecord|nil`.
  - `Recipes:ToCraftingReagentInfo(recipeID, allocation, optionalItemIDs|nil) -> { { reagent = { itemID }, dataSlotIndex, quantity } }` — only `ModifiedReagent` slots; nil when no live schematic.
  - `Recipes:FromCraftingReagentInfo(recipeID, infos) -> allocation, optionalItemIDs`.
  - `Recipes:LogMismatch(record)` — appends `{ time, recipeID, charKey, field, predicted, actual, fixture }` to `db.global.diagnostics.mismatches`, keeps the newest 200.
  - Test helper `make_world(opts) -> ns, world` (loads Core + Math + listed files, installs fake `Scanner`/`Prices` AceModules backed by `world` tables: `world.schematics`, `world.chars`, `world.items`, `world.prices`, `world.live`); `world.recipe9001` is the Task 6 scenario as a Schematic (`outputItemIDs = {[1]=5001,[2]=5002}`, slots 1–3 with items 1001/1002, 2001/2002, 3001, weights 48/32/0 in a fake `ns.GameData.Crafting.reagentWeights`, curve under `craftingDataID` 2588).

- [ ] **Step 1: Write the failing test**

```lua
describe("Recipes calibration", function()
  local ns, world, R
  before_each(function()
    ns, world = make_world({ files = { "Modules/Recipes.lua" } })
    R = ns.FS:GetModule("Recipes")
    world.live[9001] = function(allocation)                 -- fake GetLiveOperationInfo
      local top = #allocation > 0
      return { baseSkill = 480, bonusSkill = 20 + (top and 280 or 0), baseDifficulty = 700, bonusDifficulty = 0,
        craftingDataID = 2588, concentrationCost = 314, ingenuityRefund = 157,
        bonusStats = { { bonusStatName = "Multicraft", ratingPct = 20 }, { bonusStatName = "Ingenuity", ratingPct = 20 } } }
    end
  end)
  it("stores base skill, max reagent skill and stats", function()
    local c = R:Calibrate(9001)
    assert.equals(500, c.baseSkill); assert.equals(280, c.maxReagentSkill); assert.equals(700, c.baseDifficulty)
    assert.equals(2588, c.craftingDataID); assert.same({ multicraft = 0.2, ingenuity = 0.2 }, c.stats)
    assert.equals(c, R:GetCalibration("Main-Realm", 9001))
  end)
  it("returns nil when the window is closed", function()
    world.live[9001] = nil
    assert.is_nil(R:Calibrate(9001))
  end)
  it("converts allocation to Midnight CraftingReagentInfo, ModifiedReagent slots only", function()
    world.liveSchematic[9001] = { reagentSlotSchematics = {
      { slotIndex = 1, dataSlotIndex = 4, dataSlotType = 2 }, { slotIndex = 2, dataSlotIndex = 5, dataSlotType = 2 },
      { slotIndex = 3, dataSlotIndex = 6, dataSlotType = 1 } } }
    local infos = R:ToCraftingReagentInfo(9001, { {slotIndex=1,itemID=1002,quantity=7}, {slotIndex=3,itemID=3001,quantity=2} })
    assert.same({ { reagent = { itemID = 1002 }, dataSlotIndex = 4, quantity = 7 } }, infos)
    assert.same({ {slotIndex=1,itemID=1002,quantity=7} }, (R:FromCraftingReagentInfo(9001, infos)))
  end)
  it("caps the mismatch log at 200", function()
    for i = 1, 205 do R:LogMismatch({ recipeID = i, field = "quality", predicted = 1, actual = 2 }) end
    local m = ns.FS.db.global.diagnostics.mismatches
    assert.equals(200, #m); assert.equals(6, m[1].recipeID)
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/recipes/calibration_spec.lua`
Expected: FAIL — `make_world`/`Modules/Recipes.lua` missing.

- [ ] **Step 3: Implement `tests/helpers/crafting_world.lua` and `Modules/Recipes.lua`** (Interfaces above). The top-rank allocation for calibration is every slot with `#reagents >= 2` filled with its last reagent at `quantity`. `maxReagentSkill` is nil when there are no such slots.

- [ ] **Step 4: Run test to verify it passes**

Run: `busted tests/recipes/calibration_spec.lua`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Modules/Recipes.lua tests/helpers/crafting_world.lua tests/recipes/calibration_spec.lua FabricationStation.toc
git commit -m "feat: add Recipes calibration, reagent info conversion and mismatch log"
```

---

### Task 8: Recipes:Evaluate, cache, WhoCanCraft, FindRecipesForItem

**Files:**
- Modify: `Modules/Recipes.lua`
- Test: `tests/recipes/evaluate_spec.lua`

**Interfaces:**
- Consumes: Task 7; `Scanner:GetCharacters()`, `Scanner:GetCharacter(charKey)`, `Scanner:GetProfession(charKey, skillLineID)`, `Scanner:GetItemCount(itemID, charKey)`, `Prices:Get(itemID)`, `Prices:GetVersion()`, `ns.GameData.Crafting`, `Profit.EvaluateCraft`, `Profit.EvaluateAllocation`; messages `FS_PRICES_CHANGED`, `FS_DATA_CHANGED`.
- Produces: `Recipes:BuildMathInput(recipeID, charKey, opts) -> RecipeInput|nil, flags`; `Recipes:Evaluate(recipeID, charKey, opts) -> RecipeResult` (contract); `Recipes:PredictLive(recipeID, allocation, optionalItemIDs, applyConcentration) -> MathResult|nil` (current character); `Recipes:WhoCanCraft(recipeID) -> { charKey }` (contract; sorted); `Recipes:FindRecipesForItem(itemID) -> { { recipeID, quality } }`; `Recipes:GetDataStamp(charKey) -> integer`.

Input building: `baseSkill`, `baseDifficulty`, `maxReagentSkill`, `stats` and curve (`concentrationCurves[calib.craftingDataID]`) come from the calibration. Without one: `baseSkill = profession.skill`, `baseDifficulty = schematic.baseDifficulty`, `maxReagentSkill = nil`, `stats = {}`, curve nil, `flags.staleData = true`, `flags.estimated = true`. Calibration older than `staleCalibrationDays` or a character whose `lastSeen` is older → `flags.staleData = true`. Item prices from `Prices:Get(itemID).value`; any price used with `ageDays > stalePriceDays` → `flags.stalePrice`; `priceAgeDays` = max age used. `ownedReagentsFree` → `owned = bags + bank + reagentBank + warband` of that character; `providedReagents` → `provided`. Recipe not in `profession.recipes` → `flags.unknownRecipe = true` (still evaluated). `flags.noPrice = result.missingPrice`.

Cache: key `recipeID .. "|" .. charKey .. "|" .. optsKey(opts)` (opts serialised with sorted keys); entry valid while `Prices:GetVersion()` and `GetDataStamp(charKey)` are unchanged. `FS_DATA_CHANGED(charKey, kind)` bumps that character's stamp, except `kind == "items"` bumps it only when `ownedReagentsFree` is on (queue-missing math reads counts directly). `FS_PRICES_CHANGED` needs no handler (version is in the check).

- [ ] **Step 1: Write the failing test**

```lua
describe("Recipes:Evaluate", function()
  local ns, world, R
  before_each(function()
    ns, world = make_world({ files = { "Modules/Recipes.lua" }, calibrate = { ["Main-Realm"] = { 9001 } } })
    R = ns.FS:GetModule("Recipes")
  end)
  it("joins scanner, prices and math", function()
    local r = R:Evaluate(9001, "Main-Realm", {})
    assert.equals(9001, r.recipeID); assert.equals("Main-Realm", r.charKey)
    assert.equals(2, r.expectedQuality); assert.equals(120010, r.profit); assert.equals(6, r.goldPerConcentration)
    assert.same({ noPrice = false, stalePrice = false, staleData = false, unknownRecipe = false, estimated = false }, r.flags)
  end)
  it("estimates_without_calibration", function()
    local r = R:Evaluate(9001, "Alt-Realm", {})                 -- Alt knows 9001, profession skill 500, never calibrated
    assert.is_true(r.flags.staleData); assert.is_true(r.flags.estimated)
    assert.equals(280, r.perQuality[2] and (r.perQuality[2].skill - 500) and 280 or 280) -- maxReagentSkill = 0.40 × 700
    assert.is_nil(r.goldPerConcentration)                       -- no curve without craftingDataID
  end)
  it("flags stale and missing prices", function()
    world.prices[5002] = { value = 100000, source = "auction", ageDays = 5 }
    assert.is_true(R:Evaluate(9001, "Main-Realm", {}).flags.stalePrice)
    world.prices[5001], world.prices[5002] = nil, nil; world.bumpPriceVersion()
    local r = R:Evaluate(9001, "Main-Realm", {})
    assert.is_true(r.flags.noPrice); assert.is_nil(r.profit)
  end)
  it("costs owned reagents at zero when the setting is on", function()
    world.items["Main-Realm"][1001] = { bags = 10, bank = 0, reagentBank = 0, warband = 0 }
    ns.FS.db.global.settings.crafting = { ownedReagentsFree = true }
    assert.equals(2000, R:Evaluate(9001, "Main-Realm", { targetQuality = 1 }).reagentCost)  -- 3000 − 10×100
  end)
  it("caches until price version or data stamp changes", function()
    local a = R:Evaluate(9001, "Main-Realm", {}); assert.equals(a, R:Evaluate(9001, "Main-Realm", {}))
    world.bumpPriceVersion(); assert.are_not.equal(a, R:Evaluate(9001, "Main-Realm", {}))
    local b = R:Evaluate(9001, "Main-Realm", {})
    ns.FS:SendMessage("FS_DATA_CHANGED", "Main-Realm", "spec"); assert.are_not.equal(b, R:Evaluate(9001, "Main-Realm", {}))
  end)
  it("finds crafters and recipes for an item", function()
    assert.same({ "Alt-Realm", "Main-Realm" }, R:WhoCanCraft(9001))
    assert.same({ { recipeID = 9001, quality = 2 } }, R:FindRecipesForItem(5002))
    assert.same({}, R:FindRecipesForItem(424242))
  end)
end)
```

Replace the placeholder assert in `estimates_without_calibration` with: `assert.equals(780, R:Evaluate(9001, "Alt-Realm", { targetQuality = 2 }).perQuality[2].skill)`? No — use the exact rule: with base skill 500 and default max reagent skill 280 the q2 plan has skill 703, so `assert.equals(703, r.perQuality[2].skill)`.

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/recipes/evaluate_spec.lua`
Expected: FAIL — `Evaluate` undefined.

- [ ] **Step 3: Implement** the Interfaces above in `Modules/Recipes.lua`. `FindRecipesForItem` builds a reverse index from every known schematic's `outputItemIDs` once and rebuilds it on `FS_DATA_CHANGED(_, "recipes")`.

- [ ] **Step 4: Run test to verify it passes**

Run: `busted tests/recipes`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Modules/Recipes.lua tests/recipes/evaluate_spec.lua
git commit -m "feat: add Recipes:Evaluate with flags, caching, WhoCanCraft and item lookup"
```

---

### Task 9: Golden fixtures — recorder, exporter, golden spec, pin constants

This task validates the Math against the game before any UI is built on it.

**Files:**
- Modify: `Modules/Recipes.lua` (recorder)
- Create: `tools/export_math_fixtures.lua`, `tests/math/golden_spec.lua`, `tests/fixtures/math/index.lua`, `tests/fixtures/math/*.lua`
- Modify (only if fixtures disagree): `Math/*.lua` constants
- Test: `tests/math/golden_spec.lua`, `tests/recipes/recorder_spec.lua`

**Interfaces:**
- Consumes: `Recipes:Calibrate`, `Recipes:FromCraftingReagentInfo`, `Recipes:BuildMathInput`, `Profit.EvaluateAllocation`, `EventRegistry` `"ProfessionsRecipeListMixin.Event.OnRecipeSelected"`, `ProfessionsFrame.CraftingPage.SchematicForm:GetTransaction():CreateCraftingReagentInfoTbl()`.
- Produces: `Recipes:RecordFixture(recipeID) -> MathFixture|nil` — when `recordMathFixtures` is on, called on recipe selection and on `AllocationsModified`; appends to `db.global.captures.math`. `MathFixture = { build, recipeID, charKey, calib = CalibRecord, input = RecipeInput, allocation, optionalItemIDs, live = { skill = baseSkill+bonusSkill, difficulty = baseDifficulty+bonusDifficulty, quality, craftingQuality, lowerSkillThreshold, upperSkillTreshold, concentrationCost, ingenuityRefund, bonusStats } }`. `lua tools/export_math_fixtures.lua <path to FabricationStation.lua SavedVariables> tests/fixtures/math` writes one file per fixture (`<recipeID>_<n>.lua`, `return { ... }`) and `index.lua` listing them; it also exports fixtures attached to mismatch records.

- [ ] **Step 1: Write the failing tests**

`tests/recipes/recorder_spec.lua`: with `recordMathFixtures = true` and a fake live op info, `R:RecordFixture(9001)` appends one fixture whose `live.skill == 780` for the top-rank allocation and whose `input.baseSkill == 500`; with the setting off it returns nil and appends nothing.

`tests/math/golden_spec.lua`:

```lua
local ns = load_files({}, { "Math/Quality.lua","Math/Concentration.lua","Math/Stats.lua","Math/Optimizer.lua","Math/Profit.lua" })
local index = dofile("tests/fixtures/math/index.lua")
describe("golden fixtures", function()
  if #index == 0 then pending("no fixtures captured yet — see Task 9 Step 4") end
  for _, name in ipairs(index) do
    it(name, function()
      local f = dofile("tests/fixtures/math/" .. name)
      local r = ns.Math.Profit.EvaluateAllocation(f.input, f.allocation)
      assert.near(f.live.skill, r.skill, 0.5)
      assert.equals(f.live.difficulty, r.difficulty)
      assert.equals(f.live.craftingQuality, r.expectedQuality)
      assert.equals(f.live.lowerSkillThreshold, r.lowerThreshold)
      if r.nextThreshold then assert.equals(f.live.upperSkillTreshold, r.nextThreshold) end
      if f.live.concentrationCost > 0 and f.input.concentration.curve then
        assert.equals(f.live.concentrationCost, r.concentrationCostForAllocation)
      end
    end)
  end
end)
```

`EvaluateAllocation` exposes `concentrationCostForAllocation` = `Concentration.Cost` at the allocation's skill (add to Task 6's MathResult when implementing this step).

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted tests/recipes/recorder_spec.lua tests/math/golden_spec.lua`
Expected: FAIL — `RecordFixture` undefined; golden spec errors on missing `index.lua`.

- [ ] **Step 3: Implement recorder and exporter; commit an empty `index.lua` (`return {}`)**

Run: `busted tests/recipes/recorder_spec.lua tests/math/golden_spec.lua`
Expected: recorder PASS; golden spec 1 pending.

- [ ] **Step 4: Capture real fixtures in game (manual)**

Load the addon, set `recordMathFixtures` on in Settings › Crafting, and on at least two professions per character type open: (a) a Midnight recipe with quality reagents, all rank 1; (b) same recipe all rank 2; (c) a mixed allocation just under and just over the quality-2 threshold; (d) a recipe with a difficulty-raising optional reagent; (e) a recipe with a finishing reagent that adds skill or ingenuity; (f) one 5-quality gear recipe if any exists. `/reload`, then:

Run: `lua tools/export_math_fixtures.lua "<WoW>/_retail_/WTF/Account/<ACCOUNT>/SavedVariables/FabricationStation.lua" tests/fixtures/math && busted tests/math/golden_spec.lua`
Expected: ≥ 6 fixtures exported; note every failing assertion.

- [ ] **Step 5: Pin the unverified constants from the failures**

For each failure decide from the fixture numbers, change only the named constant or rounding, and add a comment naming the fixture that proves it: reagent-skill rounding (`Quality.ReagentSkill` none/floor/round); `maxReagentSkill` basis (base vs total difficulty); `Concentration.Cost` rounding; `craftingQuality` vs `quality` (switch the golden assert and `SelfCheck` field); optional-reagent rating divisors and `reduceconcentrationcost` scaling; ingenuity refund fraction (compare `live.ingenuityRefund / live.concentrationCost` with `0.5 + extra`). Multicraft constants and the 0.30 resourcefulness factor cannot be checked against op info; leave them and keep the comment "CraftSim approximation".

Run: `busted`
Expected: all specs PASS, golden spec green on every fixture.

- [ ] **Step 6: Commit**

```bash
git add Modules/Recipes.lua Math/ tools/export_math_fixtures.lua tests/math/golden_spec.lua tests/recipes/recorder_spec.lua tests/fixtures/math/
git commit -m "test: add golden math fixtures from live operation info and pin constants"
```

---

### Task 10: Recipe scan (time-sliced) and GetRanked

**Files:**
- Create: `Modules/RecipeScan.lua`
- Modify: `FabricationStation.toc`
- Test: `tests/recipes/scan_spec.lua`

**Interfaces:**
- Consumes: `Recipes:Evaluate`, `Recipes:Calibrate`, `Scanner:GetCharacters/GetCharacter/GetProfession`, `debugprofilestop()`, `CreateFrame` (driver frame), `C_TradeSkillUI.GetAllRecipeIDs()`, `C_TradeSkillUI.GetBaseProfessionInfo()`; messages `FS_PRICES_CHANGED`, `FS_DATA_CHANGED`.
- Produces: `Recipes:StartScan(charKey|nil)` (nil = every character); `Recipes:IsScanning() -> bool`; `Recipes:_ScanStep(budgetMs) -> done: bool` (one frame's work; the driver calls it from `OnUpdate` with `GetSetting("scanBudgetMs")`); `Recipes:GetRanked(filter) -> { RecipeResult }` (contract); sends `FS_RECIPES_CHANGED` once per completed pass. `FS_PRICES_CHANGED` → `StartScan(nil)`; `FS_DATA_CHANGED(charKey)` → `StartScan(charKey)` (debounced 1 s via `ns.FS:Debounce`). A `StartScan` while scanning marks the pass dirty; the scan restarts once after the pass completes. When `ProfessionsFrame` is shown for the current character, the pass first calibrates that profession's learned recipes (same coroutine, same budget).

`GetRanked`: filter `{ skillLineID?, charKey?, minQuality?, usesConcentration?, onlyProfitable?, sortBy = "profit"|"goldPerConcentration" }`. `usesConcentration` keeps results with `goldPerConcentration ~= nil`. Results with `flags.noPrice` (or nil sort key) come after all priced results, ordered by recipeID; `onlyProfitable` drops them and anything with `profit <= 0`.

- [ ] **Step 1: Write the failing test**

```lua
describe("recipe scan", function()
  local ns, world, R, clock
  before_each(function()
    ns, world = make_world({ files = { "Modules/Recipes.lua", "Modules/RecipeScan.lua" }, recipes = 10 })  -- 10 known recipes on Main
    R = ns.FS:GetModule("Recipes"); clock = 0
    _G.debugprofilestop = function() clock = clock + 1; return clock end   -- every call costs 1 ms
  end)
  it("is time-sliced and announces once", function()
    local sent = spy.on(ns.FS, "SendMessage")
    R:StartScan(nil)
    local steps = 0
    repeat steps = steps + 1 until R:_ScanStep(4) or steps > 50
    assert.is_true(steps >= 3); assert.is_false(R:IsScanning())
    assert.spy(sent).was.called_with(match._, "FS_RECIPES_CHANGED")
    assert.equals(1, #world.messages("FS_RECIPES_CHANGED"))
  end)
  it("ranks by profit with unpriced results last", function()
    world.prices[world.outputOf(3)] = nil
    R:StartScan(nil); repeat until R:_ScanStep(1000)
    local ranked = R:GetRanked({ sortBy = "profit" })
    for i = 2, #ranked - 1 do assert.is_true(ranked[i - 1].profit >= ranked[i].profit) end
    assert.is_true(ranked[#ranked].flags.noPrice)
    for _, r in ipairs(R:GetRanked({ sortBy = "profit", onlyProfitable = true })) do assert.is_true(r.profit > 0) end
  end)
  it("restarts once when data changes mid-scan", function()
    R:StartScan(nil); R:_ScanStep(2); R:StartScan("Main-Realm")
    repeat until R:_ScanStep(1000) and not R:IsScanning()
    assert.equals(2, #world.messages("FS_RECIPES_CHANGED"))
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/recipes/scan_spec.lua`
Expected: FAIL — `StartScan` undefined.

- [ ] **Step 3: Implement `Modules/RecipeScan.lua`** with a coroutine that yields when `debugprofilestop() - start >= budgetMs` after each `Evaluate`. Default opts per result: `{}` (best plan, no concentration).

- [ ] **Step 4: Run test to verify it passes**

Run: `busted tests/recipes`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Modules/RecipeScan.lua tests/recipes/scan_spec.lua FabricationStation.toc
git commit -m "feat: add time-sliced recipe scan and GetRanked"
```

---

### Task 11: Queue core — entries, restock, missing reagents, costs

**Files:**
- Create: `Modules/Queue.lua`
- Modify: `FabricationStation.toc`
- Test: `tests/queue/queue_spec.lua`

**Interfaces:**
- Consumes: `Recipes:Evaluate`, `Recipes:FindRecipesForItem`, `Recipes:WhoCanCraft`, `Recipes:GetSetting("queueUseWarband")`, `Scanner:GetItemCount(itemID, charKey)`.
- Produces (contract + additions): `Queue:Add(entry) -> id`; `Queue:Remove(id)`; `Queue:GetEntries() -> { QueueEntry }` where `QueueEntry = { id, recipeID, quantity, charKey, targetQuality?, useConcentration?, orderID?, isRestock?, itemID? }` (real entries first in insertion order, then restock entries with `id = "restock:<itemID>"`); `Queue:SetRestock(itemID, target|nil)`; `Queue:GetRestockTargets() -> { [itemID] = target }`; `Queue:SetQuantity(id, n)` (n ≤ 0 removes); `Queue:Clear()` (real entries only); `Queue:GetMissingReagents(charKey|nil) -> { [itemID] = qty }`; `Queue:GetEntryMissing(id) -> { [itemID] = qty }`; `Queue:GetEntryCost(id) -> copper|nil`. Sends `FS_QUEUE_CHANGED` on every change. Recomputes on `FS_RECIPES_CHANGED`/`FS_DATA_CHANGED` (no message storm: one `FS_QUEUE_CHANGED` per debounce).

Rules:
- Per-craft requirement of an entry = `Recipes:Evaluate(recipeID, charKey, { targetQuality, useConcentration, providedReagents }).allocation` (provided reagents of an order are not required).
- Restock: for each target, `held = Scanner:GetItemCount(itemID, nil).total`; recipe/quality from `FindRecipesForItem` (first); crafter = `WhoCanCraft` member with the highest `Evaluate(..., {targetQuality = quality}).profit` (ties → first); `crafts = ceil((target − held) / expectedYield) − queued real crafts of that recipe and quality`; entry only when `crafts > 0`.
- Missing for one character: `max(0, required − (bags + bank + reagentBank))`; then the warband pool (`GetItemCount(itemID, charKey).warband`) is subtracted once across all characters when `queueUseWarband` is on.

- [ ] **Step 1: Write the failing test**

```lua
describe("Queue", function()
  local ns, world, Q
  before_each(function()
    ns, world = make_world({ files = { "Modules/Recipes.lua", "Modules/Queue.lua" } })
    world.fakeEvaluate(9001, { allocation = { {slotIndex=1,itemID=1001,quantity=2}, {slotIndex=2,itemID=2002,quantity=1} },
                               reagentCost = 900, expectedYield = 1.31, profit = 5000 })
    Q = ns.FS:GetModule("Queue")
  end)
  it("adds, lists, removes", function()
    assert.equals(1, Q:Add({ recipeID = 9001, quantity = 3, charKey = "Alt-Realm" }))
    assert.equals(2, Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" }))
    Q:Remove(1); assert.equals(1, #Q:GetEntries()); assert.equals(2, Q:GetEntries()[1].id)
  end)
  it("computes missing reagents with the warband pool counted once", function()
    Q:Add({ recipeID = 9001, quantity = 3, charKey = "Alt-Realm" }); Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
    world.items["Alt-Realm"][1001] = { bags = 4, bank = 0, reagentBank = 0 }
    world.warband[1001], world.warband[2002] = 1, 2
    assert.same({ [1001] = 1, [2002] = 1 }, Q:GetMissingReagents("Alt-Realm"))
    assert.same({ [1001] = 3, [2002] = 1 }, Q:GetMissingReagents(nil))
    ns.FS.db.global.settings.crafting = { queueUseWarband = false }
    assert.same({ [1001] = 2, [2002] = 3 }, Q:GetMissingReagents("Alt-Realm"))
  end)
  it("tops up restock targets", function()
    world.counts[5002] = 12; Q:SetRestock(5002, 20)
    local e = Q:GetEntries()[1]
    assert.same({ id = "restock:5002", isRestock = true, itemID = 5002, recipeID = 9001, quantity = 7, targetQuality = 2 },
      { id = e.id, isRestock = e.isRestock, itemID = e.itemID, recipeID = e.recipeID, quantity = e.quantity, targetQuality = e.targetQuality })
    Q:Add({ recipeID = 9001, quantity = 3, charKey = e.charKey, targetQuality = 2 })
    assert.equals(4, Q:GetEntries()[2].quantity)
    Q:SetRestock(5002, nil); assert.equals(1, #Q:GetEntries())
  end)
  it("entry cost is per-craft cost × quantity, nil without price", function()
    local id = Q:Add({ recipeID = 9001, quantity = 3, charKey = "Alt-Realm" })
    assert.equals(2700, Q:GetEntryCost(id))
    world.fakeEvaluate(9001, { allocation = {}, reagentCost = nil, flags = { noPrice = true } })
    assert.is_nil(Q:GetEntryCost(id))
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/queue/queue_spec.lua`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement `Modules/Queue.lua`** per the rules above. Storage: `db.global.queue = { entries = {}, restock = {}, nextID = 1 }`.

- [ ] **Step 4: Run test to verify it passes**

Run: `busted tests/queue`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Modules/Queue.lua tests/queue/queue_spec.lua FabricationStation.toc
git commit -m "feat: add Queue entries, restock targets and missing reagents"
```

---

### Task 12: Queue — shopping list, Craft Next, cooldowns

**Files:**
- Create: `Modules/QueueCraft.lua`
- Modify: `FabricationStation.toc`
- Test: `tests/queue/craft_spec.lua`

**Interfaces:**
- Consumes: Task 11; `Prices:AuctionatorAPI()`; `Scanner:GetSchematic`, `Scanner:GetProfession(charKey, skillLineID).cooldowns[recipeID]` (expected `{ readyAt = serverSeconds, charges?, maxCharges? }` — if 1a stored another shape, adapt only `GetCooldownReadyAt`); `Recipes:ToCraftingReagentInfo`; `C_Item.GetItemNameByID`, `C_Item.RequestLoadItemDataByID`; `C_TradeSkillUI.CraftRecipe`, `C_TradeSkillUI.GetProfessionInfoByRecipeID`, `C_TradeSkillUI.GetBaseProfessionInfo`; event `TRADE_SKILL_ITEM_CRAFTED_RESULT`.
- Produces: `Queue:ExportShoppingList() -> ok: bool, info: { added = n, skipped = n } | "noAuctionator" | "empty"` (contract name); `Queue:CraftNext() -> CraftNextResult` where `CraftNextResult = { status = "crafted"|"open"|"missing"|"cooldown"|"empty", entryID?, charKey?, skillLineID?, missing?, readyAt? }`; `Queue:GetCooldownReadyAt(entry) -> serverSeconds|nil`; `Queue:IsProfessionOpenFor(entry) -> bool`.

Craft Next order: walk `GetEntries()`; skip entries whose cooldown is not ready; the first entry that is on the current character, has its profession open (`ProfessionsFrame:IsShown()` and `GetProfessionInfoByRecipeID(recipeID).parentProfessionID == GetBaseProfessionInfo().professionID`), and has no missing reagents for one craft is crafted: `C_TradeSkillUI.CraftRecipe(recipeID, 1, Recipes:ToCraftingReagentInfo(recipeID, allocation), nil, orderID, useConcentration and true or false)`. The entry is remembered as pending; quantity drops by 1 on the next `TRADE_SKILL_ITEM_CRAFTED_RESULT` whose `itemID` is one of that recipe's outputs (multicraft results of one craft count once per `operationID`). If no entry is craftable, report the first blocking reason in queue order: other character/profession → `"open"`; missing → `"missing"`; all on cooldown → `"cooldown"` with the earliest `readyAt`.

- [ ] **Step 1: Write the failing test**

```lua
describe("Queue craft actions", function()
  local ns, world, Q, api
  before_each(function()
    ns, world = make_world({ files = { "Modules/Recipes.lua", "Modules/Queue.lua", "Modules/QueueCraft.lua" } })
    world.fakeEvaluate(9001, { allocation = { {slotIndex=1,itemID=1001,quantity=2}, {slotIndex=2,itemID=2002,quantity=1} }, reagentCost = 900 })
    api = world.fakeAuctionator()                              -- records ConvertToSearchString / CreateShoppingList calls
    Q = ns.FS:GetModule("Queue")
  end)
  it("exports exact items with quantity and rank tier", function()
    world.names[1001], world.names[2002] = "Bright Ore", "Glimmer Dust"
    Q:Add({ recipeID = 9001, quantity = 3, charKey = "Main-Realm" })
    assert.is_true((Q:ExportShoppingList()))
    assert.same({ searchString = "Bright Ore", isExact = true, quantity = 6, tier = 1 }, api.terms[1])
    assert.same({ searchString = "Glimmer Dust", isExact = true, quantity = 3, tier = 2 }, api.terms[2])
    assert.same({ "FabricationStation", "FabricationStation" }, { api.lists[1].caller, api.lists[1].name })
  end)
  it("skips_uncached_names", function()
    world.names[1001] = "Bright Ore"                           -- 2002 not cached
    Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
    local ok, info = Q:ExportShoppingList()
    assert.is_true(ok); assert.same({ added = 1, skipped = 1 }, info)
    assert.same({ 2002 }, world.loadRequests)
  end)
  it("reports missing Auctionator", function()
    world.noAuctionator(); Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
    assert.same({ false, "noAuctionator" }, { Q:ExportShoppingList() })
  end)
  it("craft_next_window_closed", function()
    Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
    local r = Q:CraftNext()
    assert.equals("open", r.status); assert.equals("Main-Realm", r.charKey); assert.equals(0, #world.crafts)
  end)
  it("craft_next_other_character", function()
    world.openProfession(9001); Q:Add({ recipeID = 9001, quantity = 1, charKey = "Alt-Realm" })
    assert.same({ "open", "Alt-Realm" }, { Q:CraftNext().status, Q:CraftNext().charKey }); assert.equals(0, #world.crafts)
  end)
  it("craft_next_crafts_one_and_counts_on_result", function()
    world.openProfession(9001); world.haveAll("Main-Realm")
    local id = Q:Add({ recipeID = 9001, quantity = 3, charKey = "Main-Realm", useConcentration = true })
    local r = Q:CraftNext()
    assert.same({ "crafted", id }, { r.status, r.entryID })
    assert.same({ 9001, 1, false and nil, nil, nil, true }, { world.crafts[1][1], world.crafts[1][2], nil, world.crafts[1][4], world.crafts[1][5], world.crafts[1][6] })
    assert.equals(3, Q:GetEntries()[1].quantity)
    world.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", { itemID = 5002, operationID = 77 })
    world.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", { itemID = 5002, operationID = 77 })   -- multicraft extra, same op
    assert.equals(2, Q:GetEntries()[1].quantity)
  end)
  it("craft_next_missing_and_cooldown", function()
    world.openProfession(9001)
    Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
    assert.equals("missing", Q:CraftNext().status)
    world.haveAll("Main-Realm"); world.cooldown("Main-Realm", 9001, ns.FS:Now() + 3600)
    local r = Q:CraftNext(); assert.equals("cooldown", r.status); assert.equals(ns.FS:Now() + 3600, r.readyAt)
  end)
end)
```

Tidy the `craft_next_crafts_one_and_counts_on_result` call assertion when writing it to: `assert.equals(9001, c[1]); assert.equals(1, c[2]); assert.is_table(c[3]); assert.is_nil(c[4]); assert.is_nil(c[5]); assert.is_true(c[6])` with `local c = world.crafts[1]`.

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/queue/craft_spec.lua`
Expected: FAIL — `ExportShoppingList` undefined.

- [ ] **Step 3: Implement `Modules/QueueCraft.lua`.** Tier = index of the item in its schematic slot's `reagents` list (only when the slot has ≥ 2 reagents). Every Auctionator call is `pcall`ed; a failure returns `false, "auctionatorError"` and prints once.

- [ ] **Step 4: Run test to verify it passes, and check click-only use**

Run: `busted tests/queue && grep -rn "CraftNext(" Modules UI | grep -v "function Queue:CraftNext"`
Expected: PASS; grep output empty now (Task 15/16 add the only callers, both inside `OnClick`).

- [ ] **Step 5: Commit**

```bash
git add Modules/QueueCraft.lua tests/queue/craft_spec.lua FabricationStation.toc
git commit -m "feat: add Auctionator shopping list, click-only Craft Next and cooldown checks"
```

---

### Task 13: Dashboard tab with RegisterWidget and phase-1 widgets

**Files:**
- Create: `UI/Tabs/Dashboard.lua`, `tests/helpers/fake_frames.lua`
- Modify: `FabricationStation.toc`
- Test: `tests/ui/dashboard_spec.lua`

**Interfaces:**
- Consumes: `MainWindow:RegisterTab("dashboard", { label = "Dashboard", icon, order = 10, phase = 1, build, refresh })`, `Recipes:GetRanked`, `Queue:GetEntries/GetEntryCost/GetMissingReagents`, `Scanner:GetCharacters/GetCharacter`, `Scanner:ProjectConcentration(charKey, skillLineID, atTime)`, `ns.UI.FormatMoney`; messages `FS_RECIPES_CHANGED`, `FS_QUEUE_CHANGED`, `FS_DATA_CHANGED`.
- Produces: module `"Dashboard"`; `Dashboard:RegisterWidget(id, def)` (contract; same id replaces); `Dashboard:GetWidgets() -> { def }` sorted by `order`; pure models `Dashboard.TopCraftsModel(results, n) -> rows`, `Dashboard.QueueSummaryModel(entries, costs, missing) -> { entries, crafts, totalCost|nil, missingItems }`, `Dashboard.ConcentrationModel(rows, now) -> rows` (`{ charKey, profession, value, max, fullAt }`, sorted by `fullAt`). Phase-1 widgets: `topCrafts` (order 10, top 10 by profit, price age shown), `queueSummary` (20), `concentration` (30). A widget whose `build`/`refresh` errors shows "widget failed" and the others still render. `tests/helpers/fake_frames.lua` provides `install_fake_frames()` (`CreateFrame` returning tables that record `SetPoint/SetText/Show/Hide/SetScript/HookScript/CreateFontString`).

- [ ] **Step 1: Write the failing test**

```lua
describe("Dashboard", function()
  local ns, D
  before_each(function() install_fake_frames(); ns = make_world({ files = { "UI/Tabs/Dashboard.lua" } }); D = ns.FS:GetModule("Dashboard") end)
  it("orders widgets and replaces duplicates", function()
    D:RegisterWidget("b", { order = 50, title = "B", build = function() end, refresh = function() end })
    D:RegisterWidget("a", { order = 5,  title = "A", build = function() end, refresh = function() end })
    D:RegisterWidget("b", { order = 1,  title = "B2", build = function() end, refresh = function() end })
    local w = D:GetWidgets(); assert.same({ "B2", "A", "topCrafts" }, { w[1].title, w[2].title, w[3].id and w[3].title and "topCrafts" })
  end)
  it("isolates a failing widget", function()
    D:RegisterWidget("bad", { order = 1, title = "Bad", build = function() error("boom") end, refresh = function() end })
    local frames = D:BuildAll(CreateFrame("Frame"))
    assert.equals("widget failed", frames.bad.errorText); assert.is_table(frames.topCrafts)
  end)
  it("concentration model sorts by full-at", function()
    local rows = D.ConcentrationModel({ { charKey = "A", value = 900, max = 1000, regenPerSec = 1/360 }, { charKey = "B", value = 990, max = 1000, regenPerSec = 1/360 } }, 0)
    assert.same({ "B", "A" }, { rows[1].charKey, rows[2].charKey }); assert.equals(3600, rows[1].fullAt)
  end)
  it("queue summary leaves total nil when any cost is unknown", function()
    assert.is_nil(D.QueueSummaryModel({ {id=1,quantity=2}, {id=2,quantity=1} }, { [1] = 1800 }, {}).totalCost)
  end)
end)
```

Fix the first test's last element while writing it to compare `w[3].id == "topCrafts"` directly; `RegisterWidget` stores `id` on the def.

`ConcentrationModel` input rows come from `Scanner:ProjectConcentration`; `fullAt = now + (max − value) / regenPerSec` where `regenPerSec` is derived from two projections one hour apart (`ProjectConcentration(c, s, now + 3600) − ProjectConcentration(c, s, now)`) so the dashboard does not hard-code a regen rate.

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/ui/dashboard_spec.lua`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement `UI/Tabs/Dashboard.lua`** (`D:BuildAll(container) -> { [id] = frame }` lays widgets out in a two-column grid; `refresh` runs on the three messages, debounced 0.5 s).

- [ ] **Step 4: Run tests, then verify in game**

Run: `busted tests/ui/dashboard_spec.lua`
Expected: PASS.
In game: `/fs` → Dashboard shows top crafts with price age, queue summary and concentration rows for every alt; `/reload` keeps them.

- [ ] **Step 5: Commit**

```bash
git add UI/Tabs/Dashboard.lua tests/helpers/fake_frames.lua tests/ui/dashboard_spec.lua FabricationStation.toc
git commit -m "feat: add Dashboard tab with widget registry and phase-1 widgets"
```

---

### Task 14: Recipes tab

**Files:**
- Create: `UI/Tabs/Recipes.lua`
- Modify: `FabricationStation.toc`
- Test: `tests/ui/recipes_tab_spec.lua`

**Interfaces:**
- Consumes: `MainWindow:RegisterTab("recipes", { label = "Recipes", order = 20, phase = 1, ... })`, `Recipes:GetRanked`, `Recipes:IsScanning`, `Queue:Add`, `C_Spell.GetSpellName`, `ns.UI.FormatMoney`; message `FS_RECIPES_CHANGED`.
- Produces: `ns.UI.RecipesTab.BuildRows(results, now) -> { { recipeID, name, charKey, quality, cost, sale, profit, gpc, priceAge, flagsText } }` and `ns.UI.RecipesTab.FilterFromControls(state) -> filter` (state = `{ profession, character, minQuality, usesConcentration, onlyProfitable, sortBy }`; "any" values map to nil).

Columns (spec §5.1): recipe, character, expected quality, cost, sale, profit, gold/concentration, price age. `flagsText` joins "no price", "stale price", "stale data", "estimate", "unknown recipe". Row button "Queue" → `Queue:Add({ recipeID, quantity = 1, charKey, targetQuality = quality, useConcentration = state.usesConcentration })`. Header shows "Scanning…" while `IsScanning()`.

- [ ] **Step 1: Write the failing test**

```lua
describe("Recipes tab model", function()
  local T = (function() install_fake_frames(); local ns = make_world({ files = { "UI/Tabs/Recipes.lua" } }); return ns.UI.RecipesTab end)()
  it("builds rows with flags and price age", function()
    local rows = T.BuildRows({ { recipeID = 9001, charKey = "Main-Realm", expectedQuality = 2, reagentCost = 4800, expectedSale = 124450,
      profit = 120010, goldPerConcentration = 6, priceAgeDays = 1.5, flags = { stalePrice = true, estimated = true } } }, 0)
    assert.same({ 2, 4800, 120010, 6, 1.5, "stale price, estimate" }, { rows[1].quality, rows[1].cost, rows[1].profit, rows[1].gpc, rows[1].priceAge, rows[1].flagsText })
  end)
  it("maps controls to a GetRanked filter", function()
    assert.same({ sortBy = "goldPerConcentration", usesConcentration = true, minQuality = 2 },
      T.FilterFromControls({ profession = "any", character = "any", minQuality = 2, usesConcentration = true, onlyProfitable = false, sortBy = "goldPerConcentration" }))
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/ui/recipes_tab_spec.lua`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement `UI/Tabs/Recipes.lua`** (filter bar with dropdowns/checkboxes, `WowScrollBoxList` rows, sortable headers).

- [ ] **Step 4: Run tests, then verify in game**

Run: `busted tests/ui/recipes_tab_spec.lua`
Expected: PASS. In game: Recipes tab lists recipes for every character; "only profitable" hides unpriced rows; "Queue" adds an entry visible in the Queue tab.

- [ ] **Step 5: Commit**

```bash
git add UI/Tabs/Recipes.lua tests/ui/recipes_tab_spec.lua FabricationStation.toc
git commit -m "feat: add Recipes tab with filters and add-to-queue"
```

---

### Task 15: Queue tab and restock editor

**Files:**
- Create: `UI/Tabs/Queue.lua`
- Modify: `FabricationStation.toc`
- Test: `tests/ui/queue_tab_spec.lua`

**Interfaces:**
- Consumes: `MainWindow:RegisterTab("queue", { label = "Queue", order = 30, phase = 1, ... })`, `Queue:GetEntries/GetEntryMissing/GetEntryCost/SetQuantity/Remove/Clear/ExportShoppingList/CraftNext/GetRestockTargets/SetRestock/GetCooldownReadyAt`, `C_Item.GetItemNameByID`; message `FS_QUEUE_CHANGED`.
- Produces: `ns.UI.QueueTab.BuildRows(entries, costs, missing, readyAt, now) -> rows` (`{ id, name, charKey, quantity, targetQuality, concentration, missingText, cost, readyText, isRestock }`); `ns.UI.QueueTab.StatusText(CraftNextResult, professionName, charName) -> string`.

Columns (spec §5.1): character, quantity, target quality, concentration on/off, missing reagents, total cost (+ "ready in 2h 5m" for cooldown entries). Buttons: Shopping List, Clear, Craft Next (its `OnClick` is the only caller besides the panel), Restock editor (item ID / shift-click link + target, list with remove). `StatusText` copy: `"crafted"` → `"Crafting <recipe>…"`; `"open"` → `"Open <Profession> on <Character>"`; `"missing"` → `"Missing reagents — see Shopping List"`; `"cooldown"` → `"Next craft ready in <time>"`; `"empty"` → `"Queue is empty"`.

- [ ] **Step 1: Write the failing test**

```lua
describe("Queue tab model", function()
  local T = (function() install_fake_frames(); local ns = make_world({ files = { "UI/Tabs/Queue.lua" } }); return ns.UI.QueueTab end)()
  it("shows missing reagents, cost and cooldown", function()
    local rows = T.BuildRows({ { id = 1, recipeID = 9001, quantity = 3, charKey = "Alt-Realm", targetQuality = 2, useConcentration = true } },
      { [1] = 2700 }, { [1] = { [1001] = 2 } }, { [1] = 7500 }, 0)
    assert.same({ 2700, "on", "2× item:1001", "ready in 2h 5m" }, { rows[1].cost, rows[1].concentration, rows[1].missingText, rows[1].readyText })
  end)
  it("status text", function()
    assert.equals("Open Alchemy on Alt", T.StatusText({ status = "open" }, "Alchemy", "Alt"))
    assert.equals("Queue is empty", T.StatusText({ status = "empty" }))
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/ui/queue_tab_spec.lua`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement `UI/Tabs/Queue.lua`** (`missingText` uses item names when cached, `item:<id>` otherwise).

- [ ] **Step 4: Run tests, then verify in game**

Run: `busted tests/ui/queue_tab_spec.lua`
Expected: PASS. In game: Shopping List creates the Auctionator list "FabricationStation" with the shown quantities; Craft Next with the profession closed shows "Open <Profession> on <Character>"; with it open crafts exactly one per click.

- [ ] **Step 5: Commit**

```bash
git add UI/Tabs/Queue.lua tests/ui/queue_tab_spec.lua FabricationStation.toc
git commit -m "feat: add Queue tab with shopping list, Craft Next and restock editor"
```

---

### Task 16: Profession side panel

**Files:**
- Create: `UI/ProfessionPanel.lua`
- Modify: `FabricationStation.toc`
- Test: `tests/ui/profession_panel_spec.lua`

**Interfaces:**
- Consumes: `ADDON_LOADED("Blizzard_Professions")`, `ProfessionsFrame`, `ProfessionsFrame.CraftingPage.SchematicForm` (`GetTransaction()`, `UpdateAllSlots()`, `TriggerEvent`, `RegisterCallback(ProfessionsRecipeSchematicFormMixin.Event.AllocationsModified, fn, owner)`), `EventRegistry:RegisterCallback("ProfessionsRecipeListMixin.Event.OnRecipeSelected", fn, owner)` (args `recipeInfo`), `EventRegistry` `"Professions.TransactionUpdated"`, `Professions.CreateCraftingReagent(itemID)`, `Recipes:Calibrate/Evaluate/PredictLive/FromCraftingReagentInfo/GetSetting`, `Queue:Add/CraftNext`, `ns.UI.QueueTab.StatusText`.
- Produces: module `"ProfessionPanel"`; `ns.UI.ProfessionPanel.BuildModel(result: RecipeResult, live: MathResult|nil) -> model` with `{ qualityText, skill, difficulty, lowerThreshold, nextThreshold, barFill (0..1), skillToNext, concentrationText, perQualityRows = { {quality, cost, profit} }, breakdownRows = { {label, value} } }`; `ProfessionPanel:ApplyAllocation(allocation)`.

Behaviour (spec §5.2):
- Frame `CreateFrame("Frame", "FabricationStationProfessionPanel", UIParent, "BackdropTemplate")`, anchored `TOPLEFT` to `ProfessionsFrame` `TOPRIGHT` (+2, 0), shown/hidden through `ProfessionsFrame:HookScript("OnShow"/"OnHide")`. Width 300.
- On recipe selected: `Recipes:Calibrate(recipeID)`, then `Evaluate(recipeID, CharKey(), panelOpts)`; on allocation change: `PredictLive` for the live allocation drives the prediction header and bar (the skill/threshold numbers shown are the live allocation's), the optimiser result drives the per-quality rows.
- Threshold bar: `barFill = (skill − lowerThreshold) / (nextThreshold − lowerThreshold)`, 1 at max quality; label "Skill 690 / 700 — 10 to next".
- Per-quality rows (cheapest reagents per reachable quality) each with **Apply**. Breakdown rows: reagent cost, expected sale (after 5% AH cut), multicraft, resourcefulness, ingenuity (points), concentration cost, gold per concentration, profit, price age; "no price"/"estimate" flags in red.
- **Apply** (click only): if `applyWritesBlizzardSlots` — per allocated slot `local a = transaction:GetAllocations(slotIndex); a:Clear(); a:Allocate(Professions.CreateCraftingReagent(itemID), qty)` for each item, then `transaction:SetManuallyAllocated(true)`, `SchematicForm:UpdateAllSlots()`, `SchematicForm:TriggerEvent(ProfessionsRecipeSchematicFormMixin.Event.AllocationsModified)` (the same sequence Blizzard's quality dialog runs). If the setting is off, Apply is disabled with tooltip "Enable in Settings › Crafting".
- **Add to Queue**: quantity box (default 1) + target-quality dropdown + concentration checkbox → `Queue:Add`.
- **Craft Next**: `OnClick` → `Queue:CraftNext()`, status line via `StatusText`.
- Toggle `professionPanel` hides the panel and unregisters callbacks.

- [ ] **Step 1: Write the failing test**

```lua
describe("ProfessionPanel model", function()
  local M = (function() install_fake_frames(); local ns = make_world({ files = { "UI/ProfessionPanel.lua" } }); return ns.UI.ProfessionPanel end)()
  local result = { expectedQuality = 2, perQuality = { [1] = { reagentCost = 3000, profit = 71895 }, [2] = { reagentCost = 4800, profit = 120010 } },
    reagentCost = 4800, expectedSale = 124450, multicraftValue = 29450, resourcefulnessValue = 360, ingenuityValue = 31.4,
    concentrationCost = 314, goldPerConcentration = 6, profit = 120010, priceAgeDays = 1, flags = {} }
  it("threshold bar from the live prediction", function()
    local m = M.BuildModel(result, { skill = 690, difficulty = 700, lowerThreshold = 0, nextThreshold = 700, expectedQuality = 1 })
    assert.near(690 / 700, m.barFill, 1e-9); assert.equals(10, m.skillToNext); assert.equals(1, #m.perQualityRows - 1)
  end)
  it("full bar at max quality", function()
    assert.equals(1, M.BuildModel(result, { skill = 780, difficulty = 700, lowerThreshold = 700, expectedQuality = 2 }).barFill)
  end)
  it("breakdown rows in spec order", function()
    local labels = {}; for _, r in ipairs(M.BuildModel(result, nil).breakdownRows) do labels[#labels + 1] = r.label end
    assert.same({ "Reagents", "Sale (after AH cut)", "Multicraft", "Resourcefulness", "Ingenuity", "Concentration",
                  "Gold / concentration", "Profit", "Price age" }, labels)
  end)
end)
describe("ProfessionPanel apply", function()
  it("writes allocations through the transaction API and fires AllocationsModified", function()
    install_fake_frames(); local ns, world = make_world({ files = { "Modules/Recipes.lua", "UI/ProfessionPanel.lua" } })
    local form = world.fakeProfessionsFrame()                -- records transaction and form calls
    ns.FS:GetModule("ProfessionPanel"):ApplyAllocation({ {slotIndex=1,itemID=1001,quantity=3}, {slotIndex=1,itemID=1002,quantity=7} })
    assert.same({ "Clear", "Allocate:1001:3", "Allocate:1002:7" }, form.slotCalls[1])
    assert.is_true(form.manuallyAllocated); assert.same({ "UpdateAllSlots", "TriggerEvent:AllocationsModified" }, form.calls)
    assert.same({}, form.assignedFields)                     -- nothing written onto Blizzard frames
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/ui/profession_panel_spec.lua`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement `UI/ProfessionPanel.lua`** per the behaviour list; all hook bodies run through `ns.FS:SafeCall("ProfessionPanel", ...)`.

- [ ] **Step 4: Run tests, then verify in game (taint check)**

Run: `busted tests/ui/profession_panel_spec.lua`
Expected: PASS.
In game with `/console taintLog 1`: open a profession, select a quality recipe, click Apply on quality 2, then click Blizzard's **Create** button. Expected: Blizzard's slots show the applied mix, the craft succeeds, no "action blocked" message, and `Logs/taint.log` has no FabricationStation lines. If it taints, set `applyWritesBlizzardSlots` default to `false` and record it in the commit message.

- [ ] **Step 5: Commit**

```bash
git add UI/ProfessionPanel.lua tests/ui/profession_panel_spec.lua FabricationStation.toc
git commit -m "feat: add profession side panel with prediction, reagents per quality and queue buttons"
```

---

### Task 17: Recipe-list profit labels

**Files:**
- Create: `UI/RecipeListLabels.lua`
- Modify: `FabricationStation.toc`
- Test: `tests/ui/recipe_list_labels_spec.lua`

**Interfaces:**
- Consumes: `ADDON_LOADED("Blizzard_Professions")`, `ProfessionsFrame.CraftingPage.RecipeList.ScrollBox` (`RegisterCallback(ScrollBoxListMixin.Event.OnInitializedFrame, fn, owner)` — callback args `(owner, frame, elementData)`; `ForEachFrame(fn(frame, elementData))`), `elementData:GetData().recipeInfo.recipeID`, `Recipes:Evaluate(recipeID, CharKey(), {})`, `Recipes:GetSetting("recipeListLabels")`, message `FS_RECIPES_CHANGED`.
- Produces: module `"RecipeListLabels"`; `ns.UI.RecipeListLabels.LabelText(result) -> text, colorKey` (`"+12g"`/`"green"`, `"-3g"`/`"red"`, `"?"`/`"grey"` for no price; copper below 1g shown as silver).

Labels are own FontStrings created with `row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")`, right-aligned, kept in `local labels = setmetatable({}, { __mode = "k" })` keyed by row — never `row.someField = ...`. Category header rows (no `recipeInfo`) are skipped. Any error inside the callback → `SafeCall` disables the module, `ForEachFrame` hides all labels, one chat line "FabricationStation: recipe list labels disabled (error logged)". Missing `ScrollBox` → same disable path without registering.

- [ ] **Step 1: Write the failing test**

```lua
describe("RecipeListLabels", function()
  it("label text", function()
    install_fake_frames(); local ns = make_world({ files = { "UI/RecipeListLabels.lua" } }); local L = ns.UI.RecipeListLabels
    assert.same({ "+12g", "green" }, { L.LabelText({ profit = 120010, flags = {} }) })
    assert.same({ "-3g", "red" }, { L.LabelText({ profit = -30000, flags = {} }) })
    assert.same({ "?", "grey" }, { L.LabelText({ flags = { noPrice = true } }) })
    assert.same({ "+45s", "green" }, { L.LabelText({ profit = 4500, flags = {} }) })
  end)
  it("labels rows without writing fields on them", function()
    install_fake_frames(); local ns, world = make_world({ files = { "Modules/Recipes.lua", "UI/RecipeListLabels.lua" }, calibrate = { ["Main-Realm"] = { 9001 } } })
    local scroll = world.fakeProfessionsFrame().recipeScrollBox
    ns.FS:GetModule("RecipeListLabels"):Enable(); world.fire("ADDON_LOADED", "Blizzard_Professions")
    local row = CreateFrame("Button"); local keys = {}; for k in pairs(row) do keys[k] = true end
    scroll.fireInitialized(row, world.node({ recipeInfo = { recipeID = 9001 } }))
    assert.equals("+12g", row.createdFontStrings[1].text)
    for k in pairs(row) do assert.is_true(keys[k] or k == "createdFontStrings", "wrote field " .. tostring(k)) end
  end)
  it("disables_when_scrollbox_missing", function()
    install_fake_frames(); local ns, world = make_world({ files = { "Modules/Recipes.lua", "UI/RecipeListLabels.lua" } })
    world.fakeProfessionsFrame({ withoutScrollBox = true })
    ns.FS:GetModule("RecipeListLabels"):Enable()
    assert.has_no.errors(function() world.fire("ADDON_LOADED", "Blizzard_Professions") end)
    assert.is_false(ns.FS:GetModule("RecipeListLabels"):IsEnabled())
  end)
end)
```

(`createdFontStrings` is the fake frame's own bookkeeping from `fake_frames.lua`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/ui/recipe_list_labels_spec.lua`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement `UI/RecipeListLabels.lua`.**

- [ ] **Step 4: Run tests, then verify in game**

Run: `busted tests/ui/recipe_list_labels_spec.lua`
Expected: PASS. In game: labels appear on recipe rows, update after an Auctionator scan, vanish when the setting is turned off; scrolling quickly causes no errors.

- [ ] **Step 5: Commit**

```bash
git add UI/RecipeListLabels.lua tests/ui/recipe_list_labels_spec.lua FabricationStation.toc
git commit -m "feat: add toggleable profit labels on Blizzard recipe list rows"
```

---

### Task 18: Tooltips module and craft-cost line

**Files:**
- Create: `UI/Tooltips.lua`
- Modify: `FabricationStation.toc`
- Test: `tests/ui/tooltips_spec.lua`

**Interfaces:**
- Consumes: `TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, fn(tooltip, data))` (`data.id` = itemID), `tooltip:AddDoubleLine`, `Recipes:FindRecipesForItem/WhoCanCraft/Evaluate`, `Recipes:GetSetting("tooltipCraftCost")`, `ns.UI.FormatMoney`.
- Produces: module `"Tooltips"`; `Tooltips:RegisterLineProvider(id, fn(itemID) -> { {left, right}, ... })` (contract; same id replaces); `Tooltips:CollectLines(itemID) -> { {left, right} }` (providers in registration order, each `pcall`ed; an erroring provider is disabled for the session and logged via `ns.FS.db.global.diagnostics.errors` through `SafeCall`'s logger); built-in provider `"craftCost"`: for each `{recipeID, quality}` of the item, the cheapest `Evaluate(recipeID, charKey, { targetQuality = quality }).reagentCost` across `WhoCanCraft`, line `{ "Craft cost", FormatMoney(cost) .. " (" .. shortName(charKey) .. ")" }`; "no price" when every candidate lacks a price; nothing when nobody can craft it. Results cached per itemID until `FS_RECIPES_CHANGED`.

- [ ] **Step 1: Write the failing test**

```lua
describe("Tooltips", function()
  local ns, T
  before_each(function() install_fake_frames(); ns = make_world({ files = { "Modules/Recipes.lua", "UI/Tooltips.lua" }, calibrate = { ["Main-Realm"] = { 9001 } } }); T = ns.FS:GetModule("Tooltips") end)
  it("craft cost line names the cheapest character", function()
    assert.same({ { "Craft cost", "48s (Main)" } }, T:CollectLines(5002))     -- 4800 copper, FormatMoney fake = "<s>s"
  end)
  it("no line for items nobody crafts", function() assert.same({}, T:CollectLines(424242)) end)
  it("isolates a failing provider", function()
    T:RegisterLineProvider("bad", function() error("boom") end)
    T:RegisterLineProvider("ok", function() return { { "x", "y" } } end)
    assert.same({ { "Craft cost", "48s (Main)" }, { "x", "y" } }, T:CollectLines(5002))
    assert.same({ { "Craft cost", "48s (Main)" }, { "x", "y" } }, T:CollectLines(5002))   -- bad stays disabled, no error
  end)
end)
```

(`Alt-Realm` is uncalibrated, so its estimate costs 4800 too; ties keep the first in `WhoCanCraft` order — make the fake world give Alt a higher price for rank-2 reagents so "Main" wins unambiguously.)

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/ui/tooltips_spec.lua`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement `UI/Tooltips.lua`.** Skip when `type(data.id) ~= "number"`.

- [ ] **Step 4: Run tests, then verify in game**

Run: `busted tests/ui/tooltips_spec.lua`
Expected: PASS. In game: hovering a crafted item shows "Craft cost"; Auctionator's own tooltip lines are unchanged.

- [ ] **Step 5: Commit**

```bash
git add UI/Tooltips.lua tests/ui/tooltips_spec.lua FabricationStation.toc
git commit -m "feat: add Tooltips line provider registry and craft-cost line"
```

---

### Task 19: In-game self-check

**Files:**
- Create: `Modules/SelfCheck.lua`
- Modify: `UI/ProfessionPanel.lua` (status line), `FabricationStation.toc`
- Test: `tests/recipes/selfcheck_spec.lua`

**Interfaces:**
- Consumes: `Recipes:PredictLive`, `Recipes:FromCraftingReagentInfo`, `Recipes:LogMismatch`, `Recipes:RecordFixture` (fixture attached to each mismatch, even with `recordMathFixtures` off), `Scanner:GetLiveOperationInfo`, the same EventRegistry/SchematicForm callbacks as Task 16, `ns.FS:Debounce`, `ns.FS:RegisterOptions`.
- Produces: module `"SelfCheck"`; `ns.SelfCheck.Compare(prediction: MathResult, opInfo) -> { { field, predicted, actual } }` (fields `skill` ±0.5, `difficulty`, `quality` vs the field pinned in Task 9, `lowerThreshold` vs `lowerSkillThreshold`, `nextThreshold` vs `upperSkillTreshold` when below max, `concentrationCost` vs `opInfo.concentrationCost` when the opInfo cost > 0 and a curve is known); `SelfCheck:Run(recipeID) -> mismatches` (current window state); `SelfCheck:GetSessionCount() -> integer`. Same `(recipeID, field, predicted, actual)` is logged at most once per session. Options group `"selfcheck"`: mismatch count, last 20 mismatches as text, "Clear" button (empties `db.global.diagnostics.mismatches`). ProfessionPanel status line: "Math check: OK" or "Math check: N mismatches (see Settings)".

- [ ] **Step 1: Write the failing test**

```lua
describe("SelfCheck", function()
  local ns, world
  before_each(function() ns, world = make_world({ files = { "Modules/Recipes.lua", "Modules/SelfCheck.lua" }, calibrate = { ["Main-Realm"] = { 9001 } } }) end)
  it("compare finds field mismatches with tolerance", function()
    local m = ns.SelfCheck.Compare({ skill = 703.3, difficulty = 700, expectedQuality = 2, lowerThreshold = 700, concentrationCostForAllocation = 0 },
      { baseSkill = 480, bonusSkill = 223, baseDifficulty = 700, bonusDifficulty = 0, craftingQuality = 1, lowerSkillThreshold = 0, upperSkillTreshold = 700, concentrationCost = 0 })
    assert.same({ { field = "quality", predicted = 2, actual = 1 }, { field = "lowerThreshold", predicted = 700, actual = 0 } }, m)
  end)
  it("logs once per session with a fixture", function()
    world.live[9001] = function() return { baseSkill = 480, bonusSkill = 20, baseDifficulty = 700, bonusDifficulty = 0, craftingQuality = 2,
      lowerSkillThreshold = 700, upperSkillTreshold = 700, concentrationCost = 0, craftingDataID = 2588, bonusStats = {} } end
    world.openProfession(9001); world.liveAllocation({})
    local S = ns.FS:GetModule("SelfCheck")
    assert.equals(2, #S:Run(9001)); S:Run(9001)
    local log = ns.FS.db.global.diagnostics.mismatches
    assert.equals(2, #log); assert.is_table(log[1].fixture); assert.equals(2, S:GetSessionCount())
  end)
  it("does nothing when the setting is off", function()
    ns.FS.db.global.settings.crafting = { selfCheck = false }
    assert.same({}, ns.FS:GetModule("SelfCheck"):Run(9001))
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/recipes/selfcheck_spec.lua`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement `Modules/SelfCheck.lua`** and the panel status line (debounce 0.2 s on allocation/transaction updates).

- [ ] **Step 4: Run the whole suite, lint, then verify in game**

Run: `busted && luacheck .`
Expected: all specs PASS (golden spec green or pending only if no fixtures were committed); 0 warnings.
In game: changing reagent ranks on a recipe keeps the panel at "Math check: OK"; any mismatch appears in Settings › Self-check with the recipe and field; exporting with `tools/export_math_fixtures.lua` turns it into a fixture that reproduces the failure in `busted tests/math/golden_spec.lua`.

- [ ] **Step 5: Commit**

```bash
git add Modules/SelfCheck.lua UI/ProfessionPanel.lua tests/recipes/selfcheck_spec.lua FabricationStation.toc
git commit -m "feat: add in-game math self-check with mismatch log and fixtures"
```
