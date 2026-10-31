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

