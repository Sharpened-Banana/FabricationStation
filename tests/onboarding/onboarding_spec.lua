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

-- The shared frame fake keeps no text, check state or enabled state for buttons; the wizard's controls get them here.
local function patch_frames()
  local base = _G.CreateFrame
  _G.CreateFrame = function(...)
    local f = base(...)
    local text, checked, enabled = nil, false, true
    function f:SetText(t) text = t end
    function f:GetText() return text end
    function f:SetChecked(v) checked = v and true or false end
    function f:GetChecked() return checked end
    function f:Enable() enabled = true end
    function f:Disable() enabled = false end
    function f:IsEnabled() return enabled end
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

    it("changes nothing while the saved data is from a newer version", function()
      ns.FS.dbIsNewer = true
      Onboarding:ApplyModuleChoices({ ChatScan = false })
      Onboarding:ApplySocialChoices({ share = false, chatScan = false })
      ns.FS.dbIsNewer = nil
      assert.is_true(ns.FS:IsModuleEnabled("ChatScan")); assert.is_true(guild_settings.share)
      assert.are.equal(0, privacy_calls)
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

  it("counts closing the window (the X button, Escape) as Skip", function()
    Wizard:Open()
    Wizard:GetControls().frame:GetScript("OnHide")(Wizard:GetControls().frame)
    assert.is_true(record().skipped)
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
    assert.are.equal("What to share: Recipes and expected quality", c.levelButton:GetText())
    click(c.levelButton)
    assert.are.equal("What to share: Recipes only", c.levelButton:GetText())
    click(c.levelButton)
    assert.are.equal("What to share: Recipes and expected quality", c.levelButton:GetText())
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

  it("does not raise or log anything while stepping through every step", function()
    Wizard:Open()
    for i = 1, 7 do Wizard:ShowStep(i) end
    assert.same({}, ns.FS.db.global.diagnostics.errors)
  end)
end)
