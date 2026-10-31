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

