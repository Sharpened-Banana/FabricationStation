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

  describe("entries", function()
    it("is a core module", function() assert.is_true(Q.coreModule) end)
    it("stores in db.global.queue with a lazy nextID and keeps ids unique after removals", function()
      local q = ns.FS.db.global.queue
      local a = Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
      Q:Remove(a)
      local b = Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
      assert.are_not.equal(a, b)
      assert.equals(1, #q.entries)
      assert.is_number(q.nextID)
    end)
    it("derives nextID from existing entries when it is missing", function()
      ns.FS.db.global.queue.entries[1] = { id = 7, recipeID = 9001, quantity = 1, charKey = "Main-Realm" }
      assert.equals(8, Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" }))
    end)
    it("defaults the character and rejects bad entries", function()
      local id = Q:Add({ recipeID = 9001, quantity = 2 })
      assert.equals("Main-Realm", Q:GetEntries()[1].charKey)
      assert.is_nil(Q:Add({ quantity = 1 })); assert.is_nil(Q:Add({ recipeID = 9001, quantity = 0 }))
      assert.is_nil(Q:Add({ recipeID = 9001, quantity = "x" })); assert.is_nil(Q:Add(nil))
      assert.equals(1, #Q:GetEntries()); assert.is_number(id)
    end)
    it("keeps the optional fields and hands out copies", function()
      local id = Q:Add({ recipeID = 9001, quantity = 1, charKey = "Alt-Realm", targetQuality = 2, useConcentration = true,
        orderID = 55, providedReagents = { [1001] = 2 } })
      local e = Q:GetEntries()[1]
      assert.same({ id, 9001, 1, "Alt-Realm", 2, true, 55, { [1001] = 2 } },
        { e.id, e.recipeID, e.quantity, e.charKey, e.targetQuality, e.useConcentration, e.orderID, e.providedReagents })
      e.quantity = 99; e.providedReagents[1001] = 99
      assert.equals(1, Q:GetEntries()[1].quantity); assert.equals(2, Q:GetEntries()[1].providedReagents[1001])
    end)
    it("changes the quantity and removes at zero", function()
      local id = Q:Add({ recipeID = 9001, quantity = 3, charKey = "Main-Realm" })
      Q:SetQuantity(id, 5); assert.equals(5, Q:GetEntries()[1].quantity)
      Q:SetQuantity(id, 0); assert.equals(0, #Q:GetEntries())
    end)
    it("clears real entries only", function()
      world.counts[5002] = 0; Q:SetRestock(5002, 5)
      Q:Add({ recipeID = 9001, quantity = 3, charKey = "Main-Realm" })
      Q:Clear()
      local list = Q:GetEntries()
      assert.equals(1, #list); assert.is_true(list[1].isRestock)
      assert.same({ [5002] = 5 }, Q:GetRestockTargets())
    end)
    it("announces every change once, and nothing for a no-op", function()
      local n = #world.messages("FS_QUEUE_CHANGED")
      local id = Q:Add({ recipeID = 9001, quantity = 3, charKey = "Main-Realm" })
      Q:SetQuantity(id, 4); Q:SetRestock(5002, 5); Q:SetRestock(5002, nil); Q:Remove(id)
      assert.equals(n + 5, #world.messages("FS_QUEUE_CHANGED"))
      Q:Remove(id); Q:SetRestock(5002, nil); Q:Clear(); Q:SetQuantity(id, 2)
      assert.equals(n + 5, #world.messages("FS_QUEUE_CHANGED"))
    end)
    it("writes nothing while the saved data is from a newer version", function()
      ns.FS.dbIsNewer = true
      assert.is_nil(Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" }))
      Q:SetRestock(5002, 5)
      assert.equals(0, #ns.FS.db.global.queue.entries); assert.same({}, ns.FS.db.global.queue.restock)
      assert.is_nil(ns.FS.db.global.queue.nextID)
    end)
    it("blocks Remove, SetQuantity and Clear on existing entries while the saved data is newer", function()
      local a = Q:Add({ recipeID = 9001, quantity = 3, charKey = "Main-Realm" })
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Alt-Realm" })
      ns.FS.dbIsNewer = true
      local n = #world.messages("FS_QUEUE_CHANGED")
      Q:Remove(a); Q:SetQuantity(a, 7); Q:SetQuantity(a, 0); Q:Clear()
      local entries = ns.FS.db.global.queue.entries
      assert.equals(2, #entries); assert.equals(a, entries[1].id); assert.equals(3, entries[1].quantity)
      assert.equals(n, #world.messages("FS_QUEUE_CHANGED"))
    end)
    it("reads a damaged newer save without repairing it", function()
      local g = ns.FS.db.global
      local saved = { entries = "future format", restock = 5, extra = { 1 } }
      g.queue = saved
      ns.FS.dbIsNewer = true
      assert.same({}, Q:GetEntries()); assert.same({}, Q:GetRestockTargets())
      assert.same({}, Q:GetMissingReagents(nil)); assert.same({}, Q:GetEntryMissing(1)); assert.is_nil(Q:GetEntryCost(1))
      assert.equals(saved, g.queue)
      assert.same({ entries = "future format", restock = 5, extra = { 1 } }, saved)
      g.queue = nil
      assert.same({}, Q:GetEntries()); assert.same({}, Q:GetRestockTargets())
      assert.is_nil(g.queue)
      g.queue = { restock = { [5002] = 3 } }
      world.counts[5002] = 0
      assert.equals(1, #Q:GetEntries())
      assert.same({ restock = { [5002] = 3 } }, g.queue)
    end)
  end)

  describe("entry lookup", function()
    it("finds a stored entry without evaluating the restock targets", function()
      world.counts[5002] = 0; Q:SetRestock(5002, 20)
      local id = Q:Add({ recipeID = 9001, quantity = 2, charKey = "Main-Realm" })
      world.evaluated = {}
      assert.equals(1800, Q:GetEntryCost(id))
      assert.equals(1, #world.evaluated)
      assert.same({ [1001] = 4, [2002] = 2 }, Q:GetEntryMissing(id))
    end)
    it("still finds restock entries by their id", function()
      world.counts[5002] = 12; Q:SetRestock(5002, 20)
      assert.equals(6300, Q:GetEntryCost("restock:5002"))
      assert.is_nil(Q:GetEntryCost("restock:9999")); assert.is_nil(Q:GetEntryCost("restock:x"))
    end)
  end)

  describe("evaluation options", function()
    it("passes target quality, concentration and provided reagents to Evaluate", function()
      local id = Q:Add({ recipeID = 9001, quantity = 1, charKey = "Alt-Realm", targetQuality = 2, useConcentration = true,
        providedReagents = { [1001] = 2 } })
      Q:GetEntryCost(id)
      local last = world.evaluated[#world.evaluated]
      assert.same({ 9001, "Alt-Realm", 2, true, { [1001] = 2 } },
        { last.recipeID, last.charKey, last.opts.targetQuality, last.opts.useConcentration, last.opts.providedReagents })
    end)
    it("does not ask for reagents the customer provides", function()
      Q:Add({ recipeID = 9001, quantity = 2, charKey = "Alt-Realm", providedReagents = { [1001] = 2 } })
      assert.same({ [2002] = 2 }, Q:GetMissingReagents("Alt-Realm"))
    end)
  end)

  describe("missing reagents", function()
    before_each(function()
      Q:Add({ recipeID = 9001, quantity = 3, charKey = "Alt-Realm" })
    end)
    it("counts bags, bank and reagent bank of that character only", function()
      world.items["Alt-Realm"][1001] = { bags = 1, bank = 2, reagentBank = 1 }
      world.items["Main-Realm"][2002] = { bags = 50, bank = 0, reagentBank = 0 }
      assert.same({ [1001] = 2, [2002] = 3 }, Q:GetMissingReagents("Alt-Realm"))
    end)
    it("does not count the warband twice for a per-character call", function()
      world.items["Alt-Realm"][1001] = { bags = 1, bank = 0, reagentBank = 0 }
      world.warband[1001] = 2
      assert.same({ [1001] = 3, [2002] = 3 }, Q:GetMissingReagents("Alt-Realm"))   -- 6 − 1 − 2; 3 − 0
    end)
    it("does not let one character's surplus cover another's shortfall", function()
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
      world.items["Main-Realm"][1001] = { bags = 100, bank = 0, reagentBank = 0 }
      assert.same({ [1001] = 6, [2002] = 4 }, Q:GetMissingReagents(nil))
    end)
    it("clamps at zero and leaves out satisfied items", function()
      world.items["Alt-Realm"][1001] = { bags = 6, bank = 0, reagentBank = 0 }
      world.warband[2002] = 10
      assert.same({}, Q:GetMissingReagents("Alt-Realm")); assert.same({}, Q:GetMissingReagents(nil))
    end)
    it("lets two entries of one character share that character's stock", function()
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
      world.items["Main-Realm"][1001] = { bags = 3, bank = 0, reagentBank = 0 }
      world.items["Main-Realm"][2002] = { bags = 2, bank = 0, reagentBank = 0 }
      assert.same({ [1001] = 1 }, Q:GetMissingReagents("Main-Realm"))                   -- 2 + 2 − 3; 1 + 1 − 2
      assert.same({ [1001] = 7, [2002] = 3 }, Q:GetMissingReagents(nil))                -- Alt's 6/3 plus Main's 1/0
    end)
    it("is empty for a character with no entries", function()
      assert.same({}, Q:GetMissingReagents("Main-Realm"))
    end)
    it("skips an entry whose recipe has no cached schematic", function()
      world.fakeEvaluate(9001, nil)
      world.schematics[9001] = nil
      assert.same({}, Q:GetMissingReagents(nil))
    end)
    it("reports one entry's shortfall, warband subtracted when enabled", function()
      local id = Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
      world.warband[1001] = 1
      assert.same({ [1001] = 1, [2002] = 1 }, Q:GetEntryMissing(id))
      ns.FS.db.global.settings.crafting = { queueUseWarband = false }
      assert.same({ [1001] = 2, [2002] = 1 }, Q:GetEntryMissing(id))
      assert.same({}, Q:GetEntryMissing(12345))
    end)
  end)

  describe("required modifying reagents (sparks), real evaluation", function()
    before_each(function()
      ns, W, world = make_world({ last = "Modules/Queue.lua", calibrate = { ["Main-Realm"] = { 9001 } } })
      Q = ns.FS:GetModule("Queue")
      table.insert(world.schematics[9001].reagentSlots, { slotIndex = 4, required = true, quantity = 1, reagents = { 7101 },
        kind = "optional", dataSlotIndex = 14, dataSlotType = 2 })
      world.prices[7101] = { value = 4000, source = "auction", ageDays = 1 }
    end)
    it("lists the spark among the missing reagents and costs it", function()
      local id = Q:Add({ recipeID = 9001, quantity = 2, charKey = "Main-Realm" })
      assert.equals(2, Q:GetMissingReagents(nil)[7101])
      assert.equals(2, Q:GetEntryMissing(id)[7101])
      assert.equals(2 * 8800, Q:GetEntryCost(id))
    end)
  end)

  describe("restock", function()
    it("lists nothing when the target is reached, or no one can craft it", function()
      world.counts[5002] = 20; Q:SetRestock(5002, 20); assert.equals(0, #Q:GetEntries())
      world.counts[5002] = 0; Q:SetRestock(5002, 20); assert.equals(1, #Q:GetEntries())
      world.counts[9999] = 0; Q:SetRestock(9999, 5); assert.equals(1, #Q:GetEntries())   -- no recipe makes 9999
    end)
    it("drops the entry once enough crafts are queued", function()
      world.counts[5002] = 12; Q:SetRestock(5002, 20)
      Q:Add({ recipeID = 9001, quantity = 7, charKey = "Main-Realm", targetQuality = 2 })
      assert.equals(1, #Q:GetEntries())
    end)
    it("does not count queued crafts of another quality", function()
      world.counts[5002] = 12; Q:SetRestock(5002, 20)
      Q:Add({ recipeID = 9001, quantity = 7, charKey = "Main-Realm", targetQuality = 1 })
      assert.equals(7, Q:GetEntries()[2].quantity)
    end)
    it("picks the most profitable crafter, first on ties", function()
      world.fakeEvaluate(9001, function(charKey)
        return { allocation = {}, reagentCost = 1, expectedYield = 1, flags = {}, profit = charKey == "Main-Realm" and 900 or 100 }
      end)
      world.counts[5002] = 0; Q:SetRestock(5002, 1)
      assert.equals("Main-Realm", Q:GetEntries()[1].charKey)
      world.fakeEvaluate(9001, { allocation = {}, reagentCost = 1, expectedYield = 1, flags = {}, profit = 5 })
      assert.equals("Alt-Realm", Q:GetEntries()[1].charKey)
    end)
    it("skips a crafter who cannot reach the target quality, however profitable", function()
      world.fakeEvaluate(9001, function(charKey)
        if charKey == "Alt-Realm" then
          return { allocation = {}, reagentCost = 1, expectedYield = 1, profit = 900, flags = { unreachableTarget = true } }
        end
        return { allocation = {}, reagentCost = 1, expectedYield = 1, profit = 100, flags = {} }
      end)
      world.counts[5002] = 0; Q:SetRestock(5002, 1)
      assert.equals("Main-Realm", Q:GetEntries()[1].charKey)
    end)
    it("lists nothing when no crafter can reach the quality, so a lower quality is never crafted forever", function()
      world.fakeEvaluate(9001, { allocation = {}, reagentCost = 1, expectedYield = 1, profit = 9, flags = { unreachableTarget = true } })
      world.counts[5002] = 0; Q:SetRestock(5002, 5)
      assert.same({}, Q:GetEntries())
      assert.same({}, Q:GetEntryMissing("restock:5002")); assert.is_nil(Q:GetEntryCost("restock:5002"))
    end)
    it("falls back to the first crafter when no profit is known", function()
      world.fakeEvaluate(9001, { allocation = {}, expectedYield = 1, flags = { noPrice = true } })
      world.counts[5002] = 0; Q:SetRestock(5002, 1)
      assert.equals("Alt-Realm", Q:GetEntries()[1].charKey)
    end)
    it("treats a missing yield as one", function()
      world.fakeEvaluate(9001, { allocation = {}, flags = {}, profit = 1 })
      world.counts[5002] = 0; Q:SetRestock(5002, 3)
      assert.equals(3, Q:GetEntries()[1].quantity)
    end)
    it("costs and counts missing reagents of restock entries", function()
      world.counts[5002] = 12; Q:SetRestock(5002, 20)
      assert.equals(6300, Q:GetEntryCost("restock:5002"))
      assert.same({ [1001] = 14, [2002] = 7 }, Q:GetMissingReagents(nil))
    end)
    it("exposes and copies the targets", function()
      Q:SetRestock(5002, 20)
      local t = Q:GetRestockTargets(); t[5002] = 1
      assert.same({ [5002] = 20 }, Q:GetRestockTargets())
      Q:SetRestock(5002, 0); assert.same({}, Q:GetRestockTargets())
    end)
  end)

  describe("costs", function()
    it("is nil for an unknown entry or an uncached recipe", function()
      assert.is_nil(Q:GetEntryCost(999))
      local id = Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
      world.fakeEvaluate(9001, nil); world.schematics[9001] = nil
      assert.is_nil(Q:GetEntryCost(id))
    end)
    it("is zero when the reagents are all owned and free", function()
      world.fakeEvaluate(9001, { allocation = {}, reagentCost = 0, flags = {} })
      local id = Q:Add({ recipeID = 9001, quantity = 3, charKey = "Main-Realm" })
      assert.equals(0, Q:GetEntryCost(id))
    end)
  end)

  describe("recomputation", function()
    it("sends one FS_QUEUE_CHANGED per debounce window after recipe and data changes", function()
      local n = #world.messages("FS_QUEUE_CHANGED")
      for _ = 1, 4 do
        Q:SendMessage("FS_RECIPES_CHANGED"); Q:SendMessage("FS_DATA_CHANGED", "Main-Realm", "items")
        W.advance(0.2)
      end
      assert.equals(n, #world.messages("FS_QUEUE_CHANGED"))
      W.advance(0.6)
      assert.equals(n + 1, #world.messages("FS_QUEUE_CHANGED"))
      W.advance(5)
      assert.equals(n + 1, #world.messages("FS_QUEUE_CHANGED"))
    end)
    it("stops listening when disabled", function()
      Q:Disable()
      local n = #world.messages("FS_QUEUE_CHANGED")
      ns.FS:SendMessage("FS_RECIPES_CHANGED"); W.advance(2)
      assert.equals(n, #world.messages("FS_QUEUE_CHANGED"))
    end)
    it("logs a failing handler without turning the module off", function()
      local orig = Q.SendMessage
      Q.SendMessage = function(self, name, ...) if name == "FS_QUEUE_CHANGED" then error("boom") end return orig(self, name, ...) end
      Q:SendMessage("FS_RECIPES_CHANGED"); W.advance(1)
      Q.SendMessage = orig
      assert.is_true(Q:IsEnabled())
      local errors = ns.FS.db.global.diagnostics.errors
      assert.equals("Queue:Recompute", errors[#errors].source)
    end)
  end)
end)
