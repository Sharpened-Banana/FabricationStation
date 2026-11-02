### Task 15: Queue tab and restock editor

**Files:**
- Create: `UI/Tabs/Queue.lua`
- Modify: `FabricationStation.toc`
- Test: `tests/ui/queue_tab_spec.lua`

**Interfaces:**
- Consumes: `MainWindow:RegisterTab("queue", { label = "Queue", order = 30, phase = 1, ... })`, `Queue:GetEntries/GetEntryMissing/GetEntryCost/SetQuantity/Remove/Clear/ExportShoppingList/CraftNext/GetRestockTargets/SetRestock/GetCooldownReadyAt`, `C_Item.GetItemNameByID`, `ns.UI.ParseItemID/FormatMoney`; message `FS_QUEUE_CHANGED`.
- Produces: `ns.UI.QueueTab.BuildRows(entries, costs, missing, readyAt, now) -> { { id, name, charKey, quantity, targetQuality, concentration, missingText, cost, readyText, isRestock } }`; `ns.UI.QueueTab.StatusText(result, professionName, charName) -> string`.

Columns (spec §5.1): character, quantity, target quality, concentration on/off, missing reagents, total cost, plus "ready in 2h 5m" for cooldown entries. Buttons: Shopping List, Clear, Craft Next (`OnClick` only), Restock editor (item ID or shift-clicked link + target; list with Remove). `StatusText`: crafted → `"Crafting <recipe>…"`; open → `"Open <Profession> on <Character>"`; missing → `"Missing reagents — see Shopping List"`; cooldown → `"Next craft ready in <time>"`; empty → `"Queue is empty"`. Shopping List feedback: `"Shopping list updated (N items)"`, `"… N items skipped, try again"`, `"Auctionator not available"`.

- [ ] **Step 1: Write the failing test**

```lua
describe("Queue tab model", function()
  local T
  before_each(function() local ns = make_world({ last = "UI/Tabs/Queue.lua" }); T = ns.UI.QueueTab end)
  it("shows missing reagents, cost and cooldown", function()
    local rows = T.BuildRows({ { id = 1, recipeID = 9001, quantity = 3, charKey = "Alt-Realm", targetQuality = 2, useConcentration = true } },
      { [1] = 2700 }, { [1] = { [1001] = 2 } }, { [1] = 7500 }, 0)
    assert.same({ 2700, "on", "2× item:1001", "ready in 2h 5m" }, { rows[1].cost, rows[1].concentration, rows[1].missingText, rows[1].readyText })
  end)
  it("status text", function()
    assert.equals("Open Alchemy on Alt", T.StatusText({ status = "open" }, "Alchemy", "Alt"))
    assert.equals("Queue is empty", T.StatusText({ status = "empty" }))
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/ui/queue_tab_spec.lua`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement `UI/Tabs/Queue.lua`** (`missingText` uses cached item names, else `item:<id>`).

- [ ] **Step 4: Run tests, then verify in game**

Run: `busted tests/ui/queue_tab_spec.lua`
Expected: PASS. In game: Shopping List creates the Auctionator list "FabricationStation" with the shown quantities; Craft Next with the profession closed shows "Open <Profession> on <Character>"; with it open, one craft per click.

- [ ] **Step 5: Commit**

```bash
git add UI/Tabs/Queue.lua tests/ui/queue_tab_spec.lua FabricationStation.toc
git commit -m "feat: add Queue tab with shopping list, Craft Next and restock editor"
```

---

