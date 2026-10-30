describe("Prices", function()
  local W, ns, P

  before_each(function()
    W = install_wow_stubs()
    ns = load_addon({}, "Modules/Prices.lua"); W.boot()
    P = ns.FS:GetModule("Prices")
  end)

  it("is a core module", function() assert.is_true(P.coreModule) end)

  it("returns no price without Auctionator and never errors", function()
    W.removeAuctionator(); assert.is_false(P:HasSource()); assert.same({}, P:Get(2001))
    assert.is_nil(P:AuctionatorAPI())
  end)
  it("prefers overrides and bumps the version", function()
    local v = P:GetVersion(); W.auctionator.prices[2001] = 999
    assert.is_true(P:SetOverride(2001, 50000.7)); assert.same({ value = 50000, source = "override" }, P:Get(2001))
    assert.equals(v + 1, P:GetVersion()); assert.same({ "FS_PRICES_CHANGED", v + 1 }, W.messages[#W.messages])
  end)
  it("accepts an explicit zero override and removes with nil", function()
    P:SetOverride(2001, 0); assert.same({ value = 0, source = "override" }, P:Get(2001))
    P:SetOverride(2001, nil); assert.same({}, P:Get(2001))
  end)
  it("rejects invalid overrides", function()
    assert.is_false(P:SetOverride(2001, -5)); assert.is_false(P:SetOverride(2001, "abc"))
    assert.is_false(P:SetOverride(2001, 0 / 0)); assert.is_false(P:SetOverride(2001, math.huge))
    assert.is_false(P:SetOverride("x", 5)); assert.is_false(P:SetOverride(0, 5))
    assert.same({}, P:GetOverrides())
  end)
  it("does not bump or send when nothing changes", function()
    local v, n = P:GetVersion(), #W.messages
    assert.is_true(P:SetOverride(2001, nil)); assert.is_true(P:SetOverride(2001, 5)); assert.is_true(P:SetOverride(2001, 5))
    assert.equals(v + 1, P:GetVersion()); assert.equals(n + 1, #W.messages)
  end)
  it("returns auction price with age, using the FabricationStation callerID", function()
    W.auctionator.prices[2001] = 12345; W.auctionator.ages[2001] = 2
    assert.same({ value = 12345, source = "auction", ageDays = 2 }, P:Get(2001)); assert.equals("FabricationStation", W.auctionator.lastCallerID)
  end)
  it("reports a nil age when Auctionator has none", function()
    W.auctionator.prices[2001] = 12345
    assert.same({ value = 12345, source = "auction" }, P:Get(2001))
  end)
  it("treats an Auctionator price of 0 as missing", function()
    W.auctionator.prices[2001] = 0; W.auctionator.vendor[2001] = 500
    assert.same({ value = 500, source = "vendor" }, P:Get(2001)); W.auctionator.vendor[2001] = nil; assert.is_nil(P:Get(2001).value)
  end)
  it("survives the Auctionator API throwing", function()
    Auctionator.API.v1.GetAuctionPriceByItemID = function() error("api changed") end; W.auctionator.vendor[2001] = 500
    assert.equals(500, P:Get(2001).value); P:Get(2001); assert.equals(1, #ns.FS.db.global.diagnostics.errors)
    assert.equals("Prices", ns.FS.db.global.diagnostics.errors[1].source)
  end)
  it("logs the first failure of each Auctionator function once", function()
    W.auctionator.prices[2001] = 100
    Auctionator.API.v1.GetAuctionAgeByItemID = function() error("age broke") end
    Auctionator.API.v1.GetVendorPriceByItemID = function() error("vendor broke") end
    P:Get(2001); P:Get(2001)
    W.auctionator.prices[2001] = nil; P:Get(2001); P:Get(2001)
    local errs = ns.FS.db.global.diagnostics.errors
    assert.equals(2, #errs); assert.matches("age broke", errs[1].err); assert.matches("vendor broke", errs[2].err)
  end)
  it("survives the age lookup throwing and treats the price as stale", function()
    W.auctionator.prices[2001] = 100
    Auctionator.API.v1.GetAuctionAgeByItemID = function() error("boom") end
    local r = P:Get(2001); assert.equals(100, r.value); assert.is_nil(r.ageDays); assert.is_true(P:IsStale(r))
  end)
  it("ignores non-numeric item ids", function() assert.same({}, P:Get(nil)); assert.same({}, P:Get("x")) end)
  it("reports the source and exposes the v1 API table", function()
    assert.is_true(P:HasSource()); assert.equals(Auctionator.API.v1, P:AuctionatorAPI())
    Auctionator.API.v1.GetAuctionPriceByItemID = nil; assert.is_false(P:HasSource())
    _G.Auctionator = {}; assert.is_false(P:HasSource()); assert.is_nil(P:AuctionatorAPI())
    _G.Auctionator = "x"; assert.is_false(P:HasSource())
  end)
  it("judges staleness", function()
    assert.is_true(P:IsStale({ value = 1, source = "auction", ageDays = 5 })); assert.is_false(P:IsStale({ value = 1, source = "auction", ageDays = 1 }))
    assert.is_true(P:IsStale({ value = 1, source = "auction" })); assert.is_false(P:IsStale({ value = 1, source = "vendor" }))
    assert.is_false(P:IsStale({ value = 1, source = "override" }))
    assert.is_false(P:IsStale({ value = 1, source = "auction", ageDays = 3 })); assert.is_false(P:IsStale({}))
  end)
  it("follows the staleAfterDays setting", function()
    ns.FS.db.global.settings.prices.staleAfterDays = 7
    assert.is_false(P:IsStale({ value = 1, source = "auction", ageDays = 5 }))
    assert.is_true(P:IsStale({ value = 1, source = "auction", ageDays = 8 }))
  end)
  it("debounces Auctionator DB updates into one version bump", function()
    assert.equals(1, #W.auctionator.dbCallbacks); local v = P:GetVersion()
    for _ = 1, 3 do W.auctionator.dbCallbacks[1]() end; W.advance(1)
    assert.equals(v + 1, P:GetVersion()); assert.equals(W.now, P:GetLastUpdate())
    assert.same({ "FS_PRICES_CHANGED", v + 1 }, W.messages[#W.messages])
  end)
  it("starts at version 1 with no last update", function()
    assert.equals(1, P:GetVersion()); assert.is_nil(P:GetLastUpdate())
  end)
  it("ignores DB updates while disabled", function()
    local v = P:GetVersion(); W.auctionator.dbCallbacks[1](); P:Disable(); W.advance(1)
    assert.equals(v, P:GetVersion()); assert.is_nil(P:GetLastUpdate())
  end)
  it("does not register twice across disable/enable", function() P:Disable(); P:Enable(); assert.equals(1, #W.auctionator.dbCallbacks) end)
  it("does not register when Auctionator is missing", function()
    W = install_wow_stubs(); W.removeAuctionator()
    ns = load_addon({}, "Modules/Prices.lua"); W.boot()
    assert.equals(0, #W.auctionator.dbCallbacks); assert.same({}, ns.FS:GetModule("Prices"):Get(1))
  end)
  it("logs a failing DB-update registration and keeps running", function()
    W = install_wow_stubs(); Auctionator.API.v1.RegisterForDBUpdate = function() error("nope") end
    ns = load_addon({}, "Modules/Prices.lua"); W.boot()
    assert.equals(1, #ns.FS.db.global.diagnostics.errors); assert.is_true(ns.FS:GetModule("Prices"):IsEnabled())
  end)

  describe("when the saved data is from a newer version", function()
    before_each(function()
      ns.FS.dbIsNewer = true
    end)
    it("writes no overrides", function()
      assert.is_false(P:SetOverride(2001, 5)); assert.same({}, ns.FS.db.global.priceOverrides)
    end)
    it("keeps lastUpdate out of the database but still bumps the version", function()
      local v = P:GetVersion(); W.auctionator.dbCallbacks[1](); W.advance(1)
      assert.equals(v + 1, P:GetVersion()); assert.is_nil(ns.FS.db.global.priceMeta.lastUpdate)
    end)
  end)

  describe("options", function()
    local function group() return ns.FS:GetOptionsTable().args.prices end
    before_each(function()
      ns.UI = {
        FormatMoney = function(c) return c .. "c" end,
        ParseMoney = function(t) return tonumber(t:match("^(%d+)c$")) end,
        ParseItemID = function(t) return tonumber(t:match("item:(%d+)") or t:match("^%d+$")) end,
      }
    end)

    it("registers the prices group at order 20", function()
      assert.equals("group", group().type); assert.equals(20, group().order)
    end)
    it("shows the Auctionator connection status", function()
      assert.equals("Auctionator: connected", group().args.status.name())
      W.removeAuctionator()
      assert.equals("Auctionator: not found — only manual prices are used", group().args.status.name())
    end)
    it("edits staleAfterDays between 1 and 14", function()
      local o = group().args.staleAfterDays
      assert.equals("range", o.type); assert.equals(1, o.min); assert.equals(14, o.max); assert.equals(1, o.step)
      assert.equals(3, o.get()); o.set(nil, 9); assert.equals(9, ns.FS.db.global.settings.prices.staleAfterDays)
    end)
    it("bumps the price version when staleAfterDays changes", function()
      local v = P:GetVersion(); group().args.staleAfterDays.set(nil, 9)
      assert.equals(v + 1, P:GetVersion()); assert.same({ "FS_PRICES_CHANGED", v + 1 }, W.messages[#W.messages])
      group().args.staleAfterDays.set(nil, 9); assert.equals(v + 1, P:GetVersion())
    end)
    it("bumps the price version when ownedReagentsFree changes", function()
      local v = P:GetVersion(); group().args.ownedReagentsFree.set(nil, true)
      assert.equals(v + 1, P:GetVersion()); assert.same({ "FS_PRICES_CHANGED", v + 1 }, W.messages[#W.messages])
      group().args.ownedReagentsFree.set(nil, true); assert.equals(v + 1, P:GetVersion())
    end)
    it("writes neither setting and bumps nothing while the saved data is newer", function()
      ns.FS.dbIsNewer = true; local v, n = P:GetVersion(), #W.messages
      group().args.staleAfterDays.set(nil, 9); group().args.ownedReagentsFree.set(nil, true)
      assert.equals(3, ns.FS.db.global.settings.prices.staleAfterDays)
      assert.is_false(ns.FS.db.global.settings.costing.ownedReagentsFree)
      assert.equals(v, P:GetVersion()); assert.equals(n, #W.messages)
    end)
    it("edits the owned-reagents-free toggle", function()
      local o = group().args.ownedReagentsFree
      assert.equals("toggle", o.type); assert.equals("Cost reagents I already own at zero", o.name)
      assert.is_false(o.get()); o.set(nil, true); assert.is_true(ns.FS.db.global.settings.costing.ownedReagentsFree)
    end)
    it("adds an override from the item and price inputs", function()
      local a = group().args
      a.newItem.set(nil, "|cff0070dd|Hitem:2001::::|h[Ore]|h|r"); a.newPrice.set(nil, "500c")
      assert.equals("500c", a.newPrice.get()); a.add.func()
      assert.equals(500, P:GetOverrides()[2001]); assert.equals("", a.newItem.get()); assert.equals("", a.newPrice.get())
    end)
    it("adds an override using the real ns.UI parsers", function()
      ns.UI = nil; load_files(ns, { "UI/Util.lua" })
      local a = group().args
      a.newItem.set(nil, "12345"); a.newPrice.set(nil, "1g 50s"); a.add.func()
      assert.equals(15000, P:GetOverrides()[12345]); assert.equals("", a.newItem.get()); assert.equals("", a.newPrice.get())
    end)
    it("keeps the inputs and prints a message for invalid input", function()
      local a = group().args
      a.newItem.set(nil, "ore"); a.newPrice.set(nil, "500c"); a.add.func()
      assert.same({}, P:GetOverrides()); assert.equals("ore", a.newItem.get()); assert.is_true(#W.printed > 0)
    end)
    it("lists overrides with a working Remove button", function()
      P:SetOverride(2001, 100); local list = ns.FS:GetOptionsTable().args.prices.args.list.args
      local remove; for _, a in pairs(list) do if a.type == "execute" then remove = a end end
      remove.func(); assert.is_nil(P:GetOverrides()[2001])
      assert.is_nil(next(ns.FS:GetOptionsTable().args.prices.args.list.args))
    end)
    it("names list rows with the item name and formatted price at render time", function()
      C_Item.GetItemNameByID = function(id) if id == 2001 then return "Ore" end end
      P:SetOverride(2001, 100); P:SetOverride(2002, 7)
      local names = {}
      for _, a in pairs(ns.FS:GetOptionsTable().args.prices.args.list.args) do
        if a.type == "description" then names[#names + 1] = a.name() end
      end
      table.sort(names); assert.same({ "Ore — 100c", "item:2002 — 7c" }, names)
    end)
    it("shows saved overrides after a reload", function()
      W = install_wow_stubs()
      _G.FabricationStationDB = { global = { priceOverrides = { [2001] = 100 } } }
      ns = load_addon({}, "Modules/Prices.lua"); W.boot()
      local n = 0
      for _, a in pairs(ns.FS:GetOptionsTable().args.prices.args.list.args) do if a.type == "execute" then n = n + 1 end end
      assert.equals(1, n)
    end)
  end)
end)
