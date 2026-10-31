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

