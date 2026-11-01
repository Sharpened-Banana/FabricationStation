local P2 = require("tests.helpers.phase2")

describe("Orders options", function()
  local ns, W, g

  local function boot(stubs)
    ns, W = P2.boot(stubs)
    P2.load(ns, { "Modules/Customers.lua", "Data/OrderRewards.lua", "Modules/Orders.lua", "Modules/Ledger.lua",
      "Modules/SaleLog.lua", "UI/OrdersPanel.lua", "UI/OrderAlert.lua", "UI/OrdersOptions.lua" })
    g = ns.UI.OrdersOptions.Build()
  end

  before_each(function() boot() end)

  local function orders() return ns.FS:GetModule("Orders") end

  it("edits copper settings in gold", function()
    local opt = g.args.scoring.args.lowTipMargin
    assert.equal(10, opt.get()); opt.set(nil, 12.5)
    assert.equal(125000, ns.FS:GetModule("Orders"):Settings().lowTipMargin)
  end)

  it("toggles a crafting-orders addition module through 1a's SetModuleEnabled", function()
    local opt = g.args.panel.args.rows
    assert.is_true(opt.get()); opt.set(nil, false)
    assert.is_false(ns.FS.db.global.settings.modules.OrdersRowAddons)
    assert.is_false(ns.FS:GetModule("OrdersRowAddons"):IsEnabled()); assert.is_false(opt.get())
  end)

  it("registers the group and is listed beside 1a's module toggles", function()
    local args = ns.FS:GetOptionsTable().args
    assert.equal("Orders & Ledger", args.orders.name)
    assert.is_truthy(args.modules.args.OrdersRowAddons); assert.is_truthy(args.modules.args.Ledger)
  end)

  it("is a group at order 40 with the four subgroups, registered as \"Orders & Ledger\" beside General and Modules", function()
    assert.equal("group", g.type)
    assert.equal(40, g.order)
    for _, key in ipairs({ "scoring", "panel", "alerts", "ledger" }) do
      assert.equal("group", g.args[key].type, key)
    end
    local args = ns.FS:GetOptionsTable().args
    for _, key in ipairs({ "general", "modules" }) do assert.is_truthy(args[key], key) end
    assert.equal("Orders & Ledger", args.orders.name)
    assert.equal("General", args.general.name)
  end)

  it("stores gold as whole copper, rounding away float error", function()
    local s = g.args.scoring.args
    s.knowledgePointValue.set(nil, 0.29)
    assert.equal(2900, orders():Settings().knowledgePointValue)
    s.moxieValue.set(nil, 3)
    assert.equal(30000, orders():Settings().moxieValue)
    assert.equal(3, s.moxieValue.get())
    s.claimMinScore.set(nil, -5)
    assert.equal(-50000, orders():Settings().claimMinScore)
    assert.equal(-5, s.claimMinScore.get())
    assert.equal(0.29, s.knowledgePointValue.get())
    assert.equal("range", s.lowTipMargin.type)
    assert.is_true(s.lowTipMargin.min >= 0)
  end)

  it("ignores a value that is not a number", function()
    local s = g.args.scoring.args
    s.lowTipMargin.set(nil, "abc")
    assert.equal(100000, orders():Settings().lowTipMargin)
    s.lowTipMargin.set(nil, 0 / 0)
    assert.equal(100000, orders():Settings().lowTipMargin)
  end)

  it("edits the expiring-soon window in minutes", function()
    local opt = g.args.scoring.args.expiringSoonSeconds
    assert.equal(60, opt.get())
    opt.set(nil, 90)
    assert.equal(5400, orders():Settings().expiringSoonSeconds)
    assert.equal(90, opt.get())
  end)

  it("has one claim-blocking toggle per risk", function()
    local s = g.args.scoring.args
    for key in pairs(orders().SETTINGS_DEFAULTS.claimBlockingRisks) do
      local opt = s["block_" .. key]
      assert.is_truthy(opt, key)
      assert.equal("toggle", opt.type)
      assert.is_true(opt.get())
    end
    s.block_expiringSoon.set(nil, false)
    assert.is_false(orders():Settings().claimBlockingRisks.expiringSoon)
    assert.is_false(s.block_expiringSoon.get())
    assert.is_true(orders():Settings().claimBlockingRisks.noMatsLowTip)
  end)

  it("rescores the orders once, 0.5 s after the last of several scoring changes (a slider drag)", function()
    local O = orders()
    local calls = 0
    local real = O.Rescore
    O.Rescore = function(self) calls = calls + 1; return real(self) end
    g.args.scoring.args.lowTipMargin.set(nil, 20)
    g.args.scoring.args.lowTipMargin.set(nil, 21)
    g.args.scoring.args.block_noConcentration.set(nil, false)
    assert.equal(0, calls)
    W.advance(0.5)
    assert.equal(1, calls)
    ns.FS:SendMessage("FS_PRICES_CHANGED"); g.args.scoring.args.lowTipMargin.set(nil, 22)   -- shares Orders' key
    W.advance(0.5)
    assert.equal(2, calls)
  end)

  it("does not rescore while the Orders module is off, at the change or when the rescore is due", function()
    local O = orders()
    local calls = 0
    O.Rescore = function() calls = calls + 1 end
    ns.FS:SetModuleEnabled("Orders", false)
    g.args.scoring.args.lowTipMargin.set(nil, 20)
    W.advance(1)
    assert.equal(0, calls)
    assert.equal(200000, O:Settings().lowTipMargin)
    ns.FS:SetModuleEnabled("Orders", true)
    g.args.scoring.args.lowTipMargin.set(nil, 21)
    O.IsEnabled = function() return false end   -- off by the time the rescore is due
    W.advance(1)
    assert.equal(0, calls)
  end)

  it("a failing rescore turns off only Orders instead of escaping into the dialog", function()
    local O = orders()
    O.Rescore = function() error("boom") end
    assert.has_no.errors(function() g.args.scoring.args.lowTipMargin.set(nil, 20) end)
    assert.has_no.errors(function() W.advance(0.5) end)
    assert.is_false(O:IsEnabled())
    assert.is_truthy(ns.FS.failedModules.Orders)
  end)

  it("toggles each crafting-orders addition module", function()
    local p = g.args.panel.args
    for key, name in pairs({ rows = "OrdersRowAddons", sidePanel = "OrdersSidePanel",
      orderViewWarning = "OrderViewWarning" }) do
      assert.equal("toggle", p[key].type, key)
      assert.is_true(p[key].get(), key)
      p[key].set(nil, false)
      assert.is_false(ns.FS.db.global.settings.modules[name], key)
      assert.is_false(ns.FS:GetModule(name):IsEnabled(), key)
      p[key].set(nil, true)
      assert.is_true(ns.FS.db.global.settings.modules[name], key)
      assert.is_true(ns.FS:GetModule(name):IsEnabled(), key)
      assert.is_true(p[key].get(), key)
    end
  end)

  it("turning an addition back on clears its failure", function()
    ns.FS.failedModules.OrdersSidePanel = "boom"
    ns.FS:GetModule("OrdersSidePanel"):Disable()
    assert.is_false(g.args.panel.args.sidePanel.get())
    g.args.panel.args.sidePanel.set(nil, true)
    assert.is_nil(ns.FS.failedModules.OrdersSidePanel)
    assert.is_true(ns.FS:GetModule("OrdersSidePanel"):IsEnabled())
  end)

  it("edits the alert settings", function()
    local a = g.args.alerts.args
    local alerts = ns.FS:GetModule("OrderAlert")
    assert.is_true(a.personalOrderSound.get()); a.personalOrderSound.set(nil, false)
    assert.is_false(alerts:Settings().personalOrderSound)
    assert.is_true(a.personalOrderToast.get()); a.personalOrderToast.set(nil, false)
    assert.is_false(alerts:Settings().personalOrderToast)
    assert.equal(8, a.toastSeconds.get()); a.toastSeconds.set(nil, 15)
    assert.equal(15, alerts:Settings().toastSeconds)
    assert.equal(1, a.toastSeconds.min); assert.equal(60, a.toastSeconds.max)
    a.toastSeconds.set(nil, 500)
    assert.equal(60, alerts:Settings().toastSeconds)
  end)

  it("offers only the alert sounds the client has", function()
    boot({ SOUNDKIT = { RAID_WARNING = 8959, READY_CHECK = 8960 } })
    local opt = g.args.alerts.args.sound
    assert.equal("select", opt.type)
    local values = opt.values()
    assert.is_truthy(values.RAID_WARNING); assert.is_truthy(values.READY_CHECK)
    assert.is_nil(values.UI_PROFESSIONS_NEW_RECIPE_LEARNED)
    assert.equal("RAID_WARNING", opt.get())
    opt.set(nil, "READY_CHECK")
    assert.equal("READY_CHECK", ns.FS:GetModule("OrderAlert"):Settings().sound)
    assert.equal("READY_CHECK", opt.get())
    opt.set(nil, "NOT_A_SOUND")
    assert.equal("READY_CHECK", ns.FS:GetModule("OrderAlert"):Settings().sound)
    ns.FS:GetModule("OrderAlert"):Settings().sound = "GONE"
    assert.equal("RAID_WARNING", opt.get())
  end)

  it("edits the ledger settings within their ranges", function()
    local l = g.args.ledger.args
    local ledger = ns.FS:GetModule("Ledger")
    assert.equal(3, l.benchmarkMinSamples.get())
    assert.equal(1, l.benchmarkMinSamples.min); assert.equal(20, l.benchmarkMinSamples.max)
    l.benchmarkMinSamples.set(nil, 5)
    assert.equal(5, ledger:Settings().benchmarkMinSamples)
    assert.equal(365, l.keepDays.get())
    assert.equal(30, l.keepDays.min); assert.equal(1095, l.keepDays.max)
    l.keepDays.set(nil, 10)
    assert.equal(30, ledger:Settings().keepDays)
    l.keepDays.set(nil, 400.6)
    assert.equal(401, ledger:Settings().keepDays)
  end)

  it("clamps the window to 7..365 days", function()
    local l = g.args.ledger.args
    local saleLog = ns.FS:GetModule("SaleLog")
    assert.same({ "header", "Sale log" }, { l.saleLogHeader.type, l.saleLogHeader.name })
    assert.equal("Sale history window (days)", l.saleLogWindow.name)
    assert.same({ 7, 365, 30 }, { l.saleLogWindow.min, l.saleLogWindow.max, l.saleLogWindow.get() })
    l.saleLogWindow.set(nil, 3)
    assert.equal(7, saleLog:Settings().windowDays)
    l.saleLogWindow.set(nil, 1000)
    assert.equal(365, saleLog:Settings().windowDays)
    l.saleLogWindow.set(nil, 45.4)
    assert.equal(45, saleLog:Settings().windowDays)
    assert.equal(45, l.saleLogWindow.get())
    l.saleLogWindow.set(nil, 0 / 0)
    l.saleLogWindow.set(nil, "x")
    assert.equal(45, saleLog:Settings().windowDays)
  end)

  it("toggles the sale lines in item tooltips", function()
    local opt = g.args.ledger.args.saleLogTooltip
    assert.equal("Show your sales in item tooltips", opt.name)
    assert.is_true(opt.get())
    opt.set(nil, false)
    assert.is_false(ns.FS:GetModule("SaleLog"):Settings().tooltip)
    assert.is_false(opt.get())
  end)

  it("tells the Sale log views to refresh after a window change", function()
    local saleLog = ns.FS:GetModule("SaleLog")
    local sent = {}
    saleLog.SendMessage = function(_, msg) sent[#sent + 1] = msg end
    g.args.ledger.args.saleLogWindow.set(nil, 60)
    assert.same({ "FS_SALELOG_CHANGED" }, sent)
  end)

  it("tells the Ledger views to refresh after a ledger change, and never prunes", function()
    local ledger = ns.FS:GetModule("Ledger")
    local sent = {}
    ledger.SendMessage = function(_, msg) sent[#sent + 1] = msg end
    local pruned = 0
    ledger.Prune = function() pruned = pruned + 1 end
    g.args.ledger.args.keepDays.set(nil, 30)
    assert.same({ "FS_LEDGER_CHANGED" }, sent)
    assert.equal(0, pruned)
  end)

  describe("reward limits and unknown rewards", function()
    local function scoring() return g.args.scoring.args end
    local function unknown() return scoring().unknownRewards end

    local function seen(counts)
      ns.FS.db.global.ordersUnknownRewards = {}
      for key, count in pairs(counts) do ns.FS.db.global.ordersUnknownRewards[key] = { count = count, lastSeen = 1 } end
      ns.UI.OrdersOptions.RefreshUnknown()
    end

    it("stores a limit in copper, and no limit for an empty input", function()
      local limit = scoring().knowledgeLimit
      assert.equal("input", limit.type); assert.equal("", limit.get())
      limit.set(nil, "50")
      assert.equal(500000, orders():Settings().rewardCostLimits.knowledge); assert.equal("50", limit.get())
      limit.set(nil, "1g 50s")
      assert.equal(15000, orders():Settings().rewardCostLimits.knowledge)
      scoring().moxieLimit.set(nil, "2.5")
      assert.equal(25000, orders():Settings().rewardCostLimits.moxie)
      limit.set(nil, "")
      assert.is_nil(orders():Settings().rewardCostLimits.knowledge)
      assert.equal(25000, orders():Settings().rewardCostLimits.moxie); assert.equal("", limit.get())
    end)
    it("shows a limit as plain text that ParseMoney reads back, never coin markup", function()
      _G.GetMoneyString = function(copper) return "|TInterface\\MoneyFrame\\UI-GoldIcon:0|t " .. copper .. "|cffffd700g|r" end
      local limit = scoring().knowledgeLimit
      limit.set(nil, "2g 50s")
      assert.equal(25000, orders():Settings().rewardCostLimits.knowledge)
      local text = limit.get()
      assert.equal("2g 50s", text)
      assert.is_nil(text:find("|T", 1, true)); assert.is_nil(text:find("|c", 1, true))
      assert.equal(25000, ns.UI.ParseMoney(text))
      scoring().moxieLimit.set(nil, "0.5")
      assert.equal("50s", scoring().moxieLimit.get())
      orders():Settings().rewardCostLimits.moxie = 12345
      assert.equal("1g 23s 45c", scoring().moxieLimit.get())
      limit.set(nil, text)   -- committing the shown text again keeps the value
      assert.equal(25000, orders():Settings().rewardCostLimits.knowledge)
      _G.GetMoneyString = nil
    end)
    it("shows an unknown reward's override as plain text too", function()
      _G.GetMoneyString = function() return "|TIcon|t" end
      ns.FS.db.global.ordersUnknownRewards = { ["item:5"] = { count = 1 } }
      ns.UI.OrdersOptions.RefreshUnknown()
      local opt = unknown().args["item:5"]
      opt.set(nil, "1.5")
      assert.equal("1g 50s", opt.get())
      _G.GetMoneyString = nil
    end)
    it("says \"seen on 1 order\" for a single order", function()
      seen({ ["item:1"] = 1, ["item:2"] = 2 })
      assert.equal("seen on 1 order", unknown().args["item:1"].desc)
      assert.equal("seen on 2 orders", unknown().args["item:2"].desc)
    end)
    it("redraws the options only when the unknown list changed", function()
      seen({ ["item:1"] = 1 })
      local before = W.config.notified
      ns.FS:SendMessage("FS_ORDERS_CHANGED")
      assert.equal(0, W.config.notified - before)
      ns.FS.db.global.ordersUnknownRewards["item:1"].count = 2
      ns.FS:SendMessage("FS_ORDERS_CHANGED")
      assert.equal(1, W.config.notified - before)
      ns.FS.db.global.ordersUnknownRewards["item:9"] = { count = 1 }
      ns.FS:SendMessage("FS_ORDERS_CHANGED")
      assert.equal(2, W.config.notified - before)
    end)
    it("says the unknown rewards sentence once", function()
      assert.is_truthy(scoring().unknownNote)
      assert.is_nil(unknown().desc)
    end)
    it("keeps the limit when the input is not money", function()
      local limit = scoring().knowledgeLimit
      limit.set(nil, "50"); limit.set(nil, "lots"); limit.set(nil, "-5")
      assert.equal(500000, orders():Settings().rewardCostLimits.knowledge)
    end)
    it("rescores once after a limit changes", function()
      local calls = 0
      local real = orders().Rescore
      orders().Rescore = function(self) calls = calls + 1; return real(self) end
      scoring().knowledgeLimit.set(nil, "50"); scoring().moxieLimit.set(nil, "1")
      assert.equal(0, calls); W.advance(0.5); assert.equal(1, calls)
    end)

    it("lists the unknown rewards, most seen first, at most 20, named from the game", function()
      local counts = {}
      for i = 1, 25 do counts["item:" .. i] = i end
      counts["currency:900"] = 30
      counts["item:50"] = 30
      _G.C_Item.GetItemNameByID = function(id) return id == 25 and "Odd Trinket" or nil end
      _G.C_CurrencyInfo.GetCurrencyInfo = function(id) return id == 900 and { name = "Odd Coin" } or nil end
      seen(counts)
      local args = unknown().args
      local n = 0
      for _ in pairs(args) do n = n + 1 end
      assert.equal(20, n)
      local ordered = {}
      for key, opt in pairs(args) do ordered[#ordered + 1] = { key = key, order = opt.order } end
      table.sort(ordered, function(a, b) return a.order < b.order end)
      assert.same({ "currency:900", "item:50", "item:25", "item:24" },
        { ordered[1].key, ordered[2].key, ordered[3].key, ordered[4].key })
      assert.equal("Odd Coin", args["currency:900"].name()); assert.equal("Odd Trinket", args["item:25"].name())
      assert.equal("item:24", args["item:24"].name())
      assert.equal("seen on 25 orders", args["item:25"].desc)
      assert.is_nil(args["item:1"])
    end)
    it("sets and clears a reward override from the unknown rewards group", function()
      seen({ ["item:88888"] = 3 })
      local opt = unknown().args["item:88888"]
      assert.equal("", opt.get())
      opt.set(nil, "5")
      assert.equal(50000, orders():Settings().rewardOverrides["item:88888"]); assert.equal("5", opt.get())
      opt.set(nil, "")
      assert.is_nil(orders():Settings().rewardOverrides["item:88888"]); assert.equal("", opt.get())
      opt.set(nil, "5"); opt.set(nil, "junk")
      assert.equal(50000, orders():Settings().rewardOverrides["item:88888"])
    end)
    it("scores an order again after an override is set", function()
      seen({ ["item:88888"] = 3 })
      local calls = 0
      local real = orders().Rescore
      orders().Rescore = function(self) calls = calls + 1; return real(self) end
      unknown().args["item:88888"].set(nil, "5")
      W.advance(0.5); assert.equal(1, calls)
    end)
    it("has a description and an empty list before any reward was seen", function()
      ns.FS.db.global.ordersUnknownRewards = nil
      ns.UI.OrdersOptions.RefreshUnknown()
      assert.same({}, unknown().args)
      assert.equal("Unknown rewards", unknown().name)
      assert.equal("Rewards FabricationStation could not value. Give one a value and orders with it are scored.",
        scoring().unknownNote.name)
    end)
    it("shows the new list when an order changes", function()
      seen({})
      ns.FS.db.global.ordersUnknownRewards["item:77"] = { count = 1 }
      ns.FS:SendMessage("FS_ORDERS_CHANGED")
      assert.is_truthy(unknown().args["item:77"])
    end)

    describe("while the saved data is from a newer version", function()
      before_each(function()
        seen({ ["item:88888"] = 3 })
        ns.FS.db.global.settings.orders = nil
        ns.FS.dbIsNewer = true
      end)
      after_each(function() ns.FS.dbIsNewer = nil end)

      it("disables the limits and the override inputs", function()
        assert.is_true(scoring().knowledgeLimit.disabled()); assert.is_true(scoring().moxieLimit.disabled())
        assert.is_true(unknown().args["item:88888"].disabled())
        ns.FS.dbIsNewer = nil
        assert.is_false(scoring().knowledgeLimit.disabled()); assert.is_false(unknown().args["item:88888"].disabled())
      end)
      it("leaves db.global untouched when they are set", function()
        local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
        scoring().knowledgeLimit.set(nil, "50"); scoring().moxieLimit.set(nil, "5")
        unknown().args["item:88888"].set(nil, "5")
        assert.same(before, ns.FS.db.global)
        assert.is_nil(ns.FS.db.global.settings.orders)
      end)
    end)
  end)

  describe("while the saved data is from a newer version", function()
    before_each(function()
      ns.FS.db.global.settings.orders = nil
      ns.FS.db.global.settings.ledger = nil
      ns.FS.db.global.settings.alerts = nil
      ns.FS.db.global.settings.saleLog = nil
      ns.FS.dbIsNewer = true
    end)
    after_each(function() ns.FS.dbIsNewer = nil end)

    it("disables the editable options so the user sees why", function()
      for _, sub in ipairs({ "scoring", "alerts", "ledger" }) do
        for key, opt in pairs(g.args[sub].args) do
          if opt.type ~= "header" and opt.type ~= "description" then
            assert.is_function(opt.disabled, sub .. "." .. key)
            assert.is_true(opt.disabled(), sub .. "." .. key)
          end
        end
      end
      ns.FS.dbIsNewer = nil
      assert.is_false(g.args.scoring.args.lowTipMargin.disabled())
    end)

    it("every editable option's setter (ranges, toggles, the sound select) leaves db.global untouched", function()
      local set = 0
      for _, sub in ipairs({ "scoring", "alerts", "ledger" }) do
        for key, opt in pairs(g.args[sub].args) do
          if opt.type == "range" then
            opt.set(nil, opt.max); set = set + 1
          elseif opt.type == "toggle" then
            opt.set(nil, not opt.get()); set = set + 1
          elseif opt.type == "select" then
            local values = type(opt.values) == "function" and opt.values() or opt.values
            local value = next(values)
            assert.is_not_nil(value, sub .. "." .. key)
            opt.set(nil, value); set = set + 1
          end
        end
      end
      -- The row-icons toggle (panel.rowIcons) is the one editable option outside those groups. The group's other
      -- options are module toggles, which turn modules on and off, so only this one is called.
      g.args.panel.args.rowIcons.set(nil, not g.args.panel.args.rowIcons.get()); set = set + 1
      assert.equal(21, set)   -- scoring: 3 gold + minutes + claim score + 7 risk toggles; alerts: 2 toggles, sound,
                              -- toast seconds; ledger: 2 ranges, the sale window and tooltip toggle; panel: the
                              -- row-icons toggle
      local settings = ns.FS.db.global.settings
      assert.is_nil(settings.orders); assert.is_nil(settings.ledger); assert.is_nil(settings.alerts)
      assert.is_nil(settings.saleLog)
    end)

    it("setting a value leaves db.global untouched", function()
      g.args.scoring.args.lowTipMargin.set(nil, 12.5)
      g.args.scoring.args.block_expiringSoon.set(nil, false)
      g.args.alerts.args.personalOrderSound.set(nil, false)
      g.args.ledger.args.keepDays.set(nil, 90)
      local settings = ns.FS.db.global.settings
      assert.is_nil(settings.orders); assert.is_nil(settings.ledger); assert.is_nil(settings.alerts)
      -- the session-only copy still takes it
      assert.equal(125000, orders():Settings().lowTipMargin)
      assert.equal(12.5, g.args.scoring.args.lowTipMargin.get())
    end)
  end)
end)
