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
end)
