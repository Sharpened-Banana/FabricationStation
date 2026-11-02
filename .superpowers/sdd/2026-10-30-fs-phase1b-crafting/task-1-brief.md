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

