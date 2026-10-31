-- GuildDirectory: the read side of the guild data (crafters per recipe/item, tooltip and profession panel lines) and
-- ItemIndex, the itemID -> recipeIDs reverse index. Boots the real Scanner, Recipes, ProfessionPanel and Tooltips
-- (last = "UI/Tooltips.lua"); the Scanner's character list and schematic cache are p4.fake_module overrides, the
-- roster and the native query are the phase-4 harness fakes (p4.guild).
local SOCIAL_FILES = { "Modules/Social/Util.lua", "Modules/Social/Gate.lua", "Modules/Social/Codec.lua",
  "Modules/Social/Protocol.lua", "Modules/Social/Comm.lua", "Modules/Social/ItemIndex.lua", "Modules/Social/Guild.lua",
  "Modules/Social/GuildNative.lua", "Modules/Social/GuildDirectory.lua" }
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

  -- A stored peer profile in the Task 6 shape: one skill line with the given recipes (id -> { q, qc } or true).
  local function store(charKey, owner, opts)
    opts = opts or {}
    local line = { k = opts.k or 50, m = 100, recipes = {} }
    local lv = opts.lv or "q"
    if lv == "q" then line.q, line.qc = {}, {} end
    for id, quality in pairs(opts.recipes or { [100] = { 3, 5 } }) do
      line.recipes[id] = true
      if lv == "q" then
        line.q[id], line.qc[id] = quality[1], quality[2]
      end
    end
    dir().profiles[charKey] = { c = charKey, ts = 1, lv = lv, h = "00000001", owner = owner,
      verified = opts.verified ~= false, rt = opts.rt or now(), lines = { [opts.line or 2907] = line } }
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

    it("shows nothing for a contested character (no stored copy)", function()
      dir().contested["K-Realm"] = now()
      assert.are.same({ "B-Realm", "D-Realm", "C-Realm" }, names(Guild:GetCrafters(100)))
    end)

    it("reads the recipe from any skill line of a profile", function()
      store("L-Realm", "Peer-Realm", { line = 2908, recipes = { [100] = { 4, 4 } } })
      local profile = dir().profiles["L-Realm"]
      profile.lines[2909] = { k = 7, m = 100, recipes = { [555] = true } }
      assert.are.equal("L-Realm", names(Guild:GetCrafters(100))[1])
      assert.are.same({}, Guild:GetCrafters(556))
    end)

    it("survives damaged saved data", function()
      dir().profiles["X-Realm"] = "junk"
      dir().profiles["Y-Realm"] = { owner = "Peer-Realm", lines = "junk" }
      dir().profiles["W-Realm"] = { owner = "Peer-Realm", rt = now(), lines = { [1] = { recipes = "junk" }, [2] = "junk" } }
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

    it("returns nothing while Guild is turned off", function()
      ns.FS:SetModuleEnabled("Guild", false)
      assert.are.same({}, Guild:TooltipLines(5001))
    end)

    it("does not throw on damaged data", function()
      dir().profiles["X-Realm"] = { owner = {}, rt = "x", lines = { [1] = { recipes = { [100] = true }, q = "junk" } } }
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
