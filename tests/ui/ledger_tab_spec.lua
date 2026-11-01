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

  it("builds the benchmark rows from one Ledger:Benchmarks pass, not one Benchmark call per pair", function()
    for _, t in ipairs({ 10, 20, 30 }) do
      L:Add({ type = "commission", amount = t, tip = t, recipeID = 5, quality = 3 })
      L:Add({ type = "commission", amount = t, tip = t, recipeID = 5, quality = 1 })
      L:Add({ type = "commission", amount = t, tip = t, recipeID = 8 })
    end
    local expected = T.BenchmarkRows(L:Query({}))
    local calls = 0
    L.Benchmark = function() calls = calls + 1 end
    assert.same(expected, T.BenchmarkRows(L:Query({})))
    assert.equal(0, calls); assert.equal(3, #expected)
    L.Benchmark = nil
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
    local before = P2.merge(live, {})   -- a deep copy (merge copies its first argument)
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

  it("counts an entry at exactly the oldest shown week's start in both tables, and one a second earlier in neither", function()
    local now = 1000
    local since = now + 100 - WEEK - 7 * WEEK
    L:Add({ type = "sale", amount = 100, cost = 10, recipeID = 5, time = since })
    L:Add({ type = "sale", amount = 200, cost = 20, time = since })
    L:Add({ type = "sale", amount = 4000, cost = 1, recipeID = 5, time = since - 1 })
    L:Add({ type = "sale", amount = 8000, cost = 1, time = since - 1 })
    local m = T.Model(L, now)
    assert.equal(since, m.since)
    assert.equal(since, m.weekly.rows[8].weekStart)
    assert.same({ 300, 30 }, { m.weekly.rows[8].income, m.weekly.rows[8].cost })
    assert.same({ 300, 30, 0 }, { m.weekly.total.income, m.weekly.total.cost, m.weekly.total.incomplete })
    assert.equal(1, #m.recipes)
    assert.same({ 5, 100, 10, 1 }, { m.recipes[1].recipeID, m.recipes[1].income, m.recipes[1].cost, m.recipes[1].n })
    assert.same({ 200, 20, 1 }, { m.unattributed.income, m.unattributed.cost, m.unattributed.n })
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

  it("checks for sales with Ledger:HasIncome instead of reading the whole ledger", function()
    L:Add({ type = "sale", amount = 10000, cost = 1 })
    local query = L.Query
    L.Query = function() error("Query must not be called for the sales check") end
    local lines = ns.UI.OrdersWidgets.GoldThisWeekLines(L, ns.FS:Now())
    assert.is_truthy(lines[1]:find(ns.UI.FormatMoney(9999), 1, true))
    L.Query = query
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
    local db = {}; ns.FS.db.global.orderBoards = { ["Me-Silvermoon"] = db }
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
    local db = {}; ns.FS.db.global.orderBoards = { ["Me-Silvermoon"] = db }
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

  it("logs a failing leave handler under the widget's source instead of raising", function()
    _G.GameTooltip = { SetOwner = function() end, SetText = function() end, AddLine = function() end,
      Show = function() end, Hide = function() error("boom") end }
    for _, id in ipairs({ "openOrders", "goldThisWeek" }) do
      local frame = frames[id]
      assert.has_no.errors(function() frame:GetScript("OnLeave")(frame) end)
    end
    local errors = ns.FS.db.global.diagnostics.errors
    assert.same({ "Dashboard:openOrders", "Dashboard:goldThisWeek" }, { errors[1] and errors[1].source, errors[2] and errors[2].source })
    assert.is_true(ns.FS:GetModule("OrdersWidgets"):IsEnabled())
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

-- Phase 7 Task 8: the Auctions section (SaleLog stats), beside the unchanged Profit page.
describe("Ledger tab Auctions section", function()
  local ns, W, T, L, reg, container, tooltip
  local ME = "Me-Silvermoon"
  local NAMES = { [5] = "Potion", [6] = "Elixir", [7] = "Flask", [8] = "Bandage" }

  local function open(width)
    container = CreateFrame("Frame")
    container:SetSize(width or 740, 500)
    reg.ledger.build(container)
    reg.ledger.refresh(container)
    return ns.FS:GetModule("LedgerTab"):GetView()
  end
  local function show(v, id)
    v.sections[id]:GetScript("OnClick")(v.sections[id])
  end
  local function auction_rows(v)
    local out = {}
    for _, item in ipairs(v.items) do if item.kind == "row" and item.section == "auction" then out[#out + 1] = item end end
    return out
  end
  local function row_of(v, itemID)
    for i = 1, v.shown do
      local row = v.pool[i]
      if row.item and row.item.kind == "row" and row.item.section == "auction" and row.item.data.itemID == itemID then return row end
    end
  end
  local function cells(v, itemID)
    local out = {}
    for key, cell in pairs(row_of(v, itemID).groups.auction.cells) do out[key] = plain(cell:GetText()) end
    return out
  end
  local function event(kind, itemID, quantity)
    return { time = 900, kind = kind, itemID = itemID, quantity = quantity, charKey = ME }
  end
  -- Potion: 3 posted, 2 sold (19000 for both), 1 expired. Elixir: 2 posted, both expired. Flask: 1 posted.
  local function seed_auctions(listed)
    ns.FS.db.global.auctionLog = { seenMail = {}, listings = listed and { [ME] = { time = 950, items = listed } } or {},
      events = { event("post", 5, 3), event("expire", 5, 1), event("post", 6, 2), event("expire", 6, 2),
        event("post", 7, 1) } }
    L:Add({ type = "sale", itemID = 5, quantity = 2, amount = 19000 })
  end

  before_each(function()
    reg, container = {}, nil
    tooltip = { lines = {} }
    ns, W = P2.boot({
      C_DateAndTime = { GetSecondsUntilWeeklyReset = function() return 100 end },
      C_Item = { GetItemNameByID = function(id) return NAMES[id] end },
      GameTooltip = {
        SetOwner = function() tooltip.lines = {} end,
        SetText = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
        AddLine = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
        Show = function() tooltip.shown = true end,
        Hide = function() tooltip.shown = false end,
      },
    })
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
    P2.fake_module(ns, "MainWindow", { RegisterTab = function(_, id, def) reg[id] = def; return true end,
      RefreshTab = function(_, id) if id == "ledger" and container then reg[id].refresh(container) end end })
    P2.fake_module(ns, "Dashboard", { RegisterWidget = function() return true end })
    local files = {}
    for i, f in ipairs(FILES) do files[i] = f end
    files[#files + 1] = "Modules/SaleLog.lua"
    P2.load(ns, files)
    T, L = ns.UI.LedgerTab, ns.FS:GetModule("Ledger")
  end)

  it("names the sections, Profit first", function()
    local names = {}
    for i, section in ipairs(T.SECTIONS) do names[i] = { section.id, section.label } end
    assert.same({ { "profit", "Profit" }, { "auctions", "Auctions" }, { "crafts", "Crafts" } }, names)
  end)

  it("switches between Profit and Auctions", function()
    L:Add({ type = "sale", amount = 5000, itemName = "Ore", buyer = "Ann" })
    seed_auctions()
    local v = open()
    assert.is_true(v.sections.profit:IsHighlightLocked())
    assert.is_false(v.sections.auctions:IsHighlightLocked())
    assert.equal("Profit", v.sections.profit:GetText()); assert.equal("Auctions", v.sections.auctions:GetText())
    assert.equal("Weekly profit (last 8 reset weeks)", v.items[1].text)   -- today's page
    local profitItems = #v.items
    assert.equal(0, #auction_rows(v))
    show(v, "auctions")
    assert.equal("auctions", T.GetSection())
    assert.is_true(v.sections.auctions:IsHighlightLocked()); assert.is_false(v.sections.profit:IsHighlightLocked())
    assert.equal(3, #auction_rows(v))
    show(v, "profit")
    assert.equal("profit", T.GetSection())
    assert.equal(profitItems, #v.items)
    assert.equal(0, #auction_rows(v))
    assert.is_truthy(v.header:GetText():find("entries", 1, true))
  end)

  it("does not save the chosen page", function()
    seed_auctions()
    local v = open()
    show(v, "auctions")
    assert.equal("auctions", T.GetSection())
    assert.is_nil(ns.FS.db.global.settings.ledger and ns.FS.db.global.settings.ledger.section)
  end)

  it("lists each item's posts, sales, expiries, cancels and rate", function()
    seed_auctions({ [5] = 2 })
    table.insert(ns.FS.db.global.auctionLog.events, event("cancel", 5, 1))
    local v = open()
    show(v, "auctions")
    local rows = auction_rows(v)
    assert.same({ 5, 6, 7 }, { rows[1].data.itemID, rows[2].data.itemID, rows[3].data.itemID })   -- sold desc, then name
    local potion = cells(v, 5)
    assert.is_truthy(potion.item:find("Potion", 1, true))
    assert.same({ "3", "2", "1", "1", "50%" }, { potion.posted, potion.sold, potion.expired, potion.cancelled, potion.rate })
    assert.equal(plain(ns.UI.OrdersPanel.CompactMoney(9500)), potion.last)
    assert.equal("2", potion.listed)
    local elixir = cells(v, 6)
    assert.same({ "2", "0", "2", "0", "0%", "\226\128\148", "0" },
      { elixir.posted, elixir.sold, elixir.expired, elixir.cancelled, elixir.rate, elixir.last, elixir.listed })
  end)

  it("sorts by sold, unknown last, then name, then item id", function()
    NAMES[6], NAMES[7], NAMES[8] = "Elixir", "Elixir", "Bandage"
    local rows = T.AuctionRows({
      [10] = { posted = 1, sold = 4, expired = 0, cancelled = 0 },
      [11] = { posted = 1, sold = nil, expired = 0, cancelled = 0 },
      [8] = { posted = 1, sold = 0, expired = 0, cancelled = 0 },
      [7] = { posted = 1, sold = 0, expired = 0, cancelled = 0 },
      [6] = { posted = 1, sold = 0, expired = 0, cancelled = 0 },
      [12] = { posted = 1, sold = 9, expired = 0, cancelled = 0 },
    }, 1000)
    local ids = {}
    for i, row in ipairs(rows) do ids[i] = row.itemID end
    assert.same({ 12, 10, 8, 6, 7, 11 }, ids)
  end)

  it("shows ? for an unknown rate and names why", function()
    seed_auctions()
    local v = open()
    show(v, "auctions")
    -- Flask was only posted: nothing has ended, so there is no rate yet.
    assert.equal("?", cells(v, 7).rate)
    local flask = row_of(v, 7)
    flask:GetScript("OnEnter")(flask)
    assert.is_truthy(table.concat(tooltip.lines, "\n"):find("No auction has ended yet", 1, true))
    -- The Ledger off: sold and every rate are unknown, and the row tooltip says so.
    ns.FS:SetModuleEnabled("Ledger", false)
    reg.ledger.refresh(container)
    local potion = cells(v, 5)
    assert.same({ "?", "?" }, { potion.rate, potion.sold })
    assert.equal("3", potion.posted)
    local row = row_of(v, 5)
    row:GetScript("OnEnter")(row)
    assert.is_truthy(table.concat(tooltip.lines, "\n"):find("Sales unknown: the Ledger is off", 1, true))
  end)

  it("shows ? for a listing nobody has read", function()
    seed_auctions()
    local v = open()
    show(v, "auctions")
    assert.equal("?", cells(v, 5).listed)
  end)

  it("says the sale log is off", function()
    seed_auctions()
    local v = open()
    show(v, "auctions")
    assert.equal("", v.status:GetText())
    ns.FS:SetModuleEnabled("SaleLog", false)
    reg.ledger.refresh(container)
    assert.equal("Sale log off: nothing new is recorded", plain(v.status:GetText()))
    assert.equal(3, #auction_rows(v))   -- what was recorded still shows
    v.statusArea:GetScript("OnEnter")(v.statusArea)
    assert.same({ v.status:GetText(), "Turn the Sale log on again in /fs settings > Modules." }, tooltip.lines)
    show(v, "profit")
    assert.is_nil(plain(v.status:GetText()):find("Sale log", 1, true))
  end)

  it("says there is nothing yet, and ends with the footer naming the window", function()
    local v = open()
    show(v, "auctions")
    assert.is_true(v.empty:IsShown())
    assert.is_truthy(v.empty:GetText():find("No auctions recorded yet", 1, true))
    seed_auctions()
    reg.ledger.refresh(container)
    assert.is_false(v.empty:IsShown())
    local last = v.items[#v.items]
    assert.same({ "note", "Your own auctions over the last 30 days. Sales come from the Ledger's sold mail; prices are after the AH cut." },
      { last.kind, last.text })
    ns.FS:GetModule("SaleLog"):Settings().windowDays = 90
    reg.ledger.refresh(container)
    assert.is_truthy(v.items[#v.items].text:find("last 90 days", 1, true))
  end)

  it("hides Cancelled, then Expired, then Posted when narrow", function()
    assert.same({}, T.Layout("auction", 516).hidden)
    assert.is_true(T.Layout("auction", 516).flex >= 120)
    assert.same({ cancelled = true }, T.Layout("auction", 500).hidden)
    assert.same({ cancelled = true, expired = true }, T.Layout("auction", 430).hidden)
    assert.same({ cancelled = true, expired = true, posted = true }, T.Layout("auction", 380).hidden)
    seed_auctions()
    local v = open(516)
    show(v, "auctions")
    local row = row_of(v, 5)
    local g = row.groups.auction
    assert.is_true(g.cells.cancelled:IsShown())
    container:SetSize(430, 500)
    container:GetScript("OnSizeChanged")(container, 430, 500)
    assert.is_false(g.cells.cancelled:IsShown()); assert.is_false(g.cells.expired:IsShown())
    assert.is_true(g.cells.posted:IsShown())
  end)

  it("counts a sale the Ledger could not give an itemID by the name of a posted item", function()
    seed_auctions()
    ns.FS.db.global.auctionLog.names = { [7] = "Flask" }
    L:Add({ type = "sale", itemName = "Flask", quantity = 3, amount = 3000 })   -- sold mail: a name, no itemID
    local v = open()
    show(v, "auctions")
    local flask = cells(v, 7)
    assert.same({ "3", "100%" }, { flask.sold, flask.rate })
    assert.equal(plain(ns.UI.OrdersPanel.CompactMoney(1000)), flask.last)
  end)

  it("shows the page and writes nothing while the saved data is from a newer version", function()
    seed_auctions({ [5] = 2 })
    ns.FS.dbIsNewer = true
    local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
    local v = open()
    show(v, "auctions")
    assert.equal(3, #auction_rows(v))
    assert.equal("Read-only", plain(v.status:GetText()):sub(1, 9))
    row_of(v, 5):GetScript("OnEnter")(row_of(v, 5))
    assert.same(before, ns.Util.DeepCopy(ns.FS.db.global, 30))
    ns.FS.dbIsNewer = nil
  end)

  it("refreshes when the sale log changes", function()
    seed_auctions()
    local v = open()
    show(v, "auctions")
    local before = {}
    ns.FS:GetModule("MainWindow").RefreshTab = function(_, id) if id == "ledger" then before[#before + 1] = id end end
    ns.FS:GetModule("SaleLog"):SendMessage(ns.Msg.SALELOG_CHANGED)
    W.advance(1)
    assert.same({ "ledger" }, before)
  end)
end)

describe("Ledger tab Crafts section", function()
  local ns, W, T, reg, container, tooltip
  local ME = "Me-Silvermoon"
  local NAMES = { [9001] = "Potion", [9002] = "Elixir", [9003] = "Flask" }
  local DAY = 86400

  local function open(width)
    container = CreateFrame("Frame")
    container:SetSize(width or 740, 500)
    reg.ledger.build(container)
    reg.ledger.refresh(container)
    return ns.FS:GetModule("LedgerTab"):GetView()
  end
  local function show(v, id) v.sections[id]:GetScript("OnClick")(v.sections[id]) end
  local function craft_rows(v)
    local out = {}
    for _, item in ipairs(v.items) do if item.kind == "row" and item.section == "craft" then out[#out + 1] = item end end
    return out
  end
  local function row_of(v, recipeID)
    for i = 1, v.shown do
      local row = v.pool[i]
      if row.item and row.item.kind == "row" and row.item.section == "craft" and row.item.data.recipeID == recipeID then
        return row
      end
    end
  end
  local function cells(v, recipeID)
    local out = {}
    for key, cell in pairs(row_of(v, recipeID).groups.craft.cells) do out[key] = plain(cell:GetText()) end
    return out
  end
  local nextID = 0
  local function craft(recipeID, t)
    nextID = nextID + 1
    local e = { id = nextID, time = W.now, charKey = ME, recipeID = recipeID, applyConcentration = false,
      actual = { resourcesReturned = {} } }
    for k, v in pairs(t or {}) do e[k] = v end
    return e
  end
  local function seed(entries)
    ns.FS.db.global.craftLog = { nextID = #entries + 1, entries = entries }
  end
  -- Potion: 3 crafts (2 as predicted, 1 above), Multicraft +2 of +1.0 expected, 1 Resourcefulness proc, concentration
  -- 70 of 80. Elixir: 1 craft with nothing known beyond the recipe. Flask: 2 crafts.
  local function seed_crafts()
    seed({
      craft(9001, { predicted = { quality = 1, yield = 1.4, concentrationCost = 40 },
        actual = { quality = 1, baseQuantity = 1, multicraft = 1, resourcesReturned = { [100] = 1 }, concentrationSpent = 40 } }),
      craft(9001, { predicted = { quality = 1, yield = 1.2, concentrationCost = 40 },
        actual = { quality = 2, baseQuantity = 1, multicraft = 0, resourcesReturned = {}, concentrationSpent = 30 } }),
      craft(9001, { predicted = { quality = 2, yield = 1.4 },
        actual = { quality = 2, baseQuantity = 1, multicraft = 1, resourcesReturned = {} } }),
      craft(9002, { actual = { resourcesReturned = {} } }),
      craft(9003, { predicted = { quality = 3, yield = 1 }, actual = { quality = 3, resourcesReturned = {} } }),
      craft(9003, { predicted = { quality = 3, yield = 1 }, actual = { quality = 2, resourcesReturned = {} } }),
    })
  end

  before_each(function()
    reg, container, nextID = {}, nil, 0
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
    P2.fake_module(ns, "MainWindow", { RegisterTab = function(_, id, def) reg[id] = def; return true end,
      RefreshTab = function(_, id) if id == "ledger" and container then reg[id].refresh(container) end end })
    P2.fake_module(ns, "Dashboard", { RegisterWidget = function() return true end })
    P2.fake_module(ns, "Scanner", { GetSchematic = function(_, id) return NAMES[id] and { name = NAMES[id] } or nil end })
    local files = {}
    for i, f in ipairs(FILES) do files[i] = f end
    files[#files + 1] = "Modules/CraftLog.lua"
    P2.load(ns, files)
    T = ns.UI.LedgerTab
  end)

  it("lists each recipe's results in the Crafts section", function()
    seed_crafts()
    local v = open()
    show(v, "crafts")
    assert.equal("crafts", T.GetSection())
    assert.is_true(v.sections.crafts:IsHighlightLocked()); assert.is_false(v.sections.profit:IsHighlightLocked())
    local rows = craft_rows(v)
    assert.same({ 9001, 9003, 9002 }, { rows[1].data.recipeID, rows[2].data.recipeID, rows[3].data.recipeID })
    local potion = cells(v, 9001)
    assert.same({ "Potion", "3", "2 of 3 as predicted", "+2 (expected +1.0)", "1 proc", "70 of 80 predicted" },
      { potion.recipe, potion.crafts, potion.quality, potion.multicraft, potion.resourcefulness, potion.concentration })
    local flask = cells(v, 9003)
    -- Flask's crafts reported no Multicraft number, so "0 procs" would not be known either.
    assert.same({ "Flask", "2", "1 of 2 as predicted", "?", "\226\128\148" },
      { flask.recipe, flask.crafts, flask.quality, flask.resourcefulness, flask.concentration })
  end)

  it("shows 0 procs only when Multicraft was reported", function()
    seed({ craft(9001, { actual = { quality = 1, multicraft = 0, resourcesReturned = {} } }),
      craft(9002, { actual = { quality = 1, resourcesReturned = {} } }),
      craft(9003, { actual = { quality = 1, resourcesReturned = { [100] = 1 } } }) })
    local v = open()
    show(v, "crafts")
    assert.same({ "0 procs", "?", "1 proc" }, { cells(v, 9001).resourcefulness, cells(v, 9002).resourcefulness,
      cells(v, 9003).resourcefulness })
    local row = row_of(v, 9002)
    row:GetScript("OnEnter")(row)
    assert.is_truthy(table.concat(tooltip.lines, "\n"):find("Resourcefulness: ?", 1, true))
  end)

  it("shows ? for expected extras when no craft knows its base quantity", function()
    seed({ craft(9001, { predicted = { quality = 1, yield = 2.5 }, actual = { quality = 1, multicraft = 1 } }) })
    local v = open()
    show(v, "crafts")
    assert.equal("+1 (expected +?)", cells(v, 9001).multicraft)
  end)

  it("shows ? for what the game did not report, never 0", function()
    seed_crafts()
    local v = open()
    show(v, "crafts")
    local elixir = cells(v, 9002)      -- no prediction, no actual numbers
    assert.same({ "1", "?", "? (expected +?)" }, { elixir.crafts, elixir.quality, elixir.multicraft })
    -- Two of Potion's three crafts reported their extras; a third that did not leaves a ? beside the sum.
    local entries = ns.FS.db.global.craftLog.entries
    entries[2].actual.multicraft = nil
    reg.ledger.refresh(container)
    local potion = cells(v, 9001)
    assert.equal("+2 (expected +1.0) ?", potion.multicraft)
    local row = row_of(v, 9001)
    row:GetScript("OnEnter")(row)
    assert.is_truthy(table.concat(tooltip.lines, "\n"):find("Multicraft reported for 2 of 3 crafts", 1, true))
  end)

  it("sorts by crafts, then name, then recipe id", function()
    local rows = T.CraftRows({
      [10] = { crafts = 2 }, [11] = { crafts = 5 }, [12] = { crafts = 2 }, [13] = { crafts = 2 },
    }, { [10] = "banana", [11] = "Zed", [12] = "Apple", [13] = "banana" })
    local ids = {}
    for i, row in ipairs(rows) do ids[i] = row.recipeID end
    assert.same({ 11, 12, 10, 13 }, ids)
    assert.equal("Zed", rows[1].name)
    -- Without a name the cached schematic's, else "Recipe <id>".
    assert.same({ "Potion", "Recipe 5" }, { T.CraftRows({ [9001] = { crafts = 1 } })[1].name,
      T.CraftRows({ [5] = { crafts = 1 } })[1].name })
  end)

  it("keeps the flexible column at 120 px or more at 516 px and hides Concentration, then Resourcefulness", function()
    local layout = T.Layout("craft", 516)
    assert.is_true(layout.flex >= 120, tostring(layout.flex))
    assert.same({ concentration = true }, layout.hidden)
    assert.same({ concentration = true }, T.Layout("craft", 495).hidden)
    assert.same({ concentration = true, resourcefulness = true }, T.Layout("craft", 480).hidden)
    assert.same({ concentration = true, resourcefulness = true }, T.Layout("craft", 400).hidden)
    assert.same({}, T.Layout("craft", 740).hidden)
    assert.same({}, T.Layout("craft", nil).hidden)
    seed_crafts()
    local v = open(516)
    show(v, "crafts")
    local g = row_of(v, 9001).groups.craft
    assert.is_false(g.cells.concentration:IsShown()); assert.is_true(g.cells.resourcefulness:IsShown())
    -- The hidden column's numbers are still in the row tooltip.
    local row = row_of(v, 9001)
    row:GetScript("OnEnter")(row)
    assert.is_truthy(table.concat(tooltip.lines, "\n"):find("70 spent, 80 predicted", 1, true))
  end)

  it("ends with the footer naming the weeks", function()
    seed_crafts()
    local v = open()
    show(v, "crafts")
    local last = v.items[#v.items]
    assert.same({ "note", "Your crafts over the last 8 weeks, next to the predictions." }, { last.kind, last.text })
    assert.equal("6 crafts", v.header:GetText())
  end)

  it("counts only the last 8 weeks", function()
    seed({ craft(9001, { time = W.now - 8 * 7 * DAY - 10 }), craft(9001, { time = W.now - 8 * 7 * DAY }),
      craft(9002, { time = W.now - 100 }) })
    local v = open()
    show(v, "crafts")
    -- The cut-off is inclusive: the craft exactly 8 weeks old counts, the one 10 s older does not.
    local rows = craft_rows(v)
    assert.same({ { 9002, 1 }, { 9001, 1 } }, { { rows[1].data.recipeID, rows[1].data.crafts },
      { rows[2].data.recipeID, rows[2].data.crafts } })
    assert.equal(2, #rows)
    assert.equal("2 crafts", v.header:GetText())
  end)

  it("says there is nothing yet", function()
    local v = open()
    show(v, "crafts")
    assert.is_true(v.empty:IsShown())
    assert.is_truthy(v.empty:GetText():find("No crafts logged yet", 1, true))
    assert.equal("No crafts yet", v.header:GetText())
    seed_crafts()
    reg.ledger.refresh(container)
    assert.is_false(v.empty:IsShown())
  end)

  it("says the craft log is off, and still shows what was recorded", function()
    seed_crafts()
    local v = open()
    show(v, "crafts")
    assert.equal("", v.status:GetText())
    ns.FS:SetModuleEnabled("CraftLog", false)
    reg.ledger.refresh(container)
    assert.equal("Craft log off: nothing new is recorded", plain(v.status:GetText()))
    assert.equal(3, #craft_rows(v))
    v.statusArea:GetScript("OnEnter")(v.statusArea)
    assert.same({ v.status:GetText(), "Turn the Craft log on again in /fs settings > Modules." }, tooltip.lines)
    show(v, "profit")
    assert.is_nil(plain(v.status:GetText()):find("Craft log", 1, true))
  end)

  it("does not save the chosen page", function()
    seed_crafts()
    local v = open()
    show(v, "crafts")
    assert.is_nil(ns.FS.db.global.settings.ledger and ns.FS.db.global.settings.ledger.section)
  end)

  it("shows the page and writes nothing while the saved data is from a newer version", function()
    seed_crafts()
    ns.FS.dbIsNewer = true
    local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
    local v = open()
    show(v, "crafts")
    assert.equal(3, #craft_rows(v))
    assert.equal("Read-only", plain(v.status:GetText()):sub(1, 9))
    row_of(v, 9001):GetScript("OnEnter")(row_of(v, 9001))
    assert.same(before, ns.Util.DeepCopy(ns.FS.db.global, 30))
    ns.FS.dbIsNewer = nil
  end)

  describe("this session (Task 10c)", function()
    local MONEY = function(copper) return ns.UI.FormatMoney(copper) end
    local function session_item(v)
      for _, item in ipairs(v.items) do if item.kind == "session" then return item end end
    end
    local function tooltip_text(v)
      local row = v.pool[1]
      row:GetScript("OnEnter")(row)
      return table.concat(tooltip.lines, "\n")
    end
    local function ledger() return ns.FS:GetModule("Ledger") end

    before_each(function() ns.FS.sessionStart = W.now - 100 end)

    it("starts from the addon's session start, set once when it is enabled", function()
      local t0 = W.now
      ns.FS.sessionStart = nil
      ns.FS:OnEnable()
      assert.equal(t0, ns.FS:SessionStart())
      W.advance(500)
      ns.FS:OnEnable()
      assert.equal(t0, ns.FS:SessionStart())   -- set once
    end)

    it("heads the page with this session's crafts and profit, counting nothing older", function()
      seed({ craft(9001, { time = W.now - 50 }), craft(9002, { time = W.now - 10 }), craft(9001, { time = W.now - 100 }),
        craft(9003, { time = W.now - 101 }), craft(9003, { time = W.now - 5000, charKey = "Alt-Silvermoon" }) })
      ledger():Add({ type = "commission", amount = 5000, cost = 1000, time = W.now - 50, recipeID = 9001 })
      ledger():Add({ type = "sale", amount = 3000, cost = 500, time = W.now - 20, recipeID = 9001 })
      ledger():Add({ type = "sale", amount = 700, cost = 100, time = W.now - 5 })           -- no recipe: unattributed
      ledger():Add({ type = "sale", amount = 99999, cost = 0, time = W.now - 101 })         -- before this session
      ledger():Add({ type = "craft", amount = 777, time = W.now - 5 })                      -- a cost record: no profit
      local v = open()
      show(v, "crafts")
      assert.equal("session", v.items[1].kind)       -- above the column header and the rows
      assert.equal("header", v.items[2].kind)
      assert.equal("This session: 3 crafts, profit " .. MONEY(7100), v.items[1].text)
      assert.equal("This session: 3 crafts, profit " .. MONEY(7100), v.pool[1].heading:GetText())
    end)

    it("counts alts' crafts too, and says '1 craft' for one", function()
      seed({ craft(9001, { charKey = "Alt-Silvermoon" }) })
      ledger():Add({ type = "sale", amount = 300, cost = 100 })
      local v = open()
      show(v, "crafts")
      assert.equal("This session: 1 craft, profit " .. MONEY(200), session_item(v).text)
    end)

    it("marks a profit with an unknown cost with ~ and explains it in the tooltip", function()
      seed({ craft(9001) })
      ledger():Add({ type = "sale", amount = 3000, cost = 500 })
      ledger():Add({ type = "sale", amount = 400 })    -- no known cost
      local v = open()
      show(v, "crafts")
      assert.equal("This session: 1 craft, profit ~" .. MONEY(2900), session_item(v).text)
      local text = tooltip_text(v)
      assert.is_truthy(text:find("Partial: 1 with missing or partial cost", 1, true))
      assert.is_truthy(text:find("the real profit may be lower than shown", 1, true))
    end)

    it("says no profit is recorded yet when the Ledger has no sale or commission since the start", function()
      seed({ craft(9001), craft(9002) })
      ledger():Add({ type = "sale", amount = 1, cost = 0, time = W.now - 500 })
      local v = open()
      show(v, "crafts")
      assert.equal("This session: 2 crafts, no profit recorded yet", session_item(v).text)
      seed({ craft(9001) })
      reg.ledger.refresh(container)
      assert.equal("This session: 1 craft, no profit recorded yet", session_item(v).text)
    end)

    it("shows a profit even before the first craft of the session, and nothing at all on an empty page", function()
      local v = open()
      show(v, "crafts")
      assert.is_nil(session_item(v)); assert.is_true(v.empty:IsShown())
      ledger():Add({ type = "commission", amount = 900, cost = 100 })
      reg.ledger.refresh(container)
      assert.equal("This session: 0 crafts, profit " .. MONEY(800), session_item(v).text)
      assert.is_false(v.empty:IsShown())
    end)

    it("breaks the profit down by kind in the tooltip", function()
      seed({ craft(9001) })
      ledger():Add({ type = "commission", amount = 5000, cost = 1000, recipeID = 9001 })
      ledger():Add({ type = "sale", amount = 3000, cost = 500, recipeID = 9001 })
      local v = open()
      show(v, "crafts")
      local text = tooltip_text(v)
      assert.is_truthy(text:find("This session: 1 craft, profit " .. MONEY(6500), 1, true))
      assert.is_truthy(text:find("Order commission: " .. MONEY(4000), 1, true))
      assert.is_truthy(text:find("Auction sale: " .. MONEY(2500), 1, true))
      assert.is_nil(text:find("Partial", 1, true))
    end)

    it("is not drawn when the session start is unknown", function()
      ns.FS.sessionStart = nil
      seed({ craft(9001) })
      local v = open()
      show(v, "crafts")
      assert.is_nil(session_item(v))
    end)

    it("keeps the full text in the tooltip at the 516 px minimum width", function()
      seed({ craft(9001) })
      ledger():Add({ type = "sale", amount = 123456789, cost = 0 })
      local v = open(516)
      show(v, "crafts")
      local row = v.pool[1]
      assert.equal(session_item(v).text, row.heading:GetText())   -- one unwrapped line; the tooltip carries all of it
      assert.is_truthy(tooltip_text(v):find(session_item(v).text, 1, true))
    end)

    it("refreshes on a Ledger change and on a craft log change", function()
      seed({ craft(9001) })
      local v = open()
      show(v, "crafts")
      assert.is_truthy(session_item(v).text:find("no profit recorded yet", 1, true))
      ledger():Add({ type = "sale", amount = 300, cost = 100 })    -- sends FS_LEDGER_CHANGED
      W.advance(1)
      assert.equal("This session: 1 craft, profit " .. MONEY(200), session_item(v).text)
      ns.FS.db.global.craftLog.entries[#ns.FS.db.global.craftLog.entries + 1] = craft(9002)
      ns.FS:GetModule("CraftLog"):SendMessage(ns.Msg.CRAFTLOG_CHANGED)
      W.advance(1)
      assert.equal("This session: 2 crafts, profit " .. MONEY(200), session_item(v).text)
    end)

    it("writes nothing while the saved data is from a newer version", function()
      seed({ craft(9001) })
      ledger():Add({ type = "sale", amount = 300, cost = 100 })
      ns.FS.dbIsNewer = true
      local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
      local v = open()
      show(v, "crafts")
      assert.is_not_nil(session_item(v))
      tooltip_text(v)
      assert.same(before, ns.Util.DeepCopy(ns.FS.db.global, 30))
      ns.FS.dbIsNewer = nil
    end)
  end)

  it("refreshes when a craft is logged", function()
    seed_crafts()
    local v = open()
    show(v, "crafts")
    local refreshed = {}
    ns.FS:GetModule("MainWindow").RefreshTab = function(_, id) if id == "ledger" then refreshed[#refreshed + 1] = id end end
    ns.FS:GetModule("CraftLog"):SendMessage(ns.Msg.CRAFTLOG_CHANGED)
    W.advance(1)
    assert.same({ "ledger" }, refreshed)
  end)
end)
