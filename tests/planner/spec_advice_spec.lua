local FILES = { "Modules/Alts.lua", "Modules/AltsCollector.lua", "Modules/CraftingData.lua", "Modules/Planner.lua",
  "Modules/PlannerSpec.lua" }

local function planner(ns) return ns.FS:GetModule("Planner") end
local function alts(ns) return ns.FS:GetModule("Alts") end
local function char(ns, key) return ns.FS.db.global.characters[key] end

-- The brief's fixture: Aria's GetSpecSnapshot (phase3_fakes) gives unspent 4 and
--   1 = { "Path 1", rank 10, maxRank 30, available, perkRanks { 15 } },
--   2 = { "Path 2", rank 0, maxRank 20, available },
--   3 = { "Path 3", rank 5, maxRank 10, not available };
-- ranked profitable 1001 (profit 5000) and 1002 (profit 1000) on Blacksmithing (2907).
local function ranked()
  return {
    { recipeID = 1001, charKey = "Aria-Silvermoon", profit = 5000, flags = {} },
    { recipeID = 1002, charKey = "Aria-Silvermoon", profit = 1000, flags = {} },
  }
end

local function env(opts)
  opts = opts or {}
  return phase3_env({
    files = FILES,
    ranked = opts.ranked or ranked(),
    recipeLines = opts.recipeLines or { [1001] = 2907, [1002] = 2907, [1003] = 2907 },
    evaluate = opts.evaluate,
  })
end

-- The brief's stubs on the module table.
local function stub(PL, calls)
  PL._nodeBonus = function(_, _, _, pathID)
    return pathID == 1 and { skill = 5, recipes = { [1001] = true } } or { multicraft = 10 }
  end
  PL._evaluateWithBonus = function(_, recipeID, charKey, bonus)
    if calls then calls[#calls + 1] = recipeID end
    local base = ({ [1001] = 5000, [1002] = 1000 })[recipeID]
    return { recipeID = recipeID, charKey = charKey, profit = base + (bonus.skill and 2500 or 500), flags = {} }
  end
end

describe("Planner spec advice", function()
  local ns, PL
  before_each(function()
    ns = env()
    PL = planner(ns)
    stub(PL)
  end)

  it("ranks next nodes by profit gain per point", function()
    local rows = PL:GetSpecAdvice("Aria-Silvermoon", 2907)
    assert.same({1, "Path 1", 5, 2500, 500, false},  -- 5 points needed, 4 unspent
      {rows[1].pathID, rows[1].name, rows[1].points, rows[1].gain, rows[1].gainPerPoint, rows[1].affordable})
    assert.same({2, 5, 1000, 200}, {rows[2].pathID, rows[2].points, rows[2].gain, rows[2].gainPerPoint})
    assert.equal(2, #rows)
  end)

  it("no snapshot or no profitable recipes -> empty", function()
    assert.same({}, PL:GetSpecAdvice("Bren-Silvermoon", 2912))
  end)

  -- Beyond the brief.
  it("returns status \"ok\" with the rows, and the SpecAdviceRow fields", function()
    local rows, status = PL:GetSpecAdvice("Aria-Silvermoon", 2907)
    assert.equal("ok", status)
    assert.same({ pathID = 1, name = "Path 1", rank = 10, maxRank = 30, points = 5, gain = 2500, gainPerPoint = 500,
      affordable = false }, rows[1])
  end)

  it("statuses: noSpec, noProfession, noRecipes, hidden, off", function()
    assert.same({ {}, "noSpec" }, { PL:GetSpecAdvice("Bren-Silvermoon", 2912) })
    assert.same({ {}, "noProfession" }, { PL:GetSpecAdvice("Cato-Silvermoon", 2907) })
    assert.same({ {}, "noProfession" }, { PL:GetSpecAdvice("Nobody-Silvermoon", 2907) })
    char(ns, "Aria-Silvermoon").professions[2907].dropped = true
    assert.same({ {}, "noProfession" }, { PL:GetSpecAdvice("Aria-Silvermoon", 2907) })
    char(ns, "Aria-Silvermoon").professions[2907].dropped = nil

    local empty = env({ ranked = {} })
    stub(planner(empty))
    assert.same({ {}, "noRecipes" }, { planner(empty):GetSpecAdvice("Aria-Silvermoon", 2907) })

    alts(ns):SetHidden("Aria-Silvermoon", true)
    assert.same({ {}, "hidden" }, { PL:GetSpecAdvice("Aria-Silvermoon", 2907) })
    alts(ns):SetHidden("Aria-Silvermoon", false)

    alts(ns):Disable()
    assert.same({ {}, "off" }, { PL:GetSpecAdvice("Aria-Silvermoon", 2907) })
    alts(ns):Enable()
    ns.FS:GetModule("Recipes"):Disable()
    assert.same({ {}, "off" }, { PL:GetSpecAdvice("Aria-Silvermoon", 2907) })
  end)

  it("compares only the top specTopRecipes profitable results of the character's line", function()
    local list = ranked()
    list[3] = { recipeID = 1003, charKey = "Aria-Silvermoon", profit = 500, flags = {} }
    local e = env({ ranked = list })
    local calls = {}
    stub(planner(e), calls)
    local base = planner(e)._evaluateWithBonus
    planner(e)._evaluateWithBonus = function(self, id, ...)
      if id == 1003 then return { recipeID = id, profit = 500 + 100000, flags = {} } end
      return base(self, id, ...)
    end
    planner(e):Settings().specTopRecipes = 2
    local rows = planner(e):GetSpecAdvice("Aria-Silvermoon", 2907)
    assert.same({ 1, 2 }, { rows[1].pathID, rows[2].pathID })   -- 1003 (third by profit) is not compared
    assert.equal(1000, rows[2].gain)
  end)

  it("asks Recipes for the character's profitable results on the line, by profit", function()
    local e = env()
    stub(planner(e))
    local filters = {}
    local real = e.FS:GetModule("Recipes").GetRanked
    e.FS:GetModule("Recipes").GetRanked = function(self, filter)
      filters[#filters + 1] = filter
      return real(self, filter)
    end
    planner(e):GetSpecAdvice("Aria-Silvermoon", 2907)
    assert.same({ { charKey = "Aria-Silvermoon", skillLineID = 2907, onlyProfitable = true, sortBy = "profit" } },
      filters)
  end)

  it("drops results of another character even if Recipes returns them", function()
    local list = ranked()
    table.insert(list, 1, { recipeID = 1002, charKey = "Bren-Silvermoon", profit = 9000, flags = {} })
    local e = env({ ranked = list })
    stub(planner(e))
    e.FS:GetModule("Recipes").GetRanked = function() return list end      -- ignores the charKey filter
    local rows = planner(e):GetSpecAdvice("Aria-Silvermoon", 2907)
    assert.same({ 2500, 1000 }, { rows[1].gain, rows[2].gain })
  end)

  it("a what-if without a profit counts as no change", function()
    PL._evaluateWithBonus = function(_, recipeID) return recipeID == 1001 and { profit = nil, flags = {} } or nil end
    -- No gain anywhere: every known gain <= 0 is dropped.
    assert.same({ {}, "ok" }, { PL:GetSpecAdvice("Aria-Silvermoon", 2907) })
  end)

  it("a path whose bonus has no modelled stat has an unknown gain (nil), listed after known gains", function()
    PL._nodeBonus = function(_, _, _, pathID)
      return pathID == 1 and { skill = 5, recipes = { [1001] = true } } or { recipes = nil }
    end
    local rows = PL:GetSpecAdvice("Aria-Silvermoon", 2907)
    assert.equal(2, #rows)
    assert.same({ 1, 2500 }, { rows[1].pathID, rows[1].gain })
    assert.same({ 2, 5 }, { rows[2].pathID, rows[2].points })
    assert.is_nil(rows[2].gain); assert.is_nil(rows[2].gainPerPoint)
  end)

  it("keeps at most 5 rows", function()
    local paths = char(ns, "Aria-Silvermoon").professions[2907].spec.paths
    for id = 4, 10 do paths[id] = { rank = 1, maxRank = 21, state = 1, spendEntryID = 2000 + id } end
    assert.equal(5, #PL:GetSpecAdvice("Aria-Silvermoon", 2907))
  end)

  it("unspent unknown -> affordable nil", function()
    char(ns, "Aria-Silvermoon").professions[2907].spec.unspent = nil
    assert.is_nil(PL:GetSpecAdvice("Aria-Silvermoon", 2907)[1].affordable)
  end)

  describe("memo (preflight row 30)", function()
    local e, calls, R
    before_each(function()
      e = env()
      calls = {}
      stub(planner(e), calls)
      R = e.FS:GetModule("Recipes")
    end)

    it("a repeated call does not evaluate again and returns the same rows", function()
      local a = planner(e):GetSpecAdvice("Aria-Silvermoon", 2907)
      local n = #calls
      assert.is_true(n > 0)
      assert.equal(a, planner(e):GetSpecAdvice("Aria-Silvermoon", 2907))
      assert.equal(n, #calls)
    end)

    it("recomputes when the data stamp, the price version, the results, the spec or the setting change", function()
      local stamp, version = 1, 1
      R.GetDataStamp = function() return stamp end
      require("tests.helpers.phase2").fake_module(e, "Prices", { GetVersion = function() return version end })
      local function count()
        local before = #calls
        planner(e):GetSpecAdvice("Aria-Silvermoon", 2907)
        return #calls - before
      end
      assert.is_true(count() > 0); assert.equal(0, count())
      stamp = 2; assert.is_true(count() > 0); assert.equal(0, count())
      version = 2; assert.is_true(count() > 0); assert.equal(0, count())
      local list = ranked()
      R.GetRanked = function() return list end            -- a rescan: new result tables
      assert.is_true(count() > 0); assert.equal(0, count())
      char(e, "Aria-Silvermoon").professions[2907].spec.paths[1].rank = 12
      assert.is_true(count() > 0); assert.equal(0, count())
      planner(e):Settings().specTopRecipes = 1
      assert.is_true(count() > 0); assert.equal(0, count())
    end)

    it("is kept per character and line", function()
      planner(e):GetSpecAdvice("Aria-Silvermoon", 2907)
      local n = #calls
      planner(e):GetSpecAdvice("Bren-Silvermoon", 2912)
      assert.equal(n, #calls)
      planner(e):GetSpecAdvice("Aria-Silvermoon", 2907)
      assert.equal(n, #calls)
    end)
  end)
end)

describe("Planner spec advice adapters", function()
  local ns, PL
  before_each(function()
    ns = env()
    PL = planner(ns)
  end)

  it("_nodeBonus reads 1a SpecEntryEffects for the path ranks and perks crossed", function()
    ns.GameData.Define("SpecEntryEffects", 70575, { [1000] = { effects = { { type = "skill", amount = 1 } }, labels = { 777 } },
      [9000] = { effects = { { type = "multicraft", amount = 30 }, { type = "type42", amount = 9 } }, labels = { 777 } } })
    ns.GameData.Define("RecipeLabels", 70575, { [1001] = { 777 }, [1002] = { 5 } })
    assert.same({ skill = 5, multicraft = 30, recipes = { [1001] = true } }, PL:_nodeBonus("Aria-Silvermoon", 2907, 1, 10, 15))
    assert.same({ skill = 4, recipes = { [1001] = true } }, PL:_nodeBonus("Aria-Silvermoon", 2907, 1, 10, 14))   -- perk at 15 not crossed
  end)

  -- Beyond the brief.
  it("empty labels mean every recipe of the line (recipes nil, preflight row 29)", function()
    ns.GameData.Define("SpecEntryEffects", 70575, { [1000] = { effects = { { type = "resourcefulness", amount = 2 } },
      labels = {} } })
    ns.GameData.Define("RecipeLabels", 70575, { [1001] = { 777 } })
    assert.same({ resourcefulness = 6 }, PL:_nodeBonus("Aria-Silvermoon", 2907, 1, 10, 13))
  end)

  it("a perk crossed exactly at fromRank does not count again; one at toRank does", function()
    ns.GameData.Define("SpecEntryEffects", 70575,
      { [9000] = { effects = { { type = "skill", amount = 7 } }, labels = {} } })
    assert.same({}, PL:_nodeBonus("Aria-Silvermoon", 2907, 1, 15, 20))
    assert.same({ skill = 7 }, PL:_nodeBonus("Aria-Silvermoon", 2907, 1, 14, 15))
  end)

  it("missing data gives an empty bonus, never an error", function()
    assert.same({}, PL:_nodeBonus("Aria-Silvermoon", 2907, 1, 10, 15))       -- checked-in tables are empty
    assert.same({}, PL:_nodeBonus("Bren-Silvermoon", 2912, 1, 0, 5))         -- no spec record
    assert.same({}, PL:_nodeBonus("Nobody-Silvermoon", 2907, 1, 0, 5))
    assert.same({}, PL:_nodeBonus("Aria-Silvermoon", 2907, 99, 0, 5))        -- unknown path
    ns.GameData.Define("SpecEntryEffects", 70575, { [1000] = { effects = "bad" }, [9000] = "bad" })
    assert.same({}, PL:_nodeBonus("Aria-Silvermoon", 2907, 1, 10, 15))
  end)

  it("unmapped effect types (ingenuity has no EFFECT_MAP entry yet) are left out", function()
    ns.GameData.Define("SpecEntryEffects", 70575, { [1000] = { effects = { { type = "ingenuity", amount = 3 },
      { type = "type99", amount = 1 } }, labels = {} } })
    assert.same({}, PL:_nodeBonus("Aria-Silvermoon", 2907, 1, 10, 15))
  end)

  it("_evaluateWithBonus asks Recipes:Evaluate with extraStats (no ingenuity)", function()
    local seen
    local e = env({ evaluate = function(recipeID, charKey, o)
      seen = { recipeID, charKey, o }
      return { profit = 1 }
    end })
    local r = planner(e):_evaluateWithBonus(1001, "Aria-Silvermoon",
      { skill = 5, multicraft = 30, resourcefulness = 2, ingenuity = 9, recipes = { [1001] = true } })
    assert.same({ profit = 1 }, r)
    assert.same({ 1001, "Aria-Silvermoon", { extraStats = { skill = 5, multicraft = 30, resourcefulness = 2 } } }, seen)
  end)

  it("end to end: GameData effects through the adapters rank the paths", function()
    local e = env({ evaluate = function(recipeID, _, o)
      local s = o.extraStats
      local base = ({ [1001] = 5000, [1002] = 1000 })[recipeID]
      return { profit = base + (s.skill or 0) * 100 + (s.multicraft or 0) }
    end })
    e.GameData.Define("SpecEntryEffects", 70575, {
      [1000] = { effects = { { type = "skill", amount = 1 } }, labels = { 777 } },
      [1001] = { effects = { { type = "multicraft", amount = 10 } }, labels = {} },
    })
    e.GameData.Define("RecipeLabels", 70575, { [1001] = { 777 }, [1002] = { 5 } })
    local rows = planner(e):GetSpecAdvice("Aria-Silvermoon", 2907)
    -- Path 1: 5 ranks × 1 skill on 1001 only = +500 (5 points, 100/pt); path 2: 5 × 10 multicraft on both = +100.
    assert.same({ { 1, 5, 500, 100 }, { 2, 5, 100, 20 } }, {
      { rows[1].pathID, rows[1].points, rows[1].gain, rows[1].gainPerPoint },
      { rows[2].pathID, rows[2].points, rows[2].gain, rows[2].gainPerPoint } })
  end)
end)
