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

  it("is a core module", function() assert.is_true(ns.FS:GetModule("QueueCraft").coreModule) end)

  describe("shopping list", function()
    before_each(function()
      world.names[1001], world.names[2002], world.names[3001] = "Bright Ore", "Glimmer Dust", "Flux"
    end)
    it("hands the converted search strings to Auctionator under the FabricationStation caller ID", function()
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
      local ok, info = Q:ExportShoppingList()
      assert.is_true(ok); assert.same({ added = 2, skipped = 0 }, info)
      assert.same({ '"Bright Ore"', '"Glimmer Dust"' }, W.auctionator.lists.FabricationStation)
      assert.equals("FabricationStation", W.auctionator.lastCallerID)
    end)
    it("sums every character's shortfall, sorted by item ID", function()
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Alt-Realm" })
      Q:Add({ recipeID = 9001, quantity = 2, charKey = "Main-Realm" })
      world.items["Main-Realm"][1001] = { bags = 1, bank = 0, reagentBank = 0 }
      Q:ExportShoppingList()
      assert.same({ 5, 3 }, { api.terms[1].quantity, api.terms[2].quantity })
      assert.same({ "Bright Ore", "Glimmer Dust" }, { api.terms[1].searchString, api.terms[2].searchString })
    end)
    it("leaves out the tier for a single-reagent slot", function()
      world.fakeEvaluate(9001, { allocation = { {slotIndex=3,itemID=3001,quantity=2} }, reagentCost = 1000, flags = {} })
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
      Q:ExportShoppingList()
      assert.same({ searchString = "Flux", isExact = true, quantity = 2 }, api.terms[1])
    end)
    it("is empty when nothing is missing", function()
      assert.same({ false, "empty" }, { Q:ExportShoppingList() })
      world.haveAll("Main-Realm"); Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
      assert.same({ false, "empty" }, { Q:ExportShoppingList() })
      assert.equals(0, #api.lists)
    end)
    it("creates no list when every name is still loading", function()
      world.names[1001], world.names[2002] = nil, nil
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
      local ok, info = Q:ExportShoppingList()
      assert.is_true(ok); assert.same({ added = 0, skipped = 2 }, info)
      assert.equals(0, #api.lists); assert.same({ 1001, 2002 }, world.loadRequests)
    end)
    it("reports an Auctionator failure and logs it", function()
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
      _G.Auctionator.API.v1.CreateShoppingList = function() error("list boom") end
      assert.same({ false, "auctionatorError" }, { Q:ExportShoppingList() })
      local errors = ns.FS.db.global.diagnostics.errors
      assert.equals("Queue:ShoppingList", errors[#errors].source)
      _G.Auctionator.API.v1.ConvertToSearchString = function() error("convert boom") end
      assert.same({ false, "auctionatorError" }, { Q:ExportShoppingList() })
    end)
    it("treats an Auctionator without the shopping list API as missing", function()
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
      _G.Auctionator.API.v1.CreateShoppingList = nil
      assert.same({ false, "noAuctionator" }, { Q:ExportShoppingList() })
    end)
  end)

  describe("cooldowns", function()
    local entry
    before_each(function() entry = { recipeID = 9001, quantity = 1, charKey = "Main-Realm" } end)
    it("is ready without a record, once readyAt has passed, or with a charge left", function()
      assert.is_nil(Q:GetCooldownReadyAt(entry))
      world.cooldown("Main-Realm", 9001, W.now + 60)
      assert.equals(W.now + 60, Q:GetCooldownReadyAt(entry))
      assert.is_nil(Q:GetCooldownReadyAt({ recipeID = 9001, quantity = 1, charKey = "Alt-Realm" }))
      world.cooldown("Main-Realm", 9001, W.now + 60, 1)
      assert.is_nil(Q:GetCooldownReadyAt(entry))
      world.cooldown("Main-Realm", 9001, W.now)
      assert.is_nil(Q:GetCooldownReadyAt(entry))
    end)
    it("is ready for a recipe without a schematic", function()
      world.cooldown("Main-Realm", 9001, W.now + 60)
      world.schematics[9001] = nil
      assert.is_nil(Q:GetCooldownReadyAt(entry))
    end)
  end)

  describe("Craft Next", function()
    before_each(function() world.openProfession(2906) end)
    it("passes the Blizzard reagent table, the order and concentration off", function()
      world.haveAll("Main-Realm")
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm", orderID = 42 })
      Q:CraftNext()
      local c = world.crafts[1]
      assert.same({ { reagent = { itemID = 1001 }, dataSlotIndex = 11, quantity = 2 },
        { reagent = { itemID = 2002 }, dataSlotIndex = 12, quantity = 1 } }, c[3])
      assert.equals(42, c[5]); assert.is_false(c[6]); assert.equals(6, c.n)
    end)
    it("checks the open profession through the recipe's profession ID", function()
      world.openProfession(1234); world.haveAll("Main-Realm")
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
      assert.equals("open", Q:CraftNext().status); assert.equals(0, #world.crafts)
      _G.C_TradeSkillUI.GetProfessionInfoByRecipeID = function() return { professionID = 1234 } end
      assert.equals("crafted", Q:CraftNext().status)
    end)
    it("skips entries on cooldown and crafts the next one", function()
      world.haveAll("Main-Realm"); world.cooldown("Main-Realm", 9002, W.now + 60)
      local schematic = {}
      for k, v in pairs(world.schematics[9001]) do schematic[k] = v end
      schematic.recipeID = 9002; world.schematics[9002] = schematic
      world.fakeEvaluate(9002, { allocation = {}, reagentCost = 0, flags = {} })
      Q:Add({ recipeID = 9002, quantity = 1, charKey = "Main-Realm" })
      local id = Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
      local r = Q:CraftNext()
      assert.same({ "crafted", id }, { r.status, r.entryID }); assert.equals(9001, world.crafts[1][1])
    end)
    it("reports the first blocker in queue order", function()
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Alt-Realm" })
      local id = Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
      assert.same({ "open", "Alt-Realm" }, { Q:CraftNext().status, Q:CraftNext().charKey })
      Q:Clear()
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Alt-Realm" })
      local r = Q:CraftNext()
      assert.equals("missing", r.status); assert.same({ [1001] = 2, [2002] = 1 }, r.missing)
      assert.equals("Main-Realm", r.charKey); assert.are_not.equal(id, r.entryID)
    end)
    it("reports the earliest cooldown when every entry waits", function()
      world.cooldown("Main-Realm", 9001, W.now + 600); world.cooldown("Alt-Realm", 9001, W.now + 60)
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
      local alt = Q:Add({ recipeID = 9001, quantity = 1, charKey = "Alt-Realm" })
      local r = Q:CraftNext()
      assert.same({ "cooldown", W.now + 60, alt, "Alt-Realm" }, { r.status, r.readyAt, r.entryID, r.charKey })
    end)
    it("counts a crafting order's provided reagents and, when enabled, the warband", function()
      world.items["Main-Realm"][2002] = { bags = 1, bank = 0, reagentBank = 0 }
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm", providedReagents = { [1001] = 2 } })
      assert.equals("crafted", Q:CraftNext().status)
      Q:Clear()
      world.items["Main-Realm"][2002] = nil; world.warband[1001], world.warband[2002] = 2, 1
      Q:Add({ recipeID = 9001, quantity = 2, charKey = "Main-Realm" })
      assert.equals("crafted", Q:CraftNext().status)
      W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", { itemID = 5002, operationID = 1 })
      ns.FS.db.global.settings.crafting = { queueUseWarband = false }
      assert.equals("missing", Q:CraftNext().status)
    end)
    it("reports an entry whose recipe cannot be evaluated as missing", function()
      world.fakeEvaluate(9001, function() return nil end)
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
      local r = Q:CraftNext()
      assert.equals("missing", r.status); assert.same({}, r.missing); assert.equals(0, #world.crafts)
    end)
    it("decrements once per operation, removes at zero, ignores other items", function()
      world.haveAll("Main-Realm")
      local id = Q:Add({ recipeID = 9001, quantity = 2, charKey = "Main-Realm" })
      W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", { itemID = 5002, operationID = 1 })        -- nothing pending
      assert.equals(2, Q:GetEntries()[1].quantity)
      Q:CraftNext()
      W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", { itemID = 7777, operationID = 2 })
      assert.equals(2, Q:GetEntries()[1].quantity)
      W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", { itemID = 5001, operationID = 3 })
      assert.equals(1, Q:GetEntries()[1].quantity)
      assert.equals("crafted", Q:CraftNext().status)
      W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", { itemID = 5002, operationID = 3 })        -- already counted
      assert.equals(1, Q:GetEntries()[1].quantity)
      W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", { itemID = 5002, operationID = 4 })
      assert.equals(0, #Q:GetEntries())
      W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", { itemID = 5002, operationID = 5 })
      assert.equals(0, #Q:GetEntries()); assert.is_number(id)
    end)
    it("crafts a stocked entry of this character behind another character's entry", function()
      world.haveAll("Main-Realm")
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Alt-Realm" })
      local main = Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
      local r = Q:CraftNext()
      assert.same({ "crafted", main }, { r.status, r.entryID }); assert.equals(1, #world.crafts)
    end)
    it("crafts a later entry when an earlier one of this character misses reagents", function()
      world.fakeEvaluate(9002, { allocation = {}, reagentCost = 0, flags = {} })
      local schematic = {}
      for k, v in pairs(world.schematics[9001]) do schematic[k] = v end
      schematic.recipeID = 9002; world.schematics[9002] = schematic
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
      local free = Q:Add({ recipeID = 9002, quantity = 1, charKey = "Main-Realm" })
      local r = Q:CraftNext()
      assert.same({ "crafted", free }, { r.status, r.entryID }); assert.equals(9002, world.crafts[1][1])
    end)
  end)

  describe("pending craft", function()
    local id
    before_each(function()
      world.openProfession(2906); world.haveAll("Main-Realm")
      id = Q:Add({ recipeID = 9001, quantity = 2, charKey = "Main-Realm" })
      assert.equals("crafted", Q:CraftNext().status)
    end)
    it("answers busy to a second click while the craft is pending", function()
      local r = Q:CraftNext()
      assert.same({ "busy", id }, { r.status, r.entryID }); assert.equals(1, #world.crafts)
      W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", { itemID = 5002, operationID = 1 })
      assert.equals("crafted", Q:CraftNext().status); assert.equals(2, #world.crafts)
    end)
    it("is cleared by an interrupted or failed cast of the player", function()
      W.fire("UNIT_SPELLCAST_INTERRUPTED", "target", "Cast-1", 9001)
      W.fire("UNIT_SPELLCAST_INTERRUPTED", "player", "Cast-1", 12345)
      assert.equals("busy", Q:CraftNext().status)
      W.fire("UNIT_SPELLCAST_INTERRUPTED", "player", "Cast-1", 9001)
      W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", { itemID = 5002, operationID = 1 })     -- nothing pending any more
      assert.equals(2, Q:GetEntries()[1].quantity)
      assert.equals("crafted", Q:CraftNext().status)
      W.fire("UNIT_SPELLCAST_FAILED", "player", "Cast-2", 9001)
      assert.equals("crafted", Q:CraftNext().status); assert.equals(3, #world.crafts)
    end)
    it("is forgotten after 30 seconds", function()
      W.advance(29); assert.equals("busy", Q:CraftNext().status)
      W.advance(2); assert.equals("crafted", Q:CraftNext().status)
    end)
    it("is dropped when its entry is removed, so it cannot take the next entry's result", function()
      Q:Remove(id)
      local b = Q:Add({ recipeID = 9001, quantity = 2, charKey = "Main-Realm" })
      local r = Q:CraftNext()
      assert.same({ "crafted", b }, { r.status, r.entryID })
      W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", { itemID = 5002, operationID = 1 })
      assert.equals(1, Q:GetEntries()[1].quantity)
    end)
    it("ignores a succeeded cast of a recipe that makes an item", function()
      W.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 9001)
      assert.equals(2, Q:GetEntries()[1].quantity); assert.equals("busy", Q:CraftNext().status)
    end)
  end)

  describe("recipe without an output item", function()
    it("counts the player's succeeded cast of the recipe as the finished craft", function()
      world.openProfession(2906); world.haveAll("Main-Realm")
      world.schematics[9001].outputItemIDs = {}
      local id = Q:Add({ recipeID = 9001, quantity = 2, charKey = "Main-Realm" })
      Q:CraftNext()
      W.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 777)
      W.fire("UNIT_SPELLCAST_SUCCEEDED", "party1", "Cast-1", 9001)
      assert.equals(2, Q:GetEntries()[1].quantity)
      W.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 9001)
      assert.same({ id, 1 }, { Q:GetEntries()[1].id, Q:GetEntries()[1].quantity })
      assert.equals("crafted", Q:CraftNext().status)
    end)
  end)

  describe("restock of a quality nobody reaches, real evaluation", function()
    it("crafts nothing: no restock entry, so Craft Next never loops on the lower quality", function()
      ns, W, world = make_world({ last = "Modules/QueueCraft.lua" })
      Q = ns.FS:GetModule("Queue")
      for _, k in ipairs({ "Main-Realm", "Alt-Realm" }) do world.chars[k].professions[2906].skill = 100 end
      world.openProfession(2906); world.haveAll("Main-Realm")
      Q:SetRestock(5002, 5)
      assert.same({}, Q:GetEntries())
      assert.equals("empty", Q:CraftNext().status); assert.equals(0, #world.crafts)
    end)
  end)

  describe("held reagents, real evaluation", function()
    before_each(function()
      ns, W, world = make_world({ last = "Modules/QueueCraft.lua", calibrate = { ["Main-Realm"] = { 9001 } } })
      Q = ns.FS:GetModule("Queue")
      world.openProfession(2906)
      -- Only top-rank reagents held. At market prices the cheapest quality-2 mix also buys 3 × 1001 and 1 × 2001.
      local items = world.items["Main-Realm"]
      items[1002] = { bags = 10, bank = 0, reagentBank = 0 }
      items[2002] = { bags = 5, bank = 0, reagentBank = 0 }
      items[3001] = { bags = 2, bank = 0, reagentBank = 0 }
    end)
    it("crafts with the reagents held instead of reporting the market mix as missing", function()
      local market = ns.FS:GetModule("Recipes"):Evaluate(9001, "Main-Realm", { targetQuality = 2 })
      local usesLow = false
      for _, row in ipairs(market.allocation) do if row.itemID == 1001 or row.itemID == 2001 then usesLow = true end end
      assert.is_true(usesLow)
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm", targetQuality = 2 })
      local r = Q:CraftNext()
      assert.equals("crafted", r.status)
      assert.same({ { reagent = { itemID = 1002 }, dataSlotIndex = 11, quantity = 10 },
        { reagent = { itemID = 2002 }, dataSlotIndex = 12, quantity = 5 } }, world.crafts[1][3])
    end)
    it("puts nothing on the shopping list that the held reagents cover", function()
      local id = Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm", targetQuality = 2 })
      assert.same({}, Q:GetEntryMissing(id)); assert.same({}, Q:GetMissingReagents(nil))
    end)
    it("still costs the entry at market prices unless owned reagents are free", function()
      local id = Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm", targetQuality = 2 })
      assert.equals(4800, Q:GetEntryCost(id))
    end)
  end)

  describe("required modifying reagents (sparks), real evaluation", function()
    before_each(function()
      ns, W, world = make_world({ last = "Modules/QueueCraft.lua", calibrate = { ["Main-Realm"] = { 9001 } } })
      Q = ns.FS:GetModule("Queue")
      api = world.recordAuctionatorTerms()
      table.insert(world.schematics[9001].reagentSlots, { slotIndex = 4, required = true, quantity = 1, reagents = { 7101 },
        kind = "optional", dataSlotIndex = 14, dataSlotType = 2 })
      world.prices[7101] = { value = 4000, source = "auction", ageDays = 1 }
      world.openProfession(2906)
    end)
    it("sends the spark to CraftRecipe", function()
      world.haveAll("Main-Realm")
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
      assert.equals("crafted", Q:CraftNext().status)
      local infos = world.crafts[1][3]
      assert.same({ reagent = { itemID = 7101 }, dataSlotIndex = 14, quantity = 1 }, infos[#infos])
    end)
    it("reports a missing spark and puts it on the shopping list", function()
      world.haveAll("Main-Realm"); world.items["Main-Realm"][7101] = nil
      world.names[7101] = "Spark"
      Q:Add({ recipeID = 9001, quantity = 2, charKey = "Main-Realm" })
      local r = Q:CraftNext()
      assert.equals("missing", r.status); assert.same({ [7101] = 1 }, r.missing)
      assert.is_true((Q:ExportShoppingList()))
      assert.same({ searchString = "Spark", isExact = true, quantity = 2 }, api.terms[#api.terms])
    end)
    it("gives no Auctionator tier to a spark slot offering two or more items", function()
      world.schematics[9001].reagentSlots[4].reagents = { 7101, 7102 }
      world.prices[7102] = { value = 9000, source = "auction", ageDays = 1 }
      world.haveAll("Main-Realm"); world.items["Main-Realm"][7101], world.items["Main-Realm"][7102] = nil, nil
      world.names[7101] = "Spark"
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
      assert.is_true((Q:ExportShoppingList()))
      assert.same({ searchString = "Spark", isExact = true, quantity = 1 }, api.terms[#api.terms])
    end)
  end)

  -- Phase 2 Task 0 (N2): with queueUseWarband off, the plan must not rely on warband reagents Craft Next won't count.
  describe("warband reagents with queueUseWarband off, real evaluation", function()
    before_each(function()
      ns, W, world = make_world({ last = "Modules/QueueCraft.lua", calibrate = { ["Main-Realm"] = { 9001 } } })
      Q = ns.FS:GetModule("Queue")
      api = world.recordAuctionatorTerms()
      local bags = world.items["Main-Realm"]
      for itemID, n in pairs({ [1001] = 10, [1002] = 7, [2001] = 5, [2002] = 5, [3001] = 2 }) do
        bags[itemID] = { bags = n, bank = 0, reagentBank = 0 }
      end
      world.warband[1002] = 10                      -- enough top-rank ore for a plan that uses only it
      ns.FS.db.global.settings.crafting = { queueUseWarband = false }
      world.openProfession(2906)
    end)
    it("Craft Next plans with the character's own reagents and crafts", function()
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm", targetQuality = 2 })
      local r = Q:CraftNext()
      assert.same({}, r.missing or {})
      assert.equals("crafted", r.status)
      for _, info in ipairs(world.crafts[1][3]) do
        if info.reagent.itemID == 1002 then assert.is_true(info.quantity <= 7) end
      end
    end)
    it("the missing reagents and the shopping list do not plan on the warband", function()
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm", targetQuality = 2 })
      assert.same({}, Q:GetMissingReagents(nil))
      assert.same({ false, "empty" }, { Q:ExportShoppingList() })
    end)
    it("still plans on the warband when queueUseWarband is on", function()
      ns.FS.db.global.settings.crafting = { queueUseWarband = true }
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm", targetQuality = 2 })
      assert.equals("crafted", Q:CraftNext().status)
      local used = 0
      for _, info in ipairs(world.crafts[1][3]) do if info.reagent.itemID == 1002 then used = info.quantity end end
      assert.equals(10, used)                       -- the free warband ore covers the whole slot
    end)
  end)

  describe("Craft Next results", function()
    before_each(function() world.openProfession(2906) end)
    it("does not decrement restock entries", function()
      world.fakeEvaluate(9001, function(charKey)
        return { allocation = {}, reagentCost = 0, expectedYield = 1, flags = {}, profit = charKey == "Main-Realm" and 9 or 1 }
      end)
      world.counts[5002] = 0; Q:SetRestock(5002, 3)
      local r = Q:CraftNext()
      assert.same({ "crafted", "restock:5002" }, { r.status, r.entryID })
      local id = Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm", targetQuality = 1 })
      W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", { itemID = 5002, operationID = 9 })
      local entries = Q:GetEntries()
      assert.same({ id, 1 }, { entries[1].id, entries[1].quantity })
    end)
    it("changes nothing on a craft result while the saved data is newer", function()
      world.haveAll("Main-Realm")
      Q:Add({ recipeID = 9001, quantity = 2, charKey = "Main-Realm" })
      assert.equals("crafted", Q:CraftNext().status)
      ns.FS.dbIsNewer = true
      W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", { itemID = 5002, operationID = 1 })
      assert.equals(2, ns.FS.db.global.queue.entries[1].quantity)
    end)
    it("logs a failing result handler without turning the module off", function()
      world.haveAll("Main-Realm")
      Q:Add({ recipeID = 9001, quantity = 2, charKey = "Main-Realm" })
      Q:CraftNext()
      local orig = Q.SetQuantity
      Q.SetQuantity = function() error("boom") end
      W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", { itemID = 5002, operationID = 1 })
      Q.SetQuantity = orig
      assert.is_true(ns.FS:GetModule("QueueCraft"):IsEnabled()); assert.is_true(Q:IsEnabled())
      local errors = ns.FS.db.global.diagnostics.errors
      assert.equals("QueueCraft:CraftResult", errors[#errors].source)
    end)
    it("stops counting results when disabled", function()
      world.haveAll("Main-Realm")
      Q:Add({ recipeID = 9001, quantity = 2, charKey = "Main-Realm" })
      Q:CraftNext()
      ns.FS:GetModule("QueueCraft"):Disable()
      W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", { itemID = 5002, operationID = 1 })
      assert.equals(2, Q:GetEntries()[1].quantity)
    end)
  end)
end)

-- Structural rule (global constraints): C_TradeSkillUI.CraftRecipe is called only inside
-- Queue:CraftNext, and Queue:CraftNext is referenced only from OnClick handlers (a call, or the
-- function passed on, as in pcall(Queue.CraftNext, Q) or Wrap(name, Queue.CraftNext)).
describe("click-only crafting", function()
  local DIRS = "Core Data Math Modules UI"

  local function lua_files()
    local out = {}
    local p = io.popen("find " .. DIRS .. " -name '*.lua' | sort")
    for line in p:lines() do out[#out + 1] = line end
    p:close()
    return out
  end

  -- Source with --[[ ]] / --[==[ ]==] block comments and -- line comments blanked (newlines kept).
  local function strip_comments(text)
    local out, i, n = {}, 1, #text
    while i <= n do
      local s = text:find("--", i, true)
      if not s then out[#out + 1] = text:sub(i); break end
      out[#out + 1] = text:sub(i, s - 1)
      local eqs = text:match("^%[(=*)%[", s + 2)
      if eqs then
        local close = "]" .. eqs .. "]"
        local e = text:find(close, s + 4 + #eqs, true)
        local stop = e and (e + #close - 1) or n
        out[#out + 1] = (text:sub(s, stop):gsub("[^\n]", ""))
        i = stop + 1
      else
        i = text:find("\n", s, true) or (n + 1)
      end
    end
    return table.concat(out)
  end

  local function code_lines(path)
    local f = assert(io.open(path, "r"))
    local text = strip_comments(f:read("*a"))
    f:close()
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    return lines
  end

  it("blanks block and line comments", function()
    local text = strip_comments("a --[[ x\ny ]] b -- c\nd --[==[ ]] ]==] e\n")
    assert.equals("a \n b \nd  e\n", text)
  end)

  it("calls CraftRecipe only inside Queue:CraftNext", function()
    local hits = {}
    for _, path in ipairs(lua_files()) do
      local inside = false
      for i, line in ipairs(code_lines(path)) do
        if line:match("^function Queue:CraftNext%(") then inside = true
        elseif line:match("^end") then inside = false end
        if line:find("CraftRecipe", 1, true) then
          hits[#hits + 1] = path .. ":" .. i
          assert.is_true(inside, path .. ":" .. i .. " calls CraftRecipe outside Queue:CraftNext")
        end
      end
    end
    assert.same({ "Modules/QueueCraft.lua" }, { (hits[1] or ""):match("^[^:]+") })
    assert.equals(1, #hits)
  end)

  it("references Queue:CraftNext only from OnClick handlers", function()
    for _, path in ipairs(lua_files()) do
      local lines = code_lines(path)
      for i, line in ipairs(lines) do
        if line:find("CraftNext", 1, true) and not line:match("^function Queue:CraftNext%(") then
          -- The line itself (SetScript("OnClick", Wrap(name, Queue.CraftNext))) or the innermost function
          -- line at or above it (SetScript("OnClick", function() ... end)) must name OnClick.
          local j = i
          if not line:find("OnClick", 1, true) then
            while j > 0 and not lines[j]:find("function", 1, true) do j = j - 1 end
          end
          assert.is_truthy(j > 0 and lines[j]:find("OnClick", 1, true),
            path .. ":" .. i .. " references CraftNext outside an OnClick handler")
        end
      end
    end
  end)
end)
