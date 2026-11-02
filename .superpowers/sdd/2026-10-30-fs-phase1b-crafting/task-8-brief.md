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

