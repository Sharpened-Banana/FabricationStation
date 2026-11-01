local ADDON_NAME, ns = ...

-- Onboarding: the first-run setup guide. This module holds the logic, the state and the "when to show" rule; the
-- window is UI/OnboardingWizard.lua. The guide walks a new user through Auctionator (the price source), scanning the
-- professions, the optional modules, price settings and the social features (guild sharing, chat scanning).
--
-- When it shows: five seconds after the FIRST PLAYER_ENTERING_WORLD of the session (later loading screens never open
-- it), only when ShouldShow() (never completed, or completed for an older VERSION), never while the saved data is
-- from a newer version, and not in combat (it waits for PLAYER_REGEN_ENABLED). /fs setup reopens it at any time.
-- Closing it in any way counts as Skip: the choice is recorded, so it does not return at every login.
--
-- Saved data (lazily created): db.global.onboarding = { completedVersion = int|nil, time = number|nil,
-- skipped = boolean|nil }. Nothing is written while the saved data is from a newer version.
--
-- Choices: the wizard applies the module choices when the user leaves the modules step and the social choices when
-- they leave the social step. Both go through the owning modules' own switches (ns.FS:SetModuleEnabled and
-- Guild:Settings()), never through another module's saved table.
--
-- Consent before send: HoldsSync() is true while the guide will be or is being offered this session and was never
-- finished or skipped (no completedVersion at all). Guild then sends no HELLO listing characters and no DATA. The
-- hold is never permanent: without a guide to offer (completed, even for an older VERSION; saved data from a newer
-- version; Onboarding off; the guide not scheduled this session; no wizard) there is none, and Complete() and
-- OnDisable send FS_ONBOARDING_DONE so Guild starts at once.
--
-- Timers: one Debounce key ("onboarding.show"), cancelled in OnDisable.
local Onboarding = ns.FS:NewModule("Onboarding", "AceEvent-3.0")

local Util = ns.Social and ns.Social.Util

-- Call-time lookup: ns.L may be replaced after this file loaded (specs; the real AceLocale table is there from the
-- start in game).
local L = setmetatable({}, { __index = function(_, key) return ns.L[key] end })

Onboarding.VERSION = 1
Onboarding.OPTIONAL_MODULES = { "Orders", "Customers", "Ledger", "Alts", "Planner", "Guild", "ChatScan" }
Onboarding.APP_NAME = "FabricationStation"   -- Core registers the AceConfig options table under this name
Onboarding.PRICE_GROUP = "prices"            -- Prices registers its options group under this key
Onboarding.SHOW_DELAY = 5                    -- seconds after the first PLAYER_ENTERING_WORLD
Onboarding.SHARE_LEVELS = { "quality", "recipes" }

local SOURCE = "Onboarding"
local SHOW_KEY = "onboarding.show"
local AUCTIONATOR = "Auctionator"
-- GetProfessions() returns the spellbook indices of prof1, prof2, archaeology, fishing and cooking. The wizard asks
-- for the two main professions and cooking: archaeology and fishing have no recipes to read.
local CRAFT_PROFESSION_INDICES = { 1, 2, 5 }

local function read_only() return ns.FS.dbIsNewer == true end

local function global()
  return ns.FS.db and ns.FS.db.global
end

local function writable()
  return global() ~= nil and not ns.FS.dbIsNewer
end

local function module(name) return ns.FS:GetModule(name, true) end

local function wizard() return ns.UI and ns.UI.OnboardingWizard end

---------------------------------------------------------------------------
-- When to show
---------------------------------------------------------------------------

-- The stored record (a table), or nil.
local function record()
  local g = global()
  local r = g and g.onboarding
  if type(r) == "table" then return r end
end

-- True when the guide has not been completed for this VERSION. False while the saved data is from a newer version
-- (the guide would write nothing) or before the saved data exists.
function Onboarding:ShouldShow()
  if read_only() or not global() then return false end
  local r = record()
  local done = r and r.completedVersion
  return type(done) ~= "number" or done < self.VERSION
end

-- Records that the guide was finished or skipped for the current VERSION, then tells Guild the hold is over. -> true
-- when it was written.
function Onboarding:Complete(skipped)
  if not writable() then return false end
  global().onboarding = { completedVersion = self.VERSION, time = ns.FS:Now(), skipped = skipped and true or false }
  ns.FS:SendMessage(ns.Msg.ONBOARDING_DONE)
  return true
end

local offerPending = false     -- the first loading screen scheduled the guide and Onboarding stayed on since
local sessionHandled = false   -- the first PLAYER_ENTERING_WORLD of the session was handled
local worldEntered = false     -- the first PLAYER_ENTERING_WORLD happened (seen even while Onboarding is off)

-- True while guild sync must wait for the guide (see the header): Onboarding is on, the saved data is writable, the
-- wizard exists, the guide was never finished or skipped, and it is scheduled for this session (or will be at the
-- first loading screen, which has not happened yet).
function Onboarding:HoldsSync()
  if not self:IsEnabled() or not writable() or not wizard() then return false end
  local r = record()
  if r and type(r.completedVersion) == "number" then return false end
  return offerPending or (not sessionHandled and not worldEntered)
end

-- Opens the guide when it is due. In combat it waits for the end of combat instead. -> true when it was opened.
function Onboarding:MaybeShow()
  if not self:IsEnabled() then return false end
  if InCombatLockdown() then
    self:RegisterEvent("PLAYER_REGEN_ENABLED", ns.FS:Wrap(SOURCE, function() self:OnRegenEnabled() end))
    return false
  end
  if not self:ShouldShow() then return false end
  local w = wizard()
  if not w then return false end
  w:Open()
  return true
end

function Onboarding:OnRegenEnabled()
  self:UnregisterEvent("PLAYER_REGEN_ENABLED")
  self:MaybeShow()
end

---------------------------------------------------------------------------
-- Auctionator and scan status
---------------------------------------------------------------------------

-- -> { installed, loaded, apiOK }: the addon exists, is loaded, and Prices can read prices from it.
function Onboarding:CheckAuctionator()
  local addons = C_AddOns
  local exists = type(addons) == "table" and type(addons.DoesAddOnExist) == "function"
    and addons.DoesAddOnExist(AUCTIONATOR) or false
  local loaded = type(addons) == "table" and type(addons.IsAddOnLoaded) == "function"
    and addons.IsAddOnLoaded(AUCTIONATOR) or false
  exists, loaded = exists and true or false, loaded and true or false
  local installed = exists or loaded
  local apiOK = false
  local prices = module("Prices")
  if installed and loaded and prices and type(prices.HasSource) == "function" then
    local ok, has = pcall(prices.HasSource, prices)
    apiOK = ok and has == true
  end
  return { installed = installed, loaded = loaded, apiOK = apiOK }
end

local function knowledge_variants()
  local GD = ns.GameData
  local k = GD and type(GD.Get) == "function" and GD.Get("Knowledge") or nil
  return type(k) == "table" and type(k.variants) == "table" and k.variants or nil
end

-- The base profession (skill line, e.g. 164 Blacksmithing) of a profession record: its parentSkillLineID, else the
-- base of its Knowledge.variants entry.
local function base_of(line, p, variants)
  if type(p.parentSkillLineID) == "number" then return p.parentSkillLineID end
  local v = variants and variants[line]
  if type(v) == "table" and type(v.base) == "number" then return v.base end
end

-- The main professions and cooking the current character knows now: { { id = baseSkillLine, name } }. Feature-tested
-- (neither function is in the generated API documentation); an unknown profession is simply not listed.
local function known_base_professions()
  local out = {}
  if type(GetProfessions) ~= "function" or type(GetProfessionInfo) ~= "function" then return out end
  local ok, indices = pcall(function() return { GetProfessions() } end)
  if not ok then return out end
  for _, slot in ipairs(CRAFT_PROFESSION_INDICES) do
    local index = indices[slot]
    if index then
      local good, name, _, _, _, _, _, skillLine = pcall(function() return GetProfessionInfo(index) end)
      if good and type(skillLine) == "number" then out[#out + 1] = { id = skillLine, name = name } end
    end
  end
  return out
end

local function client_name(skillLineID)
  local api = type(C_TradeSkillUI) == "table" and C_TradeSkillUI.GetProfessionInfoBySkillLineID
  if type(api) ~= "function" then return nil end
  local ok, info = pcall(api, skillLineID)
  if ok and type(info) == "table" and type(info.professionName) == "string" and info.professionName ~= "" then
    return info.professionName
  end
end

local function profession_name(skillLineID, p)
  if type(p) == "table" and type(p.name) == "string" and p.name ~= "" then return p.name end
  return client_name(skillLineID) or L["Profession %d"]:format(skillLineID)
end

local function lower_name(entry) return (entry.name or ""):lower() end

local function by_name_then_id(a, b)
  local x, y = lower_name(a), lower_name(b)
  if x ~= y then return x < y end
  return a.skillLineID < b.skillLineID
end

-- One entry per account character (the current one first, then by name):
-- { charKey, isCurrent, time, professions = { { skillLineID, name, scanned, needsOpen } } }.
--   * professions are the character's current-expansion lines (Social.Util.CurrentLines: Knowledge.variants, else
--     records with a concentration or spec snapshot; dropped records never count). scanned = the record has recipes;
--     needsOpen = it is the current character's and not scanned (only the current character can open a window).
--   * For the current character a base profession it knows (GetProfessions) without any current-expansion line is
--     listed as well, as needsOpen: the Scanner creates a record only from an open profession window, so a profession
--     the character never opened has no record at all.
--   * time = when the newest profession record of the character was scanned (nil when none was).
function Onboarding:ScanStatus()
  local scanner = module("Scanner")
  local out = {}
  if not scanner then return out end
  local current = ns.FS:CharKey()
  local keys = {}
  for _, key in ipairs(scanner:GetCharacters()) do
    if key ~= current then keys[#keys + 1] = key end
  end
  table.insert(keys, 1, current)   -- the current character is listed even before it has a record
  local variants = knowledge_variants()
  for _, key in ipairs(keys) do
    local c = scanner:GetCharacter(key)
    local entry = { charKey = key, isCurrent = key == current, professions = {} }
    local profs = type(c) == "table" and type(c.professions) == "table" and c.professions or {}
    local covered = {}
    for _, line in ipairs(Util and Util.CurrentLines(c) or {}) do
      local p = profs[line]
      local scanned = type(p.recipes) == "table" and next(p.recipes) ~= nil
      entry.professions[#entry.professions + 1] = { skillLineID = line, name = profession_name(line, p),
        scanned = scanned, needsOpen = entry.isCurrent and not scanned }
      local base = base_of(line, p, variants)
      if base then covered[base] = true end
    end
    if entry.isCurrent then
      for _, base in ipairs(known_base_professions()) do
        if not covered[base.id] then
          entry.professions[#entry.professions + 1] = { skillLineID = base.id,
            name = profession_name(base.id, { name = base.name }), scanned = false, needsOpen = true }
        end
      end
    end
    table.sort(entry.professions, by_name_then_id)
    for _, p in pairs(profs) do
      if type(p) == "table" and type(p.time) == "number" and (not entry.time or p.time > entry.time) then
        entry.time = p.time
      end
    end
    out[#out + 1] = entry
  end
  return out
end

---------------------------------------------------------------------------
-- Steps and choices
---------------------------------------------------------------------------

-- -> { { id, title } } in the order the wizard shows them.
function Onboarding:GetSteps()
  return {
    { id = "welcome", title = L["Welcome"] },
    { id = "auctionator", title = L["Auctionator"] },
    { id = "scan", title = L["Scan your professions"] },
    { id = "modules", title = L["Optional features"] },
    { id = "prices", title = L["Prices"] },
    { id = "social", title = L["Guild and chat"] },
    { id = "done", title = L["All set"] },
  }
end

local guildJustEnabled = false   -- ApplyModuleChoices turned Guild on; the next ApplySocialChoices announces

-- Turns the optional modules on or off: choices = { [name] = boolean }. Only names in OPTIONAL_MODULES count, and
-- only a module whose state would change is touched. Nothing happens while the saved data is from a newer version
-- (the choice could not be stored). -> true when the choices were applied.
function Onboarding:ApplyModuleChoices(choices)
  if read_only() or type(choices) ~= "table" then return false end
  for _, name in ipairs(self.OPTIONAL_MODULES) do
    local want = choices[name]
    if type(want) == "boolean" and ns.FS:IsModuleEnabled(name) ~= want then
      ns.FS:SetModuleEnabled(name, want)
      if name == "Guild" then guildJustEnabled = want end
    end
  end
  return true
end

local VALID_LEVEL = { quality = true, recipes = true }
local VALID_ALTS = { current = true, guild = true, all = true }   -- GuildOptions' shareAlts values

-- choices = { share = boolean, shareLevel = "quality"|"recipes", shareAlts = "current"|"guild"|"all",
-- chatScan = boolean } (any of them may be missing). Writes Guild's privacy settings through Guild:Settings(),
-- switches the ChatScan module, then calls Guild:OnPrivacyChanged() when Guild is on and a sharing setting actually
-- changed, or Guild was just turned on by ApplyModuleChoices. Nothing happens while the saved data is from a newer
-- version. -> true when the choices were applied.
function Onboarding:ApplySocialChoices(choices)
  if read_only() or type(choices) ~= "table" then return false end
  local guild = module("Guild")
  local changed = false
  if guild and type(guild.Settings) == "function" then
    local settings = guild:Settings()
    local function set(key, value)
      if settings[key] ~= value then settings[key] = value; changed = true end
    end
    if type(choices.share) == "boolean" then set("share", choices.share) end
    if VALID_LEVEL[choices.shareLevel] then set("shareLevel", choices.shareLevel) end
    if VALID_ALTS[choices.shareAlts] then set("shareAlts", choices.shareAlts) end
  end
  if type(choices.chatScan) == "boolean" and ns.FS:IsModuleEnabled("ChatScan") ~= choices.chatScan then
    ns.FS:SetModuleEnabled("ChatScan", choices.chatScan)
  end
  local announce = changed or guildJustEnabled
  guildJustEnabled = false
  if announce and guild and guild:IsEnabled() and type(guild.OnPrivacyChanged) == "function" then
    guild:OnPrivacyChanged()
  end
  return true
end

-- Opens the price options: the group is selected first (the Settings tab opens the dialog when it is shown or
-- refreshed), then the main window shows the Settings tab.
function Onboarding:OpenPriceSettings()
  local dialog = LibStub("AceConfigDialog-3.0", true)
  if dialog then dialog:SelectGroup(self.APP_NAME, self.PRICE_GROUP) end
  local window = module("MainWindow")
  if window then window:Show("settings") end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

-- A tiny always-on listener (not the module, so the module's own registrations stay empty while it is off): a module
-- turned on after the first loading screen does not open the guide at the next loading screen.
do
  local watcher = {}
  LibStub("AceEvent-3.0"):Embed(watcher)
  watcher:RegisterEvent("PLAYER_ENTERING_WORLD", function()
    worldEntered = true
    watcher:UnregisterEvent("PLAYER_ENTERING_WORLD")
  end)
end

-- Only the first loading screen of the session schedules the guide; later ones (zoning, instances) do nothing.
function Onboarding:OnEnteringWorld()
  if sessionHandled then return end
  sessionHandled = true
  offerPending = true
  self:UnregisterEvent("PLAYER_ENTERING_WORLD")
  ns.FS:Debounce(SHOW_KEY, self.SHOW_DELAY, ns.FS:Wrap(SOURCE, function() self:MaybeShow() end))
end

function Onboarding:OnEnable()
  if not sessionHandled and not worldEntered then
    self:RegisterEvent("PLAYER_ENTERING_WORLD", ns.FS:Wrap(SOURCE, function() self:OnEnteringWorld() end))
  end
end

function Onboarding:OnDisable()
  ns.FS:CancelDebounce(SHOW_KEY)
  self:UnregisterAllEvents()
  local w = wizard()
  if w then w:Close(true) end   -- hidden without recording a skip: the user did not close it
  local held = offerPending
  offerPending = false          -- the guide is no longer scheduled this session, so it holds nothing
  guildJustEnabled = false
  if held then ns.FS:SendMessage(ns.Msg.ONBOARDING_DONE) end
end

ns.FS:RegisterSlash("setup", function()
  local w = wizard()
  if w then w:Open() end
end, L["reopen the setup guide"])
