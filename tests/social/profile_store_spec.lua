-- Social.ProfileStore: the compact stored shape of guildmates' profiles (packed recipe strings per skill line), the
-- phase-4 keyed copy's conversion, the reads (Each, Find, Count) and the per-guild cap (Evict, MigrateDirectory).
describe("Social.ProfileStore", function()
  local ns, PS
  before_each(function()
    install_wow_stubs()
    ns = load_addon({}, "Core/DB.lua")
    load_files(ns, { "Modules/Social/Util.lua", "Modules/Social/Protocol.lua", "Modules/Social/ProfileStore.lua" })
    PS = ns.Social.ProfileStore
  end)

  local function keys(t)
    local k = {}
    for n in pairs(t) do k[#k + 1] = n end
    table.sort(k)
    return k
  end

  it("caps a guild at 300 stored profiles", function()
    assert.are.equal(300, PS.MAX_PER_GUILD)
  end)

  it("packs a quality DATA: lines by s, last line and last recipe win, ids ascending", function()
    local msg = { t = "D", p = 1, c = "B-Realm", h = "00000001", ts = 5, lv = "q", pr = {
      { s = 2907, k = 1, m = 10, r = { 100, 1, 1 } },
      { s = 2906, k = 7, m = 50, r = { 300, 0, 2 } },
      { s = 2907, k = 50, m = 100, r = { 101, 2, 4, 100, 3, 5, 100, 4, 5 } } } }
    assert.are.same({ { s = 2906, k = 7, m = 50, r = ",300:02," },
      { s = 2907, k = 50, m = 100, r = ",100:45,101:24," } }, PS.FromData(msg))
  end)

  it("packs a recipes-only DATA and an empty line", function()
    assert.are.same({ { s = 1, k = 0, m = 0, r = "," }, { s = 2, k = 1, m = 2, r = ",7,9," } },
      PS.FromData({ lv = "r", pr = { { s = 2, k = 1, m = 2, r = { 9, 7, 9 } }, { s = 1, k = 0, m = 0, r = {} } } }))
  end)

  it("reads entries back in id order and finds one recipe", function()
    local p = { lv = "q", pr = { { s = 2906, k = 7, m = 50, r = ",300:02," },
      { s = 2907, k = 50, m = 100, r = ",100:45,101:24," } } }
    local seen = {}
    PS.Each(p.pr[2], "q", function(id, q, qc) seen[#seen + 1] = { id, q, qc } end)
    assert.are.same({ { 100, 4, 5 }, { 101, 2, 4 } }, seen)
    assert.are.same({ 2, 2, 4 }, { PS.Find(p, 101) })
    assert.is_nil((PS.Find(p, 10)))                    -- "10" is a prefix of "100": no false hit
    assert.are.equal(3, PS.Count(p))
  end)

  it("reads a recipes-only profile with zero qualities", function()
    local p = { lv = "r", pr = { { s = 1, k = 0, m = 0, r = "," }, { s = 2, k = 1, m = 2, r = ",7,9," } } }
    local seen = {}
    PS.Each(p.pr[2], "r", function(id, q, qc) seen[#seen + 1] = { id, q, qc } end)
    assert.are.same({ { 7, 0, 0 }, { 9, 0, 0 } }, seen)
    assert.are.same({ 2, 0, 0 }, { PS.Find(p, 9) })
    assert.is_nil((PS.Find(p, 79)))
    assert.is_nil((PS.Find(p, 0))); assert.is_nil((PS.Find(p, "7")))
    assert.are.equal(2, PS.Count(p))
  end)

  it("skips malformed packed entries and never raises on junk", function()
    local seen = {}
    PS.Each({ r = ",100:45,x:12,101:9,102:3,10000001:11,103:21," }, "q", function(id) seen[#seen + 1] = id end)
    assert.are.same({ 100, 103 }, seen)
    for _, junk in ipairs({ nil, 5, {}, { r = 5 }, { r = {} } }) do
      assert.has_no.errors(function() PS.Each(junk, "q", function() end) end)
    end
    assert.is_nil((PS.Find({ pr = "junk" }, 100))); assert.is_nil((PS.Find({}, 100)))
    assert.is_nil((PS.Find({ lv = "q", pr = { "junk", { r = 5 }, { r = ",100:9x," } } }, 100)))
    assert.has_no.errors(function() PS.Count("junk"); PS.Count({ lv = "q", pr = { "junk" } }) end)
    assert.are.equal(0, PS.Count({ lv = "x", pr = { { r = ",100:11," } } }))
  end)

  it("converts the phase-4 keyed copy, dropping what cannot be read", function()
    local lines = { [2907] = { k = 50, m = 100, recipes = { [100] = true, [101] = true, x = true },
      q = { [100] = 3, [101] = 9 }, qc = { [100] = 5 } }, [0] = { k = 1, m = 1, recipes = {} }, [2906] = "junk" }
    assert.are.same({ { s = 2907, k = 50, m = 100, r = ",100:35,101:00," } }, PS.FromLegacy(lines, "q"))
    assert.are.same({ { s = 2907, k = 50, m = 100, r = ",100,101," } }, PS.FromLegacy(lines, "r"))
    assert.is_nil(PS.FromLegacy("junk", "q"))
  end)

  it("evicts the least recently seen beyond the cap, never the kept one, ties by name", function()
    local profiles = { A = { rt = 10 }, B = { rt = 5 }, C = { rt = 5 }, D = { rt = 1 } }
    assert.are.same({ "B", "C" }, PS.Evict(profiles, 2, "D"))
    assert.are.same({ "A", "D" }, keys(profiles))
  end)

  it("evicts nothing at or under the cap and never raises on junk entries", function()
    local profiles = { A = { rt = 1 }, B = "junk" }
    assert.are.same({}, PS.Evict(profiles, 2))
    assert.are.same({ "B" }, PS.Evict(profiles, 1))
    assert.are.same({ "A" }, keys(profiles))
    assert.has_no.errors(function() PS.Evict("junk", 1); PS.Evict({ [1] = { rt = 1 }, x = { rt = 2 } }, 1) end)
  end)

  it("migrates every guild's profiles and counts what it did", function()
    local dirs = { G = { profiles = {
      A = { lv = "r", rt = 1, lines = { [5] = { k = 1, m = 1, recipes = { [9] = true } } } },
      B = { lv = "q", rt = 2, pr = { { s = 1, k = 1, m = 1, r = ",9:00," } } },
      C = { lv = "x", rt = 3, lines = {} },
      D = 7 } }, H = "junk", I = { profiles = "junk" } }
    assert.are.same({ converted = 1, dropped = 2, evicted = 0 }, PS.MigrateDirectory(dirs))
    assert.are.same({ { s = 5, k = 1, m = 1, r = ",9," } }, dirs.G.profiles.A.pr)
    assert.is_nil(dirs.G.profiles.A.lines)
    assert.are.same({ "A", "B" }, keys(dirs.G.profiles))
    assert.are.equal("junk", dirs.H); assert.are.equal("junk", dirs.I.profiles)
    assert.has_no.errors(function() PS.MigrateDirectory("junk") end)
  end)
end)
