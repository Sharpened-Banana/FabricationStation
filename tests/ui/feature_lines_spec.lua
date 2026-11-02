-- Phase 7 Task 12: the profession side panel's "Best optionals" row and "Queue with best optionals" button
-- (registered by FeatureLines on ProfessionPanel).
describe("FeatureLines: optionals in the profession panel", function()
  local ns, world, Panel, Queue
  local ME = "Main-Realm"

  local function lines() return Panel:CollectLines(9001, ME) end
  local function action()
    for _, spec in ipairs(Panel:CollectActions(9001, ME)) do
      if spec.text == "Queue with best optionals" then return spec end
    end
    return nil
  end

  before_each(function()
    ns, _, world = make_world({ last = "UI/FeatureLines.lua", calibrate = { [ME] = { 9001 } } })
    Panel = ns.FS:GetModule("ProfessionPanel"); Queue = ns.FS:GetModule("Queue")
    ns.GameData.Define("OptionalReagents", 70575, {
      [7001] = { categoryID = 60, effects = { { type = "skill", amount = 40 } } },
      [7002] = { categoryID = 60, effects = { { type = "skill", amount = 20 } } },
      [7003] = { categoryID = 61, effects = { { type = "multicraft", amount = 110 } } },
    })
    local slots = world.schematics[9001].reagentSlots
    slots[#slots + 1] = { slotIndex = 4, quantity = 2, reagents = { 7001, 7002 }, kind = "optional", dataSlotIndex = 14,
      dataSlotType = 2 }
    slots[#slots + 1] = { slotIndex = 5, quantity = 1, reagents = { 7003 }, kind = "finishing", dataSlotIndex = 15,
      dataSlotType = 2 }
    world.prices[7001] = { value = 50000, source = "auction", ageDays = 1 }
    world.prices[7002] = { value = 10, source = "auction", ageDays = 1 }
    world.prices[7003] = { value = 1000, source = "auction", ageDays = 1 }
    world.names[7002], world.names[7003] = "Moonpetal", "Sunfire Resin"
  end)

  it("shows the best optionals and the gain", function()
    assert.same({ { "Best optionals", "Moonpetal, Sunfire Resin (+" .. ns.UI.FormatMoney(133900 - 120010) .. ")" } }, lines())
  end)

  it("names an item the client has not cached as item:<id>", function()
    world.names[7002] = nil
    assert.equals("item:7002, Sunfire Resin (+" .. ns.UI.FormatMoney(133900 - 120010) .. ")", lines()[1][2])
  end)

  it("shows none adds profit when nothing beats the plain craft", function()
    world.prices[7002].value, world.prices[7003].value = 90000000, 90000000
    world.bumpPriceVersion()
    assert.same({ { "Best optionals", "none adds profit" } }, lines())
    assert.is_false(action().enabled)   -- no pick: the button is there but off
  end)

  it("does not claim that nothing adds profit while the plain craft's profit is unknown", function()
    world.prices[5001], world.prices[5002] = nil, nil; world.bumpPriceVersion()
    local shown = lines()
    assert.same({ "Best optionals", "profit unknown (prices missing)" }, shown[1])
    for _, line in ipairs(shown) do assert.are_not.equal("none adds profit", line[2]) end
    assert.is_false(action().enabled)
  end)

  it("counts what it skipped", function()
    world.prices[7001] = nil; world.bumpPriceVersion()
    local shown = lines()
    assert.same({ "Best optionals", "Moonpetal, Sunfire Resin (+" .. ns.UI.FormatMoney(133900 - 120010) .. ")" }, shown[1])
    assert.same({ "", "1 skipped: no price or no known effect" }, shown[2])
    assert.equals(2, #shown)
  end)

  it("adds nothing with optionalMode off", function()
    ns.FS:GetOptionsTable().args.crafting.args.optionalMode.set(nil, "off")
    assert.same({}, lines())
    assert.is_nil(action())
  end)

  it("adds nothing for a recipe without an optional slot or a schematic", function()
    assert.same({}, Panel:CollectLines(424242, ME))
    local slots = world.schematics[9001].reagentSlots
    slots[5], slots[4] = nil, nil
    assert.same({}, lines())
    assert.is_nil(action())
  end)

  it("keeps the Panel's other providers in registration order after it", function()
    Panel:RegisterLineProvider("later", function() return { { "Later", "x" } } end)
    local shown = lines()
    assert.equals("Best optionals", shown[1][1]); assert.equals("Later", shown[#shown][1])
  end)

  it("logs a failing search once as FeatureLines:optionals and keeps the providers", function()
    local recipes = ns.FS:GetModule("Recipes")
    local real = recipes.BestOptionals
    recipes.BestOptionals = function() error("boom") end
    assert.same({}, lines()); assert.same({}, lines()); assert.is_nil(action())
    local n = {}
    for _, e in ipairs(ns.FS.db.global.diagnostics.errors) do n[e.source] = (n[e.source] or 0) + 1 end
    assert.same({ ["FeatureLines:optionals"] = 1, ["FeatureLines:queueOptionals"] = 1 }, n)
    recipes.BestOptionals = real
    assert.equals("Best optionals", lines()[1][1])
    assert.is_table(action())
  end)

  describe("Queue with best optionals", function()
    it("is on when there is a pick and the queue is writable", function()
      local spec = action()
      assert.is_true(spec.enabled); assert.is_nil(spec.status)
    end)

    it("queues the recipe with the picked optionals", function()
      local before = #Queue:GetEntries()
      action().onClick()
      local entries = Queue:GetEntries()
      assert.equals(before + 1, #entries)
      local e = entries[#entries]
      assert.same({ 9001, 1, ME, { 7002, 7003 } }, { e.recipeID, e.quantity, e.charKey, e.optionalItemIDs })
      assert.equals("Queued with Moonpetal, Sunfire Resin", action().status)
    end)

    it("is off, with no pick to queue", function()
      world.prices[7002].value, world.prices[7003].value = 90000000, 90000000
      world.bumpPriceVersion()
      local spec = action()
      assert.is_false(spec.enabled)
      spec.onClick()
      assert.equals(0, #Queue:GetEntries())
    end)

    it("is off, and writes nothing, while the saved data is from a newer version", function()
      ns.FS.dbIsNewer = true
      local spec = action()
      assert.is_false(spec.enabled)
      assert.equals("Saved data is from a newer version of FabricationStation; the queue is read-only.", spec.status)
      local snapshot = ns.Util.DeepCopy(ns.FS.db.global, 30)
      spec.onClick()
      assert.same(snapshot, ns.Util.DeepCopy(ns.FS.db.global, 30))
      assert.is_falsy(action().status:find("Queued with", 1, true))
    end)

    it("queues with the picked optionals only when the button is clicked", function()
      lines(); action()
      assert.equals(0, #Queue:GetEntries())
    end)
  end)
end)

-- Phase 7 Task 14: the profession side panel's craft-or-buy rows and "Queue with sub-crafts" button (registered by
-- FeatureLines on ProfessionPanel after the optionals ones). The world's recipe 9100 makes reagent 1001 (buy 100) from
-- 2 x 1101 (20 each): crafting costs 40.
describe("FeatureLines: intermediates in the profession panel", function()
  local ns, world, Panel, Queue, I
  local ME = "Main-Realm"
  local money = function(c) return ns.UI.FormatMoney(c) end

  local function lines() return Panel:CollectLines(9001, ME) end
  local function action()
    for _, spec in ipairs(Panel:CollectActions(9001, ME)) do
      if spec.text == "Queue with sub-crafts" then return spec end
    end
    return nil
  end

  before_each(function()
    ns, _, world = make_world({ last = "UI/FeatureLines.lua", intermediates = true })
    Panel = ns.FS:GetModule("ProfessionPanel"); Queue = ns.FS:GetModule("Queue"); I = ns.FS:GetModule("Intermediates")
    world.names[1001], world.names[1101] = "Bright Ore", "Raw Ore"
  end)

  it("lists craft against buy for each craftable reagent", function()
    local res = I:Resolve(9001, ME)
    assert.same({
      { "Bright Ore", "craft " .. money(40) .. " \194\183 buy " .. money(100) .. " \194\183 crafting" },
      { "With intermediates", "saves " .. money(res.saving) .. " per craft" },
    }, lines())
    I:SetChoice(1001, "buy")
    assert.same({ { "Bright Ore", "craft " .. money(40) .. " \194\183 buy " .. money(100) .. " \194\183 buying" } }, lines())
  end)

  it("shows an unknown cost as ? and a cycle as buy only", function()
    world.prices[1101] = nil; world.bumpPriceVersion()
    assert.same({ { "Bright Ore", "craft ? \194\183 buy " .. money(100) .. " \194\183 buying" } }, lines())
    world.prices[1101] = { value = 20, source = "auction", ageDays = 1 }
    world.addRecipe(9100, 1001, { { 5001, 1 } })                 -- 1001 made from the recipe's own output
    world.bumpPriceVersion()
    assert.same({ "Bright Ore", "craft ? \194\183 buy " .. money(100) .. " \194\183 buy only (cycle)" }, lines()[1])
  end)

  it("shows at most 6 reagents, then how many more", function()
    local reagents = {}
    for i = 1, 8 do
      reagents[i] = { 2100 + i, 1 }
      world.prices[2100 + i] = { value = 1000, source = "auction", ageDays = 1 }
      world.addRecipe(9300 + i, 2100 + i, { { 1101, 1 } })
    end
    world.addRecipe(9200, 2001, reagents)
    local shown = Panel:CollectLines(9200, ME)
    assert.equals("item:2106", shown[6][1])
    assert.same({ "+2 more", "" }, shown[7])
    assert.equals("With intermediates", shown[8][1])
  end)

  it("adds nothing without a craftable reagent, or while the module is off", function()
    assert.same({}, Panel:CollectLines(424242, ME))
    world.addRecipe(9200, 2001, { { 3001, 1 } })
    assert.same({}, Panel:CollectLines(9200, ME))
    ns.FS:SetModuleEnabled("Intermediates", false)
    assert.same({}, lines())
    assert.is_nil(action())
  end)

  it("queues sub-crafts from the action", function()
    local spec = action()
    assert.is_true(spec.enabled); assert.is_nil(spec.status)
    lines(); assert.same({}, Queue:GetEntries())             -- drawing queues nothing
    spec.onClick()
    local e = Queue:GetEntries()
    assert.same({ 9100, 3, ME, e[2].id }, { e[1].recipeID, e[1].quantity, e[1].charKey, e[1].parentID })
    assert.same({ 9001, 1, ME }, { e[2].recipeID, e[2].quantity, e[2].charKey })
    assert.equals("Queued 1 sub-craft first", action().status)
  end)

  it("says when a sub-craft is made on another character", function()
    ns.FS.db.global.recipeCalib = { ["Alt-Realm"] = { [9100] = { baseSkill = 500, baseDifficulty = 700,
      maxReagentSkill = 280, craftingDataID = 2588, stats = { resourcefulness = 0.25 }, time = ns.FS:Now() } } }
    ns.FS:SendMessage("FS_DATA_CHANGED", "Alt-Realm", "recipes")
    assert.equals("Alt-Realm", I:Resolve(9001, ME).rows[1].craft.charKey)
    action().onClick()
    assert.equals("Queued 1 sub-craft first \194\183 Bright Ore crafts on Alt: mail the reagents", action().status)
  end)

  it("counts several sub-crafts", function()
    world.addRecipe(9101, 1101, { { 1201, 1 } })
    world.prices[1201] = { value = 5, source = "auction", ageDays = 1 }
    action().onClick()
    assert.equals("Queued 2 sub-crafts first", action().status)
  end)

  it("is off with nothing chosen to craft", function()
    I:SetChoice(1001, "buy")
    local spec = action()
    assert.is_false(spec.enabled)
    spec.onClick()
    assert.same({}, Queue:GetEntries())
  end)

  it("says when the reagents are already held", function()
    world.items[ME][1001] = { bags = 3, bank = 0, reagentBank = 0 }
    action().onClick()
    assert.same({}, Queue:GetEntries())
    assert.equals("No sub-craft needed: the reagents are on hand", action().status)
  end)

  it("is off, and writes nothing, while the saved data is from a newer version", function()
    ns.FS.dbIsNewer = true
    local spec = action()
    assert.is_false(spec.enabled)
    assert.equals("Saved data is from a newer version of FabricationStation; the queue is read-only.", spec.status)
    local snapshot = ns.Util.DeepCopy(ns.FS.db.global, 30)
    spec.onClick()
    assert.same(snapshot, ns.Util.DeepCopy(ns.FS.db.global, 30))
  end)

  it("comes after the optionals rows", function()
    local ids = {}
    Panel:RegisterLineProvider("later", function() return { { "Later", "x" } } end)
    for _, line in ipairs(lines()) do ids[#ids + 1] = line[1] end
    assert.equals("Bright Ore", ids[1]); assert.equals("Later", ids[#ids])
  end)

  it("logs a failing resolution once as FeatureLines:intermediates and keeps the providers", function()
    local real = I.Resolve
    I.Resolve = function() error("boom") end
    assert.same({}, lines()); assert.same({}, lines()); assert.is_nil(action())
    local n = {}
    for _, e in ipairs(ns.FS.db.global.diagnostics.errors) do n[e.source] = (n[e.source] or 0) + 1 end
    assert.same({ ["FeatureLines:intermediates"] = 1, ["FeatureLines:queueSubCrafts"] = 1 }, n)
    I.Resolve = real
    assert.equals("Bright Ore", lines()[1][1])
  end)
end)
