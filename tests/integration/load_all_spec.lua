describe("whole addon", function()
  local W, ns
  before_each(function() W = install_wow_stubs(); ns = load_addon({}); W.boot() end)
  it("enables every module without logging errors", function()
    for _, name in ipairs({ "Scanner", "Prices", "Diagnostics", "Recipes", "MainWindow", "SettingsTab", "Launcher",
      -- phase 2
      "Customers", "Orders", "Ledger", "OrdersRowAddons", "OrdersSidePanel", "OrderViewWarning", "OrderAlert",
      "OrdersTab", "CustomersTab", "LedgerTab", "OrdersWidgets",
      -- phase 3
      "Alts", "AltsTooltips", "Planner", "CharactersTab", "PlannerTab", "AltsWidgets",
      -- phase 4
      "Guild", "GuildTab", "ChatScan", "ChatToasts", "Onboarding",
      -- phase 7
      "ReadyAlerts", "SaleLog", "FeatureLines" }) do
      assert.is_true(ns.FS:GetModule(name):IsEnabled(), name)
    end
    assert.same({}, ns.FS.db.global.diagnostics.errors)
  end)
  it("opens the window and the settings tab from slash commands", function()
    ns.FS:HandleSlash(""); assert.is_true(ns.FS:GetModule("MainWindow"):IsShown())
    ns.FS:HandleSlash("settings"); assert.equals("settings", ns.FS:GetModule("MainWindow"):GetSelectedTab())
  end)
  it("registers the slash aliases", function() assert.is_truthy(W.slash.fs); assert.is_truthy(W.slash.fabstation) end)
  it("exposes the option groups", function()
    local args = ns.FS:GetOptionsTable().args
    for _, k in ipairs({ "general", "prices", "crafting", "orders", "alts", "planner", "guild", "chatScan", "modules", "diagnostics" }) do
      assert.is_truthy(args[k], k)
    end
  end)
  it("boots the whole TOC with every module on and none stopped", function()
    local count = 0
    for name, module in ns.FS:IterateModules() do
      count = count + 1
      assert.is_true(module:IsEnabled(), name)
    end
    assert.is_true(count >= 27)
    assert.same({}, ns.FS.failedModules)
    assert.same({}, ns.FS.db.global.diagnostics.errors)
  end)
  it("runs the first loading screen's delayed work (Planner's cap warning) without errors", function()
    W.fire("PLAYER_ENTERING_WORLD")
    W.advance(15)
    assert.is_true(ns.FS:GetModule("Planner"):IsEnabled())
    assert.same({}, ns.FS.failedModules)
    assert.same({}, ns.FS.db.global.diagnostics.errors)
  end)
  it("opens the setup guide five seconds after the first loading screen on a fresh install, without errors", function()
    local wizard = ns.UI.OnboardingWizard
    assert.is_false(wizard:IsShown())
    W.fire("PLAYER_ENTERING_WORLD", true, false)
    W.advance(4); assert.is_false(wizard:IsShown())
    W.advance(2); assert.is_true(wizard:IsShown())
    for i = 1, 7 do wizard:ShowStep(i) end
    wizard:Close()
    assert.is_false(ns.FS:GetModule("Onboarding"):ShouldShow())
    assert.same({}, ns.FS.failedModules)
    assert.same({}, ns.FS.db.global.diagnostics.errors)
  end)
end)
