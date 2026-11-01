local ADDON_NAME, ns = ...
local L = ns.L

-- OrderAlert: when a personal crafting order arrives (Orders sends ns.Msg.PERSONAL_ORDER_ARRIVED(professionName,
-- count, delta)), play a sound and show a toast. In-game sound and toast only (spec section 7; notifications outside
-- the game are out of scope).
--
-- Settings (db.global.settings.alerts, created lazily and repaired when a stored value has the wrong type):
-- personalOrderSound, personalOrderToast, sound (a SOUNDKIT key, RAID_WARNING when it is unknown) and toastSeconds
-- (how long the toast stays before a one second fade; a finite number from 1 to 60). While the saved data is missing
-- or from a newer version (ns.FS.dbIsNewer) nothing is written: Settings() is a session-only copy then.
--
-- Arrivals in the same frame (several professions rising at once) are coalesced: one sound, one toast naming each
-- profession. A rise of zero or less is not an arrival. A sound that fails to play is logged once per session and
-- does not stop the toast.
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
local FLUSH_KEY = "OrderAlert:flush"
local TOAST_WIDTH, TOAST_HEIGHT, TOAST_OFFSET_Y = 420, 44, -120
local BACKDROP = {
  bgFile = "Interface\\Buttons\\WHITE8x8",
  edgeFile = "Interface\\Buttons\\WHITE8x8",
  edgeSize = 1,
}

local MIN_TOAST_SECONDS, MAX_TOAST_SECONDS = 1, 60

local function is_finite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end

-- Fills every default `target` is missing or holds with the wrong type, keeping valid values (a stored false stays
-- false). toastSeconds must be a finite number from 1 to 60, else the default. Deliberately not shared with Orders'
-- and Ledger's fill: each module repairs its own settings by its own rules (Orders coerces numeric strings, Ledger
-- rejects NaN, OrderAlert range-checks toastSeconds).
local function fill(target, defaults)
  for key, default in pairs(defaults) do
    if type(target[key]) ~= type(default) then target[key] = default end
  end
  local seconds = target.toastSeconds
  if not (is_finite(seconds) and seconds >= MIN_TOAST_SECONDS and seconds <= MAX_TOAST_SECONDS) then
    target.toastSeconds = defaults.toastSeconds
  end
  return target
end

local settingsTable = ns.Util.SettingsAccessor("alerts")  -- a session-only copy while the saved data is read-only

-- The alert settings table, with defaults filled in. It is db.global.settings.alerts (created on first use); while
-- the saved data is missing or read-only it is a session-only copy, so callers can always read and set it.
function OrderAlert:Settings()
  return settingsTable(self.SETTINGS_DEFAULTS, fill)
end

-- "New personal crafting order: Tailoring (2 waiting)"; the profession and the count are left out when unknown.
function OrderAlert.ToastText(professionName, count)
  local text = L["New personal crafting order"]
  if type(professionName) == "string" and professionName ~= "" then
    text = L["New personal crafting order: %s"]:format(professionName)
  end
  if type(count) == "number" then text = L["%s (%d waiting)"]:format(text, count) end
  return text
end

-- "New personal orders: Tailoring, Alchemy" for several professions at once.
function OrderAlert.ToastTextMany(names)
  if #names == 0 then return OrderAlert.ToastText(nil, nil) end
  return L["New personal orders: %s"]:format(ns.UI.JoinList(names))
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
  frame:EnableMouse(false)   -- the toast never takes clicks
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
  ns.FS:Debounce(TIMER_KEY, seconds, ns.FS:Wrap(MODULE, start_fade))
end

-- Test and diagnostics access: { frame, text } (nil before the first toast).
function OrderAlert:GetToast() return toast end

---------------------------------------------------------------------------
-- Message handling
---------------------------------------------------------------------------

local pending          -- arrivals of this frame: { { name, count } ... }, flushed by FLUSH_KEY
local soundErrorLogged  -- a failing PlaySound is logged once per session

local function play(id)
  local ok, err = pcall(PlaySound, id)
  if not ok and not soundErrorLogged then
    soundErrorLogged = true
    ns.FS:LogError(MODULE, "PlaySound failed: " .. tostring(err))
  end
end

-- One sound and one toast for everything that arrived since the last flush.
local function flush()
  local arrivals = pending
  pending = nil
  if not arrivals or #arrivals == 0 then return end
  local settings = OrderAlert:Settings()
  if settings.personalOrderSound then
    local id = sound_id(settings.sound)
    if id then play(id) end
  end
  if settings.personalOrderToast then
    local text
    if #arrivals == 1 then
      text = OrderAlert.ToastText(arrivals[1].name, arrivals[1].count)
    else
      local names = {}
      for _, arrival in ipairs(arrivals) do
        if arrival.name then names[#names + 1] = arrival.name end
      end
      text = OrderAlert.ToastTextMany(names)
    end
    OrderAlert:ShowToast(text)
  end
end

-- Queues an arrival; a rise of zero or less, or NaN (delta given), is ignored. Arrivals in the same frame share one alert.
function OrderAlert:OnArrived(_, professionName, count, delta)
  if type(delta) == "number" and (delta ~= delta or delta <= 0) then return end   -- NaN is no rise either
  local name = type(professionName) == "string" and professionName ~= "" and professionName or nil
  pending = pending or {}
  local entry
  for _, existing in ipairs(pending) do
    if existing.name == name then entry = existing end
  end
  if entry then
    entry.count = count
  else
    pending[#pending + 1] = { name = name, count = count }
  end
  ns.FS:Debounce(FLUSH_KEY, 0, ns.FS:Wrap(MODULE, flush))
end

function OrderAlert:OnEnable()
  self:RegisterMessage(ns.Msg.PERSONAL_ORDER_ARRIVED, ns.FS:Wrap(MODULE, function(event, ...)
    self:OnArrived(event, ...)
  end))
end

function OrderAlert:OnDisable()
  pending = nil
  ns.FS:CancelDebounce(FLUSH_KEY)
  ns.FS:CancelDebounce(TIMER_KEY)
  if toast then
    stop_fade()
    toast.frame:Hide()
  end
end
