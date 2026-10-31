-- Characters tab (UI/Tabs/Characters.lua): the CharactersTab registrar, the alt grid with details, hide/show, the
-- reagent search and the narrow-window layout, on the phase-3 fixture (Aria, Bren, Cato on Silvermoon; Aria is
-- logged in).
local P2 = require("tests.helpers.phase2")

local FILES = { "Modules/Alts.lua", "Modules/AltsCollector.lua", "UI/Widgets/ExpandGrid.lua", "UI/Tabs/ViewUtil.lua",
  "UI/Tabs/CharactersView.lua", "UI/OrdersPanel.lua", "UI/Tabs/Characters.lua" }

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
    RAID_CLASS_COLORS = { PALADIN = { colorStr = "fff58cba" }, MAGE = { colorStr = "ff3fc7eb" },
      DRUID = { colorStr = "ffff7c0a" } },
    C_Spell = { GetSpellName = function(id) return id == 1001 and "Truesilver Transmute" or nil end },
    -- No live counts: every character (Aria too) and the warband bank come from their snapshots.
    C_Item = {
      GetItemCount = function() return nil end,
      GetItemNameByID = function(id) return id == 2001 and "Bismuth Ore" or nil end,
      GetItemIconByID = function(id) return id == 2001 and 4615 or nil end,
    },
  }, extra or {})
end

-- Edit boxes, check buttons and buttons that keep their text and checked state (the shared stubs make them no-ops).
local function wrap_frames()
  local real = _G.CreateFrame
  _G.CreateFrame = function(frameType, name, parent, template)
    local f = real(frameType, name, parent, template)
    if frameType == "EditBox" or frameType == "CheckButton" or frameType == "Button" then
      local text, checked = "", false
      function f:SetText(t) text = t end
      function f:GetText() return text end
      function f:Type(t) text = t; local s = self:GetScript("OnTextChanged"); if s then s(self, true) end end
      function f:SetChecked(v) checked = v and true or false end
      function f:GetChecked() return checked end
      if template == "SearchBoxTemplate" then f.Instructions = f:CreateFontString() end
    end
    return f
  end
end

describe("Characters tab", function()
  local ns, env, W, A, reg, refreshed, container

  local function boot(extra)
    refreshed, container = {}, nil
    tooltip.lines = {}
    ns, env, W = phase3_env({ files = FILES, wow = wow(extra) })
    wrap_frames()
    A = ns.FS:GetModule("Alts")
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
    reg.characters.build(container)
    reg.characters.refresh(container)
    return ns.FS:GetModule("CharactersTab"):GetView()
  end
  local function resize(width)
    container:SetSize(width, 500)
    container:GetScript("OnSizeChanged")(container, width, 500)
  end
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
  local function click(button) button:GetScript("OnClick")(button) end

  before_each(function() boot() end)

  it("registers the tab", function()
    assert.same({"Characters", 70, 3}, {env.registered.tabs.characters.label, env.registered.tabs.characters.order,
      env.registered.tabs.characters.phase})
    assert.is_function(env.registered.tabs.characters.build)
    assert.is_function(reg.characters.refresh)
    assert.equal("Interface\\Icons\\Achievement_Character_Human_Male", reg.characters.icon)
    assert.is_true(ns.FS:GetModule("CharactersTab").coreModule)
  end)

  it("shows the header sums and one grid row per visible character, the logged-in one first", function()
    local v = open()
    assert.equal(ns.UI.CharactersView.Header(A:GetOverview()).text, v.header:GetText())
    assert.truthy(v.header:GetText():find("Characters: 3", 1, true))
    assert.same({ "Aria-Silvermoon", "Cato-Silvermoon", "Bren-Silvermoon" }, shown_keys(v.grid))
    local aria = row_frame(v.grid, "Aria-Silvermoon")
    assert.equal("\226\128\162 |cfff58cbaAria|r", aria.cells.name:GetText())
    assert.equal("Blacksmithing 85/100", aria.cells.prof1:GetText())
    assert.equal("1,234g", aria.cells.gold:GetText())
    assert.equal("online", aria.cells.age:GetText())
    local bren = row_frame(v.grid, "Bren-Silvermoon")
    assert.equal("|cffff800010d|r", bren.cells.age:GetText())   -- stale: orange
    assert.is_true(v.grid.frame:IsShown()); assert.is_false(v.results.frame:IsShown())
    assert.is_false(v.empty:IsShown())
    assert.equal("Show hidden (0)", v.showHiddenLabel:GetText())
    assert.equal("Find reagent\226\128\166", v.search.Instructions:GetText())
  end)

  it("spans the empty text across the visible profession columns", function()
    local v = open(516)
    local cato = row_frame(v.grid, "Cato-Silvermoon")
    assert.equal("Open your professions on this character", plain(cato.cells.prof1:GetText()))
    assert.same({ "LEFT", cato.slots.prof1, "LEFT", 0, 0 }, point(cato.cells.prof1, 1))
    assert.same({ "RIGHT", cato.cells.kp1, "RIGHT", 0, 0 }, point(cato.cells.prof1, 2))
    resize(716)   -- Spec 1 comes back: the text reaches it
    cato = row_frame(v.grid, "Cato-Silvermoon")
    assert.same({ "RIGHT", cato.cells.spec1, "RIGHT", 0, 0 }, point(cato.cells.prof1, 2))
    -- A reused frame for a row with professions ends the label at its badge again.
    local aria = row_frame(v.grid, "Aria-Silvermoon")
    assert.same({ "RIGHT", aria.badges.prof1, "LEFT", 0, 0 }, point(aria.cells.prof1, 2))
  end)

  it("shows '+N' on the last visible profession slot through the badge", function()
    ns.FS.db.global.characters["Aria-Silvermoon"].professions[2912] = { name = "Midnight Herbalism", skill = 10,
      maxSkill = 100, recipes = {} }
    local v = open(516)
    local aria = row_frame(v.grid, "Aria-Silvermoon")
    assert.same({ "+1", "Blacksmithing 85/100" }, { aria.badges.prof1:GetText(), aria.cells.prof1:GetText() })
    resize(1400)
    aria = row_frame(v.grid, "Aria-Silvermoon")
    assert.same({ "", "Herbalism 10/100" }, { aria.badges.prof1:GetText(), aria.cells.prof2:GetText() })
  end)

  it("shows every value in the row tooltip", function()
    local v = open(516)
    local aria = row_frame(v.grid, "Aria-Silvermoon")
    aria:GetScript("OnEnter")(aria)
    assert.equal("Aria-Silvermoon", tooltip.lines[1])
    assert.truthy(table.concat(tooltip.lines, "\n"):find("Moxie: 120", 1, true))
  end)

  it("opens a detail per character with spec, knowledge, concentration, cooldowns and a hide button", function()
    local V = ns.UI.CharactersView
    local v = open()
    local aria = row_frame(v.grid, "Aria-Silvermoon")
    click(aria)
    assert.is_true(v.grid:IsExpanded("Aria-Silvermoon"))
    local detail = v.grid.detailPool[1]
    local now = ns.FS:Now()
    local lines = V.DetailLines(A:GetAltRow("Aria-Silvermoon", now), now)
    assert.equal(table.concat(lines, "\n"), detail.text:GetText())
    local entry
    for _, e in ipairs(v.grid.entries) do if e.kind == "detail" then entry = e end end
    assert.equal(ns.UI.ExpandGrid.WrappedHeight(lines, 716) + 28, entry.height)
    assert.same({ "Hide character", true }, { detail.hideButton:GetText(), detail.hideButton:IsShown() })
    assert.same({ "BOTTOMLEFT", detail, "BOTTOMLEFT", 22, 3 }, point(detail.hideButton))
  end)

  it("builds the detail lines from the AltRow", function()
    local V = ns.UI.CharactersView
    local summary = A:GetAltRow("Aria-Silvermoon", NOW).professions[1].knowledge
    assert.same({
      "|cffffd100Blacksmithing 85/100|r",
      "  Spec: 17/63 spent \194\183 4 unspent Blacksmithing Knowledge \194\183 data 1m old",
      "  Knowledge: " .. V.KnowledgeBreakdown(summary),
      "  Concentration: 400/1000 \194\183 full at " .. os.date("%a %H:%M", NOW + 216000) .. " (in 2d 12h)",
      "  Cooldown: Truesilver Transmute \194\183 ready in 2h 0m (" .. os.date("%a %H:%M", NOW + 7200) .. ")",
      "Older expansions: 1 (not shown in the grid)",
    }, V.DetailLines(A:GetAltRow("Aria-Silvermoon", NOW), NOW))
    local bren = V.DetailLines(A:GetAltRow("Bren-Silvermoon", NOW), NOW)
    assert.equal("|cffffd100Herbalism 50/100|r", bren[1])
    assert.equal("  Spec: no data (open this profession's specializations on Bren)", bren[2])
    assert.equal("  Concentration: 1000/1000 \194\183 Full", bren[4])
    assert.equal("  Cooldowns: none", bren[5])
    assert.same({ "Open your professions on this character" }, V.DetailLines(A:GetAltRow("Cato-Silvermoon", NOW), NOW))
    -- Unknown values are named, never 0.
    local unknown = V.DetailLines({ name = "X", professions = { { name = "Alchemy", cooldowns = {
      { recipeID = 7 }, { recipeID = 8, readyAt = NOW - 1 }, { recipeID = 9, readyAt = NOW + 60, charges = 1, maxCharges = 2 } } } },
      olderProfessions = 0 }, NOW)
    assert.same({
      "|cffffd100Alchemy ?|r",
      "  Spec: no data (open this profession's specializations on X)",
      "  Knowledge: " .. V.KnowledgeBreakdown(nil),
      "  Concentration: unknown",
      "  Cooldown: Recipe 7 \194\183 ready time unknown",
      "  Cooldown: Recipe 8 \194\183 ready",
      "  Cooldown: Recipe 9 \194\183 ready \194\183 charges 1/2",
    }, unknown)
  end)

  it("hides a character from its detail, shows it with 'Show hidden' and shows it again", function()
    local v = open()
    click(row_frame(v.grid, "Bren-Silvermoon"))
    local detail = v.grid.detailPool[1]
    click(detail.hideButton)
    assert.is_true(A:Settings().hidden["Bren-Silvermoon"])
    assert.same({ "Aria-Silvermoon", "Cato-Silvermoon" }, shown_keys(v.grid))
    assert.equal("Hidden: Bren-Silvermoon (tick Show hidden to see it again)", plain(v.status:GetText()))
    assert.equal("Show hidden (1)", v.showHiddenLabel:GetText())
    assert.truthy(v.header:GetText():find("Characters: 2", 1, true))
    -- Show hidden: Bren is back, marked, with a Show button.
    v.showHidden:SetChecked(true); click(v.showHidden)
    assert.same({ "Aria-Silvermoon", "Cato-Silvermoon", "Bren-Silvermoon" }, shown_keys(v.grid))
    local bren = row_frame(v.grid, "Bren-Silvermoon")
    assert.truthy(plain(bren.cells.name:GetText()):find("(hidden)", 1, true))
    assert.is_true(v.grid:IsExpanded("Bren-Silvermoon"))
    detail = v.grid.detailPool[1]
    assert.equal("Show character", detail.hideButton:GetText())
    click(detail.hideButton)
    assert.is_nil(A:Settings().hidden["Bren-Silvermoon"])
    assert.equal("Shown: Bren-Silvermoon", plain(v.status:GetText()))
    -- The status line shows its full text on hover.
    v.statusHit:GetScript("OnEnter")(v.statusHit)
    assert.same({ "Shown: Bren-Silvermoon" }, tooltip.lines)
  end)

  it("hides for this session only while the saved data is from a newer version", function()
    local v = open()
    ns.FS.dbIsNewer = true
    click(row_frame(v.grid, "Bren-Silvermoon"))
    click(v.grid.detailPool[1].hideButton)
    local stored = ns.FS.db.global.settings.alts
    assert.is_nil(stored and stored.hidden and stored.hidden["Bren-Silvermoon"])
    assert.same({ "Aria-Silvermoon", "Cato-Silvermoon" }, shown_keys(v.grid))
    assert.equal("Hidden: Bren-Silvermoon (this session only: the saved data is from a newer version)",
      plain(v.status:GetText()))
  end)

  it("says when every character is hidden", function()
    local v = open()
    for _, key in ipairs({ "Aria-Silvermoon", "Bren-Silvermoon", "Cato-Silvermoon" }) do A:SetHidden(key, true) end
    reg.characters.refresh(container)
    assert.same({}, shown_keys(v.grid))
    assert.is_true(v.empty:IsShown())
    assert.equal("Every character is hidden: tick Show hidden to see them", plain(v.empty:GetText()))
  end)

  describe("reagent search", function()
    local asked
    before_each(function()
      asked = {}
      local find = A.FindItems
      A.FindItems = function(self, q) asked[#asked + 1] = q; return find(self, q) end
    end)

    it("searches 0.3 s after the last keystroke and replaces the grid with the item results", function()
      local v = open()
      v.search:Type("o"); v.search:Type("or"); v.search:Type("  ore ")
      W.advance(0.29)
      assert.same({}, asked)
      assert.is_true(v.grid.frame:IsShown())
      W.advance(0.01)
      assert.same({ "ore" }, asked)
      assert.is_false(v.grid.frame:IsShown()); assert.is_true(v.results.frame:IsShown())
      local r = v.results.rowPool[1]
      assert.equal(1, v.results.shownRows)
      assert.same({ "|T4615:14:14|t Bismuth Ore", "25", "Aria: 15, Bren: 3", "7" },
        { r.cells.item:GetText(), r.cells.total:GetText(), r.cells.chars:GetText(), r.cells.warband:GetText() })
      assert.equal("Search: 1 item", v.status:GetText())
      r:GetScript("OnEnter")(r)
      assert.same({ "Bismuth Ore", "Aria: 15 (bags 5, bank 10)", "Bren: 3 (reagent bank 3, 10d old)",
        "Warband bank: 7", "Total: 25" }, tooltip.lines)
    end)

    it("marks unscanned banks with '+' and an unscanned warband bank as 'not scanned'", function()
      local g = ns.FS.db.global
      g.characters["Bren-Silvermoon"].itemsTime.bank = nil
      g.warband = nil
      local v = open()
      v.search:Type("ore"); W.advance(0.3)
      local r = v.results.rowPool[1]
      assert.same({ "18+", "Aria: 15, Bren: 3+", "not scanned" },
        { r.cells.total:GetText(), r.cells.chars:GetText(), plain(r.cells.warband:GetText()) })
      assert.equal("Search: 1 item \194\183 +: a bank or the warband bank was never scanned", v.status:GetText())
      r:GetScript("OnEnter")(r)
      assert.same({ "Bismuth Ore", "Aria: 15 (bags 5, bank 10)", "Bren: 3+ (bank ?, reagent bank 3, 10d old)",
        "Warband bank: not scanned", "Total: 18+" }, tooltip.lines)
    end)

    it("lists at most three holders in the cell, with '+N' for the rest", function()
      local g = ns.FS.db.global
      for i, name in ipairs({ "Dax", "Eli", "Fen" }) do
        g.characters[name .. "-Silvermoon"] = { lastSeen = NOW - i, professions = {}, items = { [2001] = { bags = i } },
          itemsTime = { bags = NOW - i, bank = NOW - i } }
      end
      local v = open()
      v.search:Type("ore"); W.advance(0.3)
      local r = v.results.rowPool[1]
      assert.same({ "Aria: 15, Bren: 3, Fen: 3", "+2" }, { r.cells.chars:GetText(), r.badges.chars:GetText() })
    end)

    it("says when nothing matches or the text is too short", function()
      local v = open()
      v.search:Type("zzz"); W.advance(0.3)
      assert.equal("Search: no items", v.status:GetText())
      assert.equal('No reagent named "zzz" on your visible characters or in the warband bank', plain(v.empty:GetText()))
      assert.is_true(v.empty:IsShown())
      v.search:Type("zz"); W.advance(0.3)
      assert.equal("Type at least 3 letters of a reagent name, or an item ID", plain(v.empty:GetText()))
      v.search:Type("a|b"); W.advance(0.3)
      assert.equal('No reagent named "a||b" on your visible characters or in the warband bank', plain(v.empty:GetText()))
    end)

    it("says the search covers visible characters only while Show hidden is ticked", function()
      A:SetHidden("Bren-Silvermoon", true)
      local v = open()
      v.showHidden:SetChecked(true); click(v.showHidden)
      v.search:Type("ore"); W.advance(0.3)
      assert.equal("Aria: 15", v.results.rowPool[1].cells.chars:GetText())   -- Bren's 3 are not searched
      assert.equal("Search: 1 item \194\183 visible characters only (hidden ones are not searched)", v.status:GetText())
      v.search:Type("zzz"); W.advance(0.3)
      assert.equal('No reagent named "zzz" on your visible characters or in the warband bank'
        .. " (hidden characters are not searched)", plain(v.empty:GetText()))
    end)

    it("restores the grid at once when the text is cleared, dropping a pending search", function()
      local v = open()
      v.search:Type("ore"); W.advance(0.3)
      v.search:Type("orb"); v.search:Type("")
      assert.is_true(v.grid.frame:IsShown()); assert.is_false(v.results.frame:IsShown())
      W.advance(1)
      assert.same({ "ore" }, asked)
      assert.equal("", v.status:GetText())
    end)

    it("runs the search again when an item name arrives, only while searching", function()
      local v = open()
      W.fire("GET_ITEM_INFO_RECEIVED", 2001, true)
      W.advance(1)
      assert.same({}, refreshed)
      v.search:Type("ore"); W.advance(0.3)
      refreshed = {}
      W.fire("GET_ITEM_INFO_RECEIVED", 2001, true)
      W.advance(1)
      assert.same({ "characters" }, refreshed)
      -- Cleared: the event is no longer listened to.
      v.search:Type("")
      refreshed = {}
      W.fire("GET_ITEM_INFO_RECEIVED", 2001, true)
      W.advance(1)
      assert.same({}, refreshed)
    end)

    it("stops listening for item names while the tab is hidden or Alts is off, and again on refresh", function()
      local v = open()
      v.search:Type("ore"); W.advance(0.3)
      container:GetScript("OnHide")(container)
      refreshed = {}
      W.fire("GET_ITEM_INFO_RECEIVED", 2001, true)
      W.advance(1)
      assert.same({}, refreshed)
      reg.characters.refresh(container)   -- selected again: still searching, so it listens again
      W.fire("GET_ITEM_INFO_RECEIVED", 2001, true)
      W.advance(1)
      assert.same({ "characters" }, refreshed)
      A:Disable(); W.advance(1)           -- Alts announces it is off: the refresh shows the off state
      refreshed = {}
      W.fire("GET_ITEM_INFO_RECEIVED", 2001, true)
      W.advance(1)
      assert.same({}, refreshed)
      assert.is_false(v.results.frame:IsShown())
    end)
  end)

  describe("refresh and lifecycle", function()
    it("refreshes through MainWindow:RefreshTab 0.5 s after the last FS_ALTS_CHANGED", function()
      A:SendMessage("FS_ALTS_CHANGED", "Aria-Silvermoon")
      A:SendMessage("FS_ALTS_CHANGED", "Bren-Silvermoon")
      W.advance(0.4)
      assert.same({}, refreshed)
      A:SendMessage("FS_ALTS_CHANGED", "Bren-Silvermoon")
      W.advance(0.4)
      assert.same({}, refreshed)
      W.advance(0.2)
      assert.same({ "characters" }, refreshed)
    end)

    it("refreshes after the Scanner announces a Moxie change (FS_DATA_CHANGED \"moxie\")", function()
      A:SendMessage("FS_DATA_CHANGED", "Aria-Silvermoon", "moxie")   -- Alts relays it as FS_ALTS_CHANGED after 0.5 s
      W.advance(0.9)
      assert.same({}, refreshed)
      W.advance(0.2)
      assert.same({ "characters" }, refreshed)
    end)

    it("ticks once a minute while refreshed, so ages and times to full move on", function()
      open()
      W.advance(59)
      assert.same({}, refreshed)
      W.advance(1)
      assert.same({ "characters" }, refreshed)
    end)

    it("cancels pending work and stops listening when turned off", function()
      local v = open()
      A:SendMessage("FS_ALTS_CHANGED", "Aria-Silvermoon")
      v.search:Type("ore")
      local tab = ns.FS:GetModule("CharactersTab")
      tab:Disable()
      W.advance(120)
      assert.same({}, refreshed)
      assert.is_true(v.grid.frame:IsShown())
      A:SendMessage("FS_ALTS_CHANGED", "Aria-Silvermoon")
      W.fire("GET_ITEM_INFO_RECEIVED", 2001, true)
      W.advance(1)
      assert.same({}, refreshed)
      -- A refresh while off (MainWindow still selects the tab) starts no tick; typing searches at once.
      reg.characters.refresh(container)
      v.search:Type("bismuth")
      assert.is_true(v.results.frame:IsShown())
      W.advance(120)
      assert.same({}, refreshed)
      W.fire("GET_ITEM_INFO_RECEIVED", 2001, true)
      W.advance(1)
      assert.same({}, refreshed)
    end)

    it("cancels the tick when the tab is hidden", function()
      open()
      container:GetScript("OnHide")(container)
      W.advance(120)
      assert.same({}, refreshed)
    end)

    it("shows 'Alts is turned off' instead of the grid while Alts is off", function()
      local v = open()
      click(row_frame(v.grid, "Bren-Silvermoon"))
      click(v.grid.detailPool[1].hideButton)   -- a status line and a hidden count before Alts goes off
      assert.equal("Show hidden (1)", v.showHiddenLabel:GetText())
      A:Disable()
      reg.characters.refresh(container)
      assert.is_false(v.grid.frame:IsShown()); assert.is_false(v.results.frame:IsShown())
      assert.is_true(v.empty:IsShown())
      assert.equal("Alts is turned off: turn it on in Settings > Modules to see your characters", plain(v.empty:GetText()))
      assert.equal("Characters", v.header:GetText())
      assert.same({ "", "", "Show hidden" }, { v.status:GetText(), v.statusText, v.showHiddenLabel:GetText() })
      tooltip.lines, tooltip.shown = {}, false
      v.statusHit:GetScript("OnEnter")(v.statusHit)
      assert.same({}, tooltip.lines); assert.is_falsy(tooltip.shown)
      A:Enable()
      reg.characters.refresh(container)
      assert.is_true(v.grid.frame:IsShown()); assert.is_false(v.empty:IsShown())
      assert.equal("", v.status:GetText())   -- the Hide feedback from before Alts went off is gone
    end)

    it("logs a failing handler under the tab's source without stopping the registrar", function()
      local v = open()
      click(row_frame(v.grid, "Aria-Silvermoon"))
      A.SetHidden = function() error("boom") end
      assert.has_no.errors(function() click(v.grid.detailPool[1].hideButton) end)
      local errors = ns.FS.db.global.diagnostics.errors
      assert.equal("Tab:characters", errors[#errors].source)
      assert.is_true(ns.FS:GetModule("CharactersTab"):IsEnabled())
    end)
  end)

  describe("layout", function()
    it("fits the header, search box, check box and status line at the 516 px minimum", function()
      local v = open(516)
      assert.same({ "TOPLEFT", container, "TOPLEFT", 6, 0 }, point(v.bar, 1))
      assert.same({ "TOPRIGHT", container, "TOPRIGHT", -6, 0 }, point(v.bar, 2))
      assert.same({ "TOPRIGHT", v.bar, "TOPRIGHT", 0, -4 }, point(v.search))
      assert.equal(160, v.search:GetWidth())
      assert.same({ "TOPLEFT", v.bar, "TOPLEFT", 0, -4 }, point(v.header))
      assert.equal(504 - 160 - 8, v.header:GetWidth())   -- 336 px for the header line
      assert.same({ "TOPLEFT", v.bar, "TOPLEFT", 0, -28 }, point(v.showHidden))
      assert.same({ "LEFT", v.showHidden, "RIGHT", 2, 0 }, point(v.showHiddenLabel))
      assert.equal(90, v.showHiddenLabel:GetWidth())
      assert.same({ "LEFT", v.showHidden, "RIGHT", 100, 0 }, point(v.status))
      assert.equal(504 - 124, v.status:GetWidth())
      assert.same({ "TOPLEFT", container, "TOPLEFT", 0, -56 }, point(v.grid.frame, 1))
      assert.same({ "BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0 }, point(v.grid.frame, 2))
      assert.equal(128, v.grid.layout.flex)
      resize(900)
      assert.same({ 900 - 12 - 168, 900 - 12 - 124 }, { v.header:GetWidth(), v.status:GetWidth() })
      resize(516)
      assert.same({ 336, 380 }, { v.header:GetWidth(), v.status:GetWidth() })
    end)

    it("shows the header sums' explanation on hover", function()
      local v = open(516)
      v.headerHit:GetScript("OnEnter")(v.headerHit)
      assert.same(ns.UI.CharactersView.Header(A:GetOverview()).tooltip, tooltip.lines)
      v.headerHit:GetScript("OnLeave")(v.headerHit)
      assert.is_false(tooltip.shown)
    end)

    it("lays the search results out from both edges at 516 px with the Item column flexible", function()
      local v = open(516)
      v.search:Type("ore"); W.advance(0.3)
      local r = v.results.rowPool[1]
      assert.same({}, v.results.layout.hidden)
      assert.equal(516 - 12 - (50 + 190 + 80) - 12, v.results.layout.flex)   -- 172 px for the item name
      assert.same({ "RIGHT", r, "RIGHT", -6, 0 }, point(r.cells.warband)); assert.equal(80, r.cells.warband:GetWidth())
      assert.same({ "RIGHT", r.cells.warband, "LEFT", -4, 0 }, point(r.slots.chars))
      assert.same({ "RIGHT", r.slots.chars, "LEFT", -4, 0 }, point(r.cells.total))
      assert.same({ "LEFT", r, "LEFT", 6, 0 }, point(r.cells.item, 1))
      assert.same({ "RIGHT", r.cells.total, "LEFT", -4, 0 }, point(r.cells.item, 2))
      assert.same({ "Item", "Total", "Characters", "Warband" }, { v.results.headers[1]:GetText(),
        v.results.headers[2]:GetText(), v.results.headers[3]:GetText(), v.results.headers[4]:GetText() })
    end)

    it("puts the outdated-data marker in its own fixed region at the start of the header line (never cut off)", function()
      boot({ GetBuildInfo = function() return "12.2.0", "70700", "Nov 1 2026", 120200 end })
      local v = open(516)
      -- The marker: first on the line, anchored to the bar's left edge, a fixed 70 px for its 8 characters.
      assert.same({ true, "Old data" }, { v.outdated:IsShown(), plain(v.outdated:GetText()) })
      assert.same({ "TOPLEFT", v.bar, "TOPLEFT", 0, -4 }, point(v.outdated))
      assert.equal(1, v.outdated:GetNumPoints())
      assert.equal(70, v.outdated:GetWidth())
      -- The header follows it and only the header (its tail) can be cut; it no longer carries the note.
      assert.same({ "TOPLEFT", v.bar, "TOPLEFT", 76, -4 }, point(v.header))
      assert.equal(336 - 76, v.header:GetWidth())
      assert.equal("Characters: 3 \194\183 Gold: 1,234g \194\183 Knowledge left: 5 KP", v.header:GetText())
      v.outdatedHit:GetScript("OnEnter")(v.outdatedHit)
      assert.same({ "Game data build 70575 is outdated",
        "Knowledge sources and counts come from game build 70575; this is game build 70700, so they may be wrong." },
        tooltip.lines)
      assert.is_true(v.outdatedHit:IsShown())
      resize(900)
      assert.same({ 70, 900 - 12 - 168 - 76 }, { v.outdated:GetWidth(), v.header:GetWidth() })
    end)

    it("gives the header the whole line without an outdated marker, gold compact", function()
      local v = open(516)
      assert.is_false(v.outdated:IsShown()); assert.is_false(v.outdatedHit:IsShown())
      assert.same({ "TOPLEFT", v.bar, "TOPLEFT", 0, -4 }, point(v.header))
      assert.equal(336, v.header:GetWidth())
      assert.truthy(v.header:GetText():find("Gold: 1,234g", 1, true))
      v.headerHit:GetScript("OnEnter")(v.headerHit)
      assert.equal("Gold: 1234g 61s 78c (all characters shown)", tooltip.lines[2])
    end)

    it("explains Show hidden on hover", function()
      A:SetHidden("Bren-Silvermoon", true)
      local v = open(516)
      v.showHiddenHit:GetScript("OnEnter")(v.showHiddenHit)
      assert.equal("Show hidden (1)", tooltip.lines[1])
      assert.truthy(table.concat(tooltip.lines, "\n"):find("Hide character", 1, true))
      assert.same({ "LEFT", v.showHidden, "RIGHT", 2, 0 }, point(v.showHiddenLabel))
      assert.equal(90, v.showHiddenLabel:GetWidth())
    end)
  end)
end)

describe("Characters tab in a full load", function()
  it("is registered by a core registrar at order 70", function()
    local W = install_wow_stubs()
    local ns = load_addon({})
    W.boot()
    local tabs = ns.FS:GetModule("MainWindow"):GetTabs()
    local ids = {}
    for _, t in ipairs(tabs) do ids[#ids + 1] = t.id end
    assert.same({ "dashboard", "recipes", "queue", "orders", "customers", "ledger", "characters", "planner", "settings" },
      ids)
    assert.is_true(ns.FS:GetModule("CharactersTab"):IsEnabled())
    assert.is_nil(ns.FS:GetOptionsTable().args.modules.args.CharactersTab)
    ns.FS:HandleSlash("tab characters")
    assert.equal("characters", ns.FS:GetModule("MainWindow"):GetSelectedTab())
    assert.same({}, ns.FS.db.global.diagnostics.errors)
  end)
end)
