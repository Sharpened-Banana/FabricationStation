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
