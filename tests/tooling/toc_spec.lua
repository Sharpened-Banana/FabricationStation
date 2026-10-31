describe("FabricationStation.toc", function()
  local toc = read_toc("FabricationStation.toc")
  it("pins the retail Interface number", function() assert.equals("120105", toc.meta.Interface) end)
  it("declares the SavedVariables", function() assert.equals("FabricationStationDB", toc.meta.SavedVariables) end)
  it("soft-depends on Auctionator", function() assert.equals("Auctionator", toc.meta.OptionalDeps) end)
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
  it("loads UI/AltsDashboard.lua last, after UI/AltsTooltips.lua", function()
    local at = {}
    for i, f in ipairs(toc.files) do at[f] = i end
    assert.is_truthy(at["UI/AltsDashboard.lua"])
    assert.is_true(at["UI/AltsTooltips.lua"] < at["UI/AltsDashboard.lua"])
    assert.equal(#toc.files, at["UI/AltsDashboard.lua"])
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
end)
