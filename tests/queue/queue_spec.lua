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
    -- Phase 7 Task 14: sub-crafts go ahead of the entry that needs them.
    it("inserts an entry before another", function()
      local a = Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
      local b = Q:Add({ recipeID = 9001, quantity = 2, charKey = "Main-Realm" })
      local c = Q:Add({ recipeID = 9001, quantity = 3, charKey = "Main-Realm", parentID = b }, { before = b })
      local d = Q:Add({ recipeID = 9001, quantity = 4, charKey = "Main-Realm", parentID = "x" }, { before = 999 })
      local ids = {}
      for i, e in ipairs(Q:GetEntries()) do ids[i] = e.id end
      assert.same({ a, c, b, d }, ids)
      assert.equals(b, Q:GetEntries()[2].parentID)
      assert.is_nil(Q:GetEntries()[4].parentID)            -- not a number: not stored
      assert.is_nil(Q:GetEntries()[1].parentID)
      assert.is_nil(ns.FS.db.global.queue.entries[1].parentID)
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
    it("stores sorted optional IDs on an entry", function()
      local id = Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm", optionalItemIDs = { 7203, 7201, 7203, "x", 7202 } })
      local e = Q:GetEntries()[1]
      assert.same({ 7201, 7202, 7203 }, e.optionalItemIDs)
      e.optionalItemIDs[1] = 1                                  -- a copy
      assert.same({ 7201, 7202, 7203 }, Q:GetEntries()[1].optionalItemIDs)
      assert.same({ 7201, 7202, 7203 }, ns.FS.db.global.queue.entries[1].optionalItemIDs)
      assert.is_number(id)
    end)
    it("stores optional IDs only when there are some, and at most 8", function()
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm", optionalItemIDs = {} })
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm", optionalItemIDs = { "x", false } })
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm", optionalItemIDs = "junk" })
      for i = 1, 3 do assert.is_nil(ns.FS.db.global.queue.entries[i].optionalItemIDs) end
      local ids = {}
      for i = 12, 1, -1 do ids[#ids + 1] = 7200 + i end
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm", optionalItemIDs = ids })
      assert.same({ 7201, 7202, 7203, 7204, 7205, 7206, 7207, 7208 }, ns.FS.db.global.queue.entries[4].optionalItemIDs)
    end)
    it("keeps only positive whole finite item IDs as optionals", function()
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm",
        optionalItemIDs = { -5, 0, 1.5, math.huge, -math.huge, 0 / 0, 7202, 2.0 } })
      assert.same({ 2, 7202 }, ns.FS.db.global.queue.entries[1].optionalItemIDs)
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm", optionalItemIDs = { -5, 0.5, math.huge } })
      assert.is_nil(ns.FS.db.global.queue.entries[2].optionalItemIDs)
    end)
    it("plans an entry with its optionals", function()
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm", optionalItemIDs = { 7202, 7201 }, targetQuality = 2 })
      local opts = Q:CraftEvaluateOpts(Q:GetEntries()[1])
      assert.same({ 7201, 7202 }, opts.optionalItemIDs); assert.equals(2, opts.targetQuality)
      assert.is_nil(Q:CraftEvaluateOpts({ recipeID = 9001, quantity = 1 }).optionalItemIDs)
    end)
    it("counts optional reagents in the missing reagents", function()
      world.fakeEvaluate(9001, function(_, opts)
        local result = { allocation = { {slotIndex=1,itemID=1001,quantity=2} }, reagentCost = 900, flags = {},
          optionalAllocation = {} }
        if opts.optionalItemIDs then result.optionalAllocation = { { slotIndex = 4, itemID = 7201, quantity = 2 } } end
        return result
      end)
      local plain = Q:Add({ recipeID = 9001, quantity = 3, charKey = "Main-Realm" })
      assert.same({ [1001] = 6 }, Q:GetMissingReagents(nil))
      Q:Add({ recipeID = 9001, quantity = 3, charKey = "Main-Realm", optionalItemIDs = { 7201 } })
      assert.same({ [1001] = 12, [7201] = 6 }, Q:GetMissingReagents(nil))
      world.items["Main-Realm"][7201] = { bags = 4, bank = 0, reagentBank = 0 }
      assert.same({ [1001] = 12, [7201] = 2 }, Q:GetMissingReagents("Main-Realm"))
      assert.same({ [1001] = 6 }, Q:GetEntryMissing(plain))
    end)
    it("costs an entry with its optionals", function()
      world.fakeEvaluate(9001, function(_, opts)
        return { allocation = {}, reagentCost = opts.optionalItemIDs and 1100 or 900, flags = {} }
      end)
      local plain = Q:Add({ recipeID = 9001, quantity = 2, charKey = "Main-Realm" })
      local with = Q:Add({ recipeID = 9001, quantity = 2, charKey = "Main-Realm", optionalItemIDs = { 7201 } })
      assert.same({ 1800, 2200 }, { Q:GetEntryCost(plain), Q:GetEntryCost(with) })
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
    it("GetMissingForEntries sums several characters' entries and takes off each one's holdings", function()
      world.items["Main-Realm"][1001] = { bags = 3, bank = 0, reagentBank = 0 }
      local entries = { { recipeID = 9001, quantity = 2, charKey = "Main-Realm" },
        { recipeID = 9001, quantity = 1, charKey = "Alt-Realm" } }
      assert.same({ [1001] = 3, [2002] = 3 }, Q:GetMissingForEntries(entries))   -- 1001: 4 − 3 + 2; 2002: 2 + 1
      world.warband[1001] = 1
      assert.same({ [1001] = 2, [2002] = 3 }, Q:GetMissingForEntries(entries))   -- the warband comes off once
      ns.FS.db.global.settings.crafting = { queueUseWarband = false }
      assert.same({ [1001] = 3, [2002] = 3 }, Q:GetMissingForEntries(entries))
    end)
    it("GetMissingForEntries ignores the queue and skips entries without a recipe, quantity or character", function()
      assert.same({ [1001] = 2, [2002] = 1 }, Q:GetMissingForEntries({ { recipeID = 9001, quantity = 1, charKey = "Main-Realm" },
        { quantity = 1, charKey = "Main-Realm" }, { recipeID = 9001, quantity = 0, charKey = "Main-Realm" },
        { recipeID = 9001, quantity = 1 }, { recipeID = "x", quantity = 1, charKey = "Main-Realm" } }))
      assert.same({}, Q:GetMissingForEntries({})); assert.same({}, Q:GetMissingForEntries(nil))
      assert.equals(1, #Q:GetEntries())   -- the stored entry (Alt, 3 crafts) is not part of it
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

  describe("restock gates and outside stock", function()
    local saleLog
    -- A stand-in SaleLog: GetListedCount answers (count, age); nil = unknown. Its enabled state is the module's.
    local function fake_sale_log(count, age)
      saleLog = ns.FS:NewModule("SaleLog")
      saleLog.calls = 0
      function saleLog:GetListedCount() self.calls = self.calls + 1; return count, age end
      saleLog:Enable()
      return saleLog
    end
    local function mail(items, time)
      ns.FS.db.global.characters["Main-Realm"].mail = { time = time or W.now, items = items }
    end
    local function crafting(settings) ns.FS.db.global.settings.crafting = settings end

    it("gates a restock entry below the min profit", function()
      world.counts[5002] = 12; Q:SetRestock(5002, 20)
      Q:SetRestockMinProfit(5002, 5001)
      assert.same({}, Q:GetEntries())
      Q:SetRestockMinProfit(5002, 5000)                      -- equal passes
      assert.equals(7, Q:GetEntries()[1].quantity)
      Q:SetRestockMinProfit(5002, nil)
      assert.equals(7, Q:GetEntries()[1].quantity)
    end)
    it("judges the gate on the chosen crafter's profit", function()
      world.fakeEvaluate(9001, function(charKey)
        return { allocation = {}, reagentCost = 1, expectedYield = 1, flags = {}, profit = charKey == "Main-Realm" and 900 or 100 }
      end)
      world.counts[5002] = 0; Q:SetRestock(5002, 1)
      Q:SetRestockMinProfit(5002, 900)
      assert.equals("Main-Realm", Q:GetEntries()[1].charKey)
      Q:SetRestockMinProfit(5002, 901)
      assert.same({}, Q:GetEntries())
    end)
    it("makes no entry when the profit is unknown and a gate is set", function()
      world.fakeEvaluate(9001, { allocation = {}, expectedYield = 1, flags = { noPrice = true } })
      world.counts[5002] = 0; Q:SetRestock(5002, 1)
      assert.equals(1, #Q:GetEntries())                      -- no gate: falls back to the first crafter
      Q:SetRestockMinProfit(5002, 0)
      assert.same({}, Q:GetEntries())
    end)
    it("counts mail and own listings as held", function()
      fake_sale_log(2, 60)
      world.counts[5002] = 12; Q:SetRestock(5002, 20)
      mail({ [5002] = 3 })
      assert.equals(3, Q:GetEntries()[1].quantity)           -- 20 - (12 + 3 + 2) = 3 short, yield 1.31 -> 3 crafts
      assert.same({ owned = 12, mail = 3, listed = 2, total = 17, mailAge = 0, listedAge = 60 }, Q:GetRestockStatus(5002).held)
    end)
    it("leaves mail out with restockCountMail off", function()
      fake_sale_log(2, 60)
      world.counts[5002] = 12; Q:SetRestock(5002, 20)
      mail({ [5002] = 3 }); crafting({ restockCountMail = false })
      assert.equals(5, Q:GetEntries()[1].quantity)           -- 20 - (12 + 2) = 6 short -> 5 crafts
      local held = Q:GetRestockStatus(5002).held
      assert.same({ 12, nil, 2, 14 }, { held.owned, held.mail, held.listed, held.total })
    end)
    it("leaves listings out with restockCountListed off", function()
      local sl = fake_sale_log(2, 60)
      world.counts[5002] = 12; Q:SetRestock(5002, 20)
      crafting({ restockCountListed = false })
      assert.equals(7, Q:GetEntries()[1].quantity)
      assert.is_nil(Q:GetRestockStatus(5002).held.listed); assert.equals(0, sl.calls)
    end)
    it("leaves listings out while SaleLog is off", function()
      local sl = fake_sale_log(2, 60)
      world.counts[5002] = 12; Q:SetRestock(5002, 20)
      sl:Disable()
      assert.equals(7, Q:GetEntries()[1].quantity)
      assert.is_nil(Q:GetRestockStatus(5002).held.listed); assert.equals(0, sl.calls)
    end)
    it("leaves listings out when there is no SaleLog module", function()
      world.counts[5002] = 12; Q:SetRestock(5002, 20)
      assert.equals(7, Q:GetEntries()[1].quantity)
      assert.is_nil(Q:GetRestockStatus(5002).held.listed)
    end)
    it("keeps an unknown outside count unknown instead of showing it as none", function()
      fake_sale_log(nil, nil)                                -- SaleLog on, no listing snapshot
      world.counts[5002] = 12; Q:SetRestock(5002, 20)        -- no mail snapshot either
      local held = Q:GetRestockStatus(5002).held
      assert.same({ nil, nil, true, true, 12 }, { held.mail, held.listed, held.mailUnknown, held.listedUnknown, held.total })
      assert.equals(7, Q:GetEntries()[1].quantity)           -- decided on what is known
      mail({})                                               -- a snapshot that holds none: a known zero
      held = Q:GetRestockStatus(5002).held
      assert.same({ 0, true }, { held.mail, held.listedUnknown }); assert.is_nil(held.mailUnknown)
    end)
    it("GetRestockStatus explains each case", function()
      assert.is_nil(Q:GetRestockStatus(5002))                -- no target
      world.counts[5002] = 12; Q:SetRestock(5002, 20)
      local s = Q:GetRestockStatus(5002)
      assert.same({ "queued", 7, 20, 5000, "Alt-Realm" }, { s.status, s.crafts, s.target, s.profit, s.crafter })
      assert.same({ 12, 12 }, { s.held.owned, s.held.total }); assert.is_nil(s.minProfit)
      assert.equals(5002, s.itemID)
      world.counts[5002] = 20
      assert.equals("stocked", Q:GetRestockStatus(5002).status)
      world.counts[5002] = 12
      Q:SetRestockMinProfit(5002, 6000)
      s = Q:GetRestockStatus(5002)
      assert.same({ "belowMinProfit", 6000, 5000 }, { s.status, s.minProfit, s.profit })
      world.fakeEvaluate(9001, { allocation = {}, expectedYield = 1, flags = { noPrice = true } })
      s = Q:GetRestockStatus(5002)
      assert.equals("unknownProfit", s.status); assert.is_nil(s.profit)
      world.fakeEvaluate(9001, { allocation = {}, reagentCost = 1, expectedYield = 1, profit = 9, flags = { unreachableTarget = true } })
      assert.equals("noCrafter", Q:GetRestockStatus(5002).status)
      world.counts[9999] = 0; Q:SetRestock(9999, 5)
      assert.equals("noRecipe", Q:GetRestockStatus(9999).status)
    end)
    it("agrees with GetEntries on every gate", function()
      world.counts[5002] = 12; Q:SetRestock(5002, 20)
      for _, minProfit in ipairs({ 0, 5000, 5001 }) do
        Q:SetRestockMinProfit(5002, minProfit)
        local s = Q:GetRestockStatus(5002)
        local e = Q:GetEntries()[1]
        assert.equals(s.status == "queued", e ~= nil)
        if e then assert.equals(s.crafts, e.quantity) end
      end
    end)
    it("counts crafts already queued against the shortfall in the status", function()
      world.counts[5002] = 12; Q:SetRestock(5002, 20)
      Q:Add({ recipeID = 9001, quantity = 7, charKey = "Main-Realm", targetQuality = 2 })
      assert.equals("stocked", Q:GetRestockStatus(5002).status)
    end)
    it("floors the min profit and ignores a bad one", function()
      Q:SetRestock(5002, 20)
      Q:SetRestockMinProfit(5002, 1234.9)
      assert.equals(1234, Q:GetRestockMinProfit(5002))
      Q:SetRestockMinProfit(5002, -1); Q:SetRestockMinProfit(5002, "9"); Q:SetRestockMinProfit(5002, 0 / 0)
      Q:SetRestockMinProfit(5002, math.huge)
      assert.equals(1234, Q:GetRestockMinProfit(5002))
      Q:SetRestockMinProfit(5002, 0); assert.equals(0, Q:GetRestockMinProfit(5002))
      Q:SetRestockMinProfit("x", 5); assert.is_nil(Q:GetRestockMinProfit("x"))
      Q:SetRestockMinProfit(5002, nil); assert.is_nil(Q:GetRestockMinProfit(5002))
    end)
    it("announces a min profit change once, and nothing for a no-op", function()
      Q:SetRestock(5002, 20)
      local n = #world.messages("FS_QUEUE_CHANGED")
      Q:SetRestockMinProfit(5002, 100); Q:SetRestockMinProfit(5002, 100); Q:SetRestockMinProfit(5002, nil)
      Q:SetRestockMinProfit(5002, nil); Q:SetRestockMinProfit(5002, -5)
      assert.equals(n + 2, #world.messages("FS_QUEUE_CHANGED"))
    end)
    it("SetRestock nil clears the min profit", function()
      Q:SetRestock(5002, 20); Q:SetRestockMinProfit(5002, 100)
      Q:SetRestock(5002, nil)
      assert.is_nil(Q:GetRestockMinProfit(5002))
      assert.same({}, ns.FS.db.global.queue.restockMinProfit)
      Q:SetRestock(5002, 20)
      assert.is_nil(Q:GetRestockMinProfit(5002))
    end)
    it("recomputes when the sale log changes", function()
      local n = #world.messages("FS_QUEUE_CHANGED")
      Q:SendMessage("FS_SALELOG_CHANGED")
      W.advance(0.6)
      assert.equals(n + 1, #world.messages("FS_QUEUE_CHANGED"))
    end)
    it("writes nothing while the saved data is from a newer version", function()
      Q:SetRestock(5002, 20); Q:SetRestockMinProfit(5002, 50)
      local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
      ns.FS.dbIsNewer = true
      Q:SetRestockMinProfit(5002, 100); Q:SetRestockMinProfit(5002, nil)
      Q:SetRestock(5002, nil)
      assert.same(before, ns.Util.DeepCopy(ns.FS.db.global, 30))
      assert.equals(50, Q:GetRestockMinProfit(5002))
    end)
    it("reads a damaged min profit table without repairing it", function()
      local g = ns.FS.db.global
      g.queue = { entries = {}, restock = { [5002] = 3 }, restockMinProfit = "future" }
      ns.FS.dbIsNewer = true
      world.counts[5002] = 0
      assert.is_nil(Q:GetRestockMinProfit(5002))
      assert.equals(1, #Q:GetEntries())
      assert.equals("future", g.queue.restockMinProfit)
    end)
  end)

  describe("entry results", function()
    it("returns the evaluation the cost comes from, nil for an unknown entry", function()
      local id = Q:Add({ recipeID = 9001, quantity = 3, charKey = "Alt-Realm", targetQuality = 2 })
      local r = Q:GetEntryResult(id)
      assert.equals(900, r.reagentCost)
      local last = world.evaluated[#world.evaluated]
      assert.same({ "Alt-Realm", 2 }, { last.charKey, last.opts.targetQuality })
      assert.is_nil(Q:GetEntryResult(12345))
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

  -- Phase 7 follow-up F2 (review M3): a sub-craft exists only for its parent, so it goes with the parent.
  describe("sub-crafts go with their parent", function()
    local ME = "Main-Realm"
    -- parent <- child <- grandchild, plus a separately queued entry of the same recipe (no parentID) and one other.
    local function tree(opts)
      opts = opts or {}
      local own = Q:Add({ recipeID = 9001, quantity = 1, charKey = ME })
      local parent = Q:Add({ recipeID = 9001, quantity = 2, charKey = ME, orderID = opts.orderID })
      local child = Q:Add({ recipeID = 9001, quantity = 3, charKey = ME, parentID = parent }, { before = parent })
      local grand = Q:Add({ recipeID = 9001, quantity = 6, charKey = ME, parentID = child }, { before = child })
      local other = Q:Add({ recipeID = 9001, quantity = 4, charKey = "Alt-Realm" })
      return { own = own, parent = parent, child = child, grand = grand, other = other }
    end
    local function ids()
      local out = {}
      for i, e in ipairs(Q:GetEntries()) do out[i] = e.id end
      return out
    end
    local function chat() return table.concat(W.printed, "\n") end

    it("removes the children and grandchildren with the parent and says how many", function()
      local t = tree()
      local n = #world.messages("FS_QUEUE_CHANGED")
      Q:Remove(t.parent)
      assert.same({ t.own, t.other }, ids())
      assert.equals(n + 1, #world.messages("FS_QUEUE_CHANGED"))
      assert.is_truthy(chat():find("Also removed 2 sub-crafts", 1, true))
    end)
    it("says 'sub-craft' for one child", function()
      local parent = Q:Add({ recipeID = 9001, quantity = 2, charKey = ME })
      Q:Add({ recipeID = 9001, quantity = 3, charKey = ME, parentID = parent }, { before = parent })
      Q:Remove(parent)
      assert.equals(0, #Q:GetEntries())
      assert.is_truthy(chat():find("Also removed 1 sub-craft", 1, true))
      assert.is_falsy(chat():find("sub-crafts", 1, true))
    end)
    it("takes a sub-craft's own sub-crafts with it but never its parent", function()
      local t = tree()
      Q:Remove(t.child)
      assert.same({ t.own, t.parent, t.other }, ids())     -- its own child goes with it
      assert.is_truthy(chat():find("Also removed 1 sub-craft", 1, true))
      W.printed = {}
      Q:Remove(t.parent)
      assert.same({ t.own, t.other }, ids())
      assert.equals("", chat())
    end)
    it("keeps an entry queued on its own, even of the same recipe, and says nothing when no child goes", function()
      local own = Q:Add({ recipeID = 9001, quantity = 1, charKey = ME })
      local same = Q:Add({ recipeID = 9001, quantity = 1, charKey = ME })
      Q:Remove(same)
      assert.same({ own }, ids())
      assert.equals("", chat())
    end)
    it("removes the children when filling the parent's order removes the parent", function()
      local t = tree({ orderID = 777 })
      local n = #world.messages("FS_QUEUE_CHANGED")
      ns.FS:SendMessage("FS_ORDER_FULFILLED", { orderID = 777 })
      assert.same({ t.own, t.other }, ids())
      assert.equals(n + 1, #world.messages("FS_QUEUE_CHANGED"))
      assert.is_truthy(chat():find("Also removed 2 sub-crafts", 1, true))
      W.fire("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 0, 777)            -- the second trigger finds nothing
      assert.same({ t.own, t.other }, ids())
    end)
    -- Damaged or newer saves: a parentID cycle and a parentID that points at nothing must not hang or raise.
    it("terminates on a parentID cycle and removes only the entries that hang on the removed one", function()
      local entries = ns.FS.db.global.queue.entries
      entries[1] = { id = 1, recipeID = 9001, quantity = 1, charKey = ME, parentID = 2 }   -- 1 -> 2 -> 1
      entries[2] = { id = 2, recipeID = 9001, quantity = 1, charKey = ME, parentID = 1 }
      entries[3] = { id = 3, recipeID = 9001, quantity = 1, charKey = ME }
      entries[4] = { id = 4, recipeID = 9001, quantity = 1, charKey = ME, parentID = 4 }   -- its own parent
      ns.FS.db.global.queue.nextID = 5
      assert.has_no.errors(function() Q:Remove(1) end)
      assert.same({ 3, 4 }, ids())
      assert.is_truthy(chat():find("Also removed 1 sub-craft", 1, true))
      assert.has_no.errors(function() Q:Remove(4) end)
      assert.same({ 3 }, ids())
    end)
    it("treats a parentID that points at no entry as an ordinary entry", function()
      local own = Q:Add({ recipeID = 9001, quantity = 1, charKey = ME })
      local orphan = ns.FS.db.global.queue.nextID
      ns.FS.db.global.queue.entries[2] = { id = orphan, recipeID = 9001, quantity = 1, charKey = ME, parentID = 999 }
      ns.FS.db.global.queue.nextID = orphan + 1
      assert.has_no.errors(function() Q:Remove(own) end)
      assert.same({ orphan }, ids())                       -- not removed with an unrelated entry
      assert.equals("", chat())
      assert.has_no.errors(function() Q:Remove(orphan) end)
      assert.same({}, ids())
      assert.equals("", chat())
    end)
    it("changes nothing while the saved data is from a newer version", function()
      local t = tree({ orderID = 777 })
      ns.FS.dbIsNewer = true
      local n = #world.messages("FS_QUEUE_CHANGED")
      Q:Remove(t.parent)
      ns.FS:SendMessage("FS_ORDER_FULFILLED", { orderID = 777 })
      assert.same({ t.own, t.grand, t.child, t.parent, t.other }, ids())
      assert.equals(n, #world.messages("FS_QUEUE_CHANGED"))
      assert.equals("", chat())
    end)
  end)

  describe("fulfilled crafting orders", function()
    it("removes the fulfilled order's entries only, with one FS_QUEUE_CHANGED", function()
      local plain = Q:Add({ recipeID = 9001, quantity = 2, charKey = "Main-Realm" })
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm", orderID = 777 })
      local other = Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm", orderID = 778 })
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Alt-Realm", orderID = 777 })
      local n = #world.messages("FS_QUEUE_CHANGED")
      ns.FS:SendMessage("FS_ORDER_FULFILLED", { orderID = 777, recipeID = 9001, time = W.now })
      local ids = {}
      for i, e in ipairs(Q:GetEntries()) do ids[i] = e.id end
      assert.same({ plain, other }, ids)
      assert.equals(n + 1, #world.messages("FS_QUEUE_CHANGED"))
    end)
    it("sends nothing when no entry belongs to the order, or the message is malformed", function()
      Q:Add({ recipeID = 9001, quantity = 2, charKey = "Main-Realm" })
      local n = #world.messages("FS_QUEUE_CHANGED")
      ns.FS:SendMessage("FS_ORDER_FULFILLED", { orderID = 1 })
      ns.FS:SendMessage("FS_ORDER_FULFILLED", nil)
      ns.FS:SendMessage("FS_ORDER_FULFILLED", { orderID = nil })
      assert.equals(1, #Q:GetEntries()); assert.equals(n, #world.messages("FS_QUEUE_CHANGED"))
    end)
    it("writes nothing while the saved data is from a newer version", function()
      Q:Add({ recipeID = 9001, quantity = 2, charKey = "Main-Realm" })
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm", orderID = 777 })
      ns.FS.dbIsNewer = true
      local n = #world.messages("FS_QUEUE_CHANGED")
      ns.FS:SendMessage("FS_ORDER_FULFILLED", { orderID = 777 })
      local entries = ns.FS.db.global.queue.entries
      assert.equals(2, #entries); assert.equals(777, entries[2].orderID)
      assert.equals(n, #world.messages("FS_QUEUE_CHANGED"))
    end)
    it("stops listening when disabled", function()
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm", orderID = 777 })
      Q:Disable()
      ns.FS:SendMessage("FS_ORDER_FULFILLED", { orderID = 777 })
      assert.equals(1, #ns.FS.db.global.queue.entries)
    end)

    describe("on Blizzard's CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", function()
      local function two_entries()
        local plain = Q:Add({ recipeID = 9001, quantity = 2, charKey = "Main-Realm" })
        Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm", orderID = 777 })
        Q:Add({ recipeID = 9001, quantity = 1, charKey = "Alt-Realm", orderID = 777 })
        return plain
      end
      it("removes the order's entries on Ok, with one FS_QUEUE_CHANGED", function()
        local plain = two_entries()
        local n = #world.messages("FS_QUEUE_CHANGED")
        W.fire("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 0, 777)
        assert.same({ plain }, { Q:GetEntries()[1].id }); assert.equals(1, #Q:GetEntries())
        assert.equals(n + 1, #world.messages("FS_QUEUE_CHANGED"))
      end)
      it("does nothing for a result other than Ok", function()
        two_entries()
        local n = #world.messages("FS_QUEUE_CHANGED")
        W.fire("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 10, 777)
        W.fire("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", nil, 777)
        assert.equals(3, #Q:GetEntries()); assert.equals(n, #world.messages("FS_QUEUE_CHANGED"))
      end)
      it("sends nothing for an order without entries, or without an orderID", function()
        two_entries()
        local n = #world.messages("FS_QUEUE_CHANGED")
        W.fire("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 0, 5)
        W.fire("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 0, nil)
        assert.equals(3, #Q:GetEntries()); assert.equals(n, #world.messages("FS_QUEUE_CHANGED"))
      end)
      it("is idempotent with FS_ORDER_FULFILLED, in either order", function()
        two_entries()
        local n = #world.messages("FS_QUEUE_CHANGED")
        ns.FS:SendMessage("FS_ORDER_FULFILLED", { orderID = 777 })
        W.fire("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 0, 777)
        assert.equals(1, #Q:GetEntries()); assert.equals(n + 1, #world.messages("FS_QUEUE_CHANGED"))
        Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm", orderID = 778 })
        n = #world.messages("FS_QUEUE_CHANGED")
        W.fire("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 0, 778)
        ns.FS:SendMessage("FS_ORDER_FULFILLED", { orderID = 778 })
        assert.equals(1, #Q:GetEntries()); assert.equals(n + 1, #world.messages("FS_QUEUE_CHANGED"))
      end)
      it("still removes without the Orders module (not loaded here, as when it is off: no FS_ORDER_FULFILLED is sent)", function()
        assert.is_nil(ns.FS:GetModule("Orders", true))
        two_entries()
        W.fire("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 0, 777)
        assert.equals(1, #Q:GetEntries())
      end)
      it("writes nothing while the saved data is from a newer version", function()
        two_entries()
        ns.FS.dbIsNewer = true
        local n = #world.messages("FS_QUEUE_CHANGED")
        W.fire("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 0, 777)
        assert.equals(3, #ns.FS.db.global.queue.entries); assert.equals(n, #world.messages("FS_QUEUE_CHANGED"))
      end)
      it("stops listening when disabled", function()
        two_entries()
        Q:Disable()
        W.fire("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 0, 777)
        assert.equals(3, #ns.FS.db.global.queue.entries)
      end)
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
    it("recomputes after a cooldowns change (the queue shows cooldowns)", function()
      local n = #world.messages("FS_QUEUE_CHANGED")
      Q:SendMessage("FS_DATA_CHANGED", "Main-Realm", "cooldowns")
      W.advance(0.6)
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
