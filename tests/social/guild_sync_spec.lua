-- Guild: own crafting profiles, privacy settings, HELLO/REQ/DATA delta sync over guild addon messages, peer storage
-- and pruning. Scanner and Recipes are p4.fake_module fakes; the AceComm, guild roster and encoding fakes are the
-- phase-4 harness ones (p4.comm, p4.guild, the reversible C_EncodingUtil).
local SOCIAL_FILES = { "Modules/Social/Util.lua", "Modules/Social/Gate.lua", "Modules/Social/Codec.lua",
  "Modules/Social/Protocol.lua", "Modules/Social/Comm.lua", "Modules/Social/Guild.lua" }
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
    dir().profiles[charKey] = { c = charKey, ts = 0, lv = "r", h = h, owner = owner, rt = ns.FS:Now(), lines = {} }
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

    it("does not request a character another member owns and still lists", function()
      seed_peer_with_profile("Peer-Realm", PB)
      Guild:OnHello(Protocol.Hello("1.0.0", { ["B-Realm"] = "0000bbbb" }), "Liar-Realm", "GUILD")
      assert.are.equal(1, count_sent("Q"))                       -- Peer's own request only
      Guild:OnHello(Protocol.Hello("1.0.0", { ["Liar-Realm"] = "0000cccc" }), "Liar-Realm", "GUILD")
      assert.are.same({ "Liar-Realm" }, last_sent_msg().c)       -- a player may always publish their own name
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
      assert.are.same({ "c", "h", "lines", "lv", "owner", "rt", "ts" }, sorted((function()
        local k = {}
        for key in pairs(p) do k[#k + 1] = key end
        return k
      end)()))
      assert.are.equal(Protocol.HashProfile(dup), p.h)
      assert.are.same({ [2907] = { k = 50, m = 100, recipes = { [100] = true, [101] = true },
        q = { [100] = 4, [101] = 2 }, qc = { [100] = 5, [101] = 4 } } }, p.lines)
    end)

    it("withdraws profiles on opt-out and clears quality on downgrade", function()
      seed_peer_with_profile("Peer-Realm", PB)                 -- PB.lv == "q"
      assert.are.same({ [100] = 3, [101] = 2 }, dir().profiles["B-Realm"].lines[2907].q)
      local PBr = as_recipes_only(PB)
      Guild:OnHello(Protocol.Hello("1.0.0", { ["B-Realm"] = Protocol.HashProfile(PBr) }), "Peer-Realm", "GUILD")
      Guild:OnData(Protocol.Data(PBr), "Peer-Realm", "WHISPER")
      assert.are.equal("r", dir().profiles["B-Realm"].lv)
      assert.is_nil(dir().profiles["B-Realm"].lines[2907].q)
      assert.is_nil(dir().profiles["B-Realm"].lines[2907].qc)
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
      -- Q turns sharing off: everything Q published goes, including P-Realm (P listed Q, Q had listed P).
      Guild:OnHello(Protocol.Hello("1", {}), "Q-Realm", "GUILD")
      assert.is_nil(dir().profiles["P-Realm"])
      assert.is_nil(dir().profiles["Q-Realm"])
    end)

    it("refreshes rt when the owner's HELLO confirms an unchanged hash", function()
      seed_peer_with_profile("Peer-Realm", PB)
      p4.advance(1000)
      Guild:OnHello(Protocol.Hello("1.0.0", { ["B-Realm"] = Protocol.HashProfile(PB) }), "Peer-Realm", "GUILD")
      assert.are.equal(ns.FS:Now(), dir().profiles["B-Realm"].rt)
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
      Guild:OnHello(Protocol.Hello("1.0.0", {}), "Peer-Realm", "GUILD")     -- reply pending
      Guild:OnRequest(Protocol.Request({ "Me-Realm" }), "P1-Realm")        -- flush pending
      ns.FS:SendMessage("FS_RECIPES_CHANGED")                               -- guildHello pending
      Guild:Disable()
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
      assert.are.same({ members = {}, profiles = {}, native = {} }, Guild:GetDirectory("New-Realm"))
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
