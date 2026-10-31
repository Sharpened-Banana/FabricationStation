### Task 7: Ledger capture — craft cost basis, order commissions, AH sale mail

**Files:**
- Modify: `Modules/Ledger.lua`, `.luacheckrc` (`GetInboxInvoiceInfo`, `GetInboxHeaderInfo`, `TakeInboxMoney`, `AutoLootMailItem`, `AUCTION_SOLD_MAIL_SUBJECT`)
- Test: `tests/ledger/capture_spec.lua`

**Interfaces:**
- Consumes: 1a `Scanner:GetSchematic(recipeID)` (`reagentSlots = { {slotIndex, required, quantity, reagents = {itemID,...} (lowest quality rank first), kind, dataSlotIndex, dataSlotType, automatic, currencyID?} }`; currency-only slots set `currencyID` and leave it out of `reagents`); 1a `Prices:Get`; `Enum.TradeskillSlotDataType.ModifiedReagent` (= 2, in 1a's stubs); `Orders:GetClaimedOrder() -> OrderInput|nil` (Task 5); `ns.Msg.ORDER_FULFILLED` / `FulfilledOrder` (Task 5). `craftingReagents` has 1a's verified shape `{ {reagent = {itemID?, currencyID?}, dataSlotIndex, quantity} }` and covers only `ModifiedReagent` slots, whether Blizzard's UI or 1b's `Queue:CraftNext` (via `Scanner:ToCraftingReagentInfo`) made the call; the post-hook sees both.
- Produces:
  - `Ledger:OnCraftRecipe(recipeID, numCasts, craftingReagents, recipeLevel, orderID, applyConcentration)` (post-hook on `C_TradeSkillUI.CraftRecipe`).
  - `Ledger:OnCraftResult(event, data)` (`TRADE_SKILL_ITEM_CRAFTED_RESULT`).
  - `Ledger:CostOfCraft(recipeID, craftingReagents, provided, returned) -> cost, incomplete, estimated`.
  - `Ledger:OnOrderFulfilled(event, fulfilled)`.
  - `Ledger:OnTakeMoney(index)` (post-hook on `TakeInboxMoney` and `AutoLootMailItem`).
  - `Ledger.ItemNameFromLink(link) -> string|nil`.
  - `Ledger:ResolveItemName(name) -> itemID|nil, ambiguous`.
- `CostOfCraft` rules:
  - A reagent's itemID is `r.reagent.itemID`; entries with only `r.reagent.currencyID` cost 0. Slots with `currencyID` and empty `reagents` are skipped.
  - For each schematic slot, use the `craftingReagents` entries whose `dataSlotIndex == slot.dataSlotIndex`. If there are none and the slot is required:
    - a slot whose `dataSlotType ~= Enum.TradeskillSlotDataType.ModifiedReagent` is a fixed reagent that Blizzard never passes, so it costs exactly `slot.reagents[1] × slot.quantity` (not estimated);
    - a `ModifiedReagent` slot with no entry uses `slot.reagents[1] × slot.quantity` and marks the cost `estimated`.
    Optional and finishing slots with no entry add nothing.
  - The paid quantity per item is `max(0, used - provided[itemID])`.
  - Returned reagents are subtracted at their price.
  - Any used item without a price makes the cost `incomplete`, and the cost then sums only the priced items.
- The craft entry is `{type="craft", amount=-cost, itemID=data.itemID, quantity=data.quantity, quality=data.craftingQuality, recipeID, ref=orderID, operationID=data.operationID, incomplete?}`. A non-order craft that is not incomplete also adds to `costBasis[itemID] = {totalCost += cost, totalQty += quantity, recipeID}` and sets `nameIndex[ItemNameFromLink(data.hyperlink)] = {itemID, ambiguous}`, where `ambiguous` becomes true once a second itemID has been seen for that name.
- Multicraft (same rule as 1b's Queue Task 12): a result whose `operationID` equals the last recorded craft's `operationID` is an extra from the same cast. It adds its `quantity` to that craft entry (and to `costBasis.totalQty` when that entry fed the cost basis), records no new cost and does not consume a cast.
- `ItemNameFromLink` strips `|A...|a` atlas markup and trims spaces from the text inside `[...]`.
- The commission entry is `{type="commission", amount=commission, tip, recipeID, itemID, quality, customer, orderType, ref=orderID, rewardsValue, cost = Σ -amount of craft entries with ref == orderID, or nil when none}`.
- Sale entries:
  - From the invoice: `invoiceType == "seller"` gives `{type="sale", source="invoice", itemName, itemID, ambiguous, quantity=count or 1, amount=bid-consignment, buyer=playerName, deposit, recipeID=costBasis.recipeID, cost=floor(totalCost/totalQty*quantity+0.5) or nil}`.
  - Subject fallback, used only when the invoice is nil: the subject matches a pattern built from `AUCTION_SOLD_MAIL_SUBJECT`, or the literal `"Auction successful: %s"` when that global is missing. It produces `{source="subject", itemName=<capture>, quantity=1, amount=header money}`.
  - Dedupe signature: `itemName|bid or money|count|playerName|floor(daysLeft*1440)`, kept for the session. Header money of 0 is skipped.
- `OnEnable` sets up, each body wrapped with `ns.FS:Wrap("Ledger", …)`; the three `hooksecurefunc` hooks are installed once per session (guard `self.hooked`, as 1a's Prices does, because `hooksecurefunc` cannot be undone and a module can be disabled and re-enabled), and each hook body returns early while `not self:IsEnabled()`:
  - `hooksecurefunc(C_TradeSkillUI, "CraftRecipe", …)`
  - `hooksecurefunc("TakeInboxMoney", …)` and `hooksecurefunc("AutoLootMailItem", …)`
  - the event `TRADE_SKILL_ITEM_CRAFTED_RESULT`
  - the message `ns.Msg.ORDER_FULFILLED`

- [ ] **Step 1: Write the failing tests**

```lua
local P2 = require("tests.helpers.phase2")
describe("Ledger capture", function()
  local ns, L, inv, hdr, claimed, op
  local LINK = "|cff1eff00|Hitem:211111::|h[Potion of Foo |A:Professions-ChatIcon-Quality-Tier3:17:15::1|a]|h|r"
  before_each(function()
    inv, hdr, claimed, op = {}, {}, nil, 0
    ns = P2.boot({ GetInboxInvoiceInfo = function(i) return unpack(inv[i] or {}, 1, 12) end,
                   GetInboxHeaderInfo = function(i) return unpack(hdr[i] or {}, 1, 12) end,
                   AUCTION_SOLD_MAIL_SUBJECT = "Auction successful: %s",
                   C_DateAndTime = { GetSecondsUntilWeeklyReset = function() return 1 end } })
    local price = {[100]=10000, [101]=15000, [200]=5000}
    P2.fake_module(ns, "Prices", { Get = function(_, id) return {value = price[id]} end })
    P2.fake_module(ns, "Scanner", { GetSchematic = function() return { reagentSlots = {
      {slotIndex=1, required=true, quantity=3, reagents={100,101}, kind="basic", dataSlotIndex=1, dataSlotType=2},   -- quality slot: in craftingReagents
      {slotIndex=2, required=true, quantity=2, reagents={200}, kind="basic", dataSlotIndex=2, dataSlotType=1} } } end })   -- fixed reagent: never passed
    P2.fake_module(ns, "Orders", { GetClaimedOrder = function() return claimed end })
    P2.load(ns, {"Modules/Ledger.lua"}); L = ns.FS:GetModule("Ledger")
  end)
  local function craft(orderID)
    op = op + 1
    L:OnCraftRecipe(4444, 1, { {reagent={itemID=100}, quantity=3, dataSlotIndex=1} }, nil, orderID, false)
    L:OnCraftResult("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID=211111, quantity=2, craftingQuality=3, hyperlink=LINK, operationID=op,
      resourcesReturned={ {reagent={itemID=100}, quantity=1} }})
  end
  it("stores craft cost basis at craft time", function()
    craft(nil)
    local e = L:Query({type="craft"})[1]
    assert.same({-30000, 2, 3, 4444, 211111}, {e.amount, e.quantity, e.quality, e.recipeID, e.itemID})
    assert.is_nil(e.incomplete)
    assert.same({totalCost=30000, totalQty=2, recipeID=4444}, ns.FS.db.global.ledger.costBasis[211111])
    assert.equal(211111, (L:ResolveItemName("Potion of Foo")))
  end)
  it("adds a multicraft extra with the same operationID to the same craft entry", function()
    craft(nil)
    L:OnCraftResult("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID=211111, quantity=1, craftingQuality=3, hyperlink=LINK, operationID=op})
    local e = L:Query({type="craft"}); assert.equal(1, #e)
    assert.same({3, -30000}, {e[1].quantity, e[1].amount})
    assert.same({totalCost=30000, totalQty=3, recipeID=4444}, ns.FS.db.global.ledger.costBasis[211111])
  end)
  it("is reached through the CraftRecipe post-hook", function()
    C_TradeSkillUI.CraftRecipe(4444, 1, { {reagent={itemID=100}, quantity=3, dataSlotIndex=1} }, nil, nil, false)
    L:OnCraftResult("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID=211111, quantity=1, craftingQuality=3, hyperlink=LINK, operationID=99})
    assert.equal(1, #L:Query({type="craft"}))
  end)
  it("subtracts customer-provided reagents and records the commission", function()
    claimed = {orderID=777, provided={[200]=2}}
    craft(777)
    assert.equal(-20000, L:Query({type="craft"})[1].amount)
    assert.is_nil(ns.FS.db.global.ledger.costBasis[211111])
    L:OnOrderFulfilled("FS_ORDER_FULFILLED", {orderID=777, orderType="personal", customer="Bob-Silvermoon", recipeID=4444, itemID=211111,
      quality=3, tip=500000, consortiumCut=50000, commission=450000, rewards={}, rewardsValue=0, time=1000, charKey="Me-Silvermoon"})
    local c = L:Query({type="commission"})[1]
    assert.same({450000, 20000, 500000, 777}, {c.amount, c.cost, c.tip, c.ref})
  end)
  it("records an AH sale from the invoice with cost basis", function()
    craft(nil); craft(nil)   -- costBasis 60000 / 4
    inv[1] = {"seller", "Potion of Foo", "Buyer", 1000000, 0, 20000, 50000, 0, 0, 0, 5, false}
    hdr[1] = {nil, nil, "Auction House", "Auction successful: Potion of Foo (5)", 970000, 0, 29.5, 0}
    L:OnTakeMoney(1)
    local s = L:Query({type="sale"})[1]
    assert.same({950000, 5, 75000, 4444, 211111, "invoice"}, {s.amount, s.quantity, s.cost, s.recipeID, s.itemID, s.source})
  end)
  it("ignores a second take of the same mail", function()
    inv[1] = {"seller", "Potion of Foo", "Buyer", 1000000, 0, 20000, 50000, 0, 0, 0, 5, false}
    hdr[1] = {nil, nil, "Auction House", "x", 970000, 0, 29.5, 0}
    L:OnTakeMoney(1); L:OnTakeMoney(1); assert.equal(1, #L:Query({type="sale"}))
  end)
  it("records a sale of an uncrafted item as incomplete", function()
    inv[2] = {"seller", "Mystery Ore", nil, 40000, 0, 0, 2000, 0, 0, 0, 1, true}
    hdr[2] = {nil, nil, "Auction House", "x", 38000, 0, 10, 0}
    L:OnTakeMoney(2)
    local s = L:Query({type="sale"})[1]
    assert.is_nil(s.itemID); assert.is_nil(s.cost); assert.equal(38000, s.amount)
    assert.equal(1, L:Weekly(1000, 1)[1].incomplete)
  end)
  it("falls back to the English subject and ignores purchases", function()
    inv[3] = {"buyer", "Thing", "Seller", 5000, 0, 0, 0, 0, 0, 0, 1, false}; hdr[3] = {nil, nil, "Auction House", "Auction won: Thing", 0, 0, 30, 1}
    hdr[4] = {nil, nil, "Auction House", "Auction successful: Potion of Foo", 950000, 0, 29, 0}
    L:OnTakeMoney(3); L:OnTakeMoney(4)
    local s = L:Query({type="sale"}); assert.equal(1, #s)
    assert.same({"subject", "Potion of Foo", 950000, 1}, {s[1].source, s[1].itemName, s[1].amount, s[1].quantity})
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted tests/ledger/capture_spec.lua`
Expected: FAIL (`attempt to call method 'OnCraftRecipe' (a nil value)`)

- [ ] **Step 3: Implement the capture functions listed under Interfaces in `Modules/Ledger.lua`**

The pending craft context `{recipeID, craftingReagents, orderID, provided, castsLeft = numCasts}` is set by `OnCraftRecipe`. `provided` comes from `Orders:GetClaimedOrder()` when its `orderID` matches. `OnCraftResult` first checks the multicraft rule (same `operationID` as the last recorded craft entry, which is kept outside the context so it still matches after the context is cleared). Otherwise it uses the context and decrements `castsLeft`, then clears the context at 0. A result with no context and no matching `operationID` records nothing.

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted tests/ledger && luacheck .`
Expected: PASS

- [ ] **Step 5: In-game check**

- Craft one item. `/dump FabricationStationDB.global.ledger.entries[#FabricationStationDB.global.ledger.entries]` shows a `craft` entry with a negative amount.
- Collect one "Auction successful" mail with Open All. It produces exactly one `sale` entry.
- Note in the commit message whether a multicraft proc arrived as a second `TRADE_SKILL_ITEM_CRAFTED_RESULT` with the same `operationID` (the rule shared with 1b's Queue), or was already included in the first result's `quantity`.

- [ ] **Step 6: Commit**

```bash
git add Modules/Ledger.lua tests/ledger/capture_spec.lua .luacheckrc
git commit -m "feat: capture craft cost basis, order commissions and AH sales from mail"
```


**Orchestrator notes (rulings and carry-forward; these win over the plan text above where they differ):**
- Ruling P3: recrafts and enchants on existing items are NOT tracked by the Ledger in phase 2 — skip them in capture (detect and ignore, with a test), and say so in a code comment.
- From Task 6: `Ledger:Add` raises for a bad `type` or a non-integer `amount`. Capture code must ROUND/validate the amount itself before calling Add (e.g. `math.floor(x + 0.5)`), and skip (log once) when it can't produce an integer — a raise inside an event hook would disable the Ledger module. Invalid cost/tip/time are already tolerated by Add (cost → nil + incomplete).
- `Ledger:Query` returns live saved rows; never mutate them.
- Hotfix H1 landed before you (Scanner live owned counts via C_Item.GetItemCount for the current character; panel game header; shopping-list retry). Don't regress it.
- Unknown money is never 0: an unknown cost basis is nil (incomplete), not 0.
