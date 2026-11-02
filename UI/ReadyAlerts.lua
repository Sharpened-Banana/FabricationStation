local ADDON_NAME, ns = ...
local L = ns.L

-- ReadyAlerts: in-game alerts for things that become ready or new (design rule 3: it only announces, nothing is done
-- for the player; spec section 7: no notification outside the game). Every alert is off by default.
--
--   * concentrationFull: a visible character's concentration pool is full (Alts:GetPools);
--   * moxieThreshold: a character's Moxie is at or above the amount (0 = off);
--   * cooldownReady: a cooldown comes off, or a charge is available (Scanner's cooldown records);
--   * newOrdersFlash / newOrdersSound: new matching orders appeared on the board of a scope seen before
--     (Orders sends FS_ORDERS_NEW), and the sound for them;
--   * personalOrderFlash: the taskbar flash for FS_PERSONAL_ORDER_ARRIVED (OrderAlert already plays its sound and
--     shows its toast for that).
-- Delivery: a chat line when `chat`, PlaySound(SOUNDKIT.RAID_WARNING) when `sound` (new orders: also when
-- newOrdersSound), OrderAlert:ShowToast when OrderAlert is on, and FlashClientIcon() (feature-tested) for the two
-- flash alerts only.
--
-- States: a key ("conc:<charKey>:<skillLine>", "moxie:...", "cd:<charKey>:<recipeID>") alerts when its state
-- becomes true; it is remembered for the session (`seen`) and forgotten when the state stops, so nothing repeats
-- until it resets. A cooldown that is ready at the first check of the session is remembered without an alert (only a
-- cooldown that comes off alerts, and one that is ready while the alert is off is never announced later).
--
-- Timing: the first loading screen (PLAYER_ENTERING_WORLD) this module sees that is not a /reload schedules the login
-- check 12 s later (Scanner's login data is in by then). That is the first loading screen of the session when the
-- module is on from the start, and the next one after it when the module is turned on later in the session, so a
-- module turned on later gets a login check too. A /reload has none, and neither has a module that is turned off and on
-- again after it has seen that loading screen: its first check only records what is true as the baseline, so nothing
-- is announced twice. The login check alerts the concentration and Moxie states already true, at most 5 lines and then
-- "+N more", and skips concentration while the Planner is on with capWarnChat (the Planner announces those). No other
-- check runs before it. After every check one Debounce key times the next one for the soonest pool that fills or
-- cooldown that comes off (5 s to 6 h); data and alt changes ask for a check 1 s later. All timers are Debounce keys,
-- cancelled in OnDisable; no ticker. Every handler runs through ns.FS:Wrap("ReadyAlerts", ...), so a failure turns
-- off only this module. Nothing is written while the saved data is from a newer version (Settings() is a
-- session-only copy then).
local MODULE = "ReadyAlerts"
local ReadyAlerts = ns.FS:NewModule(MODULE, "AceEvent-3.0")

ReadyAlerts.SETTINGS_DEFAULTS = {
  concentrationFull = false,
  moxieThreshold = 0,
  cooldownReady = false,
  newOrdersFlash = false,
  newOrdersSound = false,
  personalOrderFlash = false,
  chat = true,
  sound = true,
}

ReadyAlerts.MOXIE_MAX = 10000

local LOGIN_KEY, NEXT_KEY, SCHEDULE_KEY = "readyAlerts.login", "readyAlerts.next", "readyAlerts.schedule"
local LOGIN_DELAY, SCHEDULE_DELAY = 12, 1
local MIN_DELAY, MAX_DELAY = 5, 21600
local LOGIN_LINES = 5

local function is_finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

-- Wrong types get the default; moxieThreshold is rounded and kept within 0..MOXIE_MAX (anything that is not a finite
-- number gets the default 0).
local function fill(target, defaults)
  for key, default in pairs(defaults) do
    if type(target[key]) ~= type(default) then target[key] = default end
  end
  local m = target.moxieThreshold
  if not is_finite(m) then
    target.moxieThreshold = defaults.moxieThreshold
  else
    target.moxieThreshold = math.max(0, math.min(ReadyAlerts.MOXIE_MAX, math.floor(m + 0.5)))
  end
  return target
end

local settingsTable = ns.Util.SettingsAccessor("readyAlerts")   -- a session-only copy while the saved data is read-only

-- db.global.settings.readyAlerts with defaults filled in (a session-only copy while the saved data is read-only).
function ReadyAlerts:Settings()
  return settingsTable(self.SETTINGS_DEFAULTS, fill)
end

---------------------------------------------------------------------------
-- Delivery
---------------------------------------------------------------------------

local soundErrorLogged

local function play_sound()
  local kit = SOUNDKIT
  local id = type(kit) == "table" and kit.RAID_WARNING or nil
  if type(PlaySound) ~= "function" or id == nil then return end
  local ok, err = pcall(PlaySound, id)
  if not ok and not soundErrorLogged then
    soundErrorLogged = true
    ns.FS:LogError(MODULE, "PlaySound failed: " .. tostring(err))
  end
end

local function flash()
  if type(FlashClientIcon) == "function" then pcall(FlashClientIcon) end
end

local function toast(text)
  local alert = ns.FS:GetModule("OrderAlert", true)
  if alert and alert:IsEnabled() and type(alert.ShowToast) == "function" then alert:ShowToast(text) end
end

local function prefixed(text) return L["FabricationStation: %s"]:format(text) end

-- Delivers `lines` (plain texts) as one alert: a chat line each (after opts.maxLines, one "+N more" line), one sound
-- (when `sound` is on, or as opts.sound says when it is given) and one toast naming the first line.
local function deliver(lines, opts)
  opts = opts or {}
  if #lines == 0 then return end
  local s = ReadyAlerts:Settings()
  if s.chat then
    local shown = opts.maxLines and math.min(#lines, opts.maxLines) or #lines
    for i = 1, shown do print(prefixed(lines[i])) end
    if shown < #lines then print(prefixed(L["+%d more"]:format(#lines - shown))) end
  end
  local wantSound = s.sound
  if opts.sound ~= nil then wantSound = opts.sound end   -- new orders: only newOrdersSound decides
  if wantSound then play_sound() end
  local text = lines[1]
  if #lines > 1 then text = L["%s +%d more"]:format(text, #lines - 1) end
  toast(text)
end

---------------------------------------------------------------------------
-- States
---------------------------------------------------------------------------

local seen = {}           -- [key] = true: alerted (or, for a cooldown, noticed) this session while the state holds
local initialised = false -- the first check of the session has run
local loginPending = false -- the login check is scheduled and has not run: no other check runs before it
local loginHandled = false -- the session's first loading screen has been seen (a module switched on later has none)

local function alts()
  local A = ns.FS:GetModule("Alts", true)
  if A and A:IsEnabled() then return A end
end

local function scanner() return ns.FS:GetModule("Scanner", true) end

-- Every visible character's non-dropped profession records: { charKey, skillLineID, record }, sorted by charKey then
-- skillLineID. Characters hidden in the Alts settings are left out.
local function records()
  local S, A = scanner(), alts()
  local out = {}
  if not S then return out end
  local hidden = A and A:Settings().hidden
  hidden = type(hidden) == "table" and hidden or {}
  for _, charKey in ipairs(S:GetCharacters() or {}) do
    local c = S:GetCharacter(charKey)
    if type(charKey) == "string" and not hidden[charKey] and type(c) == "table" and type(c.professions) == "table" then
      local lines = {}
      for line, p in pairs(c.professions) do
        if type(p) == "table" and not p.dropped then lines[#lines + 1] = line end
      end
      table.sort(lines)
      for _, line in ipairs(lines) do out[#out + 1] = { charKey = charKey, skillLineID = line, record = c.professions[line] } end
    end
  end
  return out
end

local function recipe_name(recipeID)
  local api = type(C_Spell) == "table" and C_Spell.GetSpellName
  if type(api) == "function" then
    local ok, name = pcall(api, recipeID)
    if ok and type(name) == "string" and name ~= "" then return name end
  end
  return L["Recipe %d"]:format(recipeID)
end

local function cooldown_ready(cd, now)
  if type(cd.charges) == "number" and cd.charges > 0 then return true end
  return is_finite(cd.readyAt) and cd.readyAt <= now
end

-- The current states: { conc = {key=,text=,...}, moxie = {...}, cd = {...}, soonest = seconds|nil }. Every state that
-- is true now is listed whether or not its alert is on (Moxie: while its threshold is above 0), so Check can remember
-- what was already true when the session started or the alert was switched on, and announce only what becomes true
-- later; `soonest` counts only the alerts that are on.
local function collect(now, s)
  local out = { conc = {}, moxie = {}, cd = {} }
  local soonest
  local function soon(seconds)
    if is_finite(seconds) and (soonest == nil or seconds < soonest) then soonest = seconds end
  end
  local A = alts()
  if A then
    for _, pool in ipairs(A:GetPools(now)) do
      if is_finite(pool.value) and is_finite(pool.max) then
        if pool.value >= pool.max then
          out.conc[#out.conc + 1] = { key = "conc:" .. pool.charKey .. ":" .. pool.skillLineID,
            text = L["%s %s: concentration is full"]:format(pool.charKey, A:ProfessionName(pool.skillLineID)) }
        elseif s.concentrationFull and is_finite(pool.fullAt) then
          soon(pool.fullAt - now)
        end
      end
    end
  end
  for _, r in ipairs(records()) do
    local moxie = r.record.moxie
    if s.moxieThreshold > 0 and type(moxie) == "table" and is_finite(moxie.value) and moxie.value >= s.moxieThreshold then
      out.moxie[#out.moxie + 1] = { key = "moxie:" .. r.charKey .. ":" .. r.skillLineID,
        text = L["%s %s: Moxie is %d"]:format(r.charKey, A and A:ProfessionName(r.skillLineID) or tostring(r.skillLineID),
          moxie.value) }
    end
    if type(r.record.cooldowns) == "table" then
      local ids = {}
      for recipeID, cd in pairs(r.record.cooldowns) do
        if type(cd) == "table" then ids[#ids + 1] = recipeID end
      end
      table.sort(ids)
      for _, recipeID in ipairs(ids) do
        local cd = r.record.cooldowns[recipeID]
        if cooldown_ready(cd, now) then
          out.cd[#out.cd + 1] = { key = "cd:" .. r.charKey .. ":" .. recipeID,
            text = L["%s: %s is ready"]:format(r.charKey, recipe_name(recipeID)) }
        elseif s.cooldownReady and is_finite(cd.readyAt) then
          soon(cd.readyAt - now)
        end
      end
    end
  end
  out.soonest = soonest
  return out
end

local function schedule_next(soonest)
  if soonest == nil then
    ns.FS:CancelDebounce(NEXT_KEY)
    return
  end
  local delay = math.max(MIN_DELAY, math.min(MAX_DELAY, soonest))
  ns.FS:Debounce(NEXT_KEY, delay, ns.FS:Wrap(MODULE, function() ReadyAlerts:Check() end))
end

-- True while the Planner is on and announces full concentration pools itself (once, at login).
local function planner_announces()
  local P = ns.FS:GetModule("Planner", true)
  return P ~= nil and P:IsEnabled() and P:Settings().capWarnChat == true
end

-- Looks at every state, alerts the ones that became true, forgets the ones that stopped and schedules the next check.
-- `login` (the login check): concentration is skipped while the Planner announces it, and at most LOGIN_LINES lines
-- are printed. now defaults to the server time. -> the lines alerted, as a list of texts.
function ReadyAlerts:Check(now, login)
  now = is_finite(now) and now or ns.FS:Now()
  local s = self:Settings()
  local states = collect(now, s)
  local first = not initialised
  initialised = true

  -- The first check of a session that is not the login check (a /reload, or the module switched on) only takes the
  -- current states as its baseline: nothing that was already true is announced again.
  local silent = first and not login
  local active, lines = {}, {}
  local skipConc = login and planner_announces()
  for _, st in ipairs(states.conc) do
    active[st.key] = true
    if not seen[st.key] then
      seen[st.key] = true
      if s.concentrationFull and not silent and not skipConc then lines[#lines + 1] = st.text end
    end
  end
  for _, st in ipairs(states.moxie) do
    active[st.key] = true
    if not seen[st.key] then
      seen[st.key] = true
      if not silent then lines[#lines + 1] = st.text end
    end
  end
  for _, st in ipairs(states.cd) do
    active[st.key] = true
    if not seen[st.key] then
      seen[st.key] = true
      if s.cooldownReady and not first then lines[#lines + 1] = st.text end
    end
  end
  for key in pairs(seen) do
    if not active[key] then seen[key] = nil end
  end

  deliver(lines, { maxLines = login and LOGIN_LINES or nil })
  schedule_next(states.soonest)
  return lines
end

---------------------------------------------------------------------------
-- Orders
---------------------------------------------------------------------------

-- FS_ORDERS_NEW(charKey, count, orderTypeName): active while newOrdersFlash or newOrdersSound is on.
local function on_orders_new(_, _, count)
  local s = ReadyAlerts:Settings()
  if not (s.newOrdersFlash or s.newOrdersSound) then return end
  if type(count) ~= "number" or count < 1 then return end
  local text = (count == 1 and L["%d new order matches your filters"] or L["%d new orders match your filters"])
    :format(count)
  deliver({ text }, { sound = s.newOrdersSound })   -- the flash alone plays no sound
  if s.newOrdersFlash then flash() end
end

-- FS_PERSONAL_ORDER_ARRIVED(professionName, count, delta): the flash only (OrderAlert has the sound and the toast).
local function on_personal_order(_, _, _, delta)
  if type(delta) == "number" and (delta ~= delta or delta <= 0) then return end
  if ReadyAlerts:Settings().personalOrderFlash then flash() end
end

---------------------------------------------------------------------------
-- Events and timers
---------------------------------------------------------------------------

local function request_check()
  if loginPending then return end
  ns.FS:Debounce(SCHEDULE_KEY, SCHEDULE_DELAY, ns.FS:Wrap(MODULE, function()
    if not loginPending then ReadyAlerts:Check() end
  end))
end

function ReadyAlerts:OnEnable()
  local function wrap(fn) return ns.FS:Wrap(MODULE, fn) end
  if not loginHandled then
    self:RegisterEvent("PLAYER_ENTERING_WORLD", wrap(function(_, _, isReloadingUi)
      self:UnregisterEvent("PLAYER_ENTERING_WORLD")
      loginHandled = true
      if isReloadingUi then return end
      loginPending = true
      ns.FS:Debounce(LOGIN_KEY, LOGIN_DELAY, wrap(function()
        loginPending = false
        self:Check(nil, true)
      end))
    end))
  end
  self:RegisterMessage(ns.Msg.ORDERS_NEW, wrap(on_orders_new))
  self:RegisterMessage(ns.Msg.PERSONAL_ORDER_ARRIVED, wrap(on_personal_order))
  self:RegisterMessage(ns.Msg.ALTS_CHANGED, wrap(request_check))
  self:RegisterMessage(ns.Msg.DATA_CHANGED, wrap(request_check))
end

function ReadyAlerts:OnDisable()
  ns.FS:CancelDebounce(LOGIN_KEY)
  ns.FS:CancelDebounce(NEXT_KEY)
  ns.FS:CancelDebounce(SCHEDULE_KEY)
  self:UnregisterAllEvents()
  self:UnregisterAllMessages()
  seen, initialised, loginPending = {}, false, false
end

---------------------------------------------------------------------------
-- Options group ("readyAlerts", order 65)
---------------------------------------------------------------------------

local function read_only() return ns.FS.dbIsNewer == true end

local function toggle(key, order, name)
  return {
    type = "toggle", order = order, width = "full", name = name, disabled = read_only,
    get = function() return ReadyAlerts:Settings()[key] end,
    set = function(_, value) ReadyAlerts:Settings()[key] = value and true or false end,
  }
end

-- Every setter writes through ReadyAlerts:Settings() (so nothing is saved while the saved data is from a newer
-- version); the options are shown disabled then.
function ReadyAlerts.BuildOptions()
  return {
    type = "group", name = L["Ready alerts"], order = 65,
    args = {
      concentrationFull = toggle("concentrationFull", 1, L["Alert when concentration is full"]),
      moxieThreshold = {
        type = "range", order = 2, width = "full", name = L["Alert when Moxie reaches this amount (0 = off)"],
        min = 0, max = ReadyAlerts.MOXIE_MAX, step = 1, disabled = read_only,
        get = function() return ReadyAlerts:Settings().moxieThreshold end,
        set = function(_, value)
          if not is_finite(value) then return end
          ReadyAlerts:Settings().moxieThreshold = math.max(0, math.min(ReadyAlerts.MOXIE_MAX, math.floor(value + 0.5)))
        end,
      },
      cooldownReady = toggle("cooldownReady", 3, L["Alert when a cooldown is ready"]),
      newOrdersFlash = toggle("newOrdersFlash", 4, L["Flash the taskbar on new orders"]),
      newOrdersSound = toggle("newOrdersSound", 5, L["Play a sound on new orders"]),
      personalOrderFlash = toggle("personalOrderFlash", 6, L["Flash the taskbar on a personal order"]),
      chat = toggle("chat", 7, L["Show alerts in chat"]),
      sound = toggle("sound", 8, L["Play a sound with alerts"]),
    },
  }
end

ns.FS:RegisterOptions("readyAlerts", ReadyAlerts.BuildOptions())
