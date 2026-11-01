local _, ns = ...

-- OnboardingWizard: the window of the first-run setup guide (the logic and the "when to show" rule are in
-- Modules/Onboarding.lua). One own frame (BasicFrameTemplateWithInset, in UISpecialFrames so Escape closes it) with
-- seven steps: welcome, Auctionator, scan, optional modules, prices, guild and chat, done. Back / Next / Skip sit
-- along the bottom. Own frames and Blizzard templates only: no AceGUI, no dropdowns (checkboxes and a cycle button).
--
-- A choice is recorded only by Skip (Close()), the template's close button (X) and Finish. Closing the window on the
-- last step with the X records a finished guide (every choice was already applied); anywhere else the X and Skip record
-- a skip. Every other hide records nothing and leaves the guide pending: Escape (UISpecialFrames calls Hide()), any
-- other direct Hide(), and the hide that comes with the parent (Alt+Z, a cinematic; OnHide then fires while the frame's
-- own shown flag is still set, and the guide stays open). A guide that was hidden that way is still due, so it opens
-- again at the next login, and guild sync stays held until a real choice. Recording is also limited to a guide that is
-- still due (reopening a finished guide with /fs setup and closing it changes nothing). Onboarding:OnDisable closes it
-- with Close(true), which records nothing.
--
-- The choices are kept in a table that starts from the live state each time the guide opens. The module choices are
-- applied when the user leaves the modules step with Next, the social choices when they leave the social step; a Skip
-- applies nothing. The Auctionator and scan steps read their status each time they are shown, and a "Check again"
-- button reads it again.
--
-- Layout: headings, checkbox labels and the scan rows are one line in a fixed width; every explanation wraps. A step
-- builder lists its regions in order in c.layout = { { region, kind = "wrap"|"line"|"button"|"check"|"scroll", gap, x } }
-- instead of fixed y offsets, and layout_step() (run by ShowStep after the refresher) stacks the shown ones from the
-- top: a wrapped box is as tall as its measured text (never under its English height, which is also the fallback when
-- the client measures 0), a button is as wide as its text needs (never under its English width), and the window grows
-- (up to the screen) when the longest step needs it, so a longer translation does not clip. With the English text
-- every step keeps the usual 440 px. The scan list is a plain ScrollFrame of pooled one-line rows that takes the rest
-- of the content area.
local Wizard = {}
ns.UI = ns.UI or {}
ns.UI.OnboardingWizard = Wizard

local L = setmetatable({}, { __index = function(_, key) return ns.L[key] end })

local FRAME_NAME = "FabricationStationSetupWizard"
local SOURCE = "OnboardingWizard"
local TOOLTIP_SOURCE = "OnboardingWizard:Tooltip"

Wizard.WIDTH, Wizard.HEIGHT = 500, 440
local PAD = 16
local CONTENT_WIDTH = Wizard.WIDTH - 2 * PAD          -- 468
local BUTTON_HEIGHT = 22
local ROW_HEIGHT = 16
local BUTTON_PAD = 24         -- a button's width is its text width plus this
local SCROLL_MIN = 100        -- the least height the scan list needs; it takes whatever the window has beyond that
local SCROLL_FOOT = 32        -- below the scan list: the "Check again" button
local NAV_MAX_WIDTH = 120        -- Back, Next and Skip stay clear of the step counter between them
local FRAME_CHROME = 76       -- the window's height beyond its content: 36 above it, 40 below
local GOLD, GREEN, ORANGE, GRAY = "|cffffd100", "|cff40ff40", "|cffffa000", "|cff909090"

-- The modules the "modules" step lists, in display order, with their label and description. Guild's sharing details
-- and ChatScan are on the social step.
local function module_rows()
  return {
    { name = "Orders", label = L["Orders"], text = L["Public and personal crafting orders: see which ones are worth taking."] },
    { name = "Customers", label = L["Customers"], text = L["Remember the people you craft for, with notes and a block list."] },
    { name = "Ledger", label = L["Ledger"], text = L["Track what your orders and crafts earn."] },
    { name = "Alts", label = L["Alts"], text = L["Watch all your crafters: concentration, cooldowns and moxie."] },
    { name = "Planner", label = L["Planner"], text = L["Plan which crafter makes what, and when concentration is full."] },
    { name = "Guild", label = L["Guild crafter directory"], text = L["See which guildmates can craft what. Sharing is set on the Guild and chat step."] },
  }
end

local view            -- the built frame and controls, created on first use
local choices         -- the pending choices of the open guide
local current = 1
local active = false  -- the guide is open and has not been finished or skipped
local closeRequested = false   -- Skip or the close button asked to close it: the hide that follows records a choice

local function onboarding() return ns.FS:GetModule("Onboarding", true) end

local function steps()
  local module = onboarding()
  return module and module:GetSteps() or {}
end

---------------------------------------------------------------------------
-- Pure helpers
---------------------------------------------------------------------------

-- "missing" (not installed), "disabled" (installed, not loaded), "noapi" (loaded without a usable price API) or "ok",
-- from Onboarding:CheckAuctionator().
function Wizard.AuctionatorState(status)
  if type(status) ~= "table" or not status.installed then return "missing" end
  if not status.loaded then return "disabled" end
  if not status.apiOK then return "noapi" end
  return "ok"
end

-- Display rows for a ScanStatus() list: { { text, kind = "header"|"ok"|"open"|"wait"|"empty", indent } }.
-- Every row says its state in words; the colour only backs it up.
function Wizard.ScanRows(status)
  local rows = {}
  local formatAge = ns.UI and ns.UI.FormatAge
  for _, entry in ipairs(type(status) == "table" and status or {}) do
    local header = entry.charKey
    if entry.isCurrent then header = L["%s (this character)"]:format(header) end
    if entry.time and formatAge then
      header = L["%s - last scan %s ago"]:format(header, formatAge(math.max(0, ns.FS:Now() - entry.time)))
    end
    rows[#rows + 1] = { text = header, kind = "header" }
    for _, p in ipairs(entry.professions) do
      local kind, state
      if p.scanned then
        kind, state = "ok", L["scanned"]
      elseif p.needsOpen then
        kind, state = "open", L["open this profession window now"]
      else
        kind, state = "wait", L["log in to this character and open it"]
      end
      rows[#rows + 1] = { text = p.name .. " - " .. state, kind = kind, indent = true }
    end
    if #entry.professions == 0 then
      rows[#rows + 1] = { text = L["no profession found yet"], kind = "empty", indent = true }
    end
  end
  return rows
end

local ROW_COLOR = { header = GOLD, ok = GREEN, open = ORANGE, wait = GRAY, empty = GRAY }

---------------------------------------------------------------------------
-- Choices
---------------------------------------------------------------------------

local function guild_settings()
  local guild = ns.FS:GetModule("Guild", true)
  if guild and type(guild.Settings) == "function" then return guild:Settings() end
  return {}
end

-- The state the live addon is in right now: what the checkboxes start from.
local function initial_choices()
  local module = onboarding()
  local settings = guild_settings()
  local out = { modules = {}, share = settings.share ~= false, shareLevel = settings.shareLevel,
    shareAlts = settings.shareAlts, chatScan = ns.FS:IsModuleEnabled("ChatScan") }
  if out.shareLevel ~= "quality" and out.shareLevel ~= "recipes" then out.shareLevel = "quality" end
  if out.shareAlts ~= "current" and out.shareAlts ~= "guild" and out.shareAlts ~= "all" then out.shareAlts = "guild" end
  for _, name in ipairs(module and module.OPTIONAL_MODULES or {}) do
    out.modules[name] = ns.FS:IsModuleEnabled(name)
  end
  return out
end

function Wizard:GetChoices() return choices end

local function guild_chosen()
  return choices ~= nil and choices.modules.Guild ~= false
end

---------------------------------------------------------------------------
-- Widgets
---------------------------------------------------------------------------

local function wrapped(fn) return ns.FS:Wrap(SOURCE, fn) end

-- A text line at (x, y) below the top left of parent (where layout_step() moves it). wrap = a box that wraps; its
-- height is the minimum and layout_step() makes it taller when the text needs it. Otherwise one line, cut at width.
local function label(parent, template, x, y, width, height, wrap)
  local fs = parent:CreateFontString(nil, "OVERLAY", template)
  fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
  fs:SetWidth(width)
  fs:SetHeight(height)
  fs:SetJustifyH("LEFT")
  fs:SetJustifyV("TOP")
  fs:SetWordWrap(wrap and true or false)
  if not wrap then fs:SetMaxLines(1) end
  return fs
end

local function attach_tooltip(frame, title, body)
  frame:SetScript("OnEnter", ns.FS:Wrap(TOOLTIP_SOURCE, function(self)
    if not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(title, 1, 1, 1)
    if body then GameTooltip:AddLine(body, 0.8, 0.8, 0.8, true) end
    GameTooltip:Show()
  end))
  frame:SetScript("OnLeave", ns.FS:Wrap(TOOLTIP_SOURCE, function()
    if GameTooltip then GameTooltip:Hide() end
  end))
end

-- A button's text, and its width fitted to it: today's width is the minimum, maxWidth the limit.
local function set_button_text(b, text)
  b:SetText(text)
  local textWidth = tonumber(b.GetTextWidth and b:GetTextWidth()) or 0
  b:SetWidth(math.min(b.maxWidth, math.max(b.minWidth, textWidth + BUTTON_PAD)))
end

local function button(parent, text, minWidth, onClick, maxWidth)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b.minWidth, b.maxWidth = minWidth, math.max(minWidth, maxWidth or CONTENT_WIDTH)
  b:SetSize(minWidth, BUTTON_HEIGHT)
  set_button_text(b, text)
  b:SetScript("OnClick", wrapped(onClick))
  return b
end

-- A checkbox with its label to the right; the whole label is clickable. toggle() flips the pending choice and returns
-- the new value (the box shows our value, not the client's own toggle, so the two never disagree).
local function check(parent, x, y, text, width, toggle)
  local b = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  b:SetSize(24, 24)
  b:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
  b:SetHitRectInsets(0, -width, 0, 0)
  b.text = label(parent, "GameFontNormal", x + 28, y + 5, width, 14, false)
  b.text:SetText(text)
  b:SetScript("OnClick", wrapped(function(self) self:SetChecked(toggle() and true or false) end))
  return b
end

---------------------------------------------------------------------------
-- Layout: stacks a step's shown regions from the top, each as tall as its text needs
---------------------------------------------------------------------------

-- The measured height of a wrapped font string, 0 when the client cannot measure it (a hidden frame may answer 0 or nil).
local function measured_height(fs)
  local height = fs.GetStringHeight and fs:GetStringHeight()
  return type(height) == "number" and height or 0
end

-- Anchors every shown region of c.layout TOPLEFT at (x, -y) of the step's frame, from y = 0 down, and returns the bottom
-- y. kinds: "wrap" (height = the measured text, at least item.min), "line" (item.height), "button" (item.height),
-- "check" (item.height; its label follows it), "scroll" (the scan list: stretched to the bottom edge, item.min counted).
local function layout_step(c)
  local y = 0
  for _, item in ipairs(c.layout or {}) do
    local region, kind = item.region, item.kind
    if region:IsShown() then
      local x = item.x or 0
      local height = item.height or 0
      region:ClearAllPoints()
      region:SetPoint("TOPLEFT", c.frame, "TOPLEFT", x, -y)
      if kind == "wrap" then
        height = math.max(item.min or 0, math.ceil(measured_height(region)))
        region:SetHeight(height)
      elseif kind == "check" then
        region.text:ClearAllPoints()
        region.text:SetPoint("TOPLEFT", c.frame, "TOPLEFT", x + 28, -(y + 5))
      elseif kind == "scroll" then
        region:SetPoint("BOTTOMRIGHT", c.frame, "BOTTOMRIGHT", 0, SCROLL_FOOT)
        height = (item.min or 0) + SCROLL_FOOT
      end
      y = y + height + (item.gap or 0)
    end
  end
  return y
end

---------------------------------------------------------------------------
-- Steps: each builder makes the step's frame and returns its controls; each refresher fills them from the live state
---------------------------------------------------------------------------

local builders, refreshers = {}, {}

local function heading(frame) return label(frame, "GameFontNormalLarge", 0, 0, CONTENT_WIDTH, 22, false) end

function builders.welcome(frame)
  local c = { heading = heading(frame) }
  c.body = label(frame, "GameFontHighlight", 0, 32, CONTENT_WIDTH, 70, true)
  c.body:SetText(L["FabricationStation helps you pick profitable crafts, spend concentration well and keep track of all your crafters. This short guide sets up the essentials. Everything in it can be changed later in /fs settings."])
  c.more = label(frame, "GameFontHighlight", 0, 112, CONTENT_WIDTH, 50, true)
  c.more:SetText(L["Skip or the close button ends this guide; /fs setup opens it again. If the window is hidden any other way, it comes back at your next login."])
  c.readOnly = label(frame, "GameFontHighlight", 0, 172, CONTENT_WIDTH, 50, true)
  local readOnlyText = L["The saved data is from a newer version of FabricationStation, so the choices you make in this guide will not be saved."]
  c.readOnly:SetText(ORANGE .. readOnlyText .. "|r")
  c.layout = {
    { region = c.heading, kind = "line", height = 22, gap = 10 },
    { region = c.body, kind = "wrap", min = 70, gap = 10 },
    { region = c.more, kind = "wrap", min = 50, gap = 10 },
    { region = c.readOnly, kind = "wrap", min = 50 },
  }
  return c
end

function refreshers.welcome(c)
  if ns.FS.dbIsNewer then c.readOnly:Show() else c.readOnly:Hide() end
end

local function auctionator_text(state)
  if state == "missing" then
    return L["Auctionator is not installed"],
      L["FabricationStation reads item prices from Auctionator. Without it only the prices you type in yourself are used, so profit stays empty for most items. Install Auctionator from CurseForge or Wago, then type /reload."]
  elseif state == "disabled" then
    return L["Auctionator is installed but turned off"],
      L["Turn Auctionator on in the AddOns list on the character select screen, then log in again. Until then only the prices you type in yourself are used."]
  elseif state == "noapi" then
    return L["Auctionator is running, but its price API is not available"],
      L["Auctionator is loaded but did not offer its price API. Update Auctionator to the latest version, then type /reload."]
  end
  return L["Auctionator is connected"],
    L["Prices come from your latest Auctionator scan. Scan the auction house once so profit can be calculated."]
end
local AUCTIONATOR_TONE = { missing = ORANGE, disabled = ORANGE, noapi = ORANGE, ok = GREEN }

function builders.auctionator(frame)
  local c = { heading = heading(frame) }
  c.status = label(frame, "GameFontNormal", 0, 32, CONTENT_WIDTH, 16, true)
  c.body = label(frame, "GameFontHighlight", 0, 58, CONTENT_WIDTH, 90, true)
  c.again = button(frame, L["Check again"], 110, function() Wizard:ShowStep(current) end)
  c.again:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -160)
  c.layout = {
    { region = c.heading, kind = "line", height = 22, gap = 10 },
    { region = c.status, kind = "wrap", min = 16, gap = 10 },
    { region = c.body, kind = "wrap", min = 90, gap = 12 },
    { region = c.again, kind = "button", height = BUTTON_HEIGHT },
  }
  return c
end

function refreshers.auctionator(c)
  local module = onboarding()
  local state = Wizard.AuctionatorState(module and module:CheckAuctionator())
  local status, body = auctionator_text(state)
  c.state = state
  c.status:SetText(AUCTIONATOR_TONE[state] .. status .. "|r")
  c.body:SetText(body)
end

function builders.scan(frame)
  local c = { heading = heading(frame), rows = {}, rowCount = 0 }
  c.body = label(frame, "GameFontHighlight", 0, 28, CONTENT_WIDTH, 46, true)
  c.body:SetText(L["Log in to each crafter and open each profession window once. FabricationStation reads recipes, skill and specialization from that window."])
  c.scroll = CreateFrame("ScrollFrame", nil, frame)
  c.scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -80)
  c.scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 32)
  c.child = CreateFrame("Frame", nil, c.scroll)
  c.child:SetSize(CONTENT_WIDTH, ROW_HEIGHT)
  c.scroll:SetScrollChild(c.child)
  c.scroll:EnableMouseWheel(true)
  c.scroll:SetScript("OnMouseWheel", wrapped(function(scroll, delta)
    local range = scroll:GetVerticalScrollRange() or 0
    local position = scroll:GetVerticalScroll() or 0
    scroll:SetVerticalScroll(math.max(0, math.min(range, position - delta * ROW_HEIGHT * 3)))
  end))
  c.again = button(frame, L["Check again"], 110, function() Wizard:ShowStep(current) end)
  c.again:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
  c.layout = {
    { region = c.heading, kind = "line", height = 22, gap = 6 },
    { region = c.body, kind = "wrap", min = 46, gap = 6 },
    { region = c.scroll, kind = "scroll", min = SCROLL_MIN },
  }
  return c
end

function refreshers.scan(c)
  local module = onboarding()
  local rows = Wizard.ScanRows(module and module:ScanStatus() or {})
  for i, row in ipairs(rows) do
    local fs = c.rows[i]
    if not fs then
      fs = c.child:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      fs:SetJustifyH("LEFT")
      fs:SetWordWrap(false)
      fs:SetMaxLines(1)
      c.rows[i] = fs
    end
    local indent = row.indent and 14 or 0
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", c.child, "TOPLEFT", indent, -(i - 1) * ROW_HEIGHT)
    fs:SetWidth(CONTENT_WIDTH - indent)
    fs:SetHeight(ROW_HEIGHT)
    fs:SetText(ROW_COLOR[row.kind] .. row.text .. "|r")
    fs:Show()
  end
  for i = #rows + 1, #c.rows do c.rows[i]:Hide() end
  c.rowCount = #rows
  c.child:SetHeight(math.max(ROW_HEIGHT, #rows * ROW_HEIGHT))
  c.scroll:SetVerticalScroll(0)
end

function builders.modules(frame)
  local c = { heading = heading(frame), checks = {} }
  c.body = label(frame, "GameFontHighlight", 0, 28, CONTENT_WIDTH, 32, true)
  c.body:SetText(L["Turn off what you will not use. Each one can be switched back on in /fs settings."])
  c.layout = {
    { region = c.heading, kind = "line", height = 22, gap = 6 },
    { region = c.body, kind = "wrap", min = 32, gap = 4 },
  }
  for _, row in ipairs(module_rows()) do
    local b = check(frame, 0, 0, row.label, CONTENT_WIDTH - 32, function()
      choices.modules[row.name] = not choices.modules[row.name]
      return choices.modules[row.name]
    end)
    local description = label(frame, "GameFontHighlightSmall", 28, 22, CONTENT_WIDTH - 32, 24, true)
    description:SetText(row.text)
    c.checks[row.name] = b
    -- The description starts 2 px inside the 24 px box, as it always did.
    c.layout[#c.layout + 1] = { region = b, kind = "check", height = 24, gap = -2 }
    c.layout[#c.layout + 1] = { region = description, kind = "wrap", min = 24, x = 28 }
  end
  return c
end

function refreshers.modules(c)
  for name, b in pairs(c.checks) do b:SetChecked(choices.modules[name] and true or false) end
end

function builders.prices(frame)
  local c = { heading = heading(frame) }
  c.body = label(frame, "GameFontHighlight", 0, 32, CONTENT_WIDTH, 70, true)
  c.body:SetText(L["Profit needs prices. Open the price settings to check where prices come from and how old a price may get before it counts as stale."])
  c.openButton = button(frame, L["Open price settings"], 170, function()
    local module = onboarding()
    if module then module:OpenPriceSettings() end
  end)
  c.openButton:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -112)
  c.note = label(frame, "GameFontHighlightSmall", 0, 144, CONTENT_WIDTH, 40, true)
  c.note:SetText(L["The settings open in the main window. This guide stays open; move it aside if it is in the way."])
  c.layout = {
    { region = c.heading, kind = "line", height = 22, gap = 10 },
    { region = c.body, kind = "wrap", min = 70, gap = 10 },
    { region = c.openButton, kind = "button", height = BUTTON_HEIGHT, gap = 10 },
    { region = c.note, kind = "wrap", min = 40 },
  }
  return c
end

-- The cycle buttons show only their value; the question is a small heading above each.
local function level_button_text()
  return choices and choices.shareLevel == "recipes" and L["Recipes only"] or L["Recipes and expected quality"]
end

-- GuildOptions' shareAlts values, in its order, with its labels.
local ALTS_ORDER = { "current", "guild", "all" }
local function alts_label(value)
  if value == "current" then return L["Only the character I am playing"] end
  if value == "all" then return L["All my characters"] end
  return L["My characters in this guild"]
end

local function alts_button_text()
  return alts_label(choices and choices.shareAlts)
end

local function next_alts(value)
  for i, v in ipairs(ALTS_ORDER) do
    if v == value then return ALTS_ORDER[i % #ALTS_ORDER + 1] end
  end
  return ALTS_ORDER[1]
end

function builders.social(frame)
  local c = { heading = heading(frame) }
  c.body = label(frame, "GameFontHighlight", 0, 28, CONTENT_WIDTH, 48, true)
  c.body:SetText(L["Guild sharing lets guildmates who run FabricationStation see which recipes your characters can craft. Only recipes, skill levels and expected quality are shared, never gold, items or prices."])
  c.shareCheck = check(frame, 0, 0, L["Share my recipes with my guild"], CONTENT_WIDTH - 32, function()
    choices.share = not choices.share
    return choices.share
  end)
  c.levelLabel = label(frame, "GameFontNormalSmall", 28, 0, CONTENT_WIDTH - 28, 14, true)
  c.levelLabel:SetText(L["What to share"])
  c.levelButton = button(frame, "", 300, function(self)
    choices.shareLevel = choices.shareLevel == "quality" and "recipes" or "quality"
    set_button_text(self, level_button_text())
  end, CONTENT_WIDTH - 28)
  c.levelButton:SetPoint("TOPLEFT", frame, "TOPLEFT", 28, 0)
  attach_tooltip(c.levelButton, L["What to share"],
    L["Expected quality is what your character would craft with and without concentration."])
  c.altsLabel = label(frame, "GameFontNormalSmall", 28, 0, CONTENT_WIDTH - 28, 14, true)
  c.altsLabel:SetText(L["Which characters to share"])
  c.altsButton = button(frame, "", 430, function(self)
    choices.shareAlts = next_alts(choices.shareAlts)
    set_button_text(self, alts_button_text())
  end, CONTENT_WIDTH - 28)
  c.altsButton:SetPoint("TOPLEFT", frame, "TOPLEFT", 28, 0)
  attach_tooltip(c.altsButton, L["Which characters to share"],
    L["Sharing several characters lets guildmates see that they belong to the same player."])
  c.guildOff = label(frame, "GameFontDisableSmall", 28, 0, CONTENT_WIDTH - 28, 14, true)
  c.guildOff:SetText(L["Guild sharing is off because the Guild feature is turned off on the previous step."])
  c.chatBody = label(frame, "GameFontHighlight", 0, 194, CONTENT_WIDTH, 62, true)
  c.chatBody:SetText(L["Chat scanning watches Trade, Services and guild chat for someone asking for something you can craft, and shows a small toast. It never sends a message for you: you click Whisper yourself."])
  c.chatScanCheck = check(frame, 0, 0, L["Scan chat for crafting requests"], CONTENT_WIDTH - 32, function()
    choices.chatScan = not choices.chatScan
    return choices.chatScan
  end)
  c.layout = {
    { region = c.heading, kind = "line", height = 22, gap = 6 },
    { region = c.body, kind = "wrap", min = 48, gap = 8 },
    { region = c.shareCheck, kind = "check", height = 24, gap = 6 },
    { region = c.levelLabel, kind = "wrap", min = 14, x = 28, gap = 2 },
    { region = c.levelButton, kind = "button", height = BUTTON_HEIGHT, x = 28, gap = 4 },
    { region = c.altsLabel, kind = "wrap", min = 14, x = 28, gap = 2 },
    { region = c.altsButton, kind = "button", height = BUTTON_HEIGHT, x = 28, gap = 6 },
    { region = c.guildOff, kind = "wrap", min = 14, x = 28, gap = 12 },
    { region = c.chatBody, kind = "wrap", min = 62, gap = 6 },
    { region = c.chatScanCheck, kind = "check", height = 24 },
  }
  return c
end

function refreshers.social(c)
  local on = guild_chosen()
  c.shareCheck:SetChecked(choices.share and true or false)
  set_button_text(c.levelButton, level_button_text())
  set_button_text(c.altsButton, alts_button_text())
  c.chatScanCheck:SetChecked(choices.chatScan and true or false)
  if on then
    c.shareCheck:Enable(); c.levelButton:Enable(); c.altsButton:Enable(); c.guildOff:Hide()
  else
    c.shareCheck:Disable(); c.levelButton:Disable(); c.altsButton:Disable(); c.guildOff:Show()
  end
end

function builders.done(frame)
  local c = { heading = heading(frame) }
  c.body = label(frame, "GameFontHighlight", 0, 32, CONTENT_WIDTH, 50, true)
  c.body:SetText(L["Type /fs to open FabricationStation. /fs setup reopens this guide."])
  c.note = label(frame, "GameFontHighlight", 0, 90, CONTENT_WIDTH, 50, true)
  c.note:SetText(L["The saved data is from a newer version of FabricationStation, so your choices were not saved."])
  c.layout = {
    { region = c.heading, kind = "line", height = 22, gap = 10 },
    { region = c.body, kind = "wrap", min = 50, gap = 8 },
    { region = c.note, kind = "wrap", min = 50 },
  }
  return c
end

function refreshers.done(c)
  if ns.FS.dbIsNewer then c.note:Show() else c.note:Hide() end
end

---------------------------------------------------------------------------
-- The frame
---------------------------------------------------------------------------

local function set_title(frame, text)
  if frame.SetTitle then
    frame:SetTitle(text)
  elseif frame.TitleText then
    frame.TitleText:SetText(text)
  elseif frame.TitleContainer and frame.TitleContainer.TitleText then
    frame.TitleContainer.TitleText:SetText(text)
  end
end

local on_hidden   -- forward

local function ensure_view()
  if view then return view end
  local frame = CreateFrame("Frame", FRAME_NAME, UIParent, "BasicFrameTemplateWithInset")
  frame:SetSize(Wizard.WIDTH, Wizard.HEIGHT)
  frame:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
  frame:SetFrameStrata("DIALOG")
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  set_title(frame, L["FabricationStation setup"])
  frame:Hide()

  local content = CreateFrame("Frame", nil, frame)
  content:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -36)
  content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, 40)

  local v = { frame = frame, content = content, steps = {} }
  v.skip = button(frame, L["Skip"], 80, function() Wizard:Close() end, NAV_MAX_WIDTH)
  v.skip:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD - 2, 10)
  v.next = button(frame, L["Next"], 90, function() Wizard:Next() end, NAV_MAX_WIDTH)
  v.next:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -(PAD - 2), 10)
  v.back = button(frame, L["Back"], 80, function() Wizard:Back() end, NAV_MAX_WIDTH)
  v.back:SetPoint("RIGHT", v.next, "LEFT", -6, 0)
  v.stepLabel = label(frame, "GameFontDisableSmall", 0, 0, 160, 14, false)
  v.stepLabel:ClearAllPoints()
  v.stepLabel:SetPoint("BOTTOM", frame, "BOTTOM", 0, 15)
  v.stepLabel:SetJustifyH("CENTER")
  v.stepFrames = {}

  for _, step in ipairs(steps()) do
    local stepFrame = CreateFrame("Frame", nil, content)
    stepFrame:SetAllPoints(content)
    stepFrame:Hide()
    local c = builders[step.id](stepFrame)
    c.frame = stepFrame
    v.steps[step.id] = c
    v.stepFrames[step.id] = stepFrame
  end
  v.moduleChecks = v.steps.modules and v.steps.modules.checks or {}
  v.shareCheck = v.steps.social and v.steps.social.shareCheck
  v.levelButton = v.steps.social and v.steps.social.levelButton
  v.altsButton = v.steps.social and v.steps.social.altsButton
  v.chatScanCheck = v.steps.social and v.steps.social.chatScanCheck

  frame:HookScript("OnDragStart", function(self) self:StartMoving() end)
  frame:HookScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
  frame:HookScript("OnHide", wrapped(function() on_hidden() end))
  if type(frame.CloseButton) == "table" and frame.CloseButton.HookScript then
    -- PreClick runs before the template's own OnClick hides the frame, so the hide that follows is a close request.
    frame.CloseButton:HookScript("PreClick", wrapped(function() if active then closeRequested = true end end))
    -- PostClick runs after the hide: a request whose hide never came (a failed OnClick) must not outlive the click.
    frame.CloseButton:HookScript("PostClick", wrapped(function() closeRequested = false end))
  end

  local registered = false
  for _, name in ipairs(UISpecialFrames) do
    if name == FRAME_NAME then registered = true; break end
  end
  if not registered then table.insert(UISpecialFrames, FRAME_NAME) end

  view = v
  return v
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

-- The built frame and its controls (tests and tooling): { frame, back, next, skip, stepLabel, steps = { [id] = {...} },
-- moduleChecks, shareCheck, levelButton, altsButton, chatScanCheck }.
function Wizard:GetControls() return ensure_view() end

function Wizard:IsShown() return view ~= nil and view.frame:IsShown() and true or false end

function Wizard:GetStep() return current end

-- Shows step `index` (clamped to the steps that exist) and reads its status again.
function Wizard:ShowStep(index)
  local v = ensure_view()
  local list = steps()
  if #list == 0 then return end
  index = math.max(1, math.min(#list, math.floor(tonumber(index) or 1)))
  choices = choices or initial_choices()
  current = index
  local step = list[index]
  for id, stepFrame in pairs(v.stepFrames) do
    if id == step.id then stepFrame:Show() else stepFrame:Hide() end
  end
  local c = v.steps[step.id]
  if c.heading then c.heading:SetText(GOLD .. step.title .. "|r") end
  if refreshers[step.id] then refreshers[step.id](c) end
  local bottom = layout_step(c)
  local screen = UIParent and UIParent.GetHeight and UIParent:GetHeight()
  if type(screen) ~= "number" or screen <= 0 then screen = 768 end
  v.frame:SetHeight(math.min(screen - 40, math.max(Wizard.HEIGHT, bottom + FRAME_CHROME)))
  v.stepLabel:SetText(L["Step %d of %d"]:format(index, #list))
  if index > 1 then v.back:Show() else v.back:Hide() end
  if index == #list then
    set_button_text(v.next, L["Finish"])
    v.skip:Hide()
  else
    set_button_text(v.next, L["Next"])
    v.skip:Show()
  end
end

function Wizard:Back()
  if current > 1 then self:ShowStep(current - 1) end
end

-- Leaves the current step forward: the modules and social steps apply their choices first; the last step finishes.
function Wizard:Next()
  local list = steps()
  local step = list[current]
  local module = onboarding()
  if not (step and module and choices) then return end
  if step.id == "modules" then
    module:ApplyModuleChoices(choices.modules)
  elseif step.id == "social" then
    local social = { chatScan = choices.chatScan }
    if guild_chosen() then
      social.share, social.shareLevel, social.shareAlts = choices.share, choices.shareLevel, choices.shareAlts
    end
    module:ApplySocialChoices(social)
  end
  if current >= #list then
    self:Finish()
  else
    self:ShowStep(current + 1)
  end
end

-- Records a completed guide and closes the window.
function Wizard:Finish()
  local module = onboarding()
  active = false
  if module then module:Complete(false) end
  if view then view.frame:Hide() end
end

-- The window was hidden. Only a hide that Skip or the close button asked for records a choice (see the header): a
-- guide that is still due counts as skipped, except on the last step, where every choice was applied already and
-- closing it means the same as Finish. Escape and a hide with the parent leave the guide pending.
function on_hidden()
  if not active then return end
  if view and view.frame:IsShown() then return end   -- hidden with its parent (Alt+Z, a cinematic): still open
  active = false
  local requested = closeRequested
  closeRequested = false
  if not requested then return end
  local module = onboarding()
  local onLast = current >= #steps()
  if module and module:ShouldShow() then module:Complete(not onLast) end
end

-- Opens the guide at the first step with the choices read from the live state. Already open: just raised.
function Wizard:Open()
  local v = ensure_view()
  if v.frame:IsShown() and active then
    v.frame:Raise()
    return
  end
  choices = initial_choices()
  active = true
  closeRequested = false
  v.frame:Show()
  self:ShowStep(1)
end

-- Hides the window; that counts as Skip while the guide is due. silent = true hides it without recording anything.
function Wizard:Close(silent)
  if silent then
    active = false
  elseif active then
    closeRequested = true
  end
  if view then
    view.frame:Hide()
    on_hidden()   -- OnHide runs it in the client; this covers a frame whose hide script did not fire
  end
end
