local ns = load_files({}, { "Math/Quality.lua","Math/Concentration.lua","Math/Stats.lua","Math/Optimizer.lua","Math/Profit.lua" })
local P = ns.Math.Profit
local MID = { constant = { {0,200},{1000,200} }, curve = { {0,2.35},{0.6,2.2},{0.8,1.1},{0.9999,1.0},{1.0,0} } }
local function slot(i, q, w, prices) local items = {}
  for r, p in ipairs(prices) do items[r] = { itemID = i * 1000 + r, rank = r, price = p or nil, owned = 0, provided = 0 } end
  return { slotIndex = i, quantity = q, weight = w, items = items } end
local function scenario(over) local t = { maxQuality = 2, baseDifficulty = 700, baseSkill = 500, maxReagentSkill = 280,
  slots = { slot(1,10,48,{100,300}), slot(2,5,32,{200,300}), slot(3,2,0,{500}) }, optionals = {},
  stats = { multicraft = 0.2, resourcefulness = 0.25, ingenuity = 0.2 }, yield = { min = 1, max = 1 },
  outputPrices = { [1] = 60000, [2] = 100000 }, concentration = { curve = MID, lessFactors = {} } }
  for k, v in pairs(over or {}) do t[k] = v end; return t end
local ALL_TOP = { {slotIndex=1,itemID=1002,quantity=10}, {slotIndex=2,itemID=2002,quantity=5}, {slotIndex=3,itemID=3001,quantity=2} }
local ALL_LOW = { {slotIndex=1,itemID=1001,quantity=10}, {slotIndex=2,itemID=2001,quantity=5}, {slotIndex=3,itemID=3001,quantity=2} }
describe("Math.Profit", function()
  it("picks the most profitable plan without concentration", function()
    local r = P.EvaluateCraft(scenario())
    assert.equals(2, r.expectedQuality); assert.same({ [2] = 1 }, r.qualityChances)
    assert.equals(4800, r.reagentCost); assert.equals(124450, r.expectedSale)
    assert.equals(360, r.resourcefulnessValue); assert.equals(120010, r.profit)
    assert.equals(29450, r.multicraftValue); assert.near(1.31, r.expectedYield, 1e-9)
    assert.equals(71895, r.perQuality[1].profit)
  end)
  it("prices the concentration alternative", function()
    local r = P.EvaluateCraft(scenario())
    assert.equals(314, r.concentrationCost); assert.near(282.6, r.expectedConcentrationCost, 1e-9)
    assert.near(31.4, r.ingenuityValue, 1e-9); assert.equals(6, r.goldPerConcentration)    -- (121675 − 120010) / 282.6
  end)
  it("uses concentration when asked", function()
    local r = P.EvaluateCraft(scenario({ useConcentration = true }))
    assert.equals(2, r.expectedQuality); assert.equals(3000, r.reagentCost); assert.equals(121675, r.profit)
  end)
  it("honours targetQuality", function() assert.equals(71895, P.EvaluateCraft(scenario({ targetQuality = 1 })).profit) end)
  it("missing output price is flagged, never zero", function()
    local r = P.EvaluateCraft(scenario({ outputPrices = { [1] = 60000 } }))
    assert.equals(1, r.expectedQuality); assert.is_true(r.missingPrice)
    local r2 = P.EvaluateCraft(scenario({ outputPrices = {} }))
    assert.is_nil(r2.profit); assert.is_true(r2.missingPrice)
  end)
  it("EvaluateAllocation predicts a given allocation", function()
    local r = P.EvaluateAllocation(scenario(), { {slotIndex=1,itemID=1002,quantity=10}, {slotIndex=2,itemID=2002,quantity=5}, {slotIndex=3,itemID=3001,quantity=2} })
    assert.equals(780, r.skill); assert.equals(2, r.expectedQuality); assert.equals(5500, r.reagentCost)
    assert.equals(0, r.concentrationCostForAllocation)
  end)

  -- Beyond the brief.
  it("ExpectedSale applies the AH cut, weights chances and is nil without a needed price", function()
    assert.equals(95000, P.ExpectedSale({ [2] = 1 }, { [2] = 100000 }, 1))
    assert.equals(76000, P.ExpectedSale({ [1] = 0.5, [2] = 0.5 }, { [1] = 60000, [2] = 100000 }, 1))
    assert.is_nil(P.ExpectedSale({ [2] = 1 }, { [1] = 60000 }, 1))
    assert.equals(57000, P.ExpectedSale({ [1] = 1, [2] = 0 }, { [1] = 60000 }, 1))     -- a zero chance needs no price
    assert.equals(0.95, P.AH_CUT)
  end)
  it("result describes the returned allocation", function()
    local r = P.EvaluateCraft(scenario())
    assert.equals(700, r.difficulty); assert.same({ 700 }, r.thresholds)
    assert.equals(700, r.lowerThreshold); assert.is_nil(r.nextThreshold)
    assert.equals(4800, r.requiredCost); assert.is_false(r.missingPrice); assert.is_false(r.flags.noPrice)
    assert.near(500 + 280 * 928 / 1280, r.skill, 1e-9)
    assert.equals(0, r.concentrationCostForAllocation)                                   -- max quality: nothing to concentrate
    assert.equals(3000, r.perQuality[1].reagentCost); assert.equals(500, r.perQuality[1].skill)
    assert.equals(120010, r.perQuality[2].profit)
  end)
  it("concentration plan describes its own allocation", function()
    local r = P.EvaluateCraft(scenario({ useConcentration = true }))
    assert.equals(500, r.skill); assert.equals(0, r.lowerThreshold); assert.equals(700, r.nextThreshold)
    assert.equals(314, r.concentrationCost); assert.equals(314, r.concentrationCostForAllocation)
    assert.equals(6, r.goldPerConcentration); assert.same({ [2] = 1 }, r.qualityChances)
  end)
  it("unreachable_target_returns_best_with_flag", function()
    local r = P.EvaluateCraft(scenario({ baseSkill = 300, targetQuality = 2 }))          -- 300 + 280 < 700
    assert.equals(1, r.expectedQuality); assert.is_true(r.flags.unreachableTarget)
    assert.equals(3000, r.reagentCost)
    local r2 = P.EvaluateCraft(scenario({ targetQuality = 3 }))
    assert.equals(2, r2.expectedQuality); assert.is_true(r2.flags.unreachableTarget)
    local r3 = P.EvaluateCraft(scenario({ baseSkill = 300, targetQuality = 2, useConcentration = true }))
    assert.equals(2, r3.expectedQuality); assert.is_nil(r3.flags.unreachableTarget)  -- concentration reaches it
    assert.is_nil(P.EvaluateCraft(scenario({ targetQuality = 2 })).flags.unreachableTarget)
  end)
  describe("atLeastTarget: an order's minimum quality", function()
    -- Seen in game: Skinner's Cap, minimum quality 2 of 5, the patron providing top-rank reagents. Base 70 + 80 = 150
    -- against 200 is quality 3 with nothing to choose, so no plan lands on 2 exactly; the row said "cannot be reached,
    -- even with concentration" and charged concentration it did not need.
    local TIERS = { 0.2, 0.5, 0.8, 1 }
    local function provided_top(over)
      local a, b = slot(1, 40, 10, { 100, 300 }), slot(2, 20, 10, { 100, 300 })
      a.items[2].provided, b.items[2].provided = 40, 20
      local t = { maxQuality = 5, baseDifficulty = 200, baseSkill = 70, maxReagentSkill = 80, thresholdFractions = TIERS,
        slots = { a, b }, stats = {}, outputPrices = { 1000, 2000, 3000, 4000, 5000 }, targetQuality = 2, atLeastTarget = true }
      for k, v in pairs(over or {}) do t[k] = v end
      return t
    end
    it("takes a plan above the minimum when none lands on it", function()
      local r = P.EvaluateCraft(provided_top())
      assert.equals(3, r.expectedQuality); assert.is_nil(r.flags.unreachableTarget)
      assert.is_false(r.concentrated)
    end)
    it("needs no concentration for it either, when asked with concentration", function()
      local r = P.EvaluateCraft(provided_top({ useConcentration = true }))
      assert.equals(3, r.expectedQuality); assert.is_nil(r.flags.unreachableTarget)
      assert.is_false(r.concentrated)
    end)
    it("takes the lowest quality above the minimum: the cheapest reagents, not the best", function()
      local inp = scenario({ maxQuality = 5, baseDifficulty = 200, baseSkill = 110, maxReagentSkill = 80,
        thresholdFractions = TIERS, outputPrices = { 1000, 2000, 3000, 4000, 5000 }, targetQuality = 2, atLeastTarget = true })
      local r = P.EvaluateCraft(inp)
      assert.equals(3, r.expectedQuality); assert.is_nil(r.flags.unreachableTarget)
      assert.equals(r.perQuality[3].reagentCost, r.reagentCost)
    end)
    it("still takes the plan on the minimum when there is one", function()
      local r = P.EvaluateCraft(scenario({ targetQuality = 1, atLeastTarget = true }))
      assert.equals(1, r.expectedQuality); assert.is_nil(r.flags.unreachableTarget)
    end)
    it("is still unreachable when nothing reaches the minimum", function()
      local r = P.EvaluateCraft(provided_top({ targetQuality = 4 }))
      assert.equals(3, r.expectedQuality); assert.is_true(r.flags.unreachableTarget)
    end)
    it("leaves an exact target as it was: an item of that quality is not another quality's item", function()
      local r = P.EvaluateCraft(provided_top({ atLeastTarget = false }))
      assert.equals(3, r.expectedQuality); assert.is_true(r.flags.unreachableTarget)
    end)
  end)
  it("targetQuality with concentration takes that quality's concentration plan", function()
    local r = P.EvaluateCraft(scenario({ targetQuality = 2, useConcentration = true }))
    assert.equals(2, r.expectedQuality); assert.equals(3000, r.reagentCost); assert.equals(121675, r.profit)
    local r1 = P.EvaluateCraft(scenario({ targetQuality = 1, useConcentration = true }))  -- nothing concentrates to 1
    assert.equals(1, r1.expectedQuality); assert.equals(71895, r1.profit); assert.is_nil(r1.flags.unreachableTarget)
  end)
  it("says whether the chosen plan spends concentration", function()
    assert.is_false(P.EvaluateCraft(scenario()).concentrated)                              -- plain best
    assert.is_true(P.EvaluateCraft(scenario({ targetQuality = 2, useConcentration = true })).concentrated)
    assert.is_false(P.EvaluateCraft(scenario({ targetQuality = 1, useConcentration = true })).concentrated)  -- plain fallback
    assert.is_false(P.EvaluateCraft(scenario({ targetQuality = 2 })).concentrated)
    assert.is_true(P.EvaluateAllocation(scenario({ useConcentration = true }), ALL_LOW).concentrated)
    assert.is_false(P.EvaluateAllocation(scenario({ useConcentration = true }), ALL_TOP).concentrated)   -- already top
  end)
  it("a slot with no priced option gives no profit and flags noPrice", function()
    local r = P.EvaluateCraft(scenario({ slots = { slot(1,10,48,{100,300}), slot(2,5,32,{200,300}), slot(3,2,0,{false}) } }))
    assert.is_nil(r.profit); assert.is_nil(r.reagentCost); assert.is_nil(r.requiredCost)
    assert.is_true(r.missingPrice); assert.is_true(r.flags.noPrice)
    assert.is_nil(r.resourcefulnessValue); assert.is_nil(r.goldPerConcentration)
    assert.is_nil(r.perQuality[2].profit); assert.is_nil(r.perQuality[2].reagentCost)
  end)
  it("plans with no profit never beat priced plans", function()
    local r = P.EvaluateCraft(scenario({ outputPrices = { [1] = 1 } }))              -- q1 sells at a loss, q2 unpriced
    assert.equals(1, r.expectedQuality); assert.is_true(r.profit < 0); assert.is_true(r.missingPrice)
    assert.is_nil(r.goldPerConcentration)                                              -- concentration plan (q2) unpriced
    local rc = P.EvaluateCraft(scenario({ outputPrices = { [1] = 1 }, useConcentration = true }))
    assert.equals(2, rc.expectedQuality); assert.is_nil(rc.profit); assert.is_nil(rc.expectedSale)
  end)
  it("without a curve concentration costs are unknown, not zero", function()
    local r = P.EvaluateCraft(scenario({ concentration = { lessFactors = {} } }))
    assert.equals(120010, r.profit)
    assert.is_nil(r.concentrationCost); assert.is_nil(r.expectedConcentrationCost); assert.is_nil(r.ingenuityValue)
    assert.is_nil(r.goldPerConcentration); assert.is_nil(r.concentrationCostForAllocation)
    local rc = P.EvaluateCraft(scenario({ concentration = {}, useConcentration = true }))
    assert.equals(2, rc.expectedQuality); assert.equals(121675, rc.profit); assert.is_nil(rc.concentrationCost)
  end)
  it("a curve without points gives unknown concentration numbers instead of an error", function()
    for _, curve in ipairs({ { curve = MID.curve, constant = {} }, { curve = {}, constant = MID.constant } }) do
      local r
      assert.has_no.errors(function() r = P.EvaluateCraft(scenario({ concentration = { curve = curve, lessFactors = {} } })) end)
      assert.equals(120010, r.profit)
      assert.is_nil(r.concentrationCost); assert.is_nil(r.expectedConcentrationCost); assert.is_nil(r.goldPerConcentration)
      assert.is_nil(r.concentrationCostForAllocation)
      assert.has_no.errors(function() P.EvaluateAllocation(scenario({ concentration = { curve = curve } }), ALL_LOW) end)
    end
  end)
  it("costs a fixed slot marked noResourcefulness but saves nothing on it", function()
    local spark = slot(4, 1, 0, { 4000 }); spark.noResourcefulness = true
    local r = P.EvaluateCraft(scenario({ slots = { slot(1,10,48,{100,300}), slot(2,5,32,{200,300}), slot(3,2,0,{500}), spark } }))
    assert.equals(2, r.expectedQuality); assert.equals(8800, r.reagentCost)
    assert.equals(360, r.resourcefulnessValue); assert.equals(116010, r.profit)
    assert.same({ slotIndex = 4, itemID = 4001, quantity = 1 }, r.allocation[#r.allocation])
    local a = P.EvaluateAllocation(scenario({ slots = { slot(1,10,48,{100,300}), slot(2,5,32,{200,300}), slot(3,2,0,{500}), spark } }),
      { ALL_TOP[1], ALL_TOP[2], ALL_TOP[3], { slotIndex = 4, itemID = 4001, quantity = 1 } })
    assert.equals(9500, a.reagentCost); assert.equals(413, a.resourcefulnessValue)    -- 0.25 × 5500 × 0.3, the spark left out
  end)
  it("no concentration plan when every reachable quality is the top one", function()
    local r = P.EvaluateCraft(scenario({ baseSkill = 700 }))
    assert.equals(3000, r.reagentCost); assert.equals(2, r.expectedQuality); assert.is_nil(r.perQuality[1])
    assert.equals(0, r.concentrationCost); assert.equals(0, r.expectedConcentrationCost); assert.equals(0, r.ingenuityValue)
    assert.is_nil(r.goldPerConcentration)
    local r1 = P.EvaluateCraft(scenario({ maxQuality = 1, outputPrices = { [1] = 60000 } }))
    assert.equals(1, r1.expectedQuality); assert.equals(0, r1.concentrationCost); assert.equals(0, r1.concentrationCostForAllocation)
  end)
  it("optionals add skill, difficulty, stats, cost and less concentration", function()
    local opt = { itemID = 7001, price = 1000, stats = { skill = 50, increasedifficulty = 100, multicraft = 110, reduceconcentrationcost = 10 } }
    local r = P.EvaluateCraft(scenario({ maxReagentSkill = nil, optionals = { opt }, targetQuality = 1 }))
    assert.equals(800, r.difficulty); assert.same({ 800 }, r.thresholds)
    assert.equals(550, r.skill)                                                       -- 500 + 50, all rank 1
    assert.equals(4000, r.reagentCost); assert.equals(3000, r.requiredCost)
    assert.equals(225, r.resourcefulnessValue)                                        -- from the required cost only
    assert.near(1 + 0.3 * 1.55, r.expectedYield, 1e-9)                                -- multicraft 0.2 + 110 / 1100
    -- curve at 550/800 = 0.6875 → 2.2 − 1.1 × 0.4375 = 1.71875; × 200 = 343.75; − 10 % → 309.375 → 309
    assert.equals(309, r.concentrationCostForAllocation); assert.equals(309, r.concentrationCost)
    -- maxReagentSkill default comes from base difficulty: 0.40 × 700 = 280, so 550 + 280 = 830 ≥ 800 reaches q2
    local r2 = P.EvaluateCraft(scenario({ maxReagentSkill = nil, optionals = { opt }, targetQuality = 2 }))
    assert.equals(2, r2.expectedQuality); assert.is_nil(r2.flags.unreachableTarget)
    assert.is_true(r2.skill >= 800 and r2.skill <= 830)
  end)
  it("an unpriced optional makes the cost unknown", function()
    local r = P.EvaluateCraft(scenario({ optionals = { { itemID = 7001, stats = {} } } }))
    assert.is_nil(r.reagentCost); assert.is_nil(r.profit); assert.is_true(r.missingPrice)
    assert.equals(4800, r.requiredCost)
  end)
  it("EvaluateAllocation applies only the named optionals", function()
    local inp = scenario({ optionals = { { itemID = 7001, price = 1000, stats = { skill = 50 } },
                                         { itemID = 7002, price = 2000, stats = { increasedifficulty = 100 } } } })
    local r = P.EvaluateAllocation(inp, ALL_LOW, { 7001 })
    assert.equals(550, r.skill); assert.equals(700, r.difficulty); assert.equals(4000, r.reagentCost)
    local all = P.EvaluateAllocation(inp, ALL_LOW)
    assert.equals(550, all.skill); assert.equals(800, all.difficulty); assert.equals(6000, all.reagentCost)
    local none = P.EvaluateAllocation(inp, ALL_LOW, {})
    assert.equals(500, none.skill); assert.equals(3000, none.reagentCost)
  end)
  it("EvaluateAllocation flags an optional it does not know", function()
    local inp = scenario({ optionals = { { itemID = 7001, price = 1000, stats = { skill = 50 } } } })
    local r = P.EvaluateAllocation(inp, ALL_LOW, { 9999 })
    assert.is_nil(r.reagentCost); assert.is_nil(r.profit); assert.is_true(r.missingPrice)
    assert.is_true(r.flags.noPrice); assert.is_true(r.flags.unknownOptional)
    local mixed = P.EvaluateAllocation(inp, ALL_LOW, { 7001, 9999 })
    assert.equals(550, mixed.skill); assert.is_nil(mixed.reagentCost); assert.is_true(mixed.flags.unknownOptional)
    assert.is_nil(P.EvaluateAllocation(inp, ALL_LOW, { 7001 }).flags.unknownOptional)
  end)
  it("with targetQuality, gold per concentration compares against that quality's plain plan", function()
    -- 5 qualities, thresholds 140/350/560/700. Plain q1: 2000, skill 100, profit 7500; plain q2: 2300 (3 of slot 2 at
    -- rank 2), skill 142, profit 16700; plain q3: profit 52700 (the best plain plan). Concentrating q1 to q2: profit
    -- 17000 at 463 concentration (2.314286 × 200), expected 463 × 0.9 = 416.7.
    local inp = scenario({ maxQuality = 5, baseSkill = 100, slots = { slot(1,10,48,{100,300}), slot(2,5,32,{200,300}) },
      stats = { ingenuity = 0.2 }, outputPrices = { 10000, 20000, 60000, 80000, 90000 }, targetQuality = 2, useConcentration = true })
    local r = P.EvaluateCraft(inp)
    assert.equals(2, r.expectedQuality); assert.equals(17000, r.profit); assert.equals(2000, r.reagentCost)
    assert.equals(16700, r.perQuality[2].profit); assert.equals(52700, r.perQuality[3].profit)
    assert.equals(463, r.concentrationCost); assert.near(416.7, r.expectedConcentrationCost, 1e-9)
    assert.equals(1, r.goldPerConcentration)                                             -- (17000 − 16700) / 416.7, not (17000 − 52700) / 416.7
    inp.targetQuality = 5                                                                -- no plain plan at the target: best plain plan
    local r5 = P.EvaluateCraft(inp)
    assert.is_true(r5.flags.unreachableTarget); assert.equals(4, r5.expectedQuality)
  end)
  it("EvaluateAllocation prices the allocation and its concentration", function()
    local r = P.EvaluateAllocation(scenario(), ALL_LOW)
    assert.equals(1, r.expectedQuality); assert.equals(0, r.lowerThreshold); assert.equals(700, r.nextThreshold)
    assert.equals(71895, r.profit); assert.equals(314, r.concentrationCostForAllocation)
    assert.equals(314, r.concentrationCost); assert.equals(176, r.goldPerConcentration)  -- (121675 − 71895) / 282.6
  end)
  it("EvaluateAllocation with concentration adds a quality", function()
    local r = P.EvaluateAllocation(scenario({ useConcentration = true }), ALL_LOW)
    assert.equals(2, r.expectedQuality); assert.same({ [2] = 1 }, r.qualityChances)
    assert.equals(500, r.skill); assert.equals(121675, r.profit); assert.equals(314, r.concentrationCostForAllocation)
    local top = P.EvaluateAllocation(scenario({ useConcentration = true }), ALL_TOP)
    assert.equals(2, top.expectedQuality); assert.equals(0, top.concentrationCostForAllocation)
  end)
  it("EvaluateAllocation with an unknown item has no cost", function()
    local r = P.EvaluateAllocation(scenario(), { {slotIndex=1,itemID=9999,quantity=10} })
    assert.is_nil(r.reagentCost); assert.is_nil(r.profit); assert.is_true(r.missingPrice)
  end)
end)
