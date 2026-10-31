describe("CraftingData.BuildInput", function()
  local ns, world, CD, gd, schematic, calib
  local ALL_LOW = { { slotIndex = 1, itemID = 1001, quantity = 10 }, { slotIndex = 2, itemID = 2001, quantity = 5 },
                    { slotIndex = 3, itemID = 3001, quantity = 2 } }
  before_each(function()
    local _
    ns, _, world = make_world({ last = "Modules/Recipes.lua", calibrate = { ["Main-Realm"] = { 9001 } } })
    CD, gd = ns.CraftingData, ns.GameData
    schematic = world.schematics[9001]
    calib = ns.FS.db.global.recipeCalib["Main-Realm"][9001]
  end)

  it("matches the Math.Profit scenario with a calibration", function()
    local input = CD.BuildInput(gd, { schematic = schematic, calib = calib, prices = world.priceValues() })
    assert.equals(2, input.maxQuality); assert.equals(700, input.baseDifficulty); assert.equals(500, input.baseSkill)
    assert.equals(280, input.maxReagentSkill)
    assert.same({ multicraft = 0.2, resourcefulness = 0.25, ingenuity = 0.2 }, input.stats)
    assert.equals(3, #input.slots)
    assert.equals(48, input.slots[1].weight); assert.equals(32, input.slots[2].weight); assert.equals(0, input.slots[3].weight)
    assert.equals(10, input.slots[1].quantity); assert.equals(5, input.slots[2].quantity); assert.equals(2, input.slots[3].quantity)
    assert.same({ { itemID = 1001, rank = 1, price = 100, owned = 0, provided = 0 },
                  { itemID = 1002, rank = 2, price = 300, owned = 0, provided = 0 } }, input.slots[1].items)
    assert.equals(500, input.slots[3].items[1].price)
    assert.same({ 0.6, 2.2 }, input.concentration.curve.curve[2]); assert.same({}, input.concentration.lessFactors)
    assert.same({ 1.0 }, input.thresholdFractions)
    assert.same({ [1] = 60000, [2] = 100000 }, input.outputPrices)
    assert.same({ min = 1, max = 1 }, input.yield)
    assert.same({}, input.optionals)
    -- The Math.Profit scenario numbers follow.
    local r = ns.Math.Profit.EvaluateCraft(input)
    assert.equals(120010, r.profit); assert.equals(6, r.goldPerConcentration)
  end)

  it("uses the profession skill and no measured reagent skill without a calibration", function()
    local input = CD.BuildInput(gd, { schematic = schematic, professionSkill = 450, prices = world.priceValues() })
    assert.equals(450, input.baseSkill); assert.is_nil(input.maxReagentSkill); assert.same({}, input.stats)
    assert.equals(700, input.baseDifficulty)
    assert.same({ 0.6, 2.2 }, input.concentration.curve.curve[2])
  end)

  -- Beyond the brief.
  it("passes useConcentration and targetQuality, owned and provided counts", function()
    local input = CD.BuildInput(gd, { schematic = schematic, calib = calib, prices = world.priceValues(),
      owned = { [1001] = 4 }, provided = { [2002] = 5 }, useConcentration = true, targetQuality = 1 })
    assert.is_true(input.useConcentration); assert.equals(1, input.targetQuality)
    assert.equals(4, input.slots[1].items[1].owned); assert.equals(5, input.slots[2].items[2].provided)
    assert.equals(0, input.slots[1].items[2].owned)
  end)
  it("prefers the calibration's crafting data and falls back to the schematic's base difficulty", function()
    local c = { baseSkill = 400, craftingDataID = 2588, stats = {} }
    local s = {}
    for k, v in pairs(schematic) do s[k] = v end
    s.craftingDataID = nil
    local input = CD.BuildInput(gd, { schematic = s, calib = c, prices = {} })
    assert.equals(700, input.baseDifficulty); assert.same({ 1.0 }, input.thresholdFractions)
    assert.is_table(input.concentration.curve)
    assert.same({}, input.outputPrices)
    assert.is_nil(input.slots[1].items[1].price)
  end)
  it("leaves out optional, finishing, currency-only and empty slots", function()
    local slots = schematic.reagentSlots
    slots[#slots + 1] = { slotIndex = 4, quantity = 1, reagents = {}, kind = "basic", currencyID = 3008, dataSlotIndex = 14 }
    slots[#slots + 1] = { slotIndex = 5, quantity = 1, reagents = { 7001 }, kind = "optional", dataSlotIndex = 15 }
    slots[#slots + 1] = { slotIndex = 6, quantity = 1, reagents = { 7002 }, kind = "finishing", dataSlotIndex = 16 }
    slots[#slots + 1] = { slotIndex = 7, quantity = 1, kind = "basic", dataSlotIndex = 17 }
    local input = CD.BuildInput(gd, { schematic = schematic, calib = calib, prices = world.priceValues() })
    assert.equals(3, #input.slots)
  end)
  it("guards a missing or non-number maxQuality", function()
    for _, bad in ipairs({ "2", false }) do
      schematic.maxQuality = bad
      local input
      assert.has_no.errors(function() input = CD.BuildInput(gd, { schematic = schematic, calib = calib, prices = {} }) end)
      assert.is_nil(input.maxQuality); assert.is_nil(input.thresholdFractions)
      assert.has_no.errors(function() ns.Math.Profit.EvaluateCraft(input) end)
    end
    assert.is_nil(CD.ThresholdFractions(gd, 2588, "2")); assert.is_nil(CD.ThresholdFractions(gd, 2588, nil))
  end)
  it("works on empty GameData", function()
    for _, name in ipairs({ "ReagentQuality", "ReagentCategories", "OptionalReagents", "CraftingData",
      "ItemCraftingData", "QualityThresholds", "ConcentrationCurves" }) do gd.Define(name, nil, {}) end
    local input = CD.BuildInput(gd, { schematic = schematic, professionSkill = 500, prices = world.priceValues() })
    -- Ranked slots fall back to equal weights (H1-4), the single-rank slot stays 0.
    assert.same({ 1, 1, 0 }, { input.slots[1].weight, input.slots[2].weight, input.slots[3].weight })
    assert.is_true(input.missingWeights)
    assert.is_nil(input.thresholdFractions); assert.is_nil(input.concentration.curve)
    assert.has_no.errors(function() ns.Math.Profit.EvaluateCraft(input) end)
  end)

  describe("required non-basic slots (sparks)", function()
    before_each(function()
      local slots = schematic.reagentSlots
      slots[#slots + 1] = { slotIndex = 4, required = true, quantity = 1, reagents = { 7101, 7102 }, kind = "optional",
        dataSlotIndex = 14, dataSlotType = 2 }
    end)
    it("becomes a weight-0 slot that saves nothing on resourcefulness, priced like the others", function()
      local prices = world.priceValues(); prices[7101], prices[7102] = 5000, 4000
      local input = CD.BuildInput(gd, { schematic = schematic, calib = calib, prices = prices, owned = { [7101] = 1 } })
      assert.equals(4, #input.slots)
      local s = input.slots[4]
      assert.same({ 4, 1, 0, true, true }, { s.slotIndex, s.quantity, s.weight, s.noResourcefulness, s.singleItem })
      assert.same({ { itemID = 7101, rank = 1, price = 5000, owned = 1, provided = 0 },
                    { itemID = 7102, rank = 2, price = 4000, owned = 0, provided = 0 } }, s.items)
      assert.is_nil(input.slots[1].noResourcefulness); assert.is_nil(input.slots[1].singleItem)
      assert.is_false(input.missingWeights)
    end)
    it("is costed, allocated and kept out of resourcefulness by EvaluateCraft", function()
      local prices = world.priceValues(); prices[7101], prices[7102] = 5000, 4000
      local r = ns.Math.Profit.EvaluateCraft(CD.BuildInput(gd, { schematic = schematic, calib = calib, prices = prices }))
      assert.equals(8800, r.reagentCost); assert.equals(116010, r.profit); assert.equals(360, r.resourcefulnessValue)
      assert.same({ slotIndex = 4, itemID = 7102, quantity = 1 }, r.allocation[#r.allocation])
    end)
    it("is filled with one item even when the slot takes two or more (no mixed sparks)", function()
      schematic.reagentSlots[4].quantity = 2
      local prices = world.priceValues(); prices[7101], prices[7102] = 5000, 4000
      local r = ns.Math.Profit.EvaluateCraft(CD.BuildInput(gd, { schematic = schematic, calib = calib, prices = prices,
        owned = { [7101] = 1 } }))
      local rows = {}
      for _, row in ipairs(r.allocation) do if row.slotIndex == 4 then rows[#rows + 1] = row end end
      assert.same({ { slotIndex = 4, itemID = 7101, quantity = 2 } }, rows)
    end)
    it("is not offered as an optional candidate", function()
      local input = CD.BuildInput(gd, { schematic = schematic, calib = calib, prices = world.priceValues(), optionalItemIDs = {} })
      assert.same({}, input.optionals)
    end)
    it("an unpriced spark makes the cost unknown, never free", function()
      local r = ns.Math.Profit.EvaluateCraft(CD.BuildInput(gd, { schematic = schematic, calib = calib, prices = world.priceValues() }))
      assert.is_nil(r.reagentCost); assert.is_nil(r.profit); assert.is_true(r.missingPrice)
    end)
  end)

  describe("missing reagent weights", function()
    it("flags a basic slot with two or more ranks but no GameData weight, and gives it the known weights' mean", function()
      gd.Define("ReagentQuality", 70575, { [2001] = { rank = 1, categoryID = 2 }, [2002] = { rank = 2, categoryID = 2 } })
      local input = CD.BuildInput(gd, { schematic = schematic, calib = calib, prices = world.priceValues() })
      assert.equals(32, input.slots[1].weight); assert.equals(32, input.slots[2].weight); assert.is_true(input.missingWeights)
    end)
    it("does not flag single-rank slots", function()
      local input = CD.BuildInput(gd, { schematic = schematic, calib = calib, prices = world.priceValues() })
      assert.equals(0, input.slots[3].weight); assert.is_false(input.missingWeights)
    end)
  end)

  describe("optional candidates", function()
    before_each(function()
      gd.Define("ReagentQuality", 70575, {
        [1001] = { rank = 1, categoryID = 1 }, [1002] = { rank = 2, categoryID = 1 },
        [2001] = { rank = 1, categoryID = 2 }, [2002] = { rank = 2, categoryID = 2 },
        [7001] = { rank = 1, categoryID = 60, maxDifficultyAdjustment = 35 },
        [7003] = { rank = 1, categoryID = 61, reagentEffectPct = 50 },
      })
      gd.Define("OptionalReagents", 70575, {
        [7002] = { categoryID = 60, effects = { { type = "skill", amount = 20 } } },
        [7003] = { categoryID = 61, effects = { { type = "multicraft", amount = 60 } } },
      })
      local slots = schematic.reagentSlots
      slots[#slots + 1] = { slotIndex = 4, quantity = 1, reagents = { 7001, 7002 }, kind = "optional", dataSlotIndex = 14 }
      slots[#slots + 1] = { slotIndex = 5, quantity = 1, reagents = { 7003 }, kind = "finishing", dataSlotIndex = 15 }
    end)
    it("lists every candidate's stats and price when optionals are selected", function()
      local prices = world.priceValues(); prices[7001], prices[7002] = 1000, 2000
      local input = CD.BuildInput(gd, { schematic = schematic, calib = calib, prices = prices, optionalItemIDs = { 7002 } })
      assert.same({
        { itemID = 7001, price = 1000, stats = { increasedifficulty = 35 } },
        { itemID = 7002, price = 2000, stats = { skill = 20 } },
        { itemID = 7003, stats = { multicraft = 30 } },
      }, input.optionals)
      local r = ns.Math.Profit.EvaluateAllocation(input, ALL_LOW, { 7002 })
      assert.is_nil(r.flags.unknownOptional); assert.equals(520, r.skill); assert.equals(5000, r.reagentCost)
    end)
    it("lists none when no optionals are selected, so EvaluateCraft applies none", function()
      local input = CD.BuildInput(gd, { schematic = schematic, calib = calib, prices = world.priceValues() })
      assert.same({}, input.optionals)
    end)
    it("prices an owned or provided optional at zero", function()
      local prices = world.priceValues(); prices[7001], prices[7002] = 1000, 2000
      local input = CD.BuildInput(gd, { schematic = schematic, calib = calib, prices = prices, optionalItemIDs = {},
        owned = { [7001] = 1 }, provided = { [7003] = 1 } })
      assert.equals(0, input.optionals[1].price); assert.equals(2000, input.optionals[2].price)
      assert.equals(0, input.optionals[3].price)
    end)
    it("prices an optional for the copies the slot still needs, not one unit", function()
      schematic.reagentSlots[4].quantity = 2
      local prices = world.priceValues(); prices[7001], prices[7002] = 1000, 2000
      local input = CD.BuildInput(gd, { schematic = schematic, calib = calib, prices = prices, optionalItemIDs = {} })
      assert.equals(2000, input.optionals[1].price); assert.equals(4000, input.optionals[2].price)
      input = CD.BuildInput(gd, { schematic = schematic, calib = calib, prices = prices, optionalItemIDs = {},
        owned = { [7001] = 1 }, provided = { [7002] = 2 } })
      assert.equals(1000, input.optionals[1].price); assert.equals(0, input.optionals[2].price)
    end)
  end)
end)
