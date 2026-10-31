local P2 = require("tests.helpers.phase2")
describe("Ledger capture", function()
  local ns, W, L, inv, hdr, claimed, op, price, schematic
  local LINK = "|cff1eff00|Hitem:211111::|h[Potion of Foo |A:Professions-ChatIcon-Quality-Tier3:17:15::1|a]|h|r"
  local LINK2 = "|cff1eff00|Hitem:211112::|h[Potion of Foo |A:Professions-ChatIcon-Quality-Tier2:17:15::1|a]|h|r"
  local noop = function() end
  before_each(function()
    inv, hdr, claimed, op = {}, {}, nil, 0
    ns, W = P2.boot({ GetInboxInvoiceInfo = function(i) return unpack(inv[i] or {}, 1, 12) end,
                   GetInboxHeaderInfo = function(i) return unpack(hdr[i] or {}, 1, 12) end,
                   AUCTION_SOLD_MAIL_SUBJECT = "Auction successful: %s",
                   C_DateAndTime = { GetSecondsUntilWeeklyReset = function() return 1 end },
                   C_TradeSkillUI = { RecraftRecipe = noop, RecraftRecipeForOrder = noop, CraftEnchant = noop } })
    price = {[100]=10000, [101]=15000, [200]=5000}
    schematic = { reagentSlots = {
      {slotIndex=1, required=true, quantity=3, reagents={100,101}, kind="basic", dataSlotIndex=1, dataSlotType=2},   -- quality slot: in craftingReagents
      {slotIndex=2, required=true, quantity=2, reagents={200}, kind="basic", dataSlotIndex=2, dataSlotType=1} } }   -- fixed reagent: never passed
    P2.fake_module(ns, "Prices", { Get = function(_, id) return {value = price[id]} end })
    P2.fake_module(ns, "Scanner", { GetSchematic = function() return schematic end })
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

  describe("CostOfCraft", function()
    it("prices a quality slot with no entry at its lowest rank and marks the cost estimated", function()
      assert.same({40000, false, true}, {L:CostOfCraft(4444, {}, nil, nil)})
    end)
    it("charges nothing for a quality slot the customer provided (Blizzard leaves it out of craftingReagents)", function()
      assert.same({10000, false, false}, {L:CostOfCraft(4444, {}, {[101]=3}, nil)})
      assert.same({20000, false, true}, {L:CostOfCraft(4444, {}, {[101]=2}, nil)})   -- one lowest-rank item still paid
    end)
    it("does not count a provided item twice across entries", function()
      local reagents = { {reagent={itemID=100}, quantity=2, dataSlotIndex=1}, {reagent={itemID=100}, quantity=1, dataSlotIndex=1} }
      assert.same({20000, false, false}, {L:CostOfCraft(4444, reagents, {[100]=2}, nil)})
    end)
    it("charges currency entries nothing and skips optional slots with no entry", function()
      schematic.reagentSlots[3] = {slotIndex=3, required=false, quantity=1, reagents={300}, kind="optional", dataSlotIndex=3, dataSlotType=2}
      schematic.reagentSlots[4] = {slotIndex=4, required=true, quantity=5, reagents={}, currencyID=3008, dataSlotIndex=4, dataSlotType=2}
      local reagents = { {reagent={itemID=101}, quantity=3, dataSlotIndex=1}, {reagent={currencyID=3008}, quantity=5, dataSlotIndex=4} }
      assert.same({55000, false, false}, {L:CostOfCraft(4444, reagents, {}, nil)})
    end)
    it("counts an optional reagent that was passed", function()
      schematic.reagentSlots[3] = {slotIndex=3, required=false, quantity=1, reagents={101}, kind="optional", dataSlotIndex=3, dataSlotType=2}
      local reagents = { {reagent={itemID=100}, quantity=3, dataSlotIndex=1}, {reagent={itemID=101}, quantity=1, dataSlotIndex=3} }
      assert.same({55000, false, false}, {L:CostOfCraft(4444, reagents, {}, nil)})
    end)
    it("sums only priced items and marks the cost incomplete when one has no price", function()
      local reagents = { {reagent={itemID=999}, quantity=3, dataSlotIndex=1} }
      assert.same({10000, true, false}, {L:CostOfCraft(4444, reagents, {}, nil)})
    end)
    it("is incomplete without a schematic", function()
      schematic = nil
      local cost, incomplete = L:CostOfCraft(4444, { {reagent={itemID=100}, quantity=3, dataSlotIndex=1} }, {}, nil)
      assert.equal(30000, cost); assert.is_true(incomplete)
    end)
  end)

  describe("crafts", function()
    it("records the event and each cast of a multi-cast craft, then nothing without a pending craft", function()
      L:OnCraftRecipe(4444, 2, { {reagent={itemID=100}, quantity=3, dataSlotIndex=1} }, nil, nil, false)
      W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID=211111, quantity=1, hyperlink=LINK, operationID=1})
      W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID=211111, quantity=1, hyperlink=LINK, operationID=2})
      W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID=211111, quantity=1, hyperlink=LINK, operationID=3})
      assert.equal(2, #L:Query({type="craft"}))
      assert.same({totalCost=80000, totalQty=2, recipeID=4444}, ns.FS.db.global.ledger.costBasis[211111])
    end)
    it("leaves an incomplete craft out of the cost basis and passes incomplete on to the commission", function()
      price[200] = nil
      claimed = {orderID=777, provided={}}
      craft(nil)
      local e = L:Query({type="craft"})[1]
      assert.is_true(e.incomplete); assert.equal(-20000, e.amount)
      assert.is_nil(ns.FS.db.global.ledger.costBasis[211111])
      assert.is_nil(L:ResolveItemName("Potion of Foo"))
      craft(777)
      L:OnOrderFulfilled("FS_ORDER_FULFILLED", {orderID=777, recipeID=4444, tip=1000, commission=900, time=1000})
      local c = L:Query({type="commission"})[1]
      assert.equal(20000, c.cost); assert.is_true(c.incomplete)
    end)
    it("records a commission with no craft entries with cost nil", function()
      ns.FS:SendMessage("FS_ORDER_FULFILLED", {orderID=5, recipeID=4444, tip=1000, consortiumCut=100, commission=900, time=1000})
      local c = L:Query({type="commission"})[1]
      assert.same({900, 1000, 5}, {c.amount, c.tip, c.ref}); assert.is_nil(c.cost)
      assert.equal(1, L:Weekly(1000, 1)[1].incomplete)
    end)
    it("skips a commission whose amount is unknown, without an error", function()
      L:OnOrderFulfilled("FS_ORDER_FULFILLED", {orderID=5, recipeID=4444, time=1000})
      assert.equal(0, #L:Query({type="commission"})); assert.is_true(L:IsEnabled())
    end)
    it("rounds a fractional cost to whole copper", function()
      price[100] = 3333.4
      craft(nil)   -- 3 * 3333.4 + 2 * 5000 - 3333.4 = 16666.8
      assert.equal(-16667, L:Query({type="craft"})[1].amount)
      assert.same({totalCost=16667, totalQty=2, recipeID=4444}, ns.FS.db.global.ledger.costBasis[211111])
    end)
    it("skips a craft whose cost is not a finite number, without turning the Ledger off", function()
      price[100] = math.huge
      W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", {})   -- no pending craft: nothing
      L:OnCraftRecipe(4444, 1, { {reagent={itemID=100}, quantity=3, dataSlotIndex=1} }, nil, nil, false)
      W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID=211111, quantity=1, hyperlink=LINK, operationID=1})
      L:OnCraftRecipe(4444, 1, { {reagent={itemID=100}, quantity=3, dataSlotIndex=1} }, nil, nil, false)
      W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID=211111, quantity=1, hyperlink=LINK, operationID=2,
        resourcesReturned={ {reagent={itemID=100}, quantity=1} }})   -- inf - inf: NaN, not 0
      assert.is_nil(L:CostOfCraft(4444, { {reagent={itemID=100}, quantity=3, dataSlotIndex=1} }, {}, { {reagent={itemID=100}, quantity=1} }))
      assert.equal(0, #L:Query({type="craft"})); assert.is_true(L:IsEnabled())
      assert.is_nil(ns.FS.failedModules and ns.FS.failedModules.Ledger)
    end)
    it("writes nothing while the saved data is from a newer version", function()
      ns.FS.dbIsNewer = true
      craft(nil)
      inv[1] = {"seller", "Potion of Foo", "Buyer", 1000000, 0, 20000, 50000, 0, 0, 0, 5, false}
      hdr[1] = {nil, nil, "Auction House", "x", 970000, 0, 29.5, 0}
      L:OnTakeMoney(1)
      assert.equal(0, #L:Query({})); assert.is_nil(ns.FS.db.global.ledger.costBasis)
    end)
  end)

  describe("recrafts and enchants (Ruling P3: not tracked in phase 2)", function()
    it("ignores a recraft or enchant that follows an unfinished multi-cast craft", function()
      L:OnCraftRecipe(4444, 5, { {reagent={itemID=100}, quantity=3, dataSlotIndex=1} }, nil, nil, false)
      W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID=211111, quantity=1, hyperlink=LINK, operationID=1})
      C_TradeSkillUI.RecraftRecipe("Item-1", {}, nil, false)
      W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID=211111, quantity=1, hyperlink=LINK, operationID=2})
      L:OnCraftRecipe(4444, 5, { {reagent={itemID=100}, quantity=3, dataSlotIndex=1} }, nil, nil, false)
      C_TradeSkillUI.CraftEnchant(5555, 1, {}, nil, false)
      W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID=211111, quantity=1, hyperlink=LINK, operationID=3})
      assert.equal(1, #L:Query({type="craft"}))
    end)
    it("ignores an enchant result", function()
      L:OnCraftRecipe(4444, 1, { {reagent={itemID=100}, quantity=3, dataSlotIndex=1} }, nil, nil, false)
      L:OnCraftResult("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID=211111, quantity=1, hyperlink=LINK, operationID=1, isEnchant=true})
      assert.equal(0, #L:Query({type="craft"}))
    end)
    it("ignores a craft and the commission of a recraft order", function()
      claimed = {orderID=888, isRecraft=true, provided={}}
      craft(888)
      C_TradeSkillUI.RecraftRecipeForOrder(999, "Item-2", {}, nil, false)
      L:OnOrderFulfilled("FS_ORDER_FULFILLED", {orderID=888, recipeID=4444, tip=1000, commission=900, time=1000})
      L:OnOrderFulfilled("FS_ORDER_FULFILLED", {orderID=999, recipeID=4444, tip=1000, commission=900, time=1000})
      assert.equal(0, #L:Query({}))
    end)
  end)

  describe("item names", function()
    it("reads the name from a link", function()
      assert.equal("Potion of Foo", L.ItemNameFromLink(LINK))
      assert.equal("Linen Cloth", L.ItemNameFromLink("|cffffffff|Hitem:2589::|h[ Linen Cloth ]|h|r"))
      assert.is_nil(L.ItemNameFromLink(nil)); assert.is_nil(L.ItemNameFromLink("no link"))
    end)
    it("marks a name shared by two crafted itemIDs ambiguous and records its sale with no cost", function()
      craft(nil)
      L:OnCraftRecipe(4444, 1, { {reagent={itemID=100}, quantity=3, dataSlotIndex=1} }, nil, nil, false)
      L:OnCraftResult("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID=211112, quantity=1, hyperlink=LINK2, operationID=50})
      assert.same({211112, true}, {L:ResolveItemName("Potion of Foo")})
      craft(nil)   -- seeing the first ID again keeps the name ambiguous
      assert.same({211111, true}, {L:ResolveItemName("Potion of Foo")})
      inv[1] = {"seller", "Potion of Foo", "Buyer", 100000, 0, 0, 5000, 0, 0, 0, 1, false}
      hdr[1] = {nil, nil, "Auction House", "x", 95000, 0, 29.5, 0}
      L:OnTakeMoney(1)
      local s = L:Query({type="sale"})[1]
      assert.same({211111, true, 4444}, {s.itemID, s.ambiguous, s.recipeID}); assert.is_nil(s.cost)
      assert.equal(1, L:Weekly(1000, 1)[1].incomplete)
    end)
    it("resolves nothing for an unknown name", function()
      assert.is_nil(L:ResolveItemName("Nope")); assert.is_nil(L:ResolveItemName(nil))
    end)
  end)

  describe("mail", function()
    it("reads the stack size from the subject and resolves its item", function()
      craft(nil)
      hdr[1] = {nil, nil, "Auction House", "Auction successful: Potion of Foo (4)", 900000, 0, 29, 0}
      L:OnTakeMoney(1)
      local s = L:Query({type="sale"})[1]
      assert.same({"Potion of Foo", 4, 900000, 211111, 60000, 4444}, {s.itemName, s.quantity, s.amount, s.itemID, s.cost, s.recipeID})
    end)
    it("ignores pending-sale invoices, mail with no money and other subjects", function()
      inv[1] = {"seller_temp_invoice", "Potion of Foo", "Buyer", 100000, 0, 0, 5000, 0, 0, 0, 1, false}
      hdr[1] = {nil, nil, "Auction House", "Sale Pending: Potion of Foo", 0, 0, 29, 0}
      inv[2] = {"seller", "Potion of Foo", "Buyer", 100000, 0, 0, 5000, 0, 0, 0, 1, false}
      hdr[2] = {nil, nil, "Auction House", "x", 0, 0, 29, 0}
      hdr[3] = {nil, nil, "Someone", "Hello", 50000, 0, 29, 0}
      L:OnTakeMoney(1); L:OnTakeMoney(2); L:OnTakeMoney(3); L:OnTakeMoney(4)
      assert.equal(0, #L:Query({}))
    end)
    it("hooks TakeInboxMoney and AutoLootMailItem once and ignores them while off", function()
      L:Disable(); L:Enable()
      local count = {}
      for _, h in ipairs(W.hooks) do count[h[2]] = (count[h[2]] or 0) + 1 end
      assert.same({1, 1, 1}, {count.TakeInboxMoney, count.AutoLootMailItem, count.CraftRecipe})
      inv[1] = {"seller", "Potion of Foo", "Buyer", 100000, 0, 0, 5000, 0, 0, 0, 1, false}
      hdr[1] = {nil, nil, "Auction House", "x", 95000, 0, 29.5, 0}
      inv[2] = {"seller", "Other", "Buyer", 100000, 0, 0, 5000, 0, 0, 0, 1, false}
      hdr[2] = {nil, nil, "Auction House", "x", 95000, 0, 29.5, 0}
      TakeInboxMoney(1); AutoLootMailItem(1); AutoLootMailItem(2)
      assert.equal(2, #L:Query({type="sale"}))
      L:Disable()
      inv[3] = {"seller", "Third", "Buyer", 100000, 0, 0, 5000, 0, 0, 0, 1, false}
      hdr[3] = {nil, nil, "Auction House", "x", 95000, 0, 29.5, 0}
      TakeInboxMoney(3)
      C_TradeSkillUI.CraftRecipe(4444, 1, {}, nil, nil, false)
      L:Enable()
      W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID=211111, quantity=1, hyperlink=LINK, operationID=1})
      assert.equal(2, #L:Query({}))
    end)
  end)
end)
