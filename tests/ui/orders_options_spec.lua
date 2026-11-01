local P2 = require("tests.helpers.phase2")

describe("Orders options", function()
  local ns, W, g

  local function boot(stubs)
    ns, W = P2.boot(stubs)
    P2.load(ns, { "Modules/Customers.lua", "Data/OrderRewards.lua", "Modules/Orders.lua", "Modules/Ledger.lua",
      "UI/OrdersPanel.lua", "UI/OrderAlert.lua", "UI/OrdersOptions.lua" })
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

  describe("while the saved data is from a newer version", function()
    before_each(function()
      ns.FS.db.global.settings.orders = nil
      ns.FS.db.global.settings.ledger = nil
      ns.FS.db.global.settings.alerts = nil
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
      assert.equal(17, set)   -- scoring: 3 gold + minutes + claim score + 5 risk toggles; alerts: 2 toggles, sound,
                              -- toast seconds; ledger: 2 ranges; panel: the row-icons toggle
      local settings = ns.FS.db.global.settings
      assert.is_nil(settings.orders); assert.is_nil(settings.ledger); assert.is_nil(settings.alerts)
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
