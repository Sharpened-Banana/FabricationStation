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

