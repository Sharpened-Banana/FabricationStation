-- Onboarding (Modules/Onboarding.lua) and its wizard (UI/OnboardingWizard.lua): the first-run setup guide. Boots Core
-- through Diagnostics (the real Scanner, Prices and GameData), then the Social Util (the shared current-expansion line
-- rule), the module and the wizard. Guild and ChatScan are p4.fake_module fakes, so the choices have something to
-- toggle and write to. "Me-Realm" is the current character.
local FILES = { "Modules/Social/Util.lua", "Modules/Onboarding.lua", "UI/OnboardingWizard.lua" }

local function find(list, key, value)
  for _, item in ipairs(list) do
    if item[key] == value then return item end
  end
end

local function map(list, key)
  local out = {}
  for i, item in ipairs(list) do out[i] = item[key] end
  return out
end

-- Text measuring of the fake client: CHAR_W per character and LINE_H per line, on the text without colour codes.
-- measureNothing = true makes every font string measure 0, as a client may for a font string on a hidden frame.
-- As in the client, a font string with a height set (not 0) shows and measures only what fits in that height:
-- full_height() is what its whole text needs.
local CHAR_W, LINE_H = 6, 14
local measureNothing = false
local function plain(text)
  return (tostring(text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end
local function full_height(fs)
  local chars = #plain(fs:GetText())
  local lines = 1
  if fs:GetWordWrap() then lines = math.max(1, math.ceil(chars * CHAR_W / (fs:GetWidth() or 1))) end
  if fs:GetMaxLines() > 0 then lines = math.min(lines, fs:GetMaxLines()) end
  return LINE_H * lines
end

-- The shared frame fake keeps no text, check state or enabled state for buttons, and no measurements; the wizard's
-- controls get them here.
local function patch_frames()
  measureNothing = false
  local base = _G.CreateFrame
  _G.CreateFrame = function(...)
    local f = base(...)
    local text, checked, enabled = nil, false, true
    function f:GetTextWidth() return measureNothing and 0 or #plain(text) * CHAR_W end
    local makeFontString = f.CreateFontString
    f.CreateFontString = function(owner, ...)
      local fs = makeFontString(owner, ...)
      local height
      function fs:SetHeight(h) height = h end
      function fs:GetHeight() return height end
      function fs:GetStringWidth() return #plain(self:GetText()) * CHAR_W end
      local fontObject
      function fs:SetFontObject(o) fontObject = o end
      function fs:GetFontObject() return fontObject end
      function fs:GetStringHeight()
        if measureNothing then return 0 end
        local full = full_height(self)
        if type(height) == "number" and height > 0 then return math.min(full, height) end   -- cut at its set height
        return full
      end
      return fs
    end
    function f:SetText(t) text = t end
    function f:GetText() return text end
    function f:SetChecked(v) checked = v and true or false end
    function f:GetChecked() return checked end
    function f:Enable() enabled = true end
    function f:Disable() enabled = false end
    function f:IsEnabled() return enabled end
    -- The template's X button: the client runs PreClick, then OnClick, which hides the frame (and so fires OnHide).
    if select(4, ...) == "BasicFrameTemplateWithInset" then
      local close = base("Button", nil, f, "UIPanelCloseButton")
      close:SetScript("OnClick", function()
        f:Hide()
        local hide = f:GetScript("OnHide")
        if hide then hide(f) end
      end)
      f.CloseButton = close
    end
    return f
  end
end

-- The optional modules that Core + Diagnostics do not load, as plain enabled modules the choices can toggle.
local function fake_optional(p4, ns, guild_settings, on_privacy)
  for _, name in ipairs({ "Orders", "Customers", "Ledger", "Alts", "Planner", "ChatScan" }) do
    p4.fake_module(ns, name, {})
  end
  p4.fake_module(ns, "Guild", {
    Settings = function() return guild_settings end,
    OnPrivacyChanged = on_privacy,
  })
end

describe("Onboarding", function()
  local ns, W, p4, Onboarding, Wizard
  local prices_has_source, guild_settings, privacy_calls, owned

  local function wizard_open() return Wizard:IsShown() end
  local function record() return ns.FS.db.global.onboarding end

  local function boot(stubs)
    prices_has_source = false
    privacy_calls = 0
    guild_settings = { share = true, shareLevel = "quality", shareAlts = "guild" }
    -- GetProfessions: prof1 = Blacksmithing (base 164), prof2 = Alchemy (base 171), no cooking.
    owned = { 164, 171 }
    local overrides = {
      GetProfessions = function() return 1, 2, nil, nil, nil end,
      GetProfessionInfo = function(index)
        local base = owned[index]
        if not base then return nil end
        return ({ [164] = "Blacksmithing", [171] = "Alchemy", [165] = "Leatherworking" })[base], 0, 10, 100, 1, 0, base
      end,
    }
    for k, v in pairs(stubs or {}) do overrides[k] = v end
    ns, W, p4 = boot_phase4(FILES, { last = "Modules/Diagnostics.lua", stubs = overrides })
    patch_frames()
    p4.fake_module(ns, "Prices", { HasSource = function() return prices_has_source end })
    fake_optional(p4, ns, guild_settings, function() privacy_calls = privacy_calls + 1 end)
    local chars = ns.FS.db.global.characters
    -- Me-Realm: Blacksmithing's Midnight line is known (parent 164) but was never scanned; Alchemy has no record at all.
    chars["Me-Realm"] = { professions = { [2907] = { name = "Midnight Blacksmithing", parentSkillLineID = 164,
      recipes = {}, time = 100 } } }
    chars["Alt-Realm"] = { professions = { [2906] = { name = "Midnight Alchemy", parentSkillLineID = 171,
      recipes = { [1] = true }, time = 200 } } }
    Onboarding = ns.FS:GetModule("Onboarding")
    Wizard = ns.UI.OnboardingWizard
  end

  before_each(function() boot() end)

  it("is a toggleable module with the documented constants", function()
    assert.is_truthy(Onboarding)
    assert.is_falsy(Onboarding.coreModule)
    assert.is_true(Onboarding:IsEnabled())
    assert.are.equal(1, Onboarding.VERSION)
    assert.are.same({ "Orders", "Customers", "Ledger", "Alts", "Planner", "Guild", "ChatScan" },
      Onboarding.OPTIONAL_MODULES)
    assert.are.equal("FabricationStation", Onboarding.APP_NAME)
    assert.are.equal("prices", Onboarding.PRICE_GROUP)
  end)

  describe("when to show", function()
    it("shows on a fresh install, not after completion, and again after a version bump", function()
      assert.is_true(Onboarding:ShouldShow())
      Onboarding:Complete(false); assert.is_false(Onboarding:ShouldShow())
      Onboarding.VERSION = 2; assert.is_true(Onboarding:ShouldShow())
    end)

    it("stores the completed version, the time and whether it was skipped", function()
      p4.setNow(5000)
      Onboarding:Complete(true)
      assert.are.same({ completedVersion = 1, time = 5000, skipped = true }, record())
      Onboarding:Complete(false)
      assert.is_false(record().skipped)
    end)

    it("defers while in combat", function()
      p4.inCombat = true; Onboarding:MaybeShow(); assert.is_false(wizard_open())
      assert.are.same({ "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED" }, W.registrations(Onboarding).events)
      p4.inCombat = false; Onboarding:OnRegenEnabled(); assert.is_true(wizard_open())
      assert.are.same({ "PLAYER_ENTERING_WORLD" }, W.registrations(Onboarding).events)
    end)

    it("opens nothing once completed", function()
      Onboarding:Complete(false)
      Onboarding:MaybeShow()
      assert.is_false(wizard_open())
    end)

    it("shows 5 seconds after the first loading screen only", function()
      W.fire("PLAYER_ENTERING_WORLD", true, false)
      p4.advance(4); assert.is_false(wizard_open())
      p4.advance(2); assert.is_true(wizard_open())
      Wizard:Close(); Onboarding.VERSION = 2   -- due again, but a later loading screen must not open it
      W.fire("PLAYER_ENTERING_WORLD", false, false)
      p4.advance(10)
      assert.is_false(wizard_open())
    end)

    it("is quiet while the saved data is from a newer version and writes nothing", function()
      ns.FS.dbIsNewer = true
      assert.is_false(Onboarding:ShouldShow())
      Onboarding:MaybeShow(); assert.is_false(wizard_open())
      assert.is_false(Onboarding:Complete(false))
      ns.FS.dbIsNewer = nil
      assert.is_nil(record())
    end)

    it("disabling leaves no registrations and no pending timer, and closes the wizard without recording a skip", function()
      W.fire("PLAYER_ENTERING_WORLD", true, false)
      Onboarding:Disable()
      assert.are.same({ events = {}, messages = {} }, W.registrations(Onboarding))
      p4.advance(10); assert.is_false(wizard_open())
      Onboarding:Enable()
      Onboarding:MaybeShow(); assert.is_true(wizard_open())
      Onboarding:Disable()
      assert.is_false(wizard_open())
      assert.is_nil(record())
    end)
  end)

  describe("Auctionator", function()
    it("reports the three states", function()
      p4.addons.Auctionator = nil
      assert.are.same({ installed = false, loaded = false, apiOK = false }, Onboarding:CheckAuctionator())
      p4.addons.Auctionator = { exists = true, loaded = false }
      assert.are.same({ installed = true, loaded = false, apiOK = false }, Onboarding:CheckAuctionator())
      p4.addons.Auctionator = { exists = true, loaded = true }; prices_has_source = false
      assert.are.same({ installed = true, loaded = true, apiOK = false }, Onboarding:CheckAuctionator())
      prices_has_source = true
      assert.is_true(Onboarding:CheckAuctionator().apiOK)
    end)
  end)

  describe("ScanStatus", function()
    it("lists scan status per character and flags unscanned professions on the current one", function()
      local s = Onboarding:ScanStatus()
      local me = find(s, "charKey", "Me-Realm"); assert.is_true(me.isCurrent)
      assert.is_true(find(me.professions, "skillLineID", 2907).needsOpen)   -- known profession, no recipes yet
      assert.is_false(find(me.professions, "skillLineID", 2907).scanned)
      local alt = find(s, "charKey", "Alt-Realm")
      assert.is_false(alt.isCurrent)
      local line = find(alt.professions, "skillLineID", 2906)
      assert.is_true(line.scanned); assert.is_false(line.needsOpen)
      assert.are.equal("Midnight Alchemy", line.name)
      assert.are.equal(200, alt.time)
      assert.are.equal("Me-Realm", s[1].charKey)   -- the current character first
    end)

    it("adds the base professions the current character knows but never opened (no record at all)", function()
      local me = find(Onboarding:ScanStatus(), "charKey", "Me-Realm")
      local alchemy = find(me.professions, "skillLineID", 171)   -- prof2: Alchemy, no record
      assert.are.equal("Alchemy", alchemy.name)
      assert.is_true(alchemy.needsOpen); assert.is_false(alchemy.scanned)
      assert.is_nil(find(me.professions, "skillLineID", 164))    -- Blacksmithing is covered by its line 2907
    end)

    it("lists a character with no records at all", function()
      ns.FS.db.global.characters["Me-Realm"] = nil
      local me = find(Onboarding:ScanStatus(), "charKey", "Me-Realm")
      assert.are.same({ 164, 171 }, (function()
        local ids = map(me.professions, "skillLineID"); table.sort(ids); return ids
      end)())
      assert.is_true(me.professions[1].needsOpen and me.professions[2].needsOpen)
    end)

    it("shows current-expansion lines only and skips dropped records", function()
      local chars = ns.FS.db.global.characters
      chars["Me-Realm"].professions[2800] = { name = "Old Smithing", parentSkillLineID = 164, recipes = { [9] = true } }
      chars["Me-Realm"].professions[2906] = { name = "Gone", parentSkillLineID = 171, recipes = {}, dropped = true }
      local me = find(Onboarding:ScanStatus(), "charKey", "Me-Realm")
      assert.is_nil(find(me.professions, "skillLineID", 2800))
      assert.is_nil(find(me.professions, "skillLineID", 2906))
      assert.is_truthy(find(me.professions, "skillLineID", 171))   -- a dropped record does not cover the profession
    end)

    it("asks for a known base profession whose only records are from older expansions", function()
      ns.FS.db.global.characters["Me-Realm"].professions = { [2800] = { name = "Old Smithing",
        parentSkillLineID = 164, recipes = { [9] = true } } }
      local me = find(Onboarding:ScanStatus(), "charKey", "Me-Realm")
      assert.is_true(find(me.professions, "skillLineID", 164).needsOpen)
    end)

    it("names a line from its record, else the client, else a numbered fallback", function()
      local chars = ns.FS.db.global.characters
      chars["Alt-Realm"].professions[2906].name = nil
      chars["Alt-Realm"].professions[2907] = { recipes = { [2] = true } }
      _G.C_TradeSkillUI.GetProfessionInfoBySkillLineID = function(id)
        if id == 2906 then return { professionName = "Client Alchemy" } end
      end
      local alt = find(Onboarding:ScanStatus(), "charKey", "Alt-Realm")
      assert.are.equal("Client Alchemy", find(alt.professions, "skillLineID", 2906).name)
      assert.are.equal("Profession 2907", find(alt.professions, "skillLineID", 2907).name)
    end)

    -- The record has no parent and Knowledge has no base for it, but it is still a current line (snapshot rule).
    local function orphan_line()
      ns.GameData.Define("Knowledge", nil, { variants = {} })   -- no Knowledge base for the line either
      local p = ns.FS.db.global.characters["Me-Realm"].professions[2907]
      p.parentSkillLineID, p.concentration = nil, {}           -- still a current line (snapshot rule), but no parent
    end

    it("does not list a base profession twice when a current line has no parent and no Knowledge base", function()
      orphan_line()
      _G.C_TradeSkillUI.GetProfessionInfoBySkillLineID = function(id)
        return id == 2907 and { parentProfessionID = 164 } or nil
      end
      local me = find(Onboarding:ScanStatus(), "charKey", "Me-Realm")
      assert.is_nil(find(me.professions, "skillLineID", 164))
    end)

    it("uses the client's parentProfessionID when the line's name does not contain the base's name", function()
      orphan_line()
      ns.FS.db.global.characters["Me-Realm"].professions[2907].name = "Midnight Forgework"   -- no "Blacksmithing" in it
      _G.C_TradeSkillUI.GetProfessionInfoBySkillLineID = function(id)
        return id == 2907 and { parentProfessionID = 164 } or nil
      end
      local me = find(Onboarding:ScanStatus(), "charKey", "Me-Realm")
      assert.are.equal("Midnight Forgework", find(me.professions, "skillLineID", 2907).name)
      assert.is_nil(find(me.professions, "skillLineID", 164))      -- covered by the API answer alone
      assert.is_truthy(find(me.professions, "skillLineID", 171))   -- Alchemy has no line at all: still asked for
    end)

    it("falls back to the profession name when the client does not know the parent", function()
      orphan_line()
      _G.C_TradeSkillUI.GetProfessionInfoBySkillLineID = function() return nil end
      local me = find(Onboarding:ScanStatus(), "charKey", "Me-Realm")
      assert.is_nil(find(me.professions, "skillLineID", 164))      -- "Midnight Blacksmithing" contains "Blacksmithing"
      assert.is_truthy(find(me.professions, "skillLineID", 171))   -- Alchemy has no line at all: still asked for
    end)

    it("copes with a client that has no profession functions", function()
      boot({ GetProfessions = false, GetProfessionInfo = false })
      local me = find(Onboarding:ScanStatus(), "charKey", "Me-Realm")
      assert.is_nil(find(me.professions, "skillLineID", 171))
    end)
  end)

  describe("choices", function()
    it("applies only optional module choices", function()
      Onboarding:ApplyModuleChoices({ ChatScan = false, Scanner = false })
      assert.is_false(ns.FS:IsModuleEnabled("ChatScan")); assert.is_true(ns.FS:IsModuleEnabled("Scanner"))
      assert.is_false(ns.FS.db.global.settings.modules.ChatScan)
      Onboarding:ApplyModuleChoices({ ChatScan = true })
      assert.is_true(ns.FS:IsModuleEnabled("ChatScan"))
    end)

    it("writes the social settings through Guild's settings, then announces the privacy change", function()
      Onboarding:ApplySocialChoices({ share = false, shareLevel = "recipes", chatScan = false })
      assert.is_false(guild_settings.share); assert.are.equal("recipes", guild_settings.shareLevel)
      assert.are.equal("guild", guild_settings.shareAlts)   -- untouched
      assert.are.equal(1, privacy_calls)
      assert.is_false(ns.FS:IsModuleEnabled("ChatScan"))
    end)

    it("ignores an unknown share level and leaves unnamed choices alone", function()
      Onboarding:ApplySocialChoices({ shareLevel = "everything" })
      assert.are.equal("quality", guild_settings.shareLevel); assert.is_true(guild_settings.share)
      assert.is_true(ns.FS:IsModuleEnabled("ChatScan"))
    end)

    it("does not announce when Guild is off, and still stores the settings", function()
      ns.FS:SetModuleEnabled("Guild", false)
      Onboarding:ApplySocialChoices({ share = false })
      assert.is_false(guild_settings.share); assert.are.equal(0, privacy_calls)
    end)

    it("announces the privacy change only when a sharing setting actually changed", function()
      Onboarding:ApplySocialChoices({ share = true, shareLevel = "quality", shareAlts = "guild", chatScan = false })
      assert.are.equal(0, privacy_calls)                       -- the live values: no rebuild, no HELLO
      Onboarding:ApplySocialChoices({ shareAlts = "current" })
      assert.are.equal("current", guild_settings.shareAlts)
      assert.are.equal(1, privacy_calls)
      Onboarding:ApplySocialChoices({ shareAlts = "current" })
      assert.are.equal(1, privacy_calls)
    end)

    it("writes shareAlts with GuildOptions' values only", function()
      Onboarding:ApplySocialChoices({ shareAlts = "all" }); assert.are.equal("all", guild_settings.shareAlts)
      Onboarding:ApplySocialChoices({ shareAlts = "everyone" }); assert.are.equal("all", guild_settings.shareAlts)
    end)

    it("announces once after the modules step turned Guild on, even with unchanged settings", function()
      ns.FS:SetModuleEnabled("Guild", false)
      Onboarding:ApplyModuleChoices({ Guild = true })
      Onboarding:ApplySocialChoices({ share = true })
      assert.are.equal(1, privacy_calls)
      Onboarding:ApplySocialChoices({ share = true })
      assert.are.equal(1, privacy_calls)
    end)

    it("changes nothing while the saved data is from a newer version", function()
      ns.FS.dbIsNewer = true
      Onboarding:ApplyModuleChoices({ ChatScan = false })
      Onboarding:ApplySocialChoices({ share = false, chatScan = false })
      ns.FS.dbIsNewer = nil
      assert.is_true(ns.FS:IsModuleEnabled("ChatScan")); assert.is_true(guild_settings.share)
      assert.are.equal(0, privacy_calls)
    end)
  end)

  describe("holding guild sync until the guide is done", function()
    local function done_messages() return #p4.messages("FS_ONBOARDING_DONE") end

    it("holds on a fresh install from before the first loading screen until the guide is finished", function()
      assert.is_true(Onboarding:HoldsSync())                   -- the first loading screen will schedule the guide
      W.fire("PLAYER_ENTERING_WORLD", true, false)
      p4.advance(6)
      assert.is_true(wizard_open())
      assert.is_true(Onboarding:HoldsSync())
      assert.are.equal(0, done_messages())
      Wizard:Finish()
      assert.is_false(Onboarding:HoldsSync())
      assert.are.equal(1, done_messages())
    end)

    it("keeps holding after an incidental hide and releases on Skip", function()
      W.fire("PLAYER_ENTERING_WORLD", true, false); p4.advance(5)
      assert.is_true(wizard_open())
      local f = Wizard:GetControls().frame
      f:Hide(); f:GetScript("OnHide")(f)                       -- Escape
      assert.is_true(Onboarding:HoldsSync())
      assert.are.equal(0, done_messages())
      ns.FS:HandleSlash("setup"); assert.is_true(wizard_open())
      local skip = Wizard:GetControls().skip
      skip:GetScript("OnClick")(skip)
      assert.is_false(Onboarding:HoldsSync())
      assert.are.equal(1, done_messages())
    end)

    it("stops holding when the guide is skipped", function()
      W.fire("PLAYER_ENTERING_WORLD", true, false); p4.advance(6)
      Wizard:Close()
      assert.is_true(record().skipped)
      assert.is_false(Onboarding:HoldsSync())
      assert.are.equal(1, done_messages())
    end)

    it("holds while the guide waits for the end of combat", function()
      p4.inCombat = true
      W.fire("PLAYER_ENTERING_WORLD", true, false); p4.advance(6)
      assert.is_false(wizard_open())
      assert.is_true(Onboarding:HoldsSync())
      p4.inCombat = false
      W.fire("PLAYER_REGEN_ENABLED")
      assert.is_true(wizard_open())
    end)

    it("does not hold once the guide was finished or skipped, even for an older guide version", function()
      Onboarding:Complete(true)
      W.fire("PLAYER_ENTERING_WORLD", true, false)
      assert.is_false(Onboarding:HoldsSync())
      Onboarding.VERSION = 2                                    -- an upgrader: the guide shows again, holding nothing
      finally(function() Onboarding.VERSION = 1 end)
      assert.is_true(Onboarding:ShouldShow())
      assert.is_false(Onboarding:HoldsSync())
    end)

    it("does not hold while the saved data is from a newer version", function()
      ns.FS.dbIsNewer = true
      W.fire("PLAYER_ENTERING_WORLD", true, false)
      assert.is_false(Onboarding:HoldsSync())
      ns.FS.dbIsNewer = nil
    end)

    it("does not hold while Onboarding is off, and turning it off releases a hold at once", function()
      W.fire("PLAYER_ENTERING_WORLD", true, false); p4.advance(6)
      assert.is_true(Onboarding:HoldsSync())
      ns.FS:SetModuleEnabled("Onboarding", false)
      assert.is_false(Onboarding:HoldsSync())
      assert.are.equal(1, done_messages())
      assert.is_nil(record())                                   -- nothing recorded: the user did not close it
      ns.FS:SetModuleEnabled("Onboarding", true)
      assert.is_false(Onboarding:HoldsSync())                   -- not scheduled again this session
    end)

    it("does not hold when Onboarding is turned on after the first loading screen", function()
      ns.FS:SetModuleEnabled("Onboarding", false)
      W.fire("PLAYER_ENTERING_WORLD", true, false)
      ns.FS:SetModuleEnabled("Onboarding", true)
      assert.is_false(Onboarding:HoldsSync())
      p4.advance(10)
      assert.is_false(wizard_open())
    end)
  end)

  it("orders steps", function()
    assert.are.same({ "welcome", "auctionator", "scan", "modules", "prices", "social", "done" },
      map(Onboarding:GetSteps(), "id"))
    for _, step in ipairs(Onboarding:GetSteps()) do assert.are.equal("string", type(step.title)) end
  end)

  it("registers /fs setup", function()
    ns.FS:HandleSlash("setup"); assert.is_true(wizard_open())
  end)

  it("opens price settings by selecting the group first and then showing the settings tab", function()
    local order = {}
    local dialog = LibStub("AceConfigDialog-3.0")
    local select_group = dialog.SelectGroup
    dialog.SelectGroup = function(self, ...) order[#order + 1] = "select"; return select_group(self, ...) end
    p4.fake_module(ns, "MainWindow", { Show = function(_, tab) order[#order + 1] = "show:" .. tostring(tab) end })
    Onboarding:OpenPriceSettings()
    dialog.SelectGroup = select_group
    assert.are.same({ "select", "show:settings" }, order)
    assert.are.same({ app = "FabricationStation", path = { "prices" } }, W.config.selected)
  end)
end)

describe("OnboardingWizard", function()
  local ns, W, p4, Onboarding, Wizard, guild_settings, privacy_calls, prices_has_source

  local function click(button) button:GetScript("OnClick")(button) end
  local function record() return ns.FS.db.global.onboarding end

  before_each(function()
    privacy_calls = 0
    guild_settings = { share = true, shareLevel = "quality", shareAlts = "guild" }
    ns, W, p4 = boot_phase4(FILES, { last = "Modules/Diagnostics.lua" })
    patch_frames()
    prices_has_source = false
    p4.fake_module(ns, "Prices", { HasSource = function() return prices_has_source end })
    fake_optional(p4, ns, guild_settings, function() privacy_calls = privacy_calls + 1 end)
    Onboarding = ns.FS:GetModule("Onboarding")
    Wizard = ns.UI.OnboardingWizard
  end)

  local function step_id() return Onboarding:GetSteps()[Wizard:GetStep()].id end
  local function goto_step(id)
    for i, step in ipairs(Onboarding:GetSteps()) do
      if step.id == id then Wizard:ShowStep(i); return end
    end
  end

  local function click_close(f)
    local b = f.CloseButton
    local pre = b:GetScript("PreClick"); if pre then pre(b) end
    b:GetScript("OnClick")(b)
    local post = b:GetScript("PostClick"); if post then post(b) end
  end
  local function escape(f) f:Hide(); f:GetScript("OnHide")(f) end
  local function hide_with_ui(f) f:GetScript("OnHide")(f) end    -- parent hidden: the frame's own shown flag stays true

  it("is a Blizzard-template frame in UISpecialFrames, hidden until opened", function()
    local c = Wizard:GetControls()
    assert.are.equal("BasicFrameTemplateWithInset", c.frame.template)
    local found
    for _, name in ipairs(UISpecialFrames) do if name == c.frame:GetName() then found = true end end
    assert.is_true(found)
    Wizard:Close(true)
    assert.is_false(Wizard:IsShown())
    Wizard:Open()
    assert.is_true(Wizard:IsShown()); assert.are.equal(1, Wizard:GetStep())
  end)

  it("walks Back and Next, with Back hidden on the first step and Finish on the last", function()
    Wizard:Open()
    local c = Wizard:GetControls()
    assert.is_false(c.back:IsShown())
    click(c.next); assert.are.equal("auctionator", step_id()); assert.is_true(c.back:IsShown())
    click(c.back); assert.are.equal("welcome", step_id())
    for _ = 1, 6 do click(c.next) end
    assert.are.equal("done", step_id())
    assert.is_false(c.skip:IsShown())
    assert.are.equal("Finish", c.next:GetText())
  end)

  it("clamps ShowStep to the existing steps", function()
    Wizard:Open()
    Wizard:ShowStep(0); assert.are.equal(1, Wizard:GetStep())
    Wizard:ShowStep(99); assert.are.equal(7, Wizard:GetStep())
  end)

  it("Skip completes as skipped and closes", function()
    Wizard:Open()
    click(Wizard:GetControls().skip)
    assert.is_false(Wizard:IsShown())
    assert.is_true(record().skipped); assert.is_false(Onboarding:ShouldShow())
  end)

  it("counts the close button as Skip", function()
    Wizard:Open(); click_close(Wizard:GetControls().frame)
    assert.is_true(record().skipped); assert.is_false(Onboarding:ShouldShow())
  end)

  it("keeps the guide pending when it is hidden with the UI", function()
    Wizard:Open(); Wizard:ShowStep(3)
    hide_with_ui(Wizard:GetControls().frame)
    assert.is_nil(record()); assert.is_true(Wizard:IsShown()); assert.are.equal(3, Wizard:GetStep())
    click(Wizard:GetControls().skip); assert.is_true(record().skipped)    -- a later Skip still records
  end)

  it("keeps the guide pending when Escape closes it", function()
    Wizard:Open(); escape(Wizard:GetControls().frame)
    assert.is_nil(record()); assert.is_false(Wizard:IsShown()); assert.is_true(Onboarding:ShouldShow())
    ns.FS:HandleSlash("setup"); assert.is_true(Wizard:IsShown()); assert.are.equal(1, Wizard:GetStep())
  end)

  it("records nothing when the last step is hidden with the UI or by Escape", function()
    Wizard:Open(); goto_step("done"); hide_with_ui(Wizard:GetControls().frame); escape(Wizard:GetControls().frame)
    assert.is_nil(record())
  end)

  it("does not let a close request whose hide never came turn a later Escape into a choice", function()
    Wizard:Open()
    local b = Wizard:GetControls().frame.CloseButton
    b:GetScript("PreClick")(b); b:GetScript("PostClick")(b)   -- the click ran, but the frame was not hidden
    escape(Wizard:GetControls().frame)
    assert.is_nil(record())
  end)

  it("works without a template close button: Escape still keeps the guide pending", function()
    local base = _G.CreateFrame
    _G.CreateFrame = function(...)
      local f = base(...)
      rawset(f, "CloseButton", nil)                             -- the fake answers a stub for unknown fields
      return f
    end
    finally(function() _G.CreateFrame = base end)
    Wizard:Open()
    assert.is_true(Wizard:IsShown())
    escape(Wizard:GetControls().frame)
    assert.is_nil(record()); assert.is_true(Onboarding:ShouldShow())
    Wizard:Open(); click(Wizard:GetControls().skip)
    assert.is_true(record().skipped)
  end)

  it("writes nothing through any close path while the saved data is from a newer version", function()
    ns.FS.dbIsNewer = true
    finally(function() ns.FS.dbIsNewer = nil end)
    Wizard:Open(); click_close(Wizard:GetControls().frame)
    assert.is_nil(record()); assert.is_false(Wizard:IsShown())
    Wizard:Open(); click(Wizard:GetControls().skip)
    assert.is_nil(record())
    Wizard:Open(); goto_step("done"); click(Wizard:GetControls().next)
    assert.is_nil(record())
  end)

  it("Finish completes as not skipped and applies nothing twice", function()
    Wizard:Open()
    goto_step("done")
    click(Wizard:GetControls().next)
    assert.is_false(Wizard:IsShown())
    assert.is_false(record().skipped); assert.are.equal(1, record().completedVersion)
  end)

  it("reopening after completion does not turn a finished setup into a skipped one", function()
    Onboarding:Complete(false)
    ns.FS:HandleSlash("setup")
    Wizard:Close()
    assert.is_false(record().skipped)
  end)

  it("applies the module choices when leaving the modules step and the social choices when leaving the social step",
    function()
      Wizard:Open()
      goto_step("modules")
      local c = Wizard:GetControls()
      click(c.moduleChecks.Orders)
      assert.is_false(Wizard:GetChoices().modules.Orders)
      assert.is_true(ns.FS:IsModuleEnabled("Orders"))   -- nothing applied yet
      click(c.next)
      assert.is_false(ns.FS:IsModuleEnabled("Orders"))     -- applied when leaving the modules step
      assert.is_true(ns.FS:IsModuleEnabled("Customers"))
      assert.are.equal("prices", step_id())
      goto_step("social")
      click(c.shareCheck); click(c.levelButton); click(c.chatScanCheck)
      assert.is_false(Wizard:GetChoices().share)
      assert.are.equal("recipes", Wizard:GetChoices().shareLevel)
      assert.is_true(guild_settings.share)   -- not applied yet
      click(c.next)
      assert.is_false(guild_settings.share); assert.are.equal("recipes", guild_settings.shareLevel)
      assert.is_false(ns.FS:IsModuleEnabled("ChatScan"))
      assert.are.equal(1, privacy_calls)
      assert.are.equal("done", step_id())
    end)

  it("shows the pending choice in each box and on the level button", function()
    Wizard:Open()
    goto_step("modules")
    local c = Wizard:GetControls()
    assert.is_true(c.moduleChecks.Orders:GetChecked())
    click(c.moduleChecks.Orders); assert.is_false(c.moduleChecks.Orders:GetChecked())
    click(c.moduleChecks.Orders); assert.is_true(c.moduleChecks.Orders:GetChecked())
    goto_step("social")
    assert.are.equal("Recipes and expected quality", c.levelButton:GetText())
    click(c.levelButton)
    assert.are.equal("Recipes only", c.levelButton:GetText())
    click(c.levelButton)
    assert.are.equal("Recipes and expected quality", c.levelButton:GetText())
    assert.is_true(c.shareCheck:IsEnabled())
    goto_step("modules"); click(c.moduleChecks.Guild); goto_step("social")
    assert.is_false(c.shareCheck:IsEnabled()); assert.is_false(c.levelButton:IsEnabled())
  end)

  it("leaves the sharing settings alone when the Guild feature was turned off", function()
    Wizard:Open()
    goto_step("modules"); click(Wizard:GetControls().moduleChecks.Guild); click(Wizard:GetControls().next)
    assert.is_false(ns.FS:IsModuleEnabled("Guild"))
    goto_step("social")
    click(Wizard:GetControls().shareCheck)   -- cannot be clicked in the client while disabled; the guard is Next's
    click(Wizard:GetControls().next)
    assert.is_true(guild_settings.share)
  end)

  it("leaves everything alone when skipped", function()
    Wizard:Open()
    goto_step("modules")
    click(Wizard:GetControls().moduleChecks.Orders)
    click(Wizard:GetControls().skip)
    assert.is_true(ns.FS:IsModuleEnabled("Customers"))
    assert.is_true(ns.FS:IsModuleEnabled("Orders"))
  end)

  it("starts the module choices from the live state", function()
    ns.FS:SetModuleEnabled("Ledger", false)
    Wizard:Open()
    assert.is_false(Wizard:GetChoices().modules.Ledger)
    assert.is_true(Wizard:GetChoices().modules.Planner)
    assert.is_true(Wizard:GetChoices().share)
  end)

  it("says which Auctionator state it found", function()
    local function status_text()
      goto_step("auctionator")
      return Wizard:GetControls().steps.auctionator.status:GetText() .. "\n"
        .. Wizard:GetControls().steps.auctionator.body:GetText()
    end
    Wizard:Open()
    local missing = status_text()
    p4.addons.Auctionator = { exists = true, loaded = false }
    local off = status_text()
    p4.addons.Auctionator = { exists = true, loaded = true }
    local noapi = status_text()
    prices_has_source = true
    local ok = status_text()
    local seen = {}
    for i, text in ipairs({ missing, off, noapi, ok }) do
      assert.is_nil(seen[text], text .. " (" .. i .. ")"); seen[text] = true
    end
    assert.is_truthy(missing:find("not installed", 1, true))
    assert.is_truthy(ok:find("connected", 1, true))
  end)

  it("explains the scan and lists each character with what to open", function()
    local chars = ns.FS.db.global.characters
    chars["Me-Realm"] = { professions = { [2907] = { name = "Midnight Blacksmithing", parentSkillLineID = 164,
      recipes = {} } } }
    chars["Alt-Realm"] = { professions = { [2906] = { name = "Midnight Alchemy", parentSkillLineID = 171,
      recipes = { [1] = true } } } }
    Wizard:Open()
    goto_step("scan")
    local scan = Wizard:GetControls().steps.scan
    assert.are.equal("Log in to each crafter and open each profession window once. FabricationStation reads recipes, skill and specialization from that window.",
      scan.body:GetText())
    local rows = Wizard.ScanRows(Onboarding:ScanStatus())
    local text = {}
    for _, row in ipairs(rows) do text[#text + 1] = row.text end
    local joined = table.concat(text, "\n")
    assert.is_truthy(joined:find("Me-Realm", 1, true)); assert.is_truthy(joined:find("Alt-Realm", 1, true))
    assert.is_truthy(joined:find("Midnight Blacksmithing", 1, true))
    assert.is_truthy(joined:find("open", 1, true))
    assert.is_truthy(joined:find("scanned", 1, true))
    assert.is_true(scan.rowCount >= #rows)
  end)

  it("opens the price settings from the prices step", function()
    local shown
    p4.fake_module(ns, "MainWindow", { Show = function(_, tab) shown = tab end })
    Wizard:Open()
    goto_step("prices")
    click(Wizard:GetControls().steps.prices.openButton)
    assert.are.equal("settings", shown)
    assert.are.same({ "prices" }, W.config.selected.path)
    assert.are.equal("Open price settings", Wizard:GetControls().steps.prices.openButton:GetText())
  end)

  it("ends with the slash-command hint", function()
    Wizard:Open()
    goto_step("done")
    assert.are.equal("Type /fs to open FabricationStation. /fs setup reopens this guide.",
      Wizard:GetControls().steps.done.body:GetText())
  end)

  it("greys the sharing options when the Guild module is turned off in the wizard", function()
    Wizard:Open()
    goto_step("modules")
    click(Wizard:GetControls().moduleChecks.Guild)
    goto_step("social")
    assert.is_true(Wizard:GetControls().steps.social.guildOff:IsShown())
    goto_step("modules")
    click(Wizard:GetControls().moduleChecks.Guild)
    goto_step("social")
    assert.is_false(Wizard:GetControls().steps.social.guildOff:IsShown())
  end)

  it("greys the share checkbox label while the Guild feature is turned off", function()
    Wizard:Open()
    goto_step("modules")
    click(Wizard:GetControls().moduleChecks.Guild)
    goto_step("social")
    assert.are.equal("GameFontDisable", Wizard:GetControls().shareCheck.text:GetFontObject())
    assert.are_not.equal("GameFontDisable", Wizard:GetControls().chatScanCheck.text:GetFontObject())
    goto_step("modules")
    click(Wizard:GetControls().moduleChecks.Guild)
    goto_step("social")
    assert.are.equal("GameFontNormal", Wizard:GetControls().shareCheck.text:GetFontObject())
  end)

  it("writes nothing while the saved data is from a newer version and says so on the last step", function()
    ns.FS.dbIsNewer = true
    Wizard:Open()
    goto_step("modules"); click(Wizard:GetControls().moduleChecks.Orders)
    for _ = 1, 6 do click(Wizard:GetControls().next) end
    assert.are.equal("done", step_id())
    assert.is_true(Wizard:GetControls().steps.done.note:IsShown())
    click(Wizard:GetControls().next)
    ns.FS.dbIsNewer = nil
    assert.is_nil(record())
    assert.is_true(ns.FS:IsModuleEnabled("Orders"))
    assert.are.equal(0, privacy_calls)
  end)

  it("cycles which characters to share with GuildOptions' values and applies it with the social step", function()
    Wizard:Open()
    goto_step("social")
    local c = Wizard:GetControls()
    assert.are.equal("My characters in this guild", c.altsButton:GetText())
    click(c.altsButton)
    assert.are.equal("All my characters", c.altsButton:GetText())
    click(c.altsButton)
    assert.are.equal("Only the character I am playing", c.altsButton:GetText())
    assert.are.equal("guild", guild_settings.shareAlts)        -- not applied yet
    click(c.next)
    assert.are.equal("current", guild_settings.shareAlts)
    assert.are.equal(1, privacy_calls)
    goto_step("modules"); click(c.moduleChecks.Guild); goto_step("social")
    assert.is_false(c.altsButton:IsEnabled())
  end)

  it("leaves the privacy settings and Guild alone when the social step changes nothing", function()
    Wizard:Open()
    goto_step("social")
    click(Wizard:GetControls().next)
    assert.are.equal(0, privacy_calls)
  end)

  it("records a finished guide when the close button is used on the last step", function()
    Wizard:Open()
    goto_step("done")
    click_close(Wizard:GetControls().frame)
    assert.is_false(record().skipped)
    assert.are.equal(1, record().completedVersion)
  end)

  it("says on the first step that nothing will be saved while the saved data is from a newer version", function()
    Wizard:Open()
    assert.is_false(Wizard:GetControls().steps.welcome.readOnly:IsShown())
    Wizard:Close(true)
    ns.FS.dbIsNewer = true
    Wizard:Open()
    assert.are.equal(1, Wizard:GetStep())
    assert.is_true(Wizard:GetControls().steps.welcome.readOnly:IsShown())
    Wizard:Close(true)
    ns.FS.dbIsNewer = nil
  end)

  it("does not raise or log anything while stepping through every step", function()
    Wizard:Open()
    for i = 1, 7 do Wizard:ShowStep(i) end
    assert.same({}, ns.FS.db.global.diagnostics.errors)
  end)

  describe("layout from the measured text", function()
    -- Every key reads as its English text plus about half again as many "w" letters (a German-length translation).
    local function long_locale(factor)
      for key in pairs(ns.L) do rawset(ns.L, key, nil) end   -- keys read before this call are cached as English
      setmetatable(ns.L, { __index = function(_, key) return key .. " " .. ("w"):rep(math.ceil(#key * (factor or 1) / 2)) end })
    end
    local function top(region) return -select(5, region:GetPoint(1)) end
    local function height_of(item)
      return item.kind == "button" and select(2, item.region:GetSize()) or item.region:GetHeight()
    end

    it("fits every step under a long locale", function()
      long_locale()                                   -- before the frame is built
      Wizard:Open()
      local c = Wizard:GetControls()
      for i, step in ipairs(Onboarding:GetSteps()) do
        Wizard:ShowStep(i)
        local _, frameHeight = c.frame:GetSize()
        assert.is_true(#c.steps[step.id].layout > 0, step.id)
        for _, item in ipairs(c.steps[step.id].layout) do
          local r = item.region
          if r:IsShown() then
            local height = height_of(item)
            if item.kind == "wrap" then assert.is_true(r:GetHeight() >= full_height(r), step.id) end
            if item.kind == "line" then assert.is_true(r:GetStringWidth() <= r:GetWidth(), step.id) end
            if item.kind == "button" then assert.is_true(r:GetTextWidth() + 16 <= (r:GetSize()), step.id) end
            if item.kind == "check" then assert.is_true(r.text:GetStringWidth() <= r.text:GetWidth(), step.id) end
            if item.kind ~= "scroll" then assert.is_true(top(r) + height <= frameHeight - 76, step.id) end
          end
        end
      end
    end)

    it("stacks the shown regions without overlap, in the builder's order", function()
      long_locale()
      Wizard:Open()
      local c = Wizard:GetControls()
      for i, step in ipairs(Onboarding:GetSteps()) do
        Wizard:ShowStep(i)
        local previous
        for _, item in ipairs(c.steps[step.id].layout) do
          if item.region:IsShown() and item.kind ~= "scroll" then
            if previous then
              -- a module's description starts 2 px under its box's top edge by design (the box is 24 px, the text 22)
              assert.is_true(top(item.region) >= top(previous.region) + height_of(previous) - 2, step.id)
            end
            previous = item
          end
        end
      end
    end)

    it("keeps the English layout at 440 px", function()
      Wizard:Open()
      for i = 1, #Onboarding:GetSteps() do
        Wizard:ShowStep(i)
        assert.are.equal(440, select(2, Wizard:GetControls().frame:GetSize()))
      end
    end)

    it("keeps the English positions of the text and buttons", function()
      Wizard:Open()
      local c = Wizard:GetControls()
      local function tops(id)
        local out = {}
        for _, item in ipairs(c.steps[id].layout) do
          if item.region:IsShown() then out[#out + 1] = top(item.region) end
        end
        return out
      end
      Wizard:ShowStep(1); assert.are.same({ 0, 32, 112 }, tops("welcome"))
      ns.FS.dbIsNewer = true; Wizard:ShowStep(1); assert.are.same({ 0, 32, 112, 172 }, tops("welcome"))
      ns.FS.dbIsNewer = nil
      goto_step("auctionator"); assert.are.same({ 0, 32, 58, 160 }, tops("auctionator"))
      goto_step("scan"); assert.are.same({ 0, 28, 80 }, tops("scan"))
      goto_step("modules")
      assert.are.same({ 0, 28, 64, 86, 110, 132, 156, 178, 202, 224, 248, 270, 294, 316 }, tops("modules"))
      goto_step("prices"); assert.are.same({ 0, 32, 112, 144 }, tops("prices"))
      goto_step("done"); assert.are.same({ 0, 32 }, tops("done"))
      ns.FS.dbIsNewer = true; goto_step("done"); assert.are.same({ 0, 32, 90 }, tops("done"))
      ns.FS.dbIsNewer = nil
    end)

    it("shows only the value on the two cycle buttons, each under its heading", function()
      Wizard:Open()
      goto_step("social")
      local c = Wizard:GetControls()
      local social = c.steps.social
      assert.are.equal("What to share", social.levelLabel:GetText())
      assert.are.equal("Which characters to share", social.altsLabel:GetText())
      assert.is_true(top(social.levelLabel) + 14 <= top(c.levelButton))
      assert.is_true(top(c.levelButton) + 22 <= top(social.altsLabel))
      assert.is_true(top(social.altsLabel) + 14 <= top(c.altsButton))
    end)

    it("sizes a button from its text, never under its English width", function()
      Wizard:Open()
      goto_step("social")
      local c = Wizard:GetControls()
      assert.are.equal(430, (c.altsButton:GetSize()))       -- short text: today's width is the floor
      assert.are.equal(300, (c.levelButton:GetSize()))
      goto_step("auctionator")
      assert.are.equal(110, (Wizard:GetControls().steps.auctionator.again:GetSize()))
    end)

    it("grows a button to its text under a long locale and re-fits it when the text changes", function()
      long_locale(3)
      Wizard:Open()
      goto_step("social")
      local c = Wizard:GetControls()
      local text = "My characters in this guild " .. ("w"):rep(math.ceil(#"My characters in this guild" * 3 / 2))
      assert.are.equal(text, c.altsButton:GetText())
      assert.are.equal(#text * CHAR_W + 24, (c.altsButton:GetSize()))   -- grown to fit its text
      click(c.altsButton)                                                -- the next, shorter value re-fits it
      assert.are.equal(math.max(430, c.altsButton:GetTextWidth() + 24), (c.altsButton:GetSize()))
      goto_step("auctionator")
      local again = Wizard:GetControls().steps.auctionator.again
      assert.are.equal(again:GetTextWidth() + 24, (again:GetSize()))
      assert.is_true((again:GetSize()) > 110)
    end)

    it("grows the window when a step needs more room, up to the screen", function()
      long_locale(8)
      Wizard:Open()
      goto_step("modules")
      local c = Wizard:GetControls()
      local _, grown = c.frame:GetSize()
      assert.is_true(grown > 440)
      assert.is_true(grown <= 768 - 40)
      _G.UIParent:SetSize(1024, 500)
      goto_step("modules")
      assert.are.equal(460, select(2, c.frame:GetSize()))
      goto_step("done")
      assert.are.equal(440, select(2, c.frame:GetSize()))   -- a short step goes back to the usual height
    end)

    it("falls back to the English box heights when the client measures nothing", function()
      measureNothing = true
      Wizard:Open()
      local c = Wizard:GetControls()
      for i = 1, #Onboarding:GetSteps() do
        Wizard:ShowStep(i)
        assert.are.equal(440, select(2, c.frame:GetSize()))
      end
      goto_step("welcome")
      assert.are.equal(70, c.steps.welcome.body:GetHeight())
      goto_step("modules")
      assert.are.equal(24, c.steps.modules.layout[4].region:GetHeight())
    end)
  end)
end)
