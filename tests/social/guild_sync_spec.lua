-- Guild: own crafting profiles, privacy settings, HELLO/REQ/DATA delta sync over guild addon messages, peer storage
-- and pruning. Scanner and Recipes are p4.fake_module fakes; the AceComm, guild roster and encoding fakes are the
-- phase-4 harness ones (p4.comm, p4.guild, the reversible C_EncodingUtil).
local SOCIAL_FILES = { "Modules/Social/Util.lua", "Modules/Social/Gate.lua", "Modules/Social/Codec.lua",
  "Modules/Social/Protocol.lua", "Modules/Social/ProfileStore.lua", "Modules/Social/Comm.lua", "Modules/Social/Guild.lua" }
local DAY = 86400

describe("Guild sync", function()
  local ns, W, p4, Guild, Protocol, Codec, settings, evaluate_spy, chars

  -- Four characters in 1a's CharacterRecord shape. Current-expansion lines carry a concentration or spec snapshot
  -- (the rule without Knowledge data); 2477 is an older-expansion line and 2908 a dropped one.
  local function fixture_chars()
    return {
      ["Me-Realm"] = { professions = {
        [2907] = { name = "Blacksmithing", skill = 50, maxSkill = 100, recipes = { [101] = true, [100] = true },
          concentration = { value = 1, max = 1000 } },
        [2477] = { name = "Old Blacksmithing", skill = 75, maxSkill = 75, recipes = { [900] = true } },
        [2908] = { name = "Dropped", skill = 1, maxSkill = 100, recipes = { [950] = true }, dropped = true,
          concentration = { value = 1, max = 1000 } },
      } },
      ["Alt-Realm"] = { professions = {
        [2906] = { name = "Alchemy", skill = 10, maxSkill = 100, recipes = { [200] = true }, concentration = {} },
      } },
      ["Far-Realm"] = { professions = {
        [2909] = { name = "Enchanting", skill = 5, maxSkill = 100, recipes = { [300] = true }, spec = {} },
      } },
      ["Bare-Realm"] = { professions = {
        [2480] = { name = "Old Alchemy", skill = 75, maxSkill = 75, recipes = { [990] = true } },
      } },
    }
  end

  local function sorted(t)
    local out = {}
    for i, v in ipairs(t) do out[i] = v end
    table.sort(out)
    return out
  end

  local function slice(t, i, j)
    local out = {}
    for k = i, j do out[#out + 1] = t[k] end
    return out
  end

  local function merge(a, b)
    local out = {}
    for k, v in pairs(a) do out[k] = v end
    for k, v in pairs(b) do out[k] = v end
    return out
  end

  local function sent_list()
    local out = {}
    for _, s in ipairs(p4.comm.sent) do
      out[#out + 1] = { msg = (Protocol.Unwire(s.text)), dist = s.distribution, target = s.target, prio = s.prio,
        bytes = #s.text }
    end
    return out
  end
  local function last_sent() local l = sent_list(); return l[#l] end
  local function last_sent_msg() return last_sent().msg end
  local function count_sent(t, dist)
    local n = 0
    for _, s in ipairs(sent_list()) do
      if s.msg.t == t and (dist == nil or s.dist == dist) then n = n + 1 end
    end
    return n
  end
  local function clear_sent() for i = #p4.comm.sent, 1, -1 do p4.comm.sent[i] = nil end end

  local function dir() return Guild:GetDirectory() end
  local function store_profile(charKey, h, owner)
    dir().profiles[charKey] = { c = charKey, ts = 0, lv = "r", h = h, owner = owner, rt = ns.FS:Now(), pr = {} }
  end

  local PB = { c = "B-Realm", ts = 1000, lv = "q", pr = { { s = 2907, k = 50, m = 100, r = { 100, 3, 5, 101, 2, 4 } } } }
  local function as_recipes_only(p)
    local pr = {}
    for i, line in ipairs(p.pr) do
      local r = {}
      for j = 1, #line.r, 3 do r[#r + 1] = line.r[j] end
      pr[i] = { s = line.s, k = line.k, m = line.m, r = r }
    end
    return { c = p.c, ts = p.ts, lv = "r", pr = pr }
  end
  local function seed_peer_with_profile(sender, p)
    Guild:OnHello(Protocol.Hello("1.0.0", { [p.c] = Protocol.HashProfile(p) }), sender, "GUILD")
    Guild:OnData(Protocol.Data(p), sender, "WHISPER")
  end

  local function boot(opts)
    opts = opts or {}
    ns, W, p4 = boot_phase4(SOCIAL_FILES)
    Protocol, Codec = ns.Social.Protocol, ns.Social.Codec
    chars = fixture_chars()
    p4.fake_module(ns, "Scanner", {
      GetCharacters = function()
        local keys = {}
        for k in pairs(chars) do keys[#keys + 1] = k end
        table.sort(keys)
        return keys
      end,
      GetCharacter = function(_, key) return chars[key] end,
    })
    evaluate_spy = spy.new(function(_, _, _, o) return { expectedQuality = o.useConcentration and 5 or 3 } end)
    p4.fake_module(ns, "Recipes", { Evaluate = evaluate_spy })
    ns.FS.db.global.guildMyChars = { ["Alt-Realm"] = "G-Realm", ["Far-Realm"] = "Other-Realm" }
    Guild = ns.FS:GetModule("Guild")
    settings = Guild:Settings()
    if opts.guild ~= false then p4.guild.key = { "G", "Realm" } end
    if opts.login ~= false then
      W.fire("PLAYER_ENTERING_WORLD", true, false)
      p4.advance(21)        -- the login refresh and the jittered (5-20 s) login HELLO
      clear_sent()
    end
  end

  before_each(function() boot() end)

  ---------------------------------------------------------------------------
  -- Own profiles
  ---------------------------------------------------------------------------

  describe("own profiles", function()
    it("builds quality profiles via Recipes:Evaluate and recipes-only profiles without it", function()
      local p = Guild:BuildProfile("Me-Realm")
      assert.are.equal("q", p.lv); assert.are.same({ 100, 3, 5 }, slice(p.pr[1].r, 1, 3))
      settings.shareLevel = "recipes"; evaluate_spy:clear()
      p = Guild:BuildProfile("Me-Realm")
      assert.are.equal("r", p.lv); assert.are.same({ 100 }, slice(p.pr[1].r, 1, 1))
      assert.spy(evaluate_spy).was_not_called()
    end)

    it("calls Evaluate once plain and once with concentration per recipe", function()
      evaluate_spy:clear()
      Guild:BuildProfile("Me-Realm")
      assert.spy(evaluate_spy).was_called(4)
      assert.spy(evaluate_spy).was_called_with(match._, 100, "Me-Realm", {})
      assert.spy(evaluate_spy).was_called_with(match._, 100, "Me-Realm", { useConcentration = true })
    end)

    it("uses current-expansion, non-dropped lines only and passes Validate", function()
      local p = Guild:BuildProfile("Me-Realm")
      assert.are.equal(1, #p.pr)
      assert.are.same({ s = 2907, k = 50, m = 100, r = { 100, 3, 5, 101, 3, 5 } }, p.pr[1])
      assert.are.equal("Me-Realm", p.c)
      assert.is_true((Protocol.Validate(Protocol.Data(p))))
      assert.is_nil(Guild:BuildProfile("Bare-Realm"))
    end)

    it("prefers Knowledge.variants when the table exists, still skipping dropped lines", function()
      local GD = { defs = {} }
      ns.GameData = { Get = function(name) return GD.defs[name] end }
      GD.defs.Knowledge = { variants = { [2480] = { base = 171 }, [2908] = { base = 164 } } }
      local p = Guild:BuildProfile("Bare-Realm")
      assert.are.same({ 2480 }, { p.pr[1].s })
      -- Me-Realm's 2907 has a snapshot but no variant entry and no variant sibling: still listed (Alts' rule).
      assert.are.same({ 2907 }, { Guild:BuildProfile("Me-Realm").pr[1].s })
    end)

    it("caps the profile at the protocol's line limit", function()
      local profs = {}
      for i = 1, 9 do profs[3000 + i] = { skill = 1, maxSkill = 10, recipes = { [i] = true }, concentration = {} } end
      chars["Many-Realm"] = { professions = profs }
      local p = Guild:BuildProfile("Many-Realm")
      assert.are.equal(Protocol.LIMITS.MAX_LINES, #p.pr)
      assert.is_true((Protocol.Validate(Protocol.Data(p))))
    end)

    it("clamps skill so k <= m and treats a missing or bad quality as 0", function()
      chars["Odd-Realm"] = { professions = { [2907] = { skill = 120, maxSkill = 100, recipes = { [7] = true },
        concentration = {} } } }
      evaluate_spy = spy.new(function(_, _, _, o) if o.useConcentration then error("boom") end return { expectedQuality = 0 / 0 } end)
      ns.FS:GetModule("Recipes").Evaluate = evaluate_spy
      local p = Guild:BuildProfile("Odd-Realm")
      assert.are.same({ s = 2907, k = 120, m = 120, r = { 7, 0, 0 } }, p.pr[1])
    end)

    it("omits quality data first when a profile would not fit MAX_WIRE", function()
      local r = {}
      for i = 1, 1000 do r[100000 + i] = true end
      chars["Big-Realm"] = { professions = { [2907] = { skill = 1, maxSkill = 100, recipes = r, concentration = {} } } }
      local p = Guild:BuildProfile("Big-Realm")
      assert.are.equal("r", p.lv)
      assert.are.equal(1000, #p.pr[1].r)
      assert.is_true(#Protocol.Wire(Protocol.Data(p)) <= Codec.MAX_WIRE)
    end)

    it("then trims recipes per line until the profile fits", function()
      local r = {}
      for i = 1, 3000 do r[100000 + i] = true end
      chars["Huge-Realm"] = { professions = { [2907] = { skill = 1, maxSkill = 100, recipes = r, concentration = {} } } }
      local p = Guild:BuildProfile("Huge-Realm")
      assert.are.equal("r", p.lv)
      assert.is_true(#p.pr[1].r > 0 and #p.pr[1].r < 3000)
      -- The lowest recipe IDs go first: the newest (highest) recipes of the expansion are kept.
      assert.are.equal(103000, p.pr[1].r[#p.pr[1].r])
      assert.are.equal(103000 - #p.pr[1].r + 1, p.pr[1].r[1])
      assert.is_true(#Protocol.Wire(Protocol.Data(p)) <= Codec.MAX_WIRE)
      assert.is_true(Guild.stats.trimmed >= 1)
    end)

    it("selects shared characters by shareAlts", function()
      -- chars: Me-Realm (in G), Alt-Realm (guildMyChars = G), Far-Realm (other guild), Bare-Realm (no current lines)
      settings.shareAlts = "current"; assert.are.same({ "Me-Realm" }, sorted(Guild:GetSharedCharKeys()))
      settings.shareAlts = "guild";   assert.are.same({ "Alt-Realm", "Me-Realm" }, sorted(Guild:GetSharedCharKeys()))
      settings.shareAlts = "all";     assert.are.same({ "Alt-Realm", "Far-Realm", "Me-Realm" }, sorted(Guild:GetSharedCharKeys()))
      settings.share = false;         assert.are.same({}, Guild:GetSharedCharKeys())
    end)

    it("records the current character's guild in guildMyChars", function()
      assert.are.equal("G-Realm", ns.FS.db.global.guildMyChars["Me-Realm"])
      assert.are.equal("G-Realm", Guild:GetGuildKey())
    end)

    it("built the shared characters' hashes at login", function()
      local hashes = Guild:GetOwnHashes()
      assert.are.same({ "Alt-Realm", "Me-Realm" }, sorted((function()
        local k = {}
        for c in pairs(hashes) do k[#k + 1] = c end
        return k
      end)()))
      assert.are.equal(Protocol.HashProfile(Guild:BuildProfile("Me-Realm")), hashes["Me-Realm"])
      assert.are.equal("q", Guild:GetOwnProfile("Me-Realm").lv)
    end)

    it("time-slices the refresh instead of evaluating everything at once", function()
      local clock = 0
      _G.debugprofilestop = function() clock = clock + 1; return clock end   -- every call costs 1 ms
      finally(function() _G.debugprofilestop = nil end)
      evaluate_spy:clear()
      assert.is_true(Guild:RefreshOwnProfiles())
      assert.spy(evaluate_spy).was_not_called()
      assert.is_true(Guild:IsRefreshing())
      assert.is_false(Guild:_RefreshStep(2))
      local first = #evaluate_spy.calls
      assert.is_true(first > 0 and first < 6)          -- Me-Realm has 2 recipes, Alt-Realm 1: 6 calls in all
      local guard = 0
      while not Guild:_RefreshStep(2) and guard < 20 do guard = guard + 1 end
      assert.spy(evaluate_spy).was_called(6)
      assert.is_false(Guild:IsRefreshing())
    end)
  end)

  ---------------------------------------------------------------------------
  -- HELLO / REQUEST / DATA
  ---------------------------------------------------------------------------

  describe("OnHello", function()
    it("requests only mismatched chars and not again within 120s", function()
      store_profile("A-Realm", "0000aaaa", "Peer-Realm")
      Guild:OnHello(Protocol.Hello("1.0.0", { ["A-Realm"] = "0000aaaa", ["B-Realm"] = "0000bbbb" }), "Peer-Realm", "GUILD")
      local q = last_sent_msg(); assert.are.equal("Q", q.t); assert.are.same({ "B-Realm" }, q.c)
      assert.are.equal("WHISPER", last_sent().dist); assert.are.equal("Peer-Realm", last_sent().target)
      Guild:OnHello(Protocol.Hello("1.0.0", { ["B-Realm"] = "0000bbbb" }), "Peer-Realm", "GUILD")
      assert.are.equal(1, count_sent("Q"))
      p4.advance(120)
      Guild:OnHello(Protocol.Hello("1.0.0", { ["B-Realm"] = "0000bbbb" }), "Peer-Realm", "GUILD")
      assert.are.equal(2, count_sent("Q"))
    end)

    it("replies to a guild HELLO with a whispered HELLO once per 10 minutes, never to a whisper HELLO", function()
      Guild:OnHello(Protocol.Hello("1.0.0", {}), "Peer-Realm", "GUILD"); p4.advance(10)
      Guild:OnHello(Protocol.Hello("1.0.0", {}), "Peer-Realm", "GUILD"); p4.advance(10)
      Guild:OnHello(Protocol.Hello("1.0.0", {}), "Other-Realm", "WHISPER"); p4.advance(10)
      assert.are.equal(1, count_sent("H", "WHISPER"))
      assert.are.equal("Peer-Realm", last_sent().target)
      assert.are.same(Guild:GetOwnHashes(), last_sent_msg().c)
      p4.advance(600)
      Guild:OnHello(Protocol.Hello("1.0.0", {}), "Peer-Realm", "GUILD"); p4.advance(10)
      assert.are.equal(2, count_sent("H", "WHISPER"))
    end)

    it("stores the member with the wire version, not the message's p field", function()
      Guild:OnHello(merge(Protocol.Hello("2.5.0", { ["B-Realm"] = "0000bbbb" }), { p = 7 }), "Peer-Realm", "GUILD")
      local m = dir().members["Peer-Realm"]
      assert.are.equal("2.5.0", m.addonVersion)
      assert.are.equal(Protocol.VERSION, m.proto)
      assert.are.equal(ns.FS:Now(), m.lastSeen)
      assert.are.same({ ["B-Realm"] = "0000bbbb" }, m.chars)
    end)

    it("ignores messages that fail Validate", function()
      Guild:OnHello({ t = "H", p = 1, v = "1", c = { ["bad key"] = "zz" } }, "Peer-Realm", "GUILD")
      assert.is_nil(dir().members["Peer-Realm"])
      assert.are.equal(0, #p4.comm.sent)
    end)

    it("never requests or stores the player's own characters", function()
      Guild:OnHello(Protocol.Hello("1.0.0", { ["Alt-Realm"] = "0000aaaa" }), "Peer-Realm", "GUILD")
      assert.are.equal(0, count_sent("Q"))
      assert.are.same({}, dir().members["Peer-Realm"].chars)
    end)

    it("contests a character two senders claim unverified: the copy goes and nothing is requested", function()
      seed_peer_with_profile("Peer-Realm", PB)                   -- B-Realm reported by Peer (unverified)
      assert.is_false(dir().profiles["B-Realm"].verified)
      Guild:OnHello(Protocol.Hello("1.0.0", { ["B-Realm"] = "0000bbbb" }), "Liar-Realm", "GUILD")
      assert.is_nil(dir().profiles["B-Realm"])
      assert.is_not_nil(dir().contested["B-Realm"])
      assert.are.equal(1, count_sent("Q"))                       -- Peer's own request only
      p4.advance(200)
      Guild:OnHello(Protocol.Hello("1.0.0", { ["B-Realm"] = Protocol.HashProfile(PB) }), "Peer-Realm", "GUILD")
      Guild:OnData(Protocol.Data(PB), "Peer-Realm", "WHISPER")
      assert.are.equal(1, count_sent("Q"))
      assert.is_nil(dir().profiles["B-Realm"])                   -- "no data", never the squatter's or a stale copy
      Guild:OnHello(Protocol.Hello("1.0.0", { ["Liar-Realm"] = "0000cccc" }), "Liar-Realm", "GUILD")
      assert.are.same({ "Liar-Realm" }, last_sent_msg().c)       -- a player may always publish their own name
      -- B-Realm logs in itself: a verified claim clears the contest.
      local PBs = merge(PB, { ts = 2 })
      Guild:OnHello(Protocol.Hello("1.0.0", { ["B-Realm"] = Protocol.HashProfile(PBs) }), "B-Realm", "GUILD")
      assert.is_nil(dir().contested["B-Realm"])
      assert.are.same({ "B-Realm" }, last_sent_msg().c)
      Guild:OnData(Protocol.Data(PBs), "B-Realm", "WHISPER")
      assert.are.equal("B-Realm", dir().profiles["B-Realm"].owner)
      assert.is_true(dir().profiles["B-Realm"].verified)
    end)

    it("turns a squat into no data when the real main claims the alt (attacker first)", function()
      local PW = { c = "W-Realm", ts = 1, lv = "q", pr = { { s = 2907, k = 1, m = 10, r = { 100, 5, 5 } } } }
      local Wreal = { c = "W-Realm", ts = 1, lv = "q", pr = { { s = 2907, k = 9, m = 10, r = { 101, 2, 3 } } } }
      Guild:OnHello(Protocol.Hello("1", { ["W-Realm"] = Protocol.HashProfile(PW) }), "A-Realm", "GUILD")
      Guild:OnData(Protocol.Data(PW), "A-Realm", "WHISPER")
      assert.are.equal("A-Realm", dir().profiles["W-Realm"].owner)
      assert.is_false(dir().profiles["W-Realm"].verified)
      local before = count_sent("Q")
      Guild:OnHello(Protocol.Hello("1", { ["V-Realm"] = "0000aaaa", ["W-Realm"] = Protocol.HashProfile(Wreal) }), "V-Realm", "GUILD")
      assert.is_nil(dir().profiles["W-Realm"])                   -- the squatted copy is gone
      assert.are.same({ "V-Realm" }, last_sent_msg().c)          -- V's own name only; W-Realm is contested
      assert.are.equal(before + 1, count_sent("Q"))
      -- The squatter's refreshing HELLOs neither restore nor re-request it.
      Guild:OnHello(Protocol.Hello("1", { ["W-Realm"] = Protocol.HashProfile(PW) }), "A-Realm", "GUILD")
      Guild:OnData(Protocol.Data(PW), "A-Realm", "WHISPER")
      assert.is_nil(dir().profiles["W-Realm"])
      -- W-Realm logs in and names V: now V's claim is verified and replaces nothing-stored.
      Guild:OnHello(Protocol.Hello("1", { ["W-Realm"] = Protocol.HashProfile(Wreal), ["V-Realm"] = "0000aaaa" }), "W-Realm", "GUILD")
      Guild:OnData(Protocol.Data(Wreal), "V-Realm", "WHISPER")
      assert.are.equal("V-Realm", dir().profiles["W-Realm"].owner)
      assert.is_true(dir().profiles["W-Realm"].verified)
      assert.are.equal(",101:23,", dir().profiles["W-Realm"].pr[1].r)
    end)

    it("lets a verified claim replace an unverified copy and keeps a verified one from unverified claims", function()
      local PW = { c = "W-Realm", ts = 1, lv = "r", pr = { { s = 2907, k = 1, m = 10, r = { 100 } } } }
      local Wself = { c = "W-Realm", ts = 1, lv = "r", pr = { { s = 2907, k = 2, m = 10, r = { 100, 101 } } } }
      Guild:OnHello(Protocol.Hello("1", { ["W-Realm"] = Protocol.HashProfile(PW) }), "A-Realm", "GUILD")
      Guild:OnData(Protocol.Data(PW), "A-Realm", "WHISPER")
      Guild:OnHello(Protocol.Hello("1", { ["W-Realm"] = Protocol.HashProfile(Wself) }), "W-Realm", "GUILD")
      Guild:OnData(Protocol.Data(Wself), "W-Realm", "WHISPER")
      assert.are.equal("W-Realm", dir().profiles["W-Realm"].owner)
      assert.is_true(dir().profiles["W-Realm"].verified)
      -- An unverified claimant can neither replace nor contest a verified copy, nor withdraw it.
      Guild:OnHello(Protocol.Hello("1", { ["W-Realm"] = Protocol.HashProfile(PW) }), "A-Realm", "GUILD")
      Guild:OnData(Protocol.Data(PW), "A-Realm", "WHISPER")
      Guild:OnHello(Protocol.Hello("1", {}), "A-Realm", "GUILD")
      assert.are.equal("W-Realm", dir().profiles["W-Realm"].owner)
      assert.is_nil(dir().contested["W-Realm"])
      -- A same-hash verified HELLO upgrades an unverified copy in place.
      local X = { c = "X-Realm", ts = 1, lv = "r", pr = { { s = 2907, k = 1, m = 10, r = { 100 } } } }
      seed_peer_with_profile("Peer-Realm", X)
      assert.is_false(dir().profiles["X-Realm"].verified)
      Guild:OnHello(Protocol.Hello("1", { ["X-Realm"] = Protocol.HashProfile(X) }), "X-Realm", "GUILD")
      assert.is_true(dir().profiles["X-Realm"].verified)
      assert.are.equal("X-Realm", dir().profiles["X-Realm"].owner)
    end)

    it("fires FS_GUILD_CHANGED at most once per second", function()
      local before = #p4.messages("FS_GUILD_CHANGED")       -- the login's own key change
      for i = 1, 5 do Guild:OnHello(Protocol.Hello("1.0.0", {}), "P" .. i .. "-Realm", "GUILD") end
      assert.are.equal(before, #p4.messages("FS_GUILD_CHANGED"))
      p4.advance(1)
      local got = p4.messages("FS_GUILD_CHANGED")
      assert.are.equal(before + 1, #got)
      assert.are.same({ "G-Realm" }, got[#got])
    end)
  end)

  describe("OnData", function()
    it("stores DATA only when hash matches content and the sender's HELLO", function()
      Guild:OnHello(Protocol.Hello("1.0.0", { ["B-Realm"] = Protocol.HashProfile(PB) }), "Peer-Realm", "GUILD")
      Guild:OnData(merge(Protocol.Data(PB), { h = "deadbeef" }), "Peer-Realm", "WHISPER")
      assert.is_nil(dir().profiles["B-Realm"])
      Guild:OnData(Protocol.Data(PB), "Liar-Realm", "WHISPER")
      assert.is_nil(dir().profiles["B-Realm"])
      Guild:OnData(Protocol.Data(PB), "Peer-Realm", "WHISPER")
      assert.are.equal("Peer-Realm", dir().profiles["B-Realm"].owner)
    end)

    it("rejects a sender that pins a hash its data does not have", function()
      -- The HELLO lists exactly the hash the DATA claims, but the content hashes to something else.
      local forged = merge(Protocol.Data(PB), { h = "0000aaaa" })
      Guild:OnHello(Protocol.Hello("1.0.0", { ["B-Realm"] = "0000aaaa" }), "Peer-Realm", "GUILD")
      Guild:OnData(forged, "Peer-Realm", "WHISPER")
      assert.is_nil(dir().profiles["B-Realm"])
      assert.is_true(Guild.stats.rejected >= 1)
    end)

    it("stores a keyed copy of the known fields only, recomputing h", function()
      local dup = { c = "B-Realm", ts = 5, lv = "q", pr = {
        { s = 2907, k = 1, m = 10, r = { 100, 1, 1 } },
        { s = 2907, k = 50, m = 100, r = { 100, 3, 5, 101, 2, 4, 100, 4, 5 } } } }
      local msg = merge(Protocol.Data(dup), { extra = "x" })
      msg.pr[2].junk = true
      Guild:OnHello(Protocol.Hello("1.0.0", { ["B-Realm"] = msg.h }), "Peer-Realm", "GUILD")
      Guild:OnData(msg, "Peer-Realm", "WHISPER")
      local p = dir().profiles["B-Realm"]
      assert.are.same({ "c", "h", "lv", "owner", "pr", "rt", "ts", "verified" }, sorted((function()
        local k = {}
        for key in pairs(p) do k[#k + 1] = key end
        return k
      end)()))
      assert.are.equal(Protocol.HashProfile(dup), p.h)
      assert.are.same({ { s = 2907, k = 50, m = 100, r = ",100:45,101:24," } }, p.pr)
    end)

    it("withdraws profiles on opt-out and clears quality on downgrade", function()
      seed_peer_with_profile("Peer-Realm", PB)                 -- PB.lv == "q"
      assert.are.equal(",100:35,101:24,", dir().profiles["B-Realm"].pr[1].r)
      local PBr = as_recipes_only(PB)
      Guild:OnHello(Protocol.Hello("1.0.0", { ["B-Realm"] = Protocol.HashProfile(PBr) }), "Peer-Realm", "GUILD")
      Guild:OnData(Protocol.Data(PBr), "Peer-Realm", "WHISPER")
      assert.are.equal("r", dir().profiles["B-Realm"].lv)
      assert.are.equal(",100,101,", dir().profiles["B-Realm"].pr[1].r)
      Guild:OnHello(Protocol.Hello("1.0.0", {}), "Peer-Realm", "GUILD")
      assert.is_nil(dir().profiles["B-Realm"])
    end)

    it("lets linked characters update and withdraw each other but not a stranger", function()
      local PQ = { c = "Q-Realm", ts = 1, lv = "q", pr = { { s = 2906, k = 1, m = 10, r = { 200, 1, 2 } } } }
      local PP = { c = "P-Realm", ts = 1, lv = "r", pr = { { s = 2909, k = 1, m = 10, r = { 300 } } } }
      -- Q logs in and publishes itself plus its alt P; then P logs in and lists both.
      Guild:OnHello(Protocol.Hello("1", { ["Q-Realm"] = Protocol.HashProfile(PQ), ["P-Realm"] = Protocol.HashProfile(PP) }), "Q-Realm", "GUILD")
      Guild:OnData(Protocol.Data(PQ), "Q-Realm", "WHISPER"); Guild:OnData(Protocol.Data(PP), "Q-Realm", "WHISPER")
      assert.are.equal("Q-Realm", dir().profiles["P-Realm"].owner)
      assert.is_true(dir().profiles["Q-Realm"].verified)
      assert.is_false(dir().profiles["P-Realm"].verified)         -- P has not named Q yet
      -- A stranger listing Q-Realm can neither take it over nor withdraw it.
      local fake = { c = "Q-Realm", ts = 1, lv = "r", pr = { { s = 2906, k = 1, m = 10, r = { 999 } } } }
      Guild:OnHello(Protocol.Hello("1", { ["Q-Realm"] = Protocol.HashProfile(fake) }), "Liar-Realm", "GUILD")
      Guild:OnData(Protocol.Data(fake), "Liar-Realm", "WHISPER")
      assert.are.equal("Q-Realm", dir().profiles["Q-Realm"].owner)
      Guild:OnHello(Protocol.Hello("1", {}), "Liar-Realm", "GUILD")
      assert.is_not_nil(dir().profiles["Q-Realm"])
      -- P (listed by Q) lowers its sharing to recipes only: its new Q-Realm copy replaces Q's quality copy.
      local PQr = as_recipes_only(PQ)
      Guild:OnHello(Protocol.Hello("1", { ["P-Realm"] = Protocol.HashProfile(PP), ["Q-Realm"] = Protocol.HashProfile(PQr) }), "P-Realm", "GUILD")
      Guild:OnData(Protocol.Data(PQr), "P-Realm", "WHISPER")
      assert.are.equal("r", dir().profiles["Q-Realm"].lv)
      assert.is_true(dir().profiles["Q-Realm"].verified)          -- Q's own HELLO names P
      assert.is_true(dir().profiles["P-Realm"].verified)          -- upgraded by P's own same-hash HELLO
      -- Q turns sharing off: Q-Realm (Q is its own linker) and P-Realm (P's HELLO names Q) go.
      Guild:OnHello(Protocol.Hello("1", {}), "Q-Realm", "GUILD")
      assert.is_nil(dir().profiles["P-Realm"])
      assert.is_nil(dir().profiles["Q-Realm"])
    end)

    it("withdraws only by the owner or a verified linker", function()
      local X = { c = "X-Realm", ts = 1, lv = "r", pr = { { s = 2907, k = 1, m = 10, r = { 100 } } } }
      Guild:OnHello(Protocol.Hello("1", { ["X-Realm"] = Protocol.HashProfile(X), ["L-Realm"] = "0000aaaa" }), "X-Realm", "GUILD")
      Guild:OnData(Protocol.Data(X), "X-Realm", "WHISPER")
      Guild:OnHello(Protocol.Hello("1", {}), "Other-Realm", "GUILD")           -- neither owner nor linker
      assert.is_not_nil(dir().profiles["X-Realm"])
      Guild:OnHello(Protocol.Hello("1", {}), "L-Realm", "GUILD")              -- named by X's own HELLO
      assert.is_nil(dir().profiles["X-Realm"])
    end)

    it("refreshes rt when the owner's HELLO confirms an unchanged hash", function()
      seed_peer_with_profile("Peer-Realm", PB)
      p4.advance(1000)
      Guild:OnHello(Protocol.Hello("1.0.0", { ["B-Realm"] = Protocol.HashProfile(PB) }), "Peer-Realm", "GUILD")
      assert.are.equal(ns.FS:Now(), dir().profiles["B-Realm"].rt)
    end)

    it("keeps the stored hash so a confirming HELLO requests nothing", function()
      seed_peer_with_profile("Peer-Realm", PB)
      clear_sent()
      Guild:OnHello(Protocol.Hello("1.0.0", { ["B-Realm"] = Protocol.HashProfile(PB) }), "Peer-Realm", "GUILD")
      assert.are.equal(0, count_sent("Q"))
    end)

    local function profile_of(c)
      return { c = c, ts = 1, lv = "r", pr = { { s = 2907, k = 1, m = 10, r = { 100 } } } }
    end

    it("evicts the least recently seen profile beyond the cap and counts it", function()
      local cap = ns.Social.ProfileStore.MAX_PER_GUILD
      ns.Social.ProfileStore.MAX_PER_GUILD = 2
      finally(function() ns.Social.ProfileStore.MAX_PER_GUILD = cap end)
      local before = Guild.stats.evicted
      seed_peer_with_profile("PA-Realm", profile_of("A-Realm"))
      p4.advance(1)
      seed_peer_with_profile("PB-Realm", profile_of("B-Realm"))
      p4.advance(1)
      seed_peer_with_profile("PC-Realm", profile_of("C-Realm"))
      assert.is_nil(dir().profiles["A-Realm"]); assert.is_table(dir().profiles["B-Realm"])
      assert.is_table(dir().profiles["C-Realm"])
      assert.are.equal(before + 1, Guild.stats.evicted)
    end)

    it("never evicts the profile just stored, even when it is the oldest", function()
      local cap = ns.Social.ProfileStore.MAX_PER_GUILD
      ns.Social.ProfileStore.MAX_PER_GUILD = 1
      finally(function() ns.Social.ProfileStore.MAX_PER_GUILD = cap end)
      dir().profiles["Z-Realm"] = { c = "Z-Realm", ts = 1, lv = "r", h = "00000001", owner = "PZ-Realm",
        rt = ns.FS:Now() + 100, pr = {} }
      seed_peer_with_profile("PA-Realm", profile_of("A-Realm"))
      assert.is_table(dir().profiles["A-Realm"]); assert.is_nil(dir().profiles["Z-Realm"])
    end)

    it("does not re-request a pair whose DATA was stored and then evicted", function()
      local cap = ns.Social.ProfileStore.MAX_PER_GUILD
      ns.Social.ProfileStore.MAX_PER_GUILD = 1
      finally(function() ns.Social.ProfileStore.MAX_PER_GUILD = cap end)
      seed_peer_with_profile("PA-Realm", profile_of("A-Realm"))
      p4.advance(1)
      seed_peer_with_profile("PB-Realm", profile_of("B-Realm"))
      assert.is_nil(dir().profiles["A-Realm"]); assert.is_table(dir().profiles["B-Realm"])
      clear_sent()
      p4.advance(Guild.REREQUEST_COOLDOWN + 1)
      Guild:_RetryRequests()
      assert.are.equal(0, count_sent("Q"))
    end)
  end)

  describe("OnRequest / FlushRequests", function()
    it("sends an empty HELLO when sharing is turned off and then ignores requests", function()
      settings.share = false; Guild:OnPrivacyChanged()
      assert.are.same({}, last_sent_msg().c)
      assert.are.equal("GUILD", last_sent().dist)
      Guild:OnRequest(Protocol.Request({ "Me-Realm" }), "Peer-Realm"); p4.advance(5)
      assert.are.equal(0, count_sent("D"))
      assert.are.same({}, Guild:GetOwnHashes())
    end)

    it("whispers DATA to a single requester and broadcasts once for two", function()
      Guild:OnRequest(Protocol.Request({ "Me-Realm" }), "P1-Realm"); p4.advance(3)
      assert.are.equal("WHISPER", last_sent().dist); assert.are.equal("P1-Realm", last_sent().target)
      assert.are.equal("BULK", last_sent().prio)
      assert.are.equal(Guild:GetOwnHashes()["Me-Realm"], last_sent_msg().h)
      Guild:OnRequest(Protocol.Request({ "Alt-Realm" }), "P1-Realm")
      Guild:OnRequest(Protocol.Request({ "Alt-Realm" }), "P2-Realm"); p4.advance(3)
      assert.are.equal("GUILD", last_sent().dist); assert.are.equal(1, count_sent("D", "GUILD"))
      Guild:OnRequest(Protocol.Request({ "Me-Realm" }), "P1-Realm"); p4.advance(3)
      assert.are.equal(2, count_sent("D"))                     -- resend cooldown
      p4.advance(60)
      Guild:OnRequest(Protocol.Request({ "Me-Realm" }), "P1-Realm"); p4.advance(3)
      assert.are.equal(3, count_sent("D"))
    end)

    it("ignores requests for characters it does not share", function()
      Guild:OnRequest(Protocol.Request({ "Far-Realm", "Nobody-Realm" }), "P1-Realm"); p4.advance(5)
      assert.are.equal(0, count_sent("D"))
    end)

    it("re-checks sharing when the window ends", function()
      Guild:OnRequest(Protocol.Request({ "Me-Realm" }), "P1-Realm")
      settings.shareAlts = "current"
      Guild:OnRequest(Protocol.Request({ "Alt-Realm" }), "P2-Realm")
      settings.share = false
      p4.advance(5)
      assert.are.equal(0, count_sent("D"))
    end)

    it("counts and logs once a DATA the comm drops", function()
      Guild.comm.Send = function() return "dropped" end
      Guild:OnRequest(Protocol.Request({ "Me-Realm" }), "P1-Realm"); p4.advance(3)
      Guild:OnRequest(Protocol.Request({ "Me-Realm" }), "P2-Realm"); p4.advance(3)
      assert.are.equal(2, Guild.stats.dataDropped)
      local errors = ns.FS.db.global.diagnostics.errors
      assert.are.equal(1, #errors)
      assert.are.equal("Guild:Data", errors[1].source)
      assert.truthy(errors[1].err:find("Me-Realm", 1, true))
      assert.truthy(errors[1].err:find("%d+ bytes"))
    end)
  end)

  describe("whispers from outside the guild", function()
    before_each(function()
      p4.guild.members = { { "Peer-Realm", true } }        -- a loaded roster; Stranger-Realm is not on it
      p4.guild.exists["Stranger-Realm"] = false
    end)

    it("treats an empty roster as unknown, so every whisperer counts as a member", function()
      p4.guild.members = {}
      assert.is_true(Guild:IsGuildMember("Stranger-Realm"))
      p4.guild.members = { { "Peer-Realm", true } }
      assert.is_false(Guild:IsGuildMember("Stranger-Realm"))
      assert.is_true(Guild:IsGuildMember("Peer-Realm"))
    end)

    it("OnHello: no request, no reply, no member record", function()
      Guild:OnHello(Protocol.Hello("1", { ["Stranger-Realm"] = "0000aaaa" }), "Stranger-Realm", "WHISPER"); p4.advance(20)
      assert.are.equal(0, #p4.comm.sent)
      assert.is_nil(dir().members["Stranger-Realm"])
      assert.are.equal(1, Guild.stats.strangers)
    end)

    it("OnRequest: never answered", function()
      Guild:OnRequest(Protocol.Request({ "Me-Realm" }), "Stranger-Realm", "WHISPER"); p4.advance(5)
      assert.are.equal(0, count_sent("D"))
      Guild:OnRequest(Protocol.Request({ "Me-Realm" }), "Peer-Realm", "WHISPER"); p4.advance(5)
      assert.are.equal(1, count_sent("D", "WHISPER"))
    end)

    it("OnData: nothing stored", function()
      local S = { c = "Stranger-Realm", ts = 1, lv = "r", pr = { { s = 2907, k = 1, m = 10, r = { 100 } } } }
      p4.guild.exists["Stranger-Realm"] = nil                -- briefly a member: its HELLO is stored
      Guild:OnHello(Protocol.Hello("1", { ["Stranger-Realm"] = Protocol.HashProfile(S) }), "Stranger-Realm", "WHISPER")
      p4.guild.exists["Stranger-Realm"] = false              -- left the guild
      Guild:OnData(Protocol.Data(S), "Stranger-Realm", "WHISPER")
      assert.is_nil(dir().profiles["Stranger-Realm"])
    end)

    it("OnVersion: no member record (a GUILD one still counts)", function()
      Guild:OnVersion("Stranger-Realm", 2, "WHISPER")
      assert.is_nil(dir().members["Stranger-Realm"])
      Guild:OnVersion("Stranger-Realm", 2, "GUILD")
      assert.are.equal(2, dir().members["Stranger-Realm"].proto)
    end)

    it("drops a stranger's whisper that arrives through AceComm", function()
      p4.comm.deliver(Protocol.PREFIX, Protocol.Wire(Protocol.Request({ "Me-Realm" })), "WHISPER", "Stranger-Realm")
      p4.comm.deliver(Protocol.PREFIX, "2:x", "WHISPER", "Stranger-Realm")
      p4.advance(5)
      assert.are.equal(0, #p4.comm.sent)
      assert.is_nil(dir().members["Stranger-Realm"])
    end)
  end)

  ---------------------------------------------------------------------------
  -- Own changes, privacy, login
  ---------------------------------------------------------------------------

  describe("own changes", function()
    it("re-announces after the debounce only when a hash changed, ignoring Moxie", function()
      ns.FS:SendMessage("FS_DATA_CHANGED", "Me-Realm", "moxie"); p4.advance(200)
      assert.are.equal(0, count_sent("H"))
      chars["Me-Realm"].professions[2907].recipes[102] = true
      ns.FS:SendMessage("FS_DATA_CHANGED", "Me-Realm", "recipes"); p4.advance(119)
      assert.are.equal(0, count_sent("H"))
      p4.advance(2)
      assert.are.equal(1, count_sent("H", "GUILD"))
      assert.are.equal(Protocol.HashProfile(Guild:BuildProfile("Me-Realm")), last_sent_msg().c["Me-Realm"])
      ns.FS:SendMessage("FS_RECIPES_CHANGED"); p4.advance(121)
      assert.are.equal(1, count_sent("H"))                     -- nothing changed since the last HELLO
    end)

    it("coalesces a burst of changes into one refresh", function()
      evaluate_spy:clear()
      for _ = 1, 50 do ns.FS:SendMessage("FS_RECIPES_CHANGED") end
      p4.advance(121)
      assert.spy(evaluate_spy).was_called(6)
    end)

    it("re-announces a lowered sharing level after the refresh", function()
      settings.shareLevel = "recipes"; Guild:OnPrivacyChanged()
      p4.advance(1)
      assert.are.equal("r", Guild:GetOwnProfile("Me-Realm").lv)
      assert.are.equal("H", last_sent_msg().t)
      assert.are.equal(Guild:GetOwnHashes()["Me-Realm"], last_sent_msg().c["Me-Realm"])
    end)

    it("never sends the old quality profile while a lowered sharing level is rebuilt", function()
      settings.shareLevel = "recipes"; Guild:OnPrivacyChanged()
      Guild:OnRequest(Protocol.Request({ "Me-Realm" }), "P1-Realm")
      Guild:FlushRequests()                                    -- before the rebuild ran a single step
      assert.are.equal(0, count_sent("D"))
      p4.advance(4)
      assert.are.equal(1, count_sent("D"))
      assert.are.equal("r", last_sent_msg().lv)
    end)

    it("starts the login path at once when turned on after the first loading screen", function()
      boot({ login = false })
      Guild:Disable()
      W.fire("PLAYER_ENTERING_WORLD", true, false); p4.advance(30)
      assert.are.equal(0, #p4.comm.sent)
      Guild:Enable()
      assert.are.equal(1, p4.guild.rosterRequests)
      p4.advance(21)
      assert.are.equal(1, count_sent("H", "GUILD"))
    end)

    it("skips a second refresh tick within the same frame", function()
      local clock, frameTime = 0, 5
      _G.debugprofilestop = function() clock = clock + 1; return clock end
      _G.GetTime = function() return frameTime end
      finally(function() _G.debugprofilestop = nil; _G.GetTime = nil end)
      ns.FS:GetModule("Recipes").GetSetting = function() return 1 end   -- scanBudgetMs = 1: one recipe per step
      evaluate_spy:clear()
      Guild:RefreshOwnProfiles()
      Guild:_RefreshTick()
      local first = #evaluate_spy.calls
      assert.is_true(first > 0)
      Guild:_RefreshTick()                                     -- same GetTime(): skipped
      assert.are.equal(first, #evaluate_spy.calls)
      frameTime = 6
      Guild:_RefreshTick()
      assert.is_true(#evaluate_spy.calls > first)
    end)

    it("announces once on login, after the jitter, and not again on later loading screens", function()
      boot({ login = false })
      W.fire("PLAYER_ENTERING_WORLD", true, false)
      assert.are.equal(1, p4.guild.rosterRequests)
      p4.advance(4)
      assert.are.equal(0, count_sent("H"))
      p4.advance(16)
      assert.are.equal(1, count_sent("H", "GUILD"))
      assert.is_not_nil(last_sent_msg().c["Me-Realm"])
      W.fire("PLAYER_ENTERING_WORLD", false, false); p4.advance(30)
      assert.are.equal(1, count_sent("H"))
    end)

    it("starts syncing when the guild name arrives after the loading screen", function()
      boot({ login = false, guild = false })
      W.fire("PLAYER_ENTERING_WORLD", true, false); p4.advance(30)
      assert.are.equal(0, #p4.comm.sent)
      p4.guild.key = { "G", "Realm" }
      W.fire("GUILD_ROSTER_UPDATE"); p4.advance(21)
      assert.are.equal(1, count_sent("H", "GUILD"))
      assert.are.same({ { "G-Realm" } }, p4.messages("FS_GUILD_CHANGED"))
    end)

    it("does nothing outside a guild or without C_EncodingUtil", function()
      boot({ login = false, guild = false })
      W.fire("PLAYER_ENTERING_WORLD", true, false); p4.advance(30)
      Guild:SendHello(); ns.FS:SendMessage("FS_RECIPES_CHANGED"); p4.advance(200)
      assert.are.equal(0, #p4.comm.sent)
      assert.is_nil(p4.comm.registered[Protocol.PREFIX])
      assert.is_nil(Guild.comm)

      boot({ login = false })
      _G.C_EncodingUtil = {}
      W.fire("PLAYER_ENTERING_WORLD", true, false); p4.advance(30)
      Guild:OnPrivacyChanged(); p4.advance(200)
      assert.are.equal(0, #p4.comm.sent)
      assert.is_nil(Guild.comm)
      assert.are.equal("noCodec", Guild:SyncStatus())
    end)

    it("stops syncing and clears the current character's guild when it leaves the guild", function()
      p4.guild.key = nil
      Guild:OnGuildUpdate(); p4.advance(1)
      assert.is_nil(Guild:GetGuildKey())
      assert.is_nil(ns.FS.db.global.guildMyChars["Me-Realm"])
      assert.is_nil(Guild.comm)
      assert.is_nil(p4.comm.registered[Protocol.PREFIX])
      local got = p4.messages("FS_GUILD_CHANGED")
      assert.are.same({}, got[#got])                           -- FS_GUILD_CHANGED(nil)
    end)

    it("flushes the queue when the gate opens", function()
      p4.restriction.chatActive = true
      Guild:SendHello()
      assert.are.equal(0, #p4.comm.sent)
      p4.restriction.chatActive = false
      ns.FS:SendMessage("FS_COMM_GATE_CHANGED", false)
      assert.are.equal(1, count_sent("H", "GUILD"))
    end)

    it("receives through AceComm and records a newer protocol version once", function()
      assert.is_true(p4.comm.deliver(Protocol.PREFIX, "2:whatever", "GUILD", "Peer-Realm"))
      p4.comm.deliver(Protocol.PREFIX, "2:again", "GUILD", "Peer-Realm")
      assert.are.equal(2, dir().members["Peer-Realm"].proto)
      local warned = 0
      for _, line in ipairs(W.printed) do
        if line:find("newer FabricationStation sync protocol", 1, true) then warned = warned + 1 end
      end
      assert.are.equal(1, warned)
      p4.comm.deliver(Protocol.PREFIX, Protocol.Wire(Protocol.Hello("1.0.0", {})), "GUILD", "Peer-Realm")
      assert.are.equal(1, dir().members["Peer-Realm"].proto)
    end)

    it("leaves no registrations, timers or comm behind when disabled", function()
      Guild:OnHello(Protocol.Hello("1.0.0", { ["B-Realm"] = "0000bbbb" }), "Peer-Realm", "GUILD") -- reply + retry
      Guild:OnRequest(Protocol.Request({ "Me-Realm" }), "P1-Realm")        -- flush pending
      ns.FS:SendMessage("FS_RECIPES_CHANGED")                               -- guildHello pending
      assert.is_true(Guild:IsRetryArmed())
      clear_sent()                                                          -- the REQUEST went out at once
      Guild:Disable()
      assert.is_false(Guild:IsRetryArmed())
      assert.are.same({ events = {}, messages = {} }, W.registrations(Guild))
      assert.is_nil(p4.comm.registered[Protocol.PREFIX])
      assert.is_nil(Guild.comm)
      p4.advance(1000)
      assert.are.equal(0, #p4.comm.sent)
      Guild:Enable(); p4.advance(21)
      assert.are.equal(1, count_sent("H", "GUILD"))        -- re-enabled mid-session: syncs again
    end)
  end)

  ---------------------------------------------------------------------------
  -- Storage
  ---------------------------------------------------------------------------

  describe("storage", function()
    it("prunes profiles and members older than 30 days", function()
      seed_peer_with_profile("Peer-Realm", PB)
      p4.advance(30 * DAY + 1)
      Guild:Prune(ns.FS:Now())
      assert.is_nil(dir().profiles["B-Realm"]); assert.is_nil(dir().members["Peer-Realm"])
    end)

    it("keeps recent entries when pruning", function()
      seed_peer_with_profile("Peer-Realm", PB)
      p4.advance(29 * DAY)
      Guild:Prune(ns.FS:Now())
      assert.is_not_nil(dir().profiles["B-Realm"]); assert.is_not_nil(dir().members["Peer-Realm"])
    end)

    it("purges a guild's directory", function()
      seed_peer_with_profile("Peer-Realm", PB)
      assert.is_true(Guild:PurgeGuild("G-Realm"))
      assert.is_nil(ns.FS.db.global.guildDirectory["G-Realm"])
    end)

    it("creates the directory record with its three tables", function()
      assert.are.same({ members = {}, profiles = {}, native = {}, contested = {} }, Guild:GetDirectory("New-Realm"))
    end)
  end)

  ---------------------------------------------------------------------------
  -- Read-only saved data (dbIsNewer): every writer leaves db.global alone and nothing is sent
  ---------------------------------------------------------------------------

  describe("while the saved data is from a newer version", function()
    local snapshot
    before_each(function()
      seed_peer_with_profile("Peer-Realm", PB)
      p4.advance(10); clear_sent()
      ns.FS.dbIsNewer = true
      snapshot = ns.Util.DeepCopy(ns.FS.db.global, 30)
    end)
    local function unchanged() assert.are.same(snapshot, ns.Util.DeepCopy(ns.FS.db.global, 30)) end

    it("OnHello stores and sends nothing", function()
      Guild:OnHello(Protocol.Hello("1.0.0", { ["C-Realm"] = "0000cccc" }), "Peer2-Realm", "GUILD"); p4.advance(20)
      Guild:OnHello(Protocol.Hello("1.0.0", {}), "Peer-Realm", "GUILD")
      unchanged(); assert.are.equal(0, #p4.comm.sent)
    end)
    it("OnData stores nothing", function()
      Guild:OnData(Protocol.Data(as_recipes_only(PB)), "Peer-Realm", "WHISPER")
      unchanged()
    end)
    it("OnVersion stores nothing", function() Guild:OnVersion("Peer-Realm", 2); unchanged() end)
    it("GetDirectory creates nothing", function()
      assert.is_nil(Guild:GetDirectory("New-Realm"))
      assert.is_not_nil(Guild:GetDirectory())
      unchanged()
    end)
    it("OnGuildUpdate writes no guildMyChars", function()
      p4.guild.key = { "Other", "Realm" }; Guild:OnGuildUpdate()
      p4.guild.key = nil; Guild:OnGuildUpdate()
      unchanged()
    end)
    it("Prune and PurgeGuild change nothing", function()
      p4.advance(31 * DAY)
      Guild:Prune(ns.FS:Now())
      assert.is_false(Guild:PurgeGuild("G-Realm"))
      unchanged()
    end)
    it("SendHello, requests and privacy changes send nothing", function()
      Guild:SendHello(); Guild:SendHello("Peer-Realm")
      Guild:OnRequest(Protocol.Request({ "Me-Realm" }), "Peer-Realm")
      Guild:Settings().share = false; Guild:OnPrivacyChanged()   -- the session copy, not the saved table
      p4.advance(200)
      unchanged(); assert.are.equal(0, #p4.comm.sent)
      assert.are.equal("readOnly", Guild:SyncStatus())
    end)
    it("settings changes stay in the session copy", function()
      Guild:Settings().shareLevel = "recipes"
      unchanged()
    end)
    it("a read-only login builds no comm and sends nothing", function()
      boot({ login = false })
      ns.FS.dbIsNewer = true
      snapshot = ns.Util.DeepCopy(ns.FS.db.global, 30)
      W.fire("PLAYER_ENTERING_WORLD", true, false); p4.advance(60)
      assert.is_nil(Guild.comm)
      assert.are.equal(0, #p4.comm.sent)
      unchanged()
    end)
  end)

  ---------------------------------------------------------------------------
  -- Sync robustness: request cooldown per sender, bounded re-requests, whole bursts through Comm
  ---------------------------------------------------------------------------

  describe("sync robustness", function()
    local function deliver(msg, dist, sender)
      return p4.comm.deliver(Protocol.PREFIX, Protocol.Wire(msg), dist, sender)
    end
    local function requests_to(target)
      local out = {}
      for _, s in ipairs(sent_list()) do
        if s.msg.t == "Q" and s.target == target then out[#out + 1] = sorted(s.msg.c) end
      end
      return out
    end
    local function profile(c, id)
      return { c = c, ts = 1, lv = "r", pr = { { s = 2907, k = 1, m = 10, r = { id } } } }
    end
    -- A sharer whose HELLO lists `n` characters: its own name first, then alts. -> sender, { [charKey] = profile }
    local function sharer(n)
      local list = {}
      for i = 1, n do
        local c = "Bx" .. i .. "-Realm"
        list[c] = profile(c, 1000 + i)
      end
      return "Bx1-Realm", list
    end
    local function hello_of(list)
      local c = {}
      for key, p in pairs(list) do c[key] = Protocol.HashProfile(p) end
      return Protocol.Hello("1.0.0", c)
    end
    local function stored_count()
      local n = 0
      for _ in pairs(dir().profiles) do n = n + 1 end
      return n
    end

    it("keys the request cooldown by sender: a whisperer listing the owner's hash cannot delay the owner", function()
      local H = Protocol.HashProfile(profile("V-Realm", 5))
      Guild:OnHello(Protocol.Hello("1", { ["V-Realm"] = H }), "Liar-Realm", "GUILD")
      assert.are.same({ { "V-Realm" } }, requests_to("Liar-Realm"))
      Guild:OnHello(Protocol.Hello("1", { ["V-Realm"] = H }), "V-Realm", "GUILD")          -- 0 s later
      assert.are.same({ { "V-Realm" } }, requests_to("V-Realm"))
    end)

    it("lets a verified claim bypass the cooldown its earlier unverified claim set", function()
      local HW = Protocol.HashProfile(profile("W-Realm", 7))
      Guild:OnHello(Protocol.Hello("1", { ["W-Realm"] = HW }), "V-Realm", "GUILD")         -- unverified: W never seen
      assert.are.same({ { "W-Realm" } }, requests_to("V-Realm"))
      Guild:OnHello(Protocol.Hello("1", { ["V-Realm"] = "0000aaaa" }), "W-Realm", "GUILD") -- W's own HELLO names V
      p4.advance(10)
      Guild:OnHello(Protocol.Hello("1", { ["W-Realm"] = HW }), "V-Realm", "WHISPER")       -- now verified, 10 s later
      assert.are.same({ { "W-Realm" }, { "W-Realm" } }, requests_to("V-Realm"))
      p4.advance(10)
      Guild:OnHello(Protocol.Hello("1", { ["W-Realm"] = HW }), "V-Realm", "WHISPER")       -- verified again: cooldown
      assert.are.equal(2, #requests_to("V-Realm"))
    end)

    it("re-requests a pair whose DATA never came, after the cooldown, at most RETRY_MAX times", function()
      Guild:OnHello(Protocol.Hello("1.0.0", { ["B-Realm"] = Protocol.HashProfile(PB) }), "Peer-Realm", "GUILD")
      assert.are.equal(1, #requests_to("Peer-Realm"))
      assert.is_true(Guild:IsRetryArmed())
      p4.advance(Guild.REREQUEST_COOLDOWN - 1)
      assert.are.equal(1, #requests_to("Peer-Realm"))
      p4.advance(1)
      assert.are.same({ { "B-Realm" }, { "B-Realm" } }, requests_to("Peer-Realm"))
      p4.advance(Guild.REREQUEST_COOLDOWN * (Guild.RETRY_MAX + 3))
      assert.are.equal(1 + Guild.RETRY_MAX, #requests_to("Peer-Realm"))
      assert.is_false(Guild:IsRetryArmed())
    end)

    it("stops re-requesting once the DATA arrived", function()
      Guild:OnHello(Protocol.Hello("1.0.0", { ["B-Realm"] = Protocol.HashProfile(PB) }), "Peer-Realm", "GUILD")
      Guild:OnData(Protocol.Data(PB), "Peer-Realm", "WHISPER")
      p4.advance(Guild.REREQUEST_COOLDOWN * 5)
      assert.are.equal(1, #requests_to("Peer-Realm"))
      assert.is_false(Guild:IsRetryArmed())
    end)

    it("re-requests only from members seen recently that still list the hash", function()
      Guild:OnHello(Protocol.Hello("1.0.0", { ["B-Realm"] = Protocol.HashProfile(PB) }), "Peer-Realm", "GUILD")
      Guild:OnHello(Protocol.Hello("1.0.0", { ["C-Realm"] = "0000cccc" }), "Old-Realm", "GUILD")
      dir().members["Old-Realm"].lastSeen = ns.FS:Now() - Guild.RETRY_RECENT - 1          -- not seen recently
      Guild:OnHello(Protocol.Hello("1.0.0", {}), "Gone-Realm", "GUILD")
      dir().members["Peer-Realm"].chars["B-Realm"] = "0000ffff"                            -- now lists another hash
      p4.advance(Guild.REREQUEST_COOLDOWN * 3)
      assert.are.equal(1, #requests_to("Peer-Realm"))
      assert.are.equal(1, #requests_to("Old-Realm"))
    end)

    it("never re-requests a character it may no longer accept from that sender", function()
      seed_peer_with_profile("Peer-Realm", PB)                                             -- verified? no: Peer's copy
      local X = profile("X-Realm", 9)
      Guild:OnHello(Protocol.Hello("1", { ["X-Realm"] = Protocol.HashProfile(X) }), "X-Realm", "GUILD")
      Guild:OnData(Protocol.Data(X), "X-Realm", "WHISPER")                                 -- verified copy of X
      local X2 = profile("X-Realm", 10)
      Guild:OnHello(Protocol.Hello("1", { ["X-Realm"] = Protocol.HashProfile(X2) }), "Liar-Realm", "GUILD")
      assert.are.equal(0, #requests_to("Liar-Realm"))
      p4.advance(Guild.REREQUEST_COOLDOWN * 3)
      assert.are.equal(0, #requests_to("Liar-Realm"))
    end)

    it("syncs a sharer with 26 characters completely to a fresh receiver through Comm", function()
      local from, list = sharer(26)
      assert.is_true(deliver(hello_of(list), "GUILD", from))
      local q = requests_to(from)
      assert.are.equal(1, #q)
      assert.are.equal(26, #q[1])
      for _, c in ipairs(q[1]) do deliver(Protocol.Data(list[c]), "WHISPER", from) end
      assert.are.equal(26, stored_count())
      assert.are.equal(0, Guild.comm.stats.rateLimited)
      assert.is_true(dir().profiles["Bx1-Realm"].verified)
      assert.are.equal("Bx1-Realm", dir().profiles["Bx26-Realm"].owner)
    end)

    it("recovers a dropped DATA with the bounded re-request in the same session", function()
      local from, list = sharer(3)
      deliver(hello_of(list), "GUILD", from)
      deliver(Protocol.Data(list["Bx1-Realm"]), "WHISPER", from)
      deliver(Protocol.Data(list["Bx3-Realm"]), "WHISPER", from)                          -- Bx2's DATA is lost
      assert.are.equal(2, stored_count())
      p4.advance(Guild.REREQUEST_COOLDOWN)
      local q = requests_to(from)
      assert.are.same({ "Bx2-Realm" }, q[#q])
      deliver(Protocol.Data(list["Bx2-Realm"]), "WHISPER", from)
      assert.are.equal(3, stored_count())
      p4.advance(Guild.REREQUEST_COOLDOWN * 3)
      assert.are.equal(2, #requests_to(from))
    end)

    it("never unwires a stranger's whisper", function()
      p4.guild.members = { { "Peer-Realm", true } }
      p4.guild.exists["Stranger-Realm"] = false
      local unwire = spy.on(Protocol, "Unwire")
      deliver(Protocol.Request({ "Me-Realm" }), "WHISPER", "Stranger-Realm")
      assert.spy(unwire).was_not_called()
      assert.are.equal(1, Guild.comm.stats.refused)
      deliver(Protocol.Request({ "Me-Realm" }), "WHISPER", "Peer-Realm")
      assert.spy(unwire).was_called(1)
      deliver(Protocol.Hello("1", {}), "GUILD", "Stranger-Realm")                         -- GUILD proves membership
      assert.spy(unwire).was_called(2)
      unwire:revert()
    end)
  end)

  ---------------------------------------------------------------------------
  -- Mutual self-attestation: the sender's and the holder's own records list each other (same account)
  ---------------------------------------------------------------------------

  describe("mutual self-attestation", function()
    local X1 = { c = "X-Realm", ts = 1, lv = "r", pr = { { s = 2907, k = 1, m = 10, r = { 100 } } } }
    local X2 = { c = "X-Realm", ts = 2, lv = "r", pr = { { s = 2907, k = 2, m = 10, r = { 100, 101 } } } }
    local function hx(p) return Protocol.HashProfile(p) end

    -- O logs in sharing itself, its alt S and the never-logged-in alt X; O's copy of X is stored unverified.
    local function seed_o()
      Guild:OnHello(Protocol.Hello("1", { ["O-Realm"] = "0000aaaa", ["S-Realm"] = "0000bbbb", ["X-Realm"] = hx(X1) }),
        "O-Realm", "GUILD")
      Guild:OnData(Protocol.Data(X1), "O-Realm", "WHISPER")
      assert.are.equal("O-Realm", dir().profiles["X-Realm"].owner)
      assert.is_false(dir().profiles["X-Realm"].verified)
    end

    it("replaces the copy as an unverified copy owned by the sender, without a contest", function()
      seed_o()
      Guild:OnHello(Protocol.Hello("1", { ["S-Realm"] = "0000bbbb", ["O-Realm"] = "0000aaaa", ["X-Realm"] = hx(X2) }),
        "S-Realm", "GUILD")
      assert.is_nil(dir().contested["X-Realm"])
      assert.is_not_nil(dir().profiles["X-Realm"])                 -- not deleted by a contest
      Guild:OnData(Protocol.Data(X2), "S-Realm", "WHISPER")
      local p = dir().profiles["X-Realm"]
      assert.are.equal("S-Realm", p.owner)
      assert.is_false(p.verified)
      assert.are.equal(hx(X2), p.h)
    end)

    it("never becomes verified, not even through a same-hash HELLO", function()
      seed_o()
      Guild:OnHello(Protocol.Hello("1", { ["S-Realm"] = "0000bbbb", ["O-Realm"] = "0000aaaa", ["X-Realm"] = hx(X2) }),
        "S-Realm", "GUILD")
      Guild:OnData(Protocol.Data(X2), "S-Realm", "WHISPER")
      Guild:OnHello(Protocol.Hello("1", { ["S-Realm"] = "0000bbbb", ["O-Realm"] = "0000aaaa", ["X-Realm"] = hx(X2) }),
        "S-Realm", "WHISPER")
      assert.is_false(dir().profiles["X-Realm"].verified)
      Guild:OnHello(Protocol.Hello("1", { ["O-Realm"] = "0000aaaa", ["S-Realm"] = "0000bbbb", ["X-Realm"] = hx(X2) }),
        "O-Realm", "WHISPER")
      assert.is_false(dir().profiles["X-Realm"].verified)
    end)

    it("never replaces a verified copy", function()
      seed_o()
      Guild:OnHello(Protocol.Hello("1", { ["X-Realm"] = hx(X1) }), "X-Realm", "GUILD")          -- X itself: verified
      assert.is_true(dir().profiles["X-Realm"].verified)
      assert.are.equal("X-Realm", dir().profiles["X-Realm"].owner)
      Guild:OnHello(Protocol.Hello("1", { ["S-Realm"] = "0000bbbb", ["O-Realm"] = "0000aaaa", ["X-Realm"] = hx(X2) }),
        "S-Realm", "GUILD")
      Guild:OnData(Protocol.Data(X2), "S-Realm", "WHISPER")
      local p = dir().profiles["X-Realm"]
      assert.are.equal("X-Realm", p.owner)
      assert.is_true(p.verified)
      assert.are.equal(hx(X1), p.h)
    end)

    it("still contests when only one side lists the other", function()
      seed_o()
      Guild:OnHello(Protocol.Hello("1", { ["T-Realm"] = "0000bbbb", ["O-Realm"] = "0000aaaa", ["X-Realm"] = hx(X2) }),
        "T-Realm", "GUILD")                                       -- T names O, but O's HELLO does not name T
      assert.is_nil(dir().profiles["X-Realm"])
      assert.is_not_nil(dir().contested["X-Realm"])
    end)
  end)

  describe("settings", function()
    it("fills defaults and repairs bad values", function()
      assert.are.same({ share = true, shareLevel = "quality", shareAlts = "guild", tooltipLine = true,
        panelLine = true, useNative = true }, settings)
      settings.shareLevel = "everything"; settings.shareAlts = 3; settings.share = "yes"
      local s = Guild:Settings()
      assert.are.equal("quality", s.shareLevel); assert.are.equal("guild", s.shareAlts); assert.is_true(s.share)
      assert.are.equal(s, ns.FS.db.global.settings.guild)
    end)
  end)
end)
