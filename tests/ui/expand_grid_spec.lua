local P2 = require("tests.helpers.phase2")

-- Strips colour codes, so a cell can be compared with its plain text.
local function plain(text)
  return (tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

local function point(region, i) return { region:GetPoint(i or 1) } end

local function boot(overrides)
  local ns, W = P2.boot(overrides)
  P2.load(ns, { "UI/Widgets/ExpandGrid.lua", "UI/Tabs/ViewUtil.lua", "UI/Tabs/CharactersView.lua" })
  return ns, W
end

describe("ExpandGrid.Layout", function()
  local G
  before_each(function()
    local ns = boot()
    G = ns.UI.ExpandGrid
  end)

  it("Layout inserts detail rows", function()
    local l = G.Layout({ { key = "a" }, { key = "b", detailHeight = 60 }, { key = "c" } }, { b = true }, 20)
    assert.same({ { key = "a", kind = "row", height = 20 }, { key = "b", kind = "row", height = 20 },
      { key = "b", kind = "detail", height = 60 }, { key = "c", kind = "row", height = 20 } }, l)
  end)

  it("expands only rows with a positive detail height and skips entries without a key", function()
    local l = G.Layout({ { key = "a", detailHeight = 0 }, { key = "b" }, "junk", { detailHeight = 5 },
      { key = "c", detailHeight = "x" } }, { a = true, b = true, c = true })
    assert.same({ { key = "a", kind = "row", height = 20 }, { key = "b", kind = "row", height = 20 },
      { key = "c", kind = "row", height = 20 } }, l)
    assert.same({}, G.Layout(nil, nil, 20))
    assert.same({ { key = "a", kind = "row", height = 20 } }, G.Layout({ { key = "a", detailHeight = 9 } }, nil, -3))
  end)
end)

describe("ExpandGrid.ColumnLayout", function()
  local G
  local COLS = { { key = "name", flex = true }, { key = "a", width = 100 }, { key = "b", width = 100 },
    { key = "c", width = 50 } }
  before_each(function()
    local ns = boot()
    G = ns.UI.ExpandGrid
  end)

  it("gives the flexible column what the fixed ones leave (6 px padding each side, 4 px gaps)", function()
    assert.same({ hidden = {}, flex = 600 - 12 - 250 - 12 }, G.ColumnLayout(COLS, 600, { hideOrder = { "c" } }))
  end)

  it("hides by priority (single keys or groups) until the flexible column keeps its minimum", function()
    local l = G.ColumnLayout(COLS, 300, { hideOrder = { "c", { "a", "b" } } })
    assert.same({ hidden = { a = true, b = true, c = true }, flex = 288 }, l)
    l = G.ColumnLayout(COLS, 380, { hideOrder = { "c", { "a", "b" } } })   -- 106 px before hiding c
    assert.same({ hidden = { c = true }, flex = 380 - 12 - 200 - 8 }, l)
    assert.same({ hidden = {}, flex = 126 }, G.ColumnLayout(COLS, 400, { hideOrder = { "c" } }))
    assert.same({ hidden = {}, flex = 26 }, G.ColumnLayout(COLS, 300, {}))   -- nothing hideable
    assert.same({ hidden = { c = true }, flex = 80 }, G.ColumnLayout(COLS, 300, { hideOrder = { "c" }, minFlex = 50 }))
  end)

  it("hides nothing while the width is unknown", function()
    assert.same({ hidden = {} }, G.ColumnLayout(COLS, nil, { hideOrder = { "c" } }))
    assert.same({ hidden = {} }, G.ColumnLayout(COLS, 0, { hideOrder = { "c" } }))
  end)
end)

describe("ExpandGrid.New", function()
  local ns, G, parent, tooltip
  local COLS = { { key = "name", label = "Name", flex = true }, { key = "x", label = "X", width = 100, right = true },
    { key = "y", label = "Y", width = 80 } }

  local function rows(n, detailEvery)
    local out = {}
    for i = 1, n do
      out[i] = { key = "k" .. i, detailHeight = (detailEvery and i % detailEvery == 0) and 60 or nil,
        cells = { name = "Row " .. i, x = tostring(i), y = "y" .. i } }
    end
    return out
  end

  local function find_row(grid, key)
    for i = 1, grid.shownRows do
      local f = grid.rowPool[i]
      if f.data and f.data.key == key then return f end
    end
  end

  before_each(function()
    tooltip = { lines = {} }
    ns = boot({
      GameTooltip = {
        SetOwner = function() tooltip.lines = {} end,
        SetText = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
        AddLine = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
        Show = function() tooltip.shown = true end,
        Hide = function() tooltip.shown = false end,
      },
    })
    G = ns.UI.ExpandGrid
    parent = CreateFrame("Frame")
    parent:SetSize(516, 200)
  end)

  it("builds a header row of column labels and renders rows through the default renderer (row.cells)", function()
    local grid = G.New(parent, COLS, { hideOrder = { "y" }, source = "Tab:test" })
    assert.same({ "Name", "X", "Y" }, { grid.headers[1]:GetText(), grid.headers[2]:GetText(), grid.headers[3]:GetText() })
    grid:SetRows(rows(3))
    assert.equal(3, grid.shownRows)
    local r2 = find_row(grid, "k2")
    assert.same({ "Row 2", "2", "y2" }, { r2.cells.name:GetText(), r2.cells.x:GetText(), r2.cells.y:GetText() })
    -- Rows are anchored on both edges of the scroll child, one row height apart.
    assert.same({ "TOPLEFT", grid.child, "TOPLEFT", 0, -20 }, point(r2, 1))
    assert.same({ "TOPRIGHT", grid.child, "TOPRIGHT", 0, -20 }, point(r2, 2))
  end)

  it("calls the row renderer with the frame, the row and the column layout", function()
    local grid = G.New(parent, COLS, { hideOrder = { "y" } })
    local seen = {}
    grid:SetRowRenderer(function(frame, row, layout)
      seen[#seen + 1] = row.key
      frame.cells.name:SetText("R:" .. row.key)
      assert.is_table(layout.hidden)
    end)
    grid:SetRows(rows(2))
    assert.same({ "k1", "k2" }, seen)
    assert.equal("R:k2", find_row(grid, "k2").cells.name:GetText())
  end)

  it("toggles a detail row under a clicked row and shifts the rows below it", function()
    local grid = G.New(parent, COLS, {})
    local details = {}
    grid:SetDetailRenderer(function(frame, row) details[#details + 1] = row.key; frame.text:SetText("detail " .. row.key) end)
    grid:SetRows(rows(3, 2))   -- k2 has a 60 px detail
    local r2 = find_row(grid, "k2")
    r2:GetScript("OnClick")(r2)
    assert.is_true(grid:IsExpanded("k2"))
    assert.same({ "row", "row", "detail", "row" },
      { grid.entries[1].kind, grid.entries[2].kind, grid.entries[3].kind, grid.entries[4].kind })
    assert.equal(1, grid.shownDetails)
    local d = grid.detailPool[1]
    assert.same({ "TOPLEFT", grid.child, "TOPLEFT", 0, -40 }, point(d, 1))
    assert.same({ "TOPRIGHT", grid.child, "TOPRIGHT", 0, -40 }, point(d, 2))
    assert.equal(60, d:GetHeight())
    assert.same({ "k2" }, details)
    assert.equal("detail k2", d.text:GetText())
    assert.same({ "TOPLEFT", grid.child, "TOPLEFT", 0, -100 }, point(find_row(grid, "k3"), 1))
    assert.is_true(find_row(grid, "k2").expanded)
    -- A second click collapses it again.
    r2 = find_row(grid, "k2")
    r2:GetScript("OnClick")(r2)
    assert.is_false(grid:IsExpanded("k2"))
    assert.equal(0, grid.shownDetails)
    assert.is_false(d:IsShown())
    assert.same({ "TOPLEFT", grid.child, "TOPLEFT", 0, -40 }, point(find_row(grid, "k3"), 1))
  end)

  it("does not expand a row without detail, and keeps an expansion across SetRows", function()
    local grid = G.New(parent, COLS, {})
    grid:SetRows(rows(3, 2))
    assert.is_false(grid:Toggle("k1"))
    assert.is_false(grid:Toggle("nope"))
    assert.equal(3, #grid.entries)
    assert.is_nil(grid.expanded.k1)
    grid:Toggle("k2")
    grid:SetRows(rows(3, 2))
    assert.equal(4, #grid.entries)
    assert.equal(3 * 20 + 60, grid.child:GetHeight())   -- 3 rows + one detail
  end)

  it("binds only the rows in view to pooled frames and rebinds on scroll", function()
    local grid = G.New(parent, COLS, {})
    grid.scroll.GetHeight = function() return 100 end
    grid:SetRows(rows(200))
    assert.is_true(#grid.rowPool <= 7)
    assert.equal("Row 1", grid.rowPool[1].cells.name:GetText())
    grid.scroll.GetVerticalScroll = function() return 2000 end
    grid.scroll:GetScript("OnVerticalScroll")(grid.scroll, 2000)
    assert.is_true(#grid.rowPool <= 7)
    assert.is_truthy(find_row(grid, "k101"))
    assert.is_nil(find_row(grid, "k1"))
  end)

  it("lays the columns out from both edges and hides by priority on a size change", function()
    local grid = G.New(parent, COLS, { hideOrder = { "y" } })
    grid:SetRows(rows(1))
    local r = grid.rowPool[1]
    -- 516 px: 504 - 100 - 80 - 8 = 316 for Name, nothing hidden.
    assert.same({ "LEFT", r, "LEFT", 6, 0 }, point(r.cells.name, 1))
    assert.same({ "RIGHT", r.cells.x, "LEFT", -4, 0 }, point(r.cells.name, 2))
    assert.same({ "RIGHT", r, "RIGHT", -6, 0 }, point(r.cells.y)); assert.equal(80, r.cells.y:GetWidth())
    assert.same({ "RIGHT", r.cells.y, "LEFT", -4, 0 }, point(r.cells.x)); assert.equal(100, r.cells.x:GetWidth())
    assert.same({ "RIGHT", grid.headers[2], "LEFT", -4, 0 }, point(grid.headers[1], 2))
    -- Narrower: Y is hidden and X moves to the right edge (header too).
    parent:SetSize(300, 200)
    parent:GetScript("OnSizeChanged")(parent, 300, 200)
    assert.is_false(r.cells.y:IsShown()); assert.is_false(grid.headers[3]:IsShown())
    assert.same({ "RIGHT", r, "RIGHT", -6, 0 }, point(r.cells.x))
    assert.same({ "RIGHT", r.cells.x, "LEFT", -4, 0 }, point(r.cells.name, 2))
    assert.same({ y = true }, grid.layout.hidden)
    -- Wider again: back.
    parent:SetSize(516, 200)
    parent:GetScript("OnSizeChanged")(parent, 516, 200)
    assert.is_true(r.cells.y:IsShown()); assert.is_true(grid.headers[3]:IsShown())
    assert.same({ "RIGHT", r.cells.y, "LEFT", -4, 0 }, point(r.cells.x))
  end)

  it("shows the row tooltip on hover and hides it on leave", function()
    local grid = G.New(parent, COLS, {})
    grid:SetTooltip(function(row) return { row.cells.name, { text = "full " .. row.key, color = { 1, 0, 0 } } } end)
    grid:SetRows(rows(1))
    local r = grid.rowPool[1]
    r:GetScript("OnEnter")(r)
    assert.is_true(tooltip.shown)
    assert.same({ "Row 1", "full k1" }, tooltip.lines)
    r:GetScript("OnLeave")(r)
    assert.is_false(tooltip.shown)
  end)

  it("isolates a failing click handler (SafeCall under the grid's source)", function()
    local grid = G.New(parent, COLS, { source = "Tab:test" })
    grid:SetRows(rows(2, 2))
    grid:SetDetailRenderer(function() error("boom") end)
    local r = find_row(grid, "k2")
    assert.has_no.errors(function() r:GetScript("OnClick")(r) end)
  end)

  it("lays the Characters columns out at the 516 px minimum: Character at 128 px, Profession 1, Concentration 1, KP 1 and Age", function()
    local V = ns.UI.CharactersView
    local grid = G.New(parent, V.COLUMNS, { hideOrder = V.HIDE_ORDER, minFlex = 120 })
    grid:SetRows({ { key = "Aria-Silvermoon", cells = { name = "Aria" } } })
    local r = grid.rowPool[1]
    local c = r.cells
    local function placed(key) return r.slots[key] or c[key] end   -- a profession slot is a frame (label + badge)
    assert.equal(128, grid.layout.flex)
    assert.same({ "RIGHT", r, "RIGHT", -6, 0 }, point(c.age)); assert.equal(70, c.age:GetWidth())
    assert.same({ "RIGHT", c.age, "LEFT", -4, 0 }, point(c.kp1)); assert.equal(40, c.kp1:GetWidth())
    assert.same({ "RIGHT", c.kp1, "LEFT", -4, 0 }, point(c.conc1)); assert.equal(120, c.conc1:GetWidth())
    assert.same({ "RIGHT", c.conc1, "LEFT", -4, 0 }, point(r.slots.prof1)); assert.equal(130, r.slots.prof1:GetWidth())
    assert.same({ "LEFT", r, "LEFT", 6, 0 }, point(c.name, 1))
    assert.same({ "RIGHT", r.slots.prof1, "LEFT", -4, 0 }, point(c.name, 2))
    for _, key in ipairs({ "spec1", "moxie1", "cds1", "prof2", "conc2", "kp2", "spec2", "moxie2", "cds2", "gold" }) do
      assert.is_false(placed(key):IsShown(), key)
    end
    assert.is_true(c.age:IsShown())
    -- At the default window width (716 px) Spec 1 and Gold come back; slot 2 stays hidden.
    parent:SetSize(716, 200)
    parent:GetScript("OnSizeChanged")(parent, 716, 200)
    assert.is_true(c.spec1:IsShown()); assert.is_true(c.gold:IsShown())
    assert.is_false(placed("prof2"):IsShown())
    assert.same({ "RIGHT", c.gold, "LEFT", -4, 0 }, point(c.spec1))
    assert.equal("Aria", plain(c.name:GetText()))
  end)
  it("keeps the profession '+N' visible at 516 px: a right-anchored badge the long label ends before", function()
    local V = ns.UI.CharactersView
    local grid = G.New(parent, V.COLUMNS, { hideOrder = V.HIDE_ORDER })
    local prof = { label = "Leatherworking", skill = "100/100", conc = "1/2", kp = "1", spec = "x", moxie = "1", cds = "x" }
    local display = { charKey = "Bren-Silvermoon", name = "Bren", gold = "5s 0c", goldShort = "5s", age = "2h",
      staleAge = false, profs = { prof, prof } }
    local cells, badges = V.CellTexts(display, grid.layout)
    assert.same({ prof1 = "+1" }, badges)
    grid:SetRows({ { key = "Bren-Silvermoon", cells = cells, badges = badges } })
    local r = grid.rowPool[1]
    local slot, label, badge = r.slots.prof1, r.cells.prof1, r.badges.prof1
    assert.equal("Leatherworking 100/100", label:GetText())
    assert.same({ "+1", true }, { badge:GetText(), badge:IsShown() })
    assert.same({ "RIGHT", slot, "RIGHT", 0, 0 }, point(badge))
    assert.same({ "LEFT", slot, "LEFT", 0, 0 }, point(label, 1))
    assert.same({ "RIGHT", badge, "LEFT", -2, 0 }, point(label, 2))
    assert.equal(130, slot:GetWidth())
    -- Wide enough for both slots: no badge, the label reaches the slot's right edge again.
    parent:SetSize(1400, 200)
    parent:GetScript("OnSizeChanged")(parent, 1400, 200)
    cells, badges = V.CellTexts(display, grid.layout)
    grid:SetRows({ { key = "Bren-Silvermoon", cells = cells, badges = badges } })
    assert.equal("", r.badges.prof1:GetText())
    assert.same({ "RIGHT", r.badges.prof1, "LEFT", 0, 0 }, point(r.cells.prof1, 2))
  end)

  it("sizes a detail for its wrapped text at the current width and relayouts it on a width change alone", function()
    local real = CreateFrame
    local clips = {}
    _G.CreateFrame = function(...)
      local f = real(...)
      f.SetClipsChildren = function(self, on) clips[self] = on end
      return f
    end
    local V = ns.UI.CharactersView
    local line = V.KnowledgeBreakdown({ status = "unknown", darkmoon = "unknown" })
    assert.is_true(#line > 85)
    local grid = G.New(parent, COLS, { hideOrder = { "y" } })
    local rowsWithDetail = {
      { key = "a", cells = { name = "A" }, detail = line .. "\n" .. line,
        detailHeight = function(_, width) return G.WrappedHeight({ line, line }, width) end },
      { key = "b", cells = { name = "B" } },
    }
    parent:SetSize(1400, 200)
    parent:GetScript("OnSizeChanged")(parent, 1400, 200)
    grid:SetRows(rowsWithDetail)
    grid:Toggle("a")
    local d = grid.detailPool[1]
    _G.CreateFrame = real
    assert.is_true(clips[d])
    assert.equal(2 * 14 + 4, d:GetHeight())                 -- one line each at 1400 px
    -- 516 px: the hidden set does not change (Y still fits), the width does: two lines each.
    parent:SetSize(516, 200)
    parent:GetScript("OnSizeChanged")(parent, 516, 200)
    assert.same({}, grid.layout.hidden)
    assert.equal(4 * 14 + 4, d:GetHeight())
    assert.same({ "TOPLEFT", grid.child, "TOPLEFT", 0, -(20 + 60) }, point(find_row(grid, "b"), 1))
    assert.equal(line .. "\n" .. line, d.text:GetText())
  end)

  it("clears a reused detail frame before rendering another row's detail", function()
    local grid = G.New(parent, COLS, {})
    grid:SetDetailRenderer(function(frame, row) if row.key == "k2" then frame.text:SetText("only k2") end end)
    grid:SetRows(rows(4, 2))   -- k2 and k4 have details
    grid:Toggle("k2"); grid:Toggle("k4")
    assert.equal(2, grid.shownDetails)
    assert.equal("only k2", grid.detailPool[1].text:GetText())
    grid:Toggle("k2")
    assert.equal(1, grid.shownDetails)
    assert.equal("k4", grid.detailPool[1].data.key)
    assert.equal("", grid.detailPool[1].text:GetText())
  end)

  it("shows a header label's tooltip on hover (a narrow header may truncate)", function()
    local V = ns.UI.CharactersView
    local grid = G.New(parent, V.COLUMNS, { hideOrder = V.HIDE_ORDER })
    local hit = grid.headerHits[4]   -- KP 1
    hit:GetScript("OnEnter")(hit)
    assert.same({ "Profession 1: Knowledge points left this week" }, tooltip.lines)
    hit:GetScript("OnLeave")(hit)
    assert.is_false(tooltip.shown)
    assert.is_false(grid.headerHits[5]:IsShown())   -- Spec 1 is hidden at 516 px
    grid.headerHits[1]:GetScript("OnEnter")(grid.headerHits[1])
    assert.same({ "Character" }, tooltip.lines)
  end)

  -- [Task 13, Task 12 minor] The detail text's own height wins over the estimate once the client can measure it.
  it("sizes an open detail by its measured text height (plus the row's detailFooter) when the client reports one", function()
    local grid = G.New(parent, COLS, {})
    local function entry(key, kind)
      for _, e in ipairs(grid.entries) do if e.key == key and e.kind == kind then return e end end
    end
    grid:SetRows({ { key = "a", cells = { name = "A" }, detail = "x", detailHeight = 60 }, { key = "b", cells = { name = "B" } } })
    grid:Toggle("a")
    assert.equal(60, entry("a", "detail").height)   -- the stub font string cannot measure: the estimate stays
    local text = grid.detailPool[1].text
    text.GetStringHeight = function() return 41.5 end
    grid:Refresh()
    assert.equal(60, entry("a", "detail").height)   -- no laid-out width yet: an unwrapped height is not trusted
    text.GetWidth = function() return 488 end
    grid:Refresh()
    assert.equal(42 + 4, entry("a", "detail").height)
    assert.equal(20 + 46, entry("b", "row").top)
    assert.same({ "TOPLEFT", grid.child, "TOPLEFT", 0, -(20 + 46) }, point(find_row(grid, "b"), 1))
    -- A footer (room for buttons under the text) is added to the measured height.
    grid:SetRows({ { key = "a", cells = { name = "A" }, detail = "x", detailHeight = 60, detailFooter = 28 },
      { key = "b", cells = { name = "B" } } })
    assert.equal(42 + 4 + 28, entry("a", "detail").height)
    -- No usable measurement: back to the estimate.
    text.GetStringHeight = function() return 0 end
    grid:SetRows({ { key = "a", cells = { name = "A" }, detail = "x", detailHeight = 60 }, { key = "b", cells = { name = "B" } } })
    grid:Refresh()
    assert.equal(60, entry("a", "detail").height)
  end)
end)

describe("ExpandGrid.WrappedHeight", function()
  local G
  before_each(function() G = boot().UI.ExpandGrid end)

  it("counts each line of a multi-line string (split on newlines)", function()
    assert.equal(2 * 14 + 4, G.WrappedHeight({ "a\nb" }, nil))
    assert.equal(3 * 14 + 4, G.WrappedHeight({ "a\nb", "c" }, nil))
    assert.equal(3 * 14 + 4, G.WrappedHeight({ "a\n\nb" }, nil))   -- an empty line still takes a line
    -- Each part wraps on its own: 100 px leaves (100 - 28) / 6 = 12 characters per line.
    assert.equal((1 + 2) * 14 + 4, G.WrappedHeight({ "short\n" .. string.rep("x", 20) }, 100))
  end)
end)
