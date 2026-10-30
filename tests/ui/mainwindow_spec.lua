describe("MainWindow", function()
  local W, ns, MW

  before_each(function()
    W = install_wow_stubs()
    ns = load_addon({}, "UI/MainWindow.lua"); W.boot()
    MW = ns.FS:GetModule("MainWindow")
  end)

  local function tab(order, calls)
    return {
      label = "L", order = order,
      build = function() calls.b = (calls.b or 0) + 1 end,
      refresh = function() calls.r = (calls.r or 0) + 1 end,
    }
  end

  it("is a core module", function() assert.is_true(MW.coreModule) end)

  it("sorts tabs by order", function()
    MW:RegisterTab("queue", tab(30, {})); MW:RegisterTab("dashboard", tab(10, {})); MW:RegisterTab("settings", tab(100, {}))
    local ids = {}; for i, t in ipairs(MW:GetTabs()) do ids[i] = t.id end
    assert.same({ "dashboard", "queue", "settings" }, ids)
  end)
  it("rejects duplicate and incomplete tabs", function()
    assert.is_true(MW:RegisterTab("a", tab(1, {}))); assert.is_false(MW:RegisterTab("a", tab(2, {})))
    assert.is_false(MW:RegisterTab("b", { label = "B" }))
    assert.is_false(MW:RegisterTab("c", { label = "C", order = 1 })); assert.is_false(MW:RegisterTab("d", { order = 1, build = function() end }))
    assert.equals(1, #MW:GetTabs()); assert.equals(1, MW:GetTabs()[1].def.order)
    assert.is_true(#ns.FS.db.global.diagnostics.errors >= 1)
  end)
  it("toggles a closable named window", function()
    MW:Toggle(); assert.is_true(MW:IsShown()); assert.is_truthy(_G.FabricationStationMainWindow)
    assert.is_truthy(table.concat(UISpecialFrames, ","):find("FabricationStationMainWindow")); MW:Toggle()
    assert.is_false(MW:IsShown())
  end)
  it("creates the window lazily, hidden, and only once", function()
    assert.is_nil(_G.FabricationStationMainWindow); assert.is_false(MW:IsShown())
    MW:Show(); local f = _G.FabricationStationMainWindow; MW:Hide(); MW:Show()
    assert.equals(f, _G.FabricationStationMainWindow)
    local n = 0; for _, name in ipairs(UISpecialFrames) do if name == "FabricationStationMainWindow" then n = n + 1 end end
    assert.equals(1, n)
  end)
  it("builds a tab once and refreshes it on every select", function()
    local c = {}; MW:RegisterTab("a", tab(1, c)); MW:RegisterTab("b", tab(2, {})); MW:Show()
    MW:SelectTab("b"); MW:SelectTab("a"); assert.equals(1, c.b); assert.equals(2, c.r)
    assert.equals("a", ns.FS.db.global.settings.window.tab); assert.is_false(MW:SelectTab("nope"))
  end)
  it("selects the lowest-order tab on first show, or the stored one", function()
    MW:RegisterTab("b", tab(2, {})); MW:RegisterTab("a", tab(1, {})); MW:Show()
    assert.equals("a", MW:GetSelectedTab())
  end)
  it("restores the stored tab when it is registered", function()
    ns.FS.db.global.settings.window.tab = "b"
    MW:RegisterTab("a", tab(1, {})); MW:RegisterTab("b", tab(2, {})); MW:Show()
    assert.equals("b", MW:GetSelectedTab())
  end)
  it("falls back to the lowest-order tab when the stored one is gone", function()
    ns.FS.db.global.settings.window.tab = "gone"
    MW:RegisterTab("a", tab(1, {})); MW:Show(); assert.equals("a", MW:GetSelectedTab())
  end)
  it("keeps working when a tab build fails", function()
    MW:RegisterTab("boom", { label = "B", order = 1, build = function() error("kaput") end }); MW:Show()
    assert.is_true(MW:IsEnabled()); assert.equals("Tab:boom", ns.FS.db.global.diagnostics.errors[1].source)
  end)
  it("keeps working when a tab refresh fails and does not rebuild", function()
    local built = 0
    MW:RegisterTab("r", { label = "R", order = 1, build = function() built = built + 1 end, refresh = function() error("bad") end })
    MW:Show(); MW:SelectTab("r")
    assert.is_true(MW:IsEnabled()); assert.equals(1, built)
    assert.equals("Tab:r", ns.FS.db.global.diagnostics.errors[1].source)
  end)
  it("refreshes only the visible selected tab", function()
    local a, b = {}, {}; MW:RegisterTab("a", tab(1, a)); MW:RegisterTab("b", tab(2, b)); MW:Show(); MW:SelectTab("b")
    MW:RefreshTab("a"); assert.equals(1, a.r); MW:RefreshTab("b"); assert.equals(2, b.r)
    MW:Hide(); MW:RefreshTab("b"); assert.equals(2, b.r)
  end)
  it("describes price freshness in the header", function()
    local h = MW:GetHeaderText(); assert.equals("Thrall-ArgentDawn", h.character); assert.equals("Prices: not scanned yet", h.prices)
    ns.FS.db.global.priceMeta.lastUpdate = W.now - 7200; assert.equals("Prices: 2h ago", MW:GetHeaderText().prices)
    W.removeAuctionator(); assert.equals("Prices: no Auctionator", MW:GetHeaderText().prices)
  end)
  it("formats gold in the header", function()
    _G.GetMoney = function() return 1234567 end
    assert.equals("123g 45s 67c", MW:GetHeaderText().gold)
  end)
  it("opens from /fs and /fs settings", function()
    MW:RegisterTab("settings", tab(100, {})); ns.FS:HandleSlash(""); assert.is_true(MW:IsShown())
    ns.FS:HandleSlash("settings"); assert.equals("settings", MW:GetSelectedTab())
  end)
  it("handles /fs, /fs show and /fs tab <id>", function()
    MW:RegisterTab("a", tab(1, {})); MW:RegisterTab("queue", tab(30, {}))
    ns.FS:HandleSlash("show"); assert.is_true(MW:IsShown()); ns.FS:HandleSlash("")
    assert.is_false(MW:IsShown())
    ns.FS:HandleSlash("tab queue"); assert.is_true(MW:IsShown()); assert.equals("queue", MW:GetSelectedTab())
    assert.equals("open or close the window", ns.FS.slashCommands[""].help)
  end)
  it("saves its position on drag stop", function()
    MW:Show(); local f = _G.FabricationStationMainWindow; f.GetPoint = function() return "CENTER", nil, "CENTER", 10, 20 end
    f:GetScript("OnDragStop")(f); local w = ns.FS.db.global.settings.window; assert.same({ "CENTER", 10, 20 }, { w.point, w.x, w.y })
  end)
  it("saves its size and anchor once resizing settles", function()
    MW:Show(); local f = _G.FabricationStationMainWindow; f.GetSize = function() return 1000.4, 700.6 end
    f.GetPoint = function() return "TOPLEFT", nil, "TOPLEFT", 30, -40 end
    local onSize = f:GetScript("OnSizeChanged"); onSize(f, 1000.4, 700.6); onSize(f, 1000.4, 700.6)
    local w = ns.FS.db.global.settings.window; assert.same({ 900, 600 }, { w.width, w.height })
    W.advance(1); assert.same({ 1000, 701 }, { w.width, w.height })
    assert.same({ "TOPLEFT", 30, -40 }, { w.point, w.x, w.y })
  end)
  it("hooks template-owned scripts instead of replacing them", function()
    local template = {}
    local realCreate = CreateFrame
    _G.CreateFrame = function(t, name, parent, tpl)
      local f = realCreate(t, name, parent, tpl)
      if name == "FabricationStationMainWindow" then
        for _, ev in ipairs({ "OnShow", "OnHide", "OnSizeChanged" }) do
          f:SetScript(ev, function() template[ev] = (template[ev] or 0) + 1 end)
        end
      end
      return f
    end
    MW:Show(); local f = _G.FabricationStationMainWindow
    f:GetScript("OnShow")(f); f:GetScript("OnHide")(f); f:GetScript("OnSizeChanged")(f, 1, 1)
    assert.same({ OnShow = 1, OnHide = 1, OnSizeChanged = 1 }, template)
  end)
  it("has a resize grip", function() MW:Show(); assert.is_truthy(MW.resizeGrip) end)
  it("writes nothing to a newer database", function()
    ns.FS.dbIsNewer = true; MW:RegisterTab("a", tab(1, {})); MW:Show()
    local f = _G.FabricationStationMainWindow; f.GetPoint = function() return "TOP", nil, "TOP", 5, 6 end
    f:GetScript("OnDragStop")(f)
    local w = ns.FS.db.global.settings.window; assert.same({ "CENTER", 0, 0 }, { w.point, w.x, w.y }); assert.is_nil(w.tab)
  end)
  it("updates the header when prices or money change", function()
    MW:Show(); local before = MW:GetHeaderText().prices
    ns.FS.db.global.priceMeta.lastUpdate = W.now - 120
    ns.FS:GetModule("Prices"):SendMessage(ns.Msg.PRICES_CHANGED, 2)
    assert.not_equals(before, MW:GetHeaderText().prices)
    assert.equals("Prices: 2m ago", MW:GetHeaderStrings().prices:GetText())
    _G.GetMoney = function() return 10000 end; W.fire("PLAYER_MONEY")
    assert.equals("1g 0s 0c", MW:GetHeaderStrings().gold:GetText())
  end)

  describe("opening a specific tab", function()
    local function counted(order, calls)
      return {
        label = "L", order = order,
        build = function() calls.b = (calls.b or 0) + 1 end,
        refresh = function() calls.r = (calls.r or 0) + 1 end,
      }
    end
    it("builds and refreshes only the requested tab for /fs settings", function()
      local a, s = {}, {}
      MW:RegisterTab("a", counted(1, a)); MW:RegisterTab("settings", counted(100, s))
      ns.FS:HandleSlash("settings")
      assert.same({}, a); assert.same({ b = 1, r = 1 }, s); assert.equals("settings", MW:GetSelectedTab())
    end)
    it("builds and refreshes only the requested tab for /fs tab <id>", function()
      local a, q = {}, {}
      MW:RegisterTab("a", counted(1, a)); MW:RegisterTab("queue", counted(30, q))
      ns.FS:HandleSlash("tab queue")
      assert.same({}, a); assert.same({ b = 1, r = 1 }, q)
    end)
    it("selects the requested tab when the window is already open", function()
      local a, q = {}, {}
      MW:RegisterTab("a", counted(1, a)); MW:RegisterTab("queue", counted(30, q)); MW:Show()
      ns.FS:HandleSlash("tab queue"); assert.equals("queue", MW:GetSelectedTab()); assert.same({ b = 1, r = 1 }, q)
    end)
    it("opens the default tab and lists the tabs for an unknown id", function()
      MW:RegisterTab("a", counted(1, {})); ns.FS:HandleSlash("tab nope")
      assert.is_true(MW:IsShown()); assert.equals("a", MW:GetSelectedTab())
      assert.is_truthy(W.printed[#W.printed]:find("no tab named", 1, true))
    end)
  end)

  describe("building the window", function()
    it("falls back to CENTER for a corrupt saved anchor and values", function()
      local w = ns.FS.db.global.settings.window
      w.point, w.x, w.y, w.width, w.height = {}, "x", true, "wide", false
      MW:Show(); local f = _G.FabricationStationMainWindow
      assert.same({ "CENTER", 0, 0 }, { select(1, f:GetPoint(1)), select(4, f:GetPoint(1)), select(5, f:GetPoint(1)) })
      assert.same({ 900, 600 }, { f:GetSize() })
    end)
    it("falls back to CENTER for an unknown anchor name", function()
      ns.FS.db.global.settings.window.point = "NOWHERE"; MW:Show()
      assert.equals("CENTER", (_G.FabricationStationMainWindow:GetPoint(1)))
    end)
    it("leaves no half-built frame when construction fails", function()
      local realCreate, failures = CreateFrame, 1
      _G.CreateFrame = function(t, name, parent, tpl)
        if tpl == "PanelResizeButtonTemplate" and failures > 0 then failures = failures - 1; error("template missing") end
        return realCreate(t, name, parent, tpl)
      end
      MW:RegisterTab("a", { label = "A", order = 1, build = function() end })
      assert.is_false(pcall(MW.Show, MW)); assert.is_false(MW:IsShown())
      assert.is_false(table.concat(UISpecialFrames, ","):find("FabricationStationMainWindow") ~= nil)
      MW:Show(); assert.is_true(MW:IsShown()); assert.equals("a", MW:GetSelectedTab())
      assert.is_truthy(MW:GetHeaderStrings().character:GetText())
    end)
  end)
end)
