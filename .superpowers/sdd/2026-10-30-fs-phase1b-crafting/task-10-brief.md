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

