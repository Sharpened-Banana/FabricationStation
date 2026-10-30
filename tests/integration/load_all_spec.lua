describe("whole addon", function()
  local W, ns
  before_each(function() W = install_wow_stubs(); ns = load_addon({}); W.boot() end)
  it("enables every module without logging errors", function()
    for _, name in ipairs({ "Scanner", "Prices", "Diagnostics", "Recipes", "MainWindow", "SettingsTab", "Launcher" }) do
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
    for _, k in ipairs({ "general", "prices", "crafting", "modules", "diagnostics" }) do assert.is_truthy(args[k], k) end
  end)
end)
