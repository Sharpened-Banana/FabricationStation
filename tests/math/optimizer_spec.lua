local ns = load_files({}, { "Math/Quality.lua", "Math/Optimizer.lua" })
local O = ns.Math.Optimizer
local Q = ns.Math.Quality
local function slot(i, q, w, prices) local items = {}
  for r, p in ipairs(prices) do items[r] = { itemID = i * 1000 + r, rank = r, price = p or nil, owned = 0, provided = 0 } end  -- false = no price
  return { slotIndex = i, quantity = q, weight = w, items = items } end
local function input(baseSkill, slots) return { maxQuality = 2, baseDifficulty = 700, baseSkill = baseSkill, maxReagentSkill = 280, slots = slots } end

-- Sum of allocated quantities per slotIndex.
local function perSlot(allocation)
  local sums = {}
  for _, row in ipairs(allocation) do sums[row.slotIndex] = (sums[row.slotIndex] or 0) + row.quantity end
  return sums
end

describe("Math.Optimizer", function()
  it("2-rank compositions", function()
    local c = O.Compositions(slot(1, 10, 48, {100, 300}))
    assert.equals(1000, c[0].cost); assert.equals(1400, c[4].cost); assert.equals(3000, c[20].cost)
  end)
  it("3-rank composition keeps the cheapest mix per unit count", function()
    local c = O.Compositions(slot(1, 4, 10, {10, 30, 45}))
    assert.equals(130, c[5].cost); assert.same({ [1]=1, [2]=1, [3]=2 }, c[5].counts)
  end)
  it("owned reagents are free up to their count", function()
    local s = slot(1, 10, 48, {100, 300}); s.items[2].owned = 5
    assert.equals(500, O.Compositions(s)[10].cost)
  end)
  it("cheapest allocation per reachable quality", function()
    local per = O.CheapestByQuality(input(500, { slot(1, 10, 48, {100, 300}), slot(2, 5, 32, {200, 300}) }))
    assert.equals(2000, per[1].reagentCost)
    assert.equals(3800, per[2].reagentCost); assert.equals(703, per[2].skill)
    assert.same({ {slotIndex=1,itemID=1001,quantity=3}, {slotIndex=1,itemID=1002,quantity=7},
                  {slotIndex=2,itemID=2001,quantity=1}, {slotIndex=2,itemID=2002,quantity=4} }, per[2].allocation)
  end)
  it("unreachable quality is absent", function()
    assert.is_nil(O.CheapestByQuality(input(400, { slot(1, 10, 48, {100, 300}), slot(2, 5, 32, {200, 300}) }))[2])
  end)
  it("unweighted_slot_fixed", function()
    assert.equals(100, O.CheapestByQuality(input(700, { slot(1, 2, 0, {500, 50}) }))[2].reagentCost)
  end)
  it("missing_rank_price", function()
    local per, missing = O.CheapestByQuality(input(500, { slot(1, 10, 48, {100, false}), slot(2, 5, 32, {200, 300}) }))
    assert.is_false(missing); assert.is_nil(per[2])           -- only 20 of 80 units left, 58 needed
    local _, missing2 = O.CheapestByQuality(input(500, { slot(1, 10, 48, {false, false}) }))
    assert.is_true(missing2)
  end)
  it("mixed_rank_slots", function()
    local per = O.CheapestByQuality(input(500, { slot(1, 10, 48, {100, 300}), slot(2, 4, 32, {10, 30, 45}) }))
    assert.is_table(per[2]); assert.is_true(per[2].skill >= 700)
  end)

  -- Beyond the brief's eight.
  it("every plan allocates exactly each slot's quantity", function()
    local slots = { slot(1, 10, 48, {100, 300}), slot(2, 4, 32, {10, 30, 45}), slot(3, 2, 0, {500, 50}), slot(4, 3, 16, {70}) }
    local per = O.CheapestByQuality(input(500, slots))
    assert.is_table(per[1]); assert.is_table(per[2])
    for q, plan in pairs(per) do
      local sums = perSlot(plan.allocation)
      for _, s in ipairs(slots) do assert.equals(s.quantity, sums[s.slotIndex], "quality " .. q .. " slot " .. s.slotIndex) end
    end
  end)
  it("every composition sums to the slot quantity, never more", function()
    for _, s in ipairs({ slot(1, 10, 48, {100, 300}), slot(2, 4, 32, {10, 30, 45}), slot(3, 2, 0, {500, 50}) }) do
      for units, comp in pairs(O.Compositions(s)) do
        local n = 0
        for _, c in pairs(comp.counts) do n = n + c end
        assert.equals(s.quantity, n, "slot " .. s.slotIndex .. " units " .. units)
      end
    end
  end)
  it("reported skill matches Quality.ReagentSkill for the allocation", function()
    local slots = { slot(1, 10, 48, {100, 300}), slot(2, 4, 32, {10, 30, 45}), slot(3, 3, 16, {70}) }
    local per = O.CheapestByQuality(input(500, slots))
    for q, plan in pairs(per) do
      assert.near(500 + Q.ReagentSkill(slots, plan.allocation, 280), plan.skill, 1e-9, "quality " .. q)
      assert.equals(q, (Q.Predict(plan.skill, 700, 2)))
    end
  end)
  it("each plan lands on its own quality, not a higher one", function()
    -- Rank 2 is cheaper than rank 1: the cheapest mix overall reaches quality 2, so quality 1's plan is the
    -- cheapest mix that stays below the threshold (7 of rank 2 → skill 696), not the all-rank-2 mix.
    local per = O.CheapestByQuality(input(500, { slot(1, 10, 48, {300, 100}) }))
    assert.equals(1600, per[1].reagentCost); assert.equals(696, per[1].skill)
    assert.equals(1000, per[2].reagentCost); assert.equals(780, per[2].skill)
  end)
  it("base skill past every threshold leaves only the top quality", function()
    local per = O.CheapestByQuality(input(700, { slot(1, 10, 48, {100, 300}) }))
    assert.is_nil(per[1]); assert.equals(1000, per[2].reagentCost); assert.equals(700, per[2].skill)
  end)
  it("ties prefer more skill", function()
    local per = O.CheapestByQuality(input(500, { slot(1, 10, 48, {100, 100}) }))
    assert.equals(1000, per[1].reagentCost); assert.equals(696, per[1].skill)    -- 7 of rank 2, still quality 1
    assert.equals(1000, per[2].reagentCost); assert.equals(780, per[2].skill)    -- all rank 2
  end)
  it("owned reagents make higher ranks free in the plan", function()
    local s1 = slot(1, 10, 48, {100, 300}); s1.items[2].owned = 10
    local per = O.CheapestByQuality(input(500, { s1 }))
    assert.equals(0, per[2].reagentCost); assert.same({ {slotIndex=1,itemID=1002,quantity=10} }, per[2].allocation)
  end)
  it("an unpriced rank is usable up to what is owned", function()
    local s1 = slot(1, 10, 48, {100, false}); s1.items[2].owned = 10
    local per, missing = O.CheapestByQuality(input(500, { s1 }))
    assert.is_false(missing); assert.equals(0, per[2].reagentCost)
    assert.is_nil(O.Compositions(slot(1, 10, 48, {100, false}))[2])                -- not owned: unusable
  end)
  it("provided reagents fix their counts", function()
    local s1 = slot(1, 10, 48, {100, 300}); s1.items[1].provided = 10
    local c = O.Compositions(s1)
    assert.same({ 0 }, (function() local k = {}; for u in pairs(c) do k[#k + 1] = u end; return k end)())
    assert.equals(0, c[0].cost); assert.same({ [1] = 10 }, c[0].counts)
    local s2 = slot(1, 10, 48, {100, 300}); s2.items[2].provided = 4               -- partly provided: at least 4 of rank 2
    local c2 = O.Compositions(s2)
    assert.is_nil(c2[0]); assert.equals(600, c2[8].cost); assert.equals(1800, c2[20].cost)
  end)
  it("a slot with no priced option yields flagged plans with unknown cost", function()
    local per, missing = O.CheapestByQuality(input(500, { slot(1, 10, 48, {false, false}), slot(2, 5, 32, {200, 300}) }))
    assert.is_true(missing)
    assert.is_table(per[1]); assert.is_nil(per[1].reagentCost); assert.is_true(per[1].missingPrice)
    assert.same({ 10, 5 }, perSlot(per[1].allocation))
    assert.same({}, O.Compositions(slot(1, 10, 48, {false, false})))
  end)
  it("priced plans carry no missingPrice flag", function()
    local per = O.CheapestByQuality(input(500, { slot(1, 10, 48, {100, 300}) }))
    assert.is_nil(per[1].missingPrice); assert.is_nil(per[2].missingPrice)
  end)
  it("single-item weighted slot counts toward the denominator only", function()
    -- Units: 20 of 30 can come from slot 1; slot 2 (single item, weight 48) gives none but is in the denominator,
    -- so +100 skill needs 11 units (6 of rank 2), not 8 (4 of rank 2) as it would without slot 2.
    local per = O.CheapestByQuality(input(600, { slot(1, 10, 48, {100, 300}), slot(2, 5, 48, {70}) }))
    assert.equals(600 + 280 * 12 / 30, per[2].skill)
    assert.equals(400 + 1800 + 350, per[2].reagentCost)
  end)
  it("defaults maxReagentSkill to 0.40 x baseDifficulty and honours threshold fractions", function()
    local inp = input(500, { slot(1, 10, 48, {100, 300}) }); inp.maxReagentSkill = nil
    assert.near(724, O.CheapestByQuality(inp)[2].skill, 1e-9)                    -- 0.40 * 700 = 280: 16 of 20 units
    local inp2 = input(500, { slot(1, 10, 48, {100, 300}) }); inp2.thresholdFractions = { 0.75 }    -- q2 at 525
    assert.equals(1200, O.CheapestByQuality(inp2)[2].reagentCost)                  -- 1 of rank 2 → 528
  end)
  it("no weighted slots and no slots never divide by zero", function()
    local per = O.CheapestByQuality(input(500, { slot(1, 2, 0, {500, 50}) }))
    assert.equals(100, per[1].reagentCost); assert.equals(500, per[1].skill); assert.is_nil(per[2])
    local per2, missing = O.CheapestByQuality(input(500, {}))
    assert.is_false(missing); assert.equals(0, per2[1].reagentCost); assert.same({}, per2[1].allocation)
    local inp = input(500, { slot(1, 10, 48, {100, 300}) }); inp.maxReagentSkill = 0
    assert.is_nil(O.CheapestByQuality(inp)[2])
  end)
  it("unsupported maxQuality without fractions predicts quality 1 only", function()
    local inp = input(500, { slot(1, 10, 48, {100, 300}) }); inp.maxQuality = 4
    local per = O.CheapestByQuality(inp)
    assert.equals(1000, per[1].reagentCost); assert.is_nil(per[2])
  end)
  it("allocation cost", function()
    local s1, s2 = slot(1, 10, 48, {100, 300}), slot(2, 5, 32, {200, false})
    s1.items[2].owned = 3; s2.items[2].owned = 2
    local slots = { s1, s2 }
    assert.equals(300 + 4 * 300 + 5 * 200, O.AllocationCost(slots, { {slotIndex=1,itemID=1001,quantity=3}, {slotIndex=1,itemID=1002,quantity=7},
                                                                     {slotIndex=2,itemID=2001,quantity=5} }))
    assert.equals(600, O.AllocationCost(slots, { {slotIndex=2,itemID=2001,quantity=3}, {slotIndex=2,itemID=2002,quantity=2} }))  -- owned, unpriced: free
    assert.is_nil(O.AllocationCost(slots, { {slotIndex=2,itemID=2002,quantity=3} }))                                             -- buys an unpriced item
    assert.is_nil(O.AllocationCost(slots, { {slotIndex=1,itemID=9999,quantity=1} }))                                             -- unknown item
    assert.equals(0, O.AllocationCost(slots, { {slotIndex=7,itemID=7001,quantity=1} }))                                          -- not a required slot
    assert.equals(0, O.AllocationCost(slots, {}))
  end)
  it("fractional weights are rounded to integers and stay fast", function()
    local function slots(ws)
      local out = {}
      for i, w in ipairs(ws) do out[i] = slot(i, 10, w, { 100 + i, 200 + 3 * i, 300 + 7 * i }) end
      return out
    end
    local function run(ws)
      return O.CheapestByQuality({ maxQuality = 5, baseDifficulty = 700, baseSkill = 300, maxReagentSkill = 280, slots = slots(ws) })
    end
    local t = os.clock()
    local per = run({ 10.4, 20.2, 30.1, 40.3, 50.2, 59.6 })
    assert.is_true(os.clock() - t < 0.25, "took " .. (os.clock() - t) .. " s")
    assert.same(run({ 10, 20, 30, 40, 50, 60 }), per)
    -- A positive weight below 0.5 still counts: it rounds to 1, not to an unweighted 0.
    assert.same(O.CheapestByQuality(input(500, { slot(1, 10, 1, {100, 300}) })),
                O.CheapestByQuality(input(500, { slot(1, 10, 0.3, {100, 300}) })))
  end)
  it("allocation cost matches the plan's reagent cost", function()
    local slots = { slot(1, 10, 48, {100, 300}), slot(2, 4, 32, {10, 30, 45}), slot(3, 2, 0, {500, 50}) }
    for q, plan in pairs(O.CheapestByQuality(input(500, slots))) do
      assert.equals(plan.reagentCost, O.AllocationCost(slots, plan.allocation), "quality " .. q)
    end
  end)
end)
