local ADDON_NAME, ns = ...

-- OrderAlert: when a personal crafting order arrives (Orders sends ns.Msg.PERSONAL_ORDER_ARRIVED(professionName,
-- count, delta)), play a sound and show a toast. In-game sound and toast only (spec section 7; notifications outside
-- the game are out of scope).
--
-- Settings (db.global.settings.alerts, created lazily): personalOrderSound, personalOrderToast, sound (a SOUNDKIT
-- key, RAID_WARNING when it is unknown) and toastSeconds (how long the toast stays before a one second fade).
--
-- No taint (design rules 2 and 7): the toast is our own frame parented to UIParent; nothing of Blizzard's is touched.
-- Nothing here acts for the player (design rule 3): it only announces. The toast timer is 1a's Debounce, cancelled
-- (with the frame hidden) in OnDisable; the message handler runs through ns.FS:Wrap so a failure turns off only this
-- module.
local MODULE = "OrderAlert"
local OrderAlert = ns.FS:NewModule(MODULE, "AceEvent-3.0")

OrderAlert.SETTINGS_DEFAULTS = {
  personalOrderSound = true,
  personalOrderToast = true,
  sound = "RAID_WARNING",
  toastSeconds = 8,
}

local DEFAULT_SOUND = "RAID_WARNING"
local FADE_SECONDS = 1
local TIMER_KEY = "OrderAlert:toast"
local TOAST_WIDTH, TOAST_HEIGHT, TOAST_OFFSET_Y = 420, 44, -120
local BACKDROP = {
  bgFile = "Interface\\Buttons\\WHITE8x8",
  edgeFile = "Interface\\Buttons\\WHITE8x8",
  edgeSize = 1,
}

-- The alert settings table, defaults filled in for missing keys only (a stored false stays false). It is
-- db.global.settings.alerts, created on first use.
function OrderAlert:Settings()
  local g = ns.FS.db and ns.FS.db.global
  if not g then return ns.Util.DeepCopy(self.SETTINGS_DEFAULTS) end
  if type(g.settings) ~= "table" then g.settings = {} end
  if type(g.settings.alerts) ~= "table" then g.settings.alerts = {} end
  local s = g.settings.alerts
  for key, value in pairs(self.SETTINGS_DEFAULTS) do
    if s[key] == nil then s[key] = value end
  end
  return s
end

-- "New personal crafting order: Tailoring (2 waiting)"; the profession and the count are left out when unknown.
function OrderAlert.ToastText(professionName, count)
  local text = "New personal crafting order"
  if type(professionName) == "string" and professionName ~= "" then text = text .. ": " .. professionName end
  if type(count) == "number" then text = text .. " (" .. count .. " waiting)" end
  return text
end

-- The SOUNDKIT id for a settings name; the raid warning for an unknown or non-string name; nil without SOUNDKIT.
local function sound_id(name)
  local kit = SOUNDKIT
  if type(kit) ~= "table" then return nil end
  local id = type(name) == "string" and kit[name] or nil
  return id or kit[DEFAULT_SOUND]
end

---------------------------------------------------------------------------
-- Toast frame (own frame, created on first use)
---------------------------------------------------------------------------

local toast   -- { frame, text } (nil before the first toast)

local function stop_fade()
  if toast then
    toast.frame:SetScript("OnUpdate", nil)
    toast.frame:SetAlpha(1)
  end
end

local function build_toast()
  local frame = CreateFrame("Frame", "FabricationStationOrderToast", UIParent, "BackdropTemplate")
  frame:SetSize(TOAST_WIDTH, TOAST_HEIGHT)
  frame:SetPoint("TOP", UIParent, "TOP", 0, TOAST_OFFSET_Y)
  frame:SetFrameStrata("FULLSCREEN_DIALOG")
  frame:SetBackdrop(BACKDROP)
  frame:SetBackdropColor(0, 0, 0, 0.85)
  frame:SetBackdropBorderColor(1, 0.82, 0, 1)
  local text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  text:SetPoint("CENTER", frame, "CENTER", 0, 0)
  frame:Hide()
  return { frame = frame, text = text }
end

-- After toastSeconds: fade the toast out over a second with an OnUpdate on our own frame, then hide it.
local function start_fade()
  if not toast then return end
  local frame, elapsed = toast.frame, 0
  frame:SetScript("OnUpdate", ns.FS:Wrap(MODULE, function(_, dt)
    elapsed = elapsed + (tonumber(dt) or 0)
    if elapsed >= FADE_SECONDS then
      stop_fade()
      frame:Hide()
    else
      frame:SetAlpha(1 - elapsed / FADE_SECONDS)
    end
  end))
end

-- Shows (or replaces the text of) the toast and restarts its timer.
function OrderAlert:ShowToast(text)
  toast = toast or build_toast()
  stop_fade()
  toast.text:SetText(text)
  toast.frame:Show()
  local seconds = self:Settings().toastSeconds
  if type(seconds) ~= "number" or seconds <= 0 then seconds = self.SETTINGS_DEFAULTS.toastSeconds end
  ns.FS:Debounce(TIMER_KEY, seconds, ns.FS:Wrap(MODULE, start_fade))
end

-- Test and diagnostics access: { frame, text } (nil before the first toast).
function OrderAlert:GetToast() return toast end

---------------------------------------------------------------------------
-- Message handling
---------------------------------------------------------------------------

function OrderAlert:OnArrived(_, professionName, count)
  local settings = self:Settings()
  if settings.personalOrderSound then
    local id = sound_id(settings.sound)
    if id then PlaySound(id) end
  end
  if settings.personalOrderToast then
    self:ShowToast(OrderAlert.ToastText(professionName, count))
  end
end

function OrderAlert:OnEnable()
  self:RegisterMessage(ns.Msg.PERSONAL_ORDER_ARRIVED, ns.FS:Wrap(MODULE, function(event, ...)
    self:OnArrived(event, ...)
  end))
end

function OrderAlert:OnDisable()
  ns.FS:CancelDebounce(TIMER_KEY)
  if toast then
    stop_fade()
    toast.frame:Hide()
  end
end
