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
