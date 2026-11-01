-- Consent before send, second half: an explicit change of a guild sharing setting in Settings > Guild (share,
-- shareLevel, shareAlts) is the player's consent choice. It ends the setup guide's hold on guild sync for the session
-- (the HELLO goes out once the own profiles are rebuilt with the new setting), but it does not finish the guide: the guide
-- is still due. The real Guild, its options group, Onboarding and the wizard; Scanner and Recipes are p4.fake_module
-- fakes, as in guild_consent_spec.
local FILES = { "Modules/Social/Util.lua", "Modules/Social/Gate.lua", "Modules/Social/Codec.lua",
  "Modules/Social/Protocol.lua", "Modules/Social/ProfileStore.lua", "Modules/Social/Comm.lua",
  "Modules/Social/ItemIndex.lua", "Modules/Social/RecipeIndex.lua", "Modules/Social/Guild.lua",
  "Modules/Social/GuildNative.lua", "Modules/Social/GuildDirectory.lua", "Modules/Social/GuildOptions.lua",
  "Modules/Onboarding.lua", "UI/OnboardingWizard.lua" }

describe("A guild sharing choice in Settings > Guild ends the setup guide's hold", function()
  local ns, W, p4, Guild, Protocol, Onboarding, Wizard, options

  local function boot()
    ns, W, p4 = boot_phase4(FILES)
    Protocol = ns.Social.Protocol
    local chars = {
      ["Me-Realm"] = { professions = { [2907] = { skill = 50, maxSkill = 100, recipes = { [100] = true },
        concentration = {} } } },
    }
    p4.fake_module(ns, "Scanner", {
      GetCharacters = function() return { "Me-Realm" } end,
      GetCharacter = function(_, key) return chars[key] end,
      GetCachedSchematic = function() return nil end,
    })
    p4.fake_module(ns, "Recipes", { Evaluate = function() return { expectedQuality = 3 } end })
    Guild, Onboarding, Wizard = ns.FS:GetModule("Guild"), ns.FS:GetModule("Onboarding"), ns.UI.OnboardingWizard
    options = Guild.BuildOptions().args
    p4.guild.key = { "G", "Realm" }
    W.fire("PLAYER_ENTERING_WORLD", true, false)
    p4.advance(30)                                              -- the guide is open and holds sync
  end

  local function sent(t, dist)
    local n = 0
    for _, s in ipairs(p4.comm.sent) do
      local msg = Protocol.Unwire(s.text)
      if msg and msg.t == t and (dist == nil or s.distribution == dist) then n = n + 1 end
    end
    return n
  end

  local function escape()
    local f = Wizard:GetControls().frame
    f:Hide(); f:GetScript("OnHide")(f)
  end

  before_each(boot)

  it("sends the HELLO with the new setting after Escape, and the guide stays due", function()
    escape()
    assert.are.equal(0, sent("H"))
    assert.are.equal("held", Guild:SyncStatus())
    options.shareLevel.set(nil, "recipes")
    assert.is_false(Onboarding:HoldsSync())
    assert.are.equal(0, sent("H"))                              -- not before the profiles are rebuilt
    p4.advance(5)
    assert.are.equal(1, sent("H", "GUILD"))
    assert.are.equal("r", Guild:GetOwnProfile("Me-Realm").lv)
    assert.are.equal("ok", Guild:SyncStatus())
    assert.is_nil(ns.FS.db.global.onboarding)                   -- nothing recorded
    assert.is_true(Onboarding:ShouldShow())                     -- still due
  end)

  it("answers a request held before the choice", function()
    Guild:OnHello(Protocol.Hello("1.0.0", { ["Peer-Realm"] = "0000aaaa" }), "Peer-Realm", "GUILD")
    Guild:OnRequest(Protocol.Request({ "Me-Realm" }), "Peer-Realm", "WHISPER")
    p4.advance(30)
    assert.are.equal(0, sent("D"))
    options.shareAlts.set(nil, "current")
    p4.advance(5 + Guild.REQUEST_WINDOW)
    assert.are.equal(1, sent("D"))
  end)

  it("counts turning sharing off and on again as a choice too", function()
    options.share.set(nil, false)
    assert.are.equal(1, sent("H", "GUILD"))                     -- the empty sharing-off HELLO, never held
    options.share.set(nil, true)
    p4.advance(5)
    assert.are.equal(2, sent("H", "GUILD"))
    assert.is_true(Onboarding:ShouldShow())
  end)

  it("is not released by the guide's own social step, which waits for Finish or Skip", function()
    Onboarding:ApplySocialChoices({ shareLevel = "recipes" })
    p4.advance(5)
    assert.are.equal(0, sent("H"))
    assert.is_true(Onboarding:HoldsSync())
  end)

  it("changes nothing while the saved data is from a newer version", function()
    local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
    ns.FS.dbIsNewer = true
    finally(function() ns.FS.dbIsNewer = nil end)
    options.shareLevel.set(nil, "recipes")
    p4.advance(5)
    assert.are.same(before, ns.FS.db.global)
    assert.are.equal(0, sent("H"))
    ns.FS.dbIsNewer = nil
    assert.is_true(Onboarding:HoldsSync())                     -- no consent was recorded either
  end)
end)
