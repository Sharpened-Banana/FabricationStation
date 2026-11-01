describe("FabricationStation.toc", function()
  local toc = read_toc("FabricationStation.toc")
  it("pins the retail Interface number", function() assert.equals("120105", toc.meta.Interface) end)
  it("declares the SavedVariables", function() assert.equals("FabricationStationDB", toc.meta.SavedVariables) end)
  it("requires Auctionator", function()
    assert.equals("Auctionator", toc.meta.Dependencies)
    assert.is_nil(toc.meta.OptionalDeps)
  end)
  it("declares the MIT licence and the packager version token", function()
    assert.equals("MIT", toc.meta["X-License"])
    assert.equals("@project-version@", toc.meta.Version)
  end)
  it("loads embeds.xml first", function() assert.equals("embeds.xml", toc.files[1]) end)
  -- Phase 4 Task 2: the locale files come right after the libraries and before the first Core file, so every
  -- later file (in game) finds the real ns.L.
  it("loads Locales/Locales.xml right after embeds.xml, before Core/Util.lua", function()
    assert.equals("Locales/Locales.xml", toc.files[2])
    assert.equals("Core/Util.lua", toc.files[3])
  end)
  it("lists only files that exist", function()
    for _, f in ipairs(toc.files) do
      assert.is_truthy(io.open(f, "r"), "missing " .. f)
    end
  end)
  it("lists every addon .lua file under Core, Data, Math, Modules and UI", function()
    local listed = {}
    for _, f in ipairs(toc.files) do listed[f] = true end
    local found = io.popen("find Core Data Math Modules UI -name '*.lua' | sort")
    local count = 0
    for path in found:lines() do
      count = count + 1
      assert.is_truthy(listed[path], "not in the TOC: " .. path)
    end
    found:close()
    assert.is_true(count > 0)
  end)
  it("loads the phase-2 UI additions in order, the options group last", function()
    local at = {}
    for i, f in ipairs(toc.files) do at[f] = i end
    local order = { "UI/Tooltips.lua", "UI/OrdersPanel.lua", "UI/OrderAlert.lua", "UI/OrdersWidgets.lua",
      "UI/OrdersOptions.lua" }
    for i = 2, #order do
      assert.is_truthy(at[order[i]], order[i])
      assert.is_true(at[order[i - 1]] < at[order[i]], order[i - 1] .. " before " .. order[i])
    end
  end)
  -- Phase 3 (preflight row 3): the tooltip registrar after the phase-2 UI, so 1b worlds that load through
  -- UI/Tooltips.lua never load it.
  it("loads UI/AltsTooltips.lua after UI/OrdersOptions.lua", function()
    local at = {}
    for i, f in ipairs(toc.files) do at[f] = i end
    assert.is_truthy(at["UI/AltsTooltips.lua"])
    assert.is_true(at["UI/OrdersOptions.lua"] < at["UI/AltsTooltips.lua"])
  end)
  -- Phase 3 Task 15: the Dashboard widget registrar last, after the tooltip registrar.
  it("loads UI/AltsDashboard.lua after UI/AltsTooltips.lua", function()
    local at = {}
    for i, f in ipairs(toc.files) do at[f] = i end
    assert.is_truthy(at["UI/AltsDashboard.lua"])
    assert.is_true(at["UI/AltsTooltips.lua"] < at["UI/AltsDashboard.lua"])
  end)
  -- Phase 4 Task 11 (preflight row 33): the chat scanner follows the matcher, and its toast registrar goes after the
  -- phase-3 UI (the Alts Dashboard is no longer the last file).
  it("loads the phase-4 chat scanner after the matcher and the toasts after UI/AltsDashboard.lua", function()
    local at = {}
    for i, f in ipairs(toc.files) do at[f] = i end
    for _, f in ipairs({ "Modules/Social/ChatMatcher.lua", "Modules/Social/ChatScan.lua", "UI/ChatToast.lua" }) do
      assert.is_truthy(at[f], f)
    end
    assert.is_true(at["Modules/Social/Gate.lua"] < at["Modules/Social/ChatScan.lua"])
    assert.is_true(at["Modules/Social/ChatMatcher.lua"] < at["Modules/Social/ChatScan.lua"])
    assert.is_true(at["Modules/PlannerSpec.lua"] < at["Modules/Social/ChatScan.lua"])
    assert.is_true(at["Modules/Social/ChatScan.lua"] < at["UI/Util.lua"])
    assert.is_true(at["UI/AltsDashboard.lua"] < at["UI/ChatToast.lua"])
  end)
  -- Phase 4 Task 12 (preflight row 33): the setup guide module after the chat scanner, its window after the toasts
  -- (so after UI/AltsDashboard.lua).
  it("loads the onboarding module after ChatScan and its wizard after the chat toasts", function()
    local at = {}
    for i, f in ipairs(toc.files) do at[f] = i end
    for _, f in ipairs({ "Modules/Onboarding.lua", "UI/OnboardingWizard.lua" }) do assert.is_truthy(at[f], f) end
    assert.is_true(at["Modules/Social/Util.lua"] < at["Modules/Onboarding.lua"])
    assert.is_true(at["Modules/Social/ChatScan.lua"] < at["Modules/Onboarding.lua"])
    assert.is_true(at["Modules/Onboarding.lua"] < at["UI/Util.lua"])
    assert.is_true(at["UI/AltsDashboard.lua"] < at["UI/ChatToast.lua"])
    assert.is_true(at["UI/ChatToast.lua"] < at["UI/OnboardingWizard.lua"])
    assert.equal(#toc.files, at["UI/OnboardingWizard.lua"])
  end)
  -- Phase 3 (Task 16, preflight row 3): the phase-3 data files after Data/OrderRewards.lua and before Math, the
  -- phase-3 modules after Modules/Ledger.lua in dependency order, all before the UI.
  it("loads the phase-3 data files and modules in order", function()
    local at = {}
    for i, f in ipairs(toc.files) do at[f] = i end
    local chain = { "Data/GameData_Manual.lua", "Data/OrderRewards.lua", "Data/GameData_Knowledge.lua",
      "Data/GameData_RecipeSources.lua", "Math/Quality.lua", "Modules/Ledger.lua", "Modules/PlanCalc.lua",
      "Modules/Alts.lua", "Modules/AltsCollector.lua", "Modules/Planner.lua", "Modules/PlannerSpec.lua",
      "UI/Util.lua" }
    for i = 2, #chain do
      assert.is_truthy(at[chain[i - 1]], chain[i - 1]); assert.is_truthy(at[chain[i]], chain[i])
      assert.is_true(at[chain[i - 1]] < at[chain[i]], chain[i - 1] .. " before " .. chain[i])
    end
  end)
  -- Phase 3 (Tasks 12-14): the shared view helpers before the view files, the view files before the tabs that use
  -- them, all before the Settings tab.
  it("loads the phase-3 grid, view helpers, views and tabs in order", function()
    local at = {}
    for i, f in ipairs(toc.files) do at[f] = i end
    for _, pair in ipairs({
      { "UI/Tabs/Ledger.lua", "UI/Widgets/ExpandGrid.lua" },
      { "UI/Widgets/ExpandGrid.lua", "UI/Tabs/ViewUtil.lua" },
      { "UI/Tabs/ViewUtil.lua", "UI/Tabs/CharactersView.lua" },
      { "UI/Tabs/ViewUtil.lua", "UI/Tabs/PlannerView.lua" },
      { "UI/Tabs/CharactersView.lua", "UI/Tabs/Characters.lua" },
      { "UI/Tabs/PlannerView.lua", "UI/Tabs/Characters.lua" },
      { "UI/Tabs/Characters.lua", "UI/Tabs/Settings.lua" },
      { "UI/Tabs/PlannerView.lua", "UI/Tabs/Planner.lua" },
      { "UI/Tabs/Characters.lua", "UI/Tabs/Planner.lua" },
      { "UI/Tabs/Planner.lua", "UI/Tabs/Settings.lua" },
    }) do
      assert.is_truthy(at[pair[1]], pair[1]); assert.is_truthy(at[pair[2]], pair[2])
      assert.is_true(at[pair[1]] < at[pair[2]], pair[1] .. " before " .. pair[2])
    end
  end)
  -- Phase 4 Task 9: the guild options and slash command after the directory they read, the tab after the Planner's and
  -- before the Settings tab (preflight row 33).
  it("loads the guild options after GuildDirectory and the Guild tab between the Planner and Settings tabs", function()
    local at = {}
    for i, f in ipairs(toc.files) do at[f] = i end
    for _, pair in ipairs({
      { "Modules/Social/GuildDirectory.lua", "Modules/Social/GuildOptions.lua" },
      { "Modules/Social/GuildOptions.lua", "UI/Util.lua" },
      { "UI/Widgets/ExpandGrid.lua", "UI/Tabs/Guild.lua" },
      { "UI/Tabs/Planner.lua", "UI/Tabs/Guild.lua" },
      { "UI/Tabs/Guild.lua", "UI/Tabs/Settings.lua" },
    }) do
      assert.is_truthy(at[pair[1]], pair[1]); assert.is_truthy(at[pair[2]], pair[2])
      assert.is_true(at[pair[1]] < at[pair[2]], pair[1] .. " before " .. pair[2])
    end
  end)
end)
