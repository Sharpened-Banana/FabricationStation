-- Consent before send: the real Guild together with the real Onboarding and its wizard. While the first-run guide holds
-- sync (it will be or is being shown and was never finished or skipped), Guild sends no HELLO that lists characters and
-- no DATA; finishing or skipping the guide starts both at once. Without a guide to offer there is no hold at all.
-- Scanner and Recipes are p4.fake_module fakes, as in guild_sync_spec.
local FILES = { "Modules/Social/Util.lua", "Modules/Social/Gate.lua", "Modules/Social/Codec.lua",
  "Modules/Social/Protocol.lua", "Modules/Social/ProfileStore.lua", "Modules/Social/Comm.lua", "Modules/Social/Guild.lua",
  "Modules/Onboarding.lua", "UI/OnboardingWizard.lua" }

describe("Guild sync waits for the setup guide", function()
  local ns, W, p4, Guild, Protocol, Onboarding, Wizard

  local function boot(before_login)
    ns, W, p4 = boot_phase4(FILES)
    Protocol = ns.Social.Protocol
    local chars = {
      ["Me-Realm"] = { professions = { [2907] = { skill = 50, maxSkill = 100, recipes = { [100] = true },
        concentration = {} } } },
    }
    p4.fake_module(ns, "Scanner", {
      GetCharacters = function() return { "Me-Realm" } end,
      GetCharacter = function(_, key) return chars[key] end,
    })
    p4.fake_module(ns, "Recipes", { Evaluate = function() return { expectedQuality = 3 } end })
    Guild, Onboarding, Wizard = ns.FS:GetModule("Guild"), ns.FS:GetModule("Onboarding"), ns.UI.OnboardingWizard
    p4.guild.key = { "G", "Realm" }
    if before_login then before_login() end
    W.fire("PLAYER_ENTERING_WORLD", true, false)
  end

  local function sent(t, dist)
    local n = 0
    for _, s in ipairs(p4.comm.sent) do
      local msg = Protocol.Unwire(s.text)
      if msg and msg.t == t and (dist == nil or s.distribution == dist) then n = n + 1 end
    end
    return n
  end

  local function peer_asks()
    Guild:OnHello(Protocol.Hello("1.0.0", { ["Peer-Realm"] = "0000aaaa" }), "Peer-Realm", "GUILD")
    Guild:OnRequest(Protocol.Request({ "Me-Realm" }), "Peer-Realm", "WHISPER")
  end

  it("sends no HELLO listing characters and no DATA until the guide is finished, then starts at once", function()
    boot()
    p4.advance(30)
    assert.is_true(Wizard:IsShown())
    peer_asks(); p4.advance(30)
    assert.are.equal(0, sent("H"))                              -- neither the login HELLO nor the whispered reply
    assert.are.equal(0, sent("D"))
    assert.are.equal(1, sent("Q"))                              -- asking for the peer's data reveals nothing of ours
    Wizard:Finish()
    assert.are.equal(1, sent("H", "GUILD"))                     -- at once; the GUILD HELLO covers the held reply
    assert.are.equal(0, sent("H", "WHISPER"))
    p4.advance(Guild.REQUEST_WINDOW)
    assert.are.equal(1, sent("D"))                              -- the held request is answered
    p4.advance(60)
    assert.are.equal(1, sent("H"))
  end)

  it("starts at once when the guide is skipped", function()
    boot()
    p4.advance(30)
    Wizard:Close()
    assert.are.equal(1, sent("H", "GUILD"))
  end)

  it("holds the HELLO a privacy choice in the guide asks for until the guide is finished", function()
    boot()
    p4.advance(30)
    Onboarding:ApplySocialChoices({ shareLevel = "recipes" })   -- the social step changed a setting
    p4.advance(5)
    assert.are.equal(0, sent("H"))
    Wizard:Finish()
    assert.are.equal(1, sent("H", "GUILD"))
    assert.are.equal("r", Guild:GetOwnProfile("Me-Realm").lv)
  end)

  it("does not hold when the guide was finished before", function()
    boot(function() ns.FS.db.global.onboarding = { completedVersion = 1, time = 0, skipped = false } end)
    p4.advance(21)
    assert.is_false(Wizard:IsShown())
    assert.are.equal(1, sent("H", "GUILD"))
  end)

  it("does not hold while Onboarding is off", function()
    boot(function() ns.FS:SetModuleEnabled("Onboarding", false) end)
    p4.advance(21)
    assert.are.equal(1, sent("H", "GUILD"))
  end)

  it("starts at once when Onboarding is turned off while it holds", function()
    boot()
    p4.advance(30)
    assert.are.equal(0, sent("H"))
    ns.FS:SetModuleEnabled("Onboarding", false)
    assert.are.equal(1, sent("H", "GUILD"))
    assert.is_nil(ns.FS.db.global.onboarding)
  end)

  it("never holds an empty sharing-off HELLO", function()
    boot()
    p4.advance(30)
    Guild:Settings().share = false
    Guild:OnPrivacyChanged()
    assert.are.equal(1, sent("H", "GUILD"))
  end)
end)
