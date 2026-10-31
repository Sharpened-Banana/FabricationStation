local P2 = require("tests.helpers.phase2")

-- OrdersPanel (CompactMoney) loads after the tab in the TOC; the first block loads the tab without it.
local FILES = { "Modules/Customers.lua", "Data/OrderRewards.lua", "Modules/Orders.lua", "Modules/Ledger.lua",
  "UI/Tabs/Customers.lua", "UI/OrdersPanel.lua" }

describe("Customers tab", function()
  local ns, T, reg
  before_each(function()
    ns = P2.boot(); reg = {}
    P2.fake_module(ns, "MainWindow", { RegisterTab = function(_, id, def) reg[id] = def end })
    P2.load(ns, {"Modules/Customers.lua", "UI/Tabs/Customers.lua"}); T = ns.UI.CustomersTab
  end)
  it("registers at order 50", function() assert.same({"Customers", 50}, {reg.customers.label, reg.customers.order}) end)
  it("builds list rows", function()
    local rows = T.ListModel({ {nameRealm="Bob-Silvermoon", orders={{},{}}, tipsTotal=7, lastSeen=9, tags={blocked=true, VIP=true}} })
    assert.same({nameRealm="Bob-Silvermoon", orders=2, tipsTotal=7, lastSeen=9, tagsText="VIP, blocked"}, rows[1])
  end)
  it("normalizes link input", function()
    assert.equal("Bob-Silvermoon", (T.LinkInput(" Bob ")))
    assert.same({nil, "empty"}, {T.LinkInput("  ")})
  end)
end)

describe("Customers tab models", function()
  local ns, T, C, reg
  before_each(function()
    ns = P2.boot(); reg = {}
    P2.fake_module(ns, "MainWindow", { RegisterTab = function(_, id, def) reg[id] = def; return true end })
    P2.load(ns, FILES)
    T = ns.UI.CustomersTab
    C = ns.FS:GetModule("Customers")
  end)

  local function order(id, time, tip, extra)
    local row = { orderID = id, time = time, itemID = 5, quality = 3, tip = tip }
    for k, v in pairs(extra or {}) do row[k] = v end
    return row
  end

  it("registers as phase 2 with its icon and is a core module", function()
    assert.same({ 2, "Interface\\Icons\\INV_Misc_GroupNeedMore" }, { reg.customers.phase, reg.customers.icon })
    assert.is_function(reg.customers.build); assert.is_function(reg.customers.refresh)
    assert.is_true(ns.FS:GetModule("CustomersTab").coreModule)
  end)

  it("copies the link and the alt count, and shows no tags as an empty text", function()
    local rows = T.ListModel({ { nameRealm = "Alt-Silvermoon", orders = {}, tipsTotal = 0, linkedTo = "Bob-Silvermoon" },
      { nameRealm = "Bob-Silvermoon", orders = { {} }, tipsTotal = 3, lastSeen = 4, tags = { zeta = true, alpha = true }, alts = 2 } })
    assert.same({ nameRealm = "Alt-Silvermoon", orders = 0, tipsTotal = 0, tagsText = "", linkedTo = "Bob-Silvermoon" }, rows[1])
    assert.same({ "alpha, zeta", 2 }, { rows[2].tagsText, rows[2].alts })
  end)

  it("lists only customers with orders, alts once under their main, newest first", function()
    C:RecordOrder("Bob-Silvermoon", order(1, 500, 100))
    C:RecordOrder("Alt-Silvermoon", order(2, 900, 40))
    C:RecordOrder("Cat-Silvermoon", order(3, 700, 10))
    C:SetNote("Nobody-Silvermoon", "never ordered")
    C:Link("Alt-Silvermoon", "Bob-Silvermoon")
    local groups = T.Groups("")
    assert.equal(2, #groups)
    local bob, cat = groups[1], groups[2]
    assert.same({ "Bob-Silvermoon", 2, 140, 900, 1 }, { bob.nameRealm, #bob.orders, bob.tipsTotal, bob.lastSeen, bob.alts })
    assert.same({ "Bob-Silvermoon", "Alt-Silvermoon" }, bob.members)
    assert.same({ "Cat-Silvermoon", 1 }, { cat.nameRealm, #cat.orders })
    -- A search that matches the alt shows the main's group.
    local found = T.Groups("alt-")
    assert.equal(1, #found); assert.equal("Bob-Silvermoon", found[1].nameRealm)
    assert.same({}, T.Groups("nobody"))
  end)

  it("shows a group as blocked when any of its characters is blocked", function()
    C:RecordOrder("Bob-Silvermoon", order(1, 500, 100))
    C:RecordOrder("Alt-Silvermoon", order(2, 600, 0))
    C:Link("Alt-Silvermoon", "Bob-Silvermoon")
    C:SetTag("Alt-Silvermoon", "blocked", true)
    C:SetTag("Bob-Silvermoon", "VIP", true)
    assert.equal("VIP, blocked", T.ListModel(T.Groups(""))[1].tagsText)
    assert.is_nil(C:Get("Bob-Silvermoon").tags.blocked)
  end)

  it("passes Link's own errors through and links a typed name", function()
    C:RecordOrder("Bob-Silvermoon", order(1, 500, 100))
    assert.same({ false, "empty" }, { T.Link("Bob-Silvermoon", " ") })
    assert.same({ false, "self" }, { T.Link("Bob-Silvermoon", "Bob") })
    assert.same({ true }, { T.Link("Alt-Silvermoon", "Bob") })
    assert.same({ false, "cycle" }, { T.Link("Bob-Silvermoon", "Alt-Silvermoon") })
    assert.equal("Bob-Silvermoon", C:Get("Alt-Silvermoon").linkedTo)
    assert.equal("Main-Area52", (T.LinkInput("Main-Area52")))
    assert.same({ nil, "empty" }, { T.LinkInput(nil) })
  end)

  it("builds the order history of a main with its alts' orders, newest first, and of an alt alone", function()
    C:RecordOrder("Bob-Silvermoon", order(1, 500, 100, { commission = 90 }))
    C:RecordOrder("Alt-Silvermoon", order(2, 900, 40))
    C:Link("Alt-Silvermoon", "Bob-Silvermoon")
    local rows = T.HistoryRows("Bob-Silvermoon")
    assert.same({ 2, 1 }, { rows[1].orderID, rows[2].orderID })
    assert.same({ "Alt-Silvermoon", nil }, { rows[1].who, rows[2].who })
    assert.same({ 500, 5, 3, 100, 90 }, { rows[2].time, rows[2].item, rows[2].quality, rows[2].tip, rows[2].commission })
    local own = T.HistoryRows("Alt-Silvermoon")
    assert.equal(1, #own); assert.is_nil(own[1].who)
    assert.same({}, T.HistoryRows("Unknown-Silvermoon"))
  end)

  it("keeps the Name column at 120 px or more: Tags goes first, then Orders", function()
    assert.same({ {}, 194 }, { T.Layout(516).hidden, T.Layout(516).name })
    assert.same({ { tags = true }, 192 }, { T.Layout(380).hidden, T.Layout(380).name })
    assert.same({ tags = true, orders = true }, T.Layout(300).hidden)
    assert.same({}, T.Layout(nil).hidden)
  end)

  it("keeps the history's Item column at 120 px or more at the 516 px minimum; Quality goes below that", function()
    local at516 = T.HistoryLayout(516)
    assert.same({ {}, 124, 238 }, { at516.hidden, at516.item, at516.left })
    local at500 = T.HistoryLayout(500)
    assert.same({ { quality = true }, 132 }, { at500.hidden, at500.item })
    assert.same({}, T.HistoryLayout(nil).hidden)
  end)

  it("carries who blocks a group and shows it in the Tags cell", function()
    C:RecordOrder("Bob-Silvermoon", order(1, 500, 100))
    C:RecordOrder("Al-Silvermoon", order(2, 600, 0))
    C:Link("Al-Silvermoon", "Bob-Silvermoon")
    C:SetTag("Al-Silvermoon", "blocked", true)
    local group = T.Groups("")[1]
    assert.same({ "Al-Silvermoon" }, group.blockedBy)
    local row = T.ListModel({ group })[1]
    assert.same({ "blocked", "Al-Silvermoon" }, { row.tagsText, row.blockedVia })
    assert.equal("blocked (via Al)", T.CellTexts(row, 1000).tags)   -- the main's realm is left out
    assert.equal("blocked (alt)", T.CellTexts({ nameRealm = "Bob-Silvermoon", orders = 1, tagsText = "blocked",
      blockedVia = "Someone-Area52" }, 1000).tags)   -- "blocked (via Someone-Area52)" does not fit
    assert.equal("blocked (via Al-X)", T.CellTexts({ nameRealm = "B", orders = 1, tagsText = "blocked", blockedVia = "Al-X" }, 1000).tags)
    assert.equal("VIP, blocked (alt)", T.CellTexts({ nameRealm = "B", orders = 1, tagsText = "VIP, blocked", blockedVia = "Long-Silvermoon" }, 1000).tags)
    -- Blocked by its own tag: no "via".
    C:SetTag("Bob-Silvermoon", "blocked", true)
    group = T.Groups("")[1]
    assert.same({ "Bob-Silvermoon", "Al-Silvermoon" }, group.blockedBy)
    assert.is_nil(T.ListModel({ group })[1].blockedVia)
  end)

  it("formats cells: compact tips, last seen age, never shows unknown money as 0", function()
    local cells = T.CellTexts({ nameRealm = "Bob-Silvermoon", orders = 3, tipsTotal = 12345678, lastSeen = 1000 - 7200,
      tagsText = "VIP", alts = 1 }, 1000)
    assert.same({ "Bob-Silvermoon (+1)", "3", "1,234g", "2h", "VIP" },
      { cells.name, cells.orders, cells.tips, cells.lastSeen, cells.tags })
    local unknown = T.CellTexts({ nameRealm = "X-Y", orders = 1, tagsText = "" }, 1000)
    assert.same({ "|cff9d9d9d?|r", "never" }, { unknown.tips, unknown.lastSeen })   -- a tip is not a price: "?"
  end)
end)

describe("Customers tab frames", function()
  local ns, W, C, reg, refreshed, container, tooltip

  -- The shared frame stubs keep no text, check or focus state; these specs give every frame created here a little.
  local function stateful_frames()
    local base = _G.CreateFrame
    _G.CreateFrame = function(...)
      local f = base(...)
      local text, checked, focus, enabled, shown = "", false, false, true, true
      f.highlighted = 0
      -- Show and Hide run OnShow / OnHide when the state changes, as in the client; mouseOver drives IsMouseOver.
      function f:Show()
        if shown then return end
        shown = true
        local s = self:GetScript("OnShow"); if s then s(self) end
      end
      function f:Hide()
        if not shown then return end
        shown = false
        local s = self:GetScript("OnHide"); if s then s(self) end
      end
      function f:IsShown() return shown end
      function f:IsVisible() return shown end
      function f:IsMouseOver() return self.mouseOver == true end
      function f:SetText(t) text = t; local s = self:GetScript("OnTextChanged"); if s then s(self, false) end end
      function f:GetText() return text end
      function f:Type(t) text = t; local s = self:GetScript("OnTextChanged"); if s then s(self, true) end end
      function f:SetChecked(v) checked = v and true or false end
      function f:GetChecked() return checked end
      function f:SetFocus() focus = true end
      function f:ClearFocus()
        if not focus then return end
        focus = false
        local s = self:GetScript("OnEditFocusLost"); if s then s(self) end
      end
      function f:HasFocus() return focus end
      function f:HighlightText() self.highlighted = self.highlighted + 1 end
      function f:Enable() enabled = true end
      function f:Disable() enabled = false end
      function f:IsEnabled() return enabled end
      return f
    end
  end

  local function order(id, time, tip)
    return { orderID = id, time = time, itemID = 5, quality = 3, tip = tip }
  end
  local function click(button) button:GetScript("OnClick")(button) end
  local function open(width)
    container = CreateFrame("Frame")
    container:SetSize(width or 740, 500)
    reg.customers.build(container)
    reg.customers.refresh(container)
    return ns.FS:GetModule("CustomersTab"):GetView()
  end
  local function row_for(v, name)
    for i = 1, v.list.shown do if v.list.pool[i].data.nameRealm == name then return v.list.pool[i] end end
  end

  before_each(function()
    reg, refreshed, container = {}, {}, nil
    tooltip = { lines = {} }
    ns, W = P2.boot({ GameTooltip = {
      SetOwner = function() tooltip.lines = {} end,
      SetText = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
      AddLine = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
      Show = function() tooltip.shown = true end,
      Hide = function() tooltip.shown = false end,
    } })
    stateful_frames()
    P2.fake_module(ns, "MainWindow", {
      RegisterTab = function(_, id, def) reg[id] = def; return true end,
      RefreshTab = function(_, id)
        refreshed[#refreshed + 1] = id
        if container then reg[id].refresh(container) end
      end,
    })
    P2.load(ns, FILES)
    C = ns.FS:GetModule("Customers")
    C:RecordOrder("Bob-Silvermoon", order(1, 500, 100))
    C:RecordOrder("Cat-Silvermoon", order(2, 700, 10))
    W.advance(1)   -- let the refresh those changes asked for run before the test starts
    refreshed = {}
  end)

  it("lists the customers with orders, newest first, and says when there are none", function()
    local v = open()
    assert.equal(2, v.list.shown)
    assert.same({ "Cat-Silvermoon", "Bob-Silvermoon" }, { v.list.pool[1].data.nameRealm, v.list.pool[2].data.nameRealm })
    assert.equal("1", v.list.pool[1].cells.orders:GetText())
    assert.is_false(v.empty:IsShown())
    v.search:Type("zzz")
    assert.equal(0, v.list.shown); assert.is_true(v.empty:IsShown())
    assert.is_truthy(v.empty:GetText():find("zzz", 1, true))
    -- The echo is the trimmed search, at most 40 characters, with "|" escaped.
    v.search:Type("   " .. string.rep("q", 50) .. "|cff  ")
    local echoed = v.empty:GetText():match('"(.*)"')
    assert.equal(string.rep("q", 40), echoed)
    v.search:Type(" a|b ")
    assert.equal("a||b", v.empty:GetText():match('"(.*)"'))
  end)

  it("filters through Customers:Search as the search text changes", function()
    local asked = {}
    local search = C.Search
    C.Search = function(self, text) asked[#asked + 1] = text; return search(self, text) end
    local v = open()
    v.search:Type("  bob ")
    assert.equal("bob", asked[#asked])
    assert.equal(1, v.list.shown); assert.equal("Bob-Silvermoon", v.list.pool[1].data.nameRealm)
  end)

  it("lays Name out from the left and the other columns from the right edge, in the header and the rows", function()
    local v = open(516)
    local function point(cell, i) return { cell:GetPoint(i or 1) } end
    for _, set in ipairs({ { parent = v.headerBar, cells = v.headers }, { parent = v.list.pool[1], cells = v.list.pool[1].placed } }) do
      local name, orders, tags = set.cells[1], set.cells[2], set.cells[5]
      assert.same({ "LEFT", set.parent, "LEFT", 6, 0 }, point(name, 1))
      assert.same({ "RIGHT", orders, "LEFT", -4, 0 }, point(name, 2))
      assert.same({ "RIGHT", set.parent, "RIGHT", -6, 0 }, point(tags))
      assert.same({ "RIGHT", set.cells[3], "LEFT", -4, 0 }, point(orders))
      assert.equal(130, tags:GetWidth()); assert.is_true(tags:IsShown())
    end
    container:SetSize(380, 500)
    container:GetScript("OnSizeChanged")(container, 380, 500)
    assert.is_false(v.headers[5]:IsShown()); assert.is_false(v.list.pool[1].placed[5]:IsShown())
    assert.same({ "RIGHT", v.list.pool[1], "RIGHT", -6, 0 }, point(v.list.pool[1].placed[4]))
  end)

  it("lays the history out at 516 px with Item between Date and Q, at least 120 px wide", function()
    local function point(cell, i) return { cell:GetPoint(i or 1) } end
    local v = open(516)
    click(row_for(v, "Bob-Silvermoon"))
    local r = v.detail.history.pool[1]
    local dateCell, item, quality, tip = r.placed[1], r.placed[2], r.placed[3], r.placed[4]
    assert.same({ "LEFT", r, "LEFT", 2, 0 }, point(dateCell)); assert.equal(34, dateCell:GetWidth())
    assert.same({ "RIGHT", r, "RIGHT", -2, 0 }, point(tip)); assert.equal(44, tip:GetWidth())
    assert.same({ "RIGHT", tip, "LEFT", -4, 0 }, point(quality)); assert.equal(20, quality:GetWidth())
    assert.same({ "LEFT", dateCell, "RIGHT", 4, 0 }, point(item, 1))
    assert.same({ "RIGHT", quality, "LEFT", -4, 0 }, point(item, 2))
    assert.is_true(quality:IsShown())
    assert.is_true(v.historyLayout.item >= 120); assert.equal(124, v.historyLayout.item)
    -- The left column ends PAD before the fixed right column.
    assert.same({ "BOTTOMRIGHT", v.detail.right, "BOTTOMLEFT", -6, 0 }, { v.detail.left:GetPoint(2) })
    container:SetSize(500, 500)
    container:GetScript("OnSizeChanged")(container, 500, 500)
    assert.is_false(quality:IsShown())
    assert.same({ "RIGHT", tip, "LEFT", -4, 0 }, point(item, 2))
  end)

  it("reaches every alt at 516 px: chips that do not fit go under a +N chip with a pick menu", function()
    for i = 1, 3 do
      local alt = ("Alt%d-Silvermoon"):format(i)
      C:RecordOrder(alt, order(10 + i, 300 + i, 1))
      C:Link(alt, "Bob-Silvermoon")
    end
    local v = open(516)
    local d = v.detail
    click(row_for(v, "Bob-Silvermoon"))
    assert.equal(1, d.groupShown); assert.equal("Alt1-Silvermoon", d.group[1].value)
    assert.is_false(d.group[2]:IsShown()); assert.is_false(d.group[3]:IsShown())
    local more = d.groupMore
    assert.is_true(more:IsShown()); assert.equal("+2", more.label)
    assert.same({ "Alt2-Silvermoon", "Alt3-Silvermoon" }, more.hidden)
    more:GetScript("OnEnter")(more)
    assert.is_truthy(table.concat(tooltip.lines, "\n"):find("Alt3-Silvermoon", 1, true))
    d.group[1]:GetScript("OnEnter")(d.group[1])
    assert.equal("Alt1-Silvermoon", tooltip.lines[1])
    click(more)
    local menu = v.menu
    assert.is_true(menu.frame:IsShown())
    assert.same({ "Alt2-Silvermoon", "Alt3-Silvermoon" }, { menu.buttons[1].value, menu.buttons[2].value })
    click(more)   -- a second click closes it
    assert.is_false(menu.frame:IsShown())
    click(more)
    click(menu.buttons[2])
    assert.is_false(menu.frame:IsShown())
    assert.equal("Alt3-Silvermoon (alt of Bob-Silvermoon)", d.title:GetText())
    assert.is_truthy(row_for(v, "Bob-Silvermoon").selected)   -- the main's row holds the alt
    click(d.unlink)
    assert.is_nil(C:Get("Alt3-Silvermoon").linkedTo)
  end)

  describe("pick menu", function()
    local v, d, tab
    before_each(function()
      for i = 1, 3 do
        local alt = ("Alt%d-Silvermoon"):format(i)
        C:RecordOrder(alt, order(10 + i, 300 + i, 1))
        C:Link(alt, "Bob-Silvermoon")
      end
      v = open(516)
      d = v.detail
      tab = ns.FS:GetModule("CustomersTab")
      click(row_for(v, "Bob-Silvermoon"))
      click(d.groupMore)
    end)

    it("is named, closes with Escape, and listens for clicks only while shown", function()
      local found = false
      for _, name in ipairs(UISpecialFrames) do if name == v.menu.frame:GetName() then found = true end end
      assert.is_true(found)
      assert.is_true(tab:IsEventRegistered("GLOBAL_MOUSE_DOWN"))
      v.menu.frame:Hide()
      assert.is_false(tab:IsEventRegistered("GLOBAL_MOUSE_DOWN"))
    end)

    it("closes on a click outside it and its chip, not on one over them", function()
      v.menu.frame.mouseOver = true
      W.fire("GLOBAL_MOUSE_DOWN", "LeftButton")
      assert.is_true(v.menu.frame:IsShown())
      v.menu.frame.mouseOver = false; d.groupMore.mouseOver = true
      W.fire("GLOBAL_MOUSE_DOWN", "LeftButton")
      assert.is_true(v.menu.frame:IsShown())
      d.groupMore.mouseOver = false
      W.fire("GLOBAL_MOUSE_DOWN", "LeftButton")
      assert.is_false(v.menu.frame:IsShown())
      assert.is_false(tab:IsEventRegistered("GLOBAL_MOUSE_DOWN"))
    end)

    it("stays open through a refresh of the same character and shows the chip's current list", function()
      reg.customers.refresh(container)   -- e.g. after item data arrived
      assert.is_true(v.menu.frame:IsShown())
      C:Link("Alt4-Silvermoon", "Bob-Silvermoon")
      W.advance(1)
      assert.is_true(v.menu.frame:IsShown())
      assert.same({ "Alt2-Silvermoon", "Alt3-Silvermoon", "Alt4-Silvermoon" },
        { v.menu.buttons[1].value, v.menu.buttons[2].value, v.menu.buttons[3].value })
      assert.is_true(v.menu.buttons[3]:IsShown())
    end)

    it("closes when its chip is gone or another character is selected", function()
      C:Unlink("Alt2-Silvermoon"); C:Unlink("Alt3-Silvermoon")
      W.advance(1)
      assert.is_false(d.groupMore:IsShown()); assert.is_false(v.menu.frame:IsShown())
      C:Link("Alt2-Silvermoon", "Bob-Silvermoon"); C:Link("Alt3-Silvermoon", "Bob-Silvermoon")
      W.advance(1)
      click(d.groupMore)
      assert.is_true(v.menu.frame:IsShown())
      click(d.group[1])
      assert.is_false(v.menu.frame:IsShown())
    end)
  end)

  it("reaches every custom tag: the menu of hidden tags removes the one picked and says so", function()
    for i = 1, 8 do C:SetTag("Bob-Silvermoon", "tag-number-" .. i, true) end
    local v = open(516)
    local d = v.detail
    click(row_for(v, "Bob-Silvermoon"))
    assert.equal(4, d.chipsShown)
    assert.same({ "tag-number-5", "tag-number-6", "tag-number-7", "tag-number-8" }, d.chipsMore.hidden)
    d.chips[2]:GetScript("OnEnter")(d.chips[2])
    assert.equal("tag-number-2", tooltip.lines[1])
    click(d.chipsMore)
    click(v.menu.buttons[4])
    assert.is_nil(C:Get("Bob-Silvermoon").tags["tag-number-8"])
    assert.is_truthy(v.status:GetText():find('Removed the tag "tag-number-8"', 1, true))
    assert.equal("+3", d.chipsMore.label)
  end)

  it("selects an alt from its order in the main's history", function()
    C:RecordOrder("Alt-Silvermoon", order(3, 900, 5))
    C:Link("Alt-Silvermoon", "Bob-Silvermoon")
    local v = open()
    local d = v.detail
    click(row_for(v, "Bob-Silvermoon"))
    local altRow = d.history.pool[1]
    assert.equal("Alt-Silvermoon", altRow.data.who)
    altRow:GetScript("OnEnter")(altRow)
    assert.equal("Click to show Alt-Silvermoon", tooltip.lines[#tooltip.lines])
    click(altRow)
    assert.equal("Alt-Silvermoon (alt of Bob-Silvermoon)", d.title:GetText())
    click(d.history.pool[1])   -- the alt's own orders select nothing else
    assert.equal("Alt-Silvermoon (alt of Bob-Silvermoon)", d.title:GetText())
  end)

  it("shows a group blocked through an alt in the list, the tooltip and the detail pane", function()
    C:RecordOrder("Alt-Silvermoon", order(3, 400, 5))
    C:Link("Alt-Silvermoon", "Bob-Silvermoon")
    C:SetTag("Alt-Silvermoon", "blocked", true)
    local v = open()
    local d = v.detail
    local r = row_for(v, "Bob-Silvermoon")
    assert.equal("blocked (via Alt)", r.cells.tags:GetText())
    r:GetScript("OnEnter")(r)
    assert.is_truthy(table.concat(tooltip.lines, "\n"):find("Blocked because Alt-Silvermoon is blocked", 1, true))
    click(r)
    assert.is_false(d.blocked:GetChecked())
    assert.is_true(d.blockedHint:IsShown())
    assert.is_truthy(d.blockedHint.text:GetText():find("Group blocked via Alt-Silvermoon", 1, true))
    click(d.blockedHint)
    assert.equal("Alt-Silvermoon (alt of Bob-Silvermoon)", d.title:GetText())
    assert.is_true(d.blocked:GetChecked()); assert.is_false(d.blockedHint:IsShown())
  end)

  it("shows the full title and the current link in tooltips", function()
    C:Link("Cat-Silvermoon", "Bob-Silvermoon")
    local v = open()
    local d = v.detail
    click(row_for(v, "Bob-Silvermoon"))
    click(d.group[1])
    d.titleArea:GetScript("OnEnter")(d.titleArea)
    assert.equal("Cat-Silvermoon (alt of Bob-Silvermoon)", tooltip.lines[1])
    d.linkEdit:GetScript("OnEnter")(d.linkEdit)
    assert.equal("Linked to Bob-Silvermoon", tooltip.lines[1])
    click(d.group[1])
    d.linkEdit:GetScript("OnEnter")(d.linkEdit)
    assert.equal("Not linked to a main character", tooltip.lines[1])
  end)

  it("puts the full tips, tags, alts and note in the row tooltip", function()
    C:SetNote("Bob-Silvermoon", "pays well")
    C:SetTag("Bob-Silvermoon", "friend", true)
    C:RecordOrder("Alt-Silvermoon", order(3, 400, 5))
    C:Link("Alt-Silvermoon", "Bob-Silvermoon")
    local v = open()
    local r = row_for(v, "Bob-Silvermoon")
    r:GetScript("OnEnter")(r)
    assert.is_true(tooltip.shown)
    local all = table.concat(tooltip.lines, "\n")
    assert.is_truthy(all:find("Tips: " .. ns.UI.FormatMoney(105), 1, true))
    assert.is_truthy(all:find("Tags: friend", 1, true))
    assert.is_truthy(all:find("Alts: Alt-Silvermoon", 1, true))
    assert.is_truthy(all:find("pays well", 1, true))
  end)

  it("shows the selected customer's history, notes, tags and link state", function()
    C:SetNote("Bob-Silvermoon", "pays well")
    C:SetTag("Bob-Silvermoon", "VIP", true)
    C:SetTag("Bob-Silvermoon", "friend", true)
    local v = open()
    local d = v.detail
    assert.is_false(d.body:IsShown()); assert.is_true(d.hint:IsShown())
    click(row_for(v, "Bob-Silvermoon"))
    assert.is_true(d.body:IsShown()); assert.is_false(d.hint:IsShown())
    assert.equal("Bob-Silvermoon", d.title:GetText())
    assert.equal(1, d.history.shown)
    local h = d.history.pool[1]
    assert.same({ date("%m-%d", 500), "item:5", "Q3", "1s" },
      { h.cells.date:GetText(), h.cells.item:GetText(), h.cells.quality:GetText(), h.cells.tip:GetText() })
    assert.equal("pays well", d.notes:GetText())
    assert.is_true(d.vip:GetChecked()); assert.is_false(d.blocked:GetChecked())
    assert.equal(1, d.chipsShown); assert.equal("friend", d.chips[1].value)
    assert.equal("", d.linkEdit:GetText()); assert.is_false(d.unlink:IsEnabled())
    assert.is_truthy(row_for(v, "Bob-Silvermoon").selected)
  end)

  it("saves the note when the box loses focus, trimmed, and before another customer is selected", function()
    local v = open()
    local d = v.detail
    click(row_for(v, "Bob-Silvermoon"))
    d.notes:SetFocus(); d.notes:Type("  slow payer  ")
    d.notes:ClearFocus()
    assert.equal("slow payer", C:Get("Bob-Silvermoon").notes)
    d.notes:SetFocus(); d.notes:Type("changed")
    click(row_for(v, "Cat-Silvermoon"))
    assert.equal("changed", C:Get("Bob-Silvermoon").notes)
    assert.equal("", C:Get("Cat-Silvermoon").notes)
    assert.equal("", d.notes:GetText())
  end)

  it("cuts a long note to 500 characters", function()
    local v = open()
    click(row_for(v, "Bob-Silvermoon"))
    v.detail.notes:SetFocus(); v.detail.notes:Type(string.rep("a", 600)); v.detail.notes:ClearFocus()
    assert.equal(500, #C:Get("Bob-Silvermoon").notes)
  end)

  it("does not overwrite a note being typed when the list refreshes", function()
    local v = open()
    click(row_for(v, "Bob-Silvermoon"))
    v.detail.notes:SetFocus(); v.detail.notes:Type("half typed")
    C:RecordOrder("Cat-Silvermoon", order(9, 800, 1))
    W.advance(1)
    assert.equal("half typed", v.detail.notes:GetText())
  end)

  it("toggles VIP and Blocked through SetTag", function()
    local v = open()
    click(row_for(v, "Bob-Silvermoon"))
    click(v.detail.vip)
    assert.is_true(C:Get("Bob-Silvermoon").tags.VIP); assert.is_true(v.detail.vip:GetChecked())
    click(v.detail.blocked)
    assert.is_true(C:IsBlocked("Bob-Silvermoon"))
    click(v.detail.vip)
    assert.is_nil(C:Get("Bob-Silvermoon").tags.VIP); assert.is_false(v.detail.vip:GetChecked())
  end)

  it("adds a custom tag from the field and removes it with its chip", function()
    local v = open()
    local d = v.detail
    click(row_for(v, "Bob-Silvermoon"))
    d.tagEdit:Type("  big spender  ")
    click(d.tagAdd)
    assert.is_true(C:Get("Bob-Silvermoon").tags["big spender"])
    assert.equal("", d.tagEdit:GetText())
    assert.equal(1, d.chipsShown)
    d.tagEdit:Type("vip"); d.tagEdit:GetScript("OnEnterPressed")(d.tagEdit)
    assert.is_true(C:Get("Bob-Silvermoon").tags.VIP); assert.equal(1, d.chipsShown)
    d.tagEdit:Type("VIP"); click(d.tagAdd)   -- already there: nothing to change, the field still clears
    assert.equal("", d.tagEdit:GetText()); assert.is_nil(v.status:GetText():lower():find("read-only", 1, true))
    click(d.chips[1])
    assert.is_nil(C:Get("Bob-Silvermoon").tags["big spender"])
    assert.equal(0, d.chipsShown)
  end)

  it("links the selected customer to a main, lists the group, and unlinks", function()
    local v = open()
    local d = v.detail
    click(row_for(v, "Cat-Silvermoon"))
    d.linkEdit:Type(" Bob ")
    click(d.link)
    assert.equal("Bob-Silvermoon", C:Get("Cat-Silvermoon").linkedTo)
    assert.equal(1, v.list.shown)   -- Cat now shows under Bob
    assert.equal("Cat-Silvermoon (alt of Bob-Silvermoon)", d.title:GetText())
    assert.equal("Bob-Silvermoon", d.linkEdit:GetText()); assert.is_true(d.unlink:IsEnabled())
    assert.same({ 1, "Bob-Silvermoon" }, { d.groupShown, d.group[1].value })
    -- A group chip selects that character.
    click(d.group[1])
    assert.equal("Bob-Silvermoon", d.title:GetText())
    assert.equal(2, d.history.shown)
    assert.same({ 1, "Cat-Silvermoon" }, { d.groupShown, d.group[1].value })
    click(d.group[1])
    click(d.unlink)
    assert.is_nil(C:Get("Cat-Silvermoon").linkedTo)
    assert.equal(2, v.list.shown)
    assert.equal("", d.linkEdit:GetText()); assert.is_false(d.unlink:IsEnabled())
  end)

  it("says why a link was refused", function()
    local v = open()
    local d = v.detail
    click(row_for(v, "Bob-Silvermoon"))
    click(d.link)
    assert.is_truthy(v.status:GetText():find("Type the main character's name", 1, true))
    d.linkEdit:Type("Bob")
    d.linkEdit:GetScript("OnEnterPressed")(d.linkEdit)
    assert.is_truthy(v.status:GetText():find("cannot be its own alt", 1, true))
    assert.is_nil(C:Get("Bob-Silvermoon").linkedTo)
  end)

  it("writes nothing and says so while the saved data is from a newer version", function()
    local v = open()
    local d = v.detail
    click(row_for(v, "Bob-Silvermoon"))
    ns.FS.dbIsNewer = true
    click(d.vip)
    assert.is_nil(C:Get("Bob-Silvermoon").tags.VIP)
    assert.is_truthy(v.status:GetText():lower():find("read-only", 1, true))
    d.notes:SetFocus(); d.notes:Type("x"); d.notes:ClearFocus()
    assert.equal("", C:Get("Bob-Silvermoon").notes)
    assert.equal("", d.notes:GetText())   -- the stored note is back in the box
    d.linkEdit:Type("Cat"); click(d.link)
    assert.is_nil(C:Get("Bob-Silvermoon").linkedTo)
    assert.is_truthy(v.status:GetText():lower():find("read-only", 1, true))
    -- The controls are disabled and the notice stays up.
    for _, w in ipairs({ d.vip, d.blocked, d.notes, d.tagEdit, d.tagAdd, d.linkEdit, d.link, d.unlink }) do
      assert.is_false(w:IsEnabled())
    end
    W.now = W.now + 60
    reg.customers.refresh(container)
    assert.is_truthy(v.status:GetText():lower():find("read-only", 1, true))
    ns.FS.dbIsNewer = nil
    reg.customers.refresh(container)
    assert.is_true(d.vip:IsEnabled()); assert.is_true(d.notes:IsEnabled()); assert.is_false(d.unlink:IsEnabled())
  end)

  it("starts the read-only notice with Read-only, from the first refresh, with the full text in a tooltip", function()
    ns.FS.dbIsNewer = true
    local v = open(516)
    local plain = v.status:GetText():gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    assert.equal("Read-only", plain:sub(1, 9))
    v.statusArea:GetScript("OnEnter")(v.statusArea)
    assert.equal(v.status:GetText(), tooltip.lines[1])
    assert.is_truthy(tooltip.lines[1]:find("newer addon version", 1, true))
  end)

  it("disables the tag chips and their +N while read-only, but not the group's +N", function()
    for i = 1, 8 do C:SetTag("Bob-Silvermoon", "tag-number-" .. i, true) end
    for i = 1, 3 do C:Link(("Alt%d-Silvermoon"):format(i), "Bob-Silvermoon") end
    local v = open(516)
    local d = v.detail
    click(row_for(v, "Bob-Silvermoon"))
    assert.is_true(d.chips[1]:IsEnabled()); assert.is_true(d.chipsMore:IsEnabled())
    ns.FS.dbIsNewer = true
    reg.customers.refresh(container)
    assert.is_false(d.chips[1]:IsEnabled()); assert.is_false(d.chipsMore:IsEnabled())
    assert.is_true(d.groupMore:IsShown()); assert.is_true(d.groupMore:IsEnabled())
  end)

  it("exports the visible customers and their alts into a read-only, pre-selected box", function()
    C:RecordOrder("Alt-Silvermoon", order(3, 400, 5))
    C:Link("Alt-Silvermoon", "Bob-Silvermoon")
    local exported
    local export = C.Export
    C.Export = function(self, names) exported = names; return export(self, names) end
    local v = open()
    v.search:Type("bob")
    click(v.exportButton)
    assert.same({ "Bob-Silvermoon", "Alt-Silvermoon" }, exported)
    local dialog = v.dialog
    assert.is_true(dialog.frame:IsShown())
    local text = C:Export({ "Bob-Silvermoon", "Alt-Silvermoon" })
    assert.equal(text, dialog.edit:GetText())
    assert.is_true(dialog.edit:HasFocus()); assert.is_true(dialog.edit.highlighted > 0)
    dialog.edit:Type("edited")
    assert.equal(text, dialog.edit:GetText())
    dialog.edit:GetScript("OnEscapePressed")(dialog.edit)
    assert.is_false(dialog.frame:IsShown())
    local found = false
    for _, name in ipairs(UISpecialFrames) do if name == dialog.frame:GetName() then found = true end end
    assert.is_true(found)
  end)

  it("refreshes the whole list once after a burst of customer changes", function()
    local v = open()
    C:RecordOrder("Dan-Silvermoon", order(4, 950, 1))
    C:SetNote("Dan-Silvermoon", "hi")
    assert.same({}, refreshed)
    W.advance(1)
    assert.same({ "customers" }, refreshed)
    assert.equal(3, v.list.shown); assert.equal("Dan-Silvermoon", v.list.pool[1].data.nameRealm)
  end)

  it("stops listening and cancels the pending refresh when turned off", function()
    open()
    C:SetNote("Bob-Silvermoon", "x")
    ns.FS:GetModule("CustomersTab"):Disable()
    W.advance(5)
    C:SetNote("Bob-Silvermoon", "y")
    W.advance(5)
    assert.same({}, refreshed)
  end)

  it("asks once for an uncached item and refreshes when its data arrives", function()
    local asked = {}
    _G.C_Item.RequestLoadItemDataByID = function(id) asked[#asked + 1] = id end
    local v = open()
    click(row_for(v, "Bob-Silvermoon"))
    reg.customers.refresh(container)
    assert.same({ 5 }, asked)
    W.fire("GET_ITEM_INFO_RECEIVED", 99, true)
    W.advance(1)
    assert.same({}, refreshed)
    W.fire("GET_ITEM_INFO_RECEIVED", 5, true)
    W.advance(1)
    assert.same({ "customers" }, refreshed)
  end)
end)
