describe("Social.Util", function()
  local ns, p4, Util
  before_each(function()
    ns, _, p4 = boot_phase4({ "Modules/Social/Util.lua", "Modules/Social/Gate.lua" })
    Util = ns.Social.Util
  end)

  it("hashes with djb2 mod 2^32", function()
    assert.are.equal("00001505", Util.Hash32(""))
    assert.are.equal("0b885c8b", Util.Hash32("abc"))
    assert.are.equal("f9cb8f84", Util.Hash32("Name-Realm"))
  end)

  it("stays 8 lowercase hex digits for long input", function()
    local h = Util.Hash32(("x"):rep(5000))
    assert.is_truthy(h:match("^%x%x%x%x%x%x%x%x$"))
    assert.are.equal(h:lower(), h)
  end)

  it("normalizes names consistently", function()
    assert.are.equal("Thrall-Area52", Util.NormalizeName("Thrall", "Area 52"))
    assert.are.equal("Thrall-Area52", Util.NormalizeName("Thrall-Area 52"))
    assert.are.equal("Thrall-Mal'Ganis", Util.NormalizeName("Thrall-Mal'Ganis"))
    assert.are.equal("Thrall-Realm", Util.NormalizeName("Thrall"))
    assert.is_nil(Util.NormalizeName(nil))
  end)

  it("returns anything that is not a plain name unchanged", function()
    assert.are.equal("", Util.NormalizeName(""))
    assert.are.equal(42, Util.NormalizeName(42))
  end)

  it("fills defaults without overwriting false", function()
    local t = Util.ApplyDefaults({ a = false, n = { x = 1 } }, { a = true, b = 2, n = { x = 9, y = 3 } })
    assert.are.same({ a = false, b = 2, n = { x = 1, y = 3 } }, t)
  end)

  it("copies default tables instead of sharing them", function()
    local defaults = { n = { list = { 1, 2 } } }
    local t = Util.ApplyDefaults({}, defaults)
    assert.are.same({ n = { list = { 1, 2 } } }, t)
    assert.are_not.equal(defaults.n, t.n)
    assert.are_not.equal(defaults.n.list, t.n.list)
    t.n.list[1] = 99
    assert.are.equal(1, defaults.n.list[1])
  end)

  it("builds guild keys", function()
    p4.guild.key = { "Crafters United", nil }
    assert.are.equal("Crafters United-Realm", Util.GuildKey())
    p4.guild.key = nil
    assert.is_nil(Util.GuildKey())
  end)

  it("takes the guild realm from the 4th return, never the rank name (preflight row 10)", function()
    p4.guild.rank = "Guild Master"
    p4.guild.key = { "Crafters United", "Area52" }
    assert.are.equal("Crafters United-Area52", Util.GuildKey())
    p4.guild.rank = "Initiate"
    assert.are.equal("Crafters United-Area52", Util.GuildKey())   -- the same for alts of any rank
    p4.guild.key = { "Crafters United", nil }
    assert.are.equal("Crafters United-Realm", Util.GuildKey())
  end)

  it("is nil while the guild name is not loaded yet", function()
    _G.IsInGuild = function() return true end
    _G.GetGuildInfo = function() return nil end
    assert.is_nil(Util.GuildKey())
    _G.GetGuildInfo = function() return "", "Member", 0, nil end
    assert.is_nil(Util.GuildKey())
  end)

  describe("CurrentLines", function()
    local function rec(profs) return { professions = profs } end
    before_each(function()
      ns.GameData = { Get = function(name)
        if name == "Knowledge" then return { variants = { [2906] = { base = 171 }, [2907] = { base = 164 } } } end
      end }
    end)

    it("lists Knowledge.variants lines and snapshot lines, sorted, and skips dropped and older records", function()
      local lines = Util.CurrentLines(rec({
        [2907] = { recipes = {} },                                   -- a Midnight variant line
        [2906] = { recipes = {}, dropped = true },                   -- dropped: never counts
        [2800] = { recipes = { [1] = true } },                       -- older expansion, no snapshot
        [2801] = { recipes = {}, concentration = { value = 1 } },    -- unknown to Knowledge, has a snapshot
      }))
      assert.are.same({ 2801, 2907 }, lines)
    end)

    it("does not list a snapshot line whose base profession a variant line already covers", function()
      local lines = Util.CurrentLines(rec({
        [2907] = { recipes = {} },                                                         -- Blacksmithing (base 164)
        [2800] = { recipes = {}, concentration = {}, parentSkillLineID = 164 },
      }))
      assert.are.same({ 2907 }, lines)
    end)

    it("lists every snapshot line when there is no Knowledge data", function()
      ns.GameData = { Get = function() return nil end }
      local lines = Util.CurrentLines(rec({
        [2906] = { recipes = {}, concentration = { value = 1 } },    -- snapshot: concentration
        [2907] = { recipes = {}, spec = {} },                        -- snapshot: spec
        [2800] = { recipes = { [1] = true } },                       -- plain line, no snapshot
        [2905] = { recipes = {}, concentration = {}, dropped = true }, -- dropped: never counts
      }))
      assert.are.same({ 2906, 2907 }, lines)
    end)

    it("caps the list and answers an empty list for a missing record", function()
      local profs = {}
      for i = 1, 9 do profs[3000 + i] = { concentration = {} } end
      assert.are.equal(6, #Util.CurrentLines(rec(profs), 6))
      assert.are.equal(9, #Util.CurrentLines(rec(profs)))
      assert.are.same({}, Util.CurrentLines(nil))
    end)
  end)
end)
