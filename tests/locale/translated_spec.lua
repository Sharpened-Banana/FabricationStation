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
