local P2 = require("tests.helpers.phase2")

describe("Ledger tab and widgets", function()
  local ns, reg, widgets
  before_each(function()
    ns = P2.boot({ C_DateAndTime = { GetSecondsUntilWeeklyReset = function() return 1 end } }); reg, widgets = {}, {}
    P2.fake_module(ns, "MainWindow", { RegisterTab = function(_, id, def) reg[id] = def end })
    P2.fake_module(ns, "Dashboard", { RegisterWidget = function(_, id, def) widgets[id] = def end })
    P2.load(ns, {"Modules/Customers.lua", "Data/OrderRewards.lua", "Modules/Orders.lua", "Modules/Ledger.lua", "UI/Tabs/Ledger.lua", "UI/OrdersWidgets.lua"})
  end)
  it("registers tab and widgets", function()
    assert.same({"Ledger", 60}, {reg.ledger.label, reg.ledger.order})
    assert.same({40, "Open orders", 50, "Gold this week"}, {widgets.openOrders.order, widgets.openOrders.title, widgets.goldThisWeek.order, widgets.goldThisWeek.title})
  end)
  it("sorts recipe rows by profit", function()
    local rows = ns.UI.LedgerTab.RecipeRows({ [1] = {income=5, cost=0, profit=5, n=1, incomplete=0}, [2] = {income=9, cost=1, profit=8, n=1, incomplete=0} })
    assert.same({2, 1}, {rows[1].recipeID, rows[2].recipeID})
  end)
  it("builds benchmark rows from commission history", function()
    local L = ns.FS:GetModule("Ledger")
    for _, t in ipairs({100, 200, 300}) do L:Add({type="commission", amount=t, tip=t, recipeID=4444, quality=3}) end
    L:Add({type="commission", amount=1, tip=1, recipeID=4444, quality=2})
    assert.same({ {recipeID=4444, quality=3, median=200, p25=150, p75=250, n=3} }, ns.UI.LedgerTab.BenchmarkRows(L:Query({type="commission"})))
  end)
  it("models the dashboard widgets", function()
    local W = ns.UI.OrdersWidgets
    assert.same({total=2, personal=1, bestScore=50, age=600},
      W.OpenOrdersModel({time=400, orders={ {orderType="personal", score=50}, {orderType="public", score=nil} }}, 1000))
    assert.same({total=0, personal=0}, W.OpenOrdersModel({orders={}}, 1000))
    assert.same({profit=7, income=9, incomplete=1}, W.GoldThisWeekModel({ {weekStart=0, income=9, cost=2, profit=7, incomplete=1} }))
  end)
end)

-- Strips colour codes, so a cell can be compared with its plain text.
local function plain(text)
  return (tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

local FILES = { "Modules/Customers.lua", "Data/OrderRewards.lua", "Modules/Orders.lua", "Modules/Ledger.lua",
  "UI/Tabs/Ledger.lua", "UI/OrdersPanel.lua", "UI/OrdersWidgets.lua" }
local WEEK = 604800

describe("Ledger tab models", function()
  local ns, T, L, reg
  before_each(function()
    -- The weekly reset is 100 s away, so the current week started at now + 100 - WEEK.
    ns = P2.boot({ C_DateAndTime = { GetSecondsUntilWeeklyReset = function() return 100 end } }); reg = {}
    P2.fake_module(ns, "MainWindow", { RegisterTab = function(_, id, def) reg[id] = def; return true end })
    P2.fake_module(ns, "Dashboard", { RegisterWidget = function() return true end })
    P2.load(ns, FILES)
    T = ns.UI.LedgerTab
    L = ns.FS:GetModule("Ledger")
  end)

  it("registers as phase 2 with its icon and is a core module", function()
    assert.same({ 2, "Interface\\Icons\\INV_Misc_Coin_02" }, { reg.ledger.phase, reg.ledger.icon })
    assert.is_function(reg.ledger.build); assert.is_function(reg.ledger.refresh)
    assert.is_true(ns.FS:GetModule("LedgerTab").coreModule)
    assert.is_true(ns.FS:GetModule("OrdersWidgets").coreModule)
  end)

  it("sorts recipe rows by profit, unknown profit last, ties by recipeID, and copies the totals", function()
    local byRecipe = {
      [7] = { income = 5, cost = 0, profit = 5, n = 1, incomplete = 0 },
      [3] = { income = 5, cost = 0, profit = 5, n = 2, incomplete = 1 },
      [9] = { income = 1, cost = 9, profit = -8, n = 1, incomplete = 0 },
    }
    local rows = T.RecipeRows(byRecipe)
    assert.same({ 3, 7, 9 }, { rows[1].recipeID, rows[2].recipeID, rows[3].recipeID })
    assert.same({ recipeID = 3, income = 5, cost = 0, profit = 5, n = 2, incomplete = 1 }, rows[1])
    rows[1].profit = 99
    assert.equal(5, byRecipe[3].profit)
    assert.same({}, T.RecipeRows(nil))
  end)

  it("benchmarks every recipe and quality with enough commissions, sorted, leaving recrafts and unknown quality out", function()
    -- (a recipe with only unknown-quality commissions gets one all-qualities row; see the next spec)
    for _, t in ipairs({ 10, 20, 30 }) do
      L:Add({ type = "commission", amount = t, tip = t, recipeID = 9, quality = 2 })
      L:Add({ type = "commission", amount = t, tip = t, recipeID = 5, quality = 3 })
      L:Add({ type = "commission", amount = t, tip = t, recipeID = 5, quality = 1 })
      L:Add({ type = "commission", amount = t, tip = t, recipeID = 5 })   -- no quality on a recipe with qualities: no row
      L:Add({ type = "commission", amount = t, tip = t, recipeID = 6, quality = 3, recraft = true })
    end
    L:Add({ type = "sale", amount = 5, recipeID = 4, quality = 3 })
    local rows = T.BenchmarkRows(L:Query({}))
    local keys = {}
    for i, r in ipairs(rows) do keys[i] = r.recipeID .. ":" .. r.quality end
    assert.same({ "5:1", "5:3", "9:2" }, keys)
    assert.same({ recipeID = 5, quality = 1, median = 20, p25 = 15, p75 = 25, n = 3 }, rows[1])
  end)

  it("gives a recipe whose commissions have no quality one all-qualities row, shown as quality -", function()
    for _, t in ipairs({ 10, 20, 30 }) do
      L:Add({ type = "commission", amount = t, tip = t, recipeID = 8 })
      L:Add({ type = "commission", amount = t, tip = t, recipeID = 3, quality = 2 })
    end
    L:Add({ type = "commission", amount = 99, tip = 99, recipeID = 7 })   -- too few samples: no row
    local rows = T.BenchmarkRows(L:Query({}))
    assert.equal(2, #rows)
    assert.same({ recipeID = 3, quality = 2, median = 20, p25 = 15, p75 = 25, n = 3 }, rows[1])
    assert.same({ recipeID = 8, median = 20, p25 = 15, p75 = 25, n = 3 }, rows[2])
    assert.equal("-", T.CellTexts("benchmark", rows[2]).quality)
    assert.is_truthy(T.TooltipLines({ kind = "row", section = "benchmark", data = rows[2] })[1].text:find("all qualities", 1, true))
  end)

  it("keeps the flexible column of every section at 120 px or more at the 516 px minimum", function()
    for _, section in ipairs({ "weekly", "recipe", "benchmark", "entry" }) do
      local layout = T.Layout(section, 516)
      assert.same({}, layout.hidden, section)
      assert.is_true(layout.flex >= 120, section .. " " .. tostring(layout.flex))
    end
    assert.equal(226, T.Layout("entry", 516).flex)
    -- Narrower: the low-priority columns go first, in order.
    assert.same({ customer = true }, T.Layout("entry", 380).hidden)
    assert.same({ customer = true, type = true }, T.Layout("entry", 300).hidden)
    assert.same({ n = true }, T.Layout("recipe", 440).hidden)
    assert.same({ p25 = true }, T.Layout("benchmark", 380).hidden)
    -- An unknown width hides nothing.
    assert.same({}, T.Layout("entry", nil).hidden)
  end)

  it("models 8 weeks with a total, counting partial and estimated entries per week", function()
    local now = 1000
    local current = now + 100 - WEEK
    L:Add({ type = "commission", amount = 900, tip = 1000, recipeID = 5, quality = 3, cost = 200, time = current + 10 })
    L:Add({ type = "sale", amount = 300, recipeID = 5, time = current + 20 })                          -- no cost basis
    L:Add({ type = "sale", amount = 100, cost = 40, estimated = true, time = current - 10 })              -- last week
    L:Add({ type = "commission", amount = 50, recraft = true, recipeID = 6, time = current - WEEK - 5 })  -- recraft
    L:Add({ type = "craft", amount = -200, recipeID = 5, time = current + 5 })                           -- cost record
    L:Add({ type = "sale", amount = 7777, recipeID = 9, time = current - 8 * WEEK + 1 })                -- before the 8 weeks
    L:Add({ type = "sale", amount = 8888, time = current - 8 * WEEK + 1 })                              -- the same, unattributed
    local live = L:Query({})
    local before = P2.merge({}, live)   -- a deep copy
    local m = T.Model(L, now)
    assert.equal(7, m.count)
    assert.equal(8, #m.weekly.rows)
    local w1, w2, w3 = m.weekly.rows[1], m.weekly.rows[2], m.weekly.rows[3]
    assert.same({ current, 1200, 200, 1000, 1 }, { w1.weekStart, w1.income, w1.cost, w1.profit, w1.incomplete })
    assert.is_nil(w1.estimated)
    assert.same({ 100, 40, 60, 0, 1 }, { w2.income, w2.cost, w2.profit, w2.incomplete, w2.estimated })
    assert.same({ 50, 0, 50, 1 }, { w3.income, w3.cost, w3.profit, w3.incomplete })
    local total = m.weekly.total
    assert.same({ 1350, 240, 1110, 2, 1 }, { total.income, total.cost, total.profit, total.incomplete, total.estimated })
    -- Per recipe over the same 8 weeks, best first, and the unattributed sale on its own row so the totals add up.
    assert.equal(2, #m.recipes)
    assert.same({ 5, 6 }, { m.recipes[1].recipeID, m.recipes[2].recipeID })
    assert.same({ 1200, 200, 1000, 2, 1 }, { m.recipes[1].income, m.recipes[1].cost, m.recipes[1].profit, m.recipes[1].n, m.recipes[1].incomplete })
    assert.same({ 100, 40, 60, 1, 0, 1 }, { m.unattributed.income, m.unattributed.cost, m.unattributed.profit,
      m.unattributed.n, m.unattributed.incomplete, m.unattributed.estimated })
    assert.equal(total.income, m.recipes[1].income + m.recipes[2].income + m.unattributed.income)
    -- Every entry is listed, newest first, and the saved rows are left exactly as they were.
    assert.equal(7, #m.entries)
    assert.equal(current + 20, m.entries[1].time)
    T.DisplayRows(m)
    for i, row in ipairs(live) do T.CellTexts("entry", row); T.TooltipLines({ kind = "row", section = "entry", data = row }); assert.same(before[i], row) end
    assert.same(before, L:Query({}))
  end)

  it("has no weekly rows when the week boundary is unknown, and no unattributed row without such sales", function()
    _G.C_DateAndTime = {}
    L:Add({ type = "sale", amount = 300, recipeID = 5, cost = 100 })
    L:Add({ type = "sale", amount = 5, recipeID = 6, cost = 1, time = -5 * WEEK })   -- long ago: still counted
    local m = T.Model(L, 1000)
    assert.is_nil(m.weekly)
    assert.is_nil(m.unattributed)
    assert.equal(2, #m.recipes)
    local notes, headings = {}, {}
    for _, item in ipairs(T.DisplayRows(m)) do
      if item.kind == "note" then notes[#notes + 1] = item.text end
      if item.kind == "heading" then headings[#headings + 1] = item.text end
    end
    assert.is_truthy(notes[1]:find("Week boundary unknown", 1, true))
    assert.equal("Profit by recipe (all recorded)", headings[2])
  end)

  it("orders the sections: weekly, by recipe, tips, entries", function()
    for _, t in ipairs({ 10, 20, 30 }) do L:Add({ type = "commission", amount = t, tip = t, recipeID = 5, quality = 3, cost = 1 }) end
    local items = T.DisplayRows(T.Model(L, 1000))
    local headings = {}
    for _, item in ipairs(items) do if item.kind == "heading" then headings[#headings + 1] = item.text end end
    assert.same({ "Weekly profit (last 8 reset weeks)", "Profit by recipe (last 8 reset weeks)", "Your tips by recipe and quality", "Entries (3)" }, headings)
    assert.same({}, T.DisplayRows(T.Model(nil, 1000)))
  end)

  it("says partial with the count, never shows unknown money as 0, and marks estimates and recrafts", function()
    local weekly = T.CellTexts("weekly", { weekStart = 0, income = 900, cost = 0, profit = 900, incomplete = 2, estimated = 0, index = 1 })
    assert.equal("partial: 2 with missing or partial cost", plain(weekly.note))
    assert.equal("This week", weekly.week)
    assert.same({ "9s", "0g", "9s" }, { plain(weekly.income), plain(weekly.cost), plain(weekly.profit) })
    local est = T.CellTexts("weekly", { weekStart = 0, income = 50000, cost = 20000, profit = 30000, incomplete = 0, estimated = 1, index = 2 })
    assert.same({ "~2g", "~3g", "estimate" }, { plain(est.cost), plain(est.profit), plain(est.note) })
    assert.equal(os.date("%m-%d", 0), est.week)
    local unknown = T.CellTexts("weekly", { weekStart = 0, incomplete = 0, estimated = 0, index = 3 })
    assert.same({ "?", "?", "?" }, { plain(unknown.income), plain(unknown.cost), plain(unknown.profit) })

    local recipe = T.CellTexts("recipe", { recipeID = 5, income = 10000, cost = 0, profit = 10000, n = 3, incomplete = 1, estimated = 0 })
    assert.same({ "Recipe 5", "3", "1g", "0g", "1g", "partial" },
      { recipe.recipe, recipe.n, plain(recipe.income), plain(recipe.cost), plain(recipe.profit), plain(recipe.note) })
    assert.equal("Unattributed sales", T.CellTexts("recipe", { unattributed = true, income = 1, cost = 0, profit = 1, n = 1, incomplete = 1, estimated = 0 }).recipe)

    local recraft = T.CellTexts("entry", { type = "commission", amount = 12345, time = 0, recraft = true, customer = "Bob-Silvermoon", itemID = 77 })
    assert.same({ "recraft", "1g", "Bob-Silvermoon", "item:77" }, { recraft.type, plain(recraft.amount), recraft.customer, recraft.item })
    local craft = T.CellTexts("entry", { type = "craft", amount = -25000, time = 0, estimated = true, itemName = "Ore" })
    assert.same({ "craft", "~-3g", "", "Ore" }, { craft.type, plain(craft.amount), craft.customer, craft.item })
    -- A commission's amount is exact gold even when its cost was estimated: no "~" on it.
    local estCommission = T.CellTexts("entry", { type = "commission", amount = 25000, time = 0, estimated = true, cost = 100 })
    assert.equal("2g", plain(estCommission.amount))
    local estSale = T.CellTexts("entry", { type = "sale", amount = 25000, time = 0, estimated = true, cost = 100 })
    assert.equal("2g", plain(estSale.amount))
    local npc = T.CellTexts("entry", { type = "commission", amount = 1, time = 0, orderType = "npc" })
    assert.equal("Patron", npc.customer)
    local sale = T.CellTexts("entry", { type = "sale", amount = 5, buyer = "Ann", time = 0 })
    assert.same({ "sale", "Ann", "5c" }, { sale.type, sale.customer, plain(sale.amount) })
    local damaged = T.CellTexts("entry", { type = "sale", amount = "x", time = "y" })
    assert.same({ "?", "--" }, { plain(damaged.amount), damaged.date })
  end)

  it("explains a partial profit in the tooltip: the cost of those entries is not subtracted", function()
    local lines = T.TooltipLines({ kind = "row", section = "weekly", data = { weekStart = 0, income = 900, cost = 100,
      profit = 800, incomplete = 2, estimated = 1, index = 1 } })
    local texts = {}
    for i, line in ipairs(lines) do texts[i] = line.text end
    local all = table.concat(texts, "\n")
    assert.is_truthy(all:find("Income: " .. ns.UI.FormatMoney(900), 1, true))
    assert.is_truthy(all:find("Profit: ~" .. ns.UI.FormatMoney(800), 1, true))
    assert.is_truthy(all:find("Partial: 2 with missing or partial cost", 1, true))
    assert.is_truthy(all:find("real profit may be lower", 1, true))
    assert.is_nil(all:find("at least", 1, true))

    local entry = T.TooltipLines({ kind = "row", section = "entry", data = { type = "commission", amount = 900, tip = 1000,
      customer = "Bob-Silvermoon", recraft = true, time = 0, charKey = "Me-Silvermoon" } })
    local etexts = {}
    for i, line in ipairs(entry) do etexts[i] = line.text end
    local eall = table.concat(etexts, "\n")
    assert.is_truthy(eall:find("Cost: not tracked for recrafts", 1, true))
    assert.is_truthy(eall:find("Tip: " .. ns.UI.FormatMoney(1000), 1, true))
    assert.is_truthy(eall:find("Customer: Bob-Silvermoon", 1, true))
    local sale = T.TooltipLines({ kind = "row", section = "entry", data = { type = "sale", amount = 9, time = 0 } })
    local found = false
    for _, line in ipairs(sale) do if line.text == "Cost: unknown (no cost basis)" then found = true end end
    assert.is_true(found)
  end)
end)

describe("Ledger tab frames", function()
  local ns, W, L, reg, refreshed, container, tooltip

  local function open(width)
    container = CreateFrame("Frame")
    container:SetSize(width or 740, 500)
    reg.ledger.build(container)
    reg.ledger.refresh(container)
    return ns.FS:GetModule("LedgerTab"):GetView()
  end
  local function point(cell, i) return { cell:GetPoint(i or 1) } end
  -- Scrolls the list so its last rows are in the pool's reach.
  local function scroll_to_end(v)
    local pos = math.max(0, (#v.items - 5) * 18)
    v.scroll.GetVerticalScroll = function() return pos end
    v.scroll:GetScript("OnVerticalScroll")(v.scroll, pos)
  end
  local function find_row(v, pred)
    for i = 1, v.shown do
      local row = v.pool[i]
      if pred(row.item) then return row end
    end
  end
  local function data_row(v, section)
    return find_row(v, function(item) return item.kind == "row" and item.section == section end)
  end

  before_each(function()
    reg, refreshed, container = {}, {}, nil
    tooltip = { lines = {} }
    ns, W = P2.boot({
      C_DateAndTime = { GetSecondsUntilWeeklyReset = function() return 100 end },
      GameTooltip = {
        SetOwner = function() tooltip.lines = {} end,
        SetText = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
        AddLine = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
        Show = function() tooltip.shown = true end,
        Hide = function() tooltip.shown = false end,
      },
    })
    P2.fake_module(ns, "MainWindow", {
      RegisterTab = function(_, id, def) reg[id] = def; return true end,
      RefreshTab = function(_, id)
        if id ~= "ledger" then return end   -- OrdersWidgets asks for the dashboard too
        refreshed[#refreshed + 1] = id
        if container then reg[id].refresh(container) end
      end,
    })
    P2.fake_module(ns, "Dashboard", { RegisterWidget = function() return true end })
    P2.load(ns, FILES)
    L = ns.FS:GetModule("Ledger")
  end)

  local function seed()
    L:Add({ type = "commission", amount = 9000, tip = 10000, recipeID = 5, quality = 3, cost = 2000,
      customer = "Bob-Silvermoon", itemID = 77 })
    L:Add({ type = "sale", amount = 5000, itemName = "Ore", buyer = "Ann" })
    W.advance(1)
    refreshed = {}
  end

  it("says no sales are recorded yet when the ledger is empty", function()
    local v = open()
    assert.is_true(v.empty:IsShown())
    assert.is_truthy(v.empty:GetText():find("No sales recorded yet", 1, true))
    assert.equal(0, v.shown)
  end)

  it("shows the sections with headings, headers and rows", function()
    seed()
    local v = open()
    assert.is_false(v.empty:IsShown())
    assert.is_truthy(v.header:GetText():find("2 entries", 1, true))
    local heading = find_row(v, function(item) return item.kind == "heading" end)
    assert.equal("Weekly profit (last 8 reset weeks)", heading.heading:GetText())
    local week = data_row(v, "weekly")
    assert.equal("This week", week.groups.weekly.cells.week:GetText())
    assert.is_true(week.groups.weekly.cells.week:IsShown())
    assert.is_false(week.heading:IsShown())
  end)

  it("lays an entry row out at 516 px: Date and Type from the left, Amount and Customer from the right, Item between", function()
    seed()
    local v = open(516)
    scroll_to_end(v)
    local row = data_row(v, "entry")
    assert.is_not_nil(row)
    local g = row.groups.entry
    local dateCell, typeCell, item, amount, customer = g.placed[1], g.placed[2], g.placed[3], g.placed[4], g.placed[5]
    assert.same({ "LEFT", row, "LEFT", 6, 0 }, point(dateCell)); assert.equal(36, dateCell:GetWidth())
    assert.same({ "LEFT", dateCell, "RIGHT", 4, 0 }, point(typeCell)); assert.equal(64, typeCell:GetWidth())
    assert.same({ "RIGHT", row, "RIGHT", -6, 0 }, point(customer)); assert.equal(90, customer:GetWidth())
    assert.same({ "RIGHT", customer, "LEFT", -4, 0 }, point(amount)); assert.equal(72, amount:GetWidth())
    assert.same({ "LEFT", typeCell, "RIGHT", 4, 0 }, point(item, 1))
    assert.same({ "RIGHT", amount, "LEFT", -4, 0 }, point(item, 2))
    assert.is_true(customer:IsShown())
    assert.is_true(v.layouts.entry.flex >= 120)
    -- Narrower: Customer is hidden and Amount moves to the right edge.
    container:SetSize(380, 500)
    container:GetScript("OnSizeChanged")(container, 380, 500)
    assert.is_false(customer:IsShown())
    assert.same({ "RIGHT", row, "RIGHT", -6, 0 }, point(amount))
    assert.same({ "RIGHT", amount, "LEFT", -4, 0 }, point(item, 2))
    -- Wider again: back.
    container:SetSize(516, 500)
    container:GetScript("OnSizeChanged")(container, 516, 500)
    assert.is_true(customer:IsShown())
    assert.same({ "RIGHT", customer, "LEFT", -4, 0 }, point(amount))
  end)

  it("lays the weekly and recipe rows out at 516 px with the flexible column anchored on both sides", function()
    seed()
    local v = open(516)
    local week = data_row(v, "weekly")
    local g = week.groups.weekly
    assert.same({ "LEFT", week, "LEFT", 6, 0 }, point(g.cells.week)); assert.equal(64, g.cells.week:GetWidth())
    assert.same({ "LEFT", g.cells.profit, "RIGHT", 4, 0 }, point(g.cells.note, 1))
    assert.same({ "RIGHT", week, "RIGHT", -6, 0 }, point(g.cells.note, 2))
    local recipe = data_row(v, "recipe")
    local r = recipe.groups.recipe
    assert.same({ "LEFT", recipe, "LEFT", 6, 0 }, point(r.cells.recipe, 1))
    assert.same({ "RIGHT", r.cells.n, "LEFT", -4, 0 }, point(r.cells.recipe, 2))
    assert.same({ "RIGHT", recipe, "RIGHT", -6, 0 }, point(r.cells.note))
    assert.equal("Count", find_row(v, function(item) return item.kind == "header" and item.section == "recipe" end)
      .groups["recipe:header"].cells.n:GetText())
    -- The header row of a section uses the same layout.
    local header = find_row(v, function(item) return item.kind == "header" and item.section == "recipe" end)
    local h = header.groups["recipe:header"]
    assert.equal("Profit", h.cells.profit:GetText())
    assert.same({ "RIGHT", header, "RIGHT", -6, 0 }, point(h.cells.note))
  end)

  it("lays a benchmark row out at 516 px: Recipe from the left, the numbers from the right edge", function()
    for _, t in ipairs({ 10, 20, 30 }) do L:Add({ type = "commission", amount = t, tip = t, recipeID = 5, quality = 3, cost = 1 }) end
    W.advance(1)
    local v = open(516)
    local row = data_row(v, "benchmark")
    assert.is_not_nil(row)
    local g = row.groups.benchmark
    local c = g.cells
    assert.same({ "LEFT", row, "LEFT", 6, 0 }, point(c.recipe, 1))
    assert.same({ "RIGHT", c.quality, "LEFT", -4, 0 }, point(c.recipe, 2))
    assert.same({ "RIGHT", row, "RIGHT", -6, 0 }, point(c.n)); assert.equal(32, c.n:GetWidth())
    assert.same({ "RIGHT", c.n, "LEFT", -4, 0 }, point(c.p75)); assert.equal(64, c.p75:GetWidth())
    assert.same({ "RIGHT", c.p75, "LEFT", -4, 0 }, point(c.median))
    assert.same({ "RIGHT", c.median, "LEFT", -4, 0 }, point(c.p25))
    assert.same({ "RIGHT", c.p25, "LEFT", -4, 0 }, point(c.quality)); assert.equal(24, c.quality:GetWidth())
    assert.is_true(c.p25:IsShown())
    assert.equal(236, v.layouts.benchmark.flex)
    assert.same({ "3", "20c" }, { c.quality:GetText(), plain(c.median:GetText()) })
  end)

  it("shows full values and the partial explanation in a row tooltip", function()
    seed()
    local v = open()
    local week = data_row(v, "weekly")
    week:GetScript("OnEnter")(week)
    assert.is_true(tooltip.shown)
    local all = table.concat(tooltip.lines, "\n")
    assert.is_truthy(all:find("Income: " .. ns.UI.FormatMoney(14000), 1, true))
    assert.is_truthy(all:find("Partial: 1 with missing or partial cost", 1, true))
    week:GetScript("OnLeave")(week)
    assert.is_false(tooltip.shown)
  end)

  it("keeps a read-only notice that starts with Read-only, with the full text in a tooltip", function()
    seed()
    ns.FS.dbIsNewer = true
    local v = open(516)
    assert.equal("Read-only", plain(v.status:GetText()):sub(1, 9))
    v.statusArea:GetScript("OnEnter")(v.statusArea)
    assert.equal(v.status:GetText(), tooltip.lines[1])
    ns.FS.dbIsNewer = nil
    reg.ledger.refresh(container)
    assert.equal("", v.status:GetText())
  end)

  it("says when the Ledger is turned off", function()
    seed()
    ns.FS:SetModuleEnabled("Ledger", false)
    local v = open(516)
    assert.equal("Ledger off", plain(v.status:GetText()):sub(1, 10))
  end)

  it("gives the header the whole width without a status, and splits it with one", function()
    seed()
    local v = open(516)
    assert.equal(504, v.header:GetWidth())
    ns.FS.dbIsNewer = true
    reg.ledger.refresh(container)
    assert.equal(226, v.status:GetWidth())
    assert.equal(504 - 226 - 4, v.header:GetWidth())
    ns.FS.dbIsNewer = nil
  end)

  it("refreshes once after a burst of ledger changes, and stops when turned off", function()
    seed()
    open()
    L:Add({ type = "sale", amount = 1 })
    L:Add({ type = "sale", amount = 2 })
    assert.same({}, refreshed)
    W.advance(1)
    assert.same({ "ledger" }, refreshed)
    refreshed = {}
    L:Add({ type = "sale", amount = 3 })
    ns.FS:GetModule("LedgerTab"):Disable()
    W.advance(5)
    L:Add({ type = "sale", amount = 4 })
    W.advance(5)
    assert.same({}, refreshed)
  end)

  it("asks once for an uncached item and refreshes when its data arrives", function()
    local asked = {}
    _G.C_Item.RequestLoadItemDataByID = function(id) asked[#asked + 1] = id end
    seed()
    local v = open()
    scroll_to_end(v)
    reg.ledger.refresh(container)
    assert.same({ 77 }, asked)
    W.fire("GET_ITEM_INFO_RECEIVED", 99, true)
    W.advance(1)
    assert.same({}, refreshed)
    W.fire("GET_ITEM_INFO_RECEIVED", 77, true)
    W.advance(1)
    assert.same({ "ledger" }, refreshed)
  end)
end)

describe("Orders dashboard widgets", function()
  local ns, W, L, O, D, refreshed, frames

  local function line_texts(frame)
    local out = {}
    for i = 1, frame.lineCount or 0 do out[i] = plain(frame.lines[i]:GetText()) end
    return out
  end

  before_each(function()
    refreshed = {}
    ns, W = P2.boot({ C_DateAndTime = { GetSecondsUntilWeeklyReset = function() return 100 end } })
    P2.fake_module(ns, "MainWindow", {
      RegisterTab = function() return true end,
      RefreshTab = function(_, id) if id == "dashboard" then refreshed[#refreshed + 1] = id end end,
    })
    P2.load(ns, { "UI/Tabs/Dashboard.lua", "Modules/Customers.lua", "Data/OrderRewards.lua", "Modules/Orders.lua",
      "Modules/Ledger.lua", "UI/Tabs/Ledger.lua", "UI/OrdersPanel.lua", "UI/OrdersWidgets.lua" })
    L, O, D = ns.FS:GetModule("Ledger"), ns.FS:GetModule("Orders"), ns.FS:GetModule("Dashboard")
    W.advance(1)
    refreshed = {}
    frames = D:BuildAll(CreateFrame("Frame"))
  end)

  it("registers after the phase-1 widgets", function()
    local ids = {}
    for i, def in ipairs(D:GetWidgets()) do ids[i] = def.id end
    assert.same({ "topCrafts", "queueSummary", "concentration", "openOrders", "goldThisWeek" }, ids)
  end)

  it("says no sales are recorded yet on an empty ledger, then shows this week's profit", function()
    D:RefreshAll()
    assert.same("No sales recorded yet", line_texts(frames.goldThisWeek)[1])
    L:Add({ type = "commission", amount = 90000, tip = 100000, recipeID = 5, cost = 20000 })
    L:Add({ type = "sale", amount = 10000 })
    D:RefreshAll()
    local lines = line_texts(frames.goldThisWeek)
    assert.equal("Profit: " .. ns.UI.FormatMoney(80000) .. " (partial)", lines[1])
    assert.equal("Income: " .. ns.UI.FormatMoney(100000), lines[2])
    assert.equal("Partial: 1 with missing or partial cost", lines[3])
    assert.is_nil(frames.goldThisWeek.errorText)
  end)

  it("still shows the ledger while the saved data is read-only, and says so", function()
    L:Add({ type = "sale", amount = 10000, cost = 1 })
    ns.FS.dbIsNewer = true
    D:RefreshAll()
    local lines = line_texts(frames.goldThisWeek)
    assert.equal("Profit: " .. ns.UI.FormatMoney(9999), lines[1])
    assert.equal("Read-only", lines[#lines]:sub(1, 9))
    ns.FS.dbIsNewer = nil
  end)

  it("shows open orders with the best score, its markers and why others have none", function()
    D:RefreshAll()
    assert.equal("No orders seen yet", line_texts(frames.openOrders)[1])
    local db = ns.FS.db.global.ordersSnapshot
    db.time, db.charKey = 400, "Me-Silvermoon"
    db.orders = {
      [1] = { orderID = 1, orderType = "personal", score = 50000, flags = { estimated = true } },
      [2] = { orderID = 2, orderType = "public", flags = { recraft = true } },
      [3] = { orderID = 3, orderType = "public", flags = { unknownConcentrationValue = true } },
      [4] = { orderID = 4, orderType = "npc", flags = { noPrice = true } },
    }
    D:RefreshAll()
    local lines = line_texts(frames.openOrders)
    assert.equal("4 on the board, 1 personal", lines[1])
    assert.equal("Best score: ~" .. ns.UI.FormatMoney(50000), lines[2])
    assert.equal("Not scored: 1 recraft, 1 conc?, 1 no price", lines[3])
    assert.equal("Seen 10m ago on Me-Silvermoon", lines[4])
    db.orders = { [2] = { orderID = 2, orderType = "public", flags = { recraft = true } } }
    D:RefreshAll()
    lines = line_texts(frames.openOrders)
    assert.equal("Best score: none", lines[2])
    assert.equal("Not scored: 1 recraft", lines[3])
  end)

  it("takes the best score from the orders the filters leave", function()
    local db = ns.FS.db.global.ordersSnapshot
    db.time, db.charKey = 400, "Me-Silvermoon"
    db.orders = {
      [1] = { orderID = 1, orderType = "personal", score = 50000, flags = {} },
      [2] = { orderID = 2, orderType = "public", score = 20000, flags = {} },
    }
    O:Settings().filters.orderTypes.personal = false
    D:RefreshAll()
    local lines = line_texts(frames.openOrders)
    assert.equal("2 on the board, 1 personal", lines[1])
    assert.equal("Best score: " .. ns.UI.FormatMoney(20000), lines[2])
    O:Settings().filters.orderTypes.public = false
    D:RefreshAll()
    assert.equal("Best score: none", line_texts(frames.openOrders)[2])
  end)

  it("marks an estimated profit this week with ~", function()
    L:Add({ type = "commission", amount = 90000, tip = 100000, recipeID = 5, cost = 20000, estimated = true })
    D:RefreshAll()
    assert.equal("Profit: ~" .. ns.UI.FormatMoney(70000), line_texts(frames.goldThisWeek)[1])
  end)

  it("shows every line in a tooltip on the widget", function()
    local shown = {}
    _G.GameTooltip = {
      SetOwner = function() shown = {} end,
      SetText = function(_, t) shown[#shown + 1] = t end,
      AddLine = function(_, t) shown[#shown + 1] = t end,
      Show = function() end, Hide = function() end,
    }
    D:RefreshAll()
    local frame = frames.goldThisWeek
    frame:GetScript("OnEnter")(frame)
    assert.equal("Gold this week", shown[1])
    assert.equal("No sales recorded yet", plain(shown[2]))
  end)

  it("refreshes the dashboard once after a burst of order and ledger changes, and stops when turned off", function()
    L:Add({ type = "sale", amount = 1 })
    O:SendMessage(ns.Msg.ORDERS_CHANGED)
    assert.same({}, refreshed)
    W.advance(1)
    assert.same({ "dashboard" }, refreshed)
    refreshed = {}
    O:SendMessage(ns.Msg.ORDERS_CHANGED)
    ns.FS:GetModule("OrdersWidgets"):Disable()
    W.advance(5)
    L:Add({ type = "sale", amount = 2 })
    W.advance(5)
    assert.same({}, refreshed)
  end)
end)
