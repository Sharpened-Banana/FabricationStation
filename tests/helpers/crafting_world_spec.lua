describe("make_world", function()
  it("uses Main-Realm as the current character and seeds both characters", function()
    local ns, _, world = make_world({ last = "Modules/Recipes.lua" })
    assert.equals("Main-Realm", ns.FS:CharKey())
    local Scanner = ns.FS:GetModule("Scanner")
    assert.same({ "Alt-Realm", "Main-Realm" }, Scanner:GetCharacters())
    for _, key in ipairs({ "Main-Realm", "Alt-Realm" }) do
      local p = Scanner:GetProfession(key, 2906)
      assert.equals(500, p.skill); assert.is_true(p.recipes[9001])
      assert.same({}, world.items[key])
    end
  end)
  it("serves the sample schematic and GameData", function()
    local ns = make_world({ last = "Modules/Recipes.lua" })
    local s = ns.FS:GetModule("Scanner"):GetSchematic(9001)
    assert.equals(2906, s.skillLineID); assert.equals(2588, s.craftingDataID); assert.equals(700, s.baseDifficulty)
    assert.same({ [1] = 5001, [2] = 5002 }, s.outputItemIDs)
    assert.same({ 1001, 1002 }, s.reagentSlots[1].reagents); assert.equals(10, s.reagentSlots[1].quantity)
    assert.same({ 11, 12, 13 }, { s.reagentSlots[1].dataSlotIndex, s.reagentSlots[2].dataSlotIndex, s.reagentSlots[3].dataSlotIndex })
    assert.same({ 2, 2, 1 }, { s.reagentSlots[1].dataSlotType, s.reagentSlots[2].dataSlotType, s.reagentSlots[3].dataSlotType })
    local CD, gd = ns.CraftingData, ns.GameData
    assert.equals(48, CD.ReagentWeight(gd, 1002)); assert.equals(32, CD.ReagentWeight(gd, 2001)); assert.equals(0, CD.ReagentWeight(gd, 3001))
    assert.same({ 1.0 }, CD.ThresholdFractions(gd, 2588, 2))
    assert.same({ 0.6, 2.2 }, CD.Curve(gd, 2588).curve[2])
  end)
  it("backs Prices with world.prices and bumps the version", function()
    local ns, _, world = make_world({ last = "Modules/Recipes.lua" })
    local P = ns.FS:GetModule("Prices")
    assert.same({ value = 100000, source = "auction", ageDays = 1 }, P:Get(5002))
    assert.same({}, P:Get(424242))
    world.prices[5002] = nil; assert.same({}, P:Get(5002))
    local v = P:GetVersion(); world.bumpPriceVersion()
    assert.equals(v + 1, P:GetVersion()); assert.equals(1, #world.messages("FS_PRICES_CHANGED"))
  end)
  it("counts items per character, warband once, and honours counts", function()
    local ns, _, world = make_world({ last = "Modules/Recipes.lua" })
    local S = ns.FS:GetModule("Scanner")
    world.items["Alt-Realm"][1001] = { bags = 4, bank = 1, reagentBank = 0 }
    world.items["Main-Realm"][1001] = { bags = 2, bank = 0, reagentBank = 0 }
    world.warband[1001] = 3
    assert.equals(8, S:GetItemCount(1001, "Alt-Realm").total)
    assert.equals(10, S:GetItemCount(1001, nil).total)
    world.counts[5002] = 12; assert.equals(12, S:GetItemCount(5002, nil).total)
  end)
  it("serves live operation info only when world.live has the recipe", function()
    local ns, _, world = make_world({ last = "Modules/Recipes.lua" })
    local S = ns.FS:GetModule("Scanner")
    assert.is_nil(S:GetLiveOperationInfo(9001, {}, false))
    world.live[9001] = function(allocation, applyConcentration) return { n = #allocation, c = applyConcentration } end
    assert.same({ n = 0, c = true }, S:GetLiveOperationInfo(9001, nil, true))
  end)
  it("seeds calibrations and clones recipes", function()
    local ns, W, world = make_world({ last = "Modules/Recipes.lua", recipes = 3,
      calibrate = { ["Main-Realm"] = "all", ["Alt-Realm"] = { 9002 } } })
    local calib = ns.FS.db.global.recipeCalib
    for _, id in ipairs({ 9001, 9002, 9003 }) do
      assert.same({ baseSkill = 500, baseDifficulty = 700, maxReagentSkill = 280, craftingDataID = 2588,
        stats = { multicraft = 0.2, resourcefulness = 0.25, ingenuity = 0.2 }, time = W.now }, calib["Main-Realm"][id])
    end
    assert.is_truthy(calib["Alt-Realm"][9002]); assert.is_nil(calib["Alt-Realm"][9001])
    assert.equals(5002, world.outputOf(9001))
    local outs, prices = {}, {}
    for _, id in ipairs({ 9001, 9002, 9003 }) do
      local out = world.outputOf(id)
      assert.is_nil(outs[out]); outs[out] = true
      assert.is_nil(prices[world.prices[out].value]); prices[world.prices[out].value] = true
      assert.is_true(world.chars["Alt-Realm"].professions[2906].recipes[id])
    end
  end)
  it("installs the extra fakes and merges opts.stubs", function()
    make_world({ last = "Modules/Recipes.lua", stubs = { UnitName = function() return "Other" end } })
    assert.equals("function", type(EventRegistry.RegisterCallback))
    assert.equals("function", type(TooltipDataProcessor.AddTooltipPostCall))
    assert.is_number(Enum.TooltipDataType.Item); assert.is_number(debugprofilestop())
    assert.equals(1, Enum.CraftingReagentType.Basic)
    assert.equals("Other", UnitName("player"))
  end)
  it("fakes Recipes:Evaluate per recipe and records the calls", function()
    local ns, _, world = make_world({ last = "Modules/Recipes.lua", recipes = 2 })
    local R = ns.FS:GetModule("Recipes")
    local fixed = { profit = 1 }
    world.fakeEvaluate(9001, fixed)
    assert.equals(fixed, R:Evaluate(9001, "Alt-Realm", { targetQuality = 2 }))
    assert.equals(9002, R:Evaluate(9002, "Main-Realm", {}).recipeID)       -- other recipes stay real
    world.fakeEvaluate(9001, function(charKey) return { charKey = charKey } end)
    assert.equals("Alt-Realm", R:Evaluate(9001, "Alt-Realm").charKey)
    world.fakeEvaluate(9001, nil)
    assert.equals(9001, R:Evaluate(9001, "Main-Realm", {}).recipeID)
    assert.same({ 9001, "Alt-Realm", 2 }, { world.evaluated[1].recipeID, world.evaluated[1].charKey, world.evaluated[1].opts.targetQuality })
    assert.equals(4, #world.evaluated)
  end)
end)
