local P2 = require("tests.helpers.phase2")

local FILES = { "Modules/Customers.lua", "Data/OrderRewards.lua", "Modules/Orders.lua", "Modules/Ledger.lua",
  "UI/OrdersPanel.lua", "UI/Tabs/Orders.lua" }
local EM_DASH = "\226\128\148"

describe("Orders tab", function()
  local ns, T, reg
  before_each(function()
    ns = P2.boot(); reg = {}
    P2.fake_module(ns, "MainWindow", { RegisterTab = function(_, id, def) reg[id] = def end })
    P2.load(ns, {"Modules/Customers.lua", "Data/OrderRewards.lua", "Modules/Orders.lua", "Modules/Ledger.lua", "UI/OrdersPanel.lua", "UI/Tabs/Orders.lua"})
    T = ns.UI.OrdersTab
  end)
  it("registers at order 40", function()
    assert.same({"Orders", 40, 2}, {reg.orders.label, reg.orders.order, reg.orders.phase})
  end)
  it("formats the snapshot age with 1a's FormatAge", function()
    assert.equal("Orders seen <1m ago on Me-Silvermoon", T.Model({time=970, charKey="Me-Silvermoon", orders={}}, {hideRisks={}, orderTypes={}}, 1000).header)
  end)
  it("builds header and filtered rows", function()
    local snap = {time=400, charKey="Me-Silvermoon", orders={
      {orderID=1, orderType="public", itemID=5, score=10, net=10, tip=20, risks={}, expiresAt=5000},
      {orderID=2, orderType="npc", itemID=6, score=50, net=50, tip=0, risks={"expiringSoon"}, expiresAt=1500}}}
    local m = T.Model(snap, {hideRisks={expiringSoon=true}, orderTypes={public=true, npc=true}}, 1000)
    assert.equal("Orders seen 10m ago on Me-Silvermoon", m.header)
    assert.equal(1, #m.rows); assert.same({1, "public", 4000}, {m.rows[1].orderID, m.rows[1].type, m.rows[1].expiresIn})
    assert.equal("No orders seen yet", T.Model({orders={}}, {hideRisks={}, orderTypes={}}, 1000).header)
  end)
end)

describe("Orders tab models", function()
  local ns, T
  before_each(function()
    ns = P2.boot()
    P2.fake_module(ns, "MainWindow", { RegisterTab = function() return true end })
    P2.load(ns, FILES)
    T = ns.UI.OrdersTab
  end)

  local function row(view, now)
    return T.Model({ time = 900, charKey = "Me-Silvermoon", orders = { view } },
      { hideRisks = {}, orderTypes = { public = true, guild = true, personal = true, npc = true } }, now or 1000).rows[1]
  end

  it("sorts best first (nil scores last) and copies the row values", function()
    local m = T.Model({ time = 900, charKey = "Me-Silvermoon", orders = {
      { orderID = 1, orderType = "public", itemID = 5, score = nil, risks = {} },
      { orderID = 2, orderType = "personal", itemID = 6, customer = "Bob-Silvermoon", tip = 500, net = 30, score = 30,
        risks = { "expiringSoon" }, expiresAt = 1100 },
      { orderID = 3, orderType = "guild", itemID = 7, score = 90, risks = {} } } },
      { hideRisks = {}, orderTypes = { public = true, guild = true, personal = true, npc = true } }, 1000)
    assert.same({ 3, 2, 1 }, { m.rows[1].orderID, m.rows[2].orderID, m.rows[3].orderID })
    local r = m.rows[2]
    assert.same({ "personal", 6, "Bob-Silvermoon", 500, 30, 30, { "expiringSoon" }, 100 },
      { r.type, r.item, r.customer, r.tip, r.net, r.score, r.risks, r.expiresIn })
    assert.is_nil(m.rows[1].expiresIn)
    assert.is_true(m.seen); assert.equal(3, m.total)
    assert.is_false(T.Model({ orders = {} }, {}, 1000).seen)
  end)

  it("hides switched-off order types and unscored orders", function()
    local snap = { time = 900, charKey = "Me-Silvermoon", orders = {
      { orderID = 1, orderType = "public", score = 5, risks = {} },
      { orderID = 2, orderType = "npc", score = nil, risks = {} } } }
    assert.equal(1, #T.Model(snap, { hideRisks = {}, orderTypes = { public = false, npc = true } }, 1000).rows)
    assert.equal(1, #T.Model(snap, { hideRisks = {}, orderTypes = { public = true, npc = true }, hideUnscored = true }, 1000).rows)
  end)

  it("never shows unknown money as 0: no price for an unknown net, some prices missing with a known one", function()
    local cells = T.CellTexts(row({ orderID = 1, orderType = "public", risks = {}, flags = { noPrice = true } }))
    assert.is_truthy(cells.net:find("no price", 1, true)); assert.is_falsy(cells.net:find("0", 1, true))
    assert.is_truthy(cells.score:find("no price", 1, true))
    assert.equal("|cff9d9d9d?|r", cells.tip)                -- unknown money in a compact cell is "?", as on the board
    local missing = T.CellTexts(row({ orderID = 1, orderType = "public", net = 250000, score = 250000, risks = {},
      flags = { noPrice = true } }))
    assert.is_truthy(missing.net:find("+25g?", 1, true))
  end)

  it("shows recraft and unknown concentration value by name, never as no price", function()
    local recraft = T.CellTexts(row({ orderID = 1, orderType = "personal", risks = {}, flags = { recraft = true, estimated = true } }))
    assert.is_truthy(recraft.net:find(EM_DASH, 1, true)); assert.is_truthy(recraft.score:find("recraft", 1, true))
    assert.is_falsy(recraft.net:find("no price", 1, true)); assert.is_falsy(recraft.score:find("no price", 1, true))
    local conc = T.CellTexts(row({ orderID = 1, orderType = "public", net = 5000, risks = {},
      flags = { unknownConcentrationValue = true } }))
    assert.is_truthy(conc.score:find("conc?", 1, true)); assert.is_falsy(conc.score:find("no price", 1, true))
  end)

  it("marks estimates with a tilde and formats type, customer, compact tip, risk count and expiry", function()
    local cells = T.CellTexts(row({ orderID = 1, orderType = "npc", itemID = 5, tip = 12345678, net = 250000, score = 200000,
      risks = { "expiringSoon", "noMatsLowTip" }, expiresAt = 1600, flags = { estimated = true } }))
    assert.is_truthy(cells.net:find("~+25g", 1, true)); assert.is_truthy(cells.score:find("~+20g", 1, true))
    assert.equal("NPC", cells.type); assert.equal("Patron", cells.customer)
    assert.equal("1,234g", cells.tip)
    assert.equal("|cffff4040!2|r", cells.risk)
    assert.equal("45s", T.CellTexts(row({ orderID = 1, tip = 4500, risks = {} })).tip)
    assert.is_truthy(cells.expires:find("10m", 1, true))
    local plain = T.CellTexts(row({ orderID = 1, orderType = "public", customer = "Bob-Silvermoon", risks = {} }))
    assert.same({ "Public", "Bob-Silvermoon", "", "--" }, { plain.type, plain.customer, plain.risk, plain.expires })
  end)

  it("names the item from the client, else the recipe's schematic, else item:<id>", function()
    _G.C_Item.GetItemNameByID = function(id) return id == 5 and "Potion" or nil end
    P2.fake_module(ns, "Scanner", { GetSchematic = function(_, recipeID)
      return recipeID == 4444 and { name = "Elixir Recipe" } or nil end })
    assert.equal("Potion", T.CellTexts(row({ orderID = 1, itemID = 5, recipeID = 4444, risks = {} })).item)
    assert.equal("Elixir Recipe", T.CellTexts(row({ orderID = 1, itemID = 6, recipeID = 4444, risks = {} })).item)
    assert.equal("item:6", T.CellTexts(row({ orderID = 1, itemID = 6, recipeID = 1, risks = {} })).item)
  end)

  it("greys a sub-copper gain shown as 0g, like the board and the Ledger tab", function()
    local cells = T.CellTexts(row({ orderID = 1, net = 0.4, score = 0.4, risks = {} }))
    assert.equal("|cff9d9d9d0g|r", cells.net); assert.equal("|cff9d9d9d0g|r", cells.score)
    assert.equal("|cffff4040-1c|r", T.CellTexts(row({ orderID = 1, net = -0.4, risks = {} })).net)
  end)

  it("formats the tip benchmark with its quality scope", function()
    local b = { median = 50000, p25 = 40000, p75 = 60000, n = 7 }
    assert.equal(("Your tips (Q3): median %s (p25 %s, p75 %s, n=7)"):format(ns.UI.FormatMoney(50000),
      ns.UI.FormatMoney(40000), ns.UI.FormatMoney(60000)), T.BenchmarkText(b, 3))
    assert.equal("Your tips (all qualities): no history yet", T.BenchmarkText(nil, nil))
  end)

  it("builds the tooltip: customer, full tip and net, risks, notes and the tip benchmark", function()
    local r = row({ orderID = 1, orderType = "public", itemID = 5, recipeID = 4444, risks = { "expiringSoon" },
      flags = { noPrice = true } })
    local b = { median = 1, p25 = 1, p75 = 1, n = 3 }
    local function texts(lines)
      local out = {}
      for i, line in ipairs(lines) do out[i] = line.text end
      return out
    end
    assert.same({ "item:5", "Tip: --", "Net: no price", "Expiring soon", "No price", T.BenchmarkText(b, nil) },
      texts(T.TooltipLines(r, b)))
    local full = row({ orderID = 2, orderType = "personal", customer = "Bob-Silvermoon", itemID = 5, minQuality = 3,
      tip = 12345678, net = 250000, risks = {}, flags = { estimated = true } })
    assert.same({ "item:5", "Customer: Bob-Silvermoon", "Tip: " .. ns.UI.FormatMoney(12345678),
      "Net: ~" .. ns.UI.FormatMoney(250000), "Estimate (no calibration)", T.BenchmarkText(nil, 3) },
      texts(T.TooltipLines(full, nil)))
    local recraft = row({ orderID = 3, orderType = "public", risks = {}, flags = { recraft = true } })
    assert.equal("Net: " .. EM_DASH, texts(T.TooltipLines(recraft, nil))[3])
  end)

  it("keeps the Item column at 120 px or more: Customer goes first, then Type", function()
    local at516, at600, at900, at400 = T.Layout(516), T.Layout(600), T.Layout(900), T.Layout(400)
    assert.same({ { customer = true }, 128 }, { at516.hidden, at516.item })
    assert.same({ { customer = true }, 212 }, { at600.hidden, at600.item })
    assert.same({ {}, 418 }, { at900.hidden, at900.item })
    assert.same({ customer = true, type = true }, at400.hidden)
    assert.same({}, T.Layout(0).hidden); assert.same({}, T.Layout(nil).hidden)
  end)
end)

describe("Orders tab frames", function()
  local ns, W, T, reg, refreshed, queued, tooltip, benchmarks, container

  local function snapshot(views)
    local orders = {}
    for _, v in ipairs(views) do orders[v.orderID] = v end
    ns.FS.db.global.orderBoards = { ["Me-Silvermoon"] = { time = 400, orders = orders, scopes = {} } }
  end
  local function view(overrides)
    return P2.merge({ orderID = 10, orderType = "personal", customer = "Bob-Silvermoon", recipeID = 4444, itemID = 5,
      minQuality = 3, tip = 500000, net = 250000, score = 250000, risks = {}, expiresAt = 8000, flags = {},
      charKey = "Me-Silvermoon", usedConcentration = false, input = { provided = { [1001] = 2 } } }, overrides)
  end
  local function click(button) button:GetScript("OnClick")(button) end
  local function open(width)
    container = CreateFrame("Frame")
    container:SetSize(width or 740, 500)
    reg.orders.build(container)
    reg.orders.refresh(container)
    return ns.FS:GetModule("OrdersTab"):GetView()
  end

  before_each(function()
    reg, refreshed, queued, benchmarks, container = {}, {}, {}, {}, nil
    tooltip = { lines = {} }
    ns, W = P2.boot({ GameTooltip = {
      SetOwner = function(_, owner) tooltip.owner = owner; tooltip.lines = {} end,
      SetText = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
      AddLine = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
      Show = function() tooltip.shown = true end,
      Hide = function() tooltip.shown = false end,
    } })
    P2.fake_module(ns, "MainWindow", {
      RegisterTab = function(_, id, def) reg[id] = def; return true end,
      RefreshTab = function(_, id)
        refreshed[#refreshed + 1] = id
        if container then reg[id].refresh(container) end
      end,
    })
    P2.fake_module(ns, "Queue", { Add = function(_, e) queued[#queued + 1] = e; return #queued end,
      GetEntries = function() return queued end })
    P2.load(ns, FILES)
    T = ns.UI.OrdersTab
    ns.FS:GetModule("Ledger").Benchmark = function(_, recipeID, quality)
      benchmarks[#benchmarks + 1] = { recipeID, quality }
      return { median = 50000, p25 = 40000, p75 = 60000, n = 4 }
    end
  end)

  it("is a core module, so it is not offered as a user toggle", function()
    assert.is_true(ns.FS:GetModule("OrdersTab").coreModule)
    assert.equal("Interface\\Icons\\INV_Misc_Note_06", reg.orders.icon)
  end)

  it("shows the saved board with its header and one row per visible order", function()
    snapshot({ view(), view({ orderID = 11, score = 1000, net = 1000 }) })
    local v = open()
    assert.equal("Orders seen 10m ago on Me-Silvermoon", v.header:GetText())
    assert.equal(2, v.shown); assert.same({ 10, 11 }, { v.pool[1].data.orderID, v.pool[2].data.orderID })
    assert.equal("Bob-Silvermoon", v.pool[1].cells.customer:GetText())
    assert.is_false(v.empty:IsShown())
  end)

  it("says when no board was seen yet", function()
    local v = open()
    assert.equal("No orders seen yet", v.header:GetText())
    assert.is_true(v.empty:IsShown()); assert.equal(0, v.shown)
  end)

  it("tints rows by the customer highlight", function()
    snapshot({ view() })
    ns.FS:GetModule("Customers"):SetTag("Bob-Silvermoon", "VIP", true)
    local v = open()
    assert.equal("vip", v.pool[1].highlight)
    assert.same(ns.UI.OrdersPanel.HIGHLIGHT_COLORS.vip, v.pool[1].tintColor)
  end)

  it("hides flagged rows with the shared filter checkboxes and tells the other order views", function()
    snapshot({ view(), view({ orderID = 11, risks = { "expiringSoon" } }) })
    local v = open()
    assert.equal(2, v.shown)
    local check
    for _, c in ipairs(v.checks) do if c.risk == "expiringSoon" then check = c end end
    W.messages = {}
    click(check.button)
    assert.is_true(ns.FS:GetModule("Orders"):Settings().filters.hideRisks.expiringSoon)
    assert.equal("FS_ORDERS_CHANGED", W.messages[#W.messages][1])
    reg.orders.refresh(container)
    assert.equal(1, v.shown); assert.equal(10, v.pool[1].data.orderID)
    click(check.button)
    assert.is_nil(ns.FS:GetModule("Orders"):Settings().filters.hideRisks.expiringSoon)
    local unscored = v.checks[#v.checks]
    click(unscored.button)
    assert.is_true(ns.FS:GetModule("Orders"):Settings().filters.hideUnscored)
  end)

  it("adds an order to the queue through the side panel's path, once", function()
    snapshot({ view() })
    local v = open()
    local button = v.pool[1].queue
    assert.is_true(button:IsShown())
    click(button)
    assert.same({ { recipeID = 4444, quantity = 1, charKey = "Me-Silvermoon", targetQuality = 3, orderID = 10,
      providedReagents = { [1001] = 2 } } }, queued)
    assert.is_truthy(v.status:GetText():find("Added to the queue", 1, true))
    click(button)
    assert.equal(1, #queued); assert.is_truthy(v.status:GetText():find("Already in the queue", 1, true))
  end)

  it("offers no queue button for a recraft or an unknown recipe", function()
    snapshot({ view({ flags = { recraft = true } }), view({ orderID = 11, flags = { unknownRecipe = true } }) })
    local v = open()
    assert.is_false(v.pool[1].queue:IsShown()); assert.is_false(v.pool[2].queue:IsShown())
  end)

  it("shows the tip benchmark for the recipe and minimum quality in the row tooltip", function()
    snapshot({ view() })
    local v = open()
    local r = v.pool[1]
    r:GetScript("OnEnter")(r)
    assert.same({ 4444, 3 }, benchmarks[#benchmarks])
    assert.is_true(tooltip.shown)
    assert.equal(T.BenchmarkText({ median = 50000, p25 = 40000, p75 = 60000, n = 4 }, 3), tooltip.lines[#tooltip.lines])
    assert.equal("Customer: Bob-Silvermoon", tooltip.lines[2])
    r:GetScript("OnLeave")(r)
    assert.is_false(tooltip.shown)
  end)

  it("asks the benchmark over all qualities when the order has no minimum quality", function()
    snapshot({ view({ minQuality = 0 }) })
    local v = open()
    v.pool[1]:GetScript("OnEnter")(v.pool[1])
    assert.same({ 4444 }, benchmarks[#benchmarks])
  end)

  it("asks the benchmark for the delivered (expected) quality, the board's quality, and labels it", function()
    snapshot({ view({ minQuality = 2, result = { expectedQuality = 4 } }) })
    local v = open()
    v.pool[1]:GetScript("OnEnter")(v.pool[1])
    assert.same({ 4444, 4 }, benchmarks[#benchmarks])
    assert.equal(ns.UI.OrdersPanel.BenchmarkQuality(v.pool[1].data.view), 4)
    assert.equal(T.BenchmarkText({ median = 50000, p25 = 40000, p75 = 60000, n = 4 }, 4), tooltip.lines[#tooltip.lines])
  end)

  it("asks over all qualities for a recipe without qualities", function()
    snapshot({ view({ minQuality = 0, result = { expectedQuality = 1 } }) })
    local v = open()
    v.pool[1]:GetScript("OnEnter")(v.pool[1])
    assert.same({ 4444 }, benchmarks[#benchmarks])
  end)

  it("refreshes through the main window after order or customer changes", function()
    ns.FS:SendMessage("FS_ORDERS_CHANGED")
    ns.FS:SendMessage("FS_CUSTOMERS_CHANGED")
    assert.same({}, refreshed)
    W.advance(1)
    assert.same({ "orders" }, refreshed)
  end)

  it("gives the header the whole line when there is no status, and shares it with a status", function()
    snapshot({ view() })
    local v = open(740)
    local inner = 740 - 2 * 6
    assert.equal(inner, v.header:GetWidth())
    click(v.pool[1].queue)   -- an Add to Queue message on the status line: laid out at once, no refresh needed
    local statusWidth = math.floor(inner * 0.45)
    assert.equal(statusWidth, v.status:GetWidth()); assert.equal(inner - statusWidth - 4, v.header:GetWidth())
  end)

  it("stops its 30 s tick once the tab is hidden", function()
    open()
    local before = #refreshed
    W.advance(30)
    assert.equal(before + 1, #refreshed)              -- shown: the tick refreshes and schedules the next one
    local hidden = function(_, id) refreshed[#refreshed + 1] = id end   -- MainWindow skips a hidden tab's refresh
    ns.FS:GetModule("MainWindow").RefreshTab = hidden
    W.advance(30)
    assert.equal(before + 2, #refreshed)              -- the pending tick asks once, gets no refresh...
    W.advance(120)
    assert.equal(before + 2, #refreshed)              -- ...and nothing schedules another
  end)

  it("says on the status line that Orders is off, and the board is not captured", function()
    snapshot({ view() })
    local v = open()
    assert.equal("", v.status:GetText())
    ns.FS:SetModuleEnabled("Orders", false)
    reg.orders.refresh(container)
    assert.is_truthy(v.status:GetText():find("Orders off: the board is not captured", 1, true))
    ns.FS:SetModuleEnabled("Orders", true)
    reg.orders.refresh(container)
    assert.equal("", v.status:GetText())
  end)

  it("clears the Orders off notice when Orders is turned back on, without waiting for the next board visit", function()
    snapshot({ view() })
    local v = open()
    ns.FS:SetModuleEnabled("Orders", false)
    reg.orders.refresh(container)
    assert.is_truthy(v.status:GetText():find("Orders off", 1, true))
    W.advance(1)   -- the refresh Orders' turning off asked for
    refreshed = {}
    ns.FS:SetModuleEnabled("Orders", true)   -- Orders announces FS_ORDERS_CHANGED; MainWindow then refreshes the tab
    W.advance(1)
    assert.same({ "orders" }, refreshed)
    reg.orders.refresh(container)
    assert.equal("", v.status:GetText())
  end)

  it("asks once for an uncached item and refreshes when its data arrives", function()
    local asked = {}
    _G.C_Item.RequestLoadItemDataByID = function(id) asked[#asked + 1] = id end
    snapshot({ view() })
    open()
    reg.orders.refresh(container)
    assert.same({ 5 }, asked)
    W.fire("GET_ITEM_INFO_RECEIVED", 99, true)   -- not ours
    W.advance(1)
    assert.same({}, refreshed)
    W.fire("GET_ITEM_INFO_RECEIVED", 5, true)
    W.advance(1)
    assert.same({ "orders" }, refreshed)
  end)

  describe("column layout", function()
    local function point(cell, i) return { cell:GetPoint(i or 1) } end
    local function resize(width)
      container:SetSize(width, 500)
      container:GetScript("OnSizeChanged")(container, width, 500)
    end

    it("lays Type out from the left edge and Item between Type and Customer, in the header and the rows", function()
      snapshot({ view() })
      local v = open(900)
      for _, set in ipairs({ { parent = v.headerBar, cells = v.headers }, { parent = v.pool[1], cells = v.pool[1].placed } }) do
        local typeCell, item, customer, action = set.cells[1], set.cells[2], set.cells[3], set.cells[9]
        assert.same({ "LEFT", set.parent, "LEFT", 6, 0 }, point(typeCell)); assert.equal(48, typeCell:GetWidth())
        assert.same({ "LEFT", typeCell, "RIGHT", 4, 0 }, point(item, 1))
        assert.same({ "RIGHT", customer, "LEFT", -4, 0 }, point(item, 2))
        assert.same({ "RIGHT", set.parent, "RIGHT", -6, 0 }, point(action))
        assert.same({ "RIGHT", set.cells[4], "LEFT", -4, 0 }, point(customer)); assert.equal(90, customer:GetWidth())
        assert.is_true(customer:IsShown()); assert.is_true(typeCell:IsShown())
      end
    end)

    it("hides Customer at 516 and 600 px, then Type, and brings them back when wider", function()
      snapshot({ view() })
      local v = open(516)
      local r = v.pool[1]
      for _, cells in ipairs({ v.headers, r.placed }) do
        assert.is_false(cells[3]:IsShown()); assert.is_true(cells[1]:IsShown())
        assert.same({ "RIGHT", cells[4], "LEFT", -4, 0 }, point(cells[2], 2))
      end
      resize(600)
      assert.is_false(v.headers[3]:IsShown()); assert.is_false(r.placed[3]:IsShown())
      resize(400)
      for _, cells in ipairs({ v.headers, r.placed }) do
        assert.is_false(cells[1]:IsShown()); assert.is_false(cells[3]:IsShown())
      end
      assert.same({ "LEFT", r, "LEFT", 6, 0 }, point(r.placed[2], 1))
      resize(900)
      for _, cells in ipairs({ v.headers, r.placed }) do
        assert.is_true(cells[1]:IsShown()); assert.is_true(cells[3]:IsShown())
      end
      assert.same({ "LEFT", r.placed[1], "RIGHT", 4, 0 }, point(r.placed[2], 1))
    end)

    it("keeps the header and status lines apart: a status takes the right 45%, else the header takes it all", function()
      snapshot({ view() })
      local v = open(740)
      assert.same({ 0, 728 }, { v.status:GetWidth(), v.header:GetWidth() })
      click(v.pool[1].queue)
      assert.same({ 327, 397 }, { v.status:GetWidth(), v.header:GetWidth() })
      resize(516)
      assert.same({ 226, 274 }, { v.status:GetWidth(), v.header:GetWidth() })
    end)

    it("builds one checkbox per shared filter, on as many lines as they need", function()
      local v = open()
      local descriptors = ns.UI.OrdersPanel.FilterChecks()
      assert.equal(#descriptors, #v.checks); assert.equal(math.ceil(#descriptors / 3), v.filterLines)
      for i, d in ipairs(descriptors) do assert.same({ d.key, d.label }, { v.checks[i].key, v.checks[i].label:GetText() }) end
    end)
  end)

  it("says when the saved data is read-only", function()
    ns.FS:GetModule("Queue").Add = function() return nil end
    snapshot({ view() })
    local v = open()
    click(v.pool[1].queue)
    assert.is_truthy(v.status:GetText():find("Could not add to the queue (saved data is read-only)", 1, true))
  end)

  it("clears the status on the next refresh after 5 s, or when the tab is shown again", function()
    snapshot({ view() })
    local v = open()
    click(v.pool[1].queue)
    W.now = W.now + 4; reg.orders.refresh(container)
    assert.is_truthy(v.status:GetText():find("Added", 1, true))
    W.now = W.now + 1; reg.orders.refresh(container)
    assert.equal("", v.status:GetText())
    click(v.pool[1].queue)
    assert.is_truthy(v.status:GetText():find("Already", 1, true))
    container:GetScript("OnShow")(container)
    reg.orders.refresh(container)
    assert.equal("", v.status:GetText())
  end)

  it("refreshes every 30 s while shown, so ages move on and expired orders drop out", function()
    snapshot({ view(), view({ orderID = 11, expiresAt = 1020 }) })
    local v = open()
    assert.equal(2, v.shown)
    W.advance(29)
    assert.same({}, refreshed)
    W.advance(2)
    assert.same({ "orders" }, refreshed)
    assert.equal(1, v.shown); assert.equal(10, v.pool[1].data.orderID)
    W.advance(30)
    assert.same({ "orders", "orders" }, refreshed)
  end)

  it("stops listening and cancels the pending refresh and tick when turned off", function()
    snapshot({ view() })
    open()
    ns.FS:SendMessage("FS_ORDERS_CHANGED")
    ns.FS:GetModule("OrdersTab"):Disable()
    W.advance(60)
    assert.same({}, refreshed)
    ns.FS:SendMessage("FS_ORDERS_CHANGED"); ns.FS:SendMessage("FS_CUSTOMERS_CHANGED")
    W.fire("GET_ITEM_INFO_RECEIVED", 5, true)
    W.advance(60)
    assert.same({}, refreshed)
  end)

  it("never claims: the tab has no claim call", function()
    local f = assert(io.open("UI/Tabs/Orders.lua", "r"))
    local source = f:read("*a"); f:close()
    assert.is_nil(source:find("ClaimOrder", 1, true)); assert.is_nil(source:find("ClaimBest", 1, true))
  end)
end)
