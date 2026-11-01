-- Upgrading phase-4 SavedVariables end to end: a schemaVersion 1 file with keyed guildmate profiles ("lines") is booted
-- through the real migration 2 (Core/Migrations.lua, ProfileStore.MigrateDirectory) and read back through the real Guild
-- (HELLO, GetCrafters with the index ticks, the Guild tab's rows, the per-guild cap on a new DATA). Scanner is a fake.
local SOCIAL_FILES = { "Modules/Social/Util.lua", "Modules/Social/Gate.lua", "Modules/Social/Codec.lua",
  "Modules/Social/Protocol.lua", "Modules/Social/ProfileStore.lua", "Modules/Social/Comm.lua",
  "Modules/Social/ItemIndex.lua", "Modules/Social/RecipeIndex.lua", "Modules/Social/Guild.lua",
  "Modules/Social/GuildNative.lua", "Modules/Social/GuildDirectory.lua", "Modules/Social/ChatMatcher.lua" }

describe("upgrading phase-4 SavedVariables end to end", function()
  local ns, p4, Guild, Protocol, sv
  local NAMES = { [100] = "Everforged Mace", [101] = "Everforged Axe" }
  local BOOT = 1700000000                         -- the stubs' clock at boot: the profiles must be younger than 30 days
  local PB = { c = "B-Realm", ts = 1000, lv = "q", pr = { { s = 2907, k = 50, m = 100, r = { 100, 3, 5, 101, 2, 4 } } } }

  local function dir() return Guild:GetDirectory() end
  local function count(n) local c = 0; for _ in pairs(n) do c = c + 1 end; return c end
  local function names(rows)
    local out = {}
    for i, r in ipairs(rows) do out[i] = r.name end
    return out
  end
  local function key_of(i) return ("F%03d-Realm"):format(i) end
  local function ticks() for _ = 1, 25 do p4.advance(0) end end
  local function sent(t)
    local n = 0
    for _, s in ipairs(p4.comm.sent) do
      if (Protocol.Unwire(s.text)).t == t then n = n + 1 end
    end
    return n
  end

  before_each(function()
    -- The phase-4 file: B-Realm (the one under test) and 300 older recipes-only profiles, all in the keyed shape.
    -- B-Realm's h is the hash it was received with (a pure function of the wire shape).
    local hash = boot_phase4({ "Modules/Social/Util.lua", "Modules/Social/Protocol.lua" }).Social.Protocol.HashProfile(PB)
    local profiles = {
      ["B-Realm"] = { c = "B-Realm", ts = 1000, lv = "q", h = hash, owner = "Peer-Realm", verified = false, rt = BOOT - 1000,
        lines = { [2907] = { k = 50, m = 100, recipes = { [100] = true, [101] = true }, q = { [100] = 3, [101] = 2 },
          qc = { [100] = 5, [101] = 4 } } } },
    }
    for i = 1, 300 do
      profiles[key_of(i)] = { c = key_of(i), ts = 1, lv = "r", h = "0000" .. ("%04x"):format(i), owner = "Peer-Realm",
        verified = false, rt = BOOT - 400000 + i, lines = { [2907] = { k = 1, m = 10, recipes = { [900 + i] = true } } } }
    end
    sv = { global = { schemaVersion = 1, guildDirectory = { ["G-Realm"] = { members = {}, profiles = profiles,
      native = {}, contested = {} } } } }
    local W
    ns, W, p4 = boot_phase4(SOCIAL_FILES, { last = "UI/Tooltips.lua", stubs = { FabricationStationDB = sv } })
    Protocol = ns.Social.Protocol
    C_Spell.GetSpellName = function(id) return NAMES[id] end
    p4.fake_module(ns, "Scanner", {
      GetCharacters = function() return {} end,
      GetCharacter = function() return { professions = {} } end,
      GetCachedSchematic = function() return nil end,
    })
    Guild = ns.FS:GetModule("Guild")
    p4.guild.key = { "G", "Realm" }
    p4.guild.members = { { name = "Peer-Realm", online = true }, { name = "New-Realm", online = true } }
    Guild:OnGuildUpdate()
    W.fire("PLAYER_ENTERING_WORLD", true, false)
    p4.advance(21)
    for i = #p4.comm.sent, 1, -1 do p4.comm.sent[i] = nil end
  end)

  it("migrates, keeps the hash so a HELLO requests nothing, and every reader sees the compact shape", function()
    -- the boot already ran migration 2 on the file
    local g = ns.FS.db.global
    assert.are.equal(2, g.schemaVersion)
    local d = g.guildDirectory["G-Realm"]
    local b = d.profiles["B-Realm"]
    assert.are.same({ { s = 2907, k = 50, m = 100, r = ",100:35,101:24," } }, b.pr)
    assert.is_nil(b.lines)
    assert.are.equal(Protocol.HashProfile(PB), b.h)
    assert.are.equal(300, count(d.profiles))
    assert.is_nil(d.profiles[key_of(1)])                          -- the oldest went
    assert.is_table(d.profiles[key_of(2)])

    local function crafter()
      local rows = Guild:GetCrafters(100)
      assert.are.same({ "B-Realm" }, names(rows))
      return rows[1]
    end
    assert.are.same({ 3, 5 }, { crafter().expectedQuality, crafter().concentrationQuality })
    Guild:RebuildItemIndex(); ticks()
    assert.are.same({ 3, 5 }, { crafter().expectedQuality, crafter().concentrationQuality })

    ns.GameData.Define("RecipeSources", nil, { bySkillLine = {} })
    local _, meta = Guild:BuildTabRows({ text = "everforged" })
    assert.are.equal("name", meta.kind)

    -- last: this HELLO lists only B-Realm, so Peer-Realm's other copies go
    Guild:OnHello(Protocol.Hello("1.0.0", { ["B-Realm"] = Protocol.HashProfile(PB) }), "Peer-Realm", "GUILD")
    assert.are.equal(0, sent("Q"))
  end)

  it("evicts the next-oldest at the cap when a new DATA arrives", function()
    Guild:RebuildItemIndex(); ticks()
    assert.are.same({ key_of(2) }, names(Guild:GetCrafters(902)))
    local before = Guild.stats.evicted
    -- from another guildmate: a HELLO that left the other characters out would drop Peer-Realm's copies
    local PN = { c = "N-Realm", ts = 5, lv = "r", pr = { { s = 2907, k = 10, m = 100, r = { 100 } } } }
    Guild:OnHello(Protocol.Hello("1.0.0", { ["N-Realm"] = Protocol.HashProfile(PN) }), "New-Realm", "GUILD")
    Guild:OnData(Protocol.Data(PN), "New-Realm", "WHISPER")
    assert.are.equal(before + 1, Guild.stats.evicted)
    assert.are.equal(300, count(dir().profiles))
    assert.is_nil(dir().profiles[key_of(2)])
    assert.are.same({}, Guild:GetCrafters(902))
  end)
end)
