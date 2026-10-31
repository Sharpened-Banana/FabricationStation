describe("FabricationStation.toc", function()
  local toc = read_toc("FabricationStation.toc")
  it("pins the retail Interface number", function() assert.equals("120105", toc.meta.Interface) end)
  it("declares the SavedVariables", function() assert.equals("FabricationStationDB", toc.meta.SavedVariables) end)
  it("soft-depends on Auctionator", function() assert.equals("Auctionator", toc.meta.OptionalDeps) end)
  it("loads embeds.xml first", function() assert.equals("embeds.xml", toc.files[1]) end)
  it("lists only files that exist", function()
    for _, f in ipairs(toc.files) do
      if f ~= "embeds.xml" then assert.is_truthy(io.open(f, "r"), "missing " .. f) end
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
  -- Phase 3 (Tasks 12-13): the shared view helpers before the view files, the view files before the tabs that use
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
    }) do
      assert.is_truthy(at[pair[1]], pair[1]); assert.is_truthy(at[pair[2]], pair[2])
      assert.is_true(at[pair[1]] < at[pair[2]], pair[1] .. " before " .. pair[2])
    end
  end)
end)
