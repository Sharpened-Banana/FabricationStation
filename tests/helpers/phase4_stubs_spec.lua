-- The phase-4 default stubs (wow_stubs.lua) and the controllable fakes (phase4_stubs.lua).
describe("phase-4 default stubs", function()
  local W
  before_each(function() W = install_wow_stubs() end)

  it("are safe-empty for a world with no guild, no restriction and no codec", function()
    assert.is_false(IsInGuild()); assert.is_nil(GetGuildInfo("player")); assert.are.equal(0, GetNumGuildMembers())
    assert.is_false(InCombatLockdown()); assert.same({ false, "none" }, { IsInInstance() })
    assert.is_false(issecretvalue("x")); assert.is_false(C_RestrictedActions.IsAddOnRestrictionActive(Enum.AddOnRestrictionType.Chat))
    assert.is_false(C_ChatInfo.InChatMessagingLockdown()); assert.is_false(C_ChatInfo.AreOutgoingAddonChatMessagesRestricted())
    assert.is_false(C_FriendList.IsIgnored("Bob")); assert.is_true(C_GuildInfo.MemberExistsByName("Bob"))
    assert.is_nil(C_GuildInfo.QueryGuildMembersForRecipe(1, 2)); assert.has_no.errors(function() C_GuildInfo.GuildRoster() end)
    assert.is_false(C_AddOns.DoesAddOnExist("Auctionator")); assert.are.equal("@project-version@", C_AddOns.GetAddOnMetadata("x", "Version"))
    assert.is_nil(C_Spell.GetSpellName(1)); assert.are.equal("Bob-Realm", Ambiguate("Bob-Realm", "none"))
    assert.is_table(C_EncodingUtil); assert.is_nil(C_EncodingUtil.SerializeCBOR)
    assert.are.equal(3081, SOUNDKIT.TELL_MESSAGE)
  end)

  it("hold the verified Enum values", function()
    assert.are.equal(5, Enum.AddOnRestrictionType.Chat)
    assert.same({ 0, 1, 2 }, { Enum.AddOnRestrictionState.Inactive, Enum.AddOnRestrictionState.Activating, Enum.AddOnRestrictionState.Active })
    assert.are.equal(0, Enum.CompressionMethod.Deflate)
    assert.same({ 0, 3, 10, 11, 12 }, { Enum.SendAddonMessageResult.Success, Enum.SendAddonMessageResult.AddonMessageThrottle,
      Enum.SendAddonMessageResult.NotInGuild, Enum.SendAddonMessageResult.AddOnMessageLockdown, Enum.SendAddonMessageResult.TargetOffline })
    assert.are.equal(0, Enum.TooltipDataType.Item)   -- still 1a's
  end)

  it("never allow chat sending and record whispers that open the edit box", function()
    assert.has_errors(function() SendChatMessage("hi", "WHISPER", nil, "Bob") end, "auto-send forbidden")
    assert.has_errors(function() C_ChatInfo.SendChatMessage("hi", "WHISPER", nil, "Bob") end)
    ChatFrameUtil.SendTell("Bob"); ChatFrameUtil.SendTellWithMessage("Al", "hello")
    assert.same({ { "Bob" }, { "Al", "hello" } }, W.tells)
  end)

  it("carry AceComm and AceLocale fakes that modules can embed", function()
    local obj = LibStub("AceAddon-3.0"):NewAddon("X", "AceComm-3.0", "AceEvent-3.0")
    assert.is_function(obj.RegisterComm); assert.is_function(obj.SendCommMessage); assert.is_function(obj.UnregisterAllComm)
    assert.has_no.errors(function() obj:SendCommMessage("FabStn", "x", "GUILD") end)
  end)

  it("give AceLocale silent semantics", function()
    local AL = LibStub("AceLocale-3.0")
    assert.is_nil(AL:NewLocale("App", "deDE"))                       -- not the client's locale, not the default
    local L = AL:NewLocale("App", "enUS", true)
    L["Hello"] = true; L["Bye"] = "Tschuess"
    local got = AL:GetLocale("App")
    assert.same({ "Hello", "Tschuess", "Missing key" }, { got["Hello"], got["Bye"], got["Missing key"] })
    assert.has_errors(function() AL:GetLocale("Nope") end)
    assert.is_nil(AL:GetLocale("Nope", true))
  end)

  it("let AceConfigDialog select a group", function()
    LibStub("AceConfigDialog-3.0"):SelectGroup("FabricationStation", "prices")
    assert.same({ app = "FabricationStation", path = { "prices" } }, W.config.selected)
  end)

  it("remove a helper-defined global on the next install", function()
    W.defineGlobal("SomethingExtra", 1)
    assert.are.equal(1, SomethingExtra)
    install_wow_stubs()
    assert.is_nil(_G.SomethingExtra)
  end)
end)

describe("install_phase4_stubs", function()
  local W, p4
  before_each(function() W = install_wow_stubs(); p4 = install_phase4_stubs(W) end)

  it("shares the clock and filters messages by name", function()
    p4.setNow(5000); assert.are.equal(5000, GetServerTime())
    p4.advance(2.5); assert.are.equal(5002.5, W.now)
    local obj = LibStub("AceAddon-3.0"):NewAddon("Y", "AceEvent-3.0")
    obj:SendMessage("A", 1, 2); obj:SendMessage("B"); obj:SendMessage("A", false, nil)
    assert.same({ { 1, 2 }, { false } }, p4.messages("A"))
    assert.same({ {} }, p4.messages("B"))
    assert.same({}, p4.messages("C"))
  end)

  describe("secret values", function()
    it("are flagged and refuse every string operation", function()
      local s = p4.secret("Bob-Realm")
      assert.is_true(issecretvalue(s)); assert.is_false(issecretvalue("Bob")); assert.is_false(issecretvalue(nil))
      assert.has_errors(function() return s .. "x" end)
      assert.has_errors(function() return ("x"):find(s) end)
      assert.has_errors(function() return s:lower() end)
      assert.has_errors(function() return string.lower(s) end)
      assert.has_errors(function() return tostring(s) end)
      assert.has_errors(function() return ("%s"):format(s) end)
      assert.are.equal("Bob-Realm", rawget(s, "value"))
    end)
  end)

  it("drives the restriction APIs from p4.restriction", function()
    local chat = Enum.AddOnRestrictionType.Chat
    assert.same({ false, false, false }, { C_RestrictedActions.IsAddOnRestrictionActive(chat), C_ChatInfo.InChatMessagingLockdown(),
      C_ChatInfo.AreOutgoingAddonChatMessagesRestricted() })
    p4.restriction.chatActive, p4.restriction.lockdown, p4.restriction.realm = true, true, true
    assert.same({ true, true, true }, { C_RestrictedActions.IsAddOnRestrictionActive(chat), C_ChatInfo.InChatMessagingLockdown(),
      C_ChatInfo.AreOutgoingAddonChatMessagesRestricted() })
    assert.is_false(C_RestrictedActions.IsAddOnRestrictionActive(Enum.AddOnRestrictionType.Combat))
  end)

  describe("guild", function()
    it("answers GetGuildInfo with the realm as the 4th return", function()
      assert.is_false(IsInGuild()); assert.is_nil(GetGuildInfo("player"))
      p4.guild.key = { "Guild", "Realm" }
      assert.is_true(IsInGuild())
      assert.same({ "Guild", "Member", 0, "Realm" }, { GetGuildInfo("player") })
      p4.guild.rank = "Officer"
      assert.same({ "Guild", "Officer", 0, "Realm" }, { GetGuildInfo("player") })
    end)

    it("counts roster members, treats unknown names as members and records roster requests", function()
      p4.guild.members = { { name = "A-Realm", online = true }, { name = "B-Realm", online = false } }
      assert.same({ 2, 1, 1 }, { GetNumGuildMembers() })
      p4.guild.exists["Gone-Realm"] = false
      assert.same({ true, false }, { C_GuildInfo.MemberExistsByName("Anyone"), C_GuildInfo.MemberExistsByName("Gone-Realm") })
      C_GuildInfo.GuildRoster(); C_GuildInfo.GuildRoster()
      assert.are.equal(2, p4.guild.rosterRequests)
    end)

    it("records native queries and answers the post-query globals", function()
      assert.are.equal(77, C_GuildInfo.QueryGuildMembersForRecipe(2871, 77, 3))
      assert.same({ skillLineID = 2871, recipeID = 77, level = 3 }, p4.guild.lastQuery)
      assert.are.equal(1, p4.guild.queryCount)
      p4.guild.postQuery = { skillLineID = 2871, recipeID = 77, list = { { "Bob", "Bob-Realm", "MAGE", true }, { "Al", "Al-Realm", "ROGUE", false } } }
      assert.same({ 2871, 77, 2 }, { GetGuildRecipeInfoPostQuery() })
      assert.same({ "Al", "Al-Realm", "ROGUE", false }, { GetGuildRecipeMember(2) })
      assert.is_nil(GetGuildRecipeMember(3))
    end)
  end)

  describe("comm", function()
    local obj
    before_each(function()
      obj = LibStub("AceAddon-3.0"):NewAddon("Z", "AceComm-3.0")
    end)

    it("records sends and calls the callback once per 255-byte chunk", function()
      local calls = {}
      local cb = function(arg, sent, total, result) calls[#calls + 1] = { arg, sent, total, result } end
      obj:SendCommMessage("FabStn", ("x"):rep(600), "GUILD", nil, "NORMAL", cb, "tag")
      obj:SendCommMessage("FabStn", "short", "WHISPER", "Bob-Realm")
      assert.are.equal(2, #p4.comm.sent)
      assert.same({ "FabStn", "GUILD", nil, "NORMAL", "tag" }, { p4.comm.sent[1].prefix, p4.comm.sent[1].distribution,
        p4.comm.sent[1].target, p4.comm.sent[1].prio, p4.comm.sent[1].callbackArg })
      assert.same({ "FabStn", "short", "WHISPER", "Bob-Realm" }, { p4.comm.sent[2].prefix, p4.comm.sent[2].text,
        p4.comm.sent[2].distribution, p4.comm.sent[2].target })
      assert.same({ { "tag", 255, 600, 0 }, { "tag", 510, 600, 0 }, { "tag", 600, 600, 0 } }, calls)
    end)

    it("takes the per-chunk send result from p4.comm.sendResult", function()
      local results = {}
      p4.comm.sendResult = function(i) return i == 2 and Enum.SendAddonMessageResult.AddOnMessageLockdown or 0 end
      obj:SendCommMessage("FabStn", ("x"):rep(300), "GUILD", nil, "NORMAL", function(_, _, _, r) results[#results + 1] = r end)
      assert.same({ 0, 11 }, results)
    end)

    it("delivers incoming messages to the registered handler until it unregisters", function()
      local got
      function obj:OnCommReceived(...) got = { ... } end
      obj:RegisterComm("FabStn")
      assert.is_true(p4.comm.deliver("FabStn", "hi", "GUILD", "Bob-Realm"))
      assert.same({ "FabStn", "hi", "GUILD", "Bob-Realm" }, got)
      assert.is_false(p4.comm.deliver("Other", "hi", "GUILD", "Bob-Realm"))
      obj:UnregisterAllComm()
      assert.is_false(p4.comm.deliver("FabStn", "hi", "GUILD", "Bob-Realm"))
    end)

    it("exposes the locale fake", function()
      assert.are.equal(LibStub("AceLocale-3.0"), p4.locale)
    end)
  end)

  describe("encoding", function()
    local E
    before_each(function() E = C_EncodingUtil end)

    it("round-trips a value through the fake chain", function()
      local value = { v = 1, pr = { { a = 2 } }, s = "text" }
      local wire = p4.encodeRaw(value)
      assert.is_string(wire)
      local back = E.DeserializeCBOR(E.DecompressString(E.DecodeBase64(wire), Enum.CompressionMethod.Deflate))
      assert.same(value, back)
      assert.are_not.equal(value, back)
    end)

    it("raises on an unknown token and answers nil for unmarked data", function()
      assert.has_errors(function() E.DeserializeCBOR("garbage") end)
      assert.is_nil(E.DecodeBase64("garbage")); assert.is_nil(E.DecompressString("garbage", Enum.CompressionMethod.Deflate))
    end)

    it("makes a wire string whose length grows with the value, and needs the Deflate method", function()
      assert.is_true(#p4.encodeRaw({ s = ("x"):rep(2000) }) > #p4.encodeRaw({ s = "x" }) + 1900)
      assert.has_errors(function() E.CompressString("x") end)
      assert.has_errors(function() E.SerializeCBOR(function() end) end)
    end)
  end)

  it("drives addons, ignore list and combat, falling through for addons it does not know", function()
    assert.is_false(C_AddOns.DoesAddOnExist("Auctionator"))
    p4.addons.Auctionator = { exists = true, loaded = false }
    assert.same({ true, false }, { C_AddOns.DoesAddOnExist("Auctionator"), C_AddOns.IsAddOnLoaded("Auctionator") })
    p4.addons.Auctionator.loaded = true
    assert.is_true(C_AddOns.IsAddOnLoaded("Auctionator"))
    assert.is_false(C_AddOns.IsAddOnLoaded("Blizzard_Professions"))
    p4.ignored["Spam-Realm"] = true
    assert.same({ true, false }, { C_FriendList.IsIgnored("Spam-Realm"), C_FriendList.IsIgnored("Bob") })
    assert.is_false(InCombatLockdown()); p4.inCombat = true; assert.is_true(InCombatLockdown())
    assert.is_true(p4.tells == W.tells)
  end)

  it("forgets the fakes' extra globals on the next plain install", function()
    assert.is_function(GetGuildRecipeMember)
    install_wow_stubs()
    assert.is_nil(_G.GetGuildRecipeMember); assert.is_nil(_G.GetGuildRecipeInfoPostQuery)
    assert.is_false(issecretvalue(p4.secret("x")))
  end)

  it("makes a fake module after boot, or overwrites methods on an existing one", function()
    local ns, _, p = boot_phase4({})
    local m = p.fake_module(ns, "Prices", { Get = function() return "stub" end })
    assert.are.equal("stub", m:Get())
    assert.is_true(ns.FS:IsModuleEnabled("Prices"))
    local again = p.fake_module(ns, "Prices", { Get = function() return "second" end })
    assert.are.equal(m, again); assert.are.equal("second", m:Get())
  end)
end)

describe("boot_phase4", function()
  it("loads the extra files after Core and boots", function()
    local ns, W, p4 = boot_phase4({ "Modules/Scanner.lua" })
    assert.is_truthy(ns.FS:GetModule("Scanner", true))
    assert.is_function(W.boot); assert.is_table(p4.guild)
    assert.are.equal("Me-Realm", ns.FS:CharKey())
  end)

  it("skips files the TOC already placed at or before opts.last", function()
    local ns = boot_phase4({ "Modules/Scanner.lua", "Modules/Prices.lua" }, { last = "Modules/Scanner.lua" })
    assert.is_truthy(ns.FS:GetModule("Scanner", true)); assert.is_truthy(ns.FS:GetModule("Prices", true))
  end)

  it("merges opts.stubs over the Me-Realm defaults", function()
    local ns = boot_phase4({}, { stubs = { UnitName = function() return "Zed" end } })
    assert.are.equal("Zed-Realm", ns.FS:CharKey())
  end)

  it("reaches the 1b-3 UI files through opts.last", function()
    local ns = boot_phase4({}, { last = "UI/MainWindow.lua" })
    assert.is_truthy(ns.FS:GetModule("MainWindow", true))
  end)
end)
