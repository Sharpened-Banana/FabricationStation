-- Phase 7 follow-up F3 (review M4): one rule for "which expansion does this recipe belong to", ns.UI.ExpansionOfRecipe,
-- shared by the Dashboard's "Top crafts by profit" filter and the Ledger's / header's expansion profit. RecipeSources
-- (the static data) first, then the cached schematic's skill line, never a guess. Real skill lines: 2906 Midnight
-- (expansion 11), 2872 The War Within (10).
local MIDNIGHT, TWW = 2906, 2872
local STATIC_ONLY, SCHEMATIC_ONLY, NEITHER, BOTH_DISAGREE = 5101, 5102, 5103, 5104
local ME = "Main-Realm"
local G = 10000

describe("ns.UI.ExpansionOfRecipe", function()
  local ns, W, world, D, ledger

  before_each(function()
    ns, W, world = make_world({ last = "UI/Tabs/Ledger.lua" })
    D = ns.FS:GetModule("Dashboard"); ledger = ns.FS:GetModule("Ledger")
    ns.GameData.Define("RecipeSources", nil, { bySkillLine = {
      [MIDNIGHT] = { [STATIC_ONLY] = { kind = "auto" } },
      [TWW] = { [BOTH_DISAGREE] = { kind = "auto" } },
    } })
  end)

  local function cache_schematic(recipeID, skillLineID)
    world.schematics[recipeID] = { recipeID = recipeID, skillLineID = skillLineID, name = "Recipe " .. recipeID,
      build = 70575, outputItemIDs = {}, reagentSlots = {}, time = 0 }
  end
  local function cache_all()
    cache_schematic(SCHEMATIC_ONLY, MIDNIGHT)
    cache_schematic(BOTH_DISAGREE, MIDNIGHT)       -- the static data says The War Within; the static data wins
  end

  it("takes the static RecipeSources mapping first, with no cached schematic", function()
    assert.equals(11, ns.UI.ExpansionOfRecipe(STATIC_ONLY))
  end)
  it("falls back to the cached schematic's skill line when the static data has no entry", function()
    cache_all()
    assert.equals(11, ns.UI.ExpansionOfRecipe(SCHEMATIC_ONLY))
  end)
  it("lets the static data win over a cached schematic", function()
    cache_all()
    assert.equals(10, ns.UI.ExpansionOfRecipe(BOTH_DISAGREE))
  end)
  it("uses a scanned character's profession record only after both of those, as the header always did", function()
    world.chars[ME].professions[MIDNIGHT].recipes[NEITHER] = true
    assert.equals(11, ns.UI.ExpansionOfRecipe(NEITHER))
    cache_schematic(NEITHER, TWW)                  -- the cached schematic is asked before the record
    assert.equals(10, ns.UI.ExpansionOfRecipe(NEITHER))
  end)
  it("is nil for a recipe in neither, and for a missing id", function()
    cache_all()
    assert.is_nil(ns.UI.ExpansionOfRecipe(NEITHER))
    assert.is_nil(ns.UI.ExpansionOfRecipe(nil))
    cache_schematic(NEITHER, 99999)                -- a skill line with no data is not guessed at either
    assert.is_nil(ns.UI.ExpansionOfRecipe(NEITHER))
  end)

  describe("the scanned-recipe tier", function()
    -- Counts how many times the scanned characters are read.
    local function count_scans()
      local scanner = ns.FS:GetModule("Scanner")
      local real, n = scanner.GetCharacters, { n = 0 }
      scanner.GetCharacters = function(...) n.n = n.n + 1; return real(...) end
      return n
    end
    it("reads the scanned characters once per pass when the caller gives a memo, not once per recipe", function()
      local recipes = {}
      for i = 1, 20 do recipes[i] = 6000 + i; world.chars[ME].professions[MIDNIGHT].recipes[recipes[i]] = true end
      local scans = count_scans()
      local memo = {}
      for _, id in ipairs(recipes) do assert.equals(11, ns.UI.ExpansionOfRecipe(id, memo)) end
      assert.equals(1, scans.n)
    end)
    it("does not keep an answer across passes: a new memo sees a newly scanned recipe", function()
      assert.is_nil(ns.UI.ExpansionOfRecipe(6500, {}))
      world.chars[ME].professions[MIDNIGHT].recipes[6500] = true
      assert.equals(11, ns.UI.ExpansionOfRecipe(6500, {}))
      assert.equals(11, ns.UI.ExpansionOfRecipe(6500))
    end)
    it("takes the lowest expansion when a recipe is on lines of two expansions", function()
      world.chars[ME].professions[MIDNIGHT].recipes[6600] = true
      world.chars[ME].professions[TWW] = { name = "Mining", recipes = { [6600] = true } }
      for _ = 1, 5 do assert.equals(10, ns.UI.ExpansionOfRecipe(6600, {})) end
    end)
    -- Other widgets read the characters too, so compare a refresh over one scanned recipe with one over five: the cost
    -- of the expansion filter must not grow with the number of recipes.
    it("does not read the characters more often for more recipes in a Dashboard refresh or a Ledger summary", function()
      for i = 1, 5 do world.chars[ME].professions[MIDNIGHT].recipes[6700 + i] = true end
      local function refresh_reads(n)
        local list = {}
        for i = 1, n do list[i] = { recipeID = 6700 + i, charKey = ME, profit = 1000 - i, flags = {} } end
        ns.FS:GetModule("Recipes").GetRanked = function() return list end
        local scans = count_scans()
        local frames = D:BuildAll(CreateFrame("Frame"))
        D:RefreshAll()
        assert.equals(n, frames.topCrafts.lineCount)
        return scans.n
      end
      assert.equals(refresh_reads(1), refresh_reads(5))
      local scans = count_scans()
      ledger:Add({ type = "sale", amount = 10 * G, cost = 0, recipeID = 6701, time = W.now - 5 })
      assert.equals(1, ns.UI.LedgerTab.ExpansionSummary(ledger).n)
      local one = scans.n
      for i = 2, 5 do ledger:Add({ type = "sale", amount = 10 * G, cost = 0, recipeID = 6700 + i, time = W.now - 5 }) end
      scans.n = 0
      assert.equals(5, ns.UI.LedgerTab.ExpansionSummary(ledger).n)
      assert.equals(one, scans.n)
    end)
  end)

  describe("in both views", function()
    -- A ranked result per recipe, best first.
    local function stub_ranked(recipeIDs)
      local list = {}
      for i, id in ipairs(recipeIDs) do list[i] = { recipeID = id, charKey = ME, profit = 1000 - i, flags = {} } end
      ns.FS:GetModule("Recipes").GetRanked = function() return list end
    end
    local function widget()
      local frames = D:BuildAll(CreateFrame("Frame"))
      D:RefreshAll()
      return frames.topCrafts
    end
    local function plain(text) return (tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
    local function sale(recipeID)
      ledger:Add({ type = "sale", amount = 10 * G, cost = 0, recipeID = recipeID, time = W.now - 5 })
    end

    it("puts a static-only recipe and a schematic-only recipe in the same expansion", function()
      cache_all()
      stub_ranked({ STATIC_ONLY, SCHEMATIC_ONLY, NEITHER })
      local frame = widget()
      assert.same({ "all", 11 }, frame.expansionOptions)
      frame.expansionButton:GetScript("OnClick")(frame.expansionButton)        -- Midnight
      assert.equals(2, frame.lineCount)
      local text = plain(frame.lines[1]:GetText()) .. "\n" .. plain(frame.lines[2]:GetText())
      assert.is_truthy(text:find("Recipe " .. STATIC_ONLY, 1, true))
      assert.is_truthy(text:find("Recipe " .. SCHEMATIC_ONLY, 1, true))
      assert.is_falsy(text:find("Recipe " .. NEITHER, 1, true))

      for _, id in ipairs({ STATIC_ONLY, SCHEMATIC_ONLY, NEITHER, BOTH_DISAGREE }) do sale(id) end
      local summary = ns.UI.LedgerTab.ExpansionSummary(ledger)
      assert.equals(11, summary.expansion.id)
      assert.is_true(summary.keep(STATIC_ONLY)); assert.is_true(summary.keep(SCHEMATIC_ONLY))
      assert.is_false(summary.keep(NEITHER)); assert.is_false(summary.keep(BOTH_DISAGREE))
      assert.same({ 2, 20 * G }, { summary.n, summary.profit })
    end)

    it("shows a recipe in neither source in no expansion's filter and counts it nowhere", function()
      stub_ranked({ NEITHER })
      local frame = widget()
      assert.same({ "all" }, frame.expansionOptions)
      assert.equals(1, frame.lineCount)                      -- under all expansions only
      sale(NEITHER)
      local summary = ns.UI.LedgerTab.ExpansionSummary(ledger)
      assert.same({ 0, nil }, { summary.n, summary.profit })
      assert.same({}, ns.UI.LedgerTab.ExpansionByCharacter(ledger, summary))
    end)
  end)
end)
