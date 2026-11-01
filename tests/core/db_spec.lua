describe("DB", function()
  local W, ns
  before_each(function()
    W = install_wow_stubs()
    ns = load_addon({}, "Core/DB.lua")
  end)

  it("applies the defaults", function()
    W.boot()
    local g = ns.FS.db.global
    assert.equals(3, g.settings.prices.staleAfterDays)
    assert.is_false(g.settings.minimap.hide)
    assert.is_table(g.characters)
    assert.equals(900, g.settings.window.width)
    assert.is_false(g.settings.costing.ownedReagentsFree)
    assert.equals(1, g.captures.nextID)
  end)
  it("keeps the exact documented default layout", function()
    local g = ns.DBDefaults.global
    assert.same({ "CENTER", 0, 0, 900, 600 },
      { g.settings.window.point, g.settings.window.x, g.settings.window.y, g.settings.window.width, g.settings.window.height })
    assert.same({}, g.settings.modules); assert.same({}, g.priceOverrides); assert.same({}, g.priceMeta)
    assert.same({ entries = {}, restock = {} }, g.queue); assert.same({}, g.customers)
    assert.same({ entries = {} }, g.ledger); assert.is_nil(g.ordersSnapshot); assert.is_nil(g.orderBoards)
    assert.same({ errors = {}, mismatches = {} }, g.diagnostics); assert.same({ nextID = 1, list = {} }, g.captures)
    assert.same({}, g.characters); assert.same({ items = {} }, g.warband); assert.same({}, g.schematics)
  end)
  it("flushes errors logged before boot into diagnostics.errors", function()
    ns.FS:LogError("X", "e")
    W.boot()
    assert.equals("e", ns.FS.db.global.diagnostics.errors[1].err)
    assert.equals("X", ns.FS.db.global.diagnostics.errors[1].source)
    assert.equals(0, #ns.FS.pendingErrors)
  end)
  it("puts stored errors first, then pre-boot errors, in order", function()
    _G.FabricationStationDB = { global = { diagnostics = { errors = { { err = "old" } } } } }
    ns.FS:LogError("X", "e1"); ns.FS:LogError("X", "e2")
    W.boot()
    local errs = ns.FS.db.global.diagnostics.errors
    assert.same({ "old", "e1", "e2" }, { errs[1].err, errs[2].err, errs[3].err })
  end)
  it("stays capped at 50 after the flush, dropping the oldest", function()
    _G.FabricationStationDB = { global = { diagnostics = { errors = { { err = "old" } } } } }
    for i = 1, 55 do ns.FS:LogError("X", "e" .. i) end
    W.boot()
    local errs = ns.FS.db.global.diagnostics.errors
    assert.equals(50, #errs); assert.equals("e55", errs[50].err); assert.equals("e6", errs[1].err)
  end)
  it("writes nothing to a newer database, keeping errors in memory", function()
    _G.FabricationStationDB = { global = { schemaVersion = 999 } }
    ns.FS:LogError("X", "before")
    W.boot()
    ns.FS:LogError("X", "after")
    local g = ns.FS.db.global
    assert.same({}, g.diagnostics.errors); assert.same({}, g.settings.modules); assert.equals(999, g.schemaVersion)
    assert.equals(2, #ns.FS.pendingErrors); assert.equals("before", ns.FS.pendingErrors[1].err)
    assert.equals("after", ns.FS.pendingErrors[2].err)
    assert.equals(1, #W.printed); assert.matches("newer version", W.printed[1])
  end)
  describe("with a save from a newer version", function()
    local function copy(v)
      if type(v) ~= "table" then return v end
      local out = {}; for k, x in pairs(v) do out[k] = copy(x) end; return out
    end

    it("leaves the real saved table untouched, even after logout stripping", function()
      local saved = { global = { schemaVersion = 999, future = { x = 1 },
        settings = { prices = { staleAfterDays = 3 }, minimap = { hide = false }, window = { width = 900 } } } }
      local before = copy(saved)
      _G.FabricationStationDB = saved
      W.boot(); W.logout()
      assert.is_true(ns.FS.dbIsNewer)
      assert.equals(saved, _G.FabricationStationDB); assert.same(before, saved)
    end)
    it("works on an in-memory copy with the defaults filled in", function()
      _G.FabricationStationDB = { global = { schemaVersion = 999, future = { x = 1 }, settings = { prices = { staleAfterDays = 7 } } } }
      W.boot()
      local g = ns.FS.db.global
      assert.is_not.equals(_G.FabricationStationDB.global, g)
      assert.equals(999, g.schemaVersion); assert.equals(1, g.future.x); assert.equals(7, g.settings.prices.staleAfterDays)
      assert.equals(900, g.settings.window.width); assert.same({}, g.characters)
      g.future.x = 2; assert.equals(1, _G.FabricationStationDB.global.future.x)
    end)
    it("still hands a current save to AceDB itself", function()
      _G.FabricationStationDB = { global = { schemaVersion = 1, future = { x = 1 } } }
      W.boot()
      assert.is_nil(ns.FS.dbIsNewer); assert.equals(_G.FabricationStationDB.global, ns.FS.db.global)
    end)
    it("treats a non-numeric stored version as not newer", function()
      _G.FabricationStationDB = { global = { schemaVersion = "x" } }
      W.boot()
      assert.is_nil(ns.FS.dbIsNewer); assert.equals(_G.FabricationStationDB.global, ns.FS.db.global)
    end)
  end)
  it("keeps the in-memory buffer capped at 50 on a newer database", function()
    _G.FabricationStationDB = { global = { schemaVersion = 999 } }
    W.boot()
    for i = 1, 55 do ns.FS:LogError("X", "e" .. i) end
    assert.equals(50, #ns.FS.pendingErrors); assert.same({}, ns.FS.db.global.diagnostics.errors)
  end)
  it("runs migrations before flushing pending errors", function()
    ns.FS:LogError("X", "pre")
    ns.Migrations.Register(ns.Migrations.Latest() + 1, function() error("bad") end)
    W.boot()
    local errs = ns.FS.db.global.diagnostics.errors
    assert.equals("pre", errs[1].err); assert.equals("Migrations", errs[2].source)
  end)
  it("does not share default tables between boots", function()
    W.boot(); ns.FS.db.global.queue.entries[1] = "x"
    assert.same({}, ns.DBDefaults.global.queue.entries)
  end)
end)
