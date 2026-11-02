-- Task 11c: the expansion filter on the Dashboard's "Top crafts by profit" widget. A recipe's expansion is the
-- expansionID of its skill line (the generated ProfessionLines); the cycle button offers "All expansions" and then every
-- expansion that has a ranked result, newest first; the filter runs before the top ten is taken.
-- Real skill lines: 2906 is Midnight (11), 2872 The War Within (10), 2822 Dragonflight (9).
local MIDNIGHT, TWW, DF = 2906, 2872, 2822

describe("Dashboard top crafts expansion filter", function()
  local ns, world, D, tooltip, calls

  before_each(function()
    tooltip = { lines = {} }
    ns, _, world = make_world({ last = "UI/Tabs/Dashboard.lua", stubs = { GameTooltip = {
      SetOwner = function(_, owner) tooltip.owner = owner; tooltip.lines = {} end,
      SetText = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
      AddLine = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
      Show = function() tooltip.shown = true end,
      Hide = function() tooltip.shown = false end,
    } } })
    D = ns.FS:GetModule("Dashboard")
  end)

  after_each(function()
    for id = 1, 15 do _G["EXPANSION_NAME" .. id] = nil end
  end)

  -- A recipe on a skill line (nil line = no skill line known), cached as a schematic the way the Scanner stores it.
  local function add_recipe(recipeID, skillLineID)
    world.schematics[recipeID] = { recipeID = recipeID, skillLineID = skillLineID, name = "Recipe " .. recipeID,
      build = 70575, outputItemIDs = {}, reagentSlots = {}, time = 0 }
  end
  local function result(recipeID, profit)
    return { recipeID = recipeID, charKey = "Main-Realm", profit = profit, flags = {} }
  end
  -- ranked: a list of { recipeID, line, profit } best first; GetRanked answers it and records the filters it was asked.
  local function stub_ranked(ranked)
    calls = {}
    local list = {}
    for i, r in ipairs(ranked) do
      add_recipe(r[1], r[2])
      list[i] = result(r[1], r[3])
    end
    ns.FS:GetModule("Recipes").GetRanked = function(_, filter) calls[#calls + 1] = filter; return list end
  end
  local function widget()
    local frames = D:BuildAll(CreateFrame("Frame"))
    D:RefreshAll()
    return frames.topCrafts
  end
  local function texts(frame)
    local out = {}
    for i = 1, frame.lineCount do out[i] = frame.lines[i]:GetText() end
    return out
  end
  local function plain(text) return (tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
  local function click(frame) frame.expansionButton:GetScript("OnClick")(frame.expansionButton) end
  local function saved() return ns.FS.db.global.settings and ns.FS.db.global.settings.dashboard end

  -- Midnight 14 recipes (the best), Dragonflight 12 recipes (worse): the top ten of everything is all Midnight.
  local function mixed()
    local ranked = {}
    for i = 1, 14 do ranked[#ranked + 1] = { 9100 + i, MIDNIGHT, 10000 - i } end
    for i = 1, 12 do ranked[#ranked + 1] = { 9200 + i, DF, 1000 - i } end
    stub_ranked(ranked)
  end

  describe("the button", function()
    it("is built in the widget with the tooltip text, and says 'All expansions' by default", function()
      mixed()
      local frame = widget()
      assert.is_table(frame.expansionButton)
      assert.equals("All expansions", frame.expansionLabel)
      frame.expansionButton:GetScript("OnEnter")(frame.expansionButton)
      assert.is_true(tooltip.shown)
      assert.same({ "Top crafts by profit", "Show top crafts from one expansion", "All expansions" }, tooltip.lines)
      frame.expansionButton:GetScript("OnLeave")(frame.expansionButton)
      assert.is_false(tooltip.shown)
    end)

    it("leaves the unfiltered widget as it was: the same ranking request and the best ten", function()
      mixed()
      local frame = widget()
      assert.same({ { sortBy = "profit", onlyProfitable = true } }, calls)
      assert.equals(10, frame.lineCount)
      for _, line in ipairs(texts(frame)) do assert.truthy(plain(line):find("Recipe 91", 1, true)) end
    end)

    it("writes nothing to the saved data until the player picks an expansion", function()
      mixed()
      widget()
      assert.is_nil(saved())
    end)
  end)

  describe("cycling", function()
    it("goes all, then each expansion that has a result, newest first, then back to all", function()
      stub_ranked({ { 9301, DF, 500 }, { 9302, MIDNIGHT, 400 }, { 9303, DF, 300 } })   -- no War Within result
      local frame = widget()
      assert.equals("All expansions", frame.expansionLabel)
      click(frame); assert.equals("Midnight", frame.expansionLabel)
      click(frame); assert.equals("Expansion 9", frame.expansionLabel)
      click(frame); assert.equals("All expansions", frame.expansionLabel)
    end)

    it("offers a War Within result once there is one", function()
      stub_ranked({ { 9301, DF, 500 }, { 9302, TWW, 400 }, { 9303, MIDNIGHT, 300 } })
      local frame = widget()
      click(frame); click(frame)
      assert.equals("Expansion 10", frame.expansionLabel)
      assert.same({ "all", 11, 10, 9 }, frame.expansionOptions)
    end)

    it("filters before taking the top ten, so a chosen expansion still shows ten", function()
      mixed()
      local frame = widget()
      click(frame)                      -- Midnight
      assert.equals(10, frame.lineCount)
      click(frame)                      -- Dragonflight: ten of its twelve, best first
      assert.equals(10, frame.lineCount)
      local lines = texts(frame)
      assert.truthy(plain(lines[1]):find("Recipe 9201", 1, true))
      assert.truthy(plain(lines[10]):find("Recipe 9210", 1, true))
      for _, line in ipairs(lines) do assert.falsy(plain(line):find("Recipe 91", 1, true)) end
    end)

    it("shows only the chosen expansion's crafts", function()
      stub_ranked({ { 9301, DF, 500 }, { 9302, MIDNIGHT, 400 }, { 9303, DF, 300 } })
      local frame = widget()
      click(frame)
      local lines = texts(frame)
      assert.equals(1, #lines)
      assert.truthy(plain(lines[1]):find("Recipe 9302", 1, true))
    end)

    it("shows a result with an unknown expansion only under all expansions", function()
      stub_ranked({ { 9301, nil, 900 }, { 9302, 99999, 800 }, { 9303, MIDNIGHT, 700 } })   -- no skill line; a line with no data
      world.schematics[9304] = nil
      local frame = widget()
      assert.equals(3, frame.lineCount)
      assert.same({ "all", 11 }, frame.expansionOptions)
      click(frame)
      assert.equals(1, frame.lineCount)
      assert.truthy(plain(frame.lines[1]:GetText()):find("Recipe 9303", 1, true))
      click(frame)
      assert.equals(3, frame.lineCount)
    end)

    it("treats a recipe whose schematic is not cached as unknown without fetching it", function()
      stub_ranked({ { 9301, MIDNIGHT, 900 } })
      world.schematics[9301] = nil
      local frame = widget()
      assert.same({ "all" }, frame.expansionOptions)
      assert.equals(1, frame.lineCount)
    end)
  end)

  describe("names", function()
    it("uses the client's expansion name when it is a string", function()
      _G.EXPANSION_NAME10 = "The War Within"
      stub_ranked({ { 9301, TWW, 500 } })
      local frame = widget()
      click(frame)
      assert.equals("The War Within", frame.expansionLabel)
    end)

    it("falls back to 'Expansion N' for a name that is not a string", function()
      _G.EXPANSION_NAME9 = 42
      stub_ranked({ { 9301, DF, 500 } })
      local frame = widget()
      click(frame)
      assert.equals("Expansion 9", frame.expansionLabel)
    end)

    it("prefers the name a scanned profession gave, like the header's current expansion", function()
      _G.EXPANSION_NAME9 = "Client Dragonflight"
      world.chars["Main-Realm"].professions[DF] = { name = "Dragon Mining", expansionName = "Dragon Isles", recipes = {} }
      stub_ranked({ { 9301, DF, 500 } })
      local frame = widget()
      click(frame)
      assert.equals("Dragon Isles", frame.expansionLabel)
    end)

    it("names Midnight when nothing else does", function()
      stub_ranked({ { 9301, MIDNIGHT, 500 } })
      local frame = widget()
      click(frame)
      assert.equals("Midnight", frame.expansionLabel)
    end)

    it("puts the full name in the tooltip", function()
      _G.EXPANSION_NAME10 = "The War Within"
      stub_ranked({ { 9301, TWW, 500 } })
      local frame = widget()
      click(frame)
      frame.expansionButton:GetScript("OnEnter")(frame.expansionButton)
      assert.equals("The War Within", tooltip.lines[3])
    end)
  end)

  describe("the saved choice", function()
    it("is saved in the Dashboard's settings when picked", function()
      mixed()
      local frame = widget()
      click(frame)
      assert.equals(11, saved().topCraftsExpansion)
      click(frame); click(frame)
      assert.equals("all", saved().topCraftsExpansion)
    end)

    it("is used the next time the widget is built", function()
      mixed()
      ns.FS.db.global.settings.dashboard = { topCraftsExpansion = 9 }
      local frame = widget()
      assert.equals("Expansion 9", frame.expansionLabel)
      assert.truthy(plain(frame.lines[1]:GetText()):find("Recipe 9201", 1, true))
    end)

    it("reads damaged data as all expansions", function()
      mixed()
      ns.FS.db.global.settings.dashboard = { topCraftsExpansion = "nonsense" }
      local frame = widget()
      assert.equals("All expansions", frame.expansionLabel)
      ns.FS.db.global.settings.dashboard = "damaged"
      frame = widget()
      assert.equals("All expansions", frame.expansionLabel)
    end)

    it("keeps the choice when it has no results, and says so after the empty text", function()
      stub_ranked({ { 9301, MIDNIGHT, 500 } })
      ns.FS.db.global.settings.dashboard = { topCraftsExpansion = 9 }
      local frame = widget()
      local lines = texts(frame)
      assert.equals(2, #lines)
      assert.truthy(plain(lines[1]):find("No profitable crafts right now", 1, true))
      assert.equals("No profitable crafts in Expansion 9", plain(lines[2]))
      assert.equals("Expansion 9", frame.expansionLabel)
      assert.equals(9, saved().topCraftsExpansion)
      click(frame)                        -- not among the options: back to all expansions
      assert.equals("All expansions", frame.expansionLabel)
      assert.equals(1, frame.lineCount)
    end)

    it("says the scan is running instead of the empty text, still naming the expansion", function()
      stub_ranked({})
      ns.FS:GetModule("Recipes").IsScanning = function() return true end
      ns.FS.db.global.settings.dashboard = { topCraftsExpansion = 11 }
      local lines = texts(widget())
      assert.truthy(plain(lines[1]):find("Scanning recipes...", 1, true))
      assert.equals("No profitable crafts in Midnight", plain(lines[2]))
    end)

    it("is a session copy while the saved data is from a newer version", function()
      mixed()
      ns.FS.dbIsNewer = true
      local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
      local frame = widget()
      click(frame)
      assert.equals("Midnight", frame.expansionLabel)
      assert.equals(10, frame.lineCount)
      click(frame)
      assert.equals("Expansion 9", frame.expansionLabel)
      assert.same(before, ns.FS.db.global)
    end)
  end)

  describe("the shared expansion lookup", function()
    it("maps a skill line to its expansion and leaves an unknown line nil", function()
      assert.equals(11, ns.UI.ExpansionOfSkillLine(MIDNIGHT))
      assert.equals(10, ns.UI.ExpansionOfSkillLine(TWW))
      assert.equals(9, ns.UI.ExpansionOfSkillLine(DF))
      assert.is_nil(ns.UI.ExpansionOfSkillLine(99999))
      assert.is_nil(ns.UI.ExpansionOfSkillLine(nil))
    end)

    it("names an expansion: scanned name, then the client's, then the known name, else nil", function()
      assert.equals("Midnight", ns.UI.ExpansionName(11))
      assert.is_nil(ns.UI.ExpansionName(10))
      _G.EXPANSION_NAME10 = "The War Within"
      assert.equals("The War Within", ns.UI.ExpansionName(10))
      _G.EXPANSION_NAME10 = ""
      assert.is_nil(ns.UI.ExpansionName(10))
      assert.is_nil(ns.UI.ExpansionName("x"))
    end)
  end)
end)
