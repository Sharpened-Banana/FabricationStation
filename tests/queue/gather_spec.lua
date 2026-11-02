-- Queue:GetGatheringPlan (phase 7 Task 15): for each reagent the queue is still short of, where it can come from.
-- Main-Realm is the logged-in character, Alt-Realm the other one. Recipe 9001's plan is faked (1001 x3, 2002 x2,
-- 3001 x1); recipe 9100 (Intermediates) makes 1001 from 2 x 1101 at 20 each, so a craft of 1001 costs 40.
describe("Queue gathering plan", function()
  local ns, W, world, Q
  local ME, ALT = "Main-Realm", "Alt-Realm"
  local DAY = 86400

  local function boot(opts)
    opts = opts or {}
    ns, W, world = make_world({ last = "Modules/Intermediates.lua", intermediates = true, calibrate = opts.calibrate })
    Q = ns.FS:GetModule("Queue")
    world.fakeEvaluate(9001, { allocation = { { slotIndex = 1, itemID = 1001, quantity = 3 },
      { slotIndex = 2, itemID = 2002, quantity = 2 }, { slotIndex = 3, itemID = 3001, quantity = 1 } },
      reagentCost = 900, flags = {} })
    Q:Add({ recipeID = 9001, quantity = 1, charKey = ME })
  end

  local function row_of(plan, itemID)
    for _, row in ipairs(plan) do if row.itemID == itemID then return row end end
    return nil
  end

  local function kinds(row)
    local out = {}
    for i, s in ipairs(row.sources) do out[i] = s.kind end
    return out
  end

  local function source_of(row, kind, charKey)
    for _, s in ipairs(row.sources) do
      if s.kind == kind and (charKey == nil or s.charKey == charKey) then return s end
    end
    return nil
  end

  local function no_warband() ns.FS.db.global.settings.crafting = { queueUseWarband = false } end

  before_each(function() boot() end)

  it("has one row per missing reagent, by item name and then item ID", function()
    local plan = Q:GetGatheringPlan()
    assert.same({ { 1001, 3 }, { 2002, 2 }, { 3001, 1 } }, { { plan[1].itemID, plan[1].need }, { plan[2].itemID, plan[2].need },
      { plan[3].itemID, plan[3].need } })
    world.names[3001] = "Aether"; world.names[1001] = "Zephyr"; world.names[2002] = "aether"
    plan = Q:GetGatheringPlan()
    assert.same({ 2002, 3001, 1001 }, { plan[1].itemID, plan[2].itemID, plan[3].itemID })    -- case ignored, then itemID
    assert.same({}, Q:GetGatheringPlan("Nobody-Realm"))
  end)

  it("leaves out what the crafter already holds", function()
    world.items[ME][1001] = { bags = 3, bank = 0, reagentBank = 0 }
    world.items[ME][2002] = { bags = 1, bank = 0, reagentBank = 0 }
    local plan = Q:GetGatheringPlan()
    assert.same({ { 2002, 1 }, { 3001, 1 } }, { { plan[1].itemID, plan[1].need }, { plan[2].itemID, plan[2].need } })
  end)

  it("lists mail, alts, craft, vendor and AH sources in that order", function()
    no_warband()
    world.chars[ALT].mail = { time = W.now - 3600, items = { [1001] = 4 } }
    world.chars[ME].mail = { time = W.now - 7200, items = { [1001] = 2 } }
    world.items[ALT][1001] = { bags = 5, bank = 0, reagentBank = 0 }
    world.chars[ALT].itemsTime = { bags = W.now - 2 * DAY }
    world.warband[1001] = 7
    local row = row_of(Q:GetGatheringPlan(), 1001)
    assert.same({ "mail", "mail", "alt", "warband", "craft", "ah" }, kinds(row))
    assert.same({ { "mail", ALT, 4, 3600 }, { "mail", ME, 2, 7200 } },
      { { row.sources[1].kind, row.sources[1].charKey, row.sources[1].count, row.sources[1].ageSeconds },
        { row.sources[2].kind, row.sources[2].charKey, row.sources[2].count, row.sources[2].ageSeconds } })
    assert.same({ "alt", ALT, 5, 2 * DAY }, { row.sources[3].kind, row.sources[3].charKey, row.sources[3].count,
      row.sources[3].ageSeconds })
    assert.same({ "warband", 7, 0 }, { row.sources[4].kind, row.sources[4].count, row.sources[4].ageSeconds })
    local craft = row.sources[5]
    assert.same({ ME, 9100, 1, 40 }, { craft.charKey, craft.recipeID, craft.quality, craft.unitPrice })
    assert.same({ "ah", 100, DAY }, { row.sources[6].kind, row.sources[6].unitPrice, row.sources[6].ageSeconds })
    -- A vendor price is the vendor source (Prices answers one or the other).
    world.prices[2002] = { value = 50, source = "vendor" }
    local vendor = row_of(Q:GetGatheringPlan(), 2002)
    assert.same({ "vendor" }, kinds(vendor))
    assert.same({ 50, nil }, { vendor.sources[1].unitPrice, vendor.sources[1].ageSeconds })
  end)

  it("takes the logged-in character's holdings as an alt source when the crafter is another", function()
    Q:Clear()
    Q:Add({ recipeID = 9001, quantity = 1, charKey = ALT })
    world.items[ME][1001] = { bags = 6, bank = 0, reagentBank = 0 }
    local row = row_of(Q:GetGatheringPlan(), 1001)
    assert.same({ "alt", ME, 6, 0 }, { row.sources[1].kind, row.sources[1].charKey, row.sources[1].count,
      row.sources[1].ageSeconds })
    -- The crafter's own holdings are never an alt source for itself.
    world.items[ALT][1001] = { bags = 1, bank = 0, reagentBank = 0 }
    assert.is_nil(source_of(row_of(Q:GetGatheringPlan(ALT), 1001), "alt", ALT))
  end)

  it("lists alts from the Scanner snapshots while Alts is off", function()
    ns.FS:GetModule("Alts"):Disable()
    no_warband()
    world.items[ALT][1001] = { bags = 2, bank = 3, reagentBank = 1 }
    world.chars[ALT].itemsTime = { bags = W.now - 3 * DAY, bank = W.now - DAY }
    world.warband[1001] = 4
    local row = row_of(Q:GetGatheringPlan(), 1001)
    local alt = source_of(row, "alt")
    assert.same({ ALT, 6, 3 * DAY }, { alt.charKey, alt.count, alt.ageSeconds })
    assert.same({ 4 }, { source_of(row, "warband").count })
  end)

  it("leaves hidden characters out of the mail and alt sources", function()
    world.chars[ALT].mail = { time = W.now, items = { [1001] = 4 } }
    world.items[ALT][1001] = { bags = 5, bank = 0, reagentBank = 0 }
    ns.FS:GetModule("Alts"):SetHidden(ALT, true)
    local row = row_of(Q:GetGatheringPlan(), 1001)
    assert.is_nil(source_of(row, "mail")); assert.is_nil(source_of(row, "alt"))
  end)

  it("shows the warband only with queueUseWarband off", function()
    world.warband[1001] = 7
    assert.is_true(ns.FS:GetModule("Recipes"):GetSetting("queueUseWarband"))
    assert.is_nil(row_of(Q:GetGatheringPlan(), 1001))            -- the warband covers the whole need
    no_warband()
    world.warband[1001] = 2
    local row = row_of(Q:GetGatheringPlan(), 1001)
    assert.same({ 2 }, { source_of(row, "warband").count })
    world.warband[1001] = nil
    assert.is_nil(source_of(row_of(Q:GetGatheringPlan(), 1001), "warband"))
  end)

  it("leaves craft out while Intermediates is off", function()
    assert.is_truthy(source_of(row_of(Q:GetGatheringPlan(), 1001), "craft"))
    ns.FS:GetModule("Intermediates"):Disable()
    local row = row_of(Q:GetGatheringPlan(), 1001)
    assert.is_nil(source_of(row, "craft"))
    assert.same({ "ah" }, kinds(row))
  end)

  it("keeps an unknown count, price or age as nil", function()
    -- A craft with no price for its reagents: the unit cost is unknown, never 0.
    world.prices[1101] = nil
    world.bumpPriceVersion()
    local craft = source_of(row_of(Q:GetGatheringPlan(), 1001), "craft")
    assert.equals(9100, craft.recipeID); assert.is_nil(craft.unitPrice)
    -- Snapshots without a time and an auction price without an age.
    world.chars[ALT].mail = { items = { [1001] = 4 } }
    world.items[ALT][1001] = { bags = 1, bank = 0, reagentBank = 0 }
    world.chars[ALT].lastSeen = nil
    world.prices[1001] = { value = 100, source = "auction" }
    local row = row_of(Q:GetGatheringPlan(), 1001)
    assert.is_nil(source_of(row, "mail").ageSeconds)
    assert.is_nil(source_of(row, "alt").ageSeconds)
    assert.is_nil(source_of(row, "ah").ageSeconds)
    assert.equals(100, source_of(row, "ah").unitPrice)
    -- A mailbox never opened is no mail source (nil, nil is unknown, not none).
    world.chars[ALT].mail = nil
    assert.is_nil(source_of(row_of(Q:GetGatheringPlan(), 1001), "mail"))
  end)

  it("limits the plan to one character", function()
    Q:Add({ recipeID = 9001, quantity = 1, charKey = ALT })
    world.fakeEvaluate(9001, function(charKey)
      if charKey == ME then
        return { allocation = { { slotIndex = 1, itemID = 1001, quantity = 3 } }, reagentCost = 1, flags = {} }
      end
      return { allocation = { { slotIndex = 1, itemID = 1001, quantity = 2 }, { slotIndex = 2, itemID = 2002, quantity = 2 } },
        reagentCost = 1, flags = {} }
    end)
    local all = Q:GetGatheringPlan()
    assert.same({ { 1001, 5 }, { 2002, 2 } }, { { all[1].itemID, all[1].need }, { all[2].itemID, all[2].need } })
    local mine = Q:GetGatheringPlan(ME)
    assert.same({ { 1001, 3 } }, { { mine[1].itemID, mine[1].need } })
    local theirs = Q:GetGatheringPlan(ALT)
    assert.same({ { 1001, 2 }, { 2002, 2 } }, { { theirs[1].itemID, theirs[1].need }, { theirs[2].itemID, theirs[2].need } })
    -- The crafter the plan is for is not its own alt source; the other character is.
    world.items[ME][2002] = { bags = 1, bank = 0, reagentBank = 0 }
    assert.is_truthy(source_of(row_of(Q:GetGatheringPlan(ALT), 2002), "alt", ME))
  end)

  it("carries the saved Craft / Buy choice", function()
    local I = ns.FS:GetModule("Intermediates")
    assert.is_nil(row_of(Q:GetGatheringPlan(), 1001).choice)
    I:SetChoice(1001, "buy")
    assert.equals("buy", row_of(Q:GetGatheringPlan(), 1001).choice)
    assert.is_nil(row_of(Q:GetGatheringPlan(), 2002).choice)
  end)

  describe("a reagent a queued craft will make", function()
    it("is not missing: a queued sub-craft covers it", function()
      -- 9100 makes one 1001 per craft; three crafts cover the three 1001 the plan needs.
      assert.is_truthy(Q:Add({ recipeID = 9100, quantity = 3, charKey = ME, targetQuality = 1, parentID = 1 }))
      world.fakeEvaluate(9100, { allocation = { { slotIndex = 1, itemID = 1101, quantity = 2 } }, reagentCost = 40,
        expectedYield = 1, flags = {} })
      local plan = Q:GetGatheringPlan()
      assert.is_nil(row_of(plan, 1001))
      -- ... and the sub-craft's own reagents are still to gather.
      assert.same({ 1101, 6 }, { row_of(plan, 1101).itemID, row_of(plan, 1101).need })
      -- The shopping list is untouched: Queue:GetMissingReagents still lists 1001.
      assert.equals(3, Q:GetMissingReagents()[1001])
    end)

    it("is short only by what the sub-crafts leave", function()
      world.fakeEvaluate(9100, { allocation = { { slotIndex = 1, itemID = 1101, quantity = 2 } }, reagentCost = 40,
        expectedYield = 1.5, flags = {} })
      Q:Add({ recipeID = 9100, quantity = 2, charKey = ME, targetQuality = 1, parentID = 1 })
      assert.is_nil(row_of(Q:GetGatheringPlan(), 1001))               -- floor(2 * 1.5) = 3 made of 3
      Q:Clear(); Q:Add({ recipeID = 9001, quantity = 1, charKey = ME })
      Q:Add({ recipeID = 9100, quantity = 1, charKey = ME, targetQuality = 1 })
      assert.equals(2, row_of(Q:GetGatheringPlan(), 1001).need)       -- floor(1 * 1.5) = 1 made of 3
    end)

    it("counts a craft queued from the plan itself, whatever character makes it", function()
      Q:Add({ recipeID = 9100, quantity = 3, charKey = ALT, targetQuality = 1 })
      world.fakeEvaluate(9100, { allocation = { { slotIndex = 1, itemID = 1101, quantity = 2 } }, reagentCost = 40,
        expectedYield = 1, flags = {} })
      assert.is_nil(row_of(Q:GetGatheringPlan(ME), 1001))
    end)
  end)

  it("reads only: the very first plan writes nothing and sends no message", function()
    -- A fresh save has no settings.alts: Alts must not create it for a read.
    assert.is_nil(ns.FS.db.global.settings.alts)
    local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
    local sent = #world.messages("FS_QUEUE_CHANGED")
    Q:GetGatheringPlan(); Q:GetGatheringPlan(ME)
    assert.same(before, ns.Util.DeepCopy(ns.FS.db.global, 30))
    assert.is_nil(ns.FS.db.global.settings.alts)
    assert.equals(sent, #world.messages("FS_QUEUE_CHANGED"))
  end)

  it("reads only while the saved data is from a newer version", function()
    world.chars[ALT].mail = { time = W.now, items = { [1001] = 4 } }
    world.items[ALT][1001] = { bags = 5, bank = 0, reagentBank = 0 }
    ns.FS.dbIsNewer = true
    local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
    local row = row_of(Q:GetGatheringPlan(), 1001)
    assert.is_truthy(source_of(row, "alt")); assert.is_truthy(source_of(row, "mail"))
    assert.same(before, ns.Util.DeepCopy(ns.FS.db.global, 30))
  end)

  it("honours the saved hidden characters without writing", function()
    world.items[ALT][1001] = { bags = 5, bank = 0, reagentBank = 0 }
    ns.FS.db.global.settings.alts = { hidden = { [ALT] = true } }
    local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
    assert.is_nil(source_of(row_of(Q:GetGatheringPlan(), 1001), "alt"))
    assert.same(before, ns.Util.DeepCopy(ns.FS.db.global, 30))      -- not even filled with the other defaults
  end)
end)
