-- Phase-3 Dashboard widget (UI/AltsDashboard.lua): the AltsWidgets registrar's "altsKnowledge" widget (knowledge
-- points left this week, from Planner:GetKnowledgeChecklist through PlannerView.KnowledgeLines), its off / empty /
-- outdated states, the tooltip with every line, the click that opens the Planner tab and the debounced refresh on
-- FS_ALTS_CHANGED. Phase-3 fixture: Aria (Blacksmithing, 2 KP left this week), Bren (Herbalism, 3 KP; "?" once his
-- quest snapshot is removed), Cato (no professions); Aria is logged in.
local FILES = { "Modules/Alts.lua", "Modules/AltsCollector.lua", "Modules/Planner.lua", "UI/Widgets/ExpandGrid.lua",
  "UI/Tabs/ViewUtil.lua", "UI/Tabs/CharactersView.lua", "UI/Tabs/PlannerView.lua", "UI/AltsDashboard.lua" }

local function plain(text)
  return (tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

local function plain_all(lines)
  local out = {}
  for i, line in ipairs(lines or {}) do out[i] = plain(line) end
  return out
end

local tooltip = { lines = {} }

local function wow(extra)
  local t = {
    GameTooltip = {
      SetOwner = function(_, owner) tooltip.owner = owner; tooltip.lines = {} end,
      SetText = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
      AddLine = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
      Show = function() tooltip.shown = true end,
      Hide = function() tooltip.shown = false end,
    },
  }
  for k, v in pairs(extra or {}) do t[k] = v end
  return t
end

-- A fresh phase-3 world with the widget registered on the fake Dashboard; MainWindow's RefreshTab / SelectTab calls
-- are recorded.
local function setup(opts)
  opts = opts or {}
  tooltip = { lines = {} }
  local ns, env, W = phase3_env({ files = FILES, wow = wow(opts.wow), knowledge = opts.knowledge })
  local calls = { refreshed = {}, selected = {} }
  local window = ns.FS:GetModule("MainWindow")
  window.RefreshTab = function(_, id) calls.refreshed[#calls.refreshed + 1] = id end
  window.SelectTab = function(_, id) calls.selected[#calls.selected + 1] = id; return true end
  W.advance(1)   -- Alts' enable announcement (debounced) and its refresh
  calls.refreshed = {}
  return ns, env, W, calls
end

local function built(env)
  local def = env.registered.widgets.altsKnowledge
  local frame = CreateFrame("Frame")
  def.build(frame)
  return def, frame
end

local function refreshed_lines(env)
  local def, frame = built(env)
  def.refresh(frame)
  return plain_all(frame.lines), frame, def
end

describe("Dashboard widgets (phase 3)", function()
  it("registers altsKnowledge (order 65) and no concentration duplicate", function()
    local _, env = setup()
    local w = env.registered.widgets
    assert.same({ 65, "Knowledge left this week" }, { w.altsKnowledge.order, w.altsKnowledge.title })
    assert.is_function(w.altsKnowledge.build); assert.is_function(w.altsKnowledge.refresh)
    assert.is_nil(w.altsConcentration)
  end)

  it("registers from a core registrar module in OnInitialize", function()
    local ns = setup()
    local m = ns.FS:GetModule("AltsWidgets")
    assert.is_true(m.coreModule)
    assert.is_true(m:IsEnabled())
  end)

  it("builds with no lines", function()
    local _, env = setup()
    local _, frame = built(env)
    assert.same({}, frame.lines)
  end)

  it("shows the total first, then points left per character and profession, most first", function()
    local _, env = setup()
    assert.same({ "Total: 5 KP", "3 KP  Bren-Silvermoon Herbalism", "2 KP  Aria-Silvermoon Blacksmithing" },
      (refreshed_lines(env)))
  end)

  it("shows an unknown count as ? KP (never 0 KP) and marks the total", function()
    local ns, env = setup()
    ns.FS.db.global.characters["Bren-Silvermoon"].knowledgeWeekly = {}   -- no snapshot: unknown
    local lines = refreshed_lines(env)
    assert.same({ "Total: 2+? KP", "2 KP  Aria-Silvermoon Blacksmithing", "? KP  Bren-Silvermoon Herbalism" }, lines)
    for _, line in ipairs(lines) do assert.is_nil(line:find("^0 KP")) end
  end)

  it("leaves hidden characters out", function()
    local ns, env = setup()
    ns.FS:GetModule("Alts"):SetHidden("Bren-Silvermoon", true)
    assert.same({ "Total: 2 KP", "2 KP  Aria-Silvermoon Blacksmithing" }, (refreshed_lines(env)))
  end)

  it("shows at most 6 lines, the last one saying how many more there are", function()
    local ns, env = setup()
    local chars = ns.FS.db.global.characters
    for i = 1, 6 do
      chars[("Zed%d-Silvermoon"):format(i)] = {
        class = "MAGE", gold = 0, lastSeen = NOW, items = {}, itemsTime = {},
        professions = { [2907] = { name = "Midnight Blacksmithing", skill = 1, maxSkill = 100, recipes = {},
          concentration = { currencyID = 3256, value = 0, max = 1000, time = NOW, perCycle = 1, cycleSeconds = 360 } } },
        knowledgeWeekly = { time = NOW - 60, quests = {} },
      }
    end
    local lines, frame = refreshed_lines(env)
    assert.equal(6, #lines)
    assert.equal("Total: ", lines[1]:sub(1, 7))
    assert.equal("+4 more", lines[6])
    -- The tooltip lists every line.
    frame:GetScript("OnEnter")(frame)
    local all = plain_all(tooltip.lines)
    assert.equal("Knowledge left this week", all[1])
    assert.equal(1 + 1 + 8, #all - 1)   -- title, total, 8 rows, click hint
    assert.equal("Click to open the Planner", all[#all])
  end)

  it("says the knowledge data is outdated, with the reason in the tooltip", function()
    local _, env = setup({ wow = { GetBuildInfo = function() return "12.0.5", "70999", "Oct 1 2026", 120005 end } })
    local lines, frame = refreshed_lines(env)
    assert.equal("Total: 5 KP (outdated)", lines[1])
    -- [Phase 3 final M7] Orange, the colour of the tabs' "Old data" marker (was gold |cffffd100).
    assert.equal("|cffff8000Total: 5 KP (outdated)|r", frame.lines[1])
    frame:GetScript("OnEnter")(frame)
    local all = plain_all(tooltip.lines)
    assert.truthy(table.concat(all, "\n"):find("Knowledge data build 70575 (outdated)", 1, true))
    assert.truthy(table.concat(tooltip.lines, "\n"):find("|cffff8000Knowledge data build 70575 (outdated)", 1, true))
  end)

  it("takes the outdated marker from the Knowledge table's own build only", function()
    local ns, env = setup()
    ns.GameData.Define("RecipeSources", 70000, { bySkillLine = {} })   -- another table from an older build
    assert.equal("Total: 5 KP", (refreshed_lines(env))[1])
  end)

  it("says there is no knowledge data yet without rows", function()
    local ns, env = setup()
    local chars = ns.FS.db.global.characters
    chars["Aria-Silvermoon"].professions = {}
    chars["Bren-Silvermoon"].professions = {}
    local lines = refreshed_lines(env)
    assert.equal("No knowledge data yet", lines[1])
    assert.equal(2, #lines)
  end)

  it("says there is no knowledge data yet when the GameData has none for any profession", function()
    local _, env = setup({ knowledge = false })
    local lines = refreshed_lines(env)
    assert.equal("No knowledge data yet", lines[1])
    assert.equal(2, #lines)
  end)

  it("says Alts is turned off", function()
    local ns, env = setup()
    ns.FS:GetModule("Alts"):Disable()
    local lines = refreshed_lines(env)
    assert.equal("Alts is turned off", lines[1])
  end)

  it("says the Planner is turned off", function()
    local ns, env = setup()
    ns.FS:GetModule("Planner"):Disable()
    local lines = refreshed_lines(env)
    assert.equal("Planner is turned off", lines[1])
  end)

  it("opens the Planner tab on a left click", function()
    local _, env, _, calls = setup()
    local _, frame = built(env)
    frame:GetScript("OnMouseUp")(frame, "RightButton")
    assert.same({}, calls.selected)
    frame:GetScript("OnMouseUp")(frame, "LeftButton")
    assert.same({ "planner" }, calls.selected)
  end)

  it("shows every line in a tooltip and hides it on leave", function()
    local _, env = setup()
    local _, frame, def = refreshed_lines(env)
    def.refresh(frame)
    frame:GetScript("OnEnter")(frame)
    assert.equal(frame, tooltip.owner)
    assert.same({ "Knowledge left this week", "Total: 5 KP", "3 KP  Bren-Silvermoon Herbalism",
      "2 KP  Aria-Silvermoon Blacksmithing", "Click to open the Planner" }, plain_all(tooltip.lines))
    assert.is_true(tooltip.shown)
    frame:GetScript("OnLeave")(frame)
    assert.is_false(tooltip.shown)
  end)

  it("refreshes the dashboard once after a burst of FS_ALTS_CHANGED, and stops when turned off", function()
    local ns, _, W, calls = setup()
    local A = ns.FS:GetModule("Alts")
    A:SendMessage("FS_ALTS_CHANGED", "Aria-Silvermoon")
    A:SendMessage("FS_ALTS_CHANGED", "Bren-Silvermoon")
    assert.same({}, calls.refreshed)
    W.advance(1)
    assert.same({ "dashboard" }, calls.refreshed)
    calls.refreshed = {}
    A:SendMessage("FS_ALTS_CHANGED", "Aria-Silvermoon")
    ns.FS:GetModule("AltsWidgets"):Disable()
    W.advance(5)
    A:SendMessage("FS_ALTS_CHANGED", "Aria-Silvermoon")
    W.advance(5)
    assert.same({}, calls.refreshed)
  end)
end)

describe("Dashboard widgets (whole addon)", function()
  it("orders altsKnowledge after the phase-2 widgets and fills it without errors", function()
    local W = install_wow_stubs()
    local ns = load_addon({})
    W.boot()
    local D = ns.FS:GetModule("Dashboard")
    local ids = {}
    for i, def in ipairs(D:GetWidgets()) do ids[i] = def.id end
    assert.same({ "topCrafts", "queueSummary", "concentration", "openOrders", "goldThisWeek", "altsKnowledge" }, ids)
    local frames = D:BuildAll(CreateFrame("Frame"))
    D:RefreshAll()
    assert.is_nil(frames.altsKnowledge.errorText)
    assert.equal("No knowledge data yet", plain(frames.altsKnowledge.lines[1]:GetText()))
    assert.same({}, ns.FS.db.global.diagnostics.errors)
  end)
end)
