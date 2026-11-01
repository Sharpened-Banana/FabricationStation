-- Phase 7 Task 8: the sale lines of an item tooltip (SaleLog:TooltipLines) and the FeatureLines registrar.
local P2 = require("tests.helpers.phase2")

describe("SaleLog tooltip lines", function()
  local ns, W, S, sales, providers, queries
  local ME = "Me-Silvermoon"
  local NOW = 1000

  local function seed(events, listed)
    ns.FS.db.global.auctionLog = { events = events or {}, seenMail = {},
      listings = listed and { [ME] = { time = NOW - 60, items = listed } } or {} }
  end
  local function event(kind, itemID, quantity)
    return { time = NOW - 100, kind = kind, itemID = itemID, quantity = quantity, charKey = ME }
  end

  local function boot(ledger)
    ns, W = P2.boot({})
    providers = {}
    P2.fake_module(ns, "Tooltips", { RegisterLineProvider = function(_, id, fn) providers[id] = fn end })
    if ledger ~= false then
      P2.fake_module(ns, "Ledger", { Query = function(_, filter)
        queries = queries + 1
        local out = {}
        for _, sale in ipairs(sales) do
          if sale.time >= filter.since then out[#out + 1] = sale end
        end
        table.sort(out, function(a, b) return a.time > b.time end)
        return out
      end })
    end
    P2.load(ns, { "Modules/SaleLog.lua", "UI/FeatureLines.lua" })
    S = ns.FS:GetModule("SaleLog")
  end

  before_each(function()
    sales, queries = {}, 0
    boot()
  end)

  it("adds the sale lines to an item with history", function()
    seed({ event("post", 5, 2), event("expire", 5, 1) }, { [5] = 3 })
    sales[1] = { itemID = 5, quantity = 1, amount = 9500, time = NOW - 7200 }
    assert.same({
      { "Your sales", "1 of 2 sold (50%)" },
      { "Last sale", ns.UI.FormatMoney(9500) .. " each, 2h ago" },
      { "Listed now", "3" },
    }, S:TooltipLines(5, NOW))
  end)

  it("floors the percentage and divides the last sale by its quantity", function()
    seed({ event("expire", 5, 2) })
    sales[1] = { itemID = 5, quantity = 2, amount = 4001, time = NOW - 30 }
    local lines = S:TooltipLines(5, NOW)
    assert.same({ "Your sales", "2 of 4 sold (50%)" }, lines[1])
    assert.same({ "Last sale", ns.UI.FormatMoney(2000) .. " each, <1m ago" }, lines[2])
    sales[2] = { itemID = 5, quantity = 1, amount = 10, time = NOW - 40 }
    assert.same({ "Your sales", "3 of 5 sold (60%)" }, S:TooltipLines(5, NOW)[1])
    seed({ event("expire", 5, 2) })
    sales = { { itemID = 5, quantity = 1, amount = 10, time = NOW - 40 } }
    assert.same({ "Your sales", "1 of 3 sold (33%)" }, S:TooltipLines(5, NOW)[1])
  end)

  it("adds nothing without history or with the setting off", function()
    assert.same({}, S:TooltipLines(5, NOW))
    seed({ event("post", 6, 2) })   -- another item's history
    assert.same({}, S:TooltipLines(5, NOW))
    -- A post alone is no outcome: no sold line; nothing listed: no listed line.
    assert.same({}, S:TooltipLines(6, NOW))
    seed({ event("expire", 5, 1) }, { [5] = 2 })
    assert.equal(2, #S:TooltipLines(5, NOW))   -- the sold line and the listed line
    S:Settings().tooltip = false
    assert.same({}, S:TooltipLines(5, NOW))
    assert.same({}, providers.saleLog(5))
  end)

  it("leaves out the sold line while the Ledger is off and never shows unknown counts as 0", function()
    seed({ event("expire", 5, 1), event("post", 5, 1) })
    ns.FS:SetModuleEnabled("Ledger", false)
    assert.same({}, S:TooltipLines(5, NOW))   -- no listing snapshot either: nothing is known
  end)

  it("returns nothing while SaleLog is off", function()
    seed({ event("expire", 5, 1) }, { [5] = 2 })
    assert.is_true(#S:TooltipLines(5, NOW) > 0)
    S:Disable()
    assert.same({}, S:TooltipLines(5, NOW))
    assert.same({}, providers.saleLog(5))
  end)

  it("ignores an item that is not a positive number", function()
    seed({ event("expire", 5, 1) })
    assert.same({}, S:TooltipLines(nil, NOW))
    assert.same({}, S:TooltipLines("x", NOW))
  end)

  it("computes nothing and writes nothing while the saved data is from a newer version", function()
    seed({ event("post", 5, 2), event("expire", 5, 1) }, { [5] = 3 })
    sales[1] = { itemID = 5, quantity = 1, amount = 9500, time = NOW - 7200 }
    ns.FS.dbIsNewer = true
    local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
    assert.equal(3, #S:TooltipLines(5, NOW))
    assert.equal(3, #providers.saleLog(5))
    assert.same(before, ns.Util.DeepCopy(ns.FS.db.global, 30))
    ns.FS.dbIsNewer = nil
  end)

  describe("the per-item memo", function()
    before_each(function()
      seed({ event("post", 5, 2), event("expire", 5, 1) }, { [5] = 3 })
      sales[1] = { itemID = 5, quantity = 1, amount = 9500, time = NOW - 7200 }
    end)

    it("answers a repeated hover from memory", function()
      local first = S:TooltipLines(5)
      local count = queries
      assert.is_true(count > 0)
      assert.same(first, S:TooltipLines(5))
      assert.same(first, providers.saleLog(5))
      assert.equal(count, queries)
      first[1][2] = "changed by a caller"
      assert.equal("1 of 2 sold (50%)", S:TooltipLines(5)[1][2])   -- callers get copies
    end)

    it("is dropped by a Ledger change and by a sale log change", function()
      assert.equal("1 of 2 sold (50%)", S:TooltipLines(5)[1][2])
      sales[2] = { itemID = 5, quantity = 1, amount = 100, time = NOW - 10 }
      assert.equal("1 of 2 sold (50%)", S:TooltipLines(5)[1][2])   -- still the remembered lines
      ns.FS:GetModule("Ledger"):SendMessage(ns.Msg.LEDGER_CHANGED)
      assert.equal("2 of 3 sold (66%)", S:TooltipLines(5)[1][2])
      sales[3] = { itemID = 5, quantity = 1, amount = 100, time = NOW - 10 }
      S:SendMessage(ns.Msg.SALELOG_CHANGED)
      assert.equal("3 of 4 sold (75%)", S:TooltipLines(5)[1][2])
    end)

    it("expires after a minute so the age moves on, and follows the Ledger being turned off", function()
      assert.equal(" each, 2h ago", S:TooltipLines(5)[2][2]:sub(-13))
      W.advance(61)
      local count = queries
      S:TooltipLines(5)
      assert.is_true(queries > count)
      ns.FS:SetModuleEnabled("Ledger", false)
      assert.same({ { "Listed now", "3" } }, S:TooltipLines(5))   -- sold and last sale are unknown now
    end)

    it("is forgotten when SaleLog is turned off", function()
      S:TooltipLines(5)
      S:Disable()
      assert.same({}, S:TooltipLines(5))
      S:Enable()
      assert.equal(3, #S:TooltipLines(5))
    end)
  end)

  describe("FeatureLines", function()
    -- PUC Lua 5.1 (CI) has xpcall(f, err) only: extra arguments are dropped, where LuaJIT forwards them.
    local realXpcall
    before_each(function()
      realXpcall = _G.xpcall
      _G.xpcall = function(f, handler) return realXpcall(f, handler) end
    end)
    after_each(function() _G.xpcall = realXpcall end)

    it("calls the module's method with the module and the item under a 5.1 xpcall", function()
      seed({ event("expire", 5, 1) })
      assert.equal("0 of 1 sold (0%)", providers.saleLog(5)[1][2])
    end)

    it("is a core registrar that registers the saleLog provider on the Tooltips module", function()
      assert.is_true(ns.FS:GetModule("FeatureLines").coreModule)
      assert.is_true(ns.FS:GetModule("FeatureLines"):IsEnabled())
      assert.is_function(providers.saleLog)
    end)

    it("gives the module's lines for the item", function()
      seed({ event("expire", 5, 1) })
      assert.same(S:TooltipLines(5, W.now), providers.saleLog(5))
      assert.equal("0 of 1 sold (0%)", providers.saleLog(5)[1][2])
    end)

    it("logs an erroring provider under FeatureLines:saleLog and shows nothing, leaving the module on", function()
      S.TooltipLines = function() error("boom") end
      assert.same({}, providers.saleLog(5))
      local errors = ns.FS.db.global.diagnostics.errors
      assert.equal("FeatureLines:saleLog", errors[#errors].source)
      assert.is_true(S:IsEnabled())
      assert.same({}, ns.FS.failedModules)
    end)

    it("logs a failing provider once per session, however many tooltips fail", function()
      S.TooltipLines = function() error("boom") end
      for _ = 1, 5 do assert.same({}, providers.saleLog(5)) end
      local n = 0
      for _, e in ipairs(ns.FS.db.global.diagnostics.errors) do
        if e.source == "FeatureLines:saleLog" then n = n + 1 end
      end
      assert.equal(1, n)
    end)

    it("shows nothing when the SaleLog module is missing", function()
      S.TooltipLines = nil
      assert.same({}, providers.saleLog(5))
    end)
  end)
end)
