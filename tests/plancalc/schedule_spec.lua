local ns = load_files({}, { "Modules/PlanCalc.lua" })
local P = ns.PlanCalc
local NOW = 1793361600 -- Fri 2026-10-30 12:00 UTC

local function r(id, cost, gpc, flags)
  return { recipeID = id, charKey = "A", skillLineID = 2907, concentrationCost = cost, goldPerConcentration = gpc,
    profit = 1, flags = flags or {} }
end

local function pool(charKey, value, max, fullAt, skillLineID)
  return { charKey = charKey, skillLineID = skillLineID or 2907, value = value, max = max, fullAt = fullAt }
end

describe("PlanCalc scheduler", function()
  describe("Schedule", function()
    it("greedy by gold/concentration with per-recipe cap", function()
      local rows = P.Schedule({ pool("A", 1000, 1000, NOW) },
        { r(1, 300, 50), r(2, 200, 80), r(3, 100, 10), r(4, 100, 500, { noPrice = true }), r(5, 0, 90) },
        { maxCraftsPerRecipe = 3 })
      assert.equal(3, #rows)
      assert.same({ 2, 1, 3 }, { rows[1].recipeID, rows[2].recipeID, rows[3].recipeID })
      assert.same({ 3, 600, 48000 }, { rows[1].crafts, rows[1].concentrationUsed, rows[1].expectedGain })
      assert.same({ 1, 300, 15000 }, { rows[2].crafts, rows[2].concentrationUsed, rows[2].expectedGain })
      assert.same({ 1, 100, 1000 }, { rows[3].crafts, rows[3].concentrationUsed, rows[3].expectedGain })
      assert.same({ "A", 2907, 80, NOW }, { rows[1].charKey, rows[1].skillLineID, rows[1].goldPerConcentration,
        rows[1].fullAt })
    end)

    it("most urgent pool first", function()
      local b = r(9, 100, 1); b.charKey = "B"
      local rows = P.Schedule({ pool("A", 100, 1000, NOW + 9000), pool("B", 100, 1000, NOW + 10) },
        { r(1, 100, 99), b }, { maxCraftsPerRecipe = 10 })
      assert.same({ "B", "A" }, { rows[1].charKey, rows[2].charKey })
    end)

    it("a pool without fullAt sorts after pools that fill", function()
      local b = r(9, 100, 1); b.charKey = "B"
      local rows = P.Schedule({ pool("A", 100, 1000, nil), pool("B", 100, 1000, NOW + 10) },
        { r(1, 100, 99), b }, { maxCraftsPerRecipe = 10 })
      assert.same({ "B", "A" }, { rows[1].charKey, rows[2].charKey })
      assert.is_nil(rows[2].fullAt)
    end)

    it("expectedGain uses expectedConcentrationCost (ingenuity refund); spending uses the full cost", function()
      local x = r(1, 200, 80); x.expectedConcentrationCost = 150
      local rows = P.Schedule({ pool("A", 1000, 1000, NOW) }, { x }, { maxCraftsPerRecipe = 3 })
      assert.same({ 3, 600, 36000 }, { rows[1].crafts, rows[1].concentrationUsed, rows[1].expectedGain })
    end)

    it("expectedGain is floored", function()
      local x = r(1, 3, 0.5); x.expectedConcentrationCost = 2.5
      local rows = P.Schedule({ pool("A", 3, 1000, NOW) }, { x }, { maxCraftsPerRecipe = 1 })
      assert.equal(1, rows[1].expectedGain) -- 1 * 0.5 * 2.5 = 1.25
    end)

    it("a pool with an unknown value (projection unavailable) schedules nothing", function()
      local rows = P.Schedule({ pool("A", nil, 1000, nil), pool("B", nil, nil, nil) }, { r(1, 100, 99) },
        { maxCraftsPerRecipe = 10 })
      assert.same({}, rows)
    end)

    it("a capped pool schedules from its full value", function()
      local rows = P.Schedule({ pool("A", 1000, 1000, NOW) }, { r(1, 250, 10) }, { maxCraftsPerRecipe = 10 })
      assert.same({ 4, 1000 }, { rows[1].crafts, rows[1].concentrationUsed })
    end)

    it("skips results with unknown gold/concentration, unknown recipes or no concentration cost", function()
      local rows = P.Schedule({ pool("A", 1000, 1000, NOW) }, {
        r(1, 100, nil), r(2, nil, 50), r(3, 100, 0), r(4, 100, -5), r(5, 100, 40, { unknownRecipe = true }),
        r(6, 100, 0 / 0), r(7, 100, 30),
      }, { maxCraftsPerRecipe = 10 })
      assert.equal(1, #rows)
      assert.equal(7, rows[1].recipeID)
    end)

    it("results are matched to the pool by character and skill line", function()
      local other = r(2, 100, 90); other.skillLineID = 2908
      local rows = P.Schedule({ pool("A", 300, 1000, NOW) }, { r(1, 100, 10), other }, { maxCraftsPerRecipe = 10 })
      assert.equal(1, #rows)
      assert.same({ 1, 3 }, { rows[1].recipeID, rows[1].crafts })
    end)

    it("equal gold/concentration breaks ties by recipeID", function()
      local rows = P.Schedule({ pool("A", 1000, 1000, NOW) }, { r(8, 100, 50), r(3, 100, 50) },
        { maxCraftsPerRecipe = 2 })
      assert.same({ 3, 8 }, { rows[1].recipeID, rows[2].recipeID })
    end)

    it("without maxCraftsPerRecipe there is no per-recipe cap", function()
      local rows = P.Schedule({ pool("A", 1000, 1000, NOW) }, { r(1, 100, 5) }, nil)
      assert.equal(10, rows[1].crafts)
    end)

    it("a fractional maxCraftsPerRecipe is rounded down", function()
      local rows = P.Schedule({ pool("A", 1000, 1000, NOW) }, { r(1, 100, 5) }, { maxCraftsPerRecipe = 2.7 })
      assert.equal(2, rows[1].crafts)
    end)

    it("a recipe too expensive for what is left is skipped, cheaper ones still fit", function()
      local rows = P.Schedule({ pool("A", 250, 1000, NOW) }, { r(1, 300, 90), r(2, 100, 10) },
        { maxCraftsPerRecipe = 10 })
      assert.equal(1, #rows)
      assert.same({ 2, 2, 200 }, { rows[1].recipeID, rows[1].crafts, rows[1].concentrationUsed })
    end)

    it("a duplicate pool is scheduled once", function()
      local rows = P.Schedule({ pool("A", 1000, 1000, NOW), pool("A", 1000, 1000, NOW) }, { r(1, 100, 5) },
        { maxCraftsPerRecipe = 3 })
      assert.equal(1, #rows)
    end)

    it("does not modify its inputs", function()
      local pools = { pool("A", 1000, 1000, NOW) }
      local results = { r(1, 300, 50), r(2, 200, 80) }
      P.Schedule(pools, results, { maxCraftsPerRecipe = 3 })
      assert.same({ 1, 2 }, { results[1].recipeID, results[2].recipeID })
      assert.same(pool("A", 1000, 1000, NOW), pools[1])
    end)

    it("empty or nil inputs give no rows", function()
      assert.same({}, P.Schedule({}, {}, {}))
      assert.same({}, P.Schedule(nil, nil, nil))
    end)
  end)

  describe("CapWarnings", function()
    it("lists capped and soon-full pools in order of fullAt", function()
      local w = P.CapWarnings({ { charKey = "C", value = 500, max = 1000, fullAt = NOW + 2 * 86400 },
        { charKey = "S", value = 900, max = 1000, fullAt = NOW + 3600 },
        { charKey = "F", value = 1000, max = 1000, fullAt = NOW },
        { charKey = "U", value = nil, max = nil } }, NOW, 86400)
      assert.equal(2, #w)
      assert.same({ "F", "capped" }, { w[1].charKey, w[1].status })
      assert.same({ "S", "soon" }, { w[2].charKey, w[2].status })
    end)

    it("keeps the pool fields and does not modify the pool", function()
      local p = { charKey = "S", skillLineID = 2907, value = 900, max = 1000, fullAt = NOW + 60, secondsToFull = 60 }
      local w = P.CapWarnings({ p }, NOW, 86400)
      assert.same({ charKey = "S", skillLineID = 2907, value = 900, max = 1000, fullAt = NOW + 60, secondsToFull = 60,
        status = "soon" }, w[1])
      assert.is_nil(p.status)
    end)

    it("a capped pool is listed as capped even without fullAt, ahead of soon pools", function()
      local w = P.CapWarnings({ { charKey = "S", value = 900, max = 1000, fullAt = NOW + 60 },
        { charKey = "F", value = 1000, max = 1000 } }, NOW, 86400)
      assert.same({ "F", "capped" }, { w[1].charKey, w[1].status })
      assert.same({ "S", "soon" }, { w[2].charKey, w[2].status })
    end)

    it("skips pools with an unknown value, an unknown or zero max, or an unknown fullAt below the cap", function()
      local w = P.CapWarnings({ { charKey = "V", value = nil, max = 1000, fullAt = NOW },
        { charKey = "M", value = 10, max = nil, fullAt = NOW },
        { charKey = "Z", value = 0, max = 0, fullAt = NOW },
        { charKey = "T", value = 10, max = 1000, fullAt = nil } }, NOW, 86400)
      assert.same({}, w)
    end)

    it("includes a pool that fills exactly at the window's end, not one after it", function()
      local w = P.CapWarnings({ { charKey = "E", value = 1, max = 2, fullAt = NOW + 86400 },
        { charKey = "L", value = 1, max = 2, fullAt = NOW + 86401 } }, NOW, 86400)
      assert.equal(1, #w)
      assert.equal("E", w[1].charKey)
    end)

    it("ties on fullAt sort by charKey, then skillLineID", function()
      local w = P.CapWarnings({ { charKey = "B", skillLineID = 1, value = 1000, max = 1000, fullAt = NOW },
        { charKey = "A", skillLineID = 2, value = 1000, max = 1000, fullAt = NOW },
        { charKey = "A", skillLineID = 1, value = 1000, max = 1000, fullAt = NOW } }, NOW, 86400)
      assert.same({ "A", 1, "A", 2, "B", 1 }, { w[1].charKey, w[1].skillLineID, w[2].charKey, w[2].skillLineID,
        w[3].charKey, w[3].skillLineID })
    end)

    it("without a clock only capped pools are listed", function()
      local w = P.CapWarnings({ { charKey = "S", value = 900, max = 1000, fullAt = NOW + 60 },
        { charKey = "F", value = 1000, max = 1000, fullAt = NOW } }, nil, nil)
      assert.equal(1, #w)
      assert.same({ "F", "capped" }, { w[1].charKey, w[1].status })
    end)

    it("nil pools give no warnings", function()
      assert.same({}, P.CapWarnings(nil, NOW, 86400))
    end)
  end)

  describe("RankSpecNodes", function()
    it("steps to next perk, ranks per point", function()
      local gains = { [1] = 5000, [2] = 1000 }
      local rows = P.RankSpecNodes({
        { pathID = 1, name = "Smelting", rank = 10, maxRank = 30, available = true, perkRanks = { 5, 15, 25 } },
        { pathID = 2, name = "Weapons", rank = 0, maxRank = 20, available = true, perkRanks = {} },
        { pathID = 3, name = "Locked", rank = 0, maxRank = 10, available = false, perkRanks = {} },
        { pathID = 4, name = "Maxed", rank = 10, maxRank = 10, available = true, perkRanks = {} },
      }, function(id) return gains[id] end, 5)
      assert.equal(2, #rows)
      assert.same({ 1, 5, 5000, 1000, true }, { rows[1].pathID, rows[1].points, rows[1].gain, rows[1].gainPerPoint,
        rows[1].affordable })
      assert.same({ 2, 5, 200, true }, { rows[2].pathID, rows[2].points, rows[2].gainPerPoint, rows[2].affordable })
      assert.same({ "Smelting", 10, 30 }, { rows[1].name, rows[1].rank, rows[1].maxRank })
    end)

    it("affordability", function()
      local rows = P.RankSpecNodes({ { pathID = 1, name = "x", rank = 0, maxRank = 3, available = true, perkRanks = {} } },
        function() return 30 end, 2)
      assert.same({ 3, 10, false }, { rows[1].points, rows[1].gainPerPoint, rows[1].affordable })
    end)

    it("asks gainFn for the step it ranks", function()
      local calls = {}
      P.RankSpecNodes({ { pathID = 7, name = "x", rank = 2, maxRank = 30, available = true, perkRanks = { 25, 4 } } },
        function(id, from, to) calls[#calls + 1] = { id, from, to }; return 1 end, 0)
      assert.same({ { 7, 2, 4 } }, calls) -- unsorted perkRanks: the smallest above rank wins
    end)

    it("a perk exactly at the current rank is passed; the step is capped at maxRank", function()
      local calls = {}
      P.RankSpecNodes({ { pathID = 1, name = "x", rank = 5, maxRank = 8, available = true, perkRanks = { 5 } },
        { pathID = 2, name = "y", rank = 5, maxRank = 8, available = true, perkRanks = { 12 } } },
        function(id, from, to) calls[id] = { from, to }; return 1 end, 0)
      assert.same({ 5, 8 }, calls[1])
      assert.same({ 5, 8 }, calls[2])
    end)

    it("drops known zero or negative gains", function()
      local rows = P.RankSpecNodes({ { pathID = 1, name = "x", rank = 0, maxRank = 3, available = true, perkRanks = {} },
        { pathID = 2, name = "y", rank = 0, maxRank = 3, available = true, perkRanks = {} } },
        function(id) return id == 1 and 0 or -10 end, 5)
      assert.same({}, rows)
    end)

    it("an unknown gain stays nil (never 0) and sorts after known gains", function()
      local rows = P.RankSpecNodes({ { pathID = 1, name = "x", rank = 0, maxRank = 3, available = true, perkRanks = {} },
        { pathID = 2, name = "y", rank = 0, maxRank = 3, available = true, perkRanks = {} },
        { pathID = 3, name = "z", rank = 0, maxRank = 3, available = true, perkRanks = {} } },
        function(id) if id == 2 then return 30 elseif id == 3 then return 0 / 0 end end, 5)
      assert.equal(3, #rows)
      assert.same({ 2, 30, 10 }, { rows[1].pathID, rows[1].gain, rows[1].gainPerPoint })
      assert.equal(1, rows[2].pathID)
      assert.is_nil(rows[2].gain)
      assert.is_nil(rows[2].gainPerPoint)
      assert.equal(3, rows[2].points)
      assert.equal(3, rows[3].pathID)
      assert.is_nil(rows[3].gain)
    end)

    it("an unknown unspent count gives affordable = nil", function()
      local rows = P.RankSpecNodes({ { pathID = 1, name = "x", rank = 0, maxRank = 3, available = true, perkRanks = {} } },
        function() return 30 end, nil)
      assert.is_nil(rows[1].affordable)
    end)

    it("skips candidates with unknown ranks and treats missing perkRanks as none", function()
      local rows = P.RankSpecNodes({ { pathID = 1, name = "x", rank = nil, maxRank = 3, available = true },
        { pathID = 2, name = "y", rank = 0, maxRank = nil, available = true },
        { pathID = 3, name = "z", rank = 0, maxRank = 9, available = true } },
        function() return 60 end, 5)
      assert.equal(1, #rows)
      assert.same({ 3, 5, 12 }, { rows[1].pathID, rows[1].points, rows[1].gainPerPoint })
    end)

    it("equal gain per point sorts by pathID", function()
      local rows = P.RankSpecNodes({ { pathID = 9, name = "x", rank = 0, maxRank = 3, available = true, perkRanks = {} },
        { pathID = 4, name = "y", rank = 0, maxRank = 3, available = true, perkRanks = {} } },
        function() return 30 end, 5)
      assert.same({ 4, 9 }, { rows[1].pathID, rows[2].pathID })
    end)

    it("nil candidates give no rows", function()
      assert.same({}, P.RankSpecNodes(nil, function() return 1 end, 5))
    end)
  end)
end)
