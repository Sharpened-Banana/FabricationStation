-- Social.RecipeIndex: recipeID -> { charKey = code } over the compact stored profiles.
describe("Social.RecipeIndex", function()
  local RI
  before_each(function()
    install_wow_stubs()
    local ns = load_addon({}, "Core/DB.lua")
    load_files(ns, { "Modules/Social/Util.lua", "Modules/Social/Protocol.lua", "Modules/Social/ProfileStore.lua",
      "Modules/Social/RecipeIndex.lua" })
    RI = ns.Social.RecipeIndex
  end)

  it("indexes each recipe of a profile under its character with line and qualities", function()
    local idx = RI.New()
    assert.is_true(idx:Set("B-Realm", { h = "h1", lv = "q",
      pr = { { s = 1, r = ",5:00," }, { s = 2, r = ",100:35," } } }))
    assert.are.same({ ["B-Realm"] = RI.Code(2, 3, 5) }, idx:Lookup(100))
    assert.are.same({ 2, 3, 5 }, { RI.Decode(idx:Lookup(100)["B-Realm"]) })
    assert.are.same({ 1, 0, 0 }, { RI.Decode(idx:Lookup(5)["B-Realm"]) })
    assert.are.equal("h1", idx:HashOf("B-Realm"))
  end)

  it("replaces a character's entries on Set and forgets them on Remove", function()
    local idx = RI.New()
    idx:Set("B-Realm", { h = "h1", lv = "q", pr = { { s = 2, r = ",100:35," } } })
    idx:Set("B-Realm", { h = "h2", lv = "r", pr = { { s = 2, r = ",101," } } })
    assert.is_nil(idx:Lookup(100))
    assert.are.same({ ["B-Realm"] = RI.Code(1, 0, 0) }, idx:Lookup(101))
    assert.are.equal("h2", idx:HashOf("B-Realm"))
    idx:Remove("B-Realm")
    assert.is_nil(idx:Lookup(101))
    assert.is_nil(idx:HashOf("B-Realm"))
    assert.are.same({}, idx:Keys())
  end)

  it("indexes nothing for a profile without pr", function()
    local idx = RI.New()
    assert.is_false(idx:Set("X", { h = "h" }))
    assert.is_nil(idx:HashOf("X"))
    idx:Set("X", { h = "h", lv = "r", pr = { { s = 1, r = ",7," } } })
    assert.is_false(idx:Set("X", { h = "h2" }))                  -- and drops what was there
    assert.is_nil(idx:Lookup(7))
    assert.is_nil(idx:HashOf("X"))
  end)

  it("keeps the first line that lists a recipe, as ProfileStore.Find does", function()
    local idx = RI.New()
    local profile = { h = "h", lv = "q", pr = { { s = 1, r = ",9:21," }, { s = 2, r = ",9:45," } } }
    idx:Set("A-Realm", profile)
    assert.are.same({ 1, 2, 1 }, { RI.Decode(idx:Lookup(9)["A-Realm"]) })
  end)

  it("lists several characters under one recipe and its keys sorted", function()
    local idx = RI.New()
    idx:Set("B-Realm", { h = "b", lv = "r", pr = { { s = 1, r = ",5," } } })
    idx:Set("A-Realm", { h = "a", lv = "r", pr = { { s = 1, r = ",5,6," } } })
    assert.are.same({ ["A-Realm"] = RI.Code(1, 0, 0), ["B-Realm"] = RI.Code(1, 0, 0) }, idx:Lookup(5))
    assert.are.same({ "A-Realm", "B-Realm" }, idx:Keys())
    idx:Remove("A-Realm")
    assert.are.same({ ["B-Realm"] = RI.Code(1, 0, 0) }, idx:Lookup(5))
    assert.is_nil(idx:Lookup(6))
  end)

  it("skips malformed stored lines without raising", function()
    local idx = RI.New()
    assert.is_true(idx:Set("J-Realm", { h = "h", lv = "q", pr = { "junk", { s = 1, r = 5 }, { s = 2, r = ",8:11,x:yy," } } }))
    assert.are.same({ ["J-Realm"] = RI.Code(3, 1, 1) }, idx:Lookup(8))
  end)
end)
