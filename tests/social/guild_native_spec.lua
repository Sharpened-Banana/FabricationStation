-- GuildNative: the serialized native guild recipe query (C_GuildInfo.QueryGuildMembersForRecipe ->
-- GUILD_RECIPE_KNOWN_BY_MEMBERS -> GetGuildRecipeInfoPostQuery / GetGuildRecipeMember), its cache and its passive capture.
-- The roster and the query are the phase-4 harness fakes (p4.guild); postQuery = { skillLineID, recipeID, list =
-- { { displayName, fullName, classFile, online } } }.
local SOCIAL_FILES = { "Modules/Social/Util.lua", "Modules/Social/Gate.lua", "Modules/Social/Codec.lua",
  "Modules/Social/Protocol.lua", "Modules/Social/Comm.lua", "Modules/Social/Guild.lua",
  "Modules/Social/GuildNative.lua" }
local DAY = 86400

describe("Social.GuildNative", function()
  local ns, W, p4, Guild, GuildNative

  local function answer(skillLineID, recipeID, list)
    p4.guild.postQuery = { skillLineID = skillLineID, recipeID = recipeID, list = list }
    W.fire("GUILD_RECIPE_KNOWN_BY_MEMBERS")
  end
  local function native() return Guild:GetDirectory().native end

  before_each(function()
    ns, W, p4 = boot_phase4(SOCIAL_FILES)
    Guild = ns.FS:GetModule("Guild")
    GuildNative = ns.Social.GuildNative
    p4.guild.key = { "G", "Realm" }
    Guild:OnGuildUpdate()
  end)

  it("queries, waits for the event and returns normalized members", function()
    local res, err
    GuildNative:Query(171, 1234, function(m, e) res, err = m, e end)
    assert.are.same({ skillLineID = 171, recipeID = 1234 }, { skillLineID = p4.guild.lastQuery.skillLineID,
      recipeID = p4.guild.lastQuery.recipeID })
    assert.is_nil(res)
    answer(171, 1234, { { "Bob", "Bob-Realm", "MAGE", true }, { "Cy", "Cy", "ROGUE", false } })
    assert.is_nil(err)
    assert.are.same({ { name = "Bob-Realm", classFile = "MAGE", online = true },
      { name = "Cy-Realm", classFile = "ROGUE", online = false } }, res)
  end)

  it("runs one query at a time, in order, at least 1s apart", function()
    local order = {}
    GuildNative:Query(171, 1, function() order[#order + 1] = 1 end)
    GuildNative:Query(171, 2, function() order[#order + 1] = 2 end)
    GuildNative:Query(171, 3, function() order[#order + 1] = 3 end)
    assert.are.equal(1, p4.guild.queryCount)
    assert.are.equal(1, p4.guild.lastQuery.recipeID)
    p4.advance(3)
    assert.are.equal(1, p4.guild.queryCount)        -- the first is still unanswered
    answer(171, 1, {})
    assert.are.same({ 1 }, order)
    assert.are.equal(1, p4.guild.queryCount)        -- the interval starts now
    p4.advance(0.5)
    assert.are.equal(1, p4.guild.queryCount)
    p4.advance(0.6)
    assert.are.equal(2, p4.guild.queryCount)
    assert.are.equal(2, p4.guild.lastQuery.recipeID)
    answer(171, 2, {})
    p4.advance(1)
    assert.are.equal(3, p4.guild.lastQuery.recipeID)
    answer(171, 3, {})
    assert.are.same({ 1, 2, 3 }, order)
  end)

  it("times out after 5s and continues with the next", function()
    local e1, e2
    GuildNative:Query(171, 1, function(_, e) e1 = e end)
    GuildNative:Query(171, 2, function(_, e) e2 = e end)
    p4.advance(4.9)
    assert.is_nil(e1)
    p4.advance(0.2)
    assert.are.equal("timeout", e1)
    assert.are.equal(1, p4.guild.queryCount)
    p4.advance(1)
    assert.are.equal(2, p4.guild.queryCount)
    assert.are.equal(2, p4.guild.lastQuery.recipeID)
    p4.advance(5)
    assert.are.equal("timeout", e2)
  end)

  it("ignores a late answer after its query timed out, but still caches it", function()
    local calls = 0
    GuildNative:Query(171, 1, function() calls = calls + 1 end)
    p4.advance(6)
    assert.are.equal(1, calls)
    answer(171, 1, { { "Bob", "Bob-Realm", "MAGE", true } })
    assert.are.equal(1, calls)
    assert.are.equal("Bob-Realm", GuildNative:Get("G-Realm", 1).members[1].name)
  end)

  it("serves the cache within 30 minutes without a server query", function()
    GuildNative:Query(171, 1234, function() end)
    answer(171, 1234, { { "Bob", "Bob-Realm", "MAGE", true } })
    local res
    GuildNative:Query(171, 1234, function(m) res = m end)
    assert.are.equal("Bob-Realm", res[1].name)
    assert.are.equal(1, p4.guild.queryCount)
    p4.advance(1799)
    GuildNative:Query(171, 1234, function() end)
    assert.are.equal(1, p4.guild.queryCount)
    p4.advance(2)
    GuildNative:Query(171, 1234, function() end)
    assert.are.equal(2, p4.guild.queryCount)       -- stale: asks again
  end)

  it("hands out copies, never the saved tables", function()
    answer(171, 5, { { "Bob", "Bob-Realm", "MAGE", true } })
    local res
    GuildNative:Query(171, 5, function(m) res = m end)
    res[1].name = "Changed"
    assert.are.equal("Bob-Realm", native()[5].members[1].name)
  end)

  it("serves a queued query from the cache when the answer arrived meanwhile", function()
    GuildNative:Query(171, 1, function() end)
    local res
    GuildNative:Query(171, 2, function(m) res = m end)
    answer(171, 2, { { "Ann", "Ann-Realm", "PRIEST", false } })     -- Blizzard's own panel asked for 2
    assert.is_nil(res)
    answer(171, 1, {})
    p4.advance(1)
    assert.are.equal("Ann-Realm", res[1].name)
    assert.are.equal(1, p4.guild.queryCount)                         -- no second server query
  end)

  it("passively caches Blizzard's own queries", function()
    answer(171, 999, { { "Ann", "Ann-Realm", "PRIEST", false } })
    local entry = GuildNative:Get("G-Realm", 999)
    assert.are.equal("Ann-Realm", entry.members[1].name)
    assert.are.equal(ns.FS:Now(), entry.time)
    assert.are.equal(171, native()[999].skillLineID)
    assert.is_nil(GuildNative:Get("G-Realm", 998))
    assert.is_nil(GuildNative:Get("Other-Realm", 999))
  end)

  it("skips secret names", function()
    answer(171, 5, { { p4.secret("x"), p4.secret("x"), "MAGE", true }, { "Ann", "Ann-Realm", "PRIEST", true } })
    assert.are.same({ { name = "Ann-Realm", classFile = "PRIEST", online = true } }, GuildNative:Get("G-Realm", 5).members)
    answer(171, 6, { { p4.secret("x"), p4.secret("x"), "MAGE", true } })
    assert.are.same({}, GuildNative:Get("G-Realm", 6).members)
  end)

  it("refuses while locked or guildless", function()
    p4.restriction.chatActive = true
    local e1; GuildNative:Query(171, 6, function(_, e) e1 = e end); assert.are.equal("locked", e1)
    assert.are.equal(0, p4.guild.queryCount)
    p4.restriction.chatActive = false; p4.guild.key = nil; Guild:OnGuildUpdate()
    local e2; GuildNative:Query(171, 6, function(_, e) e2 = e end); assert.are.equal("noguild", e2)
    assert.are.equal(0, p4.guild.queryCount)
  end)

  it("reports locked for a queued query when the gate closes before it starts", function()
    GuildNative:Query(171, 1, function() end)
    local e2; GuildNative:Query(171, 2, function(_, e) e2 = e end)
    answer(171, 1, {})
    p4.restriction.chatActive = true
    p4.advance(1)
    assert.are.equal("locked", e2)
    assert.are.equal(1, p4.guild.queryCount)
  end)

  it("reports unavailable when the API returns nothing or the globals are missing", function()
    _G.C_GuildInfo.QueryGuildMembersForRecipe = function() return nil end
    local e1; GuildNative:Query(171, 1, function(_, e) e1 = e end); assert.are.equal("unavailable", e1)
    p4.advance(1)
    local e2; GuildNative:Query(171, 2, function(_, e) e2 = e end); assert.are.equal("unavailable", e2)
    _G.C_GuildInfo.QueryGuildMembersForRecipe = function() return 3 end
    _G.GetGuildRecipeInfoPostQuery = nil
    local e3; GuildNative:Query(171, 3, function(_, e) e3 = e end); assert.are.equal("unavailable", e3)
    assert.is_false(GuildNative:IsAvailable())
    assert.are.equal(0, GuildNative:QueueSize())
    assert.are.same({}, ns.FS.db.global.diagnostics and ns.FS.db.global.diagnostics.errors or {})
  end)

  it("keeps going after an unavailable result", function()
    local calls = 0
    _G.C_GuildInfo.QueryGuildMembersForRecipe = function() calls = calls + 1; return nil end
    local e1, e2
    GuildNative:Query(171, 1, function(_, e) e1 = e end)
    GuildNative:Query(171, 2, function(_, e) e2 = e end)
    assert.are.equal("unavailable", e1)
    p4.advance(1)
    assert.are.equal("unavailable", e2)
    assert.are.equal(2, calls)
  end)

  it("does nothing on the event outside a guild or without the globals", function()
    p4.guild.key = nil; Guild:OnGuildUpdate()
    answer(171, 7, { { "Ann", "Ann-Realm", "PRIEST", false } })
    assert.is_nil(GuildNative:Get("G-Realm", 7))
    p4.guild.key = { "G", "Realm" }; Guild:OnGuildUpdate()
    _G.GetGuildRecipeMember = nil
    assert.has_no.errors(function() GuildNative:OnRecipeKnownByMembers() end)
    assert.is_nil(GuildNative:Get("G-Realm", 7))
  end)

  it("refuses a 21st waiting query with full", function()
    for i = 1, 21 do GuildNative:Query(171, i, function() end) end   -- 1 in flight + 20 waiting
    assert.are.equal(20, GuildNative:QueueSize())
    local e; GuildNative:Query(171, 22, function(_, err) e = err end)
    assert.are.equal("full", e)
    assert.are.equal(20, GuildNative:QueueSize())
  end)

  it("survives a throwing callback and still runs the queue", function()
    GuildNative:Query(171, 1, function() error("boom") end)
    local res
    GuildNative:Query(171, 2, function(m) res = m end)
    answer(171, 1, {})
    p4.advance(1)
    answer(171, 2, {})
    assert.are.same({}, res)
    assert.is_true(Guild:IsEnabled())
  end)

  describe("storage", function()
    it("caps the saved answers at 500 recipes, oldest first", function()
      for i = 1, 500 do
        answer(171, i, {})
        p4.advance(1)
      end
      assert.is_not_nil(GuildNative:Get("G-Realm", 1))
      answer(171, 501, {})
      assert.is_nil(GuildNative:Get("G-Realm", 1))
      assert.is_not_nil(GuildNative:Get("G-Realm", 2))
      assert.is_not_nil(GuildNative:Get("G-Realm", 501))
      local n = 0
      for _ in pairs(native()) do n = n + 1 end
      assert.are.equal(500, n)
    end)

    it("is pruned with the profiles after 30 days", function()
      answer(171, 1, {})
      p4.advance(15 * DAY)
      answer(171, 2, {})
      p4.advance(15 * DAY + 1)
      Guild:Prune(ns.FS:Now())
      assert.is_nil(native()[1])
      assert.is_not_nil(native()[2])
      native()[3] = "junk"
      Guild:Prune(ns.FS:Now())
      assert.is_nil(native()[3])
    end)

    it("ignores damaged saved entries", function()
      native()[8] = { time = "x", members = {} }
      native()[9] = { time = ns.FS:Now() }
      assert.is_nil(GuildNative:Get("G-Realm", 8))
      assert.is_nil(GuildNative:Get("G-Realm", 9))
    end)

    it("while the saved data is from a newer version, resolves the query but writes nothing", function()
      local res
      native()[77] = { time = ns.FS:Now(), members = {} }          -- the guild's directory exists before the flip
      GuildNative:Query(171, 4, function(m) res = m end)
      p4.advance(2)
      ns.FS.dbIsNewer = true
      local snapshot = ns.Util.DeepCopy(ns.FS.db.global, 30)
      answer(171, 4, { { "Bob", "Bob-Realm", "MAGE", true } })
      assert.are.equal("Bob-Realm", res[1].name)
      assert.are.same(snapshot, ns.Util.DeepCopy(ns.FS.db.global, 30))
      assert.is_nil(GuildNative:Get("G-Realm", 4))
      answer(171, 78, { { "Ann", "Ann-Realm", "PRIEST", false } })   -- a passive capture writes nothing either
      assert.are.same(snapshot, ns.Util.DeepCopy(ns.FS.db.global, 30))
    end)

    it("does not cache a late answer in another guild's directory", function()
      GuildNative:Query(171, 11, function() end)
      p4.advance(6)                                                    -- timed out
      p4.guild.key = { "Other", "Realm" }; Guild:OnGuildUpdate()
      answer(171, 11, { { "Bob", "Bob-Realm", "MAGE", true } })        -- the old guild's late answer
      assert.is_nil(GuildNative:Get("Other-Realm", 11))
      assert.is_nil(GuildNative:Get("G-Realm", 11))
      answer(171, 12, { { "Ann", "Ann-Realm", "PRIEST", false } })     -- Blizzard's own panel query: still captured
      assert.is_not_nil(GuildNative:Get("Other-Realm", 12))
      p4.advance(31)
      answer(171, 11, { { "Bob", "Bob-Realm", "MAGE", true } })        -- long after: just a normal capture
      assert.is_not_nil(GuildNative:Get("Other-Realm", 11))
    end)

    it("drops the answer of a query that was in flight when the guild changed", function()
      GuildNative:Query(171, 13, function() end)
      p4.guild.key = { "Other", "Realm" }; Guild:OnGuildUpdate()
      answer(171, 13, { { "Bob", "Bob-Realm", "MAGE", true } })
      assert.is_nil(GuildNative:Get("Other-Realm", 13))
    end)
  end)

  describe("FS_GUILD_CHANGED", function()
    local function changes()
      p4.advance(1)
      return #p4.messages("FS_GUILD_CHANGED")
    end

    it("follows a passive capture and an answered query, not an unchanged re-capture", function()
      local base = changes()
      answer(171, 20, { { "Ann", "Ann-Realm", "PRIEST", false } })
      assert.are.equal(base + 1, changes())
      local t = ns.FS:Now()
      answer(171, 20, { { "Ann", "Ann-Realm", "PRIEST", false } })     -- same members, newer time
      assert.are.equal(base + 1, changes())
      assert.are.equal(t, GuildNative:Get("G-Realm", 20).time)
      answer(171, 20, { { "Ann", "Ann-Realm", "PRIEST", true } })      -- went online
      assert.are.equal(base + 2, changes())
      GuildNative:Query(171, 21, function() end)
      answer(171, 21, { { "Bob", "Bob-Realm", "MAGE", true } })
      assert.are.equal(base + 3, changes())
    end)

    it("is debounced to one message for a burst of captures", function()
      local base = changes()
      for i = 30, 35 do answer(171, i, {}) end
      assert.are.equal(base + 1, changes())
    end)
  end)

  describe("errors", function()
    it("logs a throwing query API once and reports unavailable", function()
      _G.C_GuildInfo.QueryGuildMembersForRecipe = function() error("boom") end
      local e1, e2
      GuildNative:Query(171, 1, function(_, e) e1 = e end)
      p4.advance(1)
      GuildNative:Query(171, 2, function(_, e) e2 = e end)
      assert.are.equal("unavailable", e1); assert.are.equal("unavailable", e2)
      local logged = 0
      for _, entry in ipairs(ns.FS.db.global.diagnostics.errors) do
        if entry.source == "GuildNative" then logged = logged + 1 end
      end
      assert.are.equal(1, logged)
      assert.is_true(Guild:IsEnabled())
    end)
  end)

  describe("lifecycle", function()
    it("fails pending queries with noguild when the guild changes", function()
      local e1, e2
      GuildNative:Query(171, 1, function(_, e) e1 = e end)
      GuildNative:Query(171, 2, function(_, e) e2 = e end)
      p4.guild.key = { "Other", "Realm" }; Guild:OnGuildUpdate()
      assert.are.equal("noguild", e1); assert.are.equal("noguild", e2)
      assert.are.equal(0, GuildNative:QueueSize())
      p4.advance(30)
      assert.are.equal(1, p4.guild.queryCount)
    end)

    it("leaves no registrations, timers or queries behind when Guild is disabled", function()
      local e1, e2
      GuildNative:Query(171, 1, function(_, e) e1 = e end)
      GuildNative:Query(171, 2, function(_, e) e2 = e end)
      local cancelled = {}
      local original = ns.FS.CancelDebounce
      ns.FS.CancelDebounce = function(self, key) cancelled[key] = true; return original(self, key) end
      Guild:Disable()
      ns.FS.CancelDebounce = original
      assert.is_true(cancelled["guildNative.next"]); assert.is_true(cancelled["guildNative.timeout"])
      assert.are.equal("unavailable", e1); assert.are.equal("unavailable", e2)
      assert.are.same({ events = {}, messages = {} }, W.registrations(Guild))
      p4.advance(60)
      assert.are.equal(1, p4.guild.queryCount)
      local e3; GuildNative:Query(171, 3, function(_, e) e3 = e end)
      assert.are.equal("noguild", e3)
      answer(171, 3, {})
      assert.is_nil(GuildNative:Get("G-Realm", 3))
    end)

    it("never raises into Guild from the event handler", function()
      _G.GetGuildRecipeMember = function() error("boom") end
      answer(171, 10, { { "Bob", "Bob-Realm", "MAGE", true } })
      assert.is_true(Guild:IsEnabled())
    end)
  end)
end)
