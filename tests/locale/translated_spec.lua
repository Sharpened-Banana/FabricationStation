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

  -- Task 10: the Characters row tooltip and detail lines are whole keys, so a translated ns.L reaches every sentence.
  -- The title, the profession titles ("Herbalism 50/100") and the unit values are data, not sentences.
  local function is_title(row, line)
    if line == tostring(row.charKey or row.name) then return true end
    for _, p in ipairs(row.profs) do if line == p.label .. " " .. p.skill then return true end end
    return false
  end

  it("translates every sentence of the row tooltip (a stale character)", function()
    local row = V.Row(A:GetAltRow("Bren-Silvermoon", NOW), NOW)
    local lines = V.TooltipLines(row)
    for i, line in ipairs(lines) do
      if not is_title(row, line) then assert.equal("T:", plain(line):sub(1, 2), i .. ": " .. plain(line)) end
    end
    assert.equal("T:Last seen: T:10d ago (stale)", lines[3])
    assert.equal("T:  Knowledge left this week: 3", lines[6])
    assert.equal("T:  Concentration: 1000/1000 \194\183 T:Full", lines[5])
  end)

  it("translates every sentence of the current character's tooltip", function()
    local row = V.Row(A:GetAltRow("Aria-Silvermoon", NOW), NOW)
    local lines = V.TooltipLines(row)
    for i, line in ipairs(lines) do
      if not is_title(row, line) then assert.equal("T:", plain(line):sub(1, 2), i .. ": " .. plain(line)) end
    end
    assert.equal("T:Older expansions: 1", row.older)
  end)

  it("adds the outdated-data note to the knowledge line and explains it", function()
    local row = V.Row(A:GetAltRow("Aria-Silvermoon", NOW), NOW)
    local note = V.DataBuildNote(70000, 70575)
    assert.equal("T:data build 70000 (outdated)", note)
    local lines = V.TooltipLines(row, note)
    assert.equal("T:  Knowledge left this week: 2 \194\183 T:data build 70000 (outdated)", lines[6])
    local marker = V.DataMarker(70000, 70575)
    assert.equal("T:Game data build 70000 is outdated", marker.tooltip[1])
    assert.equal("T:Knowledge sources and counts come from game build 70000; this is game build 70575, so they may be wrong.",
      marker.tooltip[2])
    local header = V.Header({ A:GetAltRow("Aria-Silvermoon", NOW) }, note)
    assert.equal("T:Knowledge T:data build 70000 (outdated): the game has changed since, so counts may be wrong",
      header.tooltip[#header.tooltip])
  end)

  it("translates the header text and its tooltip, with and without unknown gold", function()
    local rows = { A:GetAltRow("Aria-Silvermoon", NOW), A:GetAltRow("Bren-Silvermoon", NOW) }
    local header = V.Header(rows, nil)
    assert.equal(1, header.text:find("T:Characters: 2 \194\183 T:Gold: ", 1, true))
    assert.truthy(header.text:find("\194\183 T:Knowledge left: ", 1, true))
    assert.truthy(header.text:find(" KP", 1, true))
    for i, line in ipairs(header.tooltip) do assert.equal("T:", line:sub(1, 2), i .. ": " .. line) end
    rows[2].gold = nil
    local unknown = V.Header(rows, nil)
    assert.equal("T:1 character's gold is unknown", unknown.tooltip[4])
    rows[1].gold = nil
    assert.equal("T:2 characters' gold is unknown", V.Header(rows, nil).tooltip[4])
  end)

  it("translates the detail lines under an opened row", function()
    for _, name in ipairs({ "Aria-Silvermoon", "Bren-Silvermoon" }) do
      local altRow = A:GetAltRow(name, NOW)
      local lines = V.DetailLines(altRow, NOW)
      for i, line in ipairs(lines) do
        if i > 1 then assert.equal("T:", plain(line):sub(1, 2), name .. " " .. i .. ": " .. plain(line)) end
      end
    end
    local lines = V.DetailLines(A:GetAltRow("Aria-Silvermoon", NOW), NOW)
    assert.truthy(lines[2]:find("T:  Spec: T:17/63 spent \194\183 T:4 unspent Blacksmithing Knowledge \194\183 T:data ", 1, true))
    assert.truthy(lines[4]:find("\194\183 T:full at ", 1, true))
    assert.truthy(lines[5]:find("T:  Cooldown: T:Recipe 1001 \194\183 T:ready in T:2h 0m (", 1, true))
    assert.equal("T:Older expansions: 1 (not shown in the grid)", lines[6])
    assert.equal("T:  Spec: no data (open this profession's specializations on Bren)",
      V.DetailLines(A:GetAltRow("Bren-Silvermoon", NOW), NOW)[2])
  end)

  it("translates the unknown and next-cooldown variants", function()
    local row = { charKey = "X-Y", name = "X", gold = "1g", age = "1d", profs = { { label = "P", skill = "1/2",
      conc = "5/10", kp = "1", spec = "?", moxie = "1", cds = "2 \194\183 T:ready", cdsNext = "1h" } } }
    local lines = V.TooltipLines(row, nil)
    assert.equal("T:  Cooldowns: 2 \194\183 T:ready, next in 1h", lines[#lines - 1])
    row.profs[1].cds = "2 \194\183 1h"
    lines = V.TooltipLines(row, nil)
    assert.equal("T:  Cooldowns: 2 \194\183 1h", lines[#lines - 1])
    local detail = V.DetailLines({ name = "X", professions = { { name = "P", skill = 1, maxSkill = 2, spec = {},
      concentration = { now = 1, max = 2, rateUnknown = true }, cooldowns = {
        { recipeID = 8, readyAt = NOW - 1 }, { recipeID = 9, readyAt = NOW - 1, charges = 1, maxCharges = 2 },
        { recipeID = 7 } } } } }, NOW)
    assert.equal("T:  Spec: T:? spent \194\183 T:? unspent T:points \194\183 T:data age unknown", detail[2])
    assert.equal("T:  Concentration: 1/2 \194\183 T:fill time unknown (no regeneration data)", detail[4])
    assert.equal("T:  Cooldown: T:Recipe 8 \194\183 T:ready", detail[5])
    assert.equal("T:  Cooldown: T:Recipe 9 \194\183 T:ready \194\183 T:charges 1/2", detail[6])
    assert.equal("T:  Cooldown: T:Recipe 7 \194\183 T:ready time unknown", detail[7])
    assert.equal("T:  Concentration: unknown", V.DetailLines({ professions = { { name = "P" } } }, NOW)[4])
  end)

  it("translates the cooldown cell, the hidden mark and the slot tooltips", function()
    local row = V.Row(A:GetAltRow("Aria-Silvermoon", NOW), NOW)
    row.hidden = true
    assert.truthy(plain(V.CellTexts(row, { hidden = {} }).name):find("T: (hidden)", 1, true))
    assert.equal("1 \194\183 T:2h 0m", row.profs[1].cds)   -- the duration is a key
    local cooldowns = { { readyAt = NOW - 5 }, { readyAt = NOW + 3600 }, { readyAt = NOW - 1 } }
    assert.equal("3 \194\183 T:2 ready", ns.UI.CharactersView.Row({ professions = { { skillLineID = 1, cooldowns = cooldowns } } },
      NOW).profs[1].cds)
    assert.equal("T:Skill 7 ", V.Row({ professions = { { skillLineID = 7 } } }, NOW).profs[1].label .. " ")
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
    for _, pair in ipairs(lines) do if pair[1] == "T:Bren-Silvermoon Herbalism" then unknown = pair end end
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
    assert.equal("T:Prices: T:2h ago", prices)
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
    setmetatable(ns.L, { __index = function(_, key) return "T:" .. key end })   -- before the files load: constants too
    P2.load(ns, ORDERS_FILES)
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
    assert.equal("T:Orders seen T:<1m ago on Me-Silvermoon", Tab.Model({}, { ["Me-Silvermoon"] = 970 }, filters, 1000).header)
    assert.equal("T:No orders seen yet", Tab.Model({}, {}, filters, 1000).header)
    local several = Tab.Model({ { orderID = 1, charKey = "Me-Silvermoon", expiresAt = 1600 } },
      { ["Me-Silvermoon"] = 970, ["Alt-Silvermoon"] = 970 }, filters, 1000)
    assert.equal("T:Orders from 2 characters \194\183 T:next expires in T:10m", several.header)
    assert.equal("T:Alt-Silvermoon: 0 orders, seen T:<1m ago\nT:Me-Silvermoon: 1 order, seen T:<1m ago", several.headerTooltip)
  end)

  it("reads the tip benchmark's quality scope through the Q%d key", function()
    local Tab = ns.UI.OrdersTab
    assert.equal("T:Your tips (T:Q3): no history yet", Tab.BenchmarkText(nil, 3))
    assert.equal("T:Your tips (T:Q3): no history yet", Tab.BenchmarkText(nil, 3.0))
    assert.equal("T:Your tips (T:all qualities): no history yet", Tab.BenchmarkText(nil, nil))
  end)

  it("translates the recraft note of a row", function()
    local notes = ns.UI.OrdersPanel.Notes({ flags = { recraft = true } })
    assert.equal("T:Recraft \226\128\148 judge manually", notes[1])
  end)

  it("shows order and ledger types through keys", function()
    local Tab = ns.UI.OrdersTab
    local m = Tab.Model({ { orderID = 1, orderType = "public", itemID = 5, risks = {}, charKey = "Me-Silvermoon" } },
      { ["Me-Silvermoon"] = 900 }, { hideRisks = {}, orderTypes = { public = true } }, 1000)
    assert.equal("T:Public", Tab.CellTexts(m.rows[1]).type)
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
    local row = { nameRealm = "B-Silvermoon", orders = 1, tagsText = "blocked", tags = { "blocked" },
      blockedVia = "Al-Silvermoon" }
    assert.equal("T:blocked (via Al)", T.CellTexts(row, 1000).tags)   -- the main's realm is left out
    row.blockedVia = "Someone-Area52"
    assert.equal("T:blocked (alt)", T.CellTexts(row, 1000).tags)   -- the long phrase does not fit
    -- Two tags: the separator is the list key, "blocked" is replaced inside the list.
    local both = { nameRealm = "B-Silvermoon", orders = 1, tagsText = "VIPT:, blocked",
      tags = { "VIP", "blocked" }, blockedVia = "Al-Silvermoon" }
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

  it("shows order and ledger types through keys", function()
    C:RecordOrder("Bob-Silvermoon", { orderID = 1, time = 500, itemID = 5, quality = 3, tip = 100, orderType = "public" })
    local container = CreateFrame("Frame")
    container:SetSize(740, 500)
    reg.customers.build(container)
    reg.customers.refresh(container)
    local v = ns.FS:GetModule("CustomersTab"):GetView()
    local row
    for i = 1, v.list.shown do if v.list.pool[i].data.nameRealm == "Bob-Silvermoon" then row = v.list.pool[i] end end
    row:GetScript("OnClick")(row)
    local history = v.detail.history.pool[1]
    history:GetScript("OnEnter")(history)
    assert.truthy(table.concat(tooltip.lines, "\n"):find("T:Order: T:Public", 1, true), table.concat(tooltip.lines, "|"))
  end)

  it("shows the tag chip and the history quality through keys", function()
    C:RecordOrder("Bob-Silvermoon", { orderID = 1, time = 500, itemID = 5, quality = 3, tip = 100, orderType = "public" })
    C:SetTag("Bob-Silvermoon", "friend", true)
    local container = CreateFrame("Frame")
    container:SetSize(740, 500)
    reg.customers.build(container)
    reg.customers.refresh(container)
    local v = ns.FS:GetModule("CustomersTab"):GetView()
    local row
    for i = 1, v.list.shown do if v.list.pool[i].data.nameRealm == "Bob-Silvermoon" then row = v.list.pool[i] end end
    row:GetScript("OnClick")(row)
    assert.equal("T:friend x", v.detail.chips[1].label)
    assert.equal("T:Q3", v.detail.history.pool[1].cells.quality:GetText())
  end)

  it("translates the customer and its alt count as one sentence", function()
    local cells = T.CellTexts({ nameRealm = "Bob-Silvermoon", orders = 1, tagsText = "", alts = 2 }, 1000)
    assert.equal("T:Bob-Silvermoon (+2)", cells.name)
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

  it("shows order and ledger types through keys", function()
    assert.equal("T:recraft", T.CellTexts("entry", { type = "commission", amount = 1, time = 0, recraft = true }).type)
    assert.equal("T:craft", T.CellTexts("entry", { type = "craft", amount = 1, time = 0 }).type)
    assert.equal("T:sale", T.CellTexts("entry", { type = "sale", amount = 1, time = 0 }).type)
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
    assert.equal("T:1 entries, newest T:<1m ago", plain(ns.FS:GetModule("LedgerTab"):GetView().header:GetText()))
  end)
end)

-- Task 10: the Characters tab, the holdings tooltip lines and the knowledge widget.
describe("a non-identity ns.L (characters sentences)", function()
  local TAB_FILES = { "Modules/Alts.lua", "Modules/AltsCollector.lua", "UI/Widgets/ExpandGrid.lua", "UI/Tabs/ViewUtil.lua",
    "UI/Tabs/CharactersView.lua", "UI/Tabs/PlannerView.lua", "Modules/Planner.lua", "Modules/PlannerSpec.lua",
    "UI/OrdersPanel.lua", "UI/Tabs/Characters.lua", "UI/AltsDashboard.lua" }
  local tooltip = { lines = {} }
  local ns, env, W, A, Tab

  -- Edit boxes, check buttons and buttons that keep their text and checked state (the shared stubs make them no-ops).
  local function stateful_frames()
    local real = _G.CreateFrame
    _G.CreateFrame = function(frameType, name, parent, template)
      local f = real(frameType, name, parent, template)
      if frameType == "EditBox" or frameType == "CheckButton" or frameType == "Button" then
        local text, checked = "", false
        function f:SetText(t) text = t end
        function f:GetText() return text end
        function f:SetChecked(v) checked = v and true or false end
        function f:GetChecked() return checked end
        if template == "SearchBoxTemplate" then f.Instructions = f:CreateFontString() end
      end
      return f
    end
  end

  before_each(function()
    tooltip.lines = {}
    ns, env, W = phase3_env({ files = TAB_FILES, wow = {
      GameTooltip = {
        SetOwner = function() tooltip.lines = {} end,
        SetText = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
        AddLine = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
        Show = function() end, Hide = function() end,
      },
      C_Item = { GetItemCount = function() return nil end,
        GetItemNameByID = function(id) return id == 2001 and "Bismuth Ore" or nil end },
    } })
    stateful_frames()
    A = ns.FS:GetModule("Alts")
    Tab = ns.UI.CharactersTab
    W.advance(1)
    setmetatable(ns.L, { __index = function(_, key) return "T:" .. key end })
  end)

  it("translates the specialization points as one sentence", function()
    local row = ns.UI.CharactersView.Row({ charKey = "Aria-Silvermoon", professions = { { skillLineID = 1, name = "Mining",
      spec = { spent = 17, max = 63, unspent = 4 } } } }, NOW)
    assert.equal("T:17/63 (+4)", row.profs[1].spec)
  end)

  it("translates the holdings tooltip lines, warband age and totals included", function()
    local lines = A:HoldingsLines(2001)
    assert.equal("T:15 (T:bags 5T:, T:bank 10)", lines[1][2])
    assert.equal("T:3 (T:reagent bank 3T:, T:T:10d old)", lines[2][2])
    assert.equal("T:Warband bank", lines[3][1])
    assert.equal("T:Total", lines[4][1])
    A:Settings().tooltipMaxChars = 1
    assert.equal("T:+1 more", A:HoldingsLines(2001)[2][1])
  end)

  it("translates the warband bank age and the unscanned warband bank in the holdings", function()
    ns.FS.db.global.warband.time = NOW - 10 * 86400
    local lines = A:HoldingsLines(2001)
    assert.equal("T:7 (T:10d old)", lines[3][2])
    ns.FS.db.global.warband = nil
    lines = A:HoldingsLines(2001)
    assert.equal("T:18+ (warband not scanned)", lines[#lines][2])
  end)

  it("translates the age fallback of the holdings when ns.UI.FormatAge is not loaded", function()
    ns.UI.FormatAge = nil
    ns.FS.db.global.warband.time = NOW - 10 * 86400
    assert.equal("T:7 (T:10d old)", A:HoldingsLines(2001)[3][2])
  end)

  it("translates the reagent search status and its empty text", function()
    assert.equal("T:Search: 1 item", (Tab.SearchStatus("ore", { {} }, false)))
    assert.equal("T:Search: 2 items", (Tab.SearchStatus("ore", { {}, {} }, false)))
    assert.equal("T:Search: 1 item \194\183 T:visible characters only (hidden ones are not searched)",
      (Tab.SearchStatus("ore", { {} }, true)))
    assert.equal("T:Search: 1 item \194\183 T:+: a bank or the warband bank was never scanned",
      (Tab.SearchStatus("ore", { { partial = true } }, false)))
    local _, empty = Tab.SearchStatus("zzz", {}, false)
    assert.equal("T:No reagent named \"zzz\" on your visible characters or in the warband bank", empty)
    local _, hidden = Tab.SearchStatus("zzz", {}, true)
    assert.equal("T:No reagent named \"zzz\" on your visible characters or in the warband bank "
      .. "(hidden characters are not searched)", hidden)
  end)

  it("translates a search result row's tooltip", function()
    local rows = A:FindItems("bismuth")
    assert.is_true(#rows > 0)
    local row = Tab.ResultRow(rows[1], "Aria-Silvermoon")
    assert.equal("Bismuth Ore", row.tooltip[1])
    for i = 2, #row.tooltip do assert.equal("T:", row.tooltip[i]:sub(1, 2), i .. ": " .. row.tooltip[i]) end
    assert.equal("T:Aria: 15T:, T:Bren: 3", row.cells.chars)   -- the holder list: "%s: %s" per holder, the list separator
    assert.equal("T:Aria: 15 (T:bags 5T:, T:bank 10)", row.tooltip[2])
    assert.equal("T:Warband bank: 7", row.tooltip[#row.tooltip - 1])
    assert.equal("T:Total: 25", row.tooltip[#row.tooltip])
  end)

  it("translates the hide and show notices of the status line", function()
    local container = CreateFrame("Frame")
    container:SetSize(716, 500)
    local reg = env.registered.tabs
    ns.FS:GetModule("MainWindow").RefreshTab = function(_, id) reg[id].refresh(container) end
    reg.characters.build(container)
    reg.characters.refresh(container)
    local v = ns.FS:GetModule("CharactersTab"):GetView()
    local row
    for i = 1, v.grid.shownRows do
      if v.grid.rowPool[i].data.key == "Bren-Silvermoon" then row = v.grid.rowPool[i] end
    end
    row:GetScript("OnClick")(row)
    local hide = v.grid.detailPool[1].hideButton
    hide:GetScript("OnClick")(hide)
    assert.equal("T:Hidden: Bren-Silvermoon (tick Show hidden to see it again)", plain(v.status:GetText()))
    assert.equal("T:Show hidden (1)", v.showHiddenLabel:GetText())
  end)

  it("translates the knowledge widget's total line", function()
    local checklist = ns.FS:GetModule("Planner"):GetKnowledgeChecklist(NOW)
    local model = ns.UI.AltsDashboard.KnowledgeModel(checklist, "ok", 6)
    assert.truthy(plain(model.lines[1]):find("T:Total: ", 1, true))
  end)
end)

-- Task 11: the planner's tab, view and chat sentences are whole keys, so a translated ns.L reaches every sentence.
-- The ns.L metatable is set BEFORE the files load (before_load), so load-time constants (category labels, state words)
-- are translated too. Character keys, recipe and item names, durations and numbers are data, not sentences.
describe("a non-identity ns.L (planner sentences)", function()
  local P2 = require("tests.helpers.phase2")
  local PLANNER_FILES = { "Modules/Alts.lua", "Modules/AltsCollector.lua", "Modules/CraftingData.lua",
    "Modules/Planner.lua", "Modules/PlannerSpec.lua", "UI/Widgets/ExpandGrid.lua", "UI/Tabs/ViewUtil.lua",
    "UI/Tabs/CharactersView.lua", "UI/Tabs/PlannerView.lua", "UI/OrdersPanel.lua", "UI/Tabs/Planner.lua" }
  local OLD_BUILD = { GetBuildInfo = function() return "12.2.0", "70700", "Nov 1 2026", 120200 end }
  local ns, env, W, PL, Tab, PV, reg, container
  local tooltip = { lines = {} }
  local added, queueAnswer

  -- Buttons that keep their text and highlight lock (the shared stubs make them no-ops).
  local function stateful_buttons()
    local real = _G.CreateFrame
    _G.CreateFrame = function(frameType, name, parent, template)
      local f = real(frameType, name, parent, template)
      if frameType == "Button" then
        local text = ""
        function f:SetText(t) text = t end
        function f:GetText() return text end
      end
      return f
    end
  end

  local function boot(wow)
    tooltip.lines, added, queueAnswer, container = {}, {}, 7, nil
    ns, env, W = phase3_env({
      files = PLANNER_FILES, recipeLines = { [1001] = 2907, [1002] = 2907 },
      ranked = { { recipeID = 1001, charKey = "Aria-Silvermoon", concentrationCost = 200, goldPerConcentration = 80,
        profit = 5000, flags = {} }, { recipeID = 1002, charKey = "Aria-Silvermoon", profit = 1000, flags = {} } },
      before_load = function(n) setmetatable(n.L, { __index = function(_, key) return "T:" .. key end }) end,
      queue = { Add = function(_, entry) added[#added + 1] = entry; return queueAnswer end },
      wow = P2.merge({ GameTooltip = {
        SetOwner = function() tooltip.lines = {} end,
        SetText = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
        AddLine = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
        Show = function() end, Hide = function() end },
        C_Spell = { GetSpellName = function(id) return id == 1001 and "Truesilver Transmute" or nil end },
        C_Item = { GetItemCount = function() return nil end,
          GetItemNameByID = function(id) return id == 263455 and "Smith's Notes" or nil end } }, wow or {}),
    })
    stateful_buttons()
    PL, Tab, PV = ns.FS:GetModule("Planner"), ns.UI.PlannerTab, ns.UI.PlannerView
    reg = env.registered.tabs
    W.advance(1)
  end

  local function open()
    container = CreateFrame("Frame")
    container:SetSize(716, 500)
    reg.planner.build(container)
    reg.planner.refresh(container)
    return ns.FS:GetModule("PlannerTab"):GetView()
  end
  local function click(button) button:GetScript("OnClick")(button) end
  local function hover(frame) frame:GetScript("OnEnter")(frame) end
  local function select(v, id) click(v.sections[id]) end
  local function row_frame(grid, key)
    for i = 1, grid.shownRows do
      if grid.rowPool[i].data.key == key then return grid.rowPool[i] end
    end
  end

  before_each(function() boot() end)

  -- Replaces the translation with one that also records the keys asked for (a %d key is the only plural that fits a
  -- number; the T: text alone cannot tell it from a %s key).
  local function record_keys()
    local seen = {}
    setmetatable(ns.L, { __index = function(_, key) seen[key] = true; return "T:" .. key end })
    return seen
  end

  local function all_translated(lines, from)
    for i = from or 1, #lines do assert.equal("T:", plain(lines[i]):sub(1, 2), i .. ": " .. plain(lines[i])) end
  end

  it("really translates (guards the other tests)", function()
    assert.equal("T:Full", ns.L["Full"])
  end)

  describe("the cap warning row", function()
    local pool = { status = "capped", charKey = "Aria-Silvermoon", skillLineID = 2907, value = 1000, max = 1000,
      fullAt = NOW }

    it("translates the cells and every tooltip sentence of a full pool", function()
      local row = Tab.WarningRow(pool, NOW)
      assert.equal("T:Capped: concentration is full", plain(row.cells.recipe))
      assert.equal("T:Full", plain(row.cells.caps))
      assert.equal("T:Capped: concentration is full", row.tooltip[1])
      assert.equal("T:Aria-Silvermoon Blacksmithing", row.tooltip[2])   -- character and profession: data
      assert.equal("T:Concentration: 1000/1000", row.tooltip[3])
      assert.equal("T:Spend it before more is wasted", row.tooltip[4])
      all_translated(row.tooltip, 3)
    end)

    it("translates the soon row, with an unknown value as ?", function()
      local row = Tab.WarningRow({ status = "soon", charKey = "Aria-Silvermoon", skillLineID = 2907,
        fullAt = NOW + 7200 }, NOW)
      assert.equal("T:Soon: full in T:2h 0m", plain(row.cells.recipe))
      assert.equal("T:Concentration: ?/?", row.tooltip[3])
      assert.equal("T:Spend some before it is full", row.tooltip[4])
    end)

    it("translates the chat line of a warning, with the time to full nested", function()
      PL:Settings().capWarnHours = 72
      PL:AnnounceCapWarnings(NOW)
      assert.same({ "T:FabricationStation: T:Bren-Silvermoon Herbalism: concentration is full",
        "T:FabricationStation: T:Aria-Silvermoon Blacksmithing: concentration full in T:2d 12h" }, W.printed)
    end)
  end)

  describe("the schedule row", function()
    local function schedule(extra)
      local r = { charKey = "Aria-Silvermoon", skillLineID = 2907, recipeID = 1001, crafts = 2, concentrationUsed = 400,
        expectedGain = 12345, goldPerConcentration = 678, fullAt = NOW + 3 * 3600 }
      for k, v in pairs(extra or {}) do r[k] = v end
      return r
    end

    it("translates every tooltip sentence after the names", function()
      local row = Tab.ScheduleRow(schedule(), NOW)
      assert.equal("Truesilver Transmute", row.tooltip[1])
      assert.equal("T:Aria-Silvermoon Blacksmithing", row.tooltip[2])
      assert.equal("T:Crafts: 2 (400 concentration)", row.tooltip[3])
      assert.truthy(row.tooltip[4]:find("^T:Expected gain: "))
      assert.truthy(row.tooltip[5]:find("^T:Gold per concentration: "))
      assert.equal("T:Full in: T:3h 0m", row.tooltip[6])
      assert.equal("T:Queue adds the crafts with concentration", row.tooltip[7])
      all_translated(row.tooltip, 3)
    end)

    it("translates the full, unknown and slow variants of the time to full", function()
      local full = Tab.ScheduleRow(schedule({ fullAt = NOW }), NOW)
      assert.equal("T:Full", full.cells.caps)
      assert.equal("T:Full in: now (full)", full.tooltip[6])
      assert.equal("T:Full in: unknown",
        Tab.ScheduleRow(schedule({ fullAt = false, rateUnknown = true }), NOW).tooltip[6])
      assert.equal("T:Full in: more than 14 days", Tab.ScheduleRow(schedule({ fullAt = false }), NOW).tooltip[6])
    end)

    it("falls back to translated names for a recipe and a profession the client does not know", function()
      local row = Tab.ScheduleRow(schedule({ recipeID = 777, skillLineID = 999 }), NOW)
      assert.equal("T:Recipe 777", row.cells.recipe)
      assert.equal("T:Skill 999", row.cells.profession)
    end)
  end)

  describe("the concentration lines", function()
    it("translates the full marker, the fallback profession name and the overflow line", function()
      local pools = {
        { charKey = "Aria-Silvermoon", skillLineID = 2907, value = 1000, max = 1000, fullAt = NOW, secondsToFull = 0 },
        { charKey = "Bren-Silvermoon", skillLineID = 4242, value = 100, max = 1000, fullAt = NOW + 7200 },
        { charKey = "Cato-Silvermoon", skillLineID = 2907, value = 50, max = 1000, fullAt = NOW + 9000 },
        { charKey = "Dora-Silvermoon", skillLineID = 2907, value = 40, max = 1000, fullAt = NOW + 9500 },
      }
      local lines = PV.ConcentrationLines(pools, NOW, 3)
      assert.equal("T:Aria-Silvermoon Blacksmithing", lines[1][1])
      assert.equal("T:Full", lines[1][2])
      assert.equal("T:Bren-Silvermoon T:Skill 4242", lines[2][1])   -- a name and a name, joined by one key
      assert.equal("T:2h 0m", lines[2][2])
      assert.equal("T:+2 more", lines[3][1])
      assert.equal("", lines[3][2])
    end)
  end)

  describe("the knowledge texts", function()
    local function aria() return PL:GetKnowledgeChecklist()[2] end

    it("translates every detail line after the title", function()
      local lines = Tab.KnowledgeDetailLines(aria(), { [263455] = "Smith's Notes" })
      assert.same({ "|cffffd100T:Aria-Silvermoon Blacksmithing|r",
        "T:  T:Darkmoon Faire: 0/3 KP \194\183 T:closed (not the faire week)",
        "T:  T:Treasure: 0/2 KP \194\183 T:open",
        "T:  T:One-time: 0/3 KP \194\183 T:open",
        "T:  T:Weekly quest: Smith's Notes \194\183 2/2 KP \194\183 T:done",
        "T:  First crafts: 2 pending" }, lines)
      assert.equal("T:  T:Weekly quest: item:263455 \194\183 2/2 KP \194\183 T:done",
        Tab.KnowledgeDetailLines(aria(), {})[5])
      assert.equal("T:  No knowledge data for this profession in this GameData build",
        Tab.KnowledgeDetailLines({ charKey = "A-B", name = "Alchemy", summary = { status = "noData" }, states = {} })[2])
    end)

    it("translates the grid cell text and the tooltip lines", function()
      local cells = PV.KnowledgeCells(aria()).cells
      assert.equal("T:closed", cells.darkmoon)
      assert.equal("\226\128\148", cells.treatise)
      local lines = PV.KnowledgeTooltipLines(aria())
      assert.equal("T:T:Weekly quest: 2/2 (done)", lines[2])
      assert.equal("T:T:Treasures: 0/2", lines[4])
      assert.equal("T:T:Darkmoon Faire: T:closed", lines[6])
      assert.equal("T:First crafts: 2", lines[8])
      assert.equal("T:Left this week: 2", lines[9])
      all_translated(lines, 2)
      -- A profession without data adds its sentence.
      local noData = PV.KnowledgeTooltipLines({ charKey = "A-B", name = "Alchemy", summary = { status = "noData" },
        states = {} })
      assert.equal("T:No knowledge data for this profession in this GameData build", noData[#noData])
    end)

    it("translates the knowledge lines, their overflow and the weekly total", function()
      local rows = PL:GetKnowledgeChecklist()
      local lines = PV.KnowledgeLines(rows)
      assert.same({ "T:Total", "T:5 KP" }, { lines[1][1], lines[1][2] })
      assert.equal("T:3 KP", lines[2][2])
      assert.equal("T:+2 more", PV.KnowledgeLines(rows, 2)[2][1])
      assert.equal("T:? KP", PV.KnowledgeLines({ { charKey = "A-B", name = "Alchemy", summary = { status = "noData" } } })[2][2])
    end)

    it("translates the outdated marker on the total and the note nested in its sentences", function()
      boot({ GetBuildInfo = OLD_BUILD.GetBuildInfo })
      local lines = PV.KnowledgeLines(PL:GetKnowledgeChecklist())
      assert.equal("T:T:5 KP (outdated)", lines[1][2])
      assert.equal("T:Knowledge T:data build 70575 (outdated): the game has changed since, so counts may be wrong",
        lines[1].tooltip)
      local tip = PV.KnowledgeTooltipLines(PL:GetKnowledgeChecklist()[2])
      assert.equal("T:Knowledge T:data build 70575 (outdated)", tip[#tip])
    end)

    it("translates both footers and their tooltips", function()
      local text, tip = Tab.KnowledgeFooter()
      assert.equal("T:Knowledge data: build 70575 \194\183 T:Weekly reset in T:4d 3h", text)
      assert.equal("T:Knowledge sources come from GameData build 70575", tip[2])
      text, tip = Tab.MissingFooter()
      assert.equal("T:Recipe sources: not generated \194\183 T:Recipe lists fill in when you open the profession on any character",
        text)
      all_translated(tip)
    end)
  end)

  describe("the status and empty texts", function()
    it("translates every status of a named character", function()
      local function status(code) return PV.StatusText(code, { char = "Bren" }) end
      assert.equal("T:Hidden: Bren is hidden on the Characters tab", status("hidden"))
      assert.equal("T:Bren does not have this profession", status("noProfession"))
      assert.equal("T:Open this profession on Bren", status("notScanned"))
      assert.equal("T:Open this profession's specializations on Bren to load spec data", status("noSpec"))
      assert.equal("T:No profitable recipes for Bren in this profession yet: check prices or open the profession",
        status("noRecipes"))
      assert.equal("T:No data (weird)", status("weird"))
      assert.equal("T:Bren knows every listed recipe of this profession", PV.EmptyText("missing", { char = "Bren" }))
    end)

    it("translates the stand-in for a character that has no name yet, nested in its sentence", function()
      assert.equal("T:Open this profession on T:this character", PV.StatusText("notScanned"))
      assert.equal("T:T:This character knows every listed recipe of this profession", PV.EmptyText("missing"))
    end)
  end)

  describe("the spec advice and missing recipe texts", function()
    it("translates the estimate note, the path fallback and the source sentences", function()
      local model = PV.SpecAdvice({ { pathID = 9, rank = 1, maxRank = 3, gain = 100, points = 2, affordable = true } },
        "ok", { topRecipes = 7 })
      assert.equal("T:Estimate from your top 7 profitable recipes", model.note)
      assert.equal("T:Path 9", model.rows[1].path)
      assert.equal("T:Affordable", model.rows[1].affordable)
      assert.equal("T:Recipe item: Plans: Axe", PV.SourceText({ kind = "item", itemID = 1 }, "Plans: Axe"))
      assert.equal("T:Recipe item: item:5", PV.SourceText({ kind = "item", itemID = 5 }))
      assert.equal("T:Learned automatically", PV.SourceText({ kind = "auto" }))
      assert.equal("T:Unknown \226\128\148 open the profession on any character to load sources", PV.SourceText({}))
    end)
  end)

  describe("the tab frame", function()
    local function stub_spec()
      PL._nodeBonus = function(_, _, _, pathID)
        return pathID == 1 and { skill = 5, recipes = { [1001] = true } } or { multicraft = 10 }
      end
      PL._evaluateWithBonus = function(_, recipeID, charKey, bonus)
        local base = ({ [1001] = 5000, [1002] = 1000 })[recipeID]
        return { recipeID = recipeID, charKey = charKey, profit = base + (bonus.skill and 2500 or 500), flags = {} }
      end
    end

    it("translates the Knowledge status and its tooltip", function()
      local v = open()
      assert.equal("T:Knowledge left: T:5 KP", plain(v.status:GetText()))
    end)

    it("translates the Concentration status and the schedule row's hover", function()
      PL:Settings().capWarnHours = 72
      local seen = record_keys()
      local v = open()
      select(v, "concentration")
      assert.equal("T:Plan: 2 crafts \194\183 T:Capped: 1 \194\183 T:Soon: 1", plain(v.status:GetText()))
      assert.is_true(seen["Plan: %d crafts"])
      hover(row_frame(v.grids.concentration, "plan:Aria-Silvermoon:2907:1001"))
      assert.equal("Truesilver Transmute", tooltip.lines[1])
      all_translated(tooltip.lines, 3)
    end)

    it("translates the feedback of a Queue click, queued and not queued", function()
      local v = open()
      select(v, "concentration")
      click(row_frame(v.grids.concentration, "plan:Aria-Silvermoon:2907:1001").queueButton)
      assert.equal("T:Queued: 2 \195\151 Truesilver Transmute for Aria-Silvermoon (with concentration)",
        plain(v.status:GetText()))
      queueAnswer = nil
      click(row_frame(v.grids.concentration, "plan:Aria-Silvermoon:2907:1001").queueButton)
      assert.equal("T:Not queued: the Queue did not accept 2 \195\151 Truesilver Transmute", plain(v.status:GetText()))
    end)

    it("translates the Spec advice status, row tooltip and pickers", function()
      stub_spec()
      local seen = record_keys()
      local v = open()
      select(v, "spec")
      assert.equal("T:Spec advice: 2 paths", plain(v.status:GetText()))
      assert.is_true(seen["Spec advice: %d paths"])
      assert.equal("T:Estimate from your top 20 profitable recipes", v.footer:GetText())
      hover(row_frame(v.grids.spec, 1))
      assert.same({ "Path 1", "T:Rank: 10/30", "T:Points to the next step: 5", "T:Gain: 25s 0c",
        "T:Per point: 5s 0c", "T:Needs more points than you have unspent" }, { tooltip.lines[1], tooltip.lines[2],
        tooltip.lines[3], tooltip.lines[4], tooltip.lines[5], tooltip.lines[6] })
      hover(v.charButton)
      assert.same({ "T:Character: Aria-Silvermoon", "T:Click for the next character (2 with a Midnight profession)" },
        tooltip.lines)
      hover(v.profButton)
      assert.same({ "T:Profession: Blacksmithing", "T:Click for the next profession of Aria (1)" }, tooltip.lines)
      click(v.charButton)
      assert.equal("T:Open this profession's specializations on Bren to load spec data", plain(v.empty:GetText()))
    end)

    it("translates the Spec advice status for one path", function()
      PL.GetSpecAdvice = function()
        return { { pathID = 1, name = "Path 1", rank = 1, maxRank = 3, points = 2, gain = 100, gainPerPoint = 50,
          affordable = true } }, "ok"
      end
      local seen = record_keys()
      local v = open()
      select(v, "spec")
      assert.equal("T:Spec advice: 1 path", plain(v.status:GetText()))
      assert.is_true(seen["Spec advice: %d path"])
    end)

    it("translates the Missing recipes status, row tooltip and footer", function()
      ns.FS.db.global.recipeCatalog[2907] = {
        [1001] = { name = "Truesilver Transmute", sourceText = "", time = NOW },
        [1003] = { name = "Bismuth Bar", sourceText = "Trainer: Smith Bob", time = NOW },
        [1005] = { name = "Axe", sourceText = "", time = NOW },
      }
      ns.GameData.Define("RecipeSources", nil, { bySkillLine = { [2907] = { [1005] = { kind = "item", itemID = 3001 },
        [1007] = { kind = "auto" } } } })
      local seen = record_keys()
      local v = open()
      select(v, "missing")
      assert.equal("T:Missing: 3 recipes", plain(v.status:GetText()))
      assert.is_true(seen["Missing: %d recipes"])
      assert.equal("T:Recipe 1007", row_frame(v.grids.missing, 1007).cells.recipe:GetText())
      assert.equal("T:Learned automatically", row_frame(v.grids.missing, 1007).cells.source:GetText())
      hover(row_frame(v.grids.missing, 1005))
      assert.same({ "Axe", "T:Source: T:Recipe item: item:3001", "T:Recipe ID 1005" }, tooltip.lines)
      assert.equal("T:Recipe sources: not generated \194\183 T:Recipe lists fill in when you open the profession on any character",
        v.footer:GetText())
      hover(v.footerHit)
      assert.equal("T:Recipe sources: not generated \194\183 T:Recipe lists fill in when you open the profession on any character",
        tooltip.lines[1])
      all_translated(tooltip.lines, 2)
      ns.FS.db.global.characters["Aria-Silvermoon"].professions[2907].recipes = { [1001] = true, [1003] = true,
        [1005] = true }
      reg.planner.refresh(container)
      assert.equal("T:Missing: 1 recipe", plain(v.status:GetText()))
      assert.is_true(seen["Missing: %d recipe"])
    end)

    it("translates the empty text of a fully known profession and the turned-off message", function()
      ns.FS.db.global.recipeCatalog[2907] = { [1001] = { name = "Truesilver Transmute", sourceText = "", time = NOW } }
      ns.FS.db.global.characters["Aria-Silvermoon"].professions[2907].recipes = { [1001] = true }
      local v = open()
      select(v, "missing")
      assert.equal("T:Aria knows every listed recipe of this profession", plain(v.empty:GetText()))
      ns.FS:GetModule("Planner"):Disable()
      reg.planner.refresh(container)
      assert.equal("T:T:Planner is turned off: turn it on in Settings > Modules to see the plan",
        plain(v.empty:GetText()))
    end)

    it("translates the status of a plan with one craft", function()
      PL:Settings().maxCraftsPerRecipe = 1
      local seen = record_keys()
      local v = open()
      select(v, "concentration")
      assert.equal("T:Plan: 1 craft \194\183 T:Capped: 1 \194\183 T:Soon: 0", plain(v.status:GetText()))
      assert.is_true(seen["Plan: %d craft"])
    end)
  end)
end)

-- Task 6: duration and age units, plurals and the small labels are whole keys under a translated ns.L.
describe("a non-identity ns.L (units, plurals and labels)", function()
  local UNIT_FILES = { "Modules/Alts.lua", "Modules/AltsCollector.lua", "Modules/CraftingData.lua",
    "Modules/Planner.lua", "Modules/PlannerSpec.lua", "UI/Widgets/ExpandGrid.lua", "UI/Tabs/ViewUtil.lua",
    "UI/Tabs/CharactersView.lua", "UI/Tabs/PlannerView.lua", "UI/OrdersPanel.lua" }
  local function translate(ns) setmetatable(ns.L, { __index = function(_, key) return "T:" .. key end }) end

  describe("with the Characters and Planner files", function()
    local ns, V, W

    before_each(function()
      ns, _, W = phase3_env({ files = UNIT_FILES,
        before_load = function(n) setmetatable(n.L, { __index = function(_, key) return "T:" .. key end }) end })
      V = ns.UI.CharactersView
      W.advance(1)
    end)

    it("formats every duration through keys", function()
      assert.are.equal("T:<1m", ns.UI.FormatAge(30)); assert.are.equal("T:5m", ns.UI.FormatAge(300))
      assert.are.equal("T:2h", ns.UI.FormatAge(7200)); assert.are.equal("T:3d", ns.UI.FormatAge(3 * 86400))
      assert.are.equal("T:<1m", V.FormatDuration(30)); assert.are.equal("T:45m", V.FormatDuration(45 * 60))
      assert.are.equal("T:1h 1m", V.FormatDuration(3660))
      assert.are.equal("T:2d 4h", V.FormatDuration(2 * 86400 + 4 * 3600))
    end)

    it("reads the cells of a pool that is not full within 14 days through the key", function()
      local items = ns.UI.PlannerView.ConcentrationLines({ { charKey = "Aria-Silvermoon", skillLineID = 2907,
        value = 10, max = 1000, fullAt = false } }, NOW, 5)
      assert.equal("T:>14d", items[1][2])
    end)

    it("translates the whole-hour duration of the chat line when the Characters view is not loaded", function()
      ns.UI.CharactersView = nil
      ns.FS:GetModule("Planner"):Settings().capWarnHours = 72
      ns.FS:GetModule("Planner"):AnnounceCapWarnings(NOW)
      assert.equal("T:FabricationStation: T:Aria-Silvermoon Blacksmithing: concentration full in T:60h", W.printed[2])
    end)

    it("joins a character and a profession through one key in the concentration and knowledge lines", function()
      local items = ns.UI.PlannerView.ConcentrationLines({ { charKey = "Aria-Silvermoon", skillLineID = 2907,
        value = 1000, max = 1000, fullAt = NOW, secondsToFull = 0 } }, NOW, 5)
      assert.equal("T:Aria-Silvermoon Blacksmithing", items[1][1])
      local lines = ns.UI.PlannerView.KnowledgeTooltipLines({ charKey = "Aria-Silvermoon", skillLineID = 2907,
        name = "Blacksmithing", summary = { status = "noData" }, states = {} })
      assert.equal("T:Aria-Silvermoon Blacksmithing", lines[1])
    end)
  end)

  describe("the Queue tab", function()
    it("formats a wait through keys", function()
      local ns = make_world({ last = "UI/Tabs/Queue.lua" })
      translate(ns)
      local Q = ns.UI.QueueTab
      assert.are.equal("T:<1m", Q.FormatDuration(10)); assert.are.equal("T:5m", Q.FormatDuration(300))
      assert.are.equal("T:2h", Q.FormatDuration(7200)); assert.are.equal("T:2h 5m", Q.FormatDuration(7500))
      assert.are.equal("T:1d", Q.FormatDuration(86400)); assert.are.equal("T:1d 3h", Q.FormatDuration(86400 + 3 * 3600))
    end)
  end)

  describe("the Dashboard", function()
    it("formats the concentration row and its time to full through keys", function()
      local ns, W, world = make_world({ last = "UI/Tabs/Dashboard.lua" })
      translate(ns)
      local D = ns.FS:GetModule("Dashboard")
      local main = world.chars["Main-Realm"].professions[2906]
      main.name = "Sample Crafting"
      main.concentration = { currencyID = 1, value = 0, max = 100, time = W.now, perCycle = 5, cycleSeconds = 600 }
      local frames = D:BuildAll(CreateFrame("Frame")); D:RefreshAll()
      local text = frames.concentration.lines[1]:GetText()
      assert.truthy(text:find("T:full in T:3h 20m", 1, true), text)
      assert.equal("T:", plain(text):sub(1, 2))
    end)
  end)

  describe("the Recipes tab", function()
    it("shows the quality through a key", function()
      local ns = make_world({ last = "UI/Tabs/Recipes.lua" })
      translate(ns)
      local cells = ns.UI.RecipesTab.CellTexts({ name = "X", flagsText = "", charKey = "Main-Realm", quality = 3,
        cost = 1, sale = 2, profit = 1, noPrice = false, priceAge = nil })
      assert.equal("T:Q3", cells.quality)
    end)
  end)
end)

-- Task 7: every area has a case under a translated ns.L (the first line only, after colour codes are removed).
describe("a non-identity ns.L (the areas without one)", function()
  local function translate(ns) setmetatable(ns.L, { __index = function(_, key) return "T:" .. key end }) end

  describe("Core", function()
    it("starts the game data status with the translated sentence", function()
      local W = install_wow_stubs()
      local ns = load_addon({}, "Core/DB.lua"); W.boot()
      translate(ns)
      assert.equal("T:GameData", ns.FS:GameDataStatusText():sub(1, #"T:GameData"))
    end)

    it("starts the stopped-module chat line with the translated addon name sentence", function()
      local W = install_wow_stubs()
      local ns = load_addon({}, "Core/DB.lua")
      ns.FS:NewModule("Boom", "AceEvent-3.0"); W.boot()
      translate(ns)
      ns.FS:SafeCall("Boom", function() error("x") end)
      assert.equal("T:FabricationStation: ", plain(W.printed[1]):sub(1, #"T:FabricationStation: "))
    end)
  end)

  describe("SelfCheck", function()
    it("starts the panel's check line with the translated sentence", function()
      local ns, _, world = make_world({ last = "Modules/SelfCheck.lua", calibrate = { ["Main-Realm"] = { 9001 } } })
      translate(ns)
      local lines = {}
      local panel = ns.FS:NewModule("ProfessionPanel", "AceEvent-3.0")
      function panel:SetCheckLine(text, tone) lines[#lines + 1] = { text, tone } end
      panel:Enable()
      -- The first mismatch fixture of tests/recipes/selfcheck_spec.lua: the game's quality and threshold differ.
      world.live[9001] = function() return { baseSkill = 480, bonusSkill = 20, baseDifficulty = 700, bonusDifficulty = 0,
        craftingQuality = 2, lowerSkillThreshold = 700, upperSkillTreshold = 700, concentrationCost = 0,
        craftingDataID = 2588, bonusStats = {} } end
      world.openProfession(2906); world.liveReagents({})
      assert.equal(2, #ns.FS:GetModule("SelfCheck"):Run(9001))
      assert.equal(1, #lines)
      assert.equal("T:Math check: ", plain(lines[1][1]):sub(1, #"T:Math check: "))
      assert.equal("warn", lines[1][2])
    end)
  end)

  describe("GuildOptions", function()
    it("starts the /fs guild status line with the translated sentence", function()
      local ns, W, p4 = boot_phase4({ "Modules/Social/Util.lua", "Modules/Social/Gate.lua", "Modules/Social/Codec.lua",
        "Modules/Social/Protocol.lua", "Modules/Social/ProfileStore.lua", "Modules/Social/Comm.lua",
        "Modules/Social/ItemIndex.lua", "Modules/Social/RecipeIndex.lua", "Modules/Social/Guild.lua",
        "Modules/Social/GuildNative.lua", "Modules/Social/GuildDirectory.lua", "Modules/Social/GuildOptions.lua" })
      p4.fake_module(ns, "Scanner", { GetCharacters = function() return {} end })
      p4.guild.key = { "G", "Realm" }
      W.fire("PLAYER_ENTERING_WORLD", true, false)
      translate(ns)
      ns.FS:HandleSlash("guild")
      -- The chat prefix is the addon's name and stays as it is; the sentence after it is the key.
      assert.equal("FabricationStation: T:guild ", plain(W.printed[1]):sub(1, #"FabricationStation: T:guild "))
    end)
  end)

  describe("ChatToast", function()
    it("starts the whisper text with the translated template", function()
      local ns = boot_phase4({ "Modules/Social/Util.lua", "Modules/Social/Gate.lua", "Modules/Social/ChatMatcher.lua",
        "Modules/Social/ChatScan.lua", "UI/Util.lua", "UI/ChatToast.lua" })
      translate(ns)
      local match = { sender = "Buyer-Realm", kind = "trade", text = "LF crafter", lineID = 1,
        recipes = { { recipeID = 100, itemID = 212345, name = "Everforged Gloves" } } }
      local text = ns.UI.ChatToast:WhisperText(match)
      assert.equal("T:Hi! I can craft ", text:sub(1, #"T:Hi! I can craft "))
      assert.truthy(text:find("Everforged Gloves", 1, true))
    end)
  end)

  describe("ProfessionPanel", function()
    it("starts the quality and concentration lines with the translated sentence", function()
      local ns = make_world({ last = "UI/ProfessionPanel.lua" })
      translate(ns)
      -- The result of tests/ui/profession_panel_spec.lua, without a live prediction.
      local result = { expectedQuality = 2, perQuality = { [1] = { reagentCost = 3000, profit = 71895 },
        [2] = { reagentCost = 4800, profit = 120010 } }, reagentCost = 4800, expectedSale = 124450,
        multicraftValue = 29450, resourcefulnessValue = 360, ingenuityValue = 31.4, concentrationCost = 314,
        goldPerConcentration = 6, profit = 120010, priceAgeDays = 1, flags = {} }
      local model = ns.UI.ProfessionPanel.BuildModel(result, nil)
      assert.equal("T:", plain(model.qualityText):sub(1, 2), model.qualityText)
      assert.equal("T:", plain(model.concentrationText):sub(1, 2), model.concentrationText)
    end)
  end)

  describe("Dashboard", function()
    it("starts the queue widget with the formatted translated count line", function()
      local ns, _, world = make_world({ last = "UI/Tabs/Dashboard.lua" })
      translate(ns)
      local D = ns.FS:GetModule("Dashboard")
      world.fakeEvaluate(9001, { allocation = { { slotIndex = 1, itemID = 1001, quantity = 2 } }, reagentCost = 900,
        expectedYield = 1, profit = 5000, flags = {} })
      local Q = ns.FS:GetModule("Queue")
      Q:Add({ recipeID = 9001, quantity = 3, charKey = "Main-Realm" })
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Alt-Realm" })
      D:BuildAll(CreateFrame("Frame")); D:RefreshAll()
      local frame = D:GetBuiltFrames().queueSummary
      assert.equal("T:2 entries, 4 crafts", plain(frame.lines[1]:GetText()))
    end)
  end)

  describe("Recipes", function()
    it("starts the status after queueing a row with the translated sentence", function()
      local ns = make_world({ last = "UI/Tabs/Recipes.lua" })
      translate(ns)
      local Recipes = ns.FS:GetModule("Recipes")
      Recipes.GetRanked = function()
        return { { recipeID = 9001, charKey = "Alt-Realm", expectedQuality = 2, profit = 5, flags = {} } }
      end
      Recipes.IsScanning = function() return false end
      ns.FS:GetModule("MainWindow"):Show("recipes")
      local view = ns.FS:GetModule("RecipesTab"):GetView()
      local button = view.pool[1].cells[9]
      button:GetScript("OnClick")(button)
      assert.equal(1, #ns.FS:GetModule("Queue"):GetEntries())
      assert.equal("T:Queued ", plain(view.status:GetText()):sub(1, #"T:Queued "))
    end)
  end)

  -- The quality tier marker is one key everywhere; "Q" .. n joins are gone.
  describe("the Q%d tier marker", function()
    it("is read through the key in the Queue tab quality cell", function()
      local ns = make_world({ last = "UI/Tabs/Queue.lua" })
      translate(ns)
      local T = ns.UI.QueueTab
      local row = T.BuildRows({ { id = 1, recipeID = 9001, quantity = 1, charKey = "A-B", targetQuality = 2 } }, {}, {}, {}, 0)[1]
      assert.equal("T:Q%d", ns.L["Q%d"])
      assert.equal("T:Q2", plain(T.CellTexts(row).quality))
      row.targetQuality = nil
      assert.equal("--", T.CellTexts(row).quality)
    end)

    it("is read through the key in the Profession panel's quality rows", function()
      local ns, W, world = make_world({ last = "UI/ProfessionPanel.lua" })
      local form = fake_professions_frame()
      W.fire("ADDON_LOADED", "Blizzard_Professions")
      translate(ns)
      world.fakeEvaluate(9001, { expectedQuality = 2, flags = {}, perQuality = {
        [1] = { reagentCost = 3000, profit = 1, allocation = { { slotIndex = 1, itemID = 1001, quantity = 10 } } },
        [2] = { reagentCost = 4800, profit = 2, allocation = { { slotIndex = 1, itemID = 1002, quantity = 10 } } } } })
      form.selectRecipe({ recipeID = 9001 })
      local view = ns.FS:GetModule("ProfessionPanel"):GetView()
      assert.equal("T:Q1", plain(view.qualityRows[1].label:GetText()))
      assert.equal("T:Q2", plain(view.qualityRows[2].label:GetText()))
    end)
  end)

  describe("the context comments", function()
    -- The ambiguous keys: a translator cannot tell from the English alone what each one stands for.
    local CONTEXT = {
      ["Q%d"] = "-- quality tier marker, e.g. Q3",
      ["ready"] = "-- Characters tab: a cooldown or weekly knowledge that can be done now",
      ["points"] = "-- Characters tab: the fallback name of a profession's knowledge currency",
      ["Order: %s"] = "-- customer history tooltip: the order type (Public, Guild, Personal, NPC)",
      ["Total: %s"] = "-- holdings total: alts dashboard widget, Characters tab reagent tooltip",
      ["Skill %s"] = "-- stands in for a profession name the client has not given yet (%s = skill line ID)",
      ["none"] = "-- no value: concentration cost in the profession panel, the best score in the orders widget",
      ["%s (%s)"] = "-- a value and its qualifiers in brackets: holdings total (where), craft cost (character, notes), "
        .. "recipe (character), profit (partial)",
      ["%s - last scan %s ago"] = "-- setup guide scan list: character name, then how long ago",
    }

    it("comments every ambiguous key", function()
      local f = assert(io.open("Locales/enUS.lua", "r"))
      local lines = {}
      for line in f:lines() do lines[#lines + 1] = line end
      f:close()
      for key, comment in pairs(CONTEXT) do
        local head = 'L["' .. key .. '"] = true'
        local found
        for _, line in ipairs(lines) do
          if line:sub(1, #head) == head then found = line; break end
        end
        assert.truthy(found, key)
        local tail = found:sub(#head + 1)
        assert.equal(comment, tail:match("%-%-.*$"), key)
        assert.truthy(tail:match("^%s+%-%-"), key)   -- a trailing comment, on the key's own line
      end
    end)
  end)
end)
