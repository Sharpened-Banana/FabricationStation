-- A translated ns.L must not change behaviour: wrapped text is for display only, never compared as data.
local FILES = { "Modules/Alts.lua", "Modules/AltsCollector.lua", "Modules/Planner.lua", "Modules/PlannerSpec.lua",
  "UI/Widgets/ExpandGrid.lua", "UI/Tabs/ViewUtil.lua", "UI/Tabs/CharactersView.lua", "UI/Tabs/PlannerView.lua",
  "UI/OrdersPanel.lua" }

local function plain(text)
  return (tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

describe("a non-identity ns.L", function()
  local ns, A, V

  before_each(function()
    ns = phase3_env({ files = FILES })
    A = ns.FS:GetModule("Alts")
    V = ns.UI.CharactersView
    -- Every file holds this very table in `local L = ns.L`, so a new metatable translates all of them.
    setmetatable(ns.L, { __index = function(_, key) return "T:" .. key end })
  end)

  it("really translates (guards the other tests)", function()
    assert.equal("T:never", ns.UI.FormatAge(nil))
  end)

  it("keeps the never-seen branch of the Characters tooltip when FormatAge is translated", function()
    ns.FS.db.global.characters["Bren-Silvermoon"].lastSeen = nil
    local row = V.Row(A:GetAltRow("Bren-Silvermoon", NOW), NOW)
    assert.is_true(row.neverSeen)
    assert.equal("T:never", row.age)
    local text = plain(table.concat(V.TooltipLines(row), "\n"))
    assert.truthy(text:find("never (stale)", 1, true))
    assert.is_nil(text:find(" ago", 1, true))
  end)

  it("does not flag a seen or the current character as never seen", function()
    assert.is_false(V.Row(A:GetAltRow("Bren-Silvermoon", NOW), NOW).neverSeen)
    assert.is_false(V.Row(A:GetAltRow("Aria-Silvermoon", NOW), NOW).neverSeen)
  end)
end)

describe("a non-identity ns.L (data compared, not display text)", function()
  it("keeps the unknown-count pairs of the knowledge lines flagged on the data, not on the '? KP' text", function()
    local ns = phase3_env({ files = { "Modules/Alts.lua", "Modules/AltsCollector.lua", "Modules/Planner.lua",
      "Modules/PlannerSpec.lua", "UI/Widgets/ExpandGrid.lua", "UI/Tabs/ViewUtil.lua", "UI/Tabs/CharactersView.lua",
      "UI/Tabs/PlannerView.lua", "UI/OrdersPanel.lua", "UI/AltsDashboard.lua" } })
    setmetatable(ns.L, { __index = function(_, key) return "T:" .. key end })
    local PV = ns.UI.PlannerView
    ns.FS.db.global.characters["Bren-Silvermoon"].knowledgeWeekly = {}   -- no snapshot: unknown
    local lines = PV.KnowledgeLines(ns.FS:GetModule("Planner"):GetKnowledgeChecklist(NOW), 6)
    local unknown
    for _, pair in ipairs(lines) do if pair[1] == "Bren-Silvermoon Herbalism" then unknown = pair end end
    assert.equal("T:? KP", unknown[2])
    assert.is_true(PV.IsUnknown(unknown))
    assert.is_false(PV.IsUnknown(lines[1]))
    local model = ns.UI.AltsDashboard.KnowledgeModel(ns.FS:GetModule("Planner"):GetKnowledgeChecklist(NOW), "ok", 6)
    local dimmed
    for _, line in ipairs(model.lines) do if line:find("Bren-Silvermoon", 1, true) then dimmed = line end end
    assert.truthy(dimmed:find("|cff9d9d9dT:? KP|r", 1, true))
  end)

  it("stores the default whisper text as an empty setting under any locale", function()
    local ns = boot_phase4({ "Modules/Social/Util.lua", "Modules/Social/Gate.lua", "Modules/Social/ChatMatcher.lua",
      "Modules/Social/ChatScan.lua" })
    setmetatable(ns.L, { __index = function(_, key) return "T:" .. key end })
    local ChatScan = ns.FS:GetModule("ChatScan")
    local option = ns.FS:GetOptionsTable().args.chatScan.args.whisperTemplate
    assert.equal("T:Hi! I can craft %s. Send me a crafting order?", option.get())
    option.set(nil, "Mine: %s")
    assert.equal("Mine: %s", ChatScan:Settings().whisperTemplate)
    option.set(nil, "T:Hi! I can craft %s. Send me a crafting order?")   -- what the box shows for the default
    assert.equal("", ChatScan:Settings().whisperTemplate)
    assert.equal("T:Hi! I can craft %s. Send me a crafting order?", option.get())
  end)
end)

-- Task 7: the core, crafting and social display sentences are whole keys, so a translated ns.L reaches every word.
describe("a non-identity ns.L (core, crafting and social sentences)", function()
  local function translate(ns) setmetatable(ns.L, { __index = function(_, key) return "T:" .. key end }) end

  it("translates the header's price age as one sentence", function()
    local W = install_wow_stubs()
    local ns = load_addon({}, "UI/MainWindow.lua"); W.boot()
    translate(ns)
    local MW = ns.FS:GetModule("MainWindow")
    ns.FS.db.global.priceMeta.lastUpdate = W.now - 7200
    local prices = MW:GetHeaderText().prices
    assert.truthy(prices:find("T:Prices: ", 1, true))
    assert.equal("T:Prices: 2h ago", prices)
  end)

  describe("the Queue tab", function()
    local Tab

    before_each(function()
      local ns = make_world({ last = "UI/Tabs/Queue.lua" })
      translate(ns)
      Tab = ns.UI.QueueTab
    end)

    it("starts every status text with the translated sentence", function()
      for _, result in ipairs({ { status = "open" }, { status = "empty" }, { status = "missing" }, { status = "busy" },
        { status = "weird" }, { status = "cooldown", readyAt = 7500 }, { status = "order", orderID = 42 } }) do
        assert.equal("T:", Tab.StatusText(result, "Alchemy", "Alt", 0):sub(1, 2), result.status)
      end
    end)

    it("starts every shopping list text with the translated sentence", function()
      for _, info in ipairs({ { added = 1, skipped = 0 }, { added = 4, skipped = 0 }, { added = 1, skipped = 1 },
        { added = 3, skipped = 2 }, { added = 0, skipped = 1 }, { added = 0, skipped = 2 },
        { added = 0, skipped = 2, loading = true }, { added = 2, skipped = 1, loading = true },
        { added = 2, skipped = 2, loading = true } }) do
        assert.equal("T:", Tab.ShoppingText(true, info):sub(1, 2), tostring(info.added) .. "/" .. tostring(info.skipped))
      end
      for _, why in ipairs({ "noAuctionator", "empty", "auctionatorError", "other" }) do
        assert.equal("T:", Tab.ShoppingText(false, why):sub(1, 2), why)
      end
    end)

    it("translates the item counts and the wait", function()
      local text = Tab.ShoppingText(true, { added = 2, skipped = 1 })
      assert.equal("T:Shopping list updated (T:2 items), T:1 item skipped", text)
      local row = Tab.BuildRows({ { id = 1, recipeID = 9001, quantity = 1, charKey = "A-B" } }, {}, {}, { [1] = 7500 }, 0)[1]
      assert.truthy(row.readyText:find("T:ready in ", 1, true))
    end)
  end)

  it("starts the craft cost line of a tooltip with the translated sentence", function()
    local ns = make_world({ last = "UI/Tooltips.lua", calibrate = { ["Main-Realm"] = { 9001 } } })
    translate(ns)
    local lines = ns.FS:GetModule("Tooltips"):CollectLines(5002)
    assert.equal("Craft cost", lines[1][1]:gsub("^T:", ""))
    assert.equal("T:", lines[1][2]:sub(1, 2))
    assert.truthy(lines[1][2]:find("T:, ", 1, true))
  end)

  it("translates the guide's character rows as sentences", function()
    local ns = boot_phase4({ "Modules/Social/Util.lua", "Modules/Onboarding.lua", "UI/OnboardingWizard.lua" },
      { last = "Modules/Diagnostics.lua" })
    translate(ns)
    local rows = ns.UI.OnboardingWizard.ScanRows({ { charKey = "Me-Realm", isCurrent = true, time = ns.FS:Now() - 120,
      professions = {} } })
    assert.equal("T:", rows[1].text:sub(1, 2))
    assert.equal("header", rows[1].kind)
  end)
end)

-- Task 8: the orders display text is whole keys under a translated ns.L.
describe("a non-identity ns.L (orders sentences)", function()
  local P2 = require("tests.helpers.phase2")
  local ORDERS_FILES = { "Modules/Customers.lua", "Data/OrderRewards.lua", "Modules/Orders.lua", "Modules/Ledger.lua",
    "UI/OrdersPanel.lua", "UI/OrdersWidgets.lua", "UI/Tabs/Orders.lua" }
  local ns

  before_each(function()
    ns = P2.boot({ C_DateAndTime = { GetSecondsUntilWeeklyReset = function() return 1 end } })
    P2.fake_module(ns, "MainWindow", { RegisterTab = function() end })
    P2.fake_module(ns, "Dashboard", { RegisterWidget = function() end })
    P2.load(ns, ORDERS_FILES)
    setmetatable(ns.L, { __index = function(_, key) return "T:" .. key end })
  end)

  local function every_line_translated(lines)
    assert.is_true(#lines > 0)
    for i, line in ipairs(lines) do assert.equal("T:", plain(line):sub(1, 2), i .. ": " .. plain(line)) end
  end

  it("translates every open-orders line, scored or not", function()
    local W = ns.UI.OrdersWidgets
    local scored = { time = 400, charKey = "Me-Silvermoon", orders = {
      { orderID = 1, orderType = "personal", score = 50000, flags = { estimated = true } } } }
    local lines = W.OpenOrdersLines(scored, 1000)
    every_line_translated(lines)
    assert.equal(3, #lines)
    local mixed = { time = 400, charKey = "Me-Silvermoon", orders = {
      { orderID = 1, orderType = "personal", score = 50000 },
      { orderID = 2, orderType = "public", flags = { recraft = true } },
      { orderID = 3, orderType = "public", flags = { unknownConcentrationValue = true } },
      { orderID = 4, orderType = "npc", flags = { noPrice = true } } } }
    lines = W.OpenOrdersLines(mixed, 1000)
    every_line_translated(lines)
    assert.equal(4, #lines)
    assert.truthy(plain(lines[3]):find("T:Not scored: T:1 recraft", 1, true))
    assert.truthy(plain(lines[3]):find("T:1 recraftT:, T:1 conc?T:, T:1 no price", 1, true))
    local none = W.OpenOrdersLines({ time = 400, orders = { { orderID = 2, orderType = "public", flags = { recraft = true } } } }, 1000)
    assert.equal("T:Best score: T:none", plain(none[2]))
  end)

  it("translates the gold-this-week lines, a partial profit included", function()
    local ledger = { HasIncome = function() return true end, IsEnabled = function() return true end,
      Weekly = function() return { { weekStart = 0, income = 9, cost = 2, profit = 7, incomplete = 1 } } end }
    local lines = ns.UI.OrdersWidgets.GoldThisWeekLines(ledger, 1000)
    assert.truthy(plain(lines[1]):find("T:Profit: ", 1, true))
    assert.truthy(plain(lines[1]):find("T:partial", 1, true))
    assert.truthy(plain(lines[2]):find("T:Income: ", 1, true))
  end)

  it("translates the Orders tab header", function()
    local Tab = ns.UI.OrdersTab
    local filters = { hideRisks = {}, orderTypes = {} }
    local snap = { time = 970, charKey = "Me-Silvermoon", orders = {} }
    assert.equal("T:Orders seen <1m ago on Me-Silvermoon", Tab.Model(snap, filters, 1000).header)
    snap.charKey = nil
    assert.equal("T:Orders seen <1m ago", Tab.Model(snap, filters, 1000).header)
  end)

  it("translates the recraft note of a row", function()
    local notes = ns.UI.OrdersPanel.Notes({ flags = { recraft = true } })
    assert.equal("T:Recraft \226\128\148 judge manually", notes[1])
  end)
end)

describe("a non-identity ns.L (customers sentences)", function()
  local P2 = require("tests.helpers.phase2")
  local TAB_FILES = { "Modules/Customers.lua", "Data/OrderRewards.lua", "Modules/Orders.lua", "Modules/Ledger.lua",
    "UI/Tabs/Customers.lua", "UI/OrdersPanel.lua" }
  local ns, T, C, reg, tooltip

  -- The shared frame stubs keep no text, shown or focus state; the Customers tab needs a little of each to build.
  local function stateful_frames()
    local base = _G.CreateFrame
    _G.CreateFrame = function(...)
      local f = base(...)
      local text, checked, shown, enabled = "", false, true, true
      function f:Show() shown = true end
      function f:Hide() shown = false end
      function f:IsShown() return shown end
      function f:IsVisible() return shown end
      function f:IsMouseOver() return false end
      function f:SetText(t) text = t end
      function f:GetText() return text end
      function f:SetChecked(v) checked = v and true or false end
      function f:GetChecked() return checked end
      function f:SetFocus() end
      function f:ClearFocus() end
      function f:HasFocus() return false end
      function f:HighlightText() end
      function f:Enable() enabled = true end
      function f:Disable() enabled = false end
      function f:IsEnabled() return enabled end
      return f
    end
  end

  before_each(function()
    reg, tooltip = {}, { lines = {} }
    ns = P2.boot({ GameTooltip = {
      SetOwner = function() tooltip.lines = {} end,
      SetText = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
      AddLine = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
      Show = function() end, Hide = function() end,
    } })
    stateful_frames()
    P2.fake_module(ns, "MainWindow", { RegisterTab = function(_, id, def) reg[id] = def; return true end,
      RefreshTab = function() end })
    setmetatable(ns.L, { __index = function(_, key) return "T:" .. key end })   -- before the files load: constants too
    P2.load(ns, TAB_FILES)
    T = ns.UI.CustomersTab
    C = ns.FS:GetModule("Customers")
  end)

  it("translates the Tags cell, a joined tag list and its blocked phrase included", function()
    local row = { nameRealm = "B-Silvermoon", orders = 1, tagsText = "blocked", blockedVia = "Al-Silvermoon" }
    assert.equal("T:blocked (via Al)", T.CellTexts(row, 1000).tags)   -- the main's realm is left out
    row.blockedVia = "Someone-Area52"
    assert.equal("T:blocked (alt)", T.CellTexts(row, 1000).tags)   -- the long phrase does not fit
    -- Two tags: the separator is the list key, "blocked" is replaced inside the list.
    local both = { nameRealm = "B-Silvermoon", orders = 1, tagsText = "VIPT:, blocked", blockedVia = "Al-Silvermoon" }
    assert.equal("VIPT:, T:blocked (alt)", T.CellTexts(both, 1000).tags)
  end)

  it("builds the tag list of a list row with the translated separator", function()
    C:RecordOrder("Bob-Silvermoon", { orderID = 1, time = 500, itemID = 5, quality = 3, tip = 100 })
    C:SetTag("Bob-Silvermoon", "VIP", true)
    C:SetTag("Bob-Silvermoon", "blocked", true)
    assert.equal("VIPT:, blocked", T.ListModel(T.Groups(""))[1].tagsText)
  end)

  it("translates the last-seen cell of a customer that was never seen", function()
    assert.equal("T:never", T.CellTexts({ nameRealm = "B-Silvermoon", orders = 1, tagsText = "" }, 1000).lastSeen)
  end)

  it("translates every line of the list row and order history tooltips", function()
    C:RecordOrder("Bob-Silvermoon", { orderID = 1, time = 500, itemID = 5, quality = 3, tip = 100, orderType = "public" })
    C:RecordOrder("Alt-Silvermoon", { orderID = 2, time = 400, itemID = 5, quality = 3, tip = 5, orderType = "guild",
      commission = 50 })
    C:Link("Alt-Silvermoon", "Bob-Silvermoon")
    C:SetTag("Bob-Silvermoon", "friend", true)
    local container = CreateFrame("Frame")
    container:SetSize(740, 500)
    reg.customers.build(container)
    reg.customers.refresh(container)
    local v = ns.FS:GetModule("CustomersTab"):GetView()
    local row
    for i = 1, v.list.shown do if v.list.pool[i].data.nameRealm == "Bob-Silvermoon" then row = v.list.pool[i] end end
    row:GetScript("OnEnter")(row)
    assert.is_true(#tooltip.lines >= 6, table.concat(tooltip.lines, "|"))
    for i = 2, #tooltip.lines do
      assert.equal("T:", plain(tooltip.lines[i]):sub(1, 2), i .. ": " .. plain(tooltip.lines[i]))
    end
    assert.truthy(table.concat(tooltip.lines, "\n"):find("T:Alts: Alt-Silvermoon", 1, true))
    row:GetScript("OnClick")(row)
    local history
    for i = 1, v.detail.history.shown do
      if v.detail.history.pool[i].data.who == "Alt-Silvermoon" then history = v.detail.history.pool[i] end
    end
    history:GetScript("OnEnter")(history)
    assert.is_true(#tooltip.lines >= 8, table.concat(tooltip.lines, "|"))
    for i = 2, #tooltip.lines do
      assert.equal("T:", plain(tooltip.lines[i]):sub(1, 2), i .. ": " .. plain(tooltip.lines[i]))
    end
    assert.equal("T:Click to show Alt-Silvermoon", tooltip.lines[#tooltip.lines])
  end)

  it("translates the status line, the group chips and the link tooltip", function()
    C:RecordOrder("Bob-Silvermoon", { orderID = 1, time = 500, itemID = 5, quality = 3, tip = 100 })
    C:RecordOrder("Cat-Silvermoon", { orderID = 2, time = 700, itemID = 5, quality = 3, tip = 10 })
    C:Link("Cat-Silvermoon", "Bob-Silvermoon")
    local container = CreateFrame("Frame")
    container:SetSize(740, 500)
    reg.customers.build(container)
    reg.customers.refresh(container)
    local v = ns.FS:GetModule("CustomersTab"):GetView()
    local d = v.detail
    local bob
    for i = 1, v.list.shown do if v.list.pool[i].data.nameRealm == "Bob-Silvermoon" then bob = v.list.pool[i] end end
    bob:GetScript("OnClick")(bob)
    assert.equal("Cat-Silvermoon", d.group[1]:GetText())   -- a name is data
    d.group[1]:GetScript("OnClick")(d.group[1])   -- select the alt
    assert.equal("T:Bob-Silvermoon (main)", d.group[1]:GetText())
    d.linkEdit:GetScript("OnEnter")(d.linkEdit)
    assert.equal("T:Linked to Bob-Silvermoon", tooltip.lines[1])
    d.unlink:GetScript("OnClick")(d.unlink)
    assert.equal("T:Cat-Silvermoon is no longer linked", plain(v.status:GetText()))
  end)
end)

describe("a non-identity ns.L (ledger sentences)", function()
  local P2 = require("tests.helpers.phase2")
  local TAB_FILES = { "Modules/Customers.lua", "Data/OrderRewards.lua", "Modules/Orders.lua", "Modules/Ledger.lua",
    "UI/Tabs/Ledger.lua", "UI/OrdersPanel.lua", "UI/OrdersWidgets.lua" }
  local ns, T, reg

  before_each(function()
    reg = {}
    ns = P2.boot({ C_DateAndTime = { GetSecondsUntilWeeklyReset = function() return 100 end } })
    P2.fake_module(ns, "MainWindow", { RegisterTab = function(_, id, def) reg[id] = def; return true end,
      RefreshTab = function() end })
    P2.fake_module(ns, "Dashboard", { RegisterWidget = function() return true end })
    setmetatable(ns.L, { __index = function(_, key) return "T:" .. key end })   -- before the files load: constants too
    P2.load(ns, TAB_FILES)
    T = ns.UI.LedgerTab
  end)

  -- Every line after the title (and, for an entry, its date) must be a translated sentence.
  local function all_translated(lines, first)
    assert.is_true(#lines >= first)
    for i = first, #lines do assert.equal("T:", plain(lines[i].text):sub(1, 2), i .. ": " .. plain(lines[i].text)) end
  end

  it("translates every line of an income entry's tooltip", function()
    local lines = T.TooltipLines({ kind = "row", section = "entry", data = { type = "commission", amount = 900,
      cost = 200, tip = 1000, customer = "Bob-Silvermoon", quality = 3, quantity = 2, time = 0, itemName = "Ore",
      charKey = "Me-Silvermoon" } })
    all_translated(lines, 3)   -- 1 is the item, 2 its date
    assert.equal("T:Order commission", plain(lines[3].text))
    assert.equal("T:Amount: " .. ns.UI.FormatMoney(900), plain(lines[4].text))
    assert.equal("T:Cost: " .. ns.UI.FormatMoney(200), plain(lines[5].text))
    assert.equal("T:Tip: " .. ns.UI.FormatMoney(1000), plain(lines[6].text))
    assert.equal("T:Customer: Bob-Silvermoon", plain(lines[7].text))
    assert.equal("T:Character: Me-Silvermoon", plain(lines[#lines].text))
    local sale = T.TooltipLines({ kind = "row", section = "entry", data = { type = "sale", amount = 9, buyer = "Ann", time = 0 } })
    all_translated(sale, 3)
    assert.equal("T:Buyer: Ann", plain(sale[6].text))
  end)

  it("translates the recraft kind around the translated type name", function()
    local lines = T.TooltipLines({ kind = "row", section = "entry", data = { type = "commission", amount = 900,
      recraft = true, tip = 5, time = 0 } })
    assert.equal("T:T:Order commission (recraft)", plain(lines[3].text))
    all_translated(lines, 3)
  end)

  it("translates the weekly and recipe tooltips, partial and estimated lines included", function()
    local weekly = T.TooltipLines({ kind = "row", section = "weekly", data = { weekStart = 0, income = 900, cost = 100,
      profit = 800, incomplete = 2, estimated = 1, index = 1 } })
    assert.truthy(plain(weekly[1].text):find("T:Week starting ", 1, true))
    all_translated(weekly, 1)
    assert.equal("T:Partial: 2 with missing or partial cost", plain(weekly[5].text))
    local recipe = T.TooltipLines({ kind = "row", section = "recipe", data = { recipeID = 77, n = 3, income = 5,
      cost = 1, profit = 4, incomplete = 0, estimated = 0 } })
    assert.equal("T:Recipe 77", plain(recipe[1].text))
    all_translated(recipe, 1)
    assert.equal("T:Sales and commissions: 3", plain(recipe[2].text))
  end)

  it("translates the tip benchmark tooltip, with and without a quality", function()
    local q = T.TooltipLines({ kind = "row", section = "benchmark", data = { recipeID = 77, quality = 3, median = 200,
      p25 = 150, p75 = 250, n = 3 } })
    -- The recipe name (here the translated "Recipe %s" fallback) sits inside the whole title key.
    assert.equal("T:T:Recipe 77 (quality 3)", q[1].text)
    all_translated(q, 2)
    assert.equal("T:Median tip: " .. ns.UI.FormatMoney(200), q[2].text)
    assert.equal("T:A quarter of your tips were below " .. ns.UI.FormatMoney(150), q[3].text)
    assert.equal("T:A quarter of your tips were above " .. ns.UI.FormatMoney(250), q[4].text)
    local all = T.TooltipLines({ kind = "row", section = "benchmark", data = { recipeID = 77, median = 200, p25 = 150,
      p75 = 250, n = 3 } })
    assert.equal("T:T:Recipe 77 (all qualities)", all[1].text)
  end)

  it("translates the header with the age of the newest entry", function()
    local L = ns.FS:GetModule("Ledger")
    L:Add({ type = "sale", amount = 5000, itemName = "Ore", buyer = "Ann" })
    local container = CreateFrame("Frame")
    container:SetSize(740, 500)
    reg.ledger.build(container)
    reg.ledger.refresh(container)
    assert.equal("T:1 entries, newest <1m ago", plain(ns.FS:GetModule("LedgerTab"):GetView().header:GetText()))
  end)
end)
