describe("Dashboard", function()
  local ns, W, world, D, MW
  before_each(function()
    ns, W, world = make_world({ last = "UI/Tabs/Dashboard.lua" })
    D = ns.FS:GetModule("Dashboard"); MW = ns.FS:GetModule("MainWindow")
  end)

  local function result(profit, opts)
    opts = opts or {}
    return { recipeID = opts.recipeID or 9001, charKey = opts.charKey or "Main-Realm", profit = profit,
      priceAgeDays = opts.age, flags = { noPrice = opts.noPrice or false, estimated = opts.estimated or false,
        stalePrice = opts.stale or false } }
  end
  local function texts(frame)
    local out = {}
    for i = 1, frame.lineCount do out[i] = frame.lines[i]:GetText() end
    return out
  end

  describe("registry", function()
    it("is a core module that registers the dashboard tab first in the rail", function()
      assert.is_true(D.coreModule)
      local tab = MW:GetTabs()[1]
      assert.same({ "dashboard", "Dashboard", 10, 1 }, { tab.id, tab.def.label, tab.def.order, tab.def.phase })
    end)
    it("orders widgets and replaces duplicates", function()
      D:RegisterWidget("b", { order = 50, title = "B", build = function() end, refresh = function() end })
      D:RegisterWidget("a", { order = 5, title = "A", build = function() end, refresh = function() end })
      D:RegisterWidget("b", { order = 1, title = "B2", build = function() end, refresh = function() end })
      local w = D:GetWidgets()
      assert.same({ "b", "a", "topCrafts", "queueSummary", "concentration" }, { w[1].id, w[2].id, w[3].id, w[4].id, w[5].id })
      assert.equals("B2", w[1].title)
    end)
    it("has the phase-1 widgets at orders 10, 20 and 30", function()
      local w = D:GetWidgets()
      assert.same({ 10, 20, 30 }, { w[1].order, w[2].order, w[3].order })
    end)
    it("rejects a widget without an order or a build function", function()
      assert.is_false(D:RegisterWidget("x", { title = "X", build = function() end }))
      assert.is_false(D:RegisterWidget("y", { order = 1, title = "Y" }))
      assert.is_false(D:RegisterWidget("", { order = 1, build = function() end }))
      assert.equals(3, #D:GetWidgets())
    end)
  end)

  describe("building", function()
    it("isolates a failing widget", function()
      D:RegisterWidget("bad", { order = 1, title = "Bad", build = function() error("boom") end, refresh = function() end })
      local frames = D:BuildAll(CreateFrame("Frame"))
      assert.equals("widget failed", frames.bad.errorText); assert.is_table(frames.topCrafts)
      assert.is_nil(frames.topCrafts.errorText)
      assert.equals("Dashboard:bad", ns.FS.db.global.diagnostics.errors[1].source)
      assert.is_true(D:IsEnabled())
    end)
    it("does not refresh a widget whose build failed", function()
      local refreshed = 0
      D:RegisterWidget("bad", { order = 1, title = "Bad", build = function() error("boom") end,
        refresh = function() refreshed = refreshed + 1 end })
      D:BuildAll(CreateFrame("Frame")); D:RefreshAll()
      assert.equals(0, refreshed)
    end)
    it("shows a widget failure from refresh and clears it when the refresh works again", function()
      local broken = true
      D:RegisterWidget("flaky", { order = 1, title = "Flaky", build = function() end,
        refresh = function(f) if broken then error("nope") end; f.refreshed = true end })
      local frames = D:BuildAll(CreateFrame("Frame"))
      D:RefreshAll()
      assert.equals("widget failed", frames.flaky.errorText); assert.is_table(frames.queueSummary.lines)
      broken = false; D:RefreshAll()
      assert.is_nil(frames.flaky.errorText); assert.is_true(frames.flaky.refreshed)
    end)
    it("lays widgets out in two columns, filling rows left to right", function()
      local frames = D:BuildAll(CreateFrame("Frame"))
      local function first(f, i) return { f:GetPoint(i or 1) } end
      assert.equals("TOPLEFT", first(frames.topCrafts)[1]); assert.equals("TOPLEFT", first(frames.topCrafts)[3])
      assert.equals("TOP", first(frames.topCrafts, 2)[3])                    -- left column ends at the middle
      assert.equals("TOP", first(frames.queueSummary)[3])                    -- right column starts at the middle
      assert.equals(first(frames.topCrafts)[5], first(frames.queueSummary)[5])   -- same row
      assert.is_true(first(frames.concentration)[5] < first(frames.topCrafts)[5])  -- next row, further down
      assert.equals("TOPLEFT", first(frames.concentration)[1])
    end)
    local function late_widget(box, tag)
      return { order = 5, title = "Late", build = function(f) box.built = tag; f.built = tag end,
        refresh = function(f) box.refreshes = (box.refreshes or 0) + 1; f.fresh = true end }
    end
    it("leaves a widget registered while the tab is not shown for the next tab refresh", function()
      local box = {}
      D:BuildAll(CreateFrame("Frame"))
      D:RegisterWidget("late", late_widget(box, "one"))
      assert.is_nil(D:GetBuiltFrames().late); assert.is_nil(box.built); assert.is_nil(box.refreshes)
      D:RefreshAll()
      assert.equals("one", D:GetBuiltFrames().late.built); assert.equals(1, box.refreshes)
    end)
    it("leaves it while another tab is selected", function()
      local box = {}
      MW:Show("dashboard"); MW:RegisterTab("other", { label = "Other", order = 50, build = function() end })
      MW:SelectTab("other")
      D:RegisterWidget("late", late_widget(box, "one"))
      assert.is_nil(D:GetBuiltFrames().late); assert.is_nil(box.built)
      MW:SelectTab("dashboard")
      assert.equals("one", D:GetBuiltFrames().late.built); assert.equals(1, box.refreshes)
    end)
    it("builds and refreshes a late widget at once while the dashboard is shown, and replaces one in place", function()
      local box = {}
      MW:Show("dashboard")
      local topCrafts = D:GetBuiltFrames().topCrafts
      D:RegisterWidget("late", late_widget(box, "one"))
      assert.equals("one", D:GetBuiltFrames().late.built); assert.equals(1, box.refreshes)
      D:RegisterWidget("late", late_widget(box, "two"))
      local again = D:GetBuiltFrames()
      assert.equals("two", again.late.built); assert.is_true(again.late.fresh)
      assert.equals(topCrafts, again.topCrafts)
    end)
    it("scrolls with the mouse wheel inside the range", function()
      D:BuildAll(CreateFrame("Frame"))
      local scroll = D:GetScrollFrame()
      local pos = 0
      scroll.GetVerticalScrollRange = function() return 100 end
      scroll.GetVerticalScroll = function() return pos end
      scroll.SetVerticalScroll = function(_, v) pos = v end
      local onWheel = scroll:GetScript("OnMouseWheel")
      onWheel(scroll, -1); assert.is_true(pos > 0)
      for _ = 1, 20 do onWheel(scroll, -1) end; assert.equals(100, pos)
      for _ = 1, 40 do onWheel(scroll, 1) end; assert.equals(0, pos)
    end)
  end)

  describe("models", function()
    it("concentration model sorts by full-at", function()
      local rows = D.ConcentrationModel({ { charKey = "A", value = 900, max = 1000, regenPerSec = 1/360 }, { charKey = "B", value = 990, max = 1000, regenPerSec = 1/360 } }, 0)
      assert.same({ "B", "A" }, { rows[1].charKey, rows[2].charKey }); assert.near(3600, rows[1].fullAt, 1e-6)
    end)
    it("concentration model: full rows are full now, unknown regen sorts last", function()
      local rows = D.ConcentrationModel({
        { charKey = "Z", value = 10, max = 1000, regenPerSec = 0 },
        { charKey = "A", value = 1000, max = 1000, regenPerSec = 0 },
        { charKey = "M", value = 500, max = 1000, regenPerSec = 1/360 } }, 100)
      assert.same({ "A", "M", "Z" }, { rows[1].charKey, rows[2].charKey, rows[3].charKey })
      assert.equals(100, rows[1].fullAt); assert.is_true(rows[1].full)
      assert.is_nil(rows[3].fullAt); assert.is_false(rows[3].full)
    end)
    it("queue summary leaves the total nil when any cost is unknown", function()
      assert.is_nil(D.QueueSummaryModel({ {id=1,quantity=2}, {id=2,quantity=1} }, { [1] = 1800 }, {}).totalCost)
    end)
    it("queue summary totals entries, crafts, cost and missing items", function()
      local m = D.QueueSummaryModel({ {id=1,quantity=2}, {id="restock:5",quantity=3} }, { [1] = 1800, ["restock:5"] = 200 },
        { [1001] = 4, [2001] = 1, [3001] = 0 })
      assert.same({ 2, 5, 2000, 2 }, { m.entries, m.crafts, m.totalCost, m.missingItems })
      local empty = D.QueueSummaryModel({}, {}, {})
      assert.same({ 0, 0, 0, 0 }, { empty.entries, empty.crafts, empty.totalCost, empty.missingItems })
    end)
    it("top crafts keeps the ranking order, caps at n and carries the display flags", function()
      local rows = D.TopCraftsModel({
        result(900, { recipeID = 1, age = 1.5 }), result(300, { recipeID = 2, noPrice = true, estimated = true }),
        result(nil, { recipeID = 3, noPrice = true }), result(-5, { recipeID = 4, stale = true }) }, 3)
      assert.equals(3, #rows)
      assert.same({ 1, 2, 3 }, { rows[1].recipeID, rows[2].recipeID, rows[3].recipeID })
      assert.same({ 900, 1.5, false, false }, { rows[1].profit, rows[1].ageDays, rows[1].noPrice, rows[1].missingPrices })
      assert.same({ 300, true, true, false }, { rows[2].profit, rows[2].missingPrices, rows[2].estimated, rows[2].noPrice })
      assert.same({ true, false }, { rows[3].noPrice, rows[3].missingPrices }); assert.is_nil(rows[3].profit)
      assert.is_true(D.TopCraftsModel({ result(1, { stale = true }) }, 1)[1].stale)
      assert.same({}, D.TopCraftsModel({ result(1) }, 0))
    end)
  end)

  describe("widgets", function()
    local filters
    local function stub_ranked(list)
      filters = {}
      ns.FS:GetModule("Recipes").GetRanked = function(_, filter) filters[#filters + 1] = filter; return list end
    end
    local function refreshed()
      local frames = D:BuildAll(CreateFrame("Frame")); D:RefreshAll(); return frames
    end

    it("top crafts asks for the profitable crafts by profit", function()
      stub_ranked({}); refreshed()
      assert.same({ { sortBy = "profit", onlyProfitable = true } }, filters)
    end)
    -- GetRanked(onlyProfitable) never returns noPrice or nil-profit results, so this widget never shows
    -- them; TopCraftsModel keeps those branches for other callers.
    it("top crafts shows profit, estimate marker and price age", function()
      world.schematics[9001].name = "Sample Recipe"
      stub_ranked({ result(12345, { age = 2 }), result(500, { estimated = true, age = 0.5, charKey = "Alt-Realm" }) })
      local lines = texts(refreshed().topCrafts)
      assert.equals(2, #lines)
      assert.truthy(lines[1]:find("Sample Recipe", 1, true)); assert.truthy(lines[1]:find(ns.UI.FormatMoney(12345), 1, true))
      assert.truthy(lines[1]:find("price 2d old", 1, true)); assert.falsy(lines[1]:find("estimate", 1, true))
      assert.truthy(lines[2]:find("estimate", 1, true)); assert.truthy(lines[2]:find("(Alt)", 1, true))
      assert.truthy(lines[2]:find(ns.UI.FormatMoney(500), 1, true)); assert.truthy(lines[2]:find("price 12h old", 1, true))
    end)
    it("top crafts shows at most ten rows", function()
      local list = {}
      for i = 1, 14 do list[i] = result(1000 - i, { recipeID = 9000 + i }) end
      stub_ranked(list)
      assert.equals(10, refreshed().topCrafts.lineCount)
    end)
    it("top crafts explains an empty list, or says it is scanning", function()
      stub_ranked({})
      local frame = refreshed().topCrafts
      assert.equals(1, frame.lineCount)
      assert.truthy(frame.lines[1]:GetText():find("No profitable crafts right now", 1, true))
      assert.truthy(frame.lines[1]:GetText():find("Auctionator scan", 1, true))
      ns.FS:GetModule("Recipes").IsScanning = function() return true end
      D:RefreshAll()
      assert.truthy(frame.lines[1]:GetText():find("Scanning recipes...", 1, true))
      assert.falsy(frame.lines[1]:GetText():find("No profitable", 1, true))
    end)
    it("top crafts marks stale prices", function()
      stub_ranked({ result(100, { age = 5, stale = true }) })
      assert.truthy(texts(refreshed().topCrafts)[1]:find("stale", 1, true))
    end)
    it("queue summary reports the queue's entries, crafts, cost and missing reagents", function()
      local Q = ns.FS:GetModule("Queue")
      world.fakeEvaluate(9001, { allocation = { { slotIndex = 1, itemID = 1001, quantity = 2 } }, reagentCost = 900,
        expectedYield = 1, profit = 5000, flags = {} })
      assert.same({ "Queue is empty." }, texts(refreshed().queueSummary))
      Q:Add({ recipeID = 9001, quantity = 3, charKey = "Main-Realm" }); Q:Add({ recipeID = 9001, quantity = 1, charKey = "Alt-Realm" })
      local lines = texts(refreshed().queueSummary)
      assert.truthy(lines[1]:find("2 entries", 1, true)); assert.truthy(lines[1]:find("4 crafts", 1, true))
      assert.truthy(lines[2]:find(ns.UI.FormatMoney(3600), 1, true))
      assert.truthy(lines[3]:find("1 ", 1, true)); assert.truthy(lines[3]:find("missing", 1, true))
    end)
    -- The one English change of the locale conversion: the age sits in "(...)" after two spaces, colour codes outside.
    describe("queue summary reagent cost line", function()
      local function plain_line2()
        local Q = ns.FS:GetModule("Queue")
        world.fakeEvaluate(9001, { allocation = { { slotIndex = 1, itemID = 1001, quantity = 2 } }, reagentCost = 900,
          expectedYield = 1, profit = 5000, flags = {} })
        Q:Add({ recipeID = 9001, quantity = 3, charKey = "Main-Realm" })
        local line = texts(refreshed().queueSummary)[2]
        return (line:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
      end
      it("appends the price age in brackets after two spaces", function()
        ns.FS:GetModule("Prices").GetLastUpdate = function() return ns.FS:Now() - 7200 end
        assert.equals("Reagent cost: " .. ns.UI.FormatMoney(2700) .. "  (prices 2h old)", plain_line2())
      end)
      it("is the cost alone when no price update is known", function()
        ns.FS:GetModule("Prices").GetLastUpdate = function() return nil end
        assert.equals("Reagent cost: " .. ns.UI.FormatMoney(2700), plain_line2())
      end)
    end)
    it("queue summary says the cost is unknown when any cost is", function()
      local Q = ns.FS:GetModule("Queue")
      world.fakeEvaluate(9001, { allocation = {}, reagentCost = nil, expectedYield = 1, flags = {} })
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
      local lines = texts(refreshed().queueSummary)
      assert.truthy(lines[2]:find("unknown", 1, true)); assert.falsy(lines[2]:find(ns.UI.FormatMoney(0), 1, true))
    end)
    it("concentration lists every character's professions soonest-full first, projected to now", function()
      local main = world.chars["Main-Realm"].professions[2906]
      main.name = "Sample Crafting"
      main.concentration = { currencyID = 1, value = 900, max = 1000, time = W.now, perCycle = 1, cycleSeconds = 360 }
      local alt = world.chars["Alt-Realm"].professions[2906]
      alt.name = "Sample Crafting"
      alt.concentration = { currencyID = 1, value = 1000, max = 1000, time = W.now, perCycle = 1, cycleSeconds = 360 }
      world.chars["Alt-Realm"].professions[9999] = { name = "Dropped", dropped = true, recipes = {},
        concentration = { currencyID = 1, value = 1, max = 1000, time = W.now, perCycle = 1, cycleSeconds = 360 } }
      local lines = texts(refreshed().concentration)
      assert.equals(2, #lines)
      assert.truthy(lines[1]:find("Alt", 1, true)); assert.truthy(lines[1]:find("full", 1, true))
      assert.truthy(lines[2]:find("Main", 1, true)); assert.truthy(lines[2]:find("900/1000", 1, true))
      assert.truthy(lines[2]:find("10h 0m", 1, true))
    end)
    it("concentration derives the rate from the snapshot and never hard-codes it", function()
      local main = world.chars["Main-Realm"].professions[2906]
      main.concentration = { currencyID = 1, value = 0, max = 100, time = W.now, perCycle = 5, cycleSeconds = 600 }
      -- 5 points per 600 s = 1/120 per second: 100 points take 12000 s = 3h 20m.
      assert.truthy(texts(refreshed().concentration)[1]:find("3h 20m", 1, true))
    end)
    it("concentration counts the time to full exactly within an hour of full", function()
      local main = world.chars["Main-Realm"].professions[2906]
      main.concentration = { currencyID = 1, value = 995, max = 1000, time = W.now, perCycle = 1, cycleSeconds = 360 }
      -- 5 points at 1 per 360 s: 30 minutes, not the one-hour clamp of a rate measured from the projection.
      local line = texts(refreshed().concentration)[1]
      assert.truthy(line:find("995/1000", 1, true)); assert.truthy(line:find("full in 30m", 1, true))
    end)
    it("concentration says so when no character has a snapshot", function()
      assert.truthy(texts(refreshed().concentration)[1]:find("No concentration", 1, true))
    end)
    it("concentration shows unknown regeneration without a time", function()
      local main = world.chars["Main-Realm"].professions[2906]
      main.concentration = { currencyID = 1, value = 10, max = 100, time = W.now }
      local line = texts(refreshed().concentration)[1]
      assert.truthy(line:find("10/100", 1, true)); assert.truthy(line:find("?", 1, true))
    end)
  end)

  describe("refreshing", function()
    local function counting_widget()
      local box = { n = 0 }
      D:RegisterWidget("count", { order = 1, title = "Count", build = function() end, refresh = function() box.n = box.n + 1 end })
      return box
    end
    it("builds the tab when selected and refreshes it every time", function()
      local box = counting_widget()
      MW:Show("dashboard")
      assert.is_table(D:GetBuiltFrames().topCrafts); assert.equals(1, box.n)
      MW:SelectTab("dashboard"); assert.equals(2, box.n)
    end)
    for _, msg in ipairs({ "FS_RECIPES_CHANGED", "FS_QUEUE_CHANGED", "FS_DATA_CHANGED" }) do
      it("refreshes once, 0.5 s after the last " .. msg, function()
        local box = counting_widget()
        MW:Show("dashboard"); box.n = 0
        ns.FS:GetModule("Queue"):UnregisterAllMessages()   -- Queue's own recompute would send FS_QUEUE_CHANGED later
        D:SendMessage(msg); W.advance(0.3); D:SendMessage(msg); W.advance(0.3)
        assert.equals(0, box.n)
        W.advance(0.3); assert.equals(1, box.n)
        W.advance(5); assert.equals(1, box.n)
      end)
    end
    it("does not refresh while the window is closed", function()
      local box = counting_widget()
      MW:Show("dashboard"); box.n = 0
      MW:Hide(); D:SendMessage("FS_QUEUE_CHANGED"); W.advance(1)
      assert.equals(0, box.n)
    end)
    it("does not refresh while another tab is selected", function()
      local box = counting_widget()
      MW:Show("dashboard"); MW:RegisterTab("other", { label = "Other", order = 50, build = function() end })
      MW:SelectTab("other"); box.n = 0
      D:SendMessage("FS_QUEUE_CHANGED"); W.advance(1)
      assert.equals(0, box.n)
      MW:SelectTab("dashboard"); assert.equals(1, box.n)
    end)
    it("stops refreshing and cancels the pending refresh when disabled", function()
      local box = counting_widget()
      MW:Show("dashboard"); box.n = 0
      D:SendMessage("FS_QUEUE_CHANGED"); D:Disable(); W.advance(1)
      assert.equals(0, box.n)
    end)
  end)
end)
