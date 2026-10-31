-- ChatScan: chat events -> ChatMatcher -> requests the account can craft. Boots Core plus the Social files ChatScan
-- reads (Util, Gate, ChatMatcher); Recipes, Scanner and Customers are p4.fake_module fakes. Recipe 100 makes item
-- 212345 ("Everforged Gloves"); Me-Realm (the current character) crafts it at Q3 for 5000 copper, Alt-Realm at Q2.
local FILES = { "Modules/Social/Util.lua", "Modules/Social/Gate.lua", "Modules/Social/ChatMatcher.lua",
  "Modules/Social/ChatScan.lua" }
local L1 = "|cffa335ee|Hitem:212345::::::::80:::::|h[Everforged Gloves]|h|r"
local OTHER_LINK = "|cffa335ee|Hitem:999999::::::::80:::::|h[Mystery Hat]|h|r"
local RECIPE_LINK = "|cffffd000|Henchant:447379|h[Tailoring: Robe]|h|r"
local TRADE_ID, SERVICES_ID, GENERAL_ID = 2, 42, 1

describe("ChatScan", function()
  local ns, W, p4, ChatScan, customers_blocked, craftable, evaluations, item_calls

  local function say(text, who, zone, base)
    return ChatScan:HandleChat("CHAT_MSG_CHANNEL", text, who or "Buyer-Realm", "", "", "", "", zone or TRADE_ID, 2,
      base or "Trade", 0, 1)
  end

  local function boot(stubs)
    customers_blocked, evaluations, item_calls = {}, {}, 0
    craftable = { [100] = { "Alt-Realm", "Me-Realm" }, [200] = { "Me-Realm" }, [300] = { "Me-Realm" },
      [400] = { "Me-Realm" } }
    ns, W, p4 = boot_phase4(FILES, { stubs = stubs })
    _G.C_Spell.GetSpellName = function(id)
      return ({ [100] = "Everforged Gloves", [200] = "Gem Cut", [300] = "Amethyst Ring", [400] = "Emerald Amulet" })[id]
    end
    local results = {
      ["Me-Realm"] = { expectedQuality = 3, profit = 5000, flags = { noPrice = false } },
      ["Alt-Realm"] = { expectedQuality = 2, profit = 9000, flags = { noPrice = false } },
    }
    p4.fake_module(ns, "Recipes", {
      FindRecipesForItem = function(_, itemID)
        item_calls = item_calls + 1
        if itemID == 212345 then return { { recipeID = 100, quality = 3 }, { recipeID = 100, quality = 2 } } end
        if itemID == 5002 then return { { recipeID = 200, quality = 1 } } end
        if itemID == 5003 then return { { recipeID = 300, quality = 1 } } end
        if itemID == 5004 then return { { recipeID = 400, quality = 1 } } end
        return {}
      end,
      WhoCanCraft = function(_, recipeID) return craftable[recipeID] or {} end,
      Evaluate = function(_, recipeID, charKey, opts)
        evaluations[#evaluations + 1] = { recipeID, charKey, opts }
        return results[charKey]
      end,
    })
    p4.fake_module(ns, "Scanner", {
      GetCharacters = function() return { "Alt-Realm", "Me-Realm" } end,
      GetCharacter = function(_, charKey)
        if charKey == "Me-Realm" then
          return { professions = { [1] = { recipes = { [100] = true, [200] = true, [300] = true } },
            [2] = { dropped = true, recipes = { [400] = true } } } }
        end
        return { professions = { [1] = { recipes = { [100] = true } } } }
      end,
    })
    p4.fake_module(ns, "Customers", {
      IsBlocked = function(_, name) return customers_blocked[name] end,
    })
    ChatScan = ns.FS:GetModule("ChatScan")
  end

  before_each(function() boot() end)

  it("is a normal, toggleable module that arms the gate and watches both chat events", function()
    assert.is_truthy(ChatScan)
    assert.is_falsy(ChatScan.coreModule)
    assert.is_true(ChatScan:IsEnabled())
    local regs = W.registrations(ChatScan)
    assert.are.same({ "CHAT_MSG_CHANNEL", "CHAT_MSG_GUILD" }, regs.events)
    assert.are.same({ "FS_DATA_CHANGED" }, regs.messages)
  end)

  it("matches a craftable request and picks the best character", function()
    local m = say("LF crafter " .. L1)
    assert.are.equal("Buyer-Realm", m.sender); assert.are.equal("trade", m.kind)
    assert.are.equal(1, m.lineID)
    assert.are.equal(W.now, m.time)
    assert.are.equal("LF crafter " .. L1, m.text)
    assert.are.equal(1, #m.recipes)
    assert.are.same({ charKey = "Me-Realm", expectedQuality = 3, profit = 5000, noPrice = false }, m.recipes[1].best)
    assert.are.equal(100, m.recipes[1].recipeID)
    assert.are.equal(212345, m.recipes[1].itemID)
    assert.are.equal(L1, m.recipes[1].link)
    assert.are.equal("Everforged Gloves", m.recipes[1].name)
    assert.are.equal(1, #p4.messages("FS_CHATSCAN_MATCH"))
    assert.are.equal(m, p4.messages("FS_CHATSCAN_MATCH")[1][1])
    assert.are.equal(1, ChatScan.stats.matched)
  end)

  it("reads FindRecipesForItem's named fields and evaluates each crafter with default options", function()
    say("LF crafter " .. L1)
    assert.are.equal(2, #evaluations)
    assert.are.same({}, evaluations[1][3])
  end)

  it("ignores requests nobody on the account can craft", function() assert.is_nil(say("LF crafter " .. OTHER_LINK)) end)

  it("ignores text that is not a request", function()
    assert.is_nil(say("WTS " .. L1))
    assert.is_nil(say("hello world"))
    assert.are.equal(0, #p4.messages("FS_CHATSCAN_MATCH"))
  end)

  it("dedupes repeats across channels and time", function()
    assert.truthy(say("LF crafter " .. L1))
    assert.is_nil(say("LF crafter " .. L1, nil, SERVICES_ID, "Trade (Services)"))
    p4.advance(299); assert.is_nil(say("LF crafter " .. L1))
    p4.advance(2);   assert.truthy(say("LF crafter " .. L1))
    assert.are.equal(2, ChatScan.stats.deduped)
  end)

  it("dedupes per sender and per recipe", function()
    assert.truthy(say("LF crafter " .. L1))
    assert.truthy(say("LF crafter " .. L1, "Other-Realm"))
    local m = say("LF crafter " .. L1 .. " and [Gem Cut]")           -- recipe 100 is a repeat, 200 is new
    assert.is_nil(m and m.recipes[2])
    assert.are.equal(1, #m.recipes)
    assert.are.equal(200, m.recipes[1].recipeID)
  end)

  it("matches the same recipe again for the same sender once the window passed, repeats never extend it", function()
    assert.truthy(say("LF crafter " .. L1))
    p4.advance(200); assert.is_nil(say("LF crafter " .. L1))
    p4.advance(101); assert.truthy(say("LF crafter " .. L1))          -- 301 s after the emitted match, not after the repeat
  end)

  it("dedupes by item id, not by link text, within one line", function()
    local other_form = "|cff0070dd|Hitem:212345::::|h[Everforged Gloves]|h|r"
    local m = say("LF crafter " .. L1 .. " " .. other_form)
    assert.are.equal(1, #m.recipes)
    assert.are.equal(1, item_calls)
  end)

  it("skips secret payloads without touching them", function()
    assert.is_nil(say(p4.secret("LF crafter")))
    assert.is_nil(say("LF crafter " .. L1, p4.secret("Buyer")))
    assert.are.equal(2, ChatScan.stats.skippedSecret)
    assert.truthy(say("LF crafter " .. L1))   -- works again once values are readable
  end)

  it("treats a secret channel id or name as unclassifiable instead of reading it", function()
    assert.is_nil(say("LF crafter " .. L1, nil, p4.secret(2), p4.secret("Trade")))
    assert.truthy(say("LF crafter " .. L1, nil, p4.secret(2), "Trade"))
  end)

  it("respects the gate, self, ignore lists and blocked customers", function()
    p4.restriction.chatActive = true; assert.is_nil(say("LF crafter " .. L1)); p4.restriction.chatActive = false
    assert.is_nil(say("LF crafter " .. L1, "Me"))
    ChatScan:Ignore("Buyer-Realm"); assert.is_nil(say("LF crafter " .. L1)); ChatScan:Unignore("Buyer-Realm")
    p4.ignored["Buyer-Realm"] = true; assert.is_nil(say("LF crafter " .. L1)); p4.ignored["Buyer-Realm"] = nil
    customers_blocked["Buyer-Realm"] = true; assert.is_nil(say("LF crafter " .. L1))
  end)

  it("asks the ignore list with the raw name and the ambiguated name", function()
    local asked = {}
    _G.C_FriendList.IsIgnored = function(name) asked[#asked + 1] = name; return name == "Buyer" end
    _G.Ambiguate = function(name, mode) assert.are.equal("none", mode); return (name:gsub("%-.*$", "")) end
    assert.is_nil(say("LF crafter " .. L1, "Buyer-Realm"))
    assert.are.same({ "Buyer-Realm", "Buyer" }, asked)
  end)

  it("works without the Customers module", function()
    customers_blocked["Buyer-Realm"] = true; ns.FS:SetModuleEnabled("Customers", false); assert.truthy(say("LF crafter " .. L1))
  end)

  it("does nothing while the module is off and picks up again when it is turned on", function()
    ns.FS:SetModuleEnabled("ChatScan", false)
    assert.is_nil(say("LF crafter " .. L1))
    assert.are.same({ events = {}, messages = {} }, W.registrations(ChatScan))
    ns.FS:SetModuleEnabled("ChatScan", true)
    assert.truthy(say("LF crafter " .. L1))
  end)

  it("classifies channels and honours channel toggles", function()
    assert.are.equal("general", ChatScan:ClassifyChannel("CHAT_MSG_CHANNEL", 0, "General - City"))
    assert.are.equal("guild", ChatScan:ClassifyChannel("CHAT_MSG_GUILD"))
    assert.is_nil(say("LF crafter " .. L1, nil, GENERAL_ID, "General"))   -- general off by default
  end)

  it("classifies by the zone channel map first, then the lower-cased base name (services before trade)", function()
    assert.are.same({}, ChatScan.ZONE_CHANNEL_KIND)
    assert.are.equal("services", ChatScan:ClassifyChannel("CHAT_MSG_CHANNEL", 0, "Trade (Services) - City"))
    assert.are.equal("trade", ChatScan:ClassifyChannel("CHAT_MSG_CHANNEL", 0, "TRADE - City"))
    assert.is_nil(ChatScan:ClassifyChannel("CHAT_MSG_CHANNEL", 0, "LookingForGroup"))
    assert.is_nil(ChatScan:ClassifyChannel("CHAT_MSG_CHANNEL", 0, nil))
    assert.is_nil(ChatScan:ClassifyChannel("CHAT_MSG_WHISPER", 0, "Trade"))
    ChatScan.ZONE_CHANNEL_KIND[77] = "services"
    assert.are.equal("services", ChatScan:ClassifyChannel("CHAT_MSG_CHANNEL", 77, "Handel"))
    ChatScan.ZONE_CHANNEL_KIND[77] = nil
  end)

  it("scans guild chat when the guild channel is on and reports the guild kind", function()
    local m = ChatScan:HandleChat("CHAT_MSG_GUILD", "LF crafter " .. L1, "Mate-Realm", "", "", "", "", 0, 0, "", 0, 9)
    assert.are.equal("guild", m.kind)
    ChatScan:Settings().channels.guild = false
    assert.is_nil(ChatScan:HandleChat("CHAT_MSG_GUILD", "LF crafter " .. L1, "Mate2-Realm", "", "", "", "", 0, 0, "", 0, 9))
  end)

  it("normalizes a same-realm sender", function()
    assert.are.equal("Buyer-Realm", say("LF crafter " .. L1, "Buyer").sender)
  end)

  it("matches by recipe name when there is no link", function() assert.truthy(say("LF crafter for Everforged Gloves")) end)

  it("does not match by name when nameMatch is off, and ignores names under six characters and dropped professions", function()
    ChatScan:Settings().nameMatch = false
    assert.is_nil(say("LF crafter for Everforged Gloves"))
    ChatScan:Settings().nameMatch = true
    _G.C_Spell.GetSpellName = function(id)
      return ({ [100] = "Gloves", [200] = "Boots", [300] = "Amethyst Ring", [400] = "Emerald Amulet" })[id]
    end
    ChatScan:RebuildIndexes()
    assert.is_nil(say("LF crafter for boots"))
    assert.is_nil(say("LF crafter for Emerald Amulet"))                -- recipe 400 belongs to a dropped profession
    assert.truthy(say("LF crafter for Amethyst Ring"))
    assert.truthy(say("LF crafter for gloves", "Other-Realm"))         -- exactly six characters is allowed
  end)

  it("caps a line at three recipes", function()
    craftable[500] = { "Me-Realm" }
    local links = { L1, "|Hitem:5002::::|h[Gem Cut Item]|h", "|Hitem:5003::::|h[Ring Item]|h",
      "|Hitem:5004::::|h[Amulet Item]|h" }
    local m = say("LF crafter " .. table.concat(links, " "))
    assert.are.equal(3, #m.recipes)
    assert.are.same({ 100, 200, 300 }, { m.recipes[1].recipeID, m.recipes[2].recipeID, m.recipes[3].recipeID })
  end)

  it("uses recipe links and counts the cap on recipes the account can craft", function()
    craftable[447379] = { "Me-Realm" }
    local m = say("can anyone craft " .. RECIPE_LINK)
    assert.are.equal(447379, m.recipes[1].recipeID)
    assert.are.equal(RECIPE_LINK, m.recipes[1].link)
    assert.is_nil(m.recipes[1].itemID)
    local uncraftable = "|Hitem:999998::::|h[X]|h |Hitem:999997::::|h[Y]|h |Hitem:999996::::|h[Z]|h |Hitem:999995::::|h[W]|h"
    local n = say("LF crafter " .. uncraftable .. " " .. L1, "Other-Realm")
    assert.are.equal(100, n.recipes[1].recipeID)
  end)

  it("ranks characters by quality, then profit, with no price last", function()
    local results = {
      ["Alt-Realm"] = { expectedQuality = 3, profit = 9000, flags = { noPrice = false } },
      ["Me-Realm"] = { expectedQuality = 3, profit = 5000, flags = { noPrice = false } },
    }
    ns.FS:GetModule("Recipes").Evaluate = function(_, _, charKey) return results[charKey] end
    assert.are.equal("Alt-Realm", say("LF crafter " .. L1).recipes[1].best.charKey)
    results["Alt-Realm"] = { expectedQuality = 3, flags = { noPrice = true } }
    assert.are.same({ charKey = "Me-Realm", expectedQuality = 3, profit = 5000, noPrice = false },
      say("LF crafter " .. L1, "B2-Realm").recipes[1].best)
    results["Me-Realm"] = { expectedQuality = 3, flags = { noPrice = true } }
    local best = say("LF crafter " .. L1, "B3-Realm").recipes[1].best
    assert.are.same({ charKey = "Alt-Realm", expectedQuality = 3, noPrice = true }, best)
    results["Alt-Realm"], results["Me-Realm"] = nil, nil
    assert.are.same({ charKey = "Alt-Realm", noPrice = true }, say("LF crafter " .. L1, "B4-Realm").recipes[1].best)
  end)

  it("survives Evaluate raising for one character", function()
    local good = { expectedQuality = 2, profit = 1, flags = { noPrice = false } }
    ns.FS:GetModule("Recipes").Evaluate = function(_, _, charKey)
      if charKey == "Me-Realm" then error("boom") end
      return good
    end
    assert.are.equal("Alt-Realm", say("LF crafter " .. L1).recipes[1].best.charKey)
  end)

  it("rebuilds the name index on recipe changes after five seconds and not on other changes", function()
    ChatScan:RebuildIndexes()
    local calls = 0
    local original = _G.C_Spell.GetSpellName
    _G.C_Spell.GetSpellName = function(id) calls = calls + 1; return original(id) end
    ns.FS:SendMessage("FS_DATA_CHANGED", "Me-Realm", "moxie")
    p4.advance(10)
    assert.are.equal(0, calls)
    ns.FS:SendMessage("FS_DATA_CHANGED", "Me-Realm", "recipes")
    ns.FS:SendMessage("FS_DATA_CHANGED", "Me-Realm", "recipes")
    p4.advance(4); assert.are.equal(0, calls)
    p4.advance(2); assert.is_true(calls > 0)
    local first = calls
    p4.advance(30); assert.are.equal(first, calls)
  end)

  it("keeps working when GetSpellName has no name yet and retries later", function()
    _G.C_Spell.GetSpellName = function() return nil end
    ChatScan:RebuildIndexes()
    assert.is_nil(say("LF crafter for Everforged Gloves"))
    _G.C_Spell.GetSpellName = function(id) return id == 100 and "Everforged Gloves" or nil end
    p4.advance(61)
    assert.truthy(say("LF crafter for Everforged Gloves", "Other-Realm"))
  end)

  it("ignore list: add, remove, normalise, case-insensitive, capped, persisted in the settings", function()
    assert.is_false(ChatScan:IsIgnored("Buyer-Realm"))
    assert.is_true(ChatScan:Ignore("buyer"))
    assert.is_true(ChatScan:IsIgnored("Buyer-Realm"))
    assert.is_true(ChatScan:IsIgnored("BUYER"))
    assert.are.same({ "buyer-Realm" }, ns.FS.db.global.settings.chatScan.ignore)
    assert.is_false(ChatScan:Ignore("buyer-realm"))                  -- already there
    ChatScan:Unignore("BUYER-realm")
    assert.is_false(ChatScan:IsIgnored("Buyer-Realm"))
    assert.is_false(ChatScan:Ignore(nil))
    assert.is_false(ChatScan:Ignore(""))
    for i = 1, 200 do assert.is_true(ChatScan:Ignore("Name" .. i)) end
    assert.is_false(ChatScan:Ignore("OneTooMany"))
  end)

  it("disabling leaves no registrations, pending timers or remembered requests", function()
    local timers = {}
    local make = _G.C_Timer.NewTimer
    _G.C_Timer.NewTimer = function(...) local t = make(...); timers[#timers + 1] = t; return t end
    assert.truthy(say("LF crafter " .. L1))
    ns.FS:SendMessage("FS_DATA_CHANGED", "Me-Realm", "recipes")
    assert.is_true(#timers > 0)
    ns.FS:SetModuleEnabled("ChatScan", false)
    for _, t in ipairs(timers) do assert.is_true(t.cancelled) end
    assert.are.same({ events = {}, messages = {} }, W.registrations(ChatScan))
    ns.FS:SetModuleEnabled("ChatScan", true)
    assert.truthy(say("LF crafter " .. L1))                          -- the dedupe memory was dropped with the module
  end)

  it("never sends chat or whispers by itself", function()
    assert.truthy(say("LF crafter " .. L1))
    assert.are.same({}, p4.tells)
    assert.are.same({}, p4.comm.sent)
  end)

  describe("settings", function()
    it("fills the defaults lazily", function()
      local s = ChatScan:Settings()
      assert.are.same({ trade = true, services = true, general = false, guild = true }, s.channels)
      assert.are.equal(300, s.dedupeSeconds); assert.are.equal(30, s.toastSeconds)
      assert.is_true(s.sound); assert.is_true(s.nameMatch)
      assert.is_nil(s.enabled)
      assert.are.equal("Hi! I can craft %s. Send me a crafting order?", s.whisperTemplate)
      assert.are.same({}, s.ignore)
      assert.are.equal(s, ns.FS.db.global.settings.chatScan)
    end)

    it("repairs wrong types and out-of-range numbers", function()
      local s = ns.FS.db.global.settings
      s.chatScan = { channels = "x", ignore = 5, dedupeSeconds = "a", toastSeconds = 9999, sound = "yes",
        nameMatch = 1, whisperTemplate = "no placeholder", includeAdded = { 1, "ok phrase", "" } }
      local fixed = ChatScan:Settings()
      assert.are.same({ trade = true, services = true, general = false, guild = true }, fixed.channels)
      assert.are.same({}, fixed.ignore)
      assert.are.equal(300, fixed.dedupeSeconds); assert.are.equal(120, fixed.toastSeconds)
      assert.is_true(fixed.sound); assert.is_true(fixed.nameMatch)
      assert.are.equal("Hi! I can craft %s. Send me a crafting order?", fixed.whisperTemplate)
      assert.are.same({ "ok phrase" }, fixed.includeAdded)
    end)

    it("stores only keyword additions and removals and merges them with the defaults when reading", function()
      local defaults = ns.Social.ChatMatcher.DEFAULT_INCLUDE
      assert.are.same(defaults, ChatScan:GetKeywords("include"))
      ChatScan:SetKeywords("include", { "LF crafter", "  need   a MAKER ", "need a maker" })
      assert.are.same({ "lf crafter", "need a maker" }, ChatScan:GetKeywords("include"))
      local s = ChatScan:Settings()
      assert.are.same({ "need a maker" }, s.includeAdded)
      assert.are.equal(#defaults - 1, #s.includeRemoved)
      ChatScan:SetKeywords("include", defaults)
      assert.are.same({}, s.includeAdded); assert.are.same({}, s.includeRemoved)
    end)

    it("shares the merged keyword list until the settings change", function()
      local first = ChatScan:GetKeywords("include")
      assert.are.equal(first, ChatScan:GetKeywords("include"))
      ChatScan:SetKeywords("include", { "hire a maker" })
      assert.are_not.equal(first, ChatScan:GetKeywords("include"))
      assert.are.same({ "hire a maker" }, ChatScan:GetKeywords("include"))
      assert.are.same({}, ChatScan:GetKeywords("nonsense"))
    end)

    it("uses the user's keywords when scanning", function()
      ChatScan:SetKeywords("include", { "hire a maker" })
      assert.is_nil(say("LF crafter " .. L1))
      assert.truthy(say("hire a maker " .. L1))
      ChatScan:SetKeywords("exclude", { "cheap" })
      assert.is_nil(say("hire a maker cheap " .. L1, "Other-Realm"))
    end)

    it("honours dedupeSeconds", function()
      ChatScan:Settings().dedupeSeconds = 60
      assert.truthy(say("LF crafter " .. L1))
      p4.advance(61)
      assert.truthy(say("LF crafter " .. L1))
    end)
  end)

  describe("options group", function()
    local group
    local function args() return ns.FS:GetOptionsTable().args.chatScan.args end
    before_each(function() group = ns.FS:GetOptionsTable().args.chatScan end)

    it("is registered at order 80 with a control for every setting", function()
      assert.are.equal(80, group.order)
      for _, key in ipairs({ "channels", "include", "exclude", "ignore", "dedupeSeconds", "toastSeconds", "sound",
        "nameMatch", "whisperTemplate" }) do
        assert.is_truthy(args()[key], key)
      end
      assert.is_nil(args().enabled)
    end)

    it("edits channels, keywords, the ignore list and the numbers through the settings", function()
      local a = args()
      assert.is_true(a.channels.get(nil, "trade")); assert.is_false(a.channels.get(nil, "general"))
      a.channels.set(nil, "general", true)
      a.channels.set(nil, "bogus", true)
      assert.is_true(ChatScan:Settings().channels.general)
      assert.is_nil(ChatScan:Settings().channels.bogus)

      a.include.set(nil, "lf crafter\nneed a maker\n\n")
      assert.is_truthy(a.include.get():find("need a maker", 1, true))
      assert.is_truthy(a.include.get():find("lf crafter\n", 1, true))
      assert.is_nil(a.include.get():find("lf blacksmith", 1, true))
      a.exclude.set(nil, "wts")
      assert.are.equal("wts", a.exclude.get())

      a.ignore.set(nil, "Spammer\nOther-Realm\n  \nSpammer")
      assert.are.equal("Spammer-Realm\nOther-Realm", a.ignore.get())
      assert.is_true(ChatScan:IsIgnored("spammer-realm"))

      a.dedupeSeconds.set(nil, 120); assert.are.equal(120, ChatScan:Settings().dedupeSeconds)
      a.toastSeconds.set(nil, 15); assert.are.equal(15, ChatScan:Settings().toastSeconds)
      a.sound.set(nil, false); assert.is_false(ChatScan:Settings().sound)
      a.nameMatch.set(nil, false); assert.is_false(ChatScan:Settings().nameMatch)
      assert.are.same({ min = 60, max = 1800 }, { min = a.dedupeSeconds.min, max = a.dedupeSeconds.max })
      assert.are.same({ min = 10, max = 120 }, { min = a.toastSeconds.min, max = a.toastSeconds.max })
    end)

    it("validates the whisper template: exactly one %s", function()
      local t = args().whisperTemplate
      assert.is_true(t.validate(nil, "Can I craft %s for you?"))
      for _, bad in ipairs({ "no placeholder", "%s and %s", "100% sure %s", "%d %s", "" }) do
        assert.are.equal("Template must contain %s once", t.validate(nil, bad), bad)
      end
      assert.is_true(t.validate(nil, "100%% sure %s"))
      t.set(nil, "Hello %s!")
      assert.are.equal("Hello %s!", ChatScan:Settings().whisperTemplate)
      t.set(nil, "broken")
      assert.are.equal("Hello %s!", ChatScan:Settings().whisperTemplate)
    end)

    it("disables every setter and writes nothing while the saved data is from a newer version", function()
      ns.FS.dbIsNewer = true
      local snapshot = ns.Util.DeepCopy(ns.FS.db.global.settings.chatScan or {})
      for key, option in pairs(args()) do
        if option.type ~= "description" then
          assert.is_function(option.disabled, key)
          assert.is_true(option.disabled(), key)
        end
      end
      local a = args()
      a.channels.set(nil, "general", true)
      a.include.set(nil, "something new")
      a.exclude.set(nil, "something else")
      a.ignore.set(nil, "Somebody")
      a.dedupeSeconds.set(nil, 61); a.toastSeconds.set(nil, 11); a.sound.set(nil, false); a.nameMatch.set(nil, false)
      a.whisperTemplate.set(nil, "Hi %s")
      ChatScan:Ignore("Somebody")
      assert.are.same(snapshot, ns.FS.db.global.settings.chatScan or {})
      ns.FS.dbIsNewer = false
      assert.is_false(args().sound.disabled())
    end)
  end)
end)
