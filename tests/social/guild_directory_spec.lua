-- GuildDirectory: the read side of the guild data (crafters per recipe/item, tooltip and profession panel lines) and
-- ItemIndex, the itemID -> recipeIDs reverse index. Boots the real Scanner, Recipes, ProfessionPanel and Tooltips
-- (last = "UI/Tooltips.lua"); the Scanner's character list and schematic cache are p4.fake_module overrides, the
-- roster and the native query are the phase-4 harness fakes (p4.guild).
local SOCIAL_FILES = { "Modules/Social/Util.lua", "Modules/Social/Gate.lua", "Modules/Social/Codec.lua",
  "Modules/Social/Protocol.lua", "Modules/Social/ProfileStore.lua", "Modules/Social/Comm.lua",
  "Modules/Social/ItemIndex.lua", "Modules/Social/RecipeIndex.lua", "Modules/Social/Guild.lua",
  "Modules/Social/GuildNative.lua", "Modules/Social/GuildDirectory.lua", "Modules/Social/ChatMatcher.lua" }
local HOUR = 3600

describe("Social.ItemIndex", function()
  local ItemIndex
  before_each(function()
    local ns = boot_phase4({ "Modules/Social/Util.lua", "Modules/Social/ItemIndex.lua" })
    ItemIndex = ns.Social.ItemIndex
  end)

  it("indexes every output of a recipe, once, however often it is added", function()
    local calls = 0
    local idx = ItemIndex.New(function(id)
      calls = calls + 1
      return id == 100 and { 5001, 5002 } or { 6001 }
    end)
    idx:Add(100); idx:Add(100); idx:Add(200)
    assert.are.equal(2, calls)
    assert.are.same({ 100 }, idx:RecipesFor(5002))
    assert.are.same({ 100 }, idx:RecipesFor(5001))
    assert.are.same({ 200 }, idx:RecipesFor(6001))
    assert.is_true(idx:Has(100)); assert.is_false(idx:Has(300))
  end)

  it("lists several recipes for one item in the order they were added, without duplicates", function()
    local idx = ItemIndex.New(function() return { 7, 7 } end)
    idx:Add(3); idx:Add(1); idx:Add(2)
    assert.are.same({ 3, 1, 2 }, idx:RecipesFor(7))
  end)

  it("answers HasItem without allocating a list", function()
    local idx = ItemIndex.New(function() return { 7 } end)
    assert.is_false(idx:HasItem(7))
    idx:Add(1)
    assert.is_true(idx:HasItem(7)); assert.is_false(idx:HasItem(8))
  end)

  it("hands out copies and answers an unknown item with an empty list", function()
    local idx = ItemIndex.New(function() return { 7 } end)
    idx:Add(1)
    idx:RecipesFor(7)[1] = 99
    assert.are.same({ 1 }, idx:RecipesFor(7))
    assert.are.same({}, idx:RecipesFor(12345))
  end)

  it("ignores bad ids and bad resolver results, and retries a recipe that resolved to nothing", function()
    local outputs = {}
    local idx = ItemIndex.New(function() return outputs end)
    idx:Add(nil); idx:Add("x"); idx:Add(0)
    assert.is_false(idx:Has(0))
    idx:Add(5)
    assert.is_false(idx:Has(5))                         -- nothing resolved yet: not remembered
    outputs = { 8, "bad", -1, 0, false }
    idx:Add(5)
    assert.is_true(idx:Has(5))
    assert.are.same({ 5 }, idx:RecipesFor(8))
    local raising = ItemIndex.New(function() error("boom") end)
    assert.has_no.errors(function() raising:Add(1) end)
    assert.is_false(raising:Has(1))
    local garbage = ItemIndex.New(function() return "text" end)
    assert.has_no.errors(function() garbage:Add(1) end)
  end)
end)

describe("Social.Util.EscapePipes", function()
  local Util
  before_each(function()
    local ns = boot_phase4({ "Modules/Social/Util.lua" })
    Util = ns.Social.Util
  end)

  it("doubles every pipe so escape sequences print as text", function()
    assert.are.equal("Bob||cffff0000-Realm", Util.EscapePipes("Bob|cffff0000-Realm"))
    assert.are.equal("a||||b", Util.EscapePipes("a||b"))
    assert.are.equal("||T||h||H", Util.EscapePipes("|T|h|H"))
  end)

  it("leaves other text alone and turns a non-string into an empty string", function()
    assert.are.equal("Plain-Realm", Util.EscapePipes("Plain-Realm"))
    assert.are.equal("", Util.EscapePipes(nil))
    assert.are.equal("", Util.EscapePipes(42))
  end)
end)

describe("Guild directory", function()
  local ns, W, p4, Guild, ItemIndex, settings, tooltips, panel
  local schematics, apiSchematics, getSchematicCalls

  local function dir() return Guild:GetDirectory() end
  local function now() return ns.FS:Now() end
  local function names(rows)
    local out = {}
    for i, r in ipairs(rows) do out[i] = r.name end
    return out
  end

  -- A stored peer profile in the compact shape (Modules/Social/ProfileStore.lua): one skill line with the given
  -- recipes (id -> { q, qc } or true), packed from the DATA it would have come in, with that DATA's hash.
  local function store(charKey, owner, opts)
    opts = opts or {}
    local lv = opts.lv or "q"
    local recipes = opts.recipes or { [100] = { 3, 5 } }
    local ids = {}
    for id in pairs(recipes) do ids[#ids + 1] = id end
    table.sort(ids)
    local flat = {}
    for _, id in ipairs(ids) do
      flat[#flat + 1] = id
      if lv == "q" then
        flat[#flat + 1] = recipes[id][1]
        flat[#flat + 1] = recipes[id][2]
      end
    end
    local data = { lv = lv, pr = { { s = opts.line or 2907, k = opts.k or 50, m = 100, r = flat } } }
    dir().profiles[charKey] = { c = charKey, ts = 1, lv = lv, h = ns.Social.Protocol.HashProfile(data), owner = owner,
      verified = opts.verified ~= false, rt = opts.rt or now(), pr = ns.Social.ProfileStore.FromData(data) }
    Guild:_Changed()                                                     -- every real write to profiles does
  end
  local function native_members(recipeID, members, at)
    dir().native[recipeID] = { time = at or now(), skillLineID = 2907, members = members }
  end
  local NATIVE_B = { name = "B-Realm", classFile = "MAGE", online = false }
  local NATIVE_D = { name = "D-Realm", classFile = "ROGUE", online = true }
  local NATIVE_ME = { name = "Me-Realm", classFile = "MAGE", online = true }
  local function add_native_member(recipeID, name)
    local list = dir().native[recipeID].members
    list[#list + 1] = { name = name, classFile = "PRIEST", online = false }
  end

  local function seed()
    store("B-Realm", "Peer-Realm")                                        -- q3 / qc5
    store("C-Realm", "Peer2-Realm", { lv = "r" })                         -- recipes only
    native_members(100, { NATIVE_B, NATIVE_D, NATIVE_ME })
  end

  before_each(function()
    ns, W, p4 = boot_phase4(SOCIAL_FILES, { last = "UI/Tooltips.lua" })
    Guild = ns.FS:GetModule("Guild")
    ItemIndex = ns.Social.ItemIndex
    schematics = { [100] = { outputItemIDs = { [1] = 5001, [2] = 5002 } }, [101] = { outputItemIDs = { [1] = 5101 } } }
    apiSchematics = { [200] = { outputItemID = 6001 } }
    getSchematicCalls = 0
    p4.fake_module(ns, "Scanner", {
      GetCharacters = function() return { "Me-Realm" } end,
      GetCharacter = function() return { professions = {} } end,
      GetCachedSchematic = function(_, id) return schematics[id] end,
      GetSchematic = function() getSchematicCalls = getSchematicCalls + 1; return nil end,
    })
    C_TradeSkillUI.GetRecipeSchematic = function(id) return apiSchematics[id] end
    tooltips = ns.FS:GetModule("Tooltips")
    panel = ns.FS:GetModule("ProfessionPanel")
    settings = Guild:Settings()
    p4.guild.key = { "G", "Realm" }
    p4.guild.members = { { name = "Peer-Realm", online = true } }        -- a loaded (non-empty) roster
    Guild:OnGuildUpdate()
  end)

  ---------------------------------------------------------------------------
  -- Output resolution and the index
  ---------------------------------------------------------------------------

  describe("ResolveOutputs", function()
    it("reads every output of a cached schematic and never calls Scanner:GetSchematic", function()
      local out = Guild.ResolveOutputs(100)
      table.sort(out)
      assert.are.same({ 5001, 5002 }, out)
      assert.are.equal(0, getSchematicCalls)
    end)

    it("falls back to the uncached API schematic for a recipe nobody here has cached", function()
      assert.are.same({ 6001 }, Guild.ResolveOutputs(200))
      assert.are.equal(0, getSchematicCalls)
    end)

    it("answers an empty list when nothing resolves or the API raises", function()
      assert.are.same({}, Guild.ResolveOutputs(999))
      C_TradeSkillUI.GetRecipeSchematic = function() error("boom") end
      assert.are.same({}, Guild.ResolveOutputs(999))
      assert.are.same({}, Guild.ResolveOutputs(nil))
    end)

    it("indexes Scanner outputs with an API fallback", function()
      local idx = ItemIndex.New(Guild.ResolveOutputs)
      idx:Add(100); idx:Add(100); idx:Add(200)
      assert.are.same({ 100 }, idx:RecipesFor(5002))
      assert.are.same({ 200 }, idx:RecipesFor(6001))
    end)
  end)

  describe("item index", function()
    it("reads only the index once the ticks have run", function()
      for i = 1, 50 do store("C" .. i .. "-Realm", "Peer-Realm", { recipes = { [100 + i] = { 1, 1 } } }) end
      store("B-Realm", "Peer-Realm", { recipes = { [100] = { 3, 5 } } })
      Guild:RebuildItemIndex(); for _ = 1, 5 do p4.advance(0) end
      local finds, orig = 0, ns.Social.ProfileStore.Find
      ns.Social.ProfileStore.Find = function(...) finds = finds + 1; return orig(...) end
      finally(function() ns.Social.ProfileStore.Find = orig end)
      assert.are.same({ "B-Realm" }, names(Guild:GetCrafters(100)))
      assert.are.equal(0, finds)
    end)

    it("finds a profile stored after the last tick before the next tick", function()
      Guild:RebuildItemIndex(); for _ = 1, 3 do p4.advance(0) end
      store("N-Realm", "Peer-Realm", { recipes = { [100] = { 2, 2 } } })     -- no tick yet
      assert.are.same({ "N-Realm" }, names(Guild:GetCrafters(100)))
    end)

    it("drops a removed profile at once", function()
      store("B-Realm", "Peer-Realm"); Guild:RebuildItemIndex(); for _ = 1, 3 do p4.advance(0) end
      assert.are.same({ "B-Realm" }, names(Guild:GetCrafters(100)))
      dir().profiles["B-Realm"] = nil; Guild:_Changed()
      assert.are.same({}, Guild:GetCrafters(100))
    end)

    it("shows a profile whose DATA changed before the tick, not the old recipes", function()
      store("B-Realm", "Peer-Realm", { recipes = { [100] = { 3, 5 } } })
      Guild:RebuildItemIndex(); for _ = 1, 3 do p4.advance(0) end
      store("B-Realm", "Peer-Realm", { recipes = { [101] = { 1, 1 } } })    -- another hash, not indexed yet
      assert.are.same({}, Guild:GetCrafters(100))
      assert.are.same({ "B-Realm" }, names(Guild:GetCrafters(101)))
    end)

    it("bumps directoryVersion on every change, before the debounce", function()
      local v = Guild.directoryVersion
      assert.is_number(v)
      Guild:_Changed()
      assert.are.equal(v + 1, Guild.directoryVersion)
    end)

    it("indexes at most 20 profiles per tick and starts over on a guild change", function()
      for i = 1, 45 do store("C" .. i .. "-Realm", "Peer-Realm", { recipes = { [100 + i] = { 1, 1 } } }) end
      Guild:RebuildItemIndex()
      local function fresh()
        local n = 0
        for i = 1, 45 do
          local k = "C" .. i .. "-Realm"
          if Guild:GetRecipeIndex():HashOf(k) == dir().profiles[k].h then n = n + 1 end
        end
        return n
      end
      assert.are.equal(0, fresh())
      p4.advance(0); assert.are.equal(20, fresh())
      p4.advance(0); assert.are.equal(40, fresh())
      p4.advance(0); assert.are.equal(45, fresh())
      assert.are.equal(45, #Guild:GetRecipeIndex():Keys())
      p4.guild.key = { "H", "Realm" }
      Guild:OnGuildUpdate()
      ns.FS:SendMessage(ns.Msg.GUILD_CHANGED, "H-Realm")
      assert.are.same({}, Guild:GetRecipeIndex():Keys())
    end)

    it("gives a rebuild a fresh index and re-indexes every profile", function()
      store("B-Realm", "Peer-Realm")
      Guild:RebuildItemIndex(); p4.advance(0)
      assert.are.equal(dir().profiles["B-Realm"].h, Guild:GetRecipeIndex():HashOf("B-Realm"))
      Guild:RebuildItemIndex()
      assert.is_nil(Guild:GetRecipeIndex():HashOf("B-Realm"))
      assert.are.same({ "B-Realm" }, names(Guild:GetCrafters(100)))      -- still correct while stale
      p4.advance(0)
      assert.are.equal(dir().profiles["B-Realm"].h, Guild:GetRecipeIndex():HashOf("B-Realm"))
    end)

    it("drops the index when Guild is turned off", function()
      store("B-Realm", "Peer-Realm")
      Guild:RebuildItemIndex(); p4.advance(0)
      ns.FS:SetModuleEnabled("Guild", false)
      assert.are.same({}, Guild:GetRecipeIndex():Keys())
    end)

    it("adds the recipes of a stored profile when its DATA arrives", function()
      local Protocol = ns.Social.Protocol
      local profile = { c = "B-Realm", ts = 5, lv = "r", pr = { { s = 2907, k = 10, m = 100, r = { 100, 101 } } } }
      Guild:OnHello(Protocol.Hello("1.0.0", { ["B-Realm"] = Protocol.HashProfile(profile) }), "B-Realm", "GUILD")
      Guild:OnData(Protocol.Data(profile), "B-Realm", "WHISPER")
      p4.advance(1)                                                      -- FS_GUILD_CHANGED, then the index tick
      p4.advance(0)
      assert.are.same({ 100 }, Guild:GetItemIndex():RecipesFor(5001))
      assert.are.same({ 101 }, Guild:GetItemIndex():RecipesFor(5101))
    end)

    it("also indexes recipes that only the native cache knows", function()
      native_members(200, { NATIVE_D })
      ns.FS:SendMessage(ns.Msg.GUILD_CHANGED, "G-Realm")
      p4.advance(0)
      assert.are.same({ 200 }, Guild:GetItemIndex():RecipesFor(6001))
    end)

    it("rebuilds from the stored profiles, 200 recipes per tick", function()
      local recipes = {}
      for id = 1000, 1449 do recipes[id] = { 1, 1 } end                  -- 450 recipes
      store("B-Realm", "Peer-Realm", { recipes = recipes })
      schematics = setmetatable({}, { __index = function(_, id) return { outputItemIDs = { id + 100000 } } end })
      Guild:RebuildItemIndex()
      local idx = Guild:GetItemIndex()
      local function indexed()
        local n = 0
        for id = 1000, 1449 do if idx:Has(id) then n = n + 1 end end
        return n
      end
      assert.are.equal(0, indexed())                                     -- nothing before the first tick
      p4.advance(0); assert.are.equal(200, indexed())
      p4.advance(0); assert.are.equal(400, indexed())
      p4.advance(0); assert.are.equal(450, indexed())
      p4.advance(0); assert.are.equal(450, indexed())
    end)

    it("stops a tick at the time budget (at least one recipe) and continues next frame", function()
      local recipes = {}
      for id = 2000, 2009 do recipes[id] = { 1, 1 } end
      store("B-Realm", "Peer-Realm", { recipes = recipes })
      local clock = 0
      _G.debugprofilestop = function() return clock end
      finally(function() _G.debugprofilestop = nil end)
      p4.fake_module(ns, "Recipes", { GetSetting = function() return 4 end })
      C_TradeSkillUI.GetRecipeSchematic = function(id)         -- every uncached recipe costs 2 ms
        clock = clock + 2
        return { outputItemID = id + 100000 }
      end
      Guild:RebuildItemIndex()
      local idx = Guild:GetItemIndex()
      local function indexed()
        local n = 0
        for id = 2000, 2009 do if idx:Has(id) then n = n + 1 end end
        return n
      end
      p4.advance(0); assert.are.equal(2, indexed())              -- 2 ms, then 4 ms >= the 4 ms budget
      p4.advance(0); assert.are.equal(4, indexed())
      C_TradeSkillUI.GetRecipeSchematic = function(id) clock = clock + 50; return { outputItemID = id + 100000 } end
      p4.advance(0); assert.are.equal(5, indexed())              -- one very slow recipe still makes progress
    end)

    it("falls back to the 200-recipe cap when debugprofilestop is missing", function()
      _G.debugprofilestop = nil
      local recipes = {}
      for id = 3000, 3249 do recipes[id] = { 1, 1 } end
      store("B-Realm", "Peer-Realm", { recipes = recipes })
      schematics = setmetatable({}, { __index = function(_, id) return { outputItemIDs = { id + 100000 } } end })
      Guild:RebuildItemIndex(); p4.advance(0)
      local n = 0
      for id = 3000, 3249 do if Guild:GetItemIndex():Has(id) then n = n + 1 end end
      assert.are.equal(200, n)
    end)

    it("does the login index work once: the guild-changed message after it is incremental", function()
      local rebuilds, orig = 0, Guild.RebuildItemIndex
      Guild.RebuildItemIndex = function(self) rebuilds = rebuilds + 1; return orig(self) end
      finally(function() Guild.RebuildItemIndex = nil end)
      W.fire("PLAYER_ENTERING_WORLD", true, false)
      ns.FS:SendMessage(ns.Msg.GUILD_CHANGED, "G-Realm")
      ns.FS:SendMessage(ns.Msg.GUILD_CHANGED, "G-Realm")
      assert.are.equal(1, rebuilds)
      ns.FS:SendMessage(ns.Msg.GUILD_CHANGED, "Other-Realm")        -- a different guild does rebuild
      assert.are.equal(2, rebuilds)
    end)

    it("restarts cleanly when a rebuild is asked for during a rebuild", function()
      local recipes = {}
      for id = 1000, 1299 do recipes[id] = { 1, 1 } end
      store("B-Realm", "Peer-Realm", { recipes = recipes })
      schematics = setmetatable({}, { __index = function(_, id) return { outputItemIDs = { id + 100000 } } end })
      Guild:RebuildItemIndex(); p4.advance(0)
      Guild:RebuildItemIndex()
      for _ = 1, 5 do p4.advance(0) end
      assert.is_true(Guild:GetItemIndex():Has(1299))
    end)

    it("runs the login rebuild on the first loading screen and stops when Guild is turned off", function()
      local recipes = {}
      for id = 1000, 1399 do recipes[id] = { 1, 1 } end
      store("B-Realm", "Peer-Realm", { recipes = recipes })
      schematics = setmetatable({}, { __index = function(_, id) return { outputItemIDs = { id + 100000 } } end })
      W.fire("PLAYER_ENTERING_WORLD", true, false)
      p4.advance(0)
      assert.is_true(Guild:GetItemIndex():Has(1000))
      assert.is_false(Guild:GetItemIndex():Has(1399))                    -- the second tick has not run
      ns.FS:SetModuleEnabled("Guild", false)
      for _ = 1, 5 do p4.advance(0) end
      assert.is_false(Guild:GetItemIndex():Has(1399))
    end)
  end)

  ---------------------------------------------------------------------------
  -- GetCrafters
  ---------------------------------------------------------------------------

  describe("GetCrafters", function()
    before_each(function()
      seed()
      Guild:RebuildItemIndex(); p4.advance(0)
    end)

    it("merges addon and native rows, prefers addon, excludes own characters and sorts", function()
      local rows = Guild:GetCrafters(100)
      assert.are.same({ "B-Realm", "D-Realm", "C-Realm" }, names(rows))
      assert.are.equal("addon", rows[1].source)
      assert.are.equal(3, rows[1].expectedQuality)
      assert.are.equal(5, rows[1].concentrationQuality)
      assert.are.equal(50, rows[1].skill)
      assert.are.equal("Peer-Realm", rows[1].owner)
      assert.are.equal("native", rows[2].source)
      assert.is_nil(rows[2].expectedQuality); assert.is_nil(rows[2].skill)
      assert.is_true(rows[2].online)
      assert.are.equal("addon", rows[3].source)
      assert.is_nil(rows[3].expectedQuality)                            -- lv "r"
      assert.is_nil(rows[3].concentrationQuality)
    end)

    it("takes the online flag of an addon row from the native answer when it has one", function()
      native_members(100, { { name = "B-Realm", classFile = "MAGE", online = true } })
      assert.is_true(Guild:GetCrafters(100)[1].online)
    end)

    it("treats a stored quality of 0 as unknown", function()
      store("B-Realm", "Peer-Realm", { recipes = { [100] = { 0, 0 } } })
      local row
      for _, r in ipairs(Guild:GetCrafters(100)) do if r.name == "B-Realm" then row = r end end
      assert.are.equal("addon", row.source)
      assert.is_nil(row.expectedQuality); assert.is_nil(row.concentrationQuality)
    end)

    it("sorts by quality, then online first, then name", function()
      store("A-Realm", "Peer-Realm", { recipes = { [100] = { 5, 5 } } })
      store("Z-Realm", "Peer-Realm", { recipes = { [100] = { 3, 3 } } })
      native_members(100, { NATIVE_D, { name = "Q-Realm", online = false }, { name = "E-Realm", online = false } })
      assert.are.same({ "A-Realm", "B-Realm", "Z-Realm", "D-Realm", "C-Realm", "E-Realm", "Q-Realm" },
        names(Guild:GetCrafters(100)))
    end)

    it("hides crafters whose owner left the guild", function()
      dir().native[100].members = { NATIVE_D }                            -- B left, so the server no longer lists B
      p4.guild.exists["Peer-Realm"] = false
      assert.are.same({ "D-Realm", "C-Realm" }, names(Guild:GetCrafters(100)))
    end)

    it("shows nothing from another guild's data", function()
      p4.guild.key = { "Other", nil }; Guild:OnGuildUpdate()
      assert.are.same({}, Guild:GetCrafters(100))
    end)

    it("shows nothing outside a guild", function()
      p4.guild.key = nil; Guild:OnGuildUpdate()
      assert.are.same({}, Guild:GetCrafters(100))
    end)

    it("skips native rows when the native fallback is turned off, and addon rows stay", function()
      settings.useNative = false
      assert.are.same({ "B-Realm", "C-Realm" }, names(Guild:GetCrafters(100)))
    end)

    it("marks an unverified copy and keeps who reported it", function()
      store("U-Realm", "Peer-Realm", { verified = false })
      local row
      for _, r in ipairs(Guild:GetCrafters(100)) do if r.name == "U-Realm" then row = r end end
      assert.is_false(row.verified)
      assert.are.equal("Peer-Realm", row.owner)
      assert.is_true(Guild:GetCrafters(100)[1].verified)
    end)

    it("shows no addon row for a contested character, even with a stored copy", function()
      store("K-Realm", "Peer-Realm", { recipes = { [100] = { 5, 5 } } })
      assert.are.equal("K-Realm", Guild:GetCrafters(100)[1].name)
      dir().contested["K-Realm"] = now()
      assert.are.same({ "B-Realm", "D-Realm", "C-Realm" }, names(Guild:GetCrafters(100)))
    end)

    it("still shows a contested name that the server's native answer lists, without addon quality", function()
      store("K-Realm", "Peer-Realm", { recipes = { [100] = { 5, 5 } } })
      dir().contested["K-Realm"] = now()
      native_members(100, { NATIVE_D, { name = "K-Realm", classFile = "MAGE", online = false } })
      local k
      for _, r in ipairs(Guild:GetCrafters(100)) do if r.name == "K-Realm" then k = r end end
      assert.are.equal("native", k.source)
      assert.is_nil(k.expectedQuality); assert.is_nil(k.owner)
    end)

    it("reads the recipe from any skill line of a profile", function()
      store("L-Realm", "Peer-Realm", { line = 2908, recipes = { [100] = { 4, 4 } } })
      local profile = dir().profiles["L-Realm"]
      table.insert(profile.pr, { s = 2909, k = 7, m = 100, r = ",555," })
      assert.are.equal("L-Realm", names(Guild:GetCrafters(100))[1])
      assert.are.same({}, Guild:GetCrafters(556))
    end)

    it("survives damaged saved data", function()
      dir().profiles["X-Realm"] = "junk"
      dir().profiles["Y-Realm"] = { owner = "Peer-Realm", pr = "junk" }
      dir().profiles["W-Realm"] = { owner = "Peer-Realm", rt = now(), pr = { [1] = { r = 5 }, [2] = "junk" } }
      dir().native[100].members[#dir().native[100].members + 1] = "junk"
      dir().native[100].members[#dir().native[100].members + 1] = { name = 5 }
      assert.has_no.errors(function() Guild:GetCrafters(100) end)
      assert.are.same({ "B-Realm", "D-Realm", "C-Realm" }, names(Guild:GetCrafters(100)))
    end)

    it("returns nothing while Guild is turned off", function()
      ns.FS:SetModuleEnabled("Guild", false)
      assert.are.same({}, Guild:GetCrafters(100))
    end)

    it("creates no saved data and writes nothing while the saved data is read-only", function()
      ns.FS.db.global.guildDirectory = nil
      ns.FS.dbIsNewer = true
      assert.are.same({}, Guild:GetCrafters(100))
      assert.are.same({}, Guild:TooltipLines(5001))
      assert.are.same({}, Guild:PanelLines(100, "Me-Realm"))
      assert.is_nil(ns.FS.db.global.guildDirectory)
    end)
  end)

  describe("GetCraftersForItem", function()
    before_each(function()
      seed()
      Guild:RebuildItemIndex(); p4.advance(0)
    end)

    it("lists the crafters of every recipe that makes the item", function()
      store("E-Realm", "Peer-Realm", { recipes = { [101] = { 2, 2 } } })
      schematics[101] = { outputItemIDs = { 5001 } }                      -- a second recipe for 5001
      Guild:RebuildItemIndex(); p4.advance(0)
      local out = Guild:GetCraftersForItem(5001)
      table.sort(out, function(a, b) return a.recipeID < b.recipeID end)
      assert.are.equal(2, #out)
      assert.are.equal(100, out[1].recipeID); assert.are.same({ "B-Realm", "D-Realm", "C-Realm" }, names(out[1].crafters))
      assert.are.equal(101, out[2].recipeID); assert.are.same({ "E-Realm" }, names(out[2].crafters))
    end)

    it("leaves out recipes nobody crafts and answers an unknown item with an empty list", function()
      assert.are.same({}, Guild:GetCraftersForItem(123456))
      dir().profiles = {}; dir().native = {}
      assert.are.same({}, Guild:GetCraftersForItem(5001))
    end)
  end)

  ---------------------------------------------------------------------------
  -- Tooltip line
  ---------------------------------------------------------------------------

  describe("TooltipLines", function()
    before_each(function()
      seed()
      Guild:RebuildItemIndex(); p4.advance(0)
    end)

    it("renders one compact line and never queries the server", function()
      assert.are.same({ { "Guild crafters", "B-Realm (Q3), D-Realm, C-Realm" } }, Guild:TooltipLines(5001))
      add_native_member(100, "E-Realm")
      assert.truthy(Guild:TooltipLines(5001)[1][2]:find("%+1 more$"))
      assert.are.equal(0, p4.guild.queryCount)
      settings.tooltipLine = false
      assert.are.same({}, Guild:TooltipLines(5001))
    end)

    it("gives no line for an item nobody here crafts", function()
      assert.are.same({}, Guild:TooltipLines(424242))
      assert.are.same({}, Guild:TooltipLines(nil))
    end)

    it("shows an unverified copy as reported by its owner", function()
      dir().profiles["B-Realm"].verified = false
      local right = Guild:TooltipLines(5001)[1][2]
      assert.truthy(right:find("B-Realm (via Peer-Realm) (Q3)", 1, true))
    end)

    it("escapes pipe sequences in peer names", function()
      store("Ev|cffff0000il-Realm", "Peer-Realm", { recipes = { [100] = { 5, 5 } } })
      local right = Guild:TooltipLines(5001)[1][2]
      assert.truthy(right:find("Ev||cffff0000il-Realm (Q5)", 1, true))
      assert.is_nil(right:find("[^|]|c"))
    end)

    it("keeps the best quality when several recipes list the same crafter", function()
      schematics[101] = { outputItemIDs = { 5001 } }                      -- a second recipe for 5001
      store("B-Realm", "Peer-Realm", { recipes = { [100] = { 3, 3 }, [101] = { 5, 5 } } })
      Guild:RebuildItemIndex(); p4.advance(0)
      local right = Guild:TooltipLines(5001)[1][2]
      assert.truthy(right:find("B-Realm (Q5)", 1, true))
      assert.is_nil(right:find("Q3", 1, true))
      local first = right:find("B-Realm", 1, true)
      assert.is_nil(right:find("B-Realm", first + 1, true))        -- listed once
    end)

    it("escapes pipe sequences in native names", function()
      native_members(100, { NATIVE_D, { name = "Ev|cffff0000il-Realm", online = true } })
      local right = Guild:TooltipLines(5001)[1][2]
      assert.truthy(right:find("Ev||cffff0000il-Realm", 1, true))
      assert.is_nil(right:find("[^|]|c"))
    end)

    it("returns nothing while Guild is turned off", function()
      ns.FS:SetModuleEnabled("Guild", false)
      assert.are.same({}, Guild:TooltipLines(5001))
    end)

    it("does not throw on damaged data", function()
      dir().profiles["X-Realm"] = { owner = {}, rt = "x", pr = { { s = 1, r = ",100:xx," } } }
      assert.has_no.errors(function() Guild:TooltipLines(5001) end)
    end)
  end)

  ---------------------------------------------------------------------------
  -- Profession panel lines
  ---------------------------------------------------------------------------

  describe("PanelLines", function()
    before_each(function()
      seed()
      Guild:RebuildItemIndex(); p4.advance(0)
    end)

    local function find(lines, text)
      for _, l in ipairs(lines) do if l[1]:find(text, 1, true) then return l end end
    end

    it("starts with a header and lists addon rows with their quality and age", function()
      store("B-Realm", "Peer-Realm", { rt = now() - 2 * HOUR })
      local lines = Guild:PanelLines(100, "Me-Realm")
      assert.are.equal("Guild crafters", lines[1][1])
      local b = find(lines, "B-Realm")
      assert.truthy(b[2]:find("Q3", 1, true))
      assert.truthy(b[2]:find("synced 2h ago", 1, true))
    end)

    it("marks native rows as quality unknown", function()
      local d = find(Guild:PanelLines(100, "Me-Realm"), "D-Realm")
      assert.truthy(d[2]:find("quality unknown", 1, true))
      assert.is_nil(d[2]:find("synced", 1, true))
    end)

    it("measures the age from the receive time", function()
      dir().profiles["B-Realm"].ts = now() - 30 * 86400
      dir().profiles["B-Realm"].rt = now() - 30
      assert.truthy(find(Guild:PanelLines(100, "Me-Realm"), "B-Realm")[2]:find("synced <1m ago", 1, true))
    end)

    it("shows an unverified copy as reported by its owner", function()
      dir().profiles["B-Realm"].verified = false
      assert.truthy(find(Guild:PanelLines(100, "Me-Realm"), "B-Realm (via Peer-Realm)"))
    end)

    it("caps the list at five crafters and counts the rest", function()
      for i = 1, 6 do store(("P%d-Realm"):format(i), "Peer-Realm") end
      local lines = Guild:PanelLines(100, "Me-Realm")
      assert.are.equal(1 + 5 + 1, #lines)
      assert.are.equal("+4 more", lines[#lines][1])
    end)

    it("escapes pipe sequences in peer names", function()
      store("Ev|Tx-Realm", "Pe|cffer-Realm", { verified = false })
      local lines = Guild:PanelLines(100, "Me-Realm")
      local row = find(lines, "Ev||Tx-Realm")
      assert.truthy(row[1]:find("via Pe||cffer-Realm", 1, true))
    end)

    it("escapes pipe sequences in native names", function()
      native_members(100, { { name = "Ev|Tx-Realm", online = true } })
      local row = find(Guild:PanelLines(100, "Me-Realm"), "Ev||Tx-Realm")
      assert.is_not_nil(row)
      assert.is_nil(row[1]:find("[^|]|T"))
    end)

    it("is empty without crafters, with the setting off and while Guild is off", function()
      assert.are.same({}, Guild:PanelLines(777, "Me-Realm"))
      settings.panelLine = false
      assert.are.same({}, Guild:PanelLines(100, "Me-Realm"))
      settings.panelLine = true
      ns.FS:SetModuleEnabled("Guild", false)
      assert.are.same({}, Guild:PanelLines(100, "Me-Realm"))
    end)
  end)

  ---------------------------------------------------------------------------
  -- "Ask guild" in the profession panel: the native fallback for any selected recipe
  ---------------------------------------------------------------------------

  describe("PanelAction", function()
    local function answer(recipeID, list)
      p4.guild.postQuery = { skillLineID = 2907, recipeID = recipeID, list = list }
      ns.Social.GuildNative:OnRecipeKnownByMembers()
    end

    before_each(function()
      schematics[300] = { skillLineID = 2907, outputItemIDs = { [1] = 7001 } }   -- a recipe nobody listed
    end)

    it("offers Ask guild for a recipe the directory does not list, and asks only when clicked", function()
      local a = Guild:PanelAction(300)
      for _ = 1, 3 do Guild:PanelAction(300) end
      assert.are.equal(0, p4.guild.queryCount)                 -- drawing the panel never asks
      assert.are.equal("Ask guild", a.text)
      assert.is_true(a.enabled)
      assert.is_nil(a.status)
      a.onClick()
      assert.are.equal(1, p4.guild.queryCount)
      assert.are.same({ skillLineID = 2907, recipeID = 300 }, { skillLineID = p4.guild.lastQuery.skillLineID,
        recipeID = p4.guild.lastQuery.recipeID })
    end)

    it("says a question is pending, then shows the answer and the crafters it found", function()
      Guild:PanelAction(300).onClick()
      local pending = Guild:PanelAction(300)
      assert.is_false(pending.enabled)
      assert.are.equal("Asking the guild...", pending.status)
      answer(300, { { "Bob", "Bob-Realm", "MAGE", true } })
      local done = Guild:PanelAction(300)
      assert.is_true(done.enabled)
      assert.are.equal("Guild answered: 1 can craft this", done.status)
      local found
      for _, l in ipairs(Guild:PanelLines(300, "Me-Realm")) do if l[1]:find("Bob-Realm", 1, true) then found = l end end
      assert.is_not_nil(found)
    end)

    it("goes through GuildNative's queue: a second recipe waits for the first", function()
      schematics[301] = { skillLineID = 2907 }
      Guild:PanelAction(300).onClick()
      Guild:PanelAction(301).onClick()
      assert.are.equal(1, p4.guild.queryCount)
      assert.are.equal("Asking the guild...", Guild:PanelAction(301).status)
      answer(300, {})
      p4.advance(ns.Social.GuildNative.MIN_INTERVAL)
      assert.are.equal(2, p4.guild.queryCount)
      assert.are.equal("Guild answered: nobody knows this recipe", Guild:PanelAction(300).status)
    end)

    it("is disabled with the reason while the gate is locked, and the click asks nothing", function()
      p4.restriction.chatActive = true
      local a = Guild:PanelAction(300)
      assert.is_false(a.enabled)
      assert.are.equal("Sync paused (instance)", a.status)
      a.onClick()
      assert.are.equal(0, p4.guild.queryCount)
    end)

    it("names every other reason it cannot ask", function()
      settings.useNative = false
      assert.are.equal("Turned off in the Guild settings (\"Also use the game's guild recipe list\")",
        Guild:PanelAction(300).status)
      settings.useNative = true
      local query = C_GuildInfo.QueryGuildMembersForRecipe
      C_GuildInfo.QueryGuildMembersForRecipe = nil
      assert.are.equal("The game's guild recipe query is not available", Guild:PanelAction(300).status)
      C_GuildInfo.QueryGuildMembersForRecipe = query
      assert.are.equal("The game's guild recipe query is not available", Guild:PanelAction(999).status) -- no line
      ns.FS.dbIsNewer = true
      assert.are.equal("Read-only: the saved data is from a newer version of the addon", Guild:PanelAction(300).status)
      ns.FS.dbIsNewer = nil
      assert.is_false(Guild:PanelAction(999).enabled)
      assert.is_true(Guild:PanelAction(300).enabled)
    end)

    it("offers nothing while Guild is off, outside a guild or with the profession window line off", function()
      settings.panelLine = false
      assert.is_nil(Guild:PanelAction(300))
      settings.panelLine = true
      p4.guild.key = nil; Guild:OnGuildUpdate()
      assert.is_nil(Guild:PanelAction(300))
      p4.guild.key = { "G", "Realm" }; Guild:OnGuildUpdate()
      assert.is_not_nil(Guild:PanelAction(300))
      ns.FS:SetModuleEnabled("Guild", false)
      assert.is_nil(Guild:PanelAction(300))
    end)

    it("is registered as the profession panel's action", function()
      local actions = panel:CollectActions(300, "Me-Realm")
      assert.are.equal(1, #actions)
      assert.are.equal("Ask guild", actions[1].text)
      ns.FS:SetModuleEnabled("Guild", false)
      assert.are.same({}, panel:CollectActions(300, "Me-Realm"))
    end)
  end)

  ---------------------------------------------------------------------------
  -- Recipe search (the Guild tab's typed search)
  ---------------------------------------------------------------------------

  describe("recipe search", function()
    local NAMES, chars
    local function map(list, key)
      local out = {}
      for i, v in ipairs(list) do out[i] = v[key] end
      return out
    end
    local function item_link(id, text)
      return "|cffa335ee|Hitem:" .. id .. "::::::::|h[" .. text .. "]|h|r"
    end

    before_each(function()
      NAMES = { [700] = "Everforged Helm", [100] = "Everforged Mace", [101] = "Everforged Axe" }
      chars = {}
      C_Spell.GetSpellName = function(id) return NAMES[id] end
      ns.GameData.Define("RecipeSources", nil, { bySkillLine = { [2907] = { [700] = { kind = "auto" } } } })
      p4.fake_module(ns, "Scanner", {
        GetCharacters = function() return { "Me-Realm" } end,
        GetCharacter = function() return { professions = chars } end,
        GetCachedSchematic = function(_, id) return schematics[id] end,
      })
    end)

    it("finds recipes by name from the generated list, own recipes and the guild data", function()
      local r = Guild:FindRecipes("  HELM ")
      assert.are.equal("name", r.kind)
      assert.are.same({ { recipeID = 700, recipeName = "Everforged Helm", skillLineID = 2907 } }, r.recipes)
      chars[2906] = { recipes = { [101] = true } }
      store("B-Realm", "Peer-Realm")                                       -- recipe 100 on line 2907
      NAMES[555] = "Everforged Boots"
      native_members(555, { NATIVE_B })
      Guild:_DirectoryDisable()                                             -- a new catalogue
      local all = Guild:FindRecipes("everforged")
      assert.are.same({ "Everforged Axe", "Everforged Boots", "Everforged Helm", "Everforged Mace" },
        map(all.recipes, "recipeName"))
      assert.are.same({ 2906, 2907, 2907, 2907 }, map(all.recipes, "skillLineID"))
    end)

    it("ignores searches under three letters, counting letters and not bytes", function()
      assert.are.same({ kind = "none", recipes = {} }, Guild:FindRecipes("he"))
      assert.are.same({ kind = "none", recipes = {} }, Guild:FindRecipes("\195\169\195\169"))
      assert.are.same({ kind = "none", recipes = {} }, Guild:FindRecipes("   "))
      assert.are.same({ kind = "none", recipes = {} }, Guild:FindRecipes(nil))
      assert.are.equal("name", Guild:FindRecipes("hel").kind)
    end)

    it("answers nothing while Guild is turned off", function()
      Guild:Disable()
      assert.are.same({ kind = "none", recipes = {} }, Guild:FindRecipes("helm"))
    end)

    it("takes the skill line from the generated list first, then own, profile and native records", function()
      chars[2999] = { recipes = { [700] = true, [101] = true } }
      store("B-Realm", "Peer-Realm", { recipes = { [101] = { 1, 1 }, [100] = { 3, 5 } }, line = 2950 })
      native_members(100, { NATIVE_B })
      local lines = {}
      for _, r in ipairs(Guild:FindRecipes("everforged").recipes) do lines[r.recipeID] = r.skillLineID end
      assert.are.same({ [700] = 2907, [101] = 2999, [100] = 2950 }, lines)
    end)

    it("skips dropped professions of the account", function()
      chars[2906] = { dropped = true, recipes = { [101] = true } }
      assert.are.same({ 700 }, map(Guild:FindRecipes("everforged").recipes, "recipeID"))
    end)

    it("resolves an item link through the account's schematics and the guild item index", function()
      p4.fake_module(ns, "Recipes", { FindRecipesForItem = function(_, id)
        return (id == 6001 or id == 5101) and { { recipeID = 100, quality = 1 }, { recipeID = 100, quality = 2 } } or {} end })
      local r = Guild:FindRecipes(item_link(6001, "Whatever"))
      assert.are.equal("link", r.kind)
      assert.are.same({ 100 }, map(r.recipes, "recipeID"))
      assert.are.equal("Everforged Mace", r.recipes[1].recipeName)
      -- Recipe 101 (item 5101) is in the guild's data: the guild's recipe joins the account's, once each, by name.
      store("C-Realm", "Peer-Realm", { recipes = { [101] = { 1, 1 } } })
      Guild:RebuildItemIndex(); for _ = 1, 3 do p4.advance(0) end
      assert.are.same({ 101, 100 }, map(Guild:FindRecipes(item_link(5101, "Whatever")).recipes, "recipeID"))
    end)

    it("resolves an item link through the guild item index alone when the account has no schematic for it", function()
      store("C-Realm", "Peer-Realm", { recipes = { [101] = { 1, 1 } } })
      Guild:RebuildItemIndex(); for _ = 1, 3 do p4.advance(0) end
      assert.are.same({ 101 }, map(Guild:FindRecipes(item_link(5101, "Whatever")).recipes, "recipeID"))
    end)

    it("ignores the account's schematics while Recipes is turned off", function()
      p4.fake_module(ns, "Recipes", { FindRecipesForItem = function() return { { recipeID = 100, quality = 1 } } end })
      ns.FS:GetModule("Recipes"):Disable()
      assert.are.same({}, Guild:FindRecipes(item_link(6001, "Nothing Known")).recipes)
    end)

    it("falls back to the item's name when no recipe is known to make it", function()
      local r = Guild:FindRecipes("|cffa335ee|Hitem:9999::::|h[Everforged Helm |A:Professions-ChatIcon-Quality-Tier3:17:15::1|a]|h|r")
      assert.are.equal("link", r.kind)
      assert.are.same({ 700 }, map(r.recipes, "recipeID"))
      assert.are.same({}, Guild:FindRecipes(item_link(9999, "Everforged")).recipes)       -- exact, not a substring
      assert.are.same({ 700 }, map(Guild:FindRecipes(item_link(9999, "EVERFORGED helm")).recipes, "recipeID"))
    end)

    it("takes the recipe of a recipe link, whether the game writes it as enchant or spell", function()
      assert.are.same({ 100 }, map(Guild:FindRecipes("|cffffd000|Henchant:100|h[Everforged Mace]|h|r").recipes, "recipeID"))
      assert.are.same({ 101 }, map(Guild:FindRecipes("|cffffd000|Hspell:101|h[Everforged Axe]|h|r").recipes, "recipeID"))
      local unknown = Guild:FindRecipes("|cffffd000|Henchant:424242|h[Mystery]|h|r")
      assert.are.same({ { recipeID = 424242, recipeName = "Recipe 424242" } }, unknown.recipes)
    end)

    it("caps name matches at 25, sorted by name", function()
      local sources = {}
      for i = 1, 30 do
        sources[9000 + i] = { kind = "auto" }
        NAMES[9000 + i] = ("Helm %02d"):format(31 - i)
      end
      ns.GameData.Define("RecipeSources", nil, { bySkillLine = { [2907] = sources } })
      local r = Guild:FindRecipes("helm ")
      assert.are.equal(25, #r.recipes)
      assert.are.equal("Helm 01", r.recipes[1].recipeName)
      assert.are.equal("Helm 25", r.recipes[25].recipeName)
    end)

    it("leaves out a recipe the client has no name for and builds the catalogue again 300 s later", function()
      ns.GameData.Define("RecipeSources", nil, { bySkillLine = { [2907] = { [700] = {}, [800] = {} } } })
      local calls = 0
      C_Spell.GetSpellName = function(id) calls = calls + 1; return NAMES[id] end
      assert.are.same({ 700 }, map(Guild:FindRecipes("helm").recipes, "recipeID"))
      local built = calls
      NAMES[800] = "Everforged Wand"
      Guild:FindRecipes("wand")
      assert.are.equal(built, calls)                                       -- cached: nothing asked again
      assert.are.same({}, Guild:FindRecipes("wand").recipes)
      p4.advance(301)
      assert.are.same({ 800 }, map(Guild:FindRecipes("wand").recipes, "recipeID"))
    end)

    it("builds the catalogue once, from a search, and not from a tooltip or the rows of an empty search", function()
      local calls = 0
      C_Spell.GetSpellName = function(id) calls = calls + 1; return NAMES[id] end
      seed()
      Guild:RebuildItemIndex(); p4.advance(0)
      Guild:TooltipLines(5001)
      Guild:BuildTabRows({})
      Guild:BuildTabRows({ text = "he" })
      Guild:PanelLines(100, "Me-Realm")
      local before = calls
      Guild:FindRecipes("everforged")
      local built = calls
      assert.is_true(built > before)
      Guild:FindRecipes("everforged"); Guild:FindRecipes("mace")
      assert.are.equal(built, calls)
    end)

    it("drops the catalogue on a guild change and when Guild is turned off", function()
      store("B-Realm", "Peer-Realm", { recipes = { [100] = { 3, 5 } } })
      assert.are.same({ 100 }, map(Guild:FindRecipes("mace").recipes, "recipeID"))
      p4.guild.key = { "H", "Realm" }
      Guild:OnGuildUpdate()
      assert.are.same({}, Guild:FindRecipes("mace").recipes)               -- the other guild's profile is not in it
      p4.guild.key = { "G", "Realm" }
      Guild:OnGuildUpdate()
      assert.are.same({ 100 }, map(Guild:FindRecipes("mace").recipes, "recipeID"))
      Guild:_DirectoryDisable()
      dir().profiles["B-Realm"] = nil
      assert.are.same({}, Guild:FindRecipes("mace").recipes)
    end)

    it("reads only: nothing is written", function()
      store("B-Realm", "Peer-Realm")
      local before = ns.Util.DeepCopy(ns.FS.db.global)
      Guild:FindRecipes("helm"); Guild:FindRecipes(item_link(6001, "Everforged Mace"))
      Guild:BuildTabRows({ text = "helm" })
      assert.are.same(before, ns.FS.db.global)
    end)

    describe("rows", function()
      it("adds a placeholder row for a found recipe nobody is known to craft", function()
        store("B-Realm", "Peer-Realm")                                     -- recipe 100 has a crafter
        local rows, meta = Guild:BuildTabRows({ text = "everforged" })
        assert.are.same({ kind = "name", found = 2 }, meta)
        assert.are.same({ 700, 100 }, map(rows, "recipeID"))
        local helm = rows[1]
        assert.are.equal("Everforged Helm", helm.recipeName)
        assert.are.equal(2907, helm.skillLineID)
        assert.is_nil(helm.crafter)
        assert.are.equal("B-Realm", rows[2].crafter.name)
      end)

      it("sorts the placeholders in with the rest by recipe name, keeping a recipe's crafters in order", function()
        NAMES[300] = "Everforged Chestplate"
        ns.GameData.Define("RecipeSources", nil, { bySkillLine = { [2907] = { [700] = {}, [300] = {} } } })
        store("B-Realm", "Peer-Realm", { recipes = { [100] = { 3, 5 }, [101] = { 2, 4 } } })
        store("C-Realm", "Peer2-Realm", { lv = "r", recipes = { [100] = true } })
        local rows = Guild:BuildTabRows({ text = "everforged" })
        local seen = {}
        for i, r in ipairs(rows) do seen[i] = r.recipeName .. "/" .. (r.crafter and r.crafter.name or "-") end
        assert.are.same({ "Everforged Axe/B-Realm", "Everforged Chestplate/-", "Everforged Helm/-",
          "Everforged Mace/B-Realm", "Everforged Mace/C-Realm" }, seen)
      end)

      it("keeps today's matches for a crafter name and adds no placeholder for it", function()
        store("B-Realm", "Peer-Realm")
        local rows, meta = Guild:BuildTabRows({ text = "b-real" })
        assert.are.same({ kind = "name", found = 0 }, meta)
        assert.are.same({ 100 }, map(rows, "recipeID"))
        local none, noneMeta = Guild:BuildTabRows({ text = "he" })
        assert.are.same({ kind = "none", found = 0 }, noneMeta)
        assert.are.same({}, none)
      end)

      it("shows just the recipes of a pasted link, with a placeholder when nobody crafts them", function()
        store("B-Realm", "Peer-Realm", { recipes = { [100] = { 3, 5 }, [101] = { 2, 4 } } })
        local rows, meta = Guild:BuildTabRows({ text = "|cffffd000|Henchant:100|h[Everforged Mace]|h|r" })
        assert.are.same({ kind = "link", found = 1 }, meta)
        assert.are.same({ 100 }, map(rows, "recipeID"))
        rows, meta = Guild:BuildTabRows({ text = item_link(9999, "Everforged Helm") })
        assert.are.same({ kind = "link", found = 1 }, meta)
        assert.are.same({ 700 }, map(rows, "recipeID"))
        assert.is_nil(rows[1].crafter)
        rows, meta = Guild:BuildTabRows({ text = item_link(1, "Nothing Here") })
        assert.are.same({ kind = "link", found = 0 }, meta)
        assert.are.same({}, rows)
      end)

      it("keeps a placeholder only under the profession it belongs to", function()
        local _, meta = Guild:BuildTabRows({ text = "helm", skillLineID = 2907 })
        assert.are.equal(1, meta.found)
        assert.are.same({ 700 }, map((Guild:BuildTabRows({ text = "helm", skillLineID = 2907 })), "recipeID"))
        assert.are.same({}, (Guild:BuildTabRows({ text = "helm", skillLineID = 2906 })))
      end)

      it("still lists a placeholder in a guild that has no stored data yet", function()
        assert.is_nil(dir().profiles["B-Realm"])
        ns.FS.db.global.guildDirectory["G-Realm"] = nil
        local rows = Guild:BuildTabRows({ text = "helm" })
        assert.are.same({ 700 }, map(rows, "recipeID"))
        assert.is_nil(ns.FS.db.global.guildDirectory["G-Realm"])            -- and creates nothing
      end)

      it("answers nothing outside a guild", function()
        p4.guild.key = nil
        Guild:OnGuildUpdate()
        local rows, meta = Guild:BuildTabRows({ text = "helm" })
        assert.are.same({}, rows)
        assert.are.same({ kind = "none", found = 0 }, meta)
      end)
    end)
  end)

  ---------------------------------------------------------------------------
  -- Providers and refresh
  ---------------------------------------------------------------------------

  describe("providers", function()
    before_each(function()
      seed()
      Guild:RebuildItemIndex(); p4.advance(0)
    end)

    it("adds the guild line to the real Tooltips collection", function()
      local lines = tooltips:CollectLines(5001)
      local found
      for _, l in ipairs(lines) do if l[1] == "Guild crafters" then found = l end end
      assert.is_not_nil(found)
      assert.are.equal("B-Realm (Q3), D-Realm, C-Realm", found[2])
    end)

    it("adds the guild rows to the real profession panel collection", function()
      local lines = panel:CollectLines(100, "Me-Realm")
      assert.are.equal("Guild crafters", lines[1][1])
    end)

    it("shows no line once Guild is turned off", function()
      ns.FS:SetModuleEnabled("Guild", false)
      for _, l in ipairs(tooltips:CollectLines(5001)) do assert.are_not.equal("Guild crafters", l[1]) end
      assert.are.same({}, panel:CollectLines(100, "Me-Realm"))
    end)

    it("registers again, in place, when Guild is turned back on", function()
      ns.FS:SetModuleEnabled("Guild", false)
      ns.FS:SetModuleEnabled("Guild", true)
      local n = 0
      for _, l in ipairs(tooltips:CollectLines(5001)) do if l[1] == "Guild crafters" then n = n + 1 end end
      assert.are.equal(1, n)
    end)

    it("picks up directory changes in the tooltip lines", function()
      local before = tooltips:CollectLines(5001)
      add_native_member(100, "E-Realm"); ns.FS:SendMessage(ns.Msg.GUILD_CHANGED, "G-Realm")
      assert.are_not.same(before, tooltips:CollectLines(5001))
    end)

    it("refreshes the panel lines on FS_GUILD_CHANGED (Guild already debounces it, so no second debounce)", function()
      local refreshed = 0
      panel.RefreshLines = function() refreshed = refreshed + 1 end
      for _ = 1, 5 do ns.FS:SendMessage(ns.Msg.GUILD_CHANGED, "G-Realm") end
      assert.are.equal(5, refreshed)
    end)

    it("refreshes the panel when a stored profile or member changes (through Guild's debounce)", function()
      local refreshed = 0
      panel.RefreshLines = function() refreshed = refreshed + 1 end
      Guild:_Changed(); Guild:_Changed(); Guild:_Changed()
      assert.are.equal(0, refreshed)
      p4.advance(1)
      assert.are.equal(1, refreshed)
    end)

    it("lets a failing refresh through to the log only", function()
      panel.RefreshLines = function() error("boom") end
      assert.has_no.errors(function() ns.FS:SendMessage(ns.Msg.GUILD_CHANGED, "G-Realm") end)
    end)

    it("leaves no message registration or pending timer behind when disabled", function()
      Guild:RebuildItemIndex()
      ns.FS:SetModuleEnabled("Guild", false)
      local refreshed = 0
      panel.RefreshLines = function() refreshed = refreshed + 1 end
      ns.FS:SendMessage(ns.Msg.GUILD_CHANGED, "G-Realm")
      p4.advance(5)
      assert.are.equal(0, refreshed)
    end)
  end)
end)
