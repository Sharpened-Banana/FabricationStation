### Task 11: Queue core — entries, restock, missing reagents, costs

**Files:**
- Create: `Modules/Queue.lua`
- Modify: `FabricationStation.toc`, `tests/helpers/crafting_world.lua`
- Test: `tests/queue/queue_spec.lua`

**Interfaces:**
- Consumes: `Recipes:Evaluate/FindRecipesForItem/WhoCanCraft/GetSetting("queueUseWarband")`, `Scanner:GetItemCount(itemID, charKey)`.
- Produces (contract + additions): `Queue:Add(entry) -> id`; `Queue:Remove(id)`; `Queue:GetEntries() -> { QueueEntry }` with `QueueEntry = { id, recipeID, quantity, charKey, targetQuality?, useConcentration?, orderID?, providedReagents?, isRestock?, itemID? }` (real entries in insertion order, then restock entries with `id = "restock:<itemID>"`); `Queue:SetRestock(itemID, target|nil)`; `Queue:GetRestockTargets() -> { [itemID] = target }`; `Queue:SetQuantity(id, n)` (≤ 0 removes); `Queue:Clear()` (real entries only); `Queue:GetMissingReagents(charKey|nil) -> { [itemID] = qty }`; `Queue:GetEntryMissing(id) -> { [itemID] = qty }`; `Queue:GetEntryCost(id) -> copper|nil`. `FS_QUEUE_CHANGED` after every change; recomputation on `FS_RECIPES_CHANGED`/`FS_DATA_CHANGED` sends at most one `FS_QUEUE_CHANGED` per 0.5 s debounce.

Rules:
- Per-craft requirement = `Recipes:Evaluate(recipeID, charKey, { targetQuality, useConcentration, providedReagents }).allocation`, all three taken from the entry (`providedReagents = { [itemID] = qty }` is set by phase-2 order entries).
- Restock: `held = Scanner:GetItemCount(itemID, nil).total`; `{recipeID, quality}` = first of `FindRecipesForItem`; crafter = the `WhoCanCraft` member with the highest `Evaluate(..., { targetQuality = quality }).profit` (ties: first); `crafts = ceil((target − held) / expectedYield) − queued real crafts of that recipe and quality`; listed only when `crafts > 0`.
- Missing per character: `max(0, required − (bags + bank + reagentBank))`; then, when `queueUseWarband`, the warband count is subtracted once across all characters.

- [ ] **Step 1: Write the failing test**

```lua
describe("Queue", function()
  local ns, W, world, Q
  before_each(function()
    ns, W, world = make_world({ last = "Modules/Queue.lua" })
    world.fakeEvaluate(9001, { allocation = { {slotIndex=1,itemID=1001,quantity=2}, {slotIndex=2,itemID=2002,quantity=1} },
                               reagentCost = 900, expectedYield = 1.31, profit = 5000, flags = {} })
    Q = ns.FS:GetModule("Queue")
  end)
  it("adds, lists, removes", function()
    assert.equals(1, Q:Add({ recipeID = 9001, quantity = 3, charKey = "Alt-Realm" }))
    assert.equals(2, Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" }))
    Q:Remove(1); assert.equals(1, #Q:GetEntries()); assert.equals(2, Q:GetEntries()[1].id)
    assert.is_true(#world.messages("FS_QUEUE_CHANGED") >= 3)
  end)
  it("computes missing reagents with the warband pool counted once", function()
    Q:Add({ recipeID = 9001, quantity = 3, charKey = "Alt-Realm" }); Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
    world.items["Alt-Realm"][1001] = { bags = 4, bank = 0, reagentBank = 0 }
    world.warband[1001], world.warband[2002] = 1, 2
    assert.same({ [1001] = 1, [2002] = 1 }, Q:GetMissingReagents("Alt-Realm"))
    assert.same({ [1001] = 3, [2002] = 2 }, Q:GetMissingReagents(nil))      -- 1001: 2 + 2 − 1; 2002: 3 + 1 − 2
    ns.FS.db.global.settings.crafting = { queueUseWarband = false }
    assert.same({ [1001] = 2, [2002] = 3 }, Q:GetMissingReagents("Alt-Realm"))
  end)
  it("tops up restock targets", function()
    world.counts[5002] = 12; Q:SetRestock(5002, 20)
    local e = Q:GetEntries()[1]
    assert.same({ "restock:5002", true, 5002, 9001, 7, 2 }, { e.id, e.isRestock, e.itemID, e.recipeID, e.quantity, e.targetQuality })
    Q:Add({ recipeID = 9001, quantity = 3, charKey = e.charKey, targetQuality = 2 })
    assert.equals(4, Q:GetEntries()[2].quantity)
    Q:SetRestock(5002, nil); assert.equals(1, #Q:GetEntries())
  end)
  it("entry cost is per-craft cost × quantity, nil without price", function()
    local id = Q:Add({ recipeID = 9001, quantity = 3, charKey = "Alt-Realm" })
    assert.equals(2700, Q:GetEntryCost(id))
    world.fakeEvaluate(9001, { allocation = {}, reagentCost = nil, flags = { noPrice = true } })
    assert.is_nil(Q:GetEntryCost(id))
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/queue/queue_spec.lua`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement `Modules/Queue.lua`.** Storage: 1a's `db.global.queue = { entries, restock }` plus lazy `nextID = 1`.

- [ ] **Step 4: Run test to verify it passes**

Run: `busted tests/queue`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Modules/Queue.lua tests/queue/queue_spec.lua FabricationStation.toc tests/helpers/crafting_world.lua
git commit -m "feat: add Queue entries, restock targets and missing reagents"
```

---

