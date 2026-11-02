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

