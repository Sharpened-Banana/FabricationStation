local ns = load_files({}, { "Math/Quality.lua", "Math/Concentration.lua", "Math/Stats.lua", "Math/Optimizer.lua",
  "Math/Profit.lua", "Math/Optionals.lua" })
local Optionals, Profit = ns.Math.Optionals, ns.Math.Profit
local MID = { constant = { {0,200},{1000,200} }, curve = { {0,2.35},{0.6,2.2},{0.8,1.1},{0.9999,1.0},{1.0,0} } }
local G = 10000   -- copper per gold

local function slot(i, q, w, prices) local items = {}
  for r, p in ipairs(prices) do items[r] = { itemID = i * 1000 + r, rank = r, price = p, owned = 0, provided = 0 } end
  return { slotIndex = i, quantity = q, weight = w, items = items } end

-- A hand-built RecipeInput: skill 400 + at most 280 from reagents never reaches Q2 (difficulty 700) on its own.
-- Optional slot 3: 701 (+30 skill: reaches Q2, 10g) and 702 (+110 multicraft rating, 50g: less than it costs).
-- Slot 4: 703 (no price). Slot 5: 704 (no modelled effect).
local function make_input(over)
  local t = { maxQuality = 2, baseDifficulty = 700, baseSkill = 400, maxReagentSkill = 280,
    slots = { slot(1, 10, 48, { 100, 300 }), slot(2, 5, 32, { 200, 300 }) },
    stats = {}, yield = { min = 1, max = 1 }, outputPrices = { [1] = 60 * G, [2] = 100 * G },
    concentration = { curve = MID, lessFactors = {} },
    optionals = {
      { itemID = 701, price = 10 * G, stats = { skill = 30 } },
      { itemID = 702, price = 50 * G, stats = { multicraft = 110 } },
      { itemID = 703, stats = { multicraft = 500 } },
      { itemID = 704, price = 1000, stats = {} },
    },
    optionalSlots = {
      { slotIndex = 3, kind = "optional", quantity = 1, itemIDs = { 701, 702 } },
      { slotIndex = 4, kind = "optional", quantity = 1, itemIDs = { 703 } },
      { slotIndex = 5, kind = "finishing", quantity = 1, itemIDs = { 704 } },
    } }
  for k, v in pairs(over or {}) do t[k] = v end
  return t
end

-- Two slots whose optionals reach Q2 only together (+15 skill each), so one slot at a time picks neither.
local function pair_input()
  return make_input({
    optionals = { { itemID = 801, price = 1 * G, stats = { skill = 15 } }, { itemID = 802, price = 1 * G, stats = { skill = 15 } } },
    optionalSlots = { { slotIndex = 3, kind = "optional", quantity = 1, itemIDs = { 801 } },
                      { slotIndex = 4, kind = "finishing", quantity = 1, itemIDs = { 802 } } },
  })
end

-- Seven slots of one candidate each: 2^7 = 128 combinations.
local function wide_input()
  local optionals, slots = {}, {}
  for i = 1, 7 do
    optionals[i] = { itemID = 900 + i, price = 1000, stats = { skill = 1 } }
    slots[i] = { slotIndex = 2 + i, kind = "optional", quantity = 1, itemIDs = { 900 + i } }
  end
  return make_input({ optionals = optionals, optionalSlots = slots })
end

describe("Math.Optionals", function()
  local input
  before_each(function() input = make_input() end)

  it("picks the optional that raises profit most", function()
    local r = Optionals.Best(input, { mode = "simple" })
    assert.same({ 701 }, r.itemIDs); assert.is_true(r.result.profit > r.base.profit)
    assert.equals(2, r.result.expectedQuality); assert.equals(1, r.base.expectedQuality)
    assert.equals("simple", r.mode)
  end)
  it("never picks an optional without a price and counts it", function()
    local r = Optionals.Best(input, { mode = "simple" })
    assert.equals(1, r.skipped.unknownPrice)
    for _, id in ipairs(r.itemIDs) do assert.are_not.equal(703, id) end
  end)
  it("skips an optional whose effects are not modelled and counts it", function()
    local r = Optionals.Best(input, { mode = "permutation" })
    assert.equals(1, r.skipped.noEffect)
    for _, id in ipairs(r.itemIDs) do assert.are_not.equal(704, id) end
    -- a stats table of zeros models no effect either
    input.optionals[4].stats = { skill = 0, multicraft = 0 }
    assert.equals(1, Optionals.Best(input, { mode = "simple" }).skipped.noEffect)
  end)
  it("picks nothing when no optional beats none", function()
    input.optionals[1].price = 1000 * G
    local r = Optionals.Best(input, { mode = "permutation" })
    assert.same({}, r.itemIDs); assert.equals(r.base.profit, r.result.profit)
    assert.same(Profit.EvaluateCraft(make_input({ optionals = {} })).profit, r.base.profit)
  end)
  it("tries every combination when there are 64 or fewer", function()
    local r = Optionals.Best(pair_input(), { mode = "permutation" })
    assert.equals("permutation", r.mode); assert.same({ 801, 802 }, r.itemIDs)
    assert.equals(4, r.evaluated)                               -- (1 + 1) × (1 + 1), the base included
    assert.equals(2, r.result.expectedQuality)
    local s = Optionals.Best(pair_input(), { mode = "simple" })
    assert.same({}, s.itemIDs); assert.equals("simple", s.mode)
  end)
  it("falls back to one slot at a time above 64 combinations", function()
    assert.equals("simple", Optionals.Best(wide_input(), { mode = "permutation" }).mode)
    assert.equals("permutation", Optionals.Best(wide_input(), { mode = "permutation", maxCombinations = 128 }).mode)
  end)
  it("keeps the fewer optionals on a tie", function()
    -- 902 is free and changes nothing the profit sees (ingenuity without concentration)
    local tie = make_input({
      optionals = { { itemID = 901, price = 0, stats = { skill = 30 } }, { itemID = 902, price = 0, stats = { ingenuity = 100 } } },
      optionalSlots = { { slotIndex = 3, kind = "optional", quantity = 1, itemIDs = { 901 } },
                        { slotIndex = 4, kind = "optional", quantity = 1, itemIDs = { 902 } } },
    })
    assert.same({ 901 }, Optionals.Best(tie, { mode = "permutation" }).itemIDs)
    assert.same({ 901 }, Optionals.Best(tie, { mode = "simple" }).itemIDs)
  end)
  it("returns the base when the output price is unknown", function()
    input.outputPrices = {}
    local r = Optionals.Best(input, { mode = "permutation" })
    assert.same({}, r.itemIDs); assert.equals(r.base, r.result); assert.is_nil(r.base.profit)
  end)

  -- Beyond the brief.
  it("takes the smaller item list on an equal profit and count", function()
    local twin = make_input({
      optionals = { { itemID = 712, price = 1 * G, stats = { skill = 30 } }, { itemID = 711, price = 1 * G, stats = { skill = 30 } } },
      optionalSlots = { { slotIndex = 3, kind = "optional", quantity = 1, itemIDs = { 712, 711 } } },
    })
    assert.same({ 711 }, Optionals.Best(twin, { mode = "simple" }).itemIDs)
    assert.same({ 711 }, Optionals.Best(twin, { mode = "permutation" }).itemIDs)
  end)
  it("counts an item listed in two slots once and never picks it twice", function()
    local dup = make_input({
      optionals = { { itemID = 701, price = 1 * G, stats = { skill = 30 } }, { itemID = 703, stats = { skill = 5 } } },
      optionalSlots = { { slotIndex = 3, kind = "optional", quantity = 1, itemIDs = { 701, 703 } },
                        { slotIndex = 4, kind = "optional", quantity = 1, itemIDs = { 701, 703 } } },
    })
    for _, mode in ipairs({ "simple", "permutation" }) do
      local r = Optionals.Best(dup, { mode = mode })
      assert.same({ 701 }, r.itemIDs, mode); assert.equals(1, r.skipped.unknownPrice, mode)
    end
  end)
  it("defaults to one slot at a time and leaves the input unchanged", function()
    local before = #input.optionals
    local r = Optionals.Best(input)
    assert.equals("simple", r.mode); assert.same({ 701 }, r.itemIDs)
    assert.equals(before, #input.optionals)
  end)
  describe("Place (the one slot-matching rule)", function()
    local SHARED = { { slotIndex = 4, kind = "optional", quantity = 2, itemIDs = { 7001, 7002 } },
                     { slotIndex = 6, kind = "optional", quantity = 1, itemIDs = { 7001 } } }
    it("places a shared item across two slots once, freeing the slot the other item needs", function()
      local rows, unplaced = Optionals.Place(SHARED, { 7001, 7002 })
      assert.same({ { slotIndex = 4, itemID = 7002, quantity = 2 }, { slotIndex = 6, itemID = 7001, quantity = 1 } }, rows)
      assert.same({}, unplaced)
      rows, unplaced = Optionals.Place(SHARED, { 7001 })
      assert.same({ { slotIndex = 4, itemID = 7001, quantity = 2 } }, rows); assert.same({}, unplaced)
    end)
    it("places one of two items wanted for one slot and reports the other", function()
      local rows, unplaced = Optionals.Place({ SHARED[1] }, { 7002, 7001 })
      assert.same({ { slotIndex = 4, itemID = 7001, quantity = 2 } }, rows); assert.same({ 7002 }, unplaced)
    end)
    it("reports an item no slot lists and ignores a repeated one", function()
      local rows, unplaced = Optionals.Place(SHARED, { 424242, 7002, 7002 })
      assert.same({ { slotIndex = 4, itemID = 7002, quantity = 2 } }, rows); assert.same({ 424242 }, unplaced)
      assert.same({}, (Optionals.Place(nil, {}))); assert.same({ 1 }, select(2, Optionals.Place(nil, { 1 })))
    end)
  end)
  it("never returns an unplaceable set, and returns its placement", function()
    -- 701 is listed in both slots, 702 only in the first: both are worth having, so both must be placed
    local shared = make_input({
      optionals = { { itemID = 701, price = 1 * G, stats = { skill = 30 } }, { itemID = 702, price = 1 * G, stats = { multicraft = 110 } } },
      optionalSlots = { { slotIndex = 3, kind = "optional", quantity = 1, itemIDs = { 701, 702 } },
                        { slotIndex = 4, kind = "optional", quantity = 1, itemIDs = { 701 } } },
    })
    for _, mode in ipairs({ "simple", "permutation" }) do
      local r = Optionals.Best(shared, { mode = mode })
      local _, unplaced = Optionals.Place(shared.optionalSlots, r.itemIDs)
      assert.same({}, unplaced, mode)
      assert.same(Optionals.Place(shared.optionalSlots, r.itemIDs), r.allocation, mode)
    end
    assert.same({ 701, 702 }, Optionals.Best(shared, { mode = "permutation" }).itemIDs)
    local one = make_input({ optionalSlots = { { slotIndex = 3, kind = "optional", quantity = 1, itemIDs = { 701, 702 } } } })
    local r = Optionals.Best(one, { mode = "permutation" })
    assert.equals(1, #r.itemIDs); assert.equals(1, #r.allocation)
  end)
  it("returns the base for an input without optional slots", function()
    input.optionalSlots = nil
    local r = Optionals.Best(input, { mode = "permutation" })
    assert.same({}, r.itemIDs); assert.equals(r.base, r.result); assert.equals(1, r.evaluated)
    assert.same({ unknownPrice = 0, noEffect = 0 }, r.skipped)
  end)
end)
