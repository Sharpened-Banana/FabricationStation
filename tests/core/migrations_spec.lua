describe("Migrations", function()
  local W, ns, base
  before_each(function()
    W = install_wow_stubs()
    ns = load_addon({}, "Core/DB.lua")
    base = ns.Migrations.Latest()
  end)

  it("schemaVersion is never an AceDB default", function() assert.is_nil(ns.DBDefaults.global.schemaVersion) end)
  it("migrates a fresh DB to Latest", function() W.boot(); assert.equals(ns.Migrations.Latest(), ns.FS.db.global.schemaVersion) end)
  it("runs migrations in ascending order regardless of registration order", function()
    local seen = {}
    ns.Migrations.Register(base + 2, function() table.insert(seen, base + 2) end)
    ns.Migrations.Register(base + 1, function() table.insert(seen, base + 1) end)
    W.boot(); assert.same({ base + 1, base + 2 }, seen); assert.equals(base + 2, ns.FS.db.global.schemaVersion)
  end)
  it("preserves existing character data across migration", function()
    _G.FabricationStationDB = { global = { characters = { ["A-B"] = { gold = 5 } } } }
    W.boot(); assert.equals(5, ns.FS.db.global.characters["A-B"].gold)
  end)
  it("stops at a failing migration without bumping past it", function()
    ns.Migrations.Register(base + 1, function() error("bad") end)
    local ok, from, to, err = ns.Migrations.Run({ schemaVersion = base })
    assert.is_false(ok); assert.equals(base, from); assert.equals(base, to); assert.matches("bad", err)
  end)
  it("keeps the last successful version when a later migration fails", function()
    local ran = {}
    ns.Migrations.Register(base + 1, function() table.insert(ran, base + 1) end)
    ns.Migrations.Register(base + 2, function() error("bad3") end)
    ns.Migrations.Register(base + 3, function() table.insert(ran, base + 3) end)
    local g = {}
    local ok, from, to, err = ns.Migrations.Run(g)
    assert.is_false(ok); assert.equals(0, from); assert.equals(base + 1, to); assert.matches("bad3", err)
    assert.equals(base + 1, g.schemaVersion); assert.same({ base + 1 }, ran)
  end)
  it("logs a failed migration to diagnostics at boot", function()
    ns.Migrations.Register(base + 1, function() error("bad") end)
    W.boot()
    assert.equals(base, ns.FS.db.global.schemaVersion)
    assert.equals("Migrations", ns.FS.db.global.diagnostics.errors[1].source)
    assert.matches("bad", ns.FS.db.global.diagnostics.errors[1].err)
  end)
  it("leaves a newer database untouched and flags it", function()
    _G.FabricationStationDB = { global = { schemaVersion = 999 } }
    W.boot(); assert.equals(999, ns.FS.db.global.schemaVersion); assert.is_true(ns.FS.dbIsNewer)
    assert.matches("newer version", W.printed[1])
    assert.equals("FabricationStation: saved data is from a newer version; nothing was changed.", W.printed[1])
  end)
  it("Run on a newer database returns false, from, from, newer and runs nothing", function()
    local ran = false
    ns.Migrations.Register(base + 1, function() ran = true end)
    local g = { schemaVersion = 50 }
    local ok, from, to, err = ns.Migrations.Run(g)
    assert.is_false(ok); assert.equals(50, from); assert.equals(50, to); assert.equals("newer", err)
    assert.is_false(ran); assert.equals(50, g.schemaVersion)
  end)
  it("rejects a non-number schemaVersion without throwing or changing anything", function()
    for _, bad in ipairs({ "2", true, {} }) do
      local g = { schemaVersion = bad }
      local ok, from, to, err
      assert.has_no.errors(function() ok, from, to, err = ns.Migrations.Run(g) end)
      assert.is_false(ok); assert.equals(bad, from); assert.equals(bad, to); assert.equals("bad schemaVersion", err)
      assert.equals(bad, g.schemaVersion)
    end
  end)
  it("logs a non-number schemaVersion at boot and leaves it alone", function()
    _G.FabricationStationDB = { global = { schemaVersion = "2" } }
    assert.has_no.errors(function() W.boot() end)
    assert.equals("2", ns.FS.db.global.schemaVersion)
    assert.equals("Migrations", ns.FS.db.global.diagnostics.errors[1].source)
    assert.is_nil(ns.FS.dbIsNewer)
  end)
  it("does not flag an up-to-date database", function()
    W.boot(); assert.is_nil(ns.FS.dbIsNewer); assert.equals(0, #W.printed)
  end)
  it("rejects duplicate versions", function() assert.has_error(function() ns.Migrations.Register(1, function() end) end) end)
  it("rejects non-positive-integer versions and non-function handlers", function()
    for _, v in ipairs({ 0, -1, 1.5, "2", false }) do
      assert.has_error(function() ns.Migrations.Register(v, function() end) end)
    end
    assert.has_error(function() ns.Migrations.Register(9, "nope") end)
  end)
  it("Latest is the highest registered version", function()
    assert.equals(2, ns.Migrations.Latest()); ns.Migrations.Register(base + 4, function() end)
    assert.equals(base + 4, ns.Migrations.Latest())
  end)

  describe("migration 2", function()
    before_each(function()
      load_files(ns, { "Modules/Social/Util.lua", "Modules/Social/Protocol.lua", "Modules/Social/ProfileStore.lua" })
    end)

    it("migrates legacy, junk and already compact profiles without raising", function()
      _G.FabricationStationDB = { global = { schemaVersion = 1, guildDirectory = {
        ["G-Realm"] = { members = { ["P-Realm"] = { lastSeen = 9 } }, contested = {}, native = { [5] = { time = 1 } },
          profiles = {
            ["A-Realm"] = { c = "A-Realm", ts = 1, lv = "q", h = "0000000a", owner = "P-Realm", verified = true, rt = 7,
              lines = { [2907] = { k = 5, m = 9, recipes = { [100] = true }, q = { [100] = 3 }, qc = { [100] = 4 } } } },
            ["B-Realm"] = { c = "B-Realm", lv = "r", h = "0000000b", owner = "P-Realm", rt = 8,
              pr = { { s = 1, k = 1, m = 1, r = ",9," } } },
            ["C-Realm"] = { lv = "q", lines = "junk" },
            ["D-Realm"] = "junk" } },
        ["Other-Realm"] = "junk" } } }
      W.boot()
      local g = ns.FS.db.global
      assert.are.equal(2, g.schemaVersion)
      local dir = g.guildDirectory["G-Realm"]
      assert.are.same({ { s = 2907, k = 5, m = 9, r = ",100:34," } }, dir.profiles["A-Realm"].pr)
      assert.is_nil(dir.profiles["A-Realm"].lines)
      assert.are.equal("0000000a", dir.profiles["A-Realm"].h)                  -- the received hash is kept
      assert.are.same({ c = "A-Realm", ts = 1, lv = "q", h = "0000000a", owner = "P-Realm", verified = true, rt = 7,
        pr = { { s = 2907, k = 5, m = 9, r = ",100:34," } } }, dir.profiles["A-Realm"])
      assert.are.same({ { s = 1, k = 1, m = 1, r = ",9," } }, dir.profiles["B-Realm"].pr)   -- already compact: untouched
      assert.is_nil(dir.profiles["C-Realm"]); assert.is_nil(dir.profiles["D-Realm"])
      assert.are.same({ ["P-Realm"] = { lastSeen = 9 } }, dir.members)       -- everything else is left alone
      assert.are.same({ [5] = { time = 1 } }, dir.native)
      assert.are.equal("junk", g.guildDirectory["Other-Realm"])
      assert.same({}, g.diagnostics.errors)
    end)

    it("applies the per-guild cap while migrating", function()
      local profiles = {}
      for i = 1, 302 do
        profiles["A" .. i .. "-Realm"] = { c = "A" .. i .. "-Realm", ts = 1, lv = "r", h = "00000001", owner = "P-Realm",
          rt = i, lines = { [1] = { k = 1, m = 1, recipes = { [100] = true } } } }
      end
      _G.FabricationStationDB = { global = { schemaVersion = 1, guildDirectory = { ["G-Realm"] = { profiles = profiles } } } }
      W.boot()
      local stored = ns.FS.db.global.guildDirectory["G-Realm"].profiles
      assert.is_nil(stored["A1-Realm"]); assert.is_nil(stored["A2-Realm"])
      local n = 0
      for _ in pairs(stored) do n = n + 1 end
      assert.are.equal(300, n)
      assert.are.same({ { s = 1, k = 1, m = 1, r = ",100," } }, stored["A3-Realm"].pr)
    end)

    it("does nothing on a database without guild data", function()
      W.boot(); assert.is_nil(rawget(ns.FS.db.global, "guildDirectory")); assert.are.equal(2, ns.FS.db.global.schemaVersion)
    end)

    it("leaves a newer database alone", function()
      _G.FabricationStationDB = { global = { schemaVersion = 999, guildDirectory = { G = { profiles = { A = { lines = {} } } } } } }
      W.boot(); assert.is_table(ns.FS.db.global.guildDirectory.G.profiles.A.lines)
    end)

    it("stays at version 1 and logs when the profile store is missing", function()
      ns.Social.ProfileStore = nil
      _G.FabricationStationDB = { global = { schemaVersion = 1, guildDirectory = { G = { profiles = { A = { lines = {} } } } } } }
      W.boot()
      assert.are.equal(1, ns.FS.db.global.schemaVersion)
      assert.is_table(ns.FS.db.global.guildDirectory.G.profiles.A.lines)
      assert.equals("Migrations", ns.FS.db.global.diagnostics.errors[1].source)
    end)
  end)
end)
