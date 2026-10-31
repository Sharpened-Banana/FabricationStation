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

