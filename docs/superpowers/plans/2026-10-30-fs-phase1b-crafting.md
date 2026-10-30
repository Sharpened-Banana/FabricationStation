# FabricationStation Phase 1b — Crafting Math, Profit, Queue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace CraftSim for the author: predict quality and concentration cost, pick the cheapest reagents per reachable quality, rank every known recipe on every character by profit and gold per concentration, and run a click-only craft queue with an Auctionator shopping list — in the main window, beside Blizzard's Professions frame, in the recipe list and in item tooltips.

**Architecture:** `ns.Math` is pure Lua (plain tables in, plain tables out) and holds all crafting formulas. `ns.CraftingData` is a pure adapter that reads 1a's GameData tables and builds Math inputs. `Recipes` joins Scanner snapshots, per-character calibration records (taken from `GetCraftingOperationInfo` while a profession window is open), GameData and Prices, calls Math, caches results keyed on price version and per-character data stamps, and runs a time-sliced scan. `Queue` uses only Recipes/Scanner/Prices public functions. UI files expose pure "model" functions that busted tests; frames are thin and are verified in game.

**Tech Stack:** WoW retail Lua 5.1 (Midnight 12.x), Ace3, busted 2.3.0, luacheck 1.2.0, Auctionator API v1 (only through `Prices:AuctionatorAPI()`), 1a's GameData tables (wago.tools DB2).

**Spec:** `docs/superpowers/specs/2026-10-30-fabricationstation-design.md` (§5.1 Dashboard/Recipes/Queue tabs, §5.2, §5.4 craft-cost line, §6, §11, §12). Binding names: `docs/superpowers/plans/2026-10-30-fs-interface-contract.md`. Phase 1a (`docs/superpowers/plans/2026-10-30-fs-phase1a-foundation.md`) is assumed complete; the **[1a additions]** used here are named under each task's Consumes.

## Global Constraints

- Retail only, Midnight 12.x. Interface number pinned by 1a.
- Every addon file begins `local ADDON_NAME, ns = ...`. Modules: `ns.FS:NewModule("<Name>", "AceEvent-3.0")`.
- Math never calls the game: `Math/*.lua` and `Modules/CraftingData.lua` reference no WoW globals and no `ns.FS` (spec §3 rule 4). Math receives GameData values as arguments.
- Only Prices talks to Auctionator; Queue calls `Prices:AuctionatorAPI()` with caller ID `"FabricationStation"` and list name `"FabricationStation"`.
- Every protected action is a player click: `C_TradeSkillUI.CraftRecipe` is called only in `Queue:CraftNext()`, which is called only from `OnClick` handlers. No loops, no timers.
- No taint: own frames plus `hooksecurefunc`, `HookScript`, `EventRegistry:RegisterCallback`, ScrollBox `RegisterCallback`. Never assign fields on Blizzard frames; per-row data lives in addon-owned weak-keyed tables. Never replace, hide or reparent Blizzard frames.
- Missing price → `flags.noPrice = true`, shown as "no price", excluded from profit sorting, never treated as 0.
- Money is integer copper; every copper value Math returns goes through `ns.Math.Round(x) = math.floor(x + 0.5)`. Time is server seconds via `ns.FS:Now()`.
- Expected sale applies the 5% AH cut: `Profit.AH_CUT = 0.95`.
- Owned reagents are costed at market price unless 1a's `db.global.settings.costing.ownedReagentsFree` is true. Price staleness is 1a's `Prices:IsStale(priceResult)` (`settings.prices.staleAfterDays`, default 3).
- Price age is shown wherever a price is shown.
- ProfessionPanel, RecipeListLabels and Tooltips are separate AceModules, switched on/off by 1a's per-module toggles (`settings.modules[name]`, `ns.FS:SetModuleEnabled`); hook bodies run through `ns.FS:SafeCall(moduleName, fn, ...)` so a failure disables only that module (1a's SafeCall prints the one chat line).
- Recipes, Queue, QueueCraft, CraftingData and SelfCheck set `M.coreModule = true` (not user-toggleable); everything downstream depends on them.
- Late attachment: every module that attaches to Blizzard_Professions (ProfessionPanel, RecipeListLabels, Recipes' auto-calibration) does so in a single `AttachIfReady()` called both from `ADDON_LOADED("Blizzard_Professions")` and from `OnEnable` (`if C_AddOns.IsAddOnLoaded("Blizzard_Professions") and ProfessionsFrame then`), guarded by an `attached` flag so it attaches exactly once. Each of those tasks adds the test `attaches_when_professions_already_loaded` (load Blizzard_Professions fakes first, then enable the module, assert the hooks are registered once).
- 1a's `.luacheckrc` `stds.wow.read_globals` and `install_wow_stubs` do not cover every global 1b reads. The task that first reads one adds it to `read_globals`: `debugprofilestop` (Task 10), `ProfessionsRecipeSchematicFormMixin`, `Professions` (Task 16), `ScrollBoxListMixin` (Task 17), `TooltipDataProcessor` (Task 18). Specs get fakes for these plus `EventRegistry` and `Enum.TooltipDataType` through `make_world` stub overrides and `fake_professions_frame`.
- 1b settings live in `db.global.settings.crafting` (created lazily; defaults in `Recipes.DEFAULTS`). Other new saved data: `db.global.recipeCalib[charKey][recipeID]` (lazy). Queue uses 1a's default `db.global.queue = { entries, restock }` and adds `nextID` lazily. Mismatches go through `Diagnostics:LogMismatch`. No migration needed.
- Files whose formula or mapping comes from CraftSim carry `-- Formula reference: CraftSim (MIT, github.com/derfloh205/CraftSim) <path>`.
- TOC order (1a convention; TOC lines use backslashes, `load_addon(ns, lastFile)` takes the forward-slash path): `Math\Quality.lua, Math\Concentration.lua, Math\Stats.lua, Math\Optimizer.lua, Math\Profit.lua` after `Data\GameData_Manual.lua`; `Modules\CraftingData.lua, Modules\Recipes.lua, Modules\RecipeScan.lua, Modules\Queue.lua, Modules\QueueCraft.lua, Modules\SelfCheck.lua` after `Modules\Diagnostics.lua`; `UI\Tabs\Dashboard.lua, UI\Tabs\Recipes.lua, UI\Tabs\Queue.lua` between `UI\MainWindow.lua` and `UI\Tabs\Settings.lua`; `UI\ProfessionPanel.lua, UI\RecipeListLabels.lua, UI\Tooltips.lua` after `UI\Launcher.lua`. Each task adds its files when it creates them (1a's TOC test fails on a listed file that does not exist).
- Every task finishes with `busted` all green and `luacheck .` at 0 warnings. Conventional commits.

## Verified formulas and their sources

Read from CraftSim `main` @ e15fb18 (2026-10-21, data build 12.1.5.70448) and Blizzard API docs on `Gethe/wow-ui-source` `live`, fetched 2026-10-30. "CraftSim" means checked against CraftSim's code, not the game; Task 9 checks them against the game.

| Item | Value | Source |
|---|---|---|
| Default quality thresholds (fraction of total difficulty), used when GameData `QualityThresholds` is missing | maxQ 1: none; 2: {1.0}; 3: {0.5, 1.0}; 5: {0.2, 0.5, 0.8, 1.0}; reached when `skill >= threshold` | CraftSim `Modules/RecipeInfo/RecipeInfo.lua` `GetQualityThresholds` (offset option default off) |
| Quality is deterministic; concentration adds +1 quality, capped at max | | CraftSim `Classes/ResultData.lua` |
| Max reagent skill | measured live = skill(all quality slots at top rank) − skill(empty allocation); default `0.40 × baseDifficulty` | CraftSim `ReagentData:GetMaxSkillFactor`; 0.40 from the `ReagentOptimization.lua` header (Midnight-era text) |
| Reagent skill | `maxReagentSkill × Σ_s w_s·Σ_i f(rank_i)·n_i ÷ Σ_s w_s·q_s`; rank factor 2-rank {0, 1}, 3-rank {0, 0.5, 1}; `w_s` = `ModifiedCraftingCategory.MatQualityWeight` | CraftSim `ReagentOptimization.lua` header, `IsSimplifiedQualityRecipe` |
| Concentration cost | piecewise-linear `skillCurve(skill/difficulty) × difficultyCurve(difficulty)`, minus `Σ lessFactor × cost`, rounded; skill capped at difficulty; skill-curve x = `Pos[0] ÷ 100` | CraftSim `RecipeData:GetConcentrationCostForSkill`, `UTIL:CalculateConcentrationCost`, `UTIL:FindBracketData`, `DevTools/DataMining/ConcentrationCurveData/mapper.py` |
| Midnight 2-quality curve shape (most common) | `{0,2.35},{0.6,2.2},{0.8,1.1},{0.9999,1.0},{1.0,0}` × constant 80–425 (200 most common) | CraftSim `Data/ConcentrationCurveData.lua` |
| Ingenuity | expected concentration = `cost × (1 − chance × (0.5 + extra))` | CraftSim `RecipeData:GetConcentrationValue` |
| Multicraft | `maxExtra = C(baseYield) × baseYield × (1 + extra)`, extra items on proc `(1 + maxExtra)/2`; `C`: 1→2.1, 2→1.83, 5→1.875, else 2.5 | CraftSim `CALC:GetExpectedItemAmountMulticraft`, `CONST.MULTICRAFT_CONSTANTS` (approximation) |
| Resourcefulness | saving on proc = `requiredCost × 0.30 × (1 + extra)` | CraftSim `CONST.BASE_RESOURCEFULNESS_AVERAGE_SAVE_FACTOR` (CraftSim calls it an approximation) |
| Optional-reagent rating → fraction | multicraft ÷1100, resourcefulness ÷900, ingenuity ÷1000; finishing effects × `ReagentEffectPct ÷ 100` | CraftSim `CONST.PERCENT_DIVISION_FACTORS[11]`, `OptionalReagentData/mapper.py` |
| `CraftingOperationInfo` | `baseDifficulty, bonusDifficulty, baseSkill, bonusSkill, quality, craftingQuality, craftingDataID, lowerSkillThreshold, upperSkillTreshold` [sic], `bonusStats{bonusStatName, bonusStatValue, ratingPct, bonusRatingPct}, concentrationCost, ingenuityRefund` | `TradeSkillUITypesDocumentation.lua` |
| `CraftingReagentInfo` / `CraftRecipe` | `{ reagent = { itemID }, dataSlotIndex, quantity }`; `CraftRecipe(recipeSpellID, numCasts, craftingReagents, recipeLevel, orderID, applyConcentration)`; Blizzard passes only `ModifiedReagent` slots | `TradeSkillUIDocumentation.lua`, `ProfessionsRecipeTransactionMixin:CraftRecipe` |
| Dock/hook points | `ProfessionsFrame` (LoadOnDemand `Blizzard_Professions`); `.CraftingPage.SchematicForm` (`GetTransaction()`, `UpdateAllSlots()`, `ProfessionsRecipeSchematicFormMixin.Event.AllocationsModified`); transaction `GetAllocations(slotIndex):Clear()/:Allocate(reagent, qty)`, `SetManuallyAllocated(true)`, `CreateCraftingReagentInfoTbl()`; `.CraftingPage.RecipeList.ScrollBox` (`ScrollBoxListMixin.Event.OnInitializedFrame`, `ForEachFrame`); `EventRegistry` `"ProfessionsRecipeListMixin.Event.OnRecipeSelected"`, `"Professions.TransactionUpdated"` | `Blizzard_Professions*.xml/lua`, `Blizzard_ProfessionsTemplates/*`, `ScrollBox.lua` |
| Auctionator search term | `{ searchString = name, isExact = true, quantity = n, tier = rank }` → `ConvertToSearchString(callerID, term)` → `CreateShoppingList(callerID, listName, searchStrings)` | CraftSim `Modules/Shopping/Shopping.lua` |

## Review Focus

1. **Alt or recipe with no calibration record** (alt never opened that profession since install, or the recipe was learned since): `Evaluate` must return an estimate from Scanner skill, `0.40 × baseDifficulty` and the schematic's `craftingDataID`, flagged `staleData = true, estimated = true`, shown as "estimate" — never an error, never shown as certain. Test: Task 8 `estimates_without_calibration`.
2. **Item names not yet cached** when exporting the shopping list: skip the item, call `C_Item.RequestLoadItemDataByID`, report "N items skipped, try again", never send an empty search string. Test: Task 12 `skips_uncached_names`.
3. **Craft Next clicked with the wrong window or character** (window closed, other profession open, entry belongs to an alt, reagents missing, cooldown not ready): no `CraftRecipe` call; status "Open <Profession> on <Character>" / "missing reagents" / "ready at". Tests: Task 12 `craft_next_*`.
4. **Reagent slots the optimizer has not seen**: weight 0 or missing from GameData, single-item slots, a missing price on one rank, mixed 2-rank and 3-rank slots. No divide-by-zero; unweighted slots fixed at their cheapest priced rank; a slot with no priced option sets `missingPrice`. Tests: Task 5 `unweighted_slot_fixed`, `missing_rank_price`, `mixed_rank_slots`.
5. **Blizzard frame layout changes or Blizzard_Professions not loaded yet**: ProfessionPanel and RecipeListLabels wait for `ADDON_LOADED("Blizzard_Professions")`; a missing child frame disables the module with one chat line and no Lua error. Test: Task 17 `disables_when_scrollbox_missing`.

**Not verified against the game; Task 9 pins them from `/fs capture` golden fixtures before any UI task:** reagent-skill rounding (none/floor/round); whether `maxReagentSkill` scales with base or total difficulty; the 0.40 default for Midnight; concentration rounding (half-up assumed); units of 1a's `QualityThresholds` (percent assumed) and of the skill curve's `Pos[0]` (percent assumed, ÷100); which ProfessionEffect `type<N>` is Ingenuity and how optional-reagent ratings convert; whether `craftingQuality` or `quality` is the rank to compare; ingenuity refund fraction vs `ingenuityRefund`; whether the weight reached through `CraftingReagentQuality.ModifiedCraftingCategoryID` matches CraftSim's `Item → ModifiedCraftingReagentItem` path. Multicraft constants and the 0.30 resourcefulness factor stay CraftSim approximations (operation info cannot check them).

---

## File Structure

| File | Responsibility |
|---|---|
| `Math/Quality.lua` | `ns.Math.Round`, thresholds, prediction, reagent skill. |
| `Math/Concentration.lua` | Concentration cost curve, ingenuity expectation, gold per point. |
| `Math/Stats.lua` | Multicraft/resourcefulness expectations, bonus-stat parsing, optional-reagent effects. |
| `Math/Optimizer.lua` | Per-slot compositions, knapsack DP, cheapest allocation per reachable quality. |
| `Math/Profit.lua` | Expected sale, `EvaluateCraft`, `EvaluateAllocation` (the pure entry points). |
| `Modules/CraftingData.lua` | Pure adapter: 1a GameData → weights, curves, thresholds, optional stats; `BuildInput`; reagent-info → allocation. |
| `Modules/Recipes.lua` | Settings, calibration, `Evaluate`, cache, `WhoCanCraft`, `FindRecipesForItem`, `PredictLive`. |
| `Modules/RecipeScan.lua` | Time-sliced scan and `GetRanked` (extends Recipes). |
| `Modules/Queue.lua` | Entries, restock, missing reagents, costs. |
| `Modules/QueueCraft.lua` | Shopping list, `CraftNext`, craft-result accounting, cooldowns (extends Queue). |
| `Modules/SelfCheck.lua` | Live prediction vs `GetCraftingOperationInfo`; logs via `Diagnostics:LogMismatch`. |
| `UI/Tabs/Dashboard.lua` | Dashboard module and tab, `RegisterWidget`, phase-1 widgets. |
| `UI/Tabs/Recipes.lua` | Recipes tab. |
| `UI/Tabs/Queue.lua` | Queue tab and restock editor. |
| `UI/ProfessionPanel.lua` | Panel docked beside `ProfessionsFrame`. |
| `UI/RecipeListLabels.lua` | Profit labels on Blizzard recipe-list rows. |
| `UI/Tooltips.lua` | Tooltips module, `RegisterLineProvider`, craft-cost and crafters lines. |
| `tools/export_math_fixtures.lua` | SavedVariables (1a captures + 1b calibrations + mismatch contexts) → `tests/fixtures/math/*.lua` + `index.lua`. |
| `tests/helpers/crafting_world.lua` | `make_world`: 1a stubs + addon load + seeded world for Recipes/Queue/UI specs. |
| `tests/helpers/professions_frame.lua` | Fake `ProfessionsFrame` tree (schematic form, transaction, recipe-list ScrollBox) on top of 1a's `CreateFrame` fake. |

### Shared shapes

```lua
-- MathSlot (one required reagent slot as Math sees it)
{ slotIndex = 1, quantity = 10, weight = 48,                       -- weight 0 = gives no skill
  items = { { itemID = 1001, rank = 1, price = 100, owned = 0, provided = 0 },     -- ordered by rank; one item = non-quality slot
            { itemID = 1002, rank = 2, price = 300, owned = 0, provided = 0 } } }  -- price nil = no price

-- Curve (CraftingData.Curve)
{ constant = { {0, 200}, {1000, 200} }, curve = { {0, 2.35}, {0.6, 2.2}, {0.8, 1.1}, {0.9999, 1.0}, {1.0, 0} } }

-- RecipeInput (CraftingData.BuildInput → Math.Profit.EvaluateCraft)
{ maxQuality = 2, baseDifficulty = 700, baseSkill = 500, maxReagentSkill = 280|nil,
  thresholdFractions = {1.0}|nil,                                  -- nil → Quality.THRESHOLD_FRACTIONS
  slots = { MathSlot... },                                         -- required slots only
  optionals = { { itemID, price, stats = { skill=, increasedifficulty=, multicraft=, resourcefulness=, ingenuity=, reduceconcentrationcost= } } },
  stats = { multicraft = 0.2|nil, resourcefulness = 0.25|nil, ingenuity = 0.2|nil, multicraftExtra = 0, resourcefulnessExtra = 0, ingenuityExtra = 0 },
  yield = { min = 1, max = 1 }, outputPrices = { [1] = 60000, [2] = 100000 },
  concentration = { curve = Curve|nil, lessFactors = {} },
  useConcentration = false, targetQuality = nil }

-- MathResult (EvaluateCraft / EvaluateAllocation)
{ expectedQuality, qualityChances = {[q] = 1}, skill, difficulty, thresholds, lowerThreshold, nextThreshold,
  allocation = ReagentAllocation, reagentCost, requiredCost, expectedSale, profit,
  concentrationCost, expectedConcentrationCost, goldPerConcentration,
  concentrationCostForAllocation,                                  -- Concentration.Cost at this allocation's skill
  multicraftValue, resourcefulnessValue, ingenuityValue, expectedYield,
  perQuality = { [q] = { allocation, reagentCost, skill, profit } }, missingPrice = bool }

-- CalibRecord (db.global.recipeCalib[charKey][recipeID])
{ time, baseSkill, baseDifficulty, maxReagentSkill|nil, craftingDataID, stats = { multicraft?, resourcefulness?, ingenuity? } }

-- MathFixture (tests/fixtures/math/*.lua)
{ source = "capture"|"mismatch", calib = CalibRecord, schematic, reagents = {CraftingReagentInfo}, operationInfo, gameData = { [tableName] = rows } }
```

`RecipeResult` (contract) = `MathResult` + `recipeID, charKey, flags`. Additive fields beyond the contract: every `MathResult` field the contract does not name, `priceAgeDays` (oldest price used) and `flags.estimated`. `ingenuityValue` is expected concentration points refunded per craft (not copper).

---

### Task 1: CraftingData adapter over 1a GameData

**Files:**
- Create: `Modules/CraftingData.lua`
- Modify: `FabricationStation.toc`, `.luacheckrc` (add `files["Modules/CraftingData.lua"] = { std = "lua51" }` so 1a's purity lint covers it)
- Test: `tests/crafting/crafting_data_spec.lua`

**Interfaces:**
- Consumes: `ns.GameData.Get(name)` for `ReagentQuality`, `ReagentCategories`, `OptionalReagents`, `CraftingData`, `ItemCraftingData`, `QualityThresholds`, `ConcentrationCurves` (1a Task 6 shapes).
- Produces `ns.CraftingData` (pure; each function takes `gd = ns.GameData` first):
  - `ReagentWeight(gd, itemID) -> number` (`ReagentCategories[ReagentQuality[itemID].categoryID].matQualityWeight`; 0 when absent).
  - `Curve(gd, craftingDataID) -> Curve|nil` (`ConcentrationCurves[CraftingData[id].craftingDifficultyID]`; `curve` = its `skill` points with x ÷ 100; `constant` = its `difficulty` points).
  - `ThresholdFractions(gd, craftingDataID, maxQuality) -> {number}|nil` (tiers 2..maxQuality of `QualityThresholds`, ÷ 100, ascending; nil if any tier is missing).
  - `CraftingDataIDFor(gd, schematic) -> integer|nil` (`schematic.craftingDataID`, else `ItemCraftingData[schematic.outputItemIDs[1]]`).
  - `EFFECT_MAP = { skill = "skill", multicraft = "multicraft", resourcefulness = "resourcefulness" }` (Task 9 adds the Ingenuity and concentration-reduction `type<N>` keys once fixtures identify them).
  - `OptionalStats(gd, itemID, kind) -> stats` (`increasedifficulty = ReagentQuality[itemID].maxDifficultyAdjustment` when > 0; mapped `OptionalReagents` effects summed, unmapped types ignored; `kind == "finishing"` scales effects by `reagentEffectPct / 100`).
  - `AllocationFromReagentInfo(schematic, infos) -> allocation, optionalItemIDs` (maps `dataSlotIndex` → `slotIndex` via `schematic.reagentSlots[*].dataSlotIndex`; optional/finishing slots go to `optionalItemIDs`).

- [ ] **Step 1: Write the failing test**

```lua
describe("CraftingData", function()
  local ns, CD, gd
  before_each(function()
    install_wow_stubs(); ns = load_addon({}, "Modules/CraftingData.lua"); CD, gd = ns.CraftingData, ns.GameData
    gd.Define("ReagentQuality", 70575, { [1002] = { rank = 2, categoryID = 50, maxDifficultyAdjustment = 0, reagentEffectPct = 0 },
                                         [7001] = { rank = 1, categoryID = 60, maxDifficultyAdjustment = 35, reagentEffectPct = 0 },
                                         [7002] = { rank = 1, categoryID = 61, maxDifficultyAdjustment = 0, reagentEffectPct = 50 } })
    gd.Define("ReagentCategories", 70575, { [50] = { matQualityWeight = 48 } })
    gd.Define("OptionalReagents", 70575, { [7002] = { categoryID = 61, effects = { { type = "multicraft", amount = 60 }, { type = "type42", amount = 9 } } } })
    gd.Define("CraftingData", 70575, { [2588] = { craftingDifficultyID = 77, difficulty = 700, craftedItemID = 5001 } })
    gd.Define("ItemCraftingData", 70575, { [5001] = 2588 })
    gd.Define("QualityThresholds", 70575, { [77] = { [1] = 0, [2] = 100 } })
    gd.Define("ConcentrationCurves", 70575, { [77] = { skill = { {0,2.35},{60,2.2},{80,1.1},{99.99,1.0},{100,0} }, difficulty = { {0,200},{1000,200} } } })
  end)
  it("reagent weight", function() assert.equals(48, CD.ReagentWeight(gd, 1002)); assert.equals(0, CD.ReagentWeight(gd, 424242)) end)
  it("curve in fractions", function()
    assert.same({ constant = { {0,200},{1000,200} }, curve = { {0,2.35},{0.6,2.2},{0.8,1.1},{0.9999,1.0},{1,0} } }, CD.Curve(gd, 2588))
    assert.is_nil(CD.Curve(gd, 1))
  end)
  it("threshold fractions", function() assert.same({ 1.0 }, CD.ThresholdFractions(gd, 2588, 2)); assert.is_nil(CD.ThresholdFractions(gd, 2588, 5)) end)
  it("craftingDataID from schematic or output item", function()
    assert.equals(2588, CD.CraftingDataIDFor(gd, { craftingDataID = 2588, outputItemIDs = {} }))
    assert.equals(2588, CD.CraftingDataIDFor(gd, { outputItemIDs = { [1] = 5001 } }))
  end)
  it("optional and finishing stats", function()
    assert.same({ increasedifficulty = 35 }, CD.OptionalStats(gd, 7001, "optional"))
    assert.same({ multicraft = 30 }, CD.OptionalStats(gd, 7002, "finishing"))      -- 60 × 50 %, type42 ignored
  end)
  it("maps reagent info back to slots", function()
    local schematic = { reagentSlots = { { slotIndex = 1, dataSlotIndex = 4, kind = "basic" }, { slotIndex = 4, dataSlotIndex = 9, kind = "finishing" } } }
    local alloc, opt = CD.AllocationFromReagentInfo(schematic, { { reagent = { itemID = 1002 }, dataSlotIndex = 4, quantity = 7 }, { reagent = { itemID = 7002 }, dataSlotIndex = 9, quantity = 1 } })
    assert.same({ { slotIndex = 1, itemID = 1002, quantity = 7 } }, alloc); assert.same({ 7002 }, opt)
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/crafting/crafting_data_spec.lua`
Expected: FAIL — `Modules/CraftingData.lua` missing.

- [ ] **Step 3: Implement `Modules/CraftingData.lua`** (Interfaces above); add it to the TOC after `Modules\Diagnostics.lua`.

- [ ] **Step 4: Run test to verify it passes**

Run: `busted tests/crafting/crafting_data_spec.lua && luacheck Modules/CraftingData.lua`
Expected: PASS (6 tests), 0 warnings.

- [ ] **Step 5: Commit**

```bash
git add Modules/CraftingData.lua tests/crafting/crafting_data_spec.lua FabricationStation.toc .luacheckrc
git commit -m "feat: add CraftingData adapter over GameData tables"
```

---

### Task 2: Math.Quality

**Files:**
- Create: `Math/Quality.lua`
- Modify: `FabricationStation.toc`
- Test: `tests/math/quality_spec.lua`

**Interfaces:**
- Consumes: nothing.
- Produces: `ns.Math.Round(x) -> integer`; `ns.Math.Quality.THRESHOLD_FRACTIONS = { [1] = {}, [2] = {1.0}, [3] = {0.5, 1.0}, [5] = {0.2, 0.5, 0.8, 1.0} }`; `Quality.DEFAULT_REAGENT_SKILL_FACTOR = 0.40`; `Quality.Thresholds(maxQuality, difficulty, fractions|nil) -> {number}|nil` (skill needed for qualities 2..max; nil for an unsupported maxQuality without fractions); `Quality.Predict(skill, difficulty, maxQuality, fractions|nil) -> quality, nextThreshold|nil, lowerThreshold`; `Quality.RankFactor(rank, numRanks) -> number`; `Quality.ReagentSkill(slots, allocation, maxReagentSkill) -> number` (unrounded).

- [ ] **Step 1: Write the failing test**

```lua
local ns = load_files({}, { "Math/Quality.lua" })
local Q = ns.Math.Quality
local A  = { slotIndex = 1, quantity = 10, weight = 48, items = { {itemID=11,rank=1},{itemID=12,rank=2},{itemID=13,rank=3} } }
local B  = { slotIndex = 2, quantity = 5,  weight = 32, items = { {itemID=21,rank=1},{itemID=22,rank=2},{itemID=23,rank=3} } }
local A2 = { slotIndex = 1, quantity = 10, weight = 48, items = { {itemID=11,rank=1},{itemID=12,rank=2} } }
local B2 = { slotIndex = 2, quantity = 5,  weight = 32, items = { {itemID=21,rank=1},{itemID=22,rank=2} } }
describe("Math.Quality", function()
  it("thresholds", function()
    assert.same({100, 250, 400, 500}, Q.Thresholds(5, 500))
    assert.same({350, 700}, Q.Thresholds(3, 700))
    assert.same({400}, Q.Thresholds(2, 400))
    assert.same({}, Q.Thresholds(1, 100))
    assert.is_nil(Q.Thresholds(4, 100))
    assert.same({360}, Q.Thresholds(2, 400, {0.9}))                -- GameData fractions win
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

`Predict` counts thresholds with `skill >= t`; `lowerThreshold` is the reached quality's threshold (0 for quality 1). `ReagentSkill` uses `numRanks = #slot.items`, ignores allocation rows for unweighted slots, returns `maxReagentSkill × Σ w·f·n ÷ Σ w·quantity` (0 when the denominator is 0). CraftSim header comment.

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
- Produces: `ns.Math.Concentration.BASE_INGENUITY_REFUND = 0.5`; `Concentration.Cost(curve|nil, skill, difficulty, lessFactors|nil) -> integer` (0 for nil curve); `Concentration.Expected(cost, ingenuityChance|nil, refundFraction) -> number`; `Concentration.GoldPerPoint(profitWith, profitWithout, expectedCost) -> integer|nil`.

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
  it("subtracts less-concentration factors before rounding", function() assert.equals(297, C.Cost(MID, 280, 400, {0.1})) end)
  it("ingenuity expectation", function() assert.equals(270, C.Expected(300, 0.2, 0.5)); assert.equals(300, C.Expected(300, nil, 0.5)) end)
  it("gold per point", function() assert.equals(333, C.GoldPerPoint(120000, 30000, 270)); assert.is_nil(C.GoldPerPoint(1, 0, 0)) end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/math/concentration_spec.lua`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement `Math/Concentration.lua`**

The bracket search and interpolation decide the edge values, so they are pinned here (CraftSim `FindBracketData` + `CalculateConcentrationCost`):

```lua
local function bracket(x, pts)                        -- pts sorted ascending by x
  for i = 1, #pts do
    if x >= pts[i][1] then
      local nxt = pts[i + 1]
      if not nxt then return pts[i], nil end
      if x <= nxt[1] then return pts[i], nxt end
    end
  end
end
local function lerp(p0, p1, x)
  if not p1 or p1[1] == p0[1] then return p0[2] end
  return p0[2] + (p1[2] - p0[2]) * (x - p0[1]) / (p1[1] - p0[1])
end
function Concentration.Cost(curve, skill, difficulty, lessFactors)
  if not curve or difficulty <= 0 then return 0 end
  skill = math.min(skill, difficulty)
  local s, e = bracket(skill / difficulty, curve.curve)
  s, e = s or { 0, 0 }, e or { 1, 1 }
  local c0, c1 = bracket(difficulty, curve.constant)
  local k = lerp(c0 or curve.constant[1], c1, difficulty)
  local value = lerp({ difficulty * s[1], s[2] }, { difficulty * e[1], e[2] }, skill)
  local cost = value * k
  local less = 0
  for _, f in ipairs(lessFactors or {}) do less = less + cost * f end
  return ns.Math.Round(cost - less)
end
```

`GoldPerPoint = Round((profitWith - profitWithout) / expectedCost)`, nil when `expectedCost <= 0`. CraftSim header comment.

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
- Produces: `ns.Math.Stats.MULTICRAFT_CONSTANTS = { default = 2.5, [1] = 2.1, [2] = 1.83, [5] = 1.875 }`; `Stats.RESOURCEFULNESS_SAVE_FACTOR = 0.30`; `Stats.RATING_PER_UNIT = { multicraft = 1100, resourcefulness = 900, ingenuity = 1000 }`; `Stats.ExpectedYield(baseYield, mcChance|nil, mcExtra|nil) -> expected, extraOnProc`; `Stats.ResourcefulnessSaving(requiredCost, resChance|nil, resExtra|nil) -> number`; `Stats.ParseBonusStats(bonusStats, names) -> { multicraft?, resourcefulness?, ingenuity? }` (fractions; `ratingPct` 0 or absent → nil = unsupported); `Stats.ApplyOptionals(stats, optionals) -> newStats, skillBonus, difficultyBonus, lessConcentrationFactors`.

- [ ] **Step 1: Write the failing test**

```lua
local S = load_files({}, { "Math/Stats.lua" }).Math.Stats
describe("Math.Stats", function()
  it("multicraft expected yield", function()
    assert.same({1.31, 1.55}, { S.ExpectedYield(1, 0.2, 0) })
    assert.same({5.51875, 5.1875}, { S.ExpectedYield(5, 0.1, 0) })
    assert.same({3.425, 4.25}, { S.ExpectedYield(3, 0.1, 0) })        -- default constant 2.5
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
    assert.equals(10, skill); assert.equals(35, diff); assert.near(0.3, stats.multicraft, 1e-9); assert.same({0.1}, less)
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/math/stats_spec.lua`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement `Math/Stats.lua`**

`ExpectedYield`: `C = MULTICRAFT_CONSTANTS[baseYield] or default`; `maxExtra = C × baseYield × (1 + extra)`; `extraOnProc = (1 + maxExtra) / 2`; `expected = baseYield + chance × extraOnProc`. `ApplyOptionals` copies `stats`, adds rating ÷ `RATING_PER_UNIT` (creating the stat if absent), sums `skill` and `increasedifficulty`, turns each `reduceconcentrationcost` amount into `amount / 100`. CraftSim header comment.

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
- Produces: `ns.Math.Optimizer.Compositions(slot) -> { [units] = { cost, counts = {[rank] = n} } }` (units = `Σ 2·f(rank)·n` before weighting; cost `Σ max(0, n_rank − owned_rank − provided_rank) × price_rank`; an item with nil price is usable only up to `owned + provided`); `Optimizer.CheapestByQuality(input: RecipeInput) -> perQuality: { [q] = { allocation, reagentCost, skill } }, missingPrice: bool` (required slots only; unreachable qualities absent); `Optimizer.AllocationCost(slots, allocation) -> copper|nil`.

- [ ] **Step 1: Write the failing test**

```lua
local ns = load_files({}, { "Math/Quality.lua", "Math/Optimizer.lua" })
local O = ns.Math.Optimizer
local function slot(i, q, w, prices) local items = {}
  for r, p in ipairs(prices) do items[r] = { itemID = i * 1000 + r, rank = r, price = p or nil, owned = 0, provided = 0 } end  -- false = no price
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
  it("owned reagents are free up to their count", function()
    local s = slot(1, 10, 48, {100, 300}); s.items[2].owned = 5
    assert.equals(500, O.Compositions(s)[10].cost)
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
    assert.equals(100, O.CheapestByQuality(input(700, { slot(1, 2, 0, {500, 50}) }))[2].reagentCost)
  end)
  it("missing_rank_price", function()
    local per, missing = O.CheapestByQuality(input(500, { slot(1, 10, 48, {100, false}), slot(2, 5, 32, {200, 300}) }))
    assert.is_false(missing); assert.is_nil(per[2])           -- only 20 of 80 units left, 58 needed
    local _, missing2 = O.CheapestByQuality(input(500, { slot(1, 10, 48, {false, false}) }))
    assert.is_true(missing2)
  end)
  it("mixed_rank_slots", function()
    local per = O.CheapestByQuality(input(500, { slot(1, 10, 48, {100, 300}), slot(2, 4, 32, {10, 30, 45}) }))
    assert.is_table(per[2]); assert.is_true(per[2].skill >= 700)
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/math/optimizer_spec.lua`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement `Math/Optimizer.lua`**

Compositions enumerate rank counts summing to `quantity` (2 ranks: `quantity + 1` options; 3 ranks: `O(q²)`), keeping the cheapest per unit value. A slot with one item or weight 0 gets one composition (cheapest usable rank) at 0 units. Provided reagents (orders) fix their counts. Knapsack over weighted slots (weights ÷ their GCD; GCD 0 → 1):

```lua
-- Umax = Σ quantity_s * 2 * (weight_s / g); a composition's weighted units = cu * (weight_s / g)
local best, choice = { [0] = 0 }, {}
for s, sl in ipairs(weighted) do
  local nb, pick = {}, {}
  for u, c in pairs(best) do
    for cu, comp in pairs(sl.comps) do
      local nu, nc = u + cu * sl.w, c + comp.cost
      if nb[nu] == nil or nc < nb[nu] then nb[nu], pick[nu] = nc, { prev = u, comp = comp } end
    end
  end
  best, choice[s] = nb, pick
end
for q = 1, maxQuality do
  local need = (q == 1) and 0 or (thresholds[q - 1] - baseSkill)
  local uNeed = need <= 0 and 0 or (Umax > 0 and math.ceil(need * Umax / maxReagentSkill - 1e-9) or math.huge)
  -- answer = min cost over u >= uNeed in best; ties prefer larger u (more skill → cheaper concentration)
  -- rebuild counts by walking choice[] backwards from u; skill = baseSkill + maxReagentSkill * u / Umax
end
```

`maxReagentSkill` nil → `DEFAULT_REAGENT_SKILL_FACTOR × baseDifficulty`. Allocation rows in slot order then rank order, zero counts omitted; fixed slots included with their cost. CraftSim header comment (`Modules/ReagentOptimization/ReagentOptimization.lua`).

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
- Produces: `ns.Math.Profit.AH_CUT = 0.95`; `Profit.ExpectedSale(qualityChances, outputPrices, expectedYield) -> number|nil`; `Profit.EvaluateCraft(input: RecipeInput) -> MathResult`; `Profit.EvaluateAllocation(input, allocation, optionalItemIDs|nil) -> MathResult` (no optimisation; live prediction, golden fixtures, self-check).

Rules (spec §6.1):
- Optionals via `Stats.ApplyOptionals`: `skill = baseSkill + skillBonus + reagentSkill`, `difficulty = baseDifficulty + difficultyBonus`; thresholds use `difficulty` and `thresholdFractions`; the `maxReagentSkill` default uses `baseDifficulty`.
- Plain plans: one per reachable quality `q` (`Optimizer.CheapestByQuality`). Concentration plans: for each reachable `q < maxQuality`, quality `q + 1` at `Concentration.Cost(curve, skill_q, difficulty, less)`.
- Per plan: `reagentCost = required + optional cost`; `resourcefulnessValue = Stats.ResourcefulnessSaving(requiredCost, ...)`; `expectedSale = ExpectedSale({[q]=1}, outputPrices, ExpectedYield(...))`; `profit = expectedSale − (reagentCost − resourcefulnessValue)`; `multicraftValue = price_q × (expectedYield − baseYield) × AH_CUT`, `baseYield = (min + max) / 2`.
- `targetQuality` set → that quality's plan (concentration plan when `useConcentration`); if that quality is unreachable, the plan for the highest reachable quality is returned with `flags.unreachableTarget = true` (never an error; test `unreachable_target_returns_best_with_flag`); else the max-profit plan of the requested kind. Plans with nil profit never beat priced plans.
- `missingPrice = true` when any reachable quality's output price is nil or a required slot had no priced option; `profit`/`expectedSale` are nil only when the chosen plan's own output price is nil.
- `goldPerConcentration = GoldPerPoint(best concentration-plan profit, best plain-plan profit, Expected(cost, ingenuity, 0.5 + ingenuityExtra))`; `concentrationCost`, `expectedConcentrationCost`, `ingenuityValue = cost × ingenuity × (0.5 + extra)` describe that concentration plan; 0/nil when there is none or `curve` is nil.
- `concentrationCostForAllocation = Concentration.Cost(curve, skill, difficulty, less)` at the returned allocation's skill (0 at max quality, nil without curve).
- Copper outputs pass through `Round`.

- [ ] **Step 1: Write the failing test**

```lua
local ns = load_files({}, { "Math/Quality.lua","Math/Concentration.lua","Math/Stats.lua","Math/Optimizer.lua","Math/Profit.lua" })
local P = ns.Math.Profit
local MID = { constant = { {0,200},{1000,200} }, curve = { {0,2.35},{0.6,2.2},{0.8,1.1},{0.9999,1.0},{1.0,0} } }
local function slot(i, q, w, prices) local items = {}
  for r, p in ipairs(prices) do items[r] = { itemID = i * 1000 + r, rank = r, price = p or nil, owned = 0, provided = 0 } end
  return { slotIndex = i, quantity = q, weight = w, items = items } end
local function scenario(over) local t = { maxQuality = 2, baseDifficulty = 700, baseSkill = 500, maxReagentSkill = 280,
  slots = { slot(1,10,48,{100,300}), slot(2,5,32,{200,300}), slot(3,2,0,{500}) }, optionals = {},
  stats = { multicraft = 0.2, resourcefulness = 0.25, ingenuity = 0.2 }, yield = { min = 1, max = 1 },
  outputPrices = { [1] = 60000, [2] = 100000 }, concentration = { curve = MID, lessFactors = {} } }
  for k, v in pairs(over or {}) do t[k] = v end; return t end
describe("Math.Profit", function()
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
    assert.near(31.4, r.ingenuityValue, 1e-9); assert.equals(6, r.goldPerConcentration)    -- (121675 − 120010) / 282.6
  end)
  it("uses concentration when asked", function()
    local r = P.EvaluateCraft(scenario({ useConcentration = true }))
    assert.equals(2, r.expectedQuality); assert.equals(3000, r.reagentCost); assert.equals(121675, r.profit)
  end)
  it("honours targetQuality", function() assert.equals(71895, P.EvaluateCraft(scenario({ targetQuality = 1 })).profit) end)
  it("missing output price is flagged, never zero", function()
    local r = P.EvaluateCraft(scenario({ outputPrices = { [1] = 60000 } }))
    assert.equals(1, r.expectedQuality); assert.is_true(r.missingPrice)
    local r2 = P.EvaluateCraft(scenario({ outputPrices = {} }))
    assert.is_nil(r2.profit); assert.is_true(r2.missingPrice)
  end)
  it("EvaluateAllocation predicts a given allocation", function()
    local r = P.EvaluateAllocation(scenario(), { {slotIndex=1,itemID=1002,quantity=10}, {slotIndex=2,itemID=2002,quantity=5}, {slotIndex=3,itemID=3001,quantity=2} })
    assert.equals(780, r.skill); assert.equals(2, r.expectedQuality); assert.equals(5500, r.reagentCost)
    assert.equals(0, r.concentrationCostForAllocation)
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/math/profit_spec.lua`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement `Math/Profit.lua`** following the rules above.

- [ ] **Step 4: Run all math specs and the purity check**

Run: `busted tests/math && luacheck Math && grep -nE "C_[A-Za-z]+|ns\.FS|_G\b|GetServerTime" Math/*.lua`
Expected: PASS; 0 warnings; grep prints nothing.

- [ ] **Step 5: Commit**

```bash
git add Math/Profit.lua tests/math/profit_spec.lua FabricationStation.toc
git commit -m "feat: add Math.Profit expected profit and concentration evaluation"
```

---

### Task 7: Recipes — settings and calibration

**Files:**
- Create: `Modules/Recipes.lua`, `tests/helpers/crafting_world.lua`
- Modify: `FabricationStation.toc`, `tests/helpers/init.lua` (expose `make_world`), `.luacheckrc` (add `make_world`, `fake_professions_frame` to test globals)
- Test: `tests/recipes/calibration_spec.lua`

**Interfaces:**
- Consumes: `ns.FS:CharKey/Now/RegisterOptions/SafeCall`, `Scanner:GetSchematic(recipeID)`, `Scanner:GetLiveOperationInfo(recipeID, allocation, applyConcentration)`, `Stats.ParseBonusStats`; `EventRegistry:RegisterCallback("ProfessionsRecipeListMixin.Event.OnRecipeSelected", fn, owner)` after `ADDON_LOADED("Blizzard_Professions")`.
- Produces:
  - `Recipes.DEFAULTS = { staleCalibrationDays = 14, queueUseWarband = true, tooltipCraftCost = true, applyWritesBlizzardSlots = true, selfCheck = true, scanBudgetMs = 4 }`; `Recipes:GetSetting(key)` (reads `settings.crafting`, then DEFAULTS); options group `"crafting"` (order 30) with one control per key. 1a's `settings.costing.ownedReagentsFree` and `settings.prices.staleAfterDays` are read where needed, not duplicated; ProfessionPanel and RecipeListLabels on/off is 1a's module toggle, not a crafting key.
  - `Recipes.STAT_NAMES = { multicraft = "Multicraft", resourcefulness = "Resourcefulness", ingenuity = "Ingenuity" }` (enUS; other locales later).
  - `Recipes:Calibrate(recipeID) -> CalibRecord|nil` — current character; two live calls with `applyConcentration = false`: empty allocation, and every slot with ≥ 2 reagents at its last (top-rank) reagent × `quantity`. `baseSkill` = empty-call `baseSkill + bonusSkill`; `maxReagentSkill` = top-call skill − `baseSkill` (nil without quality slots); plus `baseDifficulty`, `craftingDataID`, `stats = ParseBonusStats(empty.bonusStats, STAT_NAMES)`, `time`. Stored in `db.global.recipeCalib[charKey][recipeID]`; bumps the character's data stamp. Runs automatically on recipe selection in the Professions frame.
  - `Recipes:GetCalibration(charKey, recipeID) -> CalibRecord|nil`; `Recipes:GetDataStamp(charKey) -> integer`.
  - Test helper `make_world(opts) -> ns, W, world`: `W = install_wow_stubs(overrides)` where `overrides` = `opts.stubs` merged over `{ UnitName = function() return "Main" end, GetNormalizedRealmName = function() return "Realm" end }` (so `ns.FS:CharKey()` is `"Main-Realm"`, not 1a's default `"Thrall-ArgentDawn"`) plus fakes for `EventRegistry` (`RegisterCallback`, `TriggerEvent`), `TooltipDataProcessor.AddTooltipPostCall`, `Enum.TooltipDataType.Item` and `debugprofilestop`; `ns = load_addon({}, opts.last)`; defines GameData tables for the sample recipe; `W.boot()`; then replaces the public methods of the real `Scanner` and `Prices` modules with functions backed by `world` (`schematics, chars, items, warband, counts, prices, live`; `world.bumpPriceVersion()`). Base world: recipe 9001 = the Task 6 scenario as a contract Schematic plus 1a fields (`skillLineID = 2906`, `craftingDataID = 2588`, `maxQuality = 2`, `baseDifficulty = 700`, `quantityMin = quantityMax = 1`, `outputItemIDs = {[1]=5001,[2]=5002}`, slots 1–3 with reagents `{1001,1002}`, `{2001,2002}`, `{3001}`, `dataSlotIndex` 11/12/13, `dataSlotType` 2/2/1, kind "basic"); GameData weights 48 (1001/1002) and 32 (2001/2002), `CraftingData[2588].craftingDifficultyID = 77`, curve `MID` under 77, `QualityThresholds[77] = {[1]=0,[2]=100}`; prices 1001=100, 1002=300, 2001=200, 2002=300, 3001=500, 5001=60000, 5002=100000 (`ageDays` 1); `Main-Realm` (current) and `Alt-Realm` both know 9001 at profession skill 500. `opts.calibrate = { [charKey] = { recipeID... } | "all" }` stores `{ baseSkill = 500, baseDifficulty = 700, maxReagentSkill = 280, craftingDataID = 2588, stats = { multicraft = 0.2, resourcefulness = 0.25, ingenuity = 0.2 }, time = W.now }`. `opts.recipes = n` clones 9001 as 9001..9000+n with distinct prices; `world.outputOf(recipeID)` is its quality-2 item. `world.messages(name)` filters `W.messages`. Later tasks extend the helper with the fakes their specs use.

- [ ] **Step 1: Write the failing test**

```lua
describe("Recipes calibration", function()
  local ns, W, world, R
  before_each(function()
    ns, W, world = make_world({ last = "Modules/Recipes.lua" }); R = ns.FS:GetModule("Recipes")
    world.live[9001] = function(allocation)
      return { baseSkill = 480, bonusSkill = 20 + (#allocation > 0 and 280 or 0), baseDifficulty = 700, bonusDifficulty = 0,
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
  it("bumps the data stamp", function()
    local s = R:GetDataStamp("Main-Realm"); R:Calibrate(9001); assert.equals(s + 1, R:GetDataStamp("Main-Realm"))
  end)
  it("returns nil when the window is closed", function()
    world.live[9001] = nil; assert.is_nil(R:Calibrate(9001)); assert.is_nil(R:GetCalibration("Main-Realm", 9001))
  end)
  it("reads settings with defaults", function()
    assert.equals(4, R:GetSetting("scanBudgetMs"))
    ns.FS.db.global.settings.crafting = { scanBudgetMs = 8 }; assert.equals(8, R:GetSetting("scanBudgetMs"))
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/recipes/calibration_spec.lua`
Expected: FAIL — `make_world` undefined.

- [ ] **Step 3: Implement `tests/helpers/crafting_world.lua` and `Modules/Recipes.lua`** (Interfaces above).

- [ ] **Step 4: Run test to verify it passes**

Run: `busted tests/recipes/calibration_spec.lua && luacheck .`
Expected: PASS (4 tests); 0 warnings.

- [ ] **Step 5: Commit**

```bash
git add Modules/Recipes.lua tests/helpers/crafting_world.lua tests/helpers/init.lua .luacheckrc tests/recipes/calibration_spec.lua FabricationStation.toc
git commit -m "feat: add Recipes settings and per-character calibration from live operation info"
```

---

### Task 8: Recipes:Evaluate, cache, WhoCanCraft, FindRecipesForItem

**Files:**
- Modify: `Modules/Recipes.lua`, `Modules/CraftingData.lua`, `tests/helpers/crafting_world.lua`
- Test: `tests/recipes/evaluate_spec.lua`, `tests/crafting/build_input_spec.lua`

**Interfaces:**
- Consumes: Tasks 1, 6, 7; `Scanner:GetCharacters/GetCharacter/GetProfession/GetItemCount/GetSchematic`, `Prices:Get(itemID)`, `Prices:GetVersion()`, `Prices:IsStale(priceResult)`; message `FS_DATA_CHANGED`.
- Produces:
  - `ns.CraftingData.BuildInput(gd, args) -> RecipeInput` (pure), `args = { schematic, calib|nil, professionSkill, prices = {[itemID] = copper|nil}, owned = {[itemID] = n}|nil, provided = {[itemID] = n}|nil, optionalItemIDs|nil, useConcentration, targetQuality }`. With `calib`: its `baseSkill, baseDifficulty, maxReagentSkill, stats`. Without: `baseSkill = professionSkill`, `baseDifficulty = schematic.baseDifficulty`, `maxReagentSkill = nil`, `stats = {}`. Always: `craftingDataID = calib and calib.craftingDataID or CraftingDataIDFor(gd, schematic)`, curve and threshold fractions from it, slot weights from `ReagentWeight` of each slot's first reagent, optionals from `OptionalStats` with the slot's `kind`, `yield = { min = quantityMin, max = quantityMax }`, output prices from `outputItemIDs`; only `kind == "basic"` slots with a non-empty `reagents` list become `slots` (1a leaves currency-only reagents out of `reagents` and sets `slot.currencyID`; those slots are skipped).
  - `Recipes:Evaluate(recipeID, charKey, opts) -> RecipeResult` (contract). `opts.ownedReagentsFree` nil → 1a setting. Flags: `unknownRecipe` (not in `profession.recipes`; still evaluated), `staleData` (no calibration, calibration older than `staleCalibrationDays`, or character `lastSeen` older), `estimated` (no calibration), `stalePrice` (any used price `Prices:IsStale`), `noPrice = result.missingPrice`. `priceAgeDays` = oldest `ageDays` used. Owned = `bags + bank + reagentBank + warband` from `Scanner:GetItemCount(itemID, charKey)`.
  - `Recipes:PredictLive(recipeID, allocation, optionalItemIDs, applyConcentration) -> MathResult|nil` (current character; `EvaluateAllocation`).
  - `Recipes:FromCraftingReagentInfo(recipeID, infos) -> allocation, optionalItemIDs` (`CraftingData.AllocationFromReagentInfo` with `Scanner:GetSchematic`).
  - `Recipes:WhoCanCraft(recipeID) -> { charKey }` (contract; sorted); `Recipes:FindRecipesForItem(itemID) -> { { recipeID, quality } }` (reverse index over `db.global.schematics`; marked dirty on `FS_DATA_CHANGED(_, "recipes")` and `FS_RECIPES_CHANGED`, rebuilt on the next lookup — 1a caches schematics in 25-per-frame chunks after its `"recipes"` message, so the first index can be incomplete).
  - Cache key `recipeID|charKey|optsKey` (opts with defaults filled, keys sorted, nested tables such as `providedReagents` serialized recursively with sorted keys — test `cache_key_distinguishes_providedReagents`); an entry is valid while `Prices:GetVersion()` and `GetDataStamp(charKey)` are unchanged. `FS_DATA_CHANGED(charKey, kind)` bumps that stamp, except `kind == "items"` only when owned reagents are free, and `kind == "warband"` (account-wide, sent with the current charKey) bumps every character's stamp, also only when owned reagents are free.

- [ ] **Step 1: Write the failing tests**

`tests/crafting/build_input_spec.lua`: with the base-world GameData and schematic 9001, `BuildInput(gd, { schematic, calib = <calibrate record>, prices = <base prices> })` matches the Task 6 `scenario()` field by field (`maxReagentSkill == 280`, `slots[1].weight == 48`, `slots[2].weight == 32`, `slots[3].weight == 0`, `slots[3].items[1].price == 500`, `concentration.curve.curve[2]` = `{0.6, 2.2}`, `thresholdFractions` = `{1.0}`, `outputPrices` = `{[1]=60000,[2]=100000}`, `yield` = `{min=1,max=1}`); without `calib` and `professionSkill = 450`: `baseSkill == 450`, `maxReagentSkill == nil`, `stats` = `{}`, curve still present.

```lua
describe("Recipes:Evaluate", function()
  local ns, W, world, R
  before_each(function() ns, W, world = make_world({ last = "Modules/Recipes.lua", calibrate = { ["Main-Realm"] = { 9001 } } }); R = ns.FS:GetModule("Recipes") end)
  it("joins scanner, prices and math", function()
    local r = R:Evaluate(9001, "Main-Realm", {})
    assert.equals(9001, r.recipeID); assert.equals("Main-Realm", r.charKey)
    assert.equals(2, r.expectedQuality); assert.equals(120010, r.profit); assert.equals(6, r.goldPerConcentration)
    assert.same({ noPrice = false, stalePrice = false, staleData = false, unknownRecipe = false, estimated = false }, r.flags)
    assert.equals(1, r.priceAgeDays)
  end)
  it("estimates_without_calibration", function()
    local r = R:Evaluate(9001, "Alt-Realm", {})
    assert.is_true(r.flags.staleData); assert.is_true(r.flags.estimated)
    assert.equals(703, r.perQuality[2].skill)                  -- 500 + default 0.40 × 700
    assert.equals(314, r.concentrationCost)                    -- curve via the schematic's craftingDataID
  end)
  it("flags stale and missing prices", function()
    world.prices[5002].ageDays = 5; assert.is_true(R:Evaluate(9001, "Main-Realm", {}).flags.stalePrice)
    world.prices[5001], world.prices[5002] = nil, nil; world.bumpPriceVersion()
    local r = R:Evaluate(9001, "Main-Realm", {}); assert.is_true(r.flags.noPrice); assert.is_nil(r.profit)
  end)
  it("costs owned reagents at zero when the 1a setting is on", function()
    world.items["Main-Realm"][1001] = { bags = 10, bank = 0, reagentBank = 0 }
    ns.FS.db.global.settings.costing.ownedReagentsFree = true
    assert.equals(2000, R:Evaluate(9001, "Main-Realm", { targetQuality = 1 }).reagentCost)    -- 3000 − 10 × 100
  end)
  it("caches until price version or data stamp changes", function()
    local a = R:Evaluate(9001, "Main-Realm", {}); assert.equals(a, R:Evaluate(9001, "Main-Realm", {}))
    world.bumpPriceVersion(); local b = R:Evaluate(9001, "Main-Realm", {}); assert.are_not.equal(a, b)
    ns.FS:SendMessage("FS_DATA_CHANGED", "Main-Realm", "spec"); assert.are_not.equal(b, R:Evaluate(9001, "Main-Realm", {}))
  end)
  it("finds crafters and recipes for an item", function()
    assert.same({ "Alt-Realm", "Main-Realm" }, R:WhoCanCraft(9001))
    assert.same({ { recipeID = 9001, quality = 2 } }, R:FindRecipesForItem(5002)); assert.same({}, R:FindRecipesForItem(424242))
  end)
  it("maps live reagent info back to an allocation", function()
    assert.same({ { slotIndex = 1, itemID = 1002, quantity = 7 } },
      (R:FromCraftingReagentInfo(9001, { { reagent = { itemID = 1002 }, dataSlotIndex = 11, quantity = 7 } })))
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted tests/recipes/evaluate_spec.lua tests/crafting/build_input_spec.lua`
Expected: FAIL — `Evaluate` / `BuildInput` undefined.

- [ ] **Step 3: Implement** the Interfaces above.

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted tests/recipes tests/crafting`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Modules/Recipes.lua Modules/CraftingData.lua tests/helpers/crafting_world.lua tests/recipes/evaluate_spec.lua tests/crafting/build_input_spec.lua
git commit -m "feat: add Recipes:Evaluate with flags, caching, WhoCanCraft and item lookup"
```

---

### Task 9: Golden fixtures from `/fs capture` and pinned constants

This task checks the Math against the game before any UI is built on it.

**Files:**
- Create: `tools/export_math_fixtures.lua`, `tests/tools/export_math_fixtures_spec.lua`, `tests/math/golden_spec.lua`, `tests/fixtures/math/index.lua`, `tests/fixtures/math/*.lua`
- Modify (only where fixtures disagree): `Math/*.lua`, `Modules/CraftingData.lua` (`EFFECT_MAP`, unit divisors)

**Interfaces:**
- Consumes: 1a's capture record in `db.global.captures.list` (`{ id, time, charKey, recipeID, schematic, reagents, operationInfo, operationInfoConcentration, ... }`), 1a's mismatch records in `db.global.diagnostics.mismatches` (`context` set by Task 19), `db.global.recipeCalib`, `ns.CraftingData.BuildInput/AllocationFromReagentInfo`, `Profit.EvaluateAllocation`, 1a's `tools/lib/serialize.lua`.
- Produces: `lua tools/export_math_fixtures.lua <SavedVariables/FabricationStation.lua> [outDir=tests/fixtures/math]`. It loads the file in an empty env (like 1a's `export_captures.lua`) and loads the committed `Data/GameData*.lua` files. For each capture whose `(charKey, recipeID)` has a calibration, and each mismatch with a `context`, it writes a MathFixture (`gameData` = only the GameData rows for that recipe: its reagents' `ReagentQuality`/`ReagentCategories`/`OptionalReagents`, its `CraftingData`, `ItemCraftingData`, `QualityThresholds` and `ConcentrationCurves` rows) as `<source>_<recipeID>_<id>.lua`, rewrites `index.lua` (`return { "file.lua", ... }`), and prints `exported N fixtures (M captures skipped: no calibration)`.

- [ ] **Step 1: Write the failing tests**

`tests/tools/export_math_fixtures_spec.lua`: write a temp SavedVariables file shaped like 1a's `tests/fixtures/sv/FabricationStation.lua` (whose own captures, 1001/1002, carry no schematic) with one capture for recipe 9001 and one `recipeCalib` entry for its character, plus one capture without calibration; `run_cmd("lua tools/export_math_fixtures.lua <tmp> <outDir>") == 0`; `dofile(outDir .. "/index.lua")` equals `{ "capture_9001_1.lua" }`; that fixture's `calib.baseSkill == 500`; stdout contains `1 captures skipped`.

`tests/math/golden_spec.lua`:

```lua
local index = dofile("tests/fixtures/math/index.lua")
describe("golden fixtures", function()
  if #index == 0 then pending("no fixtures yet — Task 9 Step 4") end
  for _, name in ipairs(index) do
    it(name, function()
      install_wow_stubs(); local ns = load_addon({}, "Modules/CraftingData.lua")
      local f = dofile("tests/fixtures/math/" .. name)
      for tbl, rows in pairs(f.gameData) do ns.GameData.Define(tbl, 1, rows) end
      local input = ns.CraftingData.BuildInput(ns.GameData, { schematic = f.schematic, calib = f.calib, prices = {} })
      local alloc, opt = ns.CraftingData.AllocationFromReagentInfo(f.schematic, f.reagents)
      local r, op = ns.Math.Profit.EvaluateAllocation(input, alloc, opt), f.operationInfo
      assert.near(op.baseSkill + op.bonusSkill, r.skill, 0.5)
      assert.equals(op.baseDifficulty + op.bonusDifficulty, r.difficulty)
      assert.equals(op.craftingQuality, r.expectedQuality)
      assert.equals(op.lowerSkillThreshold, r.lowerThreshold)
      if r.nextThreshold then assert.equals(op.upperSkillTreshold, r.nextThreshold) end
      if op.concentrationCost > 0 and input.concentration.curve then assert.equals(op.concentrationCost, r.concentrationCostForAllocation) end
    end)
  end
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted tests/tools/export_math_fixtures_spec.lua tests/math/golden_spec.lua`
Expected: FAIL — tool missing; golden spec errors on missing `index.lua`.

- [ ] **Step 3: Implement the exporter and add an empty `tests/fixtures/math/index.lua` (`return {}`)**

Run: `busted tests/tools/export_math_fixtures_spec.lua tests/math/golden_spec.lua`
Expected: exporter PASS; golden spec 1 pending.

- [ ] **Step 4: Capture real fixtures in game (manual)**

On each crafting character, open each profession, select the recipe (this calibrates it), set the reagents, and type `/fs capture` for: (a) a Midnight quality recipe, all rank 1; (b) the same, all rank 2; (c) a mix just under and (d) just over the quality-2 threshold; (e) a recipe with a difficulty-raising optional reagent; (f) one with a finishing reagent that adds skill; (g) one that adds ingenuity or reduces concentration; (h) a 5-quality recipe if one exists. At least two professions. `/reload`, then:

Run: `lua tools/export_math_fixtures.lua "<WoW>/_retail_/WTF/Account/<ACCOUNT>/SavedVariables/FabricationStation.lua" && busted tests/math/golden_spec.lua`
Expected: ≥ 8 fixtures exported; note every failing assertion.

- [ ] **Step 5: Pin the unverified constants from the failures**

Change only the named item, with a comment naming the fixture that proves it: reagent-skill rounding (`Quality.ReagentSkill`: none/floor/round); `maxReagentSkill` basis (base vs total difficulty); `Concentration.Cost` rounding; `QualityThresholds` divisor (`ThresholdFractions`); skill-curve `Pos[0]` divisor (`Curve`); `craftingQuality` vs `quality` (golden assert and `SelfCheck.QUALITY_FIELD`); Ingenuity and concentration-reduction effect types (`EFFECT_MAP` — read the `type<N>` fixture (g) exposes); optional-reagent rating divisors; ingenuity refund fraction (`op.ingenuityRefund / op.concentrationCost` vs `0.5 + extra`); weight path (if reagent skill is off by a constant ratio, compare `ReagentWeight` with CraftSim's `Data/ReagentWeightData.lua` value for that item). Multicraft constants and the 0.30 factor stay CraftSim approximations.

Run: `busted`
Expected: all specs PASS; golden spec green on every fixture.

- [ ] **Step 6: Commit**

```bash
git add tools/export_math_fixtures.lua tests/tools/export_math_fixtures_spec.lua tests/math/golden_spec.lua tests/fixtures/math/ Math/ Modules/CraftingData.lua
git commit -m "test: add golden math fixtures from /fs capture and pin constants"
```

---

### Task 10: Recipe scan (time-sliced) and GetRanked

**Files:**
- Create: `Modules/RecipeScan.lua`
- Modify: `FabricationStation.toc`, `tests/helpers/crafting_world.lua`
- Test: `tests/recipes/scan_spec.lua`

**Interfaces:**
- Consumes: `Recipes:Evaluate/Calibrate/GetSetting`, `Scanner:GetCharacters/GetCharacter/GetProfession/IsProfessionOpen`, `debugprofilestop()`, `CreateFrame` (driver), `ns.FS:Debounce`; messages `FS_PRICES_CHANGED`, `FS_DATA_CHANGED`.
- Produces: `Recipes:StartScan(charKey|nil)` (nil = every character); `Recipes:IsScanning() -> bool`; `Recipes:_ScanStep(budgetMs) -> done` (one frame's work; the driver frame's `OnUpdate` calls it with `GetSetting("scanBudgetMs")` and hides itself when done); `Recipes:GetRanked(filter) -> { RecipeResult }` (contract). One `FS_RECIPES_CHANGED` per completed pass. `FS_PRICES_CHANGED` → `StartScan(nil)`; `FS_DATA_CHANGED(charKey)` → `StartScan(charKey)` debounced 1 s. A `StartScan` during a pass marks it dirty; one restart follows. When `Scanner:IsProfessionOpen()` is true for the current character, the pass first calibrates that profession's known recipes (same coroutine and budget).

`GetRanked` filter `{ skillLineID?, charKey?, minQuality?, usesConcentration?, onlyProfitable?, sortBy = "profit"|"goldPerConcentration" }`. `usesConcentration` keeps results with a non-nil `goldPerConcentration`. Results with `flags.noPrice` or a nil sort key come after all priced results, by recipeID; `onlyProfitable` drops them and anything with `profit <= 0`.

- [ ] **Step 1: Write the failing test**

```lua
describe("recipe scan", function()
  local ns, W, world, R, clock
  before_each(function()
    ns, W, world = make_world({ last = "Modules/RecipeScan.lua", recipes = 10, calibrate = { ["Main-Realm"] = "all" } })
    R = ns.FS:GetModule("Recipes"); clock = 0
    _G.debugprofilestop = function() clock = clock + 1; return clock end      -- every call costs 1 ms
  end)
  it("is time-sliced and announces once", function()
    R:StartScan(nil); local steps = 0
    repeat steps = steps + 1 until R:_ScanStep(4) or steps > 50
    assert.is_true(steps >= 3); assert.is_false(R:IsScanning())
    assert.equals(1, #world.messages("FS_RECIPES_CHANGED"))
  end)
  it("ranks by profit with unpriced results last", function()
    world.prices[world.outputOf(9003)] = nil
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

- [ ] **Step 3: Implement `Modules/RecipeScan.lua`** with a coroutine that yields when `debugprofilestop() - start >= budgetMs` after each `Evaluate` (opts `{}`).

- [ ] **Step 4: Run test to verify it passes**

Run: `busted tests/recipes`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Modules/RecipeScan.lua tests/recipes/scan_spec.lua FabricationStation.toc tests/helpers/crafting_world.lua
git commit -m "feat: add time-sliced recipe scan and GetRanked"
```

---

### Task 11: Queue core — entries, restock, missing reagents, costs

**Files:**
- Create: `Modules/Queue.lua`
- Modify: `FabricationStation.toc`, `tests/helpers/crafting_world.lua`
- Test: `tests/queue/queue_spec.lua`

**Interfaces:**
- Consumes: `Recipes:Evaluate/FindRecipesForItem/WhoCanCraft/GetSetting("queueUseWarband")`, `Scanner:GetItemCount(itemID, charKey)`.
- Produces (contract + additions): `Queue:Add(entry) -> id`; `Queue:Remove(id)`; `Queue:GetEntries() -> { QueueEntry }` with `QueueEntry = { id, recipeID, quantity, charKey, targetQuality?, useConcentration?, orderID?, providedReagents?, isRestock?, itemID? }` (real entries in insertion order, then restock entries with `id = "restock:<itemID>"`); `Queue:SetRestock(itemID, target|nil)`; `Queue:GetRestockTargets() -> { [itemID] = target }`; `Queue:SetQuantity(id, n)` (≤ 0 removes); `Queue:Clear()` (real entries only); `Queue:GetMissingReagents(charKey|nil) -> { [itemID] = qty }`; `Queue:GetEntryMissing(id) -> { [itemID] = qty }`; `Queue:GetEntryCost(id) -> copper|nil`. `FS_QUEUE_CHANGED` after every change; recomputation on `FS_RECIPES_CHANGED`/`FS_DATA_CHANGED` sends at most one `FS_QUEUE_CHANGED` per 0.5 s debounce.

Rules:
- Per-craft requirement = `Recipes:Evaluate(recipeID, charKey, { targetQuality, useConcentration, providedReagents }).allocation`, all three taken from the entry (`providedReagents = { [itemID] = qty }` is set by phase-2 order entries).
- Restock: `held = Scanner:GetItemCount(itemID, nil).total`; `{recipeID, quality}` = first of `FindRecipesForItem`; crafter = the `WhoCanCraft` member with the highest `Evaluate(..., { targetQuality = quality }).profit` (ties: first); `crafts = ceil((target − held) / expectedYield) − queued real crafts of that recipe and quality`; listed only when `crafts > 0`.
- Missing per character: `max(0, required − (bags + bank + reagentBank))`; then, when `queueUseWarband`, the warband count is subtracted once across all characters.

- [ ] **Step 1: Write the failing test**

```lua
describe("Queue", function()
  local ns, W, world, Q
  before_each(function()
    ns, W, world = make_world({ last = "Modules/Queue.lua" })
    world.fakeEvaluate(9001, { allocation = { {slotIndex=1,itemID=1001,quantity=2}, {slotIndex=2,itemID=2002,quantity=1} },
                               reagentCost = 900, expectedYield = 1.31, profit = 5000, flags = {} })
    Q = ns.FS:GetModule("Queue")
  end)
  it("adds, lists, removes", function()
    assert.equals(1, Q:Add({ recipeID = 9001, quantity = 3, charKey = "Alt-Realm" }))
    assert.equals(2, Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" }))
    Q:Remove(1); assert.equals(1, #Q:GetEntries()); assert.equals(2, Q:GetEntries()[1].id)
    assert.is_true(#world.messages("FS_QUEUE_CHANGED") >= 3)
  end)
  it("computes missing reagents with the warband pool counted once", function()
    Q:Add({ recipeID = 9001, quantity = 3, charKey = "Alt-Realm" }); Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
    world.items["Alt-Realm"][1001] = { bags = 4, bank = 0, reagentBank = 0 }
    world.warband[1001], world.warband[2002] = 1, 2
    assert.same({ [1001] = 1, [2002] = 1 }, Q:GetMissingReagents("Alt-Realm"))
    assert.same({ [1001] = 3, [2002] = 2 }, Q:GetMissingReagents(nil))      -- 1001: 2 + 2 − 1; 2002: 3 + 1 − 2
    ns.FS.db.global.settings.crafting = { queueUseWarband = false }
    assert.same({ [1001] = 2, [2002] = 3 }, Q:GetMissingReagents("Alt-Realm"))
  end)
  it("tops up restock targets", function()
    world.counts[5002] = 12; Q:SetRestock(5002, 20)
    local e = Q:GetEntries()[1]
    assert.same({ "restock:5002", true, 5002, 9001, 7, 2 }, { e.id, e.isRestock, e.itemID, e.recipeID, e.quantity, e.targetQuality })
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

- [ ] **Step 3: Implement `Modules/Queue.lua`.** Storage: 1a's `db.global.queue = { entries, restock }` plus lazy `nextID = 1`.

- [ ] **Step 4: Run test to verify it passes**

Run: `busted tests/queue`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Modules/Queue.lua tests/queue/queue_spec.lua FabricationStation.toc tests/helpers/crafting_world.lua
git commit -m "feat: add Queue entries, restock targets and missing reagents"
```

---

### Task 12: Queue — shopping list, Craft Next, cooldowns

**Files:**
- Create: `Modules/QueueCraft.lua`
- Modify: `FabricationStation.toc`, `tests/helpers/crafting_world.lua`
- Test: `tests/queue/craft_spec.lua`

**Interfaces:**
- Consumes: Task 11; `Prices:AuctionatorAPI()`; `Scanner:GetSchematic`, `Scanner:GetProfession(charKey, skillLineID).cooldowns[recipeID] = { readyAt, charges, maxCharges, time }`, `Scanner:IsProfessionOpen(skillLineID)`, `Scanner:ToCraftingReagentInfo(recipeID, allocation)`; `C_Item.GetItemNameByID`, `C_Item.RequestLoadItemDataByID`; `C_TradeSkillUI.CraftRecipe`, `C_TradeSkillUI.GetProfessionInfoByRecipeID`; event `TRADE_SKILL_ITEM_CRAFTED_RESULT`.
- Produces: `Queue:ExportShoppingList() -> ok, info` (`info = { added, skipped }` | `"noAuctionator"` | `"empty"` | `"auctionatorError"`); `Queue:CraftNext() -> CraftNextResult = { status = "crafted"|"open"|"missing"|"cooldown"|"empty", entryID?, charKey?, skillLineID?, missing?, readyAt? }`; `Queue:GetCooldownReadyAt(entry) -> serverSeconds|nil` (nil = ready: no record at `Scanner:GetProfession(entry.charKey, schematic.skillLineID).cooldowns[recipeID]`, `readyAt <= Now()`, or `charges > 0`).

Shopping list: items and quantities from `GetMissingReagents(nil)`, sorted by itemID; term `{ searchString = name, isExact = true, quantity = n, tier = <index of the item in its schematic slot's reagents, only for slots with ≥ 2 reagents> }`; `api.CreateShoppingList("FabricationStation", "FabricationStation", searchStrings)`; every API call `pcall`ed.

Craft Next: walk `GetEntries()`; skip entries whose cooldown is not ready; craft the first entry that is on the current character, whose profession is open (`Scanner:IsProfessionOpen(GetProfessionInfoByRecipeID(recipeID).professionID)`), and that misses nothing for one craft: `C_TradeSkillUI.CraftRecipe(recipeID, 1, Scanner:ToCraftingReagentInfo(recipeID, allocation), nil, orderID, useConcentration and true or false)`. The entry becomes pending; its quantity drops by 1 on the next `TRADE_SKILL_ITEM_CRAFTED_RESULT` whose `itemID` is one of its outputs (one decrement per `operationID`). Restock entries are not decremented (they recompute from counts). With nothing craftable, report the first blocker in queue order: other character/profession → `"open"`; missing → `"missing"`; all on cooldown → `"cooldown"` with the earliest `readyAt`; no entries → `"empty"`.

- [ ] **Step 1: Write the failing test**

```lua
describe("Queue craft actions", function()
  local ns, W, world, Q, api
  before_each(function()
    ns, W, world = make_world({ last = "Modules/QueueCraft.lua" })
    world.fakeEvaluate(9001, { allocation = { {slotIndex=1,itemID=1001,quantity=2}, {slotIndex=2,itemID=2002,quantity=1} }, reagentCost = 900, flags = {} })
    api = world.recordAuctionatorTerms()                       -- wraps W.auctionator: api.terms, api.lists
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
    world.names[1001] = "Bright Ore"
    Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
    local ok, info = Q:ExportShoppingList()
    assert.is_true(ok); assert.same({ added = 1, skipped = 1 }, info); assert.same({ 2002 }, world.loadRequests)
  end)
  it("reports missing Auctionator", function()
    W.removeAuctionator(); Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
    assert.same({ false, "noAuctionator" }, { Q:ExportShoppingList() })
  end)
  it("craft_next_window_closed", function()
    Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
    local r = Q:CraftNext()
    assert.equals("open", r.status); assert.equals("Main-Realm", r.charKey); assert.equals(2906, r.skillLineID); assert.equals(0, #world.crafts)
  end)
  it("craft_next_other_character", function()
    world.openProfession(2906); Q:Add({ recipeID = 9001, quantity = 1, charKey = "Alt-Realm" })
    local r = Q:CraftNext()
    assert.equals("open", r.status); assert.equals("Alt-Realm", r.charKey); assert.equals(0, #world.crafts)
  end)
  it("craft_next_crafts_one_and_counts_on_result", function()
    world.openProfession(2906); world.haveAll("Main-Realm")
    local id = Q:Add({ recipeID = 9001, quantity = 3, charKey = "Main-Realm", useConcentration = true })
    local r = Q:CraftNext(); assert.same({ "crafted", id }, { r.status, r.entryID })
    local c = world.crafts[1]                                  -- recorded CraftRecipe arguments
    assert.equals(9001, c[1]); assert.equals(1, c[2]); assert.is_table(c[3]); assert.is_nil(c[4]); assert.is_nil(c[5]); assert.is_true(c[6])
    assert.equals(3, Q:GetEntries()[1].quantity)
    W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", { itemID = 5002, operationID = 77 })
    W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", { itemID = 5002, operationID = 77 })    -- multicraft extra, same operation
    assert.equals(2, Q:GetEntries()[1].quantity)
  end)
  it("craft_next_missing_and_cooldown", function()
    world.openProfession(2906); Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
    assert.equals("missing", Q:CraftNext().status)
    world.haveAll("Main-Realm"); world.cooldown("Main-Realm", 9001, W.now + 3600)
    local r = Q:CraftNext(); assert.equals("cooldown", r.status); assert.equals(W.now + 3600, r.readyAt)
  end)
  it("craft_next_empty", function() assert.equals("empty", Q:CraftNext().status) end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/queue/craft_spec.lua`
Expected: FAIL — `ExportShoppingList` undefined.

- [ ] **Step 3: Implement `Modules/QueueCraft.lua`.**

- [ ] **Step 4: Run tests and check click-only use**

Run: `busted tests/queue && grep -rn "CraftNext(" Modules UI | grep -v "function Queue:CraftNext"`
Expected: PASS; grep prints nothing (Tasks 15 and 16 add the only callers, inside `OnClick`).

- [ ] **Step 5: Commit**

```bash
git add Modules/QueueCraft.lua tests/queue/craft_spec.lua FabricationStation.toc tests/helpers/crafting_world.lua
git commit -m "feat: add Auctionator shopping list, click-only Craft Next and cooldown checks"
```

---

### Task 13: Dashboard tab with RegisterWidget and phase-1 widgets

**Files:**
- Create: `UI/Tabs/Dashboard.lua`
- Modify: `FabricationStation.toc`
- Test: `tests/ui/dashboard_spec.lua`

**Interfaces:**
- Consumes: `MainWindow:RegisterTab("dashboard", { label = "Dashboard", icon, order = 10, phase = 1, build, refresh })`, `Recipes:GetRanked`, `Queue:GetEntries/GetEntryCost/GetMissingReagents`, `Scanner:GetCharacters/GetCharacter/ProjectConcentration`, `ns.UI.FormatMoney/FormatAge`; messages `FS_RECIPES_CHANGED`, `FS_QUEUE_CHANGED`, `FS_DATA_CHANGED`.
- Produces: module `"Dashboard"`; `Dashboard:RegisterWidget(id, def)` (contract; stores `def.id = id`; same id replaces); `Dashboard:GetWidgets() -> { def }` by `order`; `Dashboard:BuildAll(container) -> { [id] = frame }` (two-column grid; a widget whose `build`/`refresh` errors shows "widget failed" in `frame.errorText`, others still render); pure models `Dashboard.TopCraftsModel(results, n)`, `Dashboard.QueueSummaryModel(entries, costs, missing) -> { entries, crafts, totalCost|nil, missingItems }`, `Dashboard.ConcentrationModel(rows, now)` (rows `{ charKey, profession, value, max, regenPerSec }` → adds `fullAt = now + (max − value) / regenPerSec`, sorted by `fullAt`; the widget derives `regenPerSec` from `ProjectConcentration(c, s, now + 3600) − ProjectConcentration(c, s, now)` ÷ 3600, so no rate is hard-coded). Phase-1 widgets: `topCrafts` (order 10, top 10 by profit with price age), `queueSummary` (20), `concentration` (30). Refresh on the three messages, debounced 0.5 s.

- [ ] **Step 1: Write the failing test**

```lua
describe("Dashboard", function()
  local ns, D
  before_each(function() ns = make_world({ last = "UI/Tabs/Dashboard.lua" }); D = ns.FS:GetModule("Dashboard") end)
  it("orders widgets and replaces duplicates", function()
    D:RegisterWidget("b", { order = 50, title = "B", build = function() end, refresh = function() end })
    D:RegisterWidget("a", { order = 5, title = "A", build = function() end, refresh = function() end })
    D:RegisterWidget("b", { order = 1, title = "B2", build = function() end, refresh = function() end })
    local w = D:GetWidgets()
    assert.same({ "b", "a", "topCrafts", "queueSummary", "concentration" }, { w[1].id, w[2].id, w[3].id, w[4].id, w[5].id })
    assert.equals("B2", w[1].title)
  end)
  it("isolates a failing widget", function()
    D:RegisterWidget("bad", { order = 1, title = "Bad", build = function() error("boom") end, refresh = function() end })
    local frames = D:BuildAll(CreateFrame("Frame"))
    assert.equals("widget failed", frames.bad.errorText); assert.is_table(frames.topCrafts)
  end)
  it("concentration model sorts by full-at", function()
    local rows = D.ConcentrationModel({ { charKey = "A", value = 900, max = 1000, regenPerSec = 1/360 }, { charKey = "B", value = 990, max = 1000, regenPerSec = 1/360 } }, 0)
    assert.same({ "B", "A" }, { rows[1].charKey, rows[2].charKey }); assert.near(3600, rows[1].fullAt, 1e-6)
  end)
  it("queue summary leaves the total nil when any cost is unknown", function()
    assert.is_nil(D.QueueSummaryModel({ {id=1,quantity=2}, {id=2,quantity=1} }, { [1] = 1800 }, {}).totalCost)
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/ui/dashboard_spec.lua`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement `UI/Tabs/Dashboard.lua`.**

- [ ] **Step 4: Run tests, then verify in game**

Run: `busted tests/ui/dashboard_spec.lua`
Expected: PASS. In game: `/fs` → Dashboard shows top crafts with price age, the queue summary and concentration rows for every alt.

- [ ] **Step 5: Commit**

```bash
git add UI/Tabs/Dashboard.lua tests/ui/dashboard_spec.lua FabricationStation.toc
git commit -m "feat: add Dashboard tab with widget registry and phase-1 widgets"
```

---

### Task 14: Recipes tab

**Files:**
- Create: `UI/Tabs/Recipes.lua`
- Modify: `FabricationStation.toc`
- Test: `tests/ui/recipes_tab_spec.lua`

**Interfaces:**
- Consumes: `MainWindow:RegisterTab("recipes", { label = "Recipes", order = 20, phase = 1, ... })`, `Recipes:GetRanked/IsScanning`, `Queue:Add`, `Scanner:GetSchematic(recipeID).name` (1a schematic field; `"recipe:" .. id` when nil), `ns.UI.FormatMoney`; message `FS_RECIPES_CHANGED`.
- Produces: `ns.UI.RecipesTab.BuildRows(results) -> { { recipeID, name, charKey, quality, cost, sale, profit, gpc, priceAge, flagsText } }`; `ns.UI.RecipesTab.FilterFromControls(state) -> filter` (`"any"` and `false` map to nil).

Columns (spec §5.1): recipe, character, expected quality, cost, sale, profit, gold/concentration, price age. `flagsText` joins, in this order, "no price", "stale price", "stale data", "estimate", "unknown recipe". Row button "Queue" → `Queue:Add({ recipeID, quantity = 1, charKey, targetQuality = quality, useConcentration = state.usesConcentration })`. Header shows "Scanning…" while `IsScanning()`. Sortable headers re-call `GetRanked`.

- [ ] **Step 1: Write the failing test**

```lua
describe("Recipes tab model", function()
  local T
  before_each(function() local ns = make_world({ last = "UI/Tabs/Recipes.lua" }); T = ns.UI.RecipesTab end)
  it("builds rows with flags and price age", function()
    local rows = T.BuildRows({ { recipeID = 9001, charKey = "Main-Realm", expectedQuality = 2, reagentCost = 4800, expectedSale = 124450,
      profit = 120010, goldPerConcentration = 6, priceAgeDays = 1.5, flags = { stalePrice = true, estimated = true } } })
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

- [ ] **Step 3: Implement `UI/Tabs/Recipes.lua`** (filter bar, `WowScrollBoxList` rows, sortable headers).

- [ ] **Step 4: Run tests, then verify in game**

Run: `busted tests/ui/recipes_tab_spec.lua`
Expected: PASS. In game: recipes for every character are listed; "only profitable" hides unpriced rows; "Queue" adds an entry that appears in the Queue tab.

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
- Consumes: `MainWindow:RegisterTab("queue", { label = "Queue", order = 30, phase = 1, ... })`, `Queue:GetEntries/GetEntryMissing/GetEntryCost/SetQuantity/Remove/Clear/ExportShoppingList/CraftNext/GetRestockTargets/SetRestock/GetCooldownReadyAt`, `C_Item.GetItemNameByID`, `ns.UI.ParseItemID/FormatMoney`; message `FS_QUEUE_CHANGED`.
- Produces: `ns.UI.QueueTab.BuildRows(entries, costs, missing, readyAt, now) -> { { id, name, charKey, quantity, targetQuality, concentration, missingText, cost, readyText, isRestock } }`; `ns.UI.QueueTab.StatusText(result, professionName, charName) -> string`.

Columns (spec §5.1): character, quantity, target quality, concentration on/off, missing reagents, total cost, plus "ready in 2h 5m" for cooldown entries. Buttons: Shopping List, Clear, Craft Next (`OnClick` only), Restock editor (item ID or shift-clicked link + target; list with Remove). `StatusText`: crafted → `"Crafting <recipe>…"`; open → `"Open <Profession> on <Character>"`; missing → `"Missing reagents — see Shopping List"`; cooldown → `"Next craft ready in <time>"`; empty → `"Queue is empty"`. Shopping List feedback: `"Shopping list updated (N items)"`, `"… N items skipped, try again"`, `"Auctionator not available"`.

- [ ] **Step 1: Write the failing test**

```lua
describe("Queue tab model", function()
  local T
  before_each(function() local ns = make_world({ last = "UI/Tabs/Queue.lua" }); T = ns.UI.QueueTab end)
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

- [ ] **Step 3: Implement `UI/Tabs/Queue.lua`** (`missingText` uses cached item names, else `item:<id>`).

- [ ] **Step 4: Run tests, then verify in game**

Run: `busted tests/ui/queue_tab_spec.lua`
Expected: PASS. In game: Shopping List creates the Auctionator list "FabricationStation" with the shown quantities; Craft Next with the profession closed shows "Open <Profession> on <Character>"; with it open, one craft per click.

- [ ] **Step 5: Commit**

```bash
git add UI/Tabs/Queue.lua tests/ui/queue_tab_spec.lua FabricationStation.toc
git commit -m "feat: add Queue tab with shopping list, Craft Next and restock editor"
```

---

### Task 16: Profession side panel

**Files:**
- Create: `UI/ProfessionPanel.lua`, `tests/helpers/professions_frame.lua`
- Modify: `FabricationStation.toc`, `tests/helpers/init.lua` (expose `fake_professions_frame`), `tests/helpers/crafting_world.lua`
- Test: `tests/ui/profession_panel_spec.lua`

**Interfaces:**
- Consumes: `ADDON_LOADED("Blizzard_Professions")`, `ProfessionsFrame`, `ProfessionsFrame.CraftingPage.SchematicForm` (`GetTransaction()`, `UpdateAllSlots()`, `TriggerEvent`, `RegisterCallback(ProfessionsRecipeSchematicFormMixin.Event.AllocationsModified, fn, owner)`), `EventRegistry` `"ProfessionsRecipeListMixin.Event.OnRecipeSelected"` (arg `recipeInfo`) and `"Professions.TransactionUpdated"`, `Professions.CreateCraftingReagent(itemID)`, `Recipes:Calibrate/Evaluate/PredictLive/FromCraftingReagentInfo/GetSetting`, `Queue:Add/CraftNext`, `ns.UI.QueueTab.StatusText`.
- Produces: module `"ProfessionPanel"`; `ns.UI.ProfessionPanel.BuildModel(result, live|nil) -> { qualityText, skill, difficulty, lowerThreshold, nextThreshold, barFill, skillToNext, concentrationText, perQualityRows = { {quality, cost, profit} }, breakdownRows = { {label, value} } }`; `ProfessionPanel:ApplyAllocation(allocation)`; `ProfessionPanel:SetStatus(text)` (Task 19). Test helper `fake_professions_frame(opts) -> form`: builds `ProfessionsFrame.CraftingPage.{SchematicForm, RecipeList.ScrollBox}` on 1a's `CreateFrame` fake; records `form.slotCalls[slotIndex]`, `form.calls`, `form.manuallyAllocated`, and every field assigned on the fake Blizzard frames (`form.assignedFields`, via a `__newindex` proxy); `form.recipeScrollBox.fireInitialized(row, elementData)`; `form.node(data)`; `opts.withoutScrollBox`.

Behaviour (spec §5.2):
- `CreateFrame("Frame", "FabricationStationProfessionPanel", UIParent, "BackdropTemplate")`, width 300, `SetPoint("TOPLEFT", ProfessionsFrame, "TOPRIGHT", 2, 0)`, shown/hidden via `ProfessionsFrame:HookScript("OnShow"/"OnHide")`.
- Recipe selected → `Recipes:Calibrate(recipeID)`, then `Evaluate(recipeID, CharKey(), panelOpts)`. Allocation changed → `PredictLive` on `FromCraftingReagentInfo(transaction:CreateCraftingReagentInfoTbl())`; the prediction header and bar show the live allocation, the per-quality rows show the optimiser.
- `barFill = (skill − lowerThreshold) / (nextThreshold − lowerThreshold)`, 1 at max quality; label `"Skill 690 / 700 — 10 to next"`.
- Per-quality rows (cheapest reagents per reachable quality) with **Apply**; breakdown rows (labels in the test); "no price" / "estimate" flags in red.
- **Apply** (click only): when `applyWritesBlizzardSlots`, for each slot in the allocation `local a = transaction:GetAllocations(slotIndex); a:Clear(); a:Allocate(Professions.CreateCraftingReagent(itemID), qty)` per item, then `transaction:SetManuallyAllocated(true)`, `SchematicForm:UpdateAllSlots()`, `SchematicForm:TriggerEvent(ProfessionsRecipeSchematicFormMixin.Event.AllocationsModified)` — the sequence Blizzard's own quality dialog runs. Setting off → Apply disabled, tooltip "Enable in Settings › Crafting".
- **Add to Queue**: quantity box (default 1), target-quality dropdown, concentration checkbox → `Queue:Add`.
- **Craft Next**: `OnClick` → `Queue:CraftNext()`; status via `StatusText`.
- Turning the module off (1a module toggle, or SafeCall after an error) hides the panel and unregisters its callbacks in `OnDisable`.

- [ ] **Step 1: Write the failing test**

```lua
describe("ProfessionPanel model", function()
  local M
  before_each(function() local ns = make_world({ last = "UI/ProfessionPanel.lua" }); M = ns.UI.ProfessionPanel end)
  local result = { expectedQuality = 2, perQuality = { [1] = { reagentCost = 3000, profit = 71895 }, [2] = { reagentCost = 4800, profit = 120010 } },
    reagentCost = 4800, expectedSale = 124450, multicraftValue = 29450, resourcefulnessValue = 360, ingenuityValue = 31.4,
    concentrationCost = 314, goldPerConcentration = 6, profit = 120010, priceAgeDays = 1, flags = {} }
  it("threshold bar from the live prediction", function()
    local m = M.BuildModel(result, { skill = 690, difficulty = 700, lowerThreshold = 0, nextThreshold = 700, expectedQuality = 1 })
    assert.near(690 / 700, m.barFill, 1e-9); assert.equals(10, m.skillToNext); assert.equals(2, #m.perQualityRows)
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
    local ns, W = make_world({ last = "UI/ProfessionPanel.lua" }); local form = fake_professions_frame()
    W.fire("ADDON_LOADED", "Blizzard_Professions")
    ns.FS:GetModule("ProfessionPanel"):ApplyAllocation({ {slotIndex=1,itemID=1001,quantity=3}, {slotIndex=1,itemID=1002,quantity=7} })
    assert.same({ "Clear", "Allocate:1001:3", "Allocate:1002:7" }, form.slotCalls[1])
    assert.is_true(form.manuallyAllocated); assert.same({ "UpdateAllSlots", "TriggerEvent:AllocationsModified" }, form.calls)
    assert.same({}, form.assignedFields)
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/ui/profession_panel_spec.lua`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement `UI/ProfessionPanel.lua` and `tests/helpers/professions_frame.lua`**; hook bodies through `ns.FS:SafeCall("ProfessionPanel", ...)`.

- [ ] **Step 4: Run tests, then verify in game (taint check)**

Run: `busted tests/ui/profession_panel_spec.lua`
Expected: PASS.
In game with `/console taintLog 1`: open a profession, select a quality recipe, Apply the quality-2 row, click Blizzard's **Create**. Expected: slots show the applied mix, the craft succeeds, no "action blocked", and `Logs/taint.log` has no FabricationStation lines. If it taints, set `Recipes.DEFAULTS.applyWritesBlizzardSlots = false` and say so in the commit body.

- [ ] **Step 5: Commit**

```bash
git add UI/ProfessionPanel.lua tests/helpers/professions_frame.lua tests/helpers/init.lua tests/ui/profession_panel_spec.lua FabricationStation.toc tests/helpers/crafting_world.lua
git commit -m "feat: add profession side panel with prediction, reagents per quality and queue buttons"
```

---

### Task 17: Recipe-list profit labels

**Files:**
- Create: `UI/RecipeListLabels.lua`
- Modify: `FabricationStation.toc`, `tests/helpers/crafting_world.lua`
- Test: `tests/ui/recipe_list_labels_spec.lua`

**Interfaces:**
- Consumes: `ADDON_LOADED("Blizzard_Professions")`, `ProfessionsFrame.CraftingPage.RecipeList.ScrollBox` (`RegisterCallback(ScrollBoxListMixin.Event.OnInitializedFrame, fn, owner)` → `fn(owner, frame, elementData)`; `ForEachFrame(fn(frame, elementData))`), `elementData:GetData().recipeInfo.recipeID`, `Recipes:Evaluate(recipeID, CharKey(), {})`, 1a's module toggle for on/off; message `FS_RECIPES_CHANGED` (relabel via `ForEachFrame`).
- Produces: module `"RecipeListLabels"`; `ns.UI.RecipeListLabels.LabelText(result) -> text, colorKey` (`"+12g"`/`"green"`, `"-3g"`/`"red"`, `"?"`/`"grey"` for no price; under 1g shown in silver).

Labels are own FontStrings from `row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")`, right-aligned, held in `local labels = setmetatable({}, { __mode = "k" })` keyed by row — never `row.x = ...`. Category rows (no `recipeInfo`) are skipped. An error in the callback → `SafeCall` disables the module and prints 1a's one standard chat line (`FabricationStation: RecipeListLabels stopped after an error and was turned off. …`); `OnDisable` hides every label via `ForEachFrame`. Missing ScrollBox → the `ADDON_LOADED` handler (run inside `SafeCall`) raises `"recipe list ScrollBox not found"`, so the same disable path runs without registering.

- [ ] **Step 1: Write the failing test**

```lua
describe("RecipeListLabels", function()
  it("label text", function()
    local ns = make_world({ last = "UI/RecipeListLabels.lua" }); local L = ns.UI.RecipeListLabels
    assert.same({ "+12g", "green" }, { L.LabelText({ profit = 120010, flags = {} }) })
    assert.same({ "-3g", "red" }, { L.LabelText({ profit = -30000, flags = {} }) })
    assert.same({ "?", "grey" }, { L.LabelText({ flags = { noPrice = true } }) })
    assert.same({ "+45s", "green" }, { L.LabelText({ profit = 4500, flags = {} }) })
  end)
  it("labels rows without writing fields on them", function()
    local ns, W = make_world({ last = "UI/RecipeListLabels.lua", calibrate = { ["Main-Realm"] = { 9001 } } })
    local form = fake_professions_frame(); W.fire("ADDON_LOADED", "Blizzard_Professions")
    local row = form.newRow()                                  -- fake Blizzard row behind the __newindex recorder
    form.recipeScrollBox.fireInitialized(row, form.node({ recipeInfo = { recipeID = 9001 } }))
    assert.equals("+12g", form.fontStringsOf(row)[1]:GetText())
    assert.same({}, form.assignedFields)
  end)
  it("disables_when_scrollbox_missing", function()
    local ns, W = make_world({ last = "UI/RecipeListLabels.lua" }); fake_professions_frame({ withoutScrollBox = true })
    assert.has_no.errors(function() W.fire("ADDON_LOADED", "Blizzard_Professions") end)
    assert.is_false(ns.FS:GetModule("RecipeListLabels"):IsEnabled())
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/ui/recipe_list_labels_spec.lua`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement `UI/RecipeListLabels.lua`** (and `form.newRow`/`form.fontStringsOf` in the frame helper).

- [ ] **Step 4: Run tests, then verify in game**

Run: `busted tests/ui/recipe_list_labels_spec.lua`
Expected: PASS. In game: labels on recipe rows, updated after an Auctionator scan, gone when the module is toggled off in Settings › Modules; fast scrolling causes no errors.

- [ ] **Step 5: Commit**

```bash
git add UI/RecipeListLabels.lua tests/ui/recipe_list_labels_spec.lua tests/helpers/professions_frame.lua FabricationStation.toc tests/helpers/crafting_world.lua
git commit -m "feat: add toggleable profit labels on Blizzard recipe list rows"
```

---

### Task 18: Tooltips module, craft-cost and crafters lines

**Files:**
- Create: `UI/Tooltips.lua`
- Modify: `FabricationStation.toc`, `tests/helpers/crafting_world.lua`
- Test: `tests/ui/tooltips_spec.lua`

**Interfaces:**
- Consumes: `TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, fn(tooltip, data))` (`data.id` = itemID), `tooltip:AddDoubleLine`, `Recipes:FindRecipesForItem/WhoCanCraft/Evaluate/GetSetting("tooltipCraftCost")`, `ns.UI.FormatMoney`, `ns.FS:LogError`.
- Produces: module `"Tooltips"`; `Tooltips:RegisterLineProvider(id, fn(itemID) -> { {left, right}, ... })` (contract; same id replaces in place); `Tooltips:CollectLines(itemID) -> { {left, right} }` (providers in registration order, each `pcall`ed; an erroring provider is disabled for the session and logged with `ns.FS:LogError("Tooltips:" .. id, err)`). Built-in providers, registered in this order: `"craftCost"` — the cheapest `Evaluate(recipeID, charKey, { targetQuality = quality }).reagentCost` over every `{recipeID, quality}` of the item and every `WhoCanCraft` character (ties: non-estimated first, then `WhoCanCraft` order) → `{ "Craft cost", FormatMoney(cost) .. " (" .. shortName .. ")" }`; `"no price"` when no candidate has a cost; nothing when nobody crafts it. `"crafters"` — `{ "Crafters", "Main, Alt" }` (short names, cheapest first; spec §5.4). Holdings lines are phase 3. Only the built-in `"craftCost"` and `"crafters"` lines are cached (per itemID until `FS_RECIPES_CHANGED`); providers registered by other modules run on every tooltip so their lines never go stale. Test: `registered_provider_not_cached` (provider output changes between two tooltip shows, second show reflects it). Nothing is added when `type(data.id) ~= "number"`. `tooltipCraftCost` gates only the built-in `"craftCost"` and `"crafters"` providers (each returns `{}` when it is off); providers registered by later phases are unaffected. Test: `tooltipCraftCost_off_keeps_other_providers` (setting off, a registered `"extra"` provider still appears, `"Craft cost"` does not).

- [ ] **Step 1: Write the failing test**

```lua
describe("Tooltips", function()
  local ns, T
  before_each(function() ns = make_world({ last = "UI/Tooltips.lua", calibrate = { ["Main-Realm"] = { 9001 } } }); T = ns.FS:GetModule("Tooltips") end)
  it("craft cost and crafters lines", function()
    assert.same({ { "Craft cost", ns.UI.FormatMoney(4800) .. " (Main)" }, { "Crafters", "Main, Alt" } }, T:CollectLines(5002))
  end)
  it("no lines for items nobody crafts", function() assert.same({}, T:CollectLines(424242)) end)
  it("isolates a failing provider", function()
    T:RegisterLineProvider("bad", function() error("boom") end)
    T:RegisterLineProvider("ok", function() return { { "x", "y" } } end)
    local want = { { "Craft cost", ns.UI.FormatMoney(4800) .. " (Main)" }, { "Crafters", "Main, Alt" }, { "x", "y" } }
    assert.same(want, T:CollectLines(5002)); assert.same(want, T:CollectLines(5002))
    assert.equals("Tooltips:bad", ns.FS.db.global.diagnostics.errors[1].source)
  end)
end)
```

(Alt is uncalibrated; its estimate also costs 4800, and the tie rule puts Main first.)

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/ui/tooltips_spec.lua`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement `UI/Tooltips.lua`.**

- [ ] **Step 4: Run tests, then verify in game**

Run: `busted tests/ui/tooltips_spec.lua`
Expected: PASS. In game: hovering a crafted item shows "Craft cost" and "Crafters"; Auctionator's tooltip lines are unchanged.

- [ ] **Step 5: Commit**

```bash
git add UI/Tooltips.lua tests/ui/tooltips_spec.lua FabricationStation.toc tests/helpers/crafting_world.lua
git commit -m "feat: add Tooltips line providers with craft-cost and crafters lines"
```

---

### Task 19: In-game self-check

**Files:**
- Create: `Modules/SelfCheck.lua`
- Modify: `UI/ProfessionPanel.lua` (status line), `FabricationStation.toc`, `tests/helpers/crafting_world.lua`
- Test: `tests/recipes/selfcheck_spec.lua`

**Interfaces:**
- Consumes: `Recipes:PredictLive/FromCraftingReagentInfo/GetCalibration/GetSetting("selfCheck")`, `Scanner:GetLiveOperationInfo/GetSchematic`, `Diagnostics:LogMismatch({ recipeID, charKey, field, expected, actual, context })`, `ProfessionPanel:SetStatus` (via `ns.FS:GetModule("ProfessionPanel", true)`; absent or disabled → no status, since `Modules\SelfCheck.lua` loads before the UI files), the Task 16 callbacks, `ns.FS:Debounce`. The game call is `Scanner:GetLiveOperationInfo(recipeID, allocation, applyConcentration)` where `allocation` is the required allocation plus one `{ slotIndex, itemID, quantity }` row per optional/finishing reagent in the transaction, so 1a's `ToCraftingReagentInfo` sends the same reagents Blizzard does.
- Produces: module `"SelfCheck"`; `ns.SelfCheck.QUALITY_FIELD = "craftingQuality"` (Task 9 may change it); `ns.SelfCheck.Compare(prediction: MathResult, opInfo) -> { { field, expected, actual } }` (`expected` = Math, `actual` = game; fields in order: `skill` (±0.5 vs `baseSkill + bonusSkill`), `difficulty` (vs `baseDifficulty + bonusDifficulty`), `quality` (vs `opInfo[QUALITY_FIELD]`), `lowerThreshold` (vs `lowerSkillThreshold`), `nextThreshold` (vs `upperSkillTreshold`, only below max), `concentrationCost` (`concentrationCostForAllocation` vs `concentrationCost`, only when the game's cost > 0 and a curve is known)); `SelfCheck:Run(recipeID) -> mismatches` (current window state; `{}` when `selfCheck` is off or the window is closed); `SelfCheck:GetSessionCount() -> integer`. The same `(recipeID, field, expected, actual)` is logged at most once per session, with `context = { calib, schematic, reagents, operationInfo }` (the MathFixture fields Task 9's exporter reads). Runs 0.2 s after allocation/transaction updates. Panel status: `"Math check: OK"` or `"Math check: N mismatches (see Settings › Diagnostics)"`.

- [ ] **Step 1: Write the failing test**

```lua
describe("SelfCheck", function()
  local ns, W, world
  before_each(function() ns, W, world = make_world({ last = "Modules/SelfCheck.lua", calibrate = { ["Main-Realm"] = { 9001 } } }) end)
  it("compare finds field mismatches with tolerance", function()
    local m = ns.SelfCheck.Compare({ skill = 703.3, difficulty = 700, expectedQuality = 2, lowerThreshold = 700, concentrationCostForAllocation = 0 },
      { baseSkill = 480, bonusSkill = 223, baseDifficulty = 700, bonusDifficulty = 0, craftingQuality = 1, lowerSkillThreshold = 0, upperSkillTreshold = 700, concentrationCost = 0 })
    assert.same({ { field = "quality", expected = 2, actual = 1 }, { field = "lowerThreshold", expected = 700, actual = 0 } }, m)
  end)
  it("logs once per session with a fixture context", function()
    world.live[9001] = function() return { baseSkill = 480, bonusSkill = 20, baseDifficulty = 700, bonusDifficulty = 0, craftingQuality = 2,
      lowerSkillThreshold = 700, upperSkillTreshold = 700, concentrationCost = 0, craftingDataID = 2588, bonusStats = {} } end
    world.openProfession(2906); world.liveReagents({})
    local S = ns.FS:GetModule("SelfCheck")
    assert.equals(2, #S:Run(9001)); S:Run(9001)
    local log = ns.FS:GetModule("Diagnostics"):GetMismatches()
    assert.equals(2, #log); assert.is_table(log[1].context.calib); assert.equals(2, S:GetSessionCount())
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

- [ ] **Step 3: Implement `Modules/SelfCheck.lua` and the panel status line.**

- [ ] **Step 4: Run the whole suite, lint, then verify in game**

Run: `busted && luacheck .`
Expected: all specs PASS (golden spec green, or pending only if no fixtures are committed); 0 warnings.
In game: changing reagent ranks keeps the panel at "Math check: OK"; a mismatch appears under Settings › Diagnostics with recipe and field; `tools/export_math_fixtures.lua` turns it into a fixture that reproduces the failure in `busted tests/math/golden_spec.lua`.

- [ ] **Step 5: Commit**

```bash
git add Modules/SelfCheck.lua UI/ProfessionPanel.lua tests/recipes/selfcheck_spec.lua FabricationStation.toc tests/helpers/crafting_world.lua
git commit -m "feat: add in-game math self-check logging mismatches with fixtures"
```
