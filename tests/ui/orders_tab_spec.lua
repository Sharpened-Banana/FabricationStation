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
  it("formats the board age with 1a's FormatAge", function()
    assert.equal("Orders seen <1m ago on Me-Silvermoon", T.Model({}, {["Me-Silvermoon"]=970}, {hideRisks={}, orderTypes={}}, 1000).header)
  end)
  it("builds the header and the rows from the orders it is given", function()
    local orders = {
      {orderID=1, orderType="public", itemID=5, score=10, net=10, tip=20, risks={}, expiresAt=5000, charKey="Me-Silvermoon"},
      {orderID=2, orderType="npc", itemID=6, score=50, net=50, tip=0, risks={"expiringSoon"}, expiresAt=1500, charKey="Me-Silvermoon"}}
    local m = T.Model(orders, {["Me-Silvermoon"]=400}, {}, 1000)
    assert.equal("Orders seen 10m ago on Me-Silvermoon", m.header)
    assert.equal(2, #m.rows)
    assert.same({1, "public", 4000, "Me-Silvermoon", 600}, {m.rows[1].orderID, m.rows[1].type, m.rows[1].expiresIn, m.rows[1].character, m.rows[1].age})
    assert.equal("No orders seen yet", T.Model({}, {}, {hideRisks={}, orderTypes={}}, 1000).header)
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

  local ALL = { public = true, guild = true, personal = true, npc = true }
  local function row(view, now)
    return T.Model({ view }, { ["Me-Silvermoon"] = 900 }, { hideRisks = {}, orderTypes = ALL }, now or 1000).rows[1]
  end
  -- Orders:GetOrders over one saved board, then the model (what the tab's refresh does).
  local function listed(views, filters, now)
    local orders = {}
    for _, v in ipairs(views) do orders[v.orderID] = v end
    ns.FS.db.global.orderBoards = { ["Me-Silvermoon"] = { time = 900, orders = orders, scopes = {} } }
    local f = filters or { hideRisks = {}, orderTypes = ALL }
    local list, times = ns.FS:GetModule("Orders"):GetOrders(f)
    return T.Model(list, times, f, now or 1000)
  end

  it("sorts best first (nil scores last) and copies the row values", function()
    local m = listed({
      { orderID = 1, orderType = "public", itemID = 5, score = nil, risks = {} },
      { orderID = 2, orderType = "personal", itemID = 6, customer = "Bob-Silvermoon", tip = 500, net = 30, score = 30,
        risks = { "expiringSoon" }, expiresAt = 1100 },
      { orderID = 3, orderType = "guild", itemID = 7, score = 90, risks = {} } })
    assert.same({ 3, 2, 1 }, { m.rows[1].orderID, m.rows[2].orderID, m.rows[3].orderID })
    local r = m.rows[2]
    assert.same({ "personal", 6, "Bob-Silvermoon", 500, 30, 30, { "expiringSoon" }, 100 },
      { r.type, r.item, r.customer, r.tip, r.net, r.score, r.risks, r.expiresIn })
    assert.is_nil(m.rows[1].expiresIn)
    assert.is_true(m.seen); assert.equal(3, m.total)
    assert.is_false(T.Model({}, {}, {}, 1000).seen)
  end)

  it("hides switched-off order types and unscored orders", function()
    local snap = {
      { orderID = 1, orderType = "public", score = 5, risks = {} },
      { orderID = 2, orderType = "npc", score = nil, risks = {} } }
    assert.equal(1, #listed(snap, { hideRisks = {}, orderTypes = { public = false, npc = true } }).rows)
    assert.equal(1, #listed(snap, { hideRisks = {}, orderTypes = { public = true, npc = true }, hideUnscored = true }).rows)
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
    assert.same({ "item:5", "Type: Public", "Tip: --", "Net: no price", "Expiring soon", "No price", T.BenchmarkText(b, nil) },
      texts(T.TooltipLines(r, b)))
    local full = row({ orderID = 2, orderType = "personal", customer = "Bob-Silvermoon", itemID = 5, minQuality = 3,
      tip = 12345678, net = 250000, risks = {}, flags = { estimated = true } })
    assert.same({ "item:5", "Type: Personal", "Customer: Bob-Silvermoon", "Tip: " .. ns.UI.FormatMoney(12345678),
      "Net: ~" .. ns.UI.FormatMoney(250000), "Estimate (no calibration)", T.BenchmarkText(nil, 3) },
      texts(T.TooltipLines(full, nil)))
    local recraft = row({ orderID = 3, orderType = "public", risks = {}, flags = { recraft = true } })
    assert.equal("Net: " .. EM_DASH, texts(T.TooltipLines(recraft, nil))[4])
  end)

  it("names the order type in the tooltip, since a narrow window hides the Type column", function()
    local function texts(r)
      local out = {}
      for i, line in ipairs(T.TooltipLines(r, nil)) do out[i] = line.text end
      return out
    end
    for orderType, label in pairs({ public = "Public", guild = "Guild", personal = "Personal", npc = "NPC" }) do
      assert.equal("Type: " .. label, texts(row({ orderID = 1, orderType = orderType, itemID = 5, risks = {} }))[2])
    end
    assert.equal("Tip: --", texts(row({ orderID = 1, itemID = 5, risks = {} }))[2])   -- no type known: no Type line
  end)

  it("names the character in the tooltip even when the board's age is unknown", function()
    local function texts(r)
      local out = {}
      for i, line in ipairs(T.TooltipLines(r, nil)) do out[i] = line.text end
      return out
    end
    local r = row({ orderID = 1, orderType = "public", itemID = 5, risks = {}, charKey = "Alt-Silvermoon" })
    r.character, r.age = "Alt-Silvermoon", 60
    assert.equal("Seen 1m ago on Alt-Silvermoon", texts(r)[3])
    r.age = nil
    assert.equal("Character: Alt-Silvermoon", texts(r)[3])
    r.character = nil
    assert.equal("Tip: --", texts(r)[3])
  end)

  it("escapes pipes in the character and customer of the tooltip", function()
    P2.load(ns, { "Modules/Social/Util.lua" })
    local r = row({ orderID = 1, orderType = "public", itemID = 5, risks = {}, customer = "Bo|b", charKey = "A|lt-Silvermoon" })
    r.age = nil
    local out = {}
    for i, line in ipairs(T.TooltipLines(r, nil)) do out[i] = line.text end
    assert.equal("Customer: Bo||b", out[3]); assert.equal("Character: A||lt-Silvermoon", out[4])
  end)

  it("keeps the Item column at 120 px or more: Character goes first, then Customer, then Type", function()
    local at516, at620, at900, at400 = T.Layout(516), T.Layout(620), T.Layout(900), T.Layout(400)
    assert.same({ { character = true, customer = true, type = true }, 156 }, { at516.hidden, at516.item })   -- Select (20 px) never hides
    assert.same({ { character = true, customer = true }, 208 }, { at620.hidden, at620.item })
    assert.same({ {}, 310 }, { at900.hidden, at900.item })
    assert.same({ character = true, customer = true, type = true }, at400.hidden)
    assert.same({}, T.Layout(0).hidden); assert.same({}, T.Layout(nil).hidden)
  end)

  it("hides the Character column first when the window is narrow", function()
    assert.is_true(T.Layout(516).hidden.character)
    local roomy = T.Layout(620)   -- Item would get 114 px with only Character gone: Customer goes too, Type stays
    assert.is_true(roomy.hidden.character); assert.is_true(roomy.hidden.customer); assert.is_nil(roomy.hidden.type)
    assert.is_nil(T.Layout(710).hidden.character); assert.is_true(T.Layout(709).hidden.character)
    assert.is_nil(T.Layout(400).hidden.select)
  end)

  it("shows the character without the current realm, and with another realm's", function()
    assert.equal("Alt", T.CellTexts(row({ orderID = 1, risks = {}, charKey = "Alt-Silvermoon" })).character)
    assert.equal("Far-Draenor", T.CellTexts(row({ orderID = 1, risks = {}, charKey = "Far-Draenor" })).character)
    assert.equal("--", T.CellTexts(row({ orderID = 1, risks = {} })).character)
  end)

  describe("several characters", function()
    local f = { hideRisks = {}, orderTypes = ALL }
    local function two(extra)
      return {
        { orderID = 1, orderType = "public", score = 5, risks = {}, charKey = "Me-Silvermoon", expiresAt = 1600 },
        P2.merge({ orderID = 2, orderType = "public", score = 50, risks = {}, charKey = "Alt-Silvermoon", expiresAt = 1300 }, extra) }
    end
    local times = { ["Me-Silvermoon"] = 400, ["Alt-Silvermoon"] = 940 }

    it("headlines the character count and the soonest expiry", function()
      local m = T.Model(two(), times, f, 1000)
      assert.equal("Orders from 2 characters \194\183 next expires in 5m", m.header)
      assert.is_true(m.seen)
    end)
    it("leaves the expiry out when no order has one", function()
      local orders = two(); orders[1].expiresAt = nil; orders[2].expiresAt = nil
      assert.equal("Orders from 2 characters", T.Model(orders, times, f, 1000).header)
    end)
    it("names each board's age and order count in the header tooltip", function()
      local m = T.Model(two(), times, f, 1000)
      assert.equal("Alt-Silvermoon: 1 order, seen 1m ago\nMe-Silvermoon: 1 order, seen 10m ago", m.headerTooltip)
      local none = T.Model({}, { ["Me-Silvermoon"] = 400, ["Alt-Silvermoon"] = 940 }, f, 1000)
      assert.equal("Alt-Silvermoon: 0 orders, seen 1m ago\nMe-Silvermoon: 0 orders, seen 10m ago", none.headerTooltip)
      assert.equal("Me-Silvermoon: 2 orders, seen 10m ago",
        T.Model({ two()[1], two()[1] }, { ["Me-Silvermoon"] = 400 }, f, 1000).headerTooltip)
    end)
    it("gives each row its character and the age of that character's board", function()
      local m = T.Model(two(), times, f, 1000)
      assert.same({ "Me-Silvermoon", 600, "Alt-Silvermoon", 60 },
        { m.rows[1].character, m.rows[1].age, m.rows[2].character, m.rows[2].age })
    end)
    it("adds the board's age to the row tooltip", function()
      local m = T.Model(two(), times, f, 1000)
      local texts = {}
      for i, line in ipairs(T.TooltipLines(m.rows[2], nil)) do texts[i] = line.text end
      assert.equal("Seen 1m ago on Alt-Silvermoon", texts[3])
    end)
  end)
end)

describe("Orders tab frames", function()
  local ns, W, T, reg, refreshed, queued, tooltip, benchmarks, container, exports, exportResult

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
    reg, refreshed, queued, benchmarks, container, exports = {}, {}, {}, {}, nil, {}
    exportResult = { true, { added = 2, skipped = 0 } }
    tooltip = { lines = {} }
    ns, W = P2.boot({ GameTooltip = {
      SetOwner = function(_, owner) tooltip.owner = owner; tooltip.lines = {} end,
      SetText = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
      AddLine = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
      Show = function() tooltip.shown = true end,
      Hide = function() tooltip.shown = false end,
    } })
    -- The stub's buttons drop their text; these remember it so the controls' labels can be read.
    local createFrame = _G.CreateFrame
    _G.CreateFrame = function(frameType, ...)
      local frame = createFrame(frameType, ...)
      local enabled, checked = true, false
      function frame:Enable() enabled = true end
      function frame:Disable() enabled = false end
      function frame:IsEnabled() return enabled end
      function frame:SetChecked(v) checked = v and true or false end
      function frame:GetChecked() return checked end
      if frameType == "Button" then
        local text
        function frame:SetText(t) text = t end
        function frame:GetText() return text end
      end
      return frame
    end
    P2.fake_module(ns, "MainWindow", {
      RegisterTab = function(_, id, def) reg[id] = def; return true end,
      RefreshTab = function(_, id)
        refreshed[#refreshed + 1] = id
        if container then reg[id].refresh(container) end
      end,
    })
    P2.fake_module(ns, "Queue", { Add = function(_, e) queued[#queued + 1] = e; return #queued end,
      GetEntries = function() return queued end,
      ExportShoppingList = function(_, onRetry, opts)
        exports[#exports + 1] = { onRetry = onRetry, opts = opts }
        return unpack(exportResult)
      end })
    -- UI/Tabs/Queue.lua loads before the Orders tab (the TOC order): ns.UI.QueueTab.ShoppingText words the export's result.
    P2.load(ns, { "Modules/Customers.lua", "Data/OrderRewards.lua", "Modules/Orders.lua", "Modules/Ledger.lua",
      "UI/OrdersPanel.lua", "UI/Tabs/Queue.lua", "UI/Tabs/Orders.lua" })
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

  describe("selecting orders to shop for", function()
    local function two_boards()
      local me = view({ orderID = 10, score = 100 })
      local alt = view({ orderID = 20, score = 300, charKey = "Alt-Silvermoon", recipeID = 5555, minQuality = 1,
        input = {} })
      local recraft = view({ orderID = 30, score = 50, flags = { recraft = true } })
      ns.FS.db.global.orderBoards = {
        ["Me-Silvermoon"] = { time = 400, orders = { [10] = me, [30] = recraft }, scopes = {} },
        ["Alt-Silvermoon"] = { time = 940, orders = { [20] = alt }, scopes = {} } }
    end
    local function tick(v, slot, on)
      local box = v.pool[slot].select
      box:SetChecked(on ~= false)
      click(box)
    end
    local function plain(v) return (v.status:GetText():gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
    local function row_of(v, orderID)
      for i = 1, v.shown do if v.pool[i].data.orderID == orderID then return i end end
    end

    it("has a Select column first, with a check button on each row", function()
      two_boards()
      local v = open()
      assert.equal("CheckButton", v.pool[1].select.frameType)
      assert.equal(v.pool[1].select, v.pool[1].placed[1]); assert.equal("", v.headers[1]:GetText())
    end)

    it("names the count on the button and disables it with nothing selected", function()
      two_boards()
      local v = open()
      assert.equal("Shop selected (0)", v.shop:GetText()); assert.is_false(v.shop:IsEnabled())
      assert.equal("Clear selection", v.clear:GetText())
      tick(v, 1)
      assert.equal("Shop selected (1)", v.shop:GetText()); assert.is_true(v.shop:IsEnabled())
      tick(v, 2)
      assert.equal("Shop selected (2)", v.shop:GetText())
      tick(v, 2, false)
      assert.equal("Shop selected (1)", v.shop:GetText())
      tick(v, 1, false)
      assert.equal("Shop selected (0)", v.shop:GetText()); assert.is_false(v.shop:IsEnabled())
    end)

    it("clears the selection", function()
      two_boards()
      local v = open()
      tick(v, 1); tick(v, 2)
      click(v.clear)
      assert.same({}, v.selected); assert.equal("Shop selected (0)", v.shop:GetText())
      assert.is_false(v.pool[1].select:GetChecked()); assert.is_false(v.pool[2].select:GetChecked())
    end)

    it("keeps the tick on a row when the list is bound again", function()
      two_boards()
      local v = open()
      local slot = row_of(v, 20)
      tick(v, slot)
      reg.orders.refresh(container)
      assert.is_true(v.pool[row_of(v, 20)].select:GetChecked())
      assert.is_false(v.pool[row_of(v, 10)].select:GetChecked())
    end)

    it("exports the selected orders' missing reagents under the orders list name, each on its own character", function()
      two_boards()
      local v = open()
      tick(v, row_of(v, 10)); tick(v, row_of(v, 20))
      click(v.shop)
      assert.equal(1, #exports)
      local opts = exports[1].opts
      assert.equal("FabricationStation Orders", opts.listName)
      table.sort(opts.entries, function(a, b) return a.orderID < b.orderID end)
      assert.equal(2, #opts.entries)
      assert.same({ 4444, "Me-Silvermoon", 10, 3 }, { opts.entries[1].recipeID, opts.entries[1].charKey, opts.entries[1].orderID,
        opts.entries[1].targetQuality })
      assert.same({ 5555, "Alt-Silvermoon", 20, 1 }, { opts.entries[2].recipeID, opts.entries[2].charKey, opts.entries[2].orderID,
        opts.entries[2].quantity })
      assert.is_function(exports[1].onRetry)
      assert.equal("Shopping list updated (2 items)", plain(v))
      assert.equal(0, #queued)   -- shopping adds nothing to the queue
    end)

    it("skips a recraft order in the selection and says how many", function()
      two_boards()
      local v = open()
      tick(v, row_of(v, 10)); tick(v, row_of(v, 30))
      click(v.shop)
      assert.equal(1, #exports[1].opts.entries); assert.equal(10, exports[1].opts.entries[1].orderID)
      assert.is_truthy(plain(v):find("1 order skipped: recraft or unknown recipe", 1, true))
      assert.is_truthy(plain(v):find("Shopping list updated (2 items)", 1, true))
    end)

    it("exports nothing and says so when every selected order is skipped", function()
      two_boards()
      local v = open()
      tick(v, row_of(v, 30))
      click(v.shop)
      assert.equal(0, #exports)
      assert.equal("1 order skipped: recraft or unknown recipe", plain(v))
    end)

    it("counts several skipped orders with the plural text", function()
      two_boards()
      ns.FS.db.global.orderBoards["Me-Silvermoon"].orders[31] = view({ orderID = 31, score = 40, flags = { unknownRecipe = true } })
      local v = open()
      tick(v, row_of(v, 30)); tick(v, row_of(v, 31)); tick(v, row_of(v, 10))
      click(v.shop)
      assert.is_truthy(plain(v):find("2 orders skipped: recraft or unknown recipe", 1, true))
      assert.equal(1, #exports[1].opts.entries)
    end)

    it("shows the failure line of an export", function()
      two_boards()
      exportResult = { false, "noAuctionator" }
      local v = open()
      tick(v, row_of(v, 10))
      click(v.shop)
      assert.is_truthy(v.status:GetText():find("Auctionator not available", 1, true))
    end)

    it("shows the retry's result on the status line when item names arrive later", function()
      two_boards()
      exportResult = { true, { added = 0, skipped = 2, loading = true } }
      local v = open()
      tick(v, row_of(v, 10))
      click(v.shop)
      assert.is_truthy(v.status:GetText():find("Loading item names", 1, true))
      exports[1].onRetry(true, { added = 2, skipped = 0 })
      assert.is_truthy(v.status:GetText():find("Shopping list updated (2 items)", 1, true))
    end)

    it("exports a character's own copy when both boards hold the same order id", function()
      two_boards()
      ns.FS.db.global.orderBoards["Alt-Silvermoon"].orders[10] = view({ orderID = 10, score = 900,
        charKey = "Alt-Silvermoon", recipeID = 7777 })
      local v = open()
      tick(v, 1)   -- the better-scored copy, the Alt's
      click(v.shop)
      assert.equal(1, #exports[1].opts.entries)
      assert.same({ 7777, "Alt-Silvermoon" }, { exports[1].opts.entries[1].recipeID, exports[1].opts.entries[1].charKey })
    end)

    it("drops selected orders that left the list", function()
      two_boards()
      local v = open()
      tick(v, row_of(v, 10)); tick(v, row_of(v, 20))
      assert.equal("Shop selected (2)", v.shop:GetText())
      ns.FS.db.global.orderBoards["Alt-Silvermoon"].orders[20] = nil
      reg.orders.refresh(container)
      assert.same({ [10] = true }, v.selected); assert.equal("Shop selected (1)", v.shop:GetText())
      click(v.shop)
      assert.equal(1, #exports[1].opts.entries)
    end)

    it("drops a selection a filter now hides", function()
      two_boards()
      local v = open()
      tick(v, row_of(v, 20))
      click(v.characters)   -- this character only
      assert.same({}, v.selected); assert.equal("Shop selected (0)", v.shop:GetText())
    end)

    it("says so when the queue cannot export", function()
      two_boards()
      ns.FS:GetModule("Queue").ExportShoppingList = nil
      local v = open()
      tick(v, 1)
      click(v.shop)
      assert.is_truthy(v.status:GetText():find("The queue is not available", 1, true))
    end)
  end)

  it("shows the tip benchmark for the recipe and minimum quality in the row tooltip", function()
    snapshot({ view() })
    local v = open()
    local r = v.pool[1]
    r:GetScript("OnEnter")(r)
    assert.same({ 4444, 3 }, benchmarks[#benchmarks])
    assert.is_true(tooltip.shown)
    assert.equal(T.BenchmarkText({ median = 50000, p25 = 40000, p75 = 60000, n = 4 }, 3), tooltip.lines[#tooltip.lines])
    assert.equal("Type: Personal", tooltip.lines[2])
    assert.equal("Customer: Bob-Silvermoon", tooltip.lines[3])
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

    -- Cell indices: 1 Select, 2 Type, 3 Character, 4 Item, 5 Customer, 6 Tip, ..., 11 the Queue button.
    it("lays Select out from the left edge and Item between Character and Customer, in the header and the rows", function()
      snapshot({ view() })
      local v = open(900)
      for _, set in ipairs({ { parent = v.headerBar, cells = v.headers }, { parent = v.pool[1], cells = v.pool[1].placed } }) do
        local select, typeCell, character, item, customer, action = set.cells[1], set.cells[2], set.cells[3], set.cells[4],
          set.cells[5], set.cells[11]
        assert.same({ "LEFT", set.parent, "LEFT", 6, 0 }, point(select)); assert.equal(20, select:GetWidth())
        assert.same({ "LEFT", select, "RIGHT", 4, 0 }, point(typeCell)); assert.equal(48, typeCell:GetWidth())
        assert.same({ "LEFT", typeCell, "RIGHT", 4, 0 }, point(character)); assert.equal(80, character:GetWidth())
        assert.same({ "LEFT", character, "RIGHT", 4, 0 }, point(item, 1))
        assert.same({ "RIGHT", customer, "LEFT", -4, 0 }, point(item, 2))
        assert.same({ "RIGHT", set.parent, "RIGHT", -6, 0 }, point(action))
        assert.same({ "RIGHT", set.cells[6], "LEFT", -4, 0 }, point(customer)); assert.equal(90, customer:GetWidth())
        assert.is_true(customer:IsShown()); assert.is_true(typeCell:IsShown()); assert.is_true(character:IsShown())
        assert.is_true(select:IsShown())
      end
    end)

    it("hides Character, then Customer, then Type as the window narrows, keeps Select, and brings them back when wider", function()
      snapshot({ view() })
      local v = open(516)
      local r = v.pool[1]
      for _, cells in ipairs({ v.headers, r.placed }) do
        assert.is_false(cells[3]:IsShown()); assert.is_false(cells[5]:IsShown()); assert.is_false(cells[2]:IsShown())
        assert.is_true(cells[1]:IsShown())
        assert.same({ "LEFT", cells[1], "RIGHT", 4, 0 }, point(cells[4], 1))
        assert.same({ "RIGHT", cells[6], "LEFT", -4, 0 }, point(cells[4], 2))
      end
      resize(620)
      for _, cells in ipairs({ v.headers, r.placed }) do
        assert.is_false(cells[3]:IsShown()); assert.is_false(cells[5]:IsShown()); assert.is_true(cells[2]:IsShown())
      end
      resize(710)
      for _, cells in ipairs({ v.headers, r.placed }) do
        assert.is_true(cells[3]:IsShown()); assert.is_true(cells[5]:IsShown())
      end
      resize(400)
      for _, cells in ipairs({ v.headers, r.placed }) do
        assert.is_false(cells[3]:IsShown()); assert.is_false(cells[5]:IsShown()); assert.is_false(cells[2]:IsShown())
        assert.is_true(cells[1]:IsShown())
      end
      assert.same({ "LEFT", r.placed[1], "RIGHT", 4, 0 }, point(r.placed[4], 1))
      resize(900)
      for _, cells in ipairs({ v.headers, r.placed }) do
        assert.is_true(cells[2]:IsShown()); assert.is_true(cells[3]:IsShown()); assert.is_true(cells[5]:IsShown())
      end
      assert.same({ "LEFT", r.placed[3], "RIGHT", 4, 0 }, point(r.placed[4], 1))
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

  describe("several characters", function()
    local function two_boards(altExtra)
      local me, alt = view({ score = 100 }), view(P2.merge({ orderID = 20, score = 300, customer = "Cy-Silvermoon",
        charKey = "Alt-Silvermoon", expiresAt = 5000 }, altExtra))
      local far = view({ orderID = 30, score = 200, charKey = "Far-Draenor", expiresAt = 9000 })
      ns.FS.db.global.orderBoards = {
        ["Me-Silvermoon"] = { time = 400, orders = { [me.orderID] = me }, scopes = {} },
        ["Alt-Silvermoon"] = { time = 940, orders = { [alt.orderID] = alt }, scopes = {} },
        ["Far-Draenor"] = { time = 700, orders = { [far.orderID] = far }, scopes = {} } }
    end
    local function ids(v)
      local out = {}
      for i = 1, v.shown do out[i] = v.pool[i].data.orderID end
      return out
    end

    it("lists every character's orders with a Character column", function()
      two_boards()
      local v = open()
      assert.same({ 20, 30, 10 }, ids(v))
      assert.same({ "Alt", "Far-Draenor", "Me" }, { v.pool[1].cells.character:GetText(), v.pool[2].cells.character:GetText(),
        v.pool[3].cells.character:GetText() })
      assert.equal("Character", v.headers[3]:GetText())
      assert.equal("Orders from 3 characters \194\183 next expires in 1h", v.header:GetText())
    end)

    it("shows only the current character's board for \"this one\", and back", function()
      two_boards()
      local v = open()
      assert.equal("Characters: all", v.characters:GetText())
      click(v.characters)
      assert.equal("current", ns.FS:GetModule("Orders"):Settings().filters.characters)
      reg.orders.refresh(container)
      assert.equal("Characters: this one", v.characters:GetText())
      assert.same({ 10 }, ids(v))
      assert.equal("Orders seen 10m ago on Me-Silvermoon", v.header:GetText())
      click(v.characters)
      assert.equal("all", ns.FS:GetModule("Orders"):Settings().filters.characters)
      assert.same({ 20, 30, 10 }, ids(v))
    end)

    it("cycles the sort: best, expiring, character", function()
      two_boards()
      local v = open()
      assert.equal("Sort: best", v.sort:GetText())
      click(v.sort)
      assert.equal("expires", ns.FS:GetModule("Orders"):Settings().filters.sort)
      assert.equal("Sort: expiring", v.sort:GetText())
      assert.same({ 20, 10, 30 }, ids(v))   -- expiring at 5000, 8000, 9000
      click(v.sort)
      assert.equal("Sort: character", v.sort:GetText())
      assert.same({ 20, 30, 10 }, ids(v))
      click(v.sort)
      assert.equal("Sort: best", v.sort:GetText())
      assert.equal("score", ns.FS:GetModule("Orders"):Settings().filters.sort)
    end)

    it("sorts by expiry with the soonest first", function()
      two_boards()
      ns.FS.db.global.orderBoards["Me-Silvermoon"].orders[10].expiresAt = 4000
      local v = open()
      click(v.sort)
      assert.same({ 10, 20, 30 }, ids(v))
    end)

    it("sorts by character, then best first", function()
      two_boards()
      local v = open()
      click(v.sort); click(v.sort)
      assert.same({ 20, 30, 10 }, ids(v))   -- Alt, Far-Draenor, Me
      ns.FS.db.global.orderBoards["Alt-Silvermoon"].orders[21] = view({ orderID = 21, score = 400, charKey = "Alt-Silvermoon" })
      reg.orders.refresh(container)
      assert.same({ 21, 20, 30, 10 }, ids(v))
    end)

    it("leaves hidden characters out while Alts is on", function()
      two_boards()
      P2.fake_module(ns, "Alts", { Settings = function() return { hidden = { ["Alt-Silvermoon"] = true } } end })
      ns.FS:SetModuleEnabled("Alts", true)
      local v = open()
      assert.same({ 30, 10 }, ids(v))
      assert.equal("Orders from 2 characters \194\183 next expires in 1h", v.header:GetText())
    end)

    it("names each board's age in the header tooltip", function()
      two_boards()
      local v = open()
      v.headerHit:GetScript("OnEnter")(v.headerHit)
      assert.is_true(tooltip.shown)
      assert.same({ "Alt-Silvermoon: 1 order, seen 1m ago", "Far-Draenor: 1 order, seen 5m ago",
        "Me-Silvermoon: 1 order, seen 10m ago" }, tooltip.lines)
      v.headerHit:GetScript("OnLeave")(v.headerHit)
      assert.is_false(tooltip.shown)
    end)

    it("says which board an order was seen on in its row tooltip", function()
      two_boards()
      local v = open()
      v.pool[1]:GetScript("OnEnter")(v.pool[1])
      assert.equal("Seen 1m ago on Alt-Silvermoon", tooltip.lines[4])
    end)

    it("adds another character's order to the queue for that character", function()
      two_boards()
      local v = open()
      click(v.pool[1].queue)
      assert.equal(1, #queued)
      assert.same({ 4444, "Alt-Silvermoon", 20 }, { queued[1].recipeID, queued[1].charKey, queued[1].orderID })
    end)

    it("queues the other character's copy of an order both boards hold", function()
      two_boards()
      local mine = ns.FS.db.global.orderBoards["Me-Silvermoon"].orders[10]
      ns.FS.db.global.orderBoards["Alt-Silvermoon"].orders[10] = view({ orderID = 10, score = 900, charKey = "Alt-Silvermoon" })
      ns.FS.db.global.orderBoards["Alt-Silvermoon"].orders[20] = nil
      local v = open()
      assert.equal("Alt-Silvermoon", v.pool[1].data.character)
      click(v.pool[1].queue)
      assert.equal("Alt-Silvermoon", queued[1].charKey)
      assert.equal("Me-Silvermoon", mine.charKey)
    end)

    it("keeps a session copy of the choices while the saved data is read-only", function()
      two_boards()
      ns.FS.dbIsNewer = true
      local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
      local v = open()
      click(v.characters); click(v.sort)
      assert.equal("Characters: this one", v.characters:GetText()); assert.equal("Sort: expiring", v.sort:GetText())
      assert.same({ 10 }, ids(v))
      assert.same(before, ns.FS.db.global)
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
