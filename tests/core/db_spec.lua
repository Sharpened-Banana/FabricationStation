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
    assert.same({ entries = {} }, g.ledger); assert.same({ orders = {} }, g.ordersSnapshot)
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
  it("keeps the in-memory buffer capped at 50 on a newer database", function()
    _G.FabricationStationDB = { global = { schemaVersion = 999 } }
    W.boot()
    for i = 1, 55 do ns.FS:LogError("X", "e" .. i) end
    assert.equals(50, #ns.FS.pendingErrors); assert.same({}, ns.FS.db.global.diagnostics.errors)
  end)
  it("runs migrations before flushing pending errors", function()
    ns.FS:LogError("X", "pre")
    ns.Migrations.Register(2, function() error("bad") end)
    W.boot()
    local errs = ns.FS.db.global.diagnostics.errors
    assert.equals("pre", errs[1].err); assert.equals("Migrations", errs[2].source)
  end)
  it("does not share default tables between boots", function()
    W.boot(); ns.FS.db.global.queue.entries[1] = "x"
    assert.same({}, ns.DBDefaults.global.queue.entries)
  end)
end)
