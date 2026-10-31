local FILES = { "Modules/Alts.lua", "Modules/AltsCollector.lua", "Modules/Planner.lua" }

local function planner(ns) return ns.FS:GetModule("Planner") end
local function alts(ns) return ns.FS:GetModule("Alts") end
local function char(ns, key) return ns.FS.db.global.characters[key] end

-- The brief's fixture (preflight row 24: 1099 lives on another line instead of having no schematic).
local function ranked()
  return {
    { recipeID = 1001, charKey = "Aria-Silvermoon", concentrationCost = 200, goldPerConcentration = 80, profit = 5000,
      flags = {} },
    { recipeID = 1004, charKey = "Aria-Silvermoon", concentrationCost = 100, goldPerConcentration = 500,
      flags = { noPrice = true } },
    { recipeID = 1099, charKey = "Aria-Silvermoon", concentrationCost = 100, goldPerConcentration = 70, flags = {} },
  }
end

local function env(opts)
  opts = opts or {}
  return phase3_env({
    files = FILES,
    ranked = opts.ranked or ranked(),
    schematics = { [1001] = { skillLineID = 2907 }, [1004] = { skillLineID = 2907 } },
    recipeLines = opts.recipeLines or { [1099] = 2910, [2001] = 2912 },
  })
end

local function ids(rows)
  local out = {}
  for i, r in ipairs(rows) do out[i] = r.charKey .. ":" .. r.recipeID end
  return out
end

describe("Planner concentration schedule", function()
  it("schedule uses projected concentration and skips unpriced / unmapped", function()
    local ns = env()
    local rows = planner(ns):GetSchedule(NOW)
    assert.equal(1, #rows)
    assert.same({ "Aria-Silvermoon", 1001, 2, 400, 32000 }, { rows[1].charKey, rows[1].recipeID, rows[1].crafts,
      rows[1].concentrationUsed, rows[1].expectedGain })
    assert.same({ 2907, 80 }, { rows[1].skillLineID, rows[1].goldPerConcentration })
  end)

  it("returns status \"ok\" with the rows", function()
    local ns = env()
    assert.equal("ok", select(2, planner(ns):GetSchedule(NOW)))
  end)

  it("projects the pool to the given time", function()
    local ns = env()
    -- Aria gains 1 point per 360 s: 72000 s later she has 600, enough for a third craft.
    local rows = planner(ns):GetSchedule(NOW + 72000)
    assert.same({ 3, 600, 48000 }, { rows[1].crafts, rows[1].concentrationUsed, rows[1].expectedGain })
  end)

  it("defaults the time to the server time", function()
    local ns = env()
    assert.same(planner(ns):GetSchedule(NOW), planner(ns):GetSchedule())
  end)

  it("expectedGain uses the expected concentration cost (preflight row 25)", function()
    local list = ranked()
    list[1].expectedConcentrationCost = 150
    local ns = env({ ranked = list })
    local rows = planner(ns):GetSchedule(NOW)
    assert.same({ 2, 400, 24000 }, { rows[1].crafts, rows[1].concentrationUsed, rows[1].expectedGain })
  end)

  it("applies the maxCraftsPerRecipe setting", function()
    local ns = env()
    planner(ns):Settings().maxCraftsPerRecipe = 1
    assert.equal(1, planner(ns):GetSchedule(NOW)[1].crafts)
    planner(ns):Settings().maxCraftsPerRecipe = 0                -- 0 = no per-recipe cap
    assert.equal(2, planner(ns):GetSchedule(NOW)[1].crafts)
  end)

  it("asks Recipes once per pool, by character and line, for concentration results ranked by gold/concentration",
    function()
      local ns, e = env()
      local calls = {}
      local real = e.recipes.GetRanked
      e.recipes.GetRanked = function(self, filter)
        calls[#calls + 1] = filter
        return real(self, filter)
      end
      planner(ns):GetSchedule(NOW)
      table.sort(calls, function(a, b) return a.charKey < b.charKey end)
      assert.same({
        { charKey = "Aria-Silvermoon", skillLineID = 2907, usesConcentration = true, sortBy = "goldPerConcentration" },
        { charKey = "Bren-Silvermoon", skillLineID = 2912, usesConcentration = true, sortBy = "goldPerConcentration" },
      }, calls)
    end)

  it("a capped pool is scheduled first, from its full value", function()
    local list = ranked()
    list[#list + 1] = { recipeID = 2001, charKey = "Bren-Silvermoon", concentrationCost = 300,
      goldPerConcentration = 10, flags = {} }
    local ns = env({ ranked = list })
    local rows = planner(ns):GetSchedule(NOW)
    assert.same({ "Bren-Silvermoon:2001", "Aria-Silvermoon:1001" }, ids(rows))
    assert.same({ 2912, 3, 900, 9000 }, { rows[1].skillLineID, rows[1].crafts, rows[1].concentrationUsed,
      rows[1].expectedGain })
  end)

  it("a result of one character is never planned on another character's pool", function()
    local list = ranked()
    list[#list + 1] = { recipeID = 2001, charKey = "Aria-Silvermoon", concentrationCost = 100,
      goldPerConcentration = 99, flags = {} }                           -- Aria has no Herbalism (2912) pool
    local ns = env({ ranked = list })
    assert.same({ "Aria-Silvermoon:1001" }, ids(planner(ns):GetSchedule(NOW)))
  end)

  it("drops hidden characters", function()
    local ns = env()
    alts(ns):SetHidden("Aria-Silvermoon", true)
    assert.same({ {}, "ok" }, { planner(ns):GetSchedule(NOW) })
  end)

  it("skips a pool whose concentration is unknown without asking Recipes", function()
    local ns, e = env()
    char(ns, "Aria-Silvermoon").professions[2907].concentration.max = 0
    char(ns, "Bren-Silvermoon").professions[2912].concentration.max = nil
    local asked = 0
    e.recipes.GetRanked = function() asked = asked + 1; return ranked() end
    assert.same({ {}, "ok" }, { planner(ns):GetSchedule(NOW) })
    assert.equal(0, asked)
  end)

  it("does not modify the shared Recipes results", function()
    local list = ranked()
    local ns = env({ ranked = list })
    planner(ns):GetSchedule(NOW)
    assert.is_nil(list[1].skillLineID)
    assert.same(ranked(), list)
  end)

  it("is \"off\" with no rows while Alts or Recipes is turned off", function()
    local ns, e = env()
    alts(ns):Disable()
    assert.same({ {}, "off" }, { planner(ns):GetSchedule(NOW) })
    alts(ns):Enable()
    e.recipes:Disable()
    assert.same({ {}, "off" }, { planner(ns):GetSchedule(NOW) })
  end)

  it("answers while Planner itself is turned off (the tab checks that)", function()
    local ns = env()
    planner(ns):Disable()
    assert.equal(1, #planner(ns):GetSchedule(NOW))
  end)
end)

describe("Planner cap warnings", function()
  it("cap warnings within setting", function()
    local ns = env()
    local PL = planner(ns)
    local w = PL:GetCapWarnings(NOW)
    assert.equal(1, #w)
    assert.same({ "Bren-Silvermoon", 2912, "capped" }, { w[1].charKey, w[1].skillLineID, w[1].status })
    PL:Settings().capWarnHours = 72
    w = PL:GetCapWarnings(NOW)
    assert.same({ "Bren-Silvermoon", "Aria-Silvermoon" }, { w[1].charKey, w[2].charKey })
    assert.equal("soon", w[2].status)
  end)

  it("keeps the pool fields and returns status \"ok\"", function()
    local ns = env()
    local w, status = planner(ns):GetCapWarnings(NOW)
    assert.equal("ok", status)
    assert.same({ 1000, 1000 }, { w[1].value, w[1].max })
  end)

  it("defaults the time to the server time", function()
    local ns = env()
    planner(ns):Settings().capWarnHours = 72
    assert.same(planner(ns):GetCapWarnings(NOW), planner(ns):GetCapWarnings())
  end)

  it("leaves out hidden characters and pools with unknown concentration", function()
    local ns = env()
    planner(ns):Settings().capWarnHours = 72
    alts(ns):SetHidden("Bren-Silvermoon", true)
    assert.same({ "Aria-Silvermoon" }, (function()
      local out = {}
      for i, w in ipairs(planner(ns):GetCapWarnings(NOW)) do out[i] = w.charKey end
      return out
    end)())
    char(ns, "Aria-Silvermoon").professions[2907].concentration.max = 0
    assert.same({ {}, "ok" }, { planner(ns):GetCapWarnings(NOW) })
  end)

  it("is \"off\" with no rows while Alts is turned off (Recipes is not needed)", function()
    local ns, e = env()
    e.recipes:Disable()
    assert.equal(1, #planner(ns):GetCapWarnings(NOW))
    alts(ns):Disable()
    assert.same({ {}, "off" }, { planner(ns):GetCapWarnings(NOW) })
  end)
end)

describe("Planner cap warnings in chat", function()
  it("announces once per session", function()
    local ns, _, W = env()
    local PL = planner(ns)
    PL:AnnounceCapWarnings(NOW); PL:AnnounceCapWarnings(NOW)
    assert.same({ "FabricationStation: Bren-Silvermoon Herbalism: concentration is full" }, W.printed)
  end)

  it("says when a soon-full pool fills, in whole hours without the Characters view", function()
    local ns, _, W = env()
    planner(ns):Settings().capWarnHours = 72
    planner(ns):AnnounceCapWarnings(NOW)
    assert.same({ "FabricationStation: Bren-Silvermoon Herbalism: concentration is full",
      "FabricationStation: Aria-Silvermoon Blacksmithing: concentration full in 60h" }, W.printed)
  end)

  it("uses the Characters view's duration format when it is loaded", function()
    local ns, _, W = env()
    planner(ns):Settings().capWarnHours = 72
    ns.UI.CharactersView = { FormatDuration = function(s) return "D" .. s end }
    local fullAt = planner(ns):GetCapWarnings(NOW)[2].fullAt
    planner(ns):AnnounceCapWarnings(NOW)
    assert.equal("FabricationStation: Aria-Silvermoon Blacksmithing: concentration full in D" .. (fullAt - NOW),
      W.printed[2])
  end)

  it("rounds to the nearest hour, never below 1h", function()
    local ns, _, W = env()
    local aria = char(ns, "Aria-Silvermoon").professions[2907].concentration
    aria.value = 999                                                     -- 1 point left: 360 s
    char(ns, "Bren-Silvermoon").professions[2912].concentration.value = 100
    char(ns, "Bren-Silvermoon").professions[2912].concentration.time = NOW
    planner(ns):AnnounceCapWarnings(NOW)
    assert.same({ "FabricationStation: Aria-Silvermoon Blacksmithing: concentration full in 1h" }, W.printed)
  end)

  it("prints nothing when nothing is full or about to be, and does not try again", function()
    local ns, _, W = env()
    local bren = char(ns, "Bren-Silvermoon").professions[2912].concentration
    bren.value, bren.time = 100, NOW
    planner(ns):AnnounceCapWarnings(NOW)
    bren.value = 1000
    planner(ns):AnnounceCapWarnings(NOW)
    assert.same({}, W.printed)
  end)

  it("prints nothing while capWarnChat is off", function()
    local ns, _, W = env()
    planner(ns):Settings().capWarnChat = false
    planner(ns):AnnounceCapWarnings(NOW)
    assert.same({}, W.printed)
  end)

  it("prints nothing while Alts is turned off", function()
    local ns, _, W = env()
    alts(ns):Disable()
    planner(ns):AnnounceCapWarnings(NOW)
    assert.same({}, W.printed)
  end)

  it("announces 10 s after the first loading screen, only once", function()
    local ns, _, W = env()
    W.fire("PLAYER_ENTERING_WORLD")
    W.advance(9)
    assert.same({}, W.printed)
    W.advance(1)
    assert.same({ "FabricationStation: Bren-Silvermoon Herbalism: concentration is full" }, W.printed)
    W.fire("PLAYER_ENTERING_WORLD")
    W.advance(20)
    assert.equal(1, #W.printed)
    assert.is_true(planner(ns):IsEnabled())
  end)

  it("a later loading screen does not restart the wait", function()
    local _, _, W = env()
    W.fire("PLAYER_ENTERING_WORLD")
    W.advance(6)
    W.fire("PLAYER_ENTERING_WORLD")
    W.advance(4)
    assert.equal(1, #W.printed)
  end)

  it("turning Planner off cancels the pending announcement", function()
    local ns, _, W = env()
    W.fire("PLAYER_ENTERING_WORLD")
    planner(ns):Disable()
    W.advance(20)
    assert.same({}, W.printed)
  end)

  it("an error in the announcement turns Planner off instead of escaping", function()
    local ns, _, W = env()
    alts(ns).GetPools = function() error("boom") end
    W.fire("PLAYER_ENTERING_WORLD")
    assert.has_no.errors(function() W.advance(10) end)
    assert.is_false(planner(ns):IsEnabled())
  end)
end)
