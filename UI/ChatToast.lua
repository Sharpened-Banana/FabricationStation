local _, ns = ...

-- ChatToast: one small toast per ChatScan match ("Buyer-Realm . Trade / Everforged Gloves / You: Q3 on Alt-Realm .
-- 12g"), with Whisper, Ignore and Dismiss buttons. At most MAX_TOASTS are shown at once, stacked at the top centre; a
-- fourth replaces the oldest. Each hides itself after settings.chatScan.toastSeconds and plays the whisper sound when
-- settings.chatScan.sound is on.
--
-- The core registrar module "ChatToasts" listens for FS_CHATSCAN_MATCH in OnEnable, ignores matches while ChatScan is
-- off and, in OnDisable, hides every toast and cancels every hide timer. The toast frames are our own (parented to
-- UIParent), pooled and reused; nothing of Blizzard's is touched (design rule 7).
--
-- The only whisper path in the addon's chat scanning is the Whisper button's OnClick: it calls
-- ChatFrameUtil.SendTellWithMessage (SendTell when that is missing), which opens the chat edit box with the text and
-- sends nothing. The player reads it, edits it and presses Enter (in-game check P4-21: that this sends untainted,
-- also in instances). Showing a toast never writes to chat.
--
-- Layout: every line is one line (no word wrap) in a fixed width, so a long sender or recipe name is cut with "..."
-- inside the toast; the full text is in the toast's tooltip. Sender and recipe names come from other players or the
-- game's data and always go through Social.Util.EscapePipes.
local ChatToasts = ns.FS:NewModule("ChatToasts", "AceEvent-3.0")
ChatToasts.coreModule = true

local Toast = {}
ns.UI = ns.UI or {}
ns.UI.ChatToast = Toast

local L = setmetatable({}, { __index = function(_, key) return ns.L[key] end })

local MODULE = "ChatToasts"
local CLICK_SOURCE, TOOLTIP_SOURCE = "ChatToast:Click", "ChatToast:Tooltip"
local TIMER_PREFIX = "chatToast.hide."
local DEFAULT_TOAST_SECONDS = 30
local DOT = " \194\183 "
local TITLE_COLOR = "|cffffd100"

Toast.MAX_TOASTS = 3
Toast.WIDTH, Toast.HEIGHT, Toast.GAP, Toast.TOP = 340, 88, 6, 90

local PAD, BUTTON_HEIGHT, BUTTON_GAP = 8, 22, 6
local BACKDROP = {
  bgFile = "Interface\\Buttons\\WHITE8x8",
  edgeFile = "Interface\\Buttons\\WHITE8x8",
  edgeSize = 1,
}

local active = {}   -- shown toasts, oldest first
local free = {}     -- hidden toasts ready for reuse
local nextId = 0

local function escape(text) return ns.Social.Util.EscapePipes(text) end

local function chat_scan() return ns.FS:GetModule("ChatScan", true) end

-- The ChatScan settings (a plain default table before ChatScan exists, which only a spec without it sees).
local function settings()
  local scan = chat_scan()
  if scan and scan.Settings then return scan:Settings() end
  return { toastSeconds = DEFAULT_TOAST_SECONDS, sound = true,
    whisperTemplate = L["Hi! I can craft %s. Send me a crafting order?"] }
end

local function kind_label(kind)
  local labels = { trade = L["Trade"], services = L["Services"], general = L["General"], guild = L["Guild"] }
  return labels[kind] or escape(tostring(kind or ""))
end

local function valid_match(match)
  if type(match) ~= "table" or type(match.sender) ~= "string" or match.sender == "" then return false end
  local recipes = match.recipes
  return type(recipes) == "table" and type(recipes[1]) == "table"
end

local function recipe_text(recipe)
  local name = recipe.name
  if type(name) ~= "string" or name == "" then
    name = type(recipe.recipeID) == "number" and L["Recipe %d"]:format(recipe.recipeID) or ""
  end
  return name
end

-- "You: Q3 on Alt-Realm . 12g" (profit or "no price"); "" when no character is named.
local function you_text(best)
  if type(best) ~= "table" or type(best.charKey) ~= "string" then return "" end
  local quality = best.expectedQuality
  local qualityText = type(quality) == "number" and quality == quality
    and L["Q%d"]:format(math.floor(quality + 0.5)) or L["quality unknown"]
  local text = L["You: %s on %s"]:format(qualityText, escape(best.charKey))
  local profit
  if best.noPrice or type(best.profit) ~= "number" then
    profit = L["no price"]
  else
    profit = ns.UI.FormatMoney and ns.UI.FormatMoney(best.profit) or tostring(best.profit)
  end
  return text .. DOT .. profit
end

---------------------------------------------------------------------------
-- Whisper (the only path from a toast to a whisper)
---------------------------------------------------------------------------

-- The text typed into the chat box: the whisper template with the first recipe's link (its name without one).
function Toast:WhisperText(match)
  local recipe = match.recipes[1]
  return settings().whisperTemplate:format(recipe.link or recipe_text(recipe))
end

-- Opens the chat edit box on a whisper to the sender with the template text. Sends nothing, does nothing else.
function Toast:OnWhisperClick(match)
  local chat = ChatFrameUtil
  if type(chat) ~= "table" then return end
  if type(chat.SendTellWithMessage) == "function" then
    chat.SendTellWithMessage(match.sender, self:WhisperText(match))
  elseif type(chat.SendTell) == "function" then
    chat.SendTell(match.sender)
  end
end

---------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------

local function line(frame, template, top, height)
  local fs = frame:CreateFontString(nil, "OVERLAY", template)
  fs:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -top)
  fs:SetWidth(Toast.WIDTH - 2 * PAD)
  fs:SetHeight(height)
  fs:SetJustifyH("LEFT")
  fs:SetWordWrap(false)
  fs:SetMaxLines(1)
  return fs
end

local function button(frame, view, index, label, onClick)
  local width = (Toast.WIDTH - 2 * PAD - 2 * BUTTON_GAP) / 3
  local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  b:SetSize(width, BUTTON_HEIGHT)
  b:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD + (index - 1) * (width + BUTTON_GAP), PAD)
  b:SetText(label)
  b:SetScript("OnClick", ns.FS:Wrap(CLICK_SOURCE, function()
    local match = view.match
    if match then onClick(match) end
  end))
  return b
end

local release   -- forward

local function show_tooltip(view)
  local match = view.match
  if not match or not GameTooltip then return end
  GameTooltip:SetOwner(view.frame, "ANCHOR_BOTTOM")
  GameTooltip:SetText(escape(match.sender) .. DOT .. kind_label(match.kind))
  for _, recipe in ipairs(match.recipes) do
    if type(recipe) == "table" then
      GameTooltip:AddLine(escape(recipe_text(recipe)), 1, 1, 1)
      local you = you_text(recipe.best)
      if you ~= "" then GameTooltip:AddLine(you, 0.8, 0.8, 0.8) end
    end
  end
  GameTooltip:Show()
end

local function build_view()
  nextId = nextId + 1
  local view = { id = nextId, timerKey = TIMER_PREFIX .. nextId }
  local frame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
  frame:SetSize(Toast.WIDTH, Toast.HEIGHT)
  frame:SetFrameStrata("FULLSCREEN_DIALOG")
  frame:SetClampedToScreen(true)
  frame:EnableMouse(true)
  frame:SetBackdrop(BACKDROP)
  frame:SetBackdropColor(0, 0, 0, 0.85)
  frame:SetBackdropBorderColor(1, 0.82, 0, 1)
  frame:SetScript("OnEnter", ns.FS:Wrap(TOOLTIP_SOURCE, function() show_tooltip(view) end))
  frame:SetScript("OnLeave", ns.FS:Wrap(TOOLTIP_SOURCE, function()
    if GameTooltip then GameTooltip:Hide() end
  end))
  view.frame = frame
  view.title = line(frame, "GameFontNormal", 6, 16)
  view.recipe = line(frame, "GameFontHighlight", 24, 16)
  view.you = line(frame, "GameFontHighlightSmall", 42, 14)
  view.whisper = button(frame, view, 1, L["Whisper"], function(match)
    Toast:OnWhisperClick(match)
    release(view)
  end)
  view.ignore = button(frame, view, 2, L["Ignore"], function(match)
    local scan = chat_scan()
    if scan then scan:Ignore(match.sender) end
    release(view)
  end)
  view.dismiss = button(frame, view, 3, L["Dismiss"], function() release(view) end)
  frame:Hide()
  return view
end

-- Top-centre stack, oldest on top; no toast overlaps another.
local function layout()
  for i, view in ipairs(active) do
    view.frame:ClearAllPoints()
    view.frame:SetPoint("TOP", UIParent, "TOP", 0, -(Toast.TOP + (i - 1) * (Toast.HEIGHT + Toast.GAP)))
  end
end

function release(view)
  ns.FS:CancelDebounce(view.timerKey)
  for i, shown in ipairs(active) do
    if shown == view then table.remove(active, i); break end
  end
  view.match = nil
  view.frame:Hide()
  if GameTooltip and GameTooltip.GetOwner and GameTooltip:GetOwner() == view.frame then GameTooltip:Hide() end
  free[#free + 1] = view
  layout()
end

local function play_sound()
  local kit = SOUNDKIT
  local id = type(kit) == "table" and kit.TELL_MESSAGE or nil
  if id then pcall(PlaySound, id) end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

-- Shows a toast for a ChatMatch. A malformed match shows nothing. -> true when a toast was shown.
function Toast:Show(match)
  if not valid_match(match) then return false end
  while #active >= Toast.MAX_TOASTS do release(active[1]) end
  local view = table.remove(free) or build_view()
  view.match = match
  local first = match.recipes[1]
  view.title:SetText(TITLE_COLOR .. escape(match.sender) .. "|r" .. DOT .. kind_label(match.kind))
  local recipeLine = escape(recipe_text(first))
  if #match.recipes > 1 then recipeLine = recipeLine .. " " .. L["+%d more"]:format(#match.recipes - 1) end
  view.recipe:SetText(recipeLine)
  view.you:SetText(you_text(first.best))
  active[#active + 1] = view
  layout()
  view.frame:Show()
  local current = settings()
  ns.FS:Debounce(view.timerKey, current.toastSeconds or DEFAULT_TOAST_SECONDS,
    ns.FS:Wrap(CLICK_SOURCE, function() if view.match == match then release(view) end end))
  if current.sound then play_sound() end
  return true
end

function Toast:VisibleCount() return #active end

-- The shown toasts, oldest first: { frame, title, recipe, you, whisper, ignore, dismiss, match } (tests and tooling).
function Toast:GetToasts()
  local out = {}
  for i, view in ipairs(active) do out[i] = view end
  return out
end

function Toast:HideAll()
  while #active > 0 do release(active[#active]) end
end

---------------------------------------------------------------------------
-- Registrar
---------------------------------------------------------------------------

function ChatToasts:OnEnable()
  self:RegisterMessage(ns.Msg.CHATSCAN_MATCH, ns.FS:Wrap(MODULE, function(_, match)
    if not ns.FS:IsModuleEnabled("ChatScan") then return end
    Toast:Show(match)
  end))
end

function ChatToasts:OnDisable()
  self:UnregisterAllMessages()
  Toast:HideAll()
end
