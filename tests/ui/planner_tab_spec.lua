-- Planner tab (UI/Tabs/Planner.lua): the PlannerTab registrar, the four sections (Knowledge, Concentration, Spec
-- advice, Missing recipes) with the remembered section, the character/profession pickers, the Queue button, the lazy
-- spec advice, refresh and the narrow-window layout, on the phase-3 fixture (Aria, Bren, Cato on Silvermoon; Aria is
-- logged in).
local P2 = require("tests.helpers.phase2")

local FILES = { "Modules/Alts.lua", "Modules/AltsCollector.lua", "Modules/CraftingData.lua", "Modules/Planner.lua",
  "Modules/PlannerSpec.lua", "UI/Widgets/ExpandGrid.lua", "UI/Tabs/ViewUtil.lua", "UI/Tabs/CharactersView.lua",
  "UI/Tabs/PlannerView.lua", "UI/OrdersPanel.lua", "UI/Tabs/Planner.lua" }

local DOT, TIMES = " \194\183 ", "\195\151"
local CHECK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:12:12|t"

local function plain(text)
  return (tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end
local function point(region, i) return { region:GetPoint(i or 1) } end

local tooltip = { lines = {} }

local function wow(extra)
  return P2.merge({
    GameTooltip = {
      SetOwner = function(_, owner) tooltip.owner = owner; tooltip.lines = {} end,
      SetText = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
      AddLine = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
      Show = function() tooltip.shown = true end,
      Hide = function() tooltip.shown = false end,
    },
    C_Spell = { GetSpellName = function(id) return id == 1001 and "Truesilver Transmute" or nil end },
    C_Item = {
      GetItemCount = function() return nil end,
      GetItemNameByID = function(id)
        return ({ [263455] = "Smith's Notes", [3001] = "Plans: Axe" })[id]
      end,
    },
  }, extra or {})
end

-- Buttons that keep their text, highlight lock and shown state (the shared stubs make them no-ops).
local function wrap_frames()
  local real = _G.CreateFrame
  _G.CreateFrame = function(frameType, name, parent, template)
    local f = real(frameType, name, parent, template)
    if frameType == "Button" then
      local text, locked = "", false
      function f:SetText(t) text = t end
      function f:GetText() return text end
      function f:LockHighlight() locked = true end
      function f:UnlockHighlight() locked = false end
      function f:IsHighlightLocked() return locked end
    end
    return f
  end
end

-- Concentration crafts (1001: 2 crafts of 200 from Aria's 400) and profitable results for the spec advice.
local function ranked()
  return {
    { recipeID = 1001, charKey = "Aria-Silvermoon", concentrationCost = 200, goldPerConcentration = 80, profit = 5000,
      flags = {} },
    { recipeID = 1002, charKey = "Aria-Silvermoon", profit = 1000, flags = {} },
  }
end

-- Spec effect stubs (as tests/planner/spec_advice_spec.lua): Path 1 +2500 on 1001, every other path +500 a recipe.
local function stub_spec(PL)
  PL._nodeBonus = function(_, _, _, pathID)
    return pathID == 1 and { skill = 5, recipes = { [1001] = true } } or { multicraft = 10 }
  end
  PL._evaluateWithBonus = function(_, recipeID, charKey, bonus)
    local base = ({ [1001] = 5000, [1002] = 1000 })[recipeID]
    return { recipeID = recipeID, charKey = charKey, profit = base + (bonus.skill and 2500 or 500), flags = {} }
  end
end

describe("Planner tab", function()
  local ns, env, W, A, PL, reg, refreshed, container, added, queueAnswer, specCalls

  local function boot(opts)
    opts = opts or {}
    refreshed, container, added, queueAnswer, specCalls = {}, nil, {}, 7, {}
    tooltip.lines = {}
    ns, env, W = phase3_env({
      files = FILES, wow = wow(opts.wow), ranked = opts.ranked or ranked(),
      recipeLines = { [1001] = 2907, [1002] = 2907 },
      queue = { Add = function(_, entry) added[#added + 1] = entry; return queueAnswer end },
    })
    wrap_frames()
    A, PL = ns.FS:GetModule("Alts"), ns.FS:GetModule("Planner")
    stub_spec(PL)
    local advice = PL.GetSpecAdvice
    PL.GetSpecAdvice = function(self, charKey, sl)
      specCalls[#specCalls + 1] = charKey .. ":" .. tostring(sl)
      return advice(self, charKey, sl)
    end
    reg = env.registered.tabs
    ns.FS:GetModule("MainWindow").RefreshTab = function(_, id)
      refreshed[#refreshed + 1] = id
      if container then reg[id].refresh(container) end
    end
    W.advance(1)   -- Alts announces that it is on; nothing is built yet
    refreshed = {}
  end
  local function open(width)
    container = CreateFrame("Frame")
    container:SetSize(width or 716, 500)
    reg.planner.build(container)
    reg.planner.refresh(container)
    return ns.FS:GetModule("PlannerTab"):GetView()
  end
  local function resize(width)
    container:SetSize(width, 500)
    container:GetScript("OnSizeChanged")(container, width, 500)
  end
  local function click(button) button:GetScript("OnClick")(button) end
  local function hover(frame) frame:GetScript("OnEnter")(frame) end
  local function shown_keys(grid)
    local keys = {}
    for i = 1, grid.shownRows do keys[#keys + 1] = grid.rowPool[i].data.key end
    return keys
  end
  local function row_frame(grid, key)
    for i = 1, grid.shownRows do
      if grid.rowPool[i].data.key == key then return grid.rowPool[i] end
    end
  end
  local function select(v, id) click(v.sections[id]) end

  before_each(function() boot() end)

  it("registers the tab", function()
    local def = reg.planner
    assert.same({ "Planner", 80, 3 }, { def.label, def.order, def.phase })
    assert.equal("Interface\\Icons\\INV_Misc_Note_01", def.icon)
    assert.is_function(def.build); assert.is_function(def.refresh)
    assert.is_true(ns.FS:GetModule("PlannerTab").coreModule)
  end)

  describe("sections", function()
    it("starts on Knowledge and shows one section at a time from the button row", function()
      local v = open()
      assert.same({ "Knowledge", "Concentration", "Spec advice", "Missing recipes" }, {
        v.sections.knowledge:GetText(), v.sections.concentration:GetText(), v.sections.spec:GetText(),
        v.sections.missing:GetText() })
      assert.is_true(v.sections.knowledge:IsHighlightLocked())
      assert.is_false(v.sections.spec:IsHighlightLocked())
      assert.is_true(v.grids.knowledge.frame:IsShown())
      for _, id in ipairs({ "concentration", "spec", "missing" }) do assert.is_false(v.grids[id].frame:IsShown(), id) end
      select(v, "concentration")
      assert.is_true(v.grids.concentration.frame:IsShown()); assert.is_false(v.grids.knowledge.frame:IsShown())
      assert.is_true(v.sections.concentration:IsHighlightLocked())
      assert.is_false(v.sections.knowledge:IsHighlightLocked())
    end)

    it("remembers the last section in settings.planner.section", function()
      local v = open()
      select(v, "spec")
      assert.equal("spec", ns.FS.db.global.settings.planner.section)
      -- A new build (e.g. after /reload) opens on it.
      local v2 = open()
      assert.is_true(v2.grids.spec.frame:IsShown())
      assert.is_true(v2.sections.spec:IsHighlightLocked())
      -- An unknown stored section falls back to Knowledge.
      ns.FS.db.global.settings.planner.section = "bogus"
      reg.planner.refresh(container)
      assert.is_true(v2.grids.knowledge.frame:IsShown())
    end)

    it("switches section for this session only while the saved data is from a newer version", function()
      local v = open()
      ns.FS.dbIsNewer = true
      select(v, "missing")
      assert.is_true(v.grids.missing.frame:IsShown())
      local stored = ns.FS.db.global.settings.planner
      assert.is_nil(stored and stored.section)
    end)
  end)

  describe("Knowledge", function()
    it("lists one row per visible character and Midnight profession, most points left first", function()
      local v = open()
      local grid = v.grids.knowledge
      assert.same({ "Bren-Silvermoon:2912", "Aria-Silvermoon:2907" }, shown_keys(grid))
      local aria = row_frame(grid, "Aria-Silvermoon:2907")
      assert.same({ "Aria-Silvermoon", "Blacksmithing", "2/2 " .. CHECK, "\226\128\148", "0/2", "closed", "0/3", "2", "2" },
        { aria.cells.character:GetText(), aria.cells.profession:GetText(), aria.cells.weeklyQuest:GetText(),
          aria.cells.treatise:GetText(), aria.cells.treasure:GetText(), aria.cells.darkmoon:GetText(),
          aria.cells.once:GetText(), aria.cells.firstCrafts:GetText(), aria.cells.left:GetText() })
      assert.equal("Knowledge left: 5 KP", plain(v.status:GetText()))
      hover(aria)
      local rows = PL:GetKnowledgeChecklist()
      assert.same(ns.UI.PlannerView.KnowledgeTooltipLines(rows[2]), tooltip.lines)
    end)

    it("opens a detail listing each source with its item name, points and hint", function()
      ns.GameData.Get("Knowledge").sources[4].hint = "Turn in at the forge"
      local v = open()
      local grid = v.grids.knowledge
      click(row_frame(grid, "Aria-Silvermoon:2907"))
      assert.is_true(grid:IsExpanded("Aria-Silvermoon:2907"))
      local expected = {
        "|cffffd100Aria-Silvermoon Blacksmithing|r",
        "  Darkmoon Faire: 0/3 KP" .. DOT .. "closed (not the faire week)",
        "  Treasure: 0/2 KP" .. DOT .. "open",
        "  One-time: 0/3 KP" .. DOT .. "open",
        "  Weekly quest: Smith's Notes" .. DOT .. "2/2 KP" .. DOT .. "done" .. DOT .. "Turn in at the forge",
        "  First crafts: 2 pending",
      }
      assert.same(expected, ns.UI.PlannerTab.KnowledgeDetailLines(PL:GetKnowledgeChecklist()[2],
        { [263455] = "Smith's Notes" }))
      assert.equal(table.concat(expected, "\n"), grid.detailPool[1].text:GetText())
    end)

    -- Fix round 1: the detail model reads no API and requests nothing (the section builder resolves the names).
    it("builds the detail lines from the given names only", function()
      local row = PL:GetKnowledgeChecklist()[2]
      _G.C_Item.GetItemNameByID = function() error("the model read the item API") end
      _G.C_Item.RequestLoadItemDataByID = function() error("the model requested an item") end
      local lines = ns.UI.PlannerTab.KnowledgeDetailLines(row)
      assert.equal("  Weekly quest: item:263455" .. DOT .. "2/2 KP" .. DOT .. "done", lines[5])
    end)

    it("names unknown states and missing data in the detail, never 0", function()
      local T = ns.UI.PlannerTab
      ns.FS.db.global.characters["Aria-Silvermoon"].knowledgeWeekly = {}
      local lines = T.KnowledgeDetailLines(PL:GetKnowledgeChecklist()[2], {})
      assert.equal("  Treasure: ?/2 KP" .. DOT .. "unknown (no quest data from this week)", lines[3])
      assert.same({ "|cffffd100Aria-Silvermoon Alchemy|r",
        "  No knowledge data for this profession in this GameData build" },
        T.KnowledgeDetailLines({ charKey = "Aria-Silvermoon", name = "Alchemy", summary = { status = "noData" },
          states = {} }))
      -- An item without a known name shows its id.
      ns.FS.db.global.characters["Aria-Silvermoon"].knowledgeWeekly = { time = NOW, quests = {} }
      assert.equal("  Weekly quest: item:263455" .. DOT .. "0/2 KP" .. DOT .. "open",
        T.KnowledgeDetailLines(PL:GetKnowledgeChecklist()[1], {})[5])
    end)

    it("asks for an uncached item name once and refreshes when it arrives, listening only while one is pending", function()
      local requested, names = {}, {}
      _G.C_Item.GetItemNameByID = function(id) return names[id] end
      _G.C_Item.RequestLoadItemDataByID = function(id) requested[#requested + 1] = id end
      local v = open()
      local tab = ns.FS:GetModule("PlannerTab")
      assert.is_true(tab:IsEventRegistered("GET_ITEM_INFO_RECEIVED"))
      click(row_frame(v.grids.knowledge, "Aria-Silvermoon:2907"))
      assert.truthy(v.grids.knowledge.detailPool[1].text:GetText():find("item:263455", 1, true))
      reg.planner.refresh(container)
      assert.same({ 263455 }, requested)
      W.fire("GET_ITEM_INFO_RECEIVED", 999, true)   -- another item: ignored
      W.advance(0.5)
      assert.same({}, refreshed)
      W.fire("GET_ITEM_INFO_RECEIVED", 263455, true)
      names[263455] = "Smith's Notes"
      W.advance(0.5)
      assert.same({ "planner" }, refreshed)
      assert.truthy(v.grids.knowledge.detailPool[1].text:GetText():find("Smith's Notes", 1, true))
      -- Nothing pending any more: the event is no longer registered.
      assert.is_false(tab:IsEventRegistered("GET_ITEM_INFO_RECEIVED"))
      -- Pending again, then hidden: unregistered even with a name pending.
      names[263455] = nil
      reg.planner.refresh(container)
      assert.is_true(tab:IsEventRegistered("GET_ITEM_INFO_RECEIVED"))
      container:GetScript("OnHide")(container)
      assert.is_false(tab:IsEventRegistered("GET_ITEM_INFO_RECEIVED"))
      assert.same({ 263455 }, requested)
    end)

    -- [Task 15, Task 14 follow-up] An uncached name is remembered as false for the row, so two sources with the same
    -- item look it up once.
    it("looks an uncached item up once per row when two sources share it", function()
      local knowledge = ns.GameData.Get("Knowledge")
      knowledge.sources[#knowledge.sources + 1] = { id = "2907:treatise:93999", skillLineID = 2907,
        category = "treatise", reset = "weekly", quests = { 93999 }, itemID = 263455, points = 1 }
      local looked = 0
      _G.C_Item.GetItemNameByID = function(id) if id == 263455 then looked = looked + 1 end end
      _G.C_Item.RequestLoadItemDataByID = function() end
      local v = open()
      looked = 0
      reg.planner.refresh(container)
      assert.equal(1, looked)
      click(row_frame(v.grids.knowledge, "Aria-Silvermoon:2907"))
      local _, n = v.grids.knowledge.detailPool[1].text:GetText():gsub("item:263455", "")
      assert.equal(2, n)
    end)

    -- Fix round 1: only the Knowledge table's own build counts (GameData.TableBuild), never 1a's status.missing.
    it("names the Knowledge table's own build in the footer", function()
      ns.GameData.Define("CraftingData", nil, {})      -- an ungenerated 1a table must not change the footer
      local v = open()
      assert.is_true(ns.FS:GameDataStatus().missing)
      assert.equal("Knowledge data: build 70575" .. DOT .. "Weekly reset in 4d 3h", v.footer:GetText())
      hover(v.footerHit)
      assert.same({ "Knowledge data: build 70575" .. DOT .. "Weekly reset in 4d 3h",
        "Knowledge sources come from GameData build 70575" }, tooltip.lines)
      assert.is_false(v.marker:IsShown())
      -- Without the reset API the reset part is left out.
      _G.C_DateAndTime.GetSecondsUntilWeeklyReset = nil
      reg.planner.refresh(container)
      assert.equal("Knowledge data: build 70575", v.footer:GetText())
    end)

    it("says 'not generated' when the Knowledge table has no build or is missing", function()
      ns.GameData.Define("Knowledge", nil, ns.GameData.Get("Knowledge"))
      local v = open()
      assert.equal("Knowledge data: not generated" .. DOT .. "Weekly reset in 4d 3h", v.footer:GetText())
      hover(v.footerHit)
      assert.same({ "Knowledge data: not generated" .. DOT .. "Weekly reset in 4d 3h",
        "No knowledge data in this GameData: knowledge counts show as ?" }, tooltip.lines)
      assert.is_false(v.marker:IsShown())
      boot({ wow = { GetBuildInfo = function() return "12.2.0", "70700", "Nov 1 2026", 120200 end } })
      ns.GameData.Define("Knowledge", nil, ns.GameData.Get("Knowledge"))
      v = open()
      assert.equal("Knowledge data: not generated" .. DOT .. "Weekly reset in 4d 3h", v.footer:GetText())
      assert.is_false(v.marker:IsShown())   -- not generated is not "old"
    end)

    it("marks only an outdated Knowledge build, not other tables' builds", function()
      for i = 1, 6 do ns.GameData.Define("Other" .. i, 70500, {}) end
      ns.GameData.Define("RecipeSources", nil, { bySkillLine = {} })
      assert.is_true(ns.FS:GameDataStatus().outdated)
      local v = open()
      assert.is_false(v.marker:IsShown())
      assert.equal("Knowledge data: build 70575" .. DOT .. "Weekly reset in 4d 3h", v.footer:GetText())
    end)

    it("puts an 'Old data' marker in its own region at the start of the footer while the data build is outdated", function()
      boot({ wow = { GetBuildInfo = function() return "12.2.0", "70700", "Nov 1 2026", 120200 end } })
      local v = open(516)
      assert.same({ true, "Old data" }, { v.marker:IsShown(), plain(v.marker:GetText()) })
      assert.same({ "TOPLEFT", v.footerBar, "TOPLEFT", 0, 0 }, point(v.marker))
      assert.equal(70, v.marker:GetWidth())
      assert.same({ "TOPLEFT", v.footerBar, "TOPLEFT", 76, 0 }, point(v.footer))
      assert.equal(504 - 76, v.footer:GetWidth())
      hover(v.markerHit)
      assert.same({ "Game data build 70575 is outdated",
        "Knowledge sources and counts come from game build 70575; this is game build 70700, so they may be wrong." },
        tooltip.lines)
      hover(v.footerHit)
      assert.equal("Knowledge sources come from GameData build 70575 (this is game build 70700)", tooltip.lines[2])
      -- Other sections show no marker.
      select(v, "missing")
      assert.is_false(v.marker:IsShown()); assert.is_false(v.markerHit:IsShown())
      assert.same({ "TOPLEFT", v.footerBar, "TOPLEFT", 0, 0 }, point(v.footer))
      assert.equal(504, v.footer:GetWidth())
    end)

    it("says when no character has a Midnight profession", function()
      for _, key in ipairs({ "Aria-Silvermoon", "Bren-Silvermoon" }) do A:SetHidden(key, true) end
      local v = open()
      assert.same({}, shown_keys(v.grids.knowledge))
      assert.same({ true, "No characters with a Midnight profession yet" }, { v.empty:IsShown(), plain(v.empty:GetText()) })
    end)
  end)

  describe("Concentration", function()
    it("lists cap warnings first (capped red, soon orange), then the schedule", function()
      PL:Settings().capWarnHours = 72   -- Aria fills in 60 h: a "soon" warning too
      local v = open()
      select(v, "concentration")
      local grid = v.grids.concentration
      assert.same({ "warn:Bren-Silvermoon:2912", "warn:Aria-Silvermoon:2907", "plan:Aria-Silvermoon:2907:1001" },
        shown_keys(grid))
      local bren = row_frame(grid, "warn:Bren-Silvermoon:2912")
      assert.same({ "Bren-Silvermoon", "Herbalism", "|cffff4040Capped: concentration is full|r", "|cffff4040Full|r" },
        { bren.cells.character:GetText(), bren.cells.profession:GetText(), bren.cells.recipe:GetText(),
          bren.cells.caps:GetText() })
      local soon = row_frame(grid, "warn:Aria-Silvermoon:2907")
      assert.same({ "|cffff8000Soon: full in 2d 12h|r", "|cffff80002d 12h|r" },
        { soon.cells.recipe:GetText(), soon.cells.caps:GetText() })
      assert.is_false(bren.queueButton ~= nil and bren.queueButton:IsShown())
      local plan = row_frame(grid, "plan:Aria-Silvermoon:2907:1001")
      assert.same({ "Aria-Silvermoon", "Blacksmithing", "Truesilver Transmute", "2", "400", "3g", "80c", "2d 12h" },
        { plan.cells.character:GetText(), plan.cells.profession:GetText(), plan.cells.recipe:GetText(),
          plan.cells.crafts:GetText(), plan.cells.conc:GetText(), plan.cells.gain:GetText(), plan.cells.gpc:GetText(),
          plan.cells.caps:GetText() })
      assert.same({ true, "Queue" }, { plan.queueButton:IsShown(), plan.queueButton:GetText() })
      assert.equal("Plan: 2 crafts" .. DOT .. "Capped: 1" .. DOT .. "Soon: 1", plain(v.status:GetText()))
      hover(plan)
      assert.same({ "Truesilver Transmute", "Aria-Silvermoon Blacksmithing", "Crafts: 2 (400 concentration)",
        "Expected gain: 3g 20s 0c", "Gold per concentration: 80c", "Full in: 2d 12h",
        "Queue adds the crafts with concentration" }, tooltip.lines)
    end)

    -- [Phase 3 final M2] A pool whose regeneration rate is unknown: "?" in Caps in, "Full in: unknown" in the tooltip
    -- (not ">14d"); no soon warning for it.
    it("shows '?' in Caps in when the regeneration rate is unknown", function()
      ns.FS.db.global.characters["Aria-Silvermoon"].professions[2907].concentration.perCycle = 0
      PL:Settings().capWarnHours = 168
      local v = open()
      select(v, "concentration")
      local grid = v.grids.concentration
      assert.same({ "warn:Bren-Silvermoon:2912", "plan:Aria-Silvermoon:2907:1001" }, shown_keys(grid))
      local plan = row_frame(grid, "plan:Aria-Silvermoon:2907:1001")
      assert.equal("?", plan.cells.caps:GetText())
      hover(plan)
      assert.equal("Full in: unknown", tooltip.lines[6])
      local T = ns.UI.PlannerTab
      assert.same({ "?", "Full in: unknown" }, { T.ScheduleRow({ charKey = "A-B", skillLineID = 2907, recipeID = 1,
        rateUnknown = true }, NOW).cells.caps, T.ScheduleRow({ charKey = "A-B", skillLineID = 2907, recipeID = 1,
        rateUnknown = true }, NOW).tooltip[6] })
      assert.same({ ">14d", "Full in: more than 14 days" }, { T.ScheduleRow({ charKey = "A-B", skillLineID = 2907,
        recipeID = 1 }, NOW).cells.caps, T.ScheduleRow({ charKey = "A-B", skillLineID = 2907, recipeID = 1 },
        NOW).tooltip[6] })
    end)

    it("adds a schedule row to the Queue on a click and says so", function()
      local v = open()
      select(v, "concentration")
      click(row_frame(v.grids.concentration, "plan:Aria-Silvermoon:2907:1001").queueButton)
      assert.same({ { recipeID = 1001, quantity = 2, charKey = "Aria-Silvermoon", useConcentration = true } }, added)
      assert.equal("Queued: 2 " .. TIMES .. " Truesilver Transmute for Aria-Silvermoon (with concentration)",
        plain(v.status:GetText()))
      hover(v.statusHit)
      assert.same({ "Queued: 2 " .. TIMES .. " Truesilver Transmute for Aria-Silvermoon (with concentration)" },
        tooltip.lines)
      -- Nothing is queued without a click.
      reg.planner.refresh(container)
      assert.equal(1, #added)
    end)

    it("says why the Queue did not take the entry", function()
      local v = open()
      select(v, "concentration")
      queueAnswer = nil
      ns.FS.dbIsNewer = true
      click(row_frame(v.grids.concentration, "plan:Aria-Silvermoon:2907:1001").queueButton)
      assert.equal("Not queued: the saved data is from a newer version (read-only)", plain(v.status:GetText()))
      ns.FS.dbIsNewer = nil
      click(row_frame(v.grids.concentration, "plan:Aria-Silvermoon:2907:1001").queueButton)
      assert.equal("Not queued: the Queue did not accept 2 " .. TIMES .. " Truesilver Transmute",
        plain(v.status:GetText()))
      env.queue:Disable()
      click(row_frame(v.grids.concentration, "plan:Aria-Silvermoon:2907:1001").queueButton)
      assert.equal("Not queued: the Queue is turned off", plain(v.status:GetText()))
      -- Switching section drops the feedback.
      select(v, "knowledge"); select(v, "concentration")
      assert.equal("Plan: 2 crafts" .. DOT .. "Capped: 1" .. DOT .. "Soon: 0", plain(v.status:GetText()))
    end)

    it("names the module that is off and the empty plan", function()
      boot({ ranked = {} })
      local v = open()
      select(v, "concentration")
      assert.same({ "warn:Bren-Silvermoon:2912" }, shown_keys(v.grids.concentration))
      assert.equal("Nothing to schedule: no concentration pool has a priced recipe", plain(v.empty:GetText()))
      -- Under rows: on its own line above the footer, the grid ends above it (never scrolled out of view).
      assert.same({ "BOTTOMLEFT", container, "BOTTOMLEFT", 10, 24 }, point(v.empty, 1))
      assert.same({ "BOTTOMRIGHT", container, "BOTTOMRIGHT", -10, 24 }, point(v.empty, 2))
      assert.same({ "BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 42 }, point(v.grids.concentration.frame, 2))
      ns.FS:GetModule("Recipes"):Disable()
      reg.planner.refresh(container)
      assert.equal("Recipes is turned off", plain(v.empty:GetText()))
      A:Disable()
      reg.planner.refresh(container)
      assert.same({}, shown_keys(v.grids.concentration))
      assert.equal("Alts is turned off", plain(v.empty:GetText()))
      -- No rows: under the grid header, the grid down to the footer.
      assert.same({ "TOPLEFT", container, "TOPLEFT", 10, -82 }, point(v.empty, 1))
      assert.same({ "BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 22 }, point(v.grids.concentration.frame, 2))
    end)

    -- [Task 15, Task 14 follow-up] The message on its own 20 px line above the footer never wraps; hovering it shows the
    -- whole text. Under the grid header it wraps again and has no hover area.
    it("keeps the message above the footer on one line, with the whole text on hover", function()
      boot({ ranked = {} })
      local v = open()
      local wraps = {}
      v.empty.SetWordWrap = function(_, on) wraps[#wraps + 1] = on end
      select(v, "concentration")
      assert.same({ "BOTTOMLEFT", container, "BOTTOMLEFT", 10, 24 }, point(v.empty, 1))
      assert.is_false(wraps[#wraps])
      assert.is_true(v.emptyHit:IsShown())
      v.emptyHit:GetScript("OnEnter")(v.emptyHit)
      assert.equal("Nothing to schedule: no concentration pool has a priced recipe", plain(tooltip.lines[1]))
      A:Disable()
      reg.planner.refresh(container)
      assert.same({ "TOPLEFT", container, "TOPLEFT", 10, -82 }, point(v.empty, 1))
      assert.is_true(wraps[#wraps])
      assert.is_false(v.emptyHit:IsShown())
    end)
  end)

  describe("Spec advice", function()
    it("computes advice only while the section is shown, for the selected character and profession", function()
      local v = open()
      assert.same({}, specCalls)
      select(v, "spec")
      assert.same({ "Aria-Silvermoon:2907" }, specCalls)
      local grid = v.grids.spec
      assert.same({ 1, 2 }, shown_keys(grid))
      local p1 = row_frame(grid, 1)
      assert.same({ "Path 1", "10/30", "5", "25s", "5s", "" }, { p1.cells.path:GetText(), p1.cells.rank:GetText(),
        p1.cells.points:GetText(), p1.cells.gain:GetText(), p1.cells.perPoint:GetText(), p1.cells.affordable:GetText() })
      assert.equal("Estimate from your top 20 profitable recipes", v.footer:GetText())
      assert.equal("Spec advice: 2 paths", plain(v.status:GetText()))
      hover(p1)
      assert.same({ "Path 1", "Rank: 10/30", "Points to the next step: 5", "Gain: 25s 0c", "Per point: 5s 0c",
        "Needs more points than you have unspent" }, tooltip.lines)
    end)

    it("recomputes after a debounced message, never inside the handler, and not on other sections", function()
      local v = open()
      select(v, "spec")
      specCalls = {}
      A:SendMessage("FS_ALTS_CHANGED", "Aria-Silvermoon")
      A:SendMessage("FS_RECIPES_CHANGED")
      assert.same({}, specCalls)
      W.advance(0.5)
      assert.same({ "planner" }, refreshed)
      assert.same({ "Aria-Silvermoon:2907" }, specCalls)
      select(v, "knowledge")
      specCalls = {}
      A:SendMessage("FS_RECIPES_CHANGED")
      W.advance(0.5)
      assert.same({}, specCalls)
    end)

    it("cycles the character and profession pickers through visible characters with a listed profession", function()
      local v = open()
      select(v, "spec")
      assert.same({ true, true, "Aria", "Blacksmithing" }, { v.charButton:IsShown(), v.profButton:IsShown(),
        v.charButton:GetText(), v.profButton:GetText() })
      specCalls = {}
      click(v.charButton)
      assert.same({ "Bren", "Herbalism" }, { v.charButton:GetText(), v.profButton:GetText() })
      assert.same({ "Bren-Silvermoon:2912" }, specCalls)
      assert.equal("Open this profession's specializations on Bren to load spec data", plain(v.empty:GetText()))
      assert.same({}, shown_keys(v.grids.spec))
      click(v.charButton)   -- Cato has no listed profession: back to Aria
      assert.equal("Aria", v.charButton:GetText())
      hover(v.charButton)
      assert.same({ "Character: Aria-Silvermoon", "Click for the next character (2 with a Midnight profession)" },
        tooltip.lines)
      -- The selection is shared with Missing recipes; the pickers hide on the other sections.
      click(v.charButton)
      select(v, "missing")
      assert.equal("Bren", v.charButton:GetText())
      select(v, "knowledge")
      assert.same({ false, false }, { v.charButton:IsShown(), v.profButton:IsShown() })
    end)

    it("says when no gain is known from this GameData build", function()
      boot()
      ns.GameData.Define("SpecEntryEffects", nil, {})
      PL._nodeBonus = function() return {} end
      local v = open()
      select(v, "spec")
      assert.same({}, shown_keys(v.grids.spec))
      assert.equal("Spec effect data not in this GameData build (not generated)", plain(v.empty:GetText()))
    end)

    it("says no spec effects are modelled when the table is generated but no gain is known", function()
      boot()
      ns.GameData.Define("SpecEntryEffects", 70575, {})
      PL._nodeBonus = function() return {} end
      local v = open()
      select(v, "spec")
      assert.same({}, shown_keys(v.grids.spec))
      assert.equal("No modelled spec effects for these paths and recipes", plain(v.empty:GetText()))
    end)
  end)

  describe("Missing recipes", function()
    before_each(function()
      ns.FS.db.global.recipeCatalog[2907] = {
        [1001] = { name = "Truesilver Transmute", sourceText = "", time = NOW },
        [1003] = { name = "Bismuth Bar", sourceText = "Trainer: Smith Bob", time = NOW },
        [1005] = { name = "Axe", sourceText = "", time = NOW },
      }
      ns.GameData.Define("RecipeSources", nil, { bySkillLine = { [2907] = { [1005] = { kind = "item", itemID = 3001 },
        [1007] = { kind = "auto" } } } })
    end)

    it("lists the recipes the selected character does not know with their sources", function()
      local v = open()
      select(v, "missing")
      local grid = v.grids.missing
      assert.same({ 1005, 1003, 1007 }, shown_keys(grid))
      local axe = row_frame(grid, 1005)
      assert.same({ "Axe", "Recipe item: Plans: Axe" }, { axe.cells.recipe:GetText(), axe.cells.source:GetText() })
      assert.equal("Trainer: Smith Bob", row_frame(grid, 1003).cells.source:GetText())
      assert.same({ "Recipe 1007", "Learned automatically" }, { row_frame(grid, 1007).cells.recipe:GetText(),
        row_frame(grid, 1007).cells.source:GetText() })
      assert.equal("Missing: 3 recipes", plain(v.status:GetText()))
      hover(axe)
      assert.same({ "Axe", "Source: Recipe item: Plans: Axe", "Recipe ID 1005" }, tooltip.lines)
    end)

    it("says in the footer when the recipe sources are not generated", function()
      local v = open()
      select(v, "missing")
      local text = "Recipe sources: not generated" .. DOT
        .. "Recipe lists fill in when you open the profession on any character"
      assert.equal(text, v.footer:GetText())
      hover(v.footerHit)
      assert.same({ text, "Without generated recipe sources, only recipes a character has seen in the profession window "
        .. "are listed, and a source the game did not describe shows as Unknown" }, tooltip.lines)
      ns.GameData.Define("RecipeSources", 70575, ns.GameData.Get("RecipeSources"))
      reg.planner.refresh(container)
      text = "Recipe lists fill in when you open the profession on any character"
      assert.equal(text, v.footer:GetText())
      hover(v.footerHit)
      assert.same({ text, "Recipe sources come from GameData build 70575; the game's own source text wins once a "
        .. "character has seen the recipe" }, tooltip.lines)
    end)

    it("shows the getter's status for the selected character", function()
      local v = open()
      select(v, "missing")
      click(v.charButton)
      assert.equal("Open this profession on Bren", plain(v.empty:GetText()))
      assert.same({}, shown_keys(v.grids.missing))
      ns.FS.db.global.characters["Aria-Silvermoon"].professions[2907].recipes = { [1001] = true, [1003] = true,
        [1005] = true, [1007] = true }
      click(v.charButton)
      assert.equal("Aria knows every listed recipe of this profession", plain(v.empty:GetText()))
    end)

    -- Fix round 1: every getter status renders its PlannerView message through the tab, in place of rows.
    it("renders each getter status through the tab", function()
      local v = open()
      for _, case in ipairs({
        { "spec", "GetSpecAdvice", "noRecipes",
          "No profitable recipes for Aria in this profession yet: check prices or open the profession" },
        { "spec", "GetSpecAdvice", "noProfession", "Aria does not have this profession" },
        { "spec", "GetSpecAdvice", "hidden", "Hidden: Aria is hidden on the Characters tab" },
        { "missing", "GetMissingRecipes", "noProfession", "Aria does not have this profession" },
        { "missing", "GetMissingRecipes", "noData", "No recipe list yet: open this profession on any character" },
        { "missing", "GetMissingRecipes", "hidden", "Hidden: Aria is hidden on the Characters tab" },
      }) do
        PL[case[2]] = function() return {}, case[3] end
        select(v, case[1])
        assert.equal(case[4], plain(v.empty:GetText()), case[1] .. " " .. case[3])
        assert.is_true(v.empty:IsShown())
        assert.same({}, shown_keys(v.grids[case[1]]))
      end
    end)

    it("says the pickers have nothing to offer while no character has a listed profession", function()
      for _, key in ipairs({ "Aria-Silvermoon", "Bren-Silvermoon" }) do A:SetHidden(key, true) end
      local v = open()
      select(v, "missing")
      assert.same({ false, false }, { v.charButton:IsShown(), v.profButton:IsShown() })
      assert.equal("No characters with a Midnight profession yet", plain(v.empty:GetText()))
    end)
  end)

  describe("refresh and lifecycle", function()
    it("refreshes through MainWindow:RefreshTab 0.5 s after the last FS_ALTS_CHANGED or FS_RECIPES_CHANGED", function()
      A:SendMessage("FS_ALTS_CHANGED", "Aria-Silvermoon")
      W.advance(0.4)
      A:SendMessage("FS_RECIPES_CHANGED")
      W.advance(0.4)
      assert.same({}, refreshed)
      W.advance(0.1)
      assert.same({ "planner" }, refreshed)
    end)

    it("ticks once a minute while refreshed and stops when the tab is hidden", function()
      open()
      W.advance(60)
      assert.same({ "planner" }, refreshed)
      container:GetScript("OnHide")(container)
      refreshed = {}
      W.advance(120)
      assert.same({}, refreshed)
    end)

    it("ticks only on the Knowledge and Concentration sections", function()
      local v = open()
      select(v, "spec")
      refreshed = {}
      W.advance(120)
      assert.same({}, refreshed)
      select(v, "missing")
      W.advance(120)
      assert.same({}, refreshed)
      select(v, "concentration")
      W.advance(60)
      assert.same({ "planner" }, refreshed)
    end)

    it("cancels pending work and stops listening when turned off", function()
      open()
      A:SendMessage("FS_ALTS_CHANGED", "Aria-Silvermoon")
      ns.FS:GetModule("PlannerTab"):Disable()
      W.advance(120)
      assert.same({}, refreshed)
      A:SendMessage("FS_RECIPES_CHANGED")
      W.advance(1)
      assert.same({}, refreshed)
      reg.planner.refresh(container)   -- while off: no tick starts
      W.advance(120)
      assert.same({}, refreshed)
    end)

    it("shows 'Planner is turned off' instead of a section while Planner is off", function()
      local v = open()
      select(v, "spec")
      specCalls = {}
      PL:Disable()
      reg.planner.refresh(container)
      for _, id in ipairs({ "knowledge", "concentration", "spec", "missing" }) do
        assert.is_false(v.grids[id].frame:IsShown(), id)
      end
      assert.same({}, specCalls)
      assert.equal("Planner is turned off: turn it on in Settings > Modules to see the plan", plain(v.empty:GetText()))
      assert.same({ "", "", false, false }, { v.status:GetText(), v.footer:GetText(), v.charButton:IsShown(),
        v.marker:IsShown() })
      PL:Enable()
      reg.planner.refresh(container)
      assert.is_true(v.grids.spec.frame:IsShown())
    end)

    it("shows 'Alts is turned off' in every section while Alts is off", function()
      local v = open()
      A:Disable()
      for _, id in ipairs({ "knowledge", "spec", "missing" }) do
        select(v, id)
        assert.equal("Alts is turned off", plain(v.empty:GetText()), id)
        assert.is_false(v.charButton:IsShown())
      end
    end)

    it("logs a failing handler under the tab's source without stopping the registrar", function()
      local v = open()
      select(v, "concentration")
      env.queue.Add = function() error("boom") end
      assert.has_no.errors(function()
        click(row_frame(v.grids.concentration, "plan:Aria-Silvermoon:2907:1001").queueButton)
      end)
      local errors = ns.FS.db.global.diagnostics.errors
      assert.equal("Tab:planner", errors[#errors].source)
      assert.is_true(ns.FS:GetModule("PlannerTab"):IsEnabled())
    end)
  end)

  describe("layout", function()
    it("fits the section buttons, pickers, status line, grid and footer at the 516 px minimum", function()
      local v = open(516)
      assert.same({ "TOPLEFT", container, "TOPLEFT", 6, 0 }, point(v.bar, 1))
      assert.same({ "TOPRIGHT", container, "TOPRIGHT", -6, 0 }, point(v.bar, 2))
      local x = 0
      for _, s in ipairs({ { "knowledge", 96 }, { "concentration", 116 }, { "spec", 100 }, { "missing", 124 } }) do
        assert.same({ "TOPLEFT", v.bar, "TOPLEFT", x, -4 }, point(v.sections[s[1]]), s[1])
        assert.equal(s[2], v.sections[s[1]]:GetWidth(), s[1])
        x = x + s[2] + 4
      end
      assert.is_true(x - 4 <= 504)
      -- Knowledge: no pickers, the status line takes the whole row.
      assert.same({ "TOPLEFT", v.bar, "TOPLEFT", 0, -30 }, point(v.status))
      assert.equal(504, v.status:GetWidth())
      assert.same({ "TOPLEFT", container, "TOPLEFT", 0, -56 }, point(v.grids.knowledge.frame, 1))
      assert.same({ "BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 22 }, point(v.grids.knowledge.frame, 2))
      assert.same({ "BOTTOMLEFT", container, "BOTTOMLEFT", 6, 2 }, point(v.footerBar, 1))
      assert.same({ "BOTTOMRIGHT", container, "BOTTOMRIGHT", -6, 2 }, point(v.footerBar, 2))
      assert.equal(156, v.grids.knowledge.layout.flex)
      -- Spec: pickers on the second row, the status line after them.
      select(v, "spec")
      assert.same({ "TOPLEFT", v.bar, "TOPLEFT", 0, -30 }, point(v.charButton))
      assert.same({ "TOPLEFT", v.bar, "TOPLEFT", 144, -30 }, point(v.profButton))
      assert.same({ 140, 140 }, { v.charButton:GetWidth(), v.profButton:GetWidth() })
      assert.same({ "TOPLEFT", v.bar, "TOPLEFT", 296, -30 }, point(v.status))
      assert.equal(504 - 296, v.status:GetWidth())
      assert.equal(516 - 12 - (50 + 44 + 80 + 70 + 70) - 5 * 4, v.grids.spec.layout.flex)   -- 170 px for the path
      resize(900)
      assert.equal(900 - 12 - 296, v.status:GetWidth())
    end)

    it("lays the schedule out from both edges at 516 px, the Recipe column flexible", function()
      local v = open(516)
      select(v, "concentration")
      local grid = v.grids.concentration
      assert.same({ gpc = true, profession = true, caps = true }, grid.layout.hidden)
      assert.equal(516 - 12 - (110 + 40 + 50 + 70 + 52) - 5 * 4, grid.layout.flex)   -- 162 px
      local r = row_frame(grid, "plan:Aria-Silvermoon:2907:1001")
      assert.same({ "LEFT", r, "LEFT", 6, 0 }, point(r.cells.character))
      assert.same({ "LEFT", r.cells.character, "RIGHT", 4, 0 }, point(r.cells.recipe, 1))
      assert.same({ "RIGHT", r.cells.crafts, "LEFT", -4, 0 }, point(r.cells.recipe, 2))
      assert.same({ "RIGHT", r, "RIGHT", -6, 0 }, point(r.cells.queue))
      assert.same({ "LEFT", r.cells.queue, "LEFT", 0, 0 }, point(r.queueButton, 1))
      assert.same({ "RIGHT", r.cells.queue, "RIGHT", 0, 0 }, point(r.queueButton, 2))
      -- Hidden values stay in the tooltip.
      hover(r)
      assert.truthy(table.concat(tooltip.lines, "\n"):find("Gold per concentration: 80c", 1, true))
      resize(716)
      assert.same({}, grid.layout.hidden)
    end)

    it("gives the missing recipes' Source column the rest of the width", function()
      local v = open(516)
      select(v, "missing")
      assert.equal(516 - 12 - 180 - 4, v.grids.missing.layout.flex)
    end)
  end)
end)

describe("Planner tab in a full load", function()
  it("is registered by a core registrar at order 80", function()
    local W = install_wow_stubs()
    local ns = load_addon({})
    W.boot()
    local ids = {}
    for _, t in ipairs(ns.FS:GetModule("MainWindow"):GetTabs()) do ids[#ids + 1] = t.id end
    assert.same({ "dashboard", "recipes", "queue", "orders", "customers", "ledger", "characters", "planner", "settings" },
      ids)
    assert.is_true(ns.FS:GetModule("PlannerTab"):IsEnabled())
    assert.is_nil(ns.FS:GetOptionsTable().args.modules.args.PlannerTab)
    ns.FS:HandleSlash("tab planner")
    assert.equal("planner", ns.FS:GetModule("MainWindow"):GetSelectedTab())
    assert.same({}, ns.FS.db.global.diagnostics.errors)
  end)
end)
