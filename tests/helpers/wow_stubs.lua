-- Fake WoW API + Ace3 layer for unit tests.
--
-- Deliberate divergences from real WoW/Ace3 (so tests stay simple and failures stay loud):
--   * Errors in OnInitialize/OnEnable and in event/message handlers propagate to the caller.
--     Real Ace3 routes them to geterrorhandler() and carries on.
--   * AceDB strips default values only when a test calls W.logout() (the client does it on
--     PLAYER_LOGOUT), and has no "*" / "**" wildcard defaults.
--   * Frame Show/Hide do not fire OnShow/OnHide.
--   * HookScript composes with the existing SetScript/HookScript handler, so GetScript returns the chain.
--   * frame:RegisterEvent is a no-op (use W.fire to drive AceEvent handlers).
--   * W.advance(0) is one frame: a zero-delay timer (C_Timer.After(0, ...)) created while advance is
--     running callbacks at the advance's target time waits for the next W.advance, as it waits for
--     the next frame in the client. Created earlier inside a longer advance (W.now < target), it runs
--     within that advance, as later frames would have run it.
--   * hooksecurefunc hook bodies run inline after the original, so an error in a hook propagates to the caller
--     (the client reports it and carries on). Hooks are recorded in W.hooks as { tbl, name, fn }
--     (tbl is nil for a global function, so the name is at [2] and fn at [3] either way).
--   * time() and GetServerTime() return W.now unfloored (fractional after a sub-second advance), so
--     tests can compare stored timestamps with W.now. The client returns whole seconds; tests of
--     logic that floors or divides time should advance by whole seconds.
--   * Phase-4 defaults (preflight row 3) are inert: no guild, no restrictions, no secret values, every optional addon
--     absent, chat sending raises ("auto-send forbidden"). tests/helpers/phase4_stubs.lua makes them controllable.
--   local W = install_wow_stubs(overrides)
-- Every call rebuilds all fakes from scratch. `overrides` is deep-merged into the default globals
-- (plain tables merge key by key, anything else replaces). Returns the handle `W`.
-- One override is not a global: `LibStubMissing = { "LibName", ... }` lists libraries that
-- LibStub(name, true) reports as absent (nil), so tests can check that optional libs are optional.

local unpack = unpack or table.unpack
local realPrint = print

-- Globals this module has put into _G, so the next install can remove them again.
local installedNames = {}
local framesByName = {}

local function is_plain_table(v) return type(v) == "table" and getmetatable(v) == nil end

local function deep_copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = deep_copy(x) end
  return out
end

local function deep_merge(dst, src)
  for k, v in pairs(src) do
    if is_plain_table(v) and is_plain_table(dst[k]) then deep_merge(dst[k], v) else dst[k] = v end
  end
  return dst
end

local function join_args(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  return table.concat(parts, " ")
end

local function noop() end

-- WoW strsplit(delimiter, subject [, pieces]): every character of `delimiter` is a separator
-- (it is a character set, not a pattern). With `pieces`, the last piece keeps the remainder.
local function strsplit(delimiter, subject, pieces)
  local seps = {}
  for i = 1, #delimiter do seps[delimiter:sub(i, i)] = true end
  local out, startIdx = {}, 1
  for i = 1, #subject do
    if pieces and #out >= pieces - 1 then break end
    if seps[subject:sub(i, i)] then
      out[#out + 1] = subject:sub(startIdx, i - 1)
      startIdx = i + 1
    end
  end
  out[#out + 1] = subject:sub(startIdx)
  return unpack(out)
end

-- WoW strtrim(str [, chars]): strips leading and trailing characters found in `chars`
-- (default: space, tab, CR, LF). `chars` is a character set, not a pattern.
local function strtrim(str, chars)
  chars = chars or " \t\r\n"
  local set = {}
  for i = 1, #chars do set[chars:sub(i, i)] = true end
  local first, last = 1, #str
  while first <= last and set[str:sub(first, first)] do first = first + 1 end
  while last >= first and set[str:sub(last, last)] do last = last - 1 end
  return str:sub(first, last)
end

-- A table whose unknown Capitalized keys are no-op methods (so `frame:SetBackdrop(...)` works),
-- while lower-case field lookups still return nil.
local function method_stub_meta()
  return { __index = function(_, k)
    if type(k) == "string" and k:match("^%u") then return noop end
  end }
end

local function install(overrides)
  overrides = overrides or {}
  -- LibStubMissing configures the LibStub fake; it is not a global to install.
  local missingLibs = {}
  if overrides.LibStubMissing ~= nil then
    for _, name in ipairs(overrides.LibStubMissing) do missingLibs[name] = true end
    local rest = {}
    for k, v in pairs(overrides) do if k ~= "LibStubMissing" then rest[k] = v end end
    overrides = rest
  end

  -- Undo the previous install.
  for name in pairs(installedNames) do _G[name] = nil end
  _G.print = realPrint
  for name in pairs(framesByName) do _G[name] = nil end
  installedNames, framesByName = {}, {}
  _G.FabricationStationDB = nil
  -- Globals a fake_professions_frame (professions_frame.lua) installed in the previous world.
  require("professions_frame").reset()

  local W = {
    now = 1700000000,
    messages = {},
    printed = {},
    slash = {},
    config = { registered = {}, notified = 0, opened = {}, blizOptions = {} },
    ldb = { objects = {} },
    dbicon = { registered = {}, shown = {} },
    auctionator = { prices = {}, ages = {}, vendor = {}, lists = {}, dbCallbacks = {}, exact = {} },
    errors = {},  -- errors reported through geterrorhandler()
    hooks = {},   -- every hooksecurefunc call: { tbl|nil, name, fn }
    tells = {},   -- ChatFrameUtil.SendTell / SendTellWithMessage calls: { name, text|nil }
  }

  ---------------------------------------------------------------------------
  -- Clock and C_Timer
  ---------------------------------------------------------------------------
  local timers, timerSeq = {}, 0
  local advancing, advanceSeq, advanceTarget = false, 0, nil

  local function schedule(seconds, fn, handle)
    timerSeq = timerSeq + 1
    handle = handle or {}
    handle.due = W.now + (seconds or 0)
    handle.seq = timerSeq
    handle.fn = fn
    -- A zero-delay timer created at the advance's target time belongs to the next frame.
    handle.heldFor = (advancing and (seconds or 0) <= 0 and W.now >= advanceTarget) and advanceSeq or nil
    timers[#timers + 1] = handle
    return handle
  end

  local function remove_timer(handle)
    for i = #timers, 1, -1 do
      if timers[i] == handle then table.remove(timers, i) end
    end
  end

  local function new_handle(seconds, fn, iterations, repeating)
    local handle = { cancelled = false, iterations = iterations, interval = seconds, repeating = repeating }
    function handle:Cancel() self.cancelled = true; remove_timer(self) end
    function handle:IsCancelled() return self.cancelled end
    return schedule(seconds, fn, handle)
  end

  local C_Timer = {
    After = function(seconds, fn) new_handle(seconds, fn, 1, false).afterOnly = true end,
    NewTimer = function(seconds, fn) return new_handle(seconds, fn, 1, false) end,
    NewTicker = function(seconds, fn, iterations)
      return new_handle(math.max(seconds, 1e-9), fn, iterations, true)
    end,
  }

  function W.advance(seconds)
    local target = W.now + (seconds or 0)
    advanceSeq = advanceSeq + 1
    advancing, advanceTarget = true, target
    while true do
      local nextTimer
      for _, t in ipairs(timers) do
        if t.due <= target and t.heldFor ~= advanceSeq and (not nextTimer or t.due < nextTimer.due
          or (t.due == nextTimer.due and t.seq < nextTimer.seq)) then
          nextTimer = t
        end
      end
      if not nextTimer then break end
      remove_timer(nextTimer)
      if nextTimer.due > W.now then W.now = nextTimer.due end
      if not nextTimer.cancelled then
        local again = false
        if nextTimer.repeating then
          if nextTimer.iterations then
            nextTimer.iterations = nextTimer.iterations - 1
            again = nextTimer.iterations > 0
          else
            again = true
          end
        end
        if again then schedule(nextTimer.interval, nextTimer.fn, nextTimer) end
        if nextTimer.afterOnly then nextTimer.fn() else nextTimer.fn(nextTimer) end
      end
    end
    advancing = false
    W.now = target
  end

  ---------------------------------------------------------------------------
  -- Frames
  ---------------------------------------------------------------------------
  local frameMT = method_stub_meta()

  local function new_object(extra)
    local o = setmetatable({}, frameMT)
    for k, v in pairs(extra or {}) do o[k] = v end
    return o
  end

  -- Font strings record their text, show state, anchors and width (GetWidth is nil until SetWidth, as before).
  local function make_fontstring(parent)
    local fs = new_object()
    local text, shown, points, width = nil, true, {}, nil
    function fs:SetText(t) text = t end
    function fs:GetText() return text end
    function fs:Show() shown = true end
    function fs:Hide() shown = false end
    function fs:IsShown() return shown end
    function fs:SetPoint(point, a, b, c, d)
      local rel, relPoint, x, y = parent, point
      if type(a) == "number" then
        x, y = a, b or 0
      else
        if a ~= nil then rel = a end
        relPoint = b or point
        x, y = c or 0, d or 0
      end
      points[#points + 1] = { point, rel, relPoint, x, y }
    end
    function fs:GetPoint(i)
      local p = points[i or 1]
      if p then return unpack(p, 1, 5) end
    end
    function fs:GetNumPoints() return #points end
    function fs:ClearAllPoints() points = {} end
    function fs:SetWidth(w) width = w end
    function fs:GetWidth() return width end
    return fs
  end

  local function CreateFrame(frameType, name, parent, template)
    local f = new_object({ frameType = frameType, name = name, template = template })
    local shown, scripts, points, w, h, par = true, {}, {}, 0, 0, parent
    function f:Show() shown = true end
    function f:Hide() shown = false end
    function f:IsShown() return shown end
    function f:IsVisible() return shown end
    function f:SetScript(event, fn) scripts[event] = fn end
    function f:GetScript(event) return scripts[event] end
    -- Runs after any existing handler instead of replacing it, as in the client.
    function f:HookScript(event, fn)
      local existing = scripts[event]
      if not existing then scripts[event] = fn; return end
      scripts[event] = function(...) existing(...); return fn(...) end
    end
    function f:SetPoint(point, a, b, c, d)
      local rel, relPoint, x, y = par, point
      if type(a) == "number" then
        x, y = a, b or 0
      else
        if a ~= nil then rel = a end
        relPoint = b or point
        x, y = c or 0, d or 0
      end
      points[#points + 1] = { point, rel, relPoint, x, y }
    end
    function f:GetPoint(i)
      local p = points[i or 1]
      if p then return unpack(p, 1, 5) end
    end
    function f:GetNumPoints() return #points end
    function f:ClearAllPoints() points = {} end
    function f:SetSize(width, height) w, h = width, height end
    function f:GetSize() return w, h end
    function f:SetWidth(width) w = width end
    function f:SetHeight(height) h = height end
    function f:GetWidth() return w end
    function f:GetHeight() return h end
    function f:SetParent(p) par = p end
    function f:GetParent() return par end
    function f:GetName() return name end
    function f:CreateFontString() return make_fontstring(f) end
    function f:CreateTexture() return new_object() end
    if name then
      framesByName[name] = true
      _G[name] = f
    end
    return f
  end

  ---------------------------------------------------------------------------
  -- LibStub and Ace3 fakes
  ---------------------------------------------------------------------------
  local libs = {}
  local LibStub = setmetatable({}, { __call = function(self, name, silent) return self:GetLibrary(name, silent) end })
  function LibStub:GetLibrary(name, silent)
    local lib = not missingLibs[name] and libs[name] or nil
    if not lib and not silent then error(('Cannot find a library instance of "%s".'):format(tostring(name)), 2) end
    return lib
  end
  function LibStub:NewLibrary(name)
    if libs[name] then return nil end
    libs[name] = {}
    return libs[name]
  end
  function LibStub:IterateLibraries() return pairs(libs) end

  -- AceEvent: per-object event and message registrations.
  local eventRegs, messageRegs = {}, {}  -- [name] = { [obj] = handler }

  local function register(regs, self, name, handler)
    if handler == nil then handler = name end
    if type(handler) == "string" and type(self[handler]) ~= "function" then
      error(("Cannot register %q: method %q not found on the object"):format(tostring(name), handler), 3)
    elseif type(handler) ~= "string" and type(handler) ~= "function" then
      error("Invalid handler for " .. tostring(name), 3)
    end
    regs[name] = regs[name] or {}
    regs[name][self] = handler
  end

  local function dispatch(regs, name, ...)
    local bucket = regs[name]
    if not bucket then return end
    local snapshot = {}
    for obj, handler in pairs(bucket) do snapshot[#snapshot + 1] = { obj, handler } end
    -- Registration order is not tracked by pairs(); sort by object id for stable output.
    table.sort(snapshot, function(a, b) return (a[1].__order or 0) < (b[1].__order or 0) end)
    for _, entry in ipairs(snapshot) do
      local obj, handler = entry[1], entry[2]
      if bucket[obj] == handler then  -- still registered
        if type(handler) == "string" then obj[handler](obj, name, ...) else handler(name, ...) end
      end
    end
  end

  local function unregister_all(regs, self)
    for _, bucket in pairs(regs) do bucket[self] = nil end
  end

  local AceEvent = {}
  function AceEvent.Embed(_, target)
    function target:RegisterEvent(event, handler) register(eventRegs, self, event, handler) end
    function target:UnregisterEvent(event) if eventRegs[event] then eventRegs[event][self] = nil end end
    function target:UnregisterAllEvents() unregister_all(eventRegs, self) end
    function target:IsEventRegistered(event) return eventRegs[event] ~= nil and eventRegs[event][self] ~= nil end
    function target:RegisterMessage(message, handler) register(messageRegs, self, message, handler) end
    function target:UnregisterMessage(message) if messageRegs[message] then messageRegs[message][self] = nil end end
    function target:UnregisterAllMessages() unregister_all(messageRegs, self) end
    function target:SendMessage(message, ...)
      local rec = { message, ... }
      W.messages[#W.messages + 1] = rec
      dispatch(messageRegs, message, ...)
    end
    return target
  end
  libs["AceEvent-3.0"] = AceEvent

  function W.fire(event, ...) dispatch(eventRegs, event, ...) end

  -- Installs a global that the next install_wow_stubs call removes again (for fakes a helper adds after install).
  function W.defineGlobal(name, value)
    installedNames[name] = true
    _G[name] = value
  end

  -- What obj has registered right now: { events = { name... }, messages = { name... } }, each sorted.
  function W.registrations(obj)
    local function names(regs)
      local out = {}
      for name, bucket in pairs(regs) do
        if bucket[obj] ~= nil then out[#out + 1] = name end
      end
      table.sort(out)
      return out
    end
    return { events = names(eventRegs), messages = names(messageRegs) }
  end

  -- AceConsole
  local AceConsole = {}
  function AceConsole.Embed(_, target)
    function target:RegisterChatCommand(cmd, handler)
      if type(handler) == "string" then
        local obj = self
        W.slash[cmd] = function(...) return obj[handler](obj, ...) end
      else
        W.slash[cmd] = handler
      end
    end
    function target:UnregisterChatCommand(cmd) W.slash[cmd] = nil end
    function target:Print(...) W.printed[#W.printed + 1] = join_args(...) end
    return target
  end
  libs["AceConsole-3.0"] = AceConsole

  -- AceAddon
  local addons, addonOrder, orderCounter = {}, {}, 0

  local function embed_libs(obj, ...)
    for i = 1, select("#", ...) do
      local libname = select(i, ...)
      local lib = LibStub(libname)
      if type(lib.Embed) == "function" then lib:Embed(obj) end
    end
  end

  local addonMethods = {}

  local function new_object_with_methods(name, parent, ...)
    orderCounter = orderCounter + 1
    local obj = { name = name, modules = {}, orderedModules = {}, enabledState = true, __order = orderCounter,
      initialized = false, running = false, parent = parent }
    for k, v in pairs(addonMethods) do obj[k] = v end
    embed_libs(obj, ...)
    return obj
  end

  local function disable_object(obj)
    if not obj.running then return false end
    obj.running = false
    if obj.OnDisable then obj:OnDisable() end
    if obj.running == false then
      if obj.UnregisterAllEvents then obj:UnregisterAllEvents() end
      if obj.UnregisterAllMessages then obj:UnregisterAllMessages() end
      for _, m in ipairs(obj.orderedModules) do disable_object(m) end
    end
    return not obj.running
  end

  local function enable_object(obj)
    if obj.running or not obj.enabledState then return false end
    obj.running = true
    if obj.OnEnable then obj:OnEnable() end
    if obj.running then
      for _, m in ipairs(obj.orderedModules) do enable_object(m) end
    end
    return obj.running
  end

  function addonMethods:NewModule(name, prototype, ...)
    if self.modules[name] then error(("Module %q already exists."):format(tostring(name)), 2) end
    local libsToEmbed = { ... }
    if type(prototype) == "string" then table.insert(libsToEmbed, 1, prototype); prototype = nil end
    local module = new_object_with_methods(name, self, unpack(libsToEmbed))
    if type(prototype) == "table" then
      for k, v in pairs(prototype) do module[k] = v end
    end
    module.IsModule = function() return true end
    self.modules[name] = module
    self.orderedModules[#self.orderedModules + 1] = module
    return module
  end
  function addonMethods:GetModule(name, silent)
    local m = self.modules[name]
    if not m and not silent then error(("Cannot find Module %q."):format(tostring(name)), 2) end
    return m
  end
  function addonMethods:IterateModules() return pairs(self.modules) end
  function addonMethods:SetEnabledState(state) self.enabledState = state and true or false end
  function addonMethods:IsEnabled() return self.enabledState end
  function addonMethods:Enable()
    self:SetEnabledState(true)
    if self.initialized then return enable_object(self) end
  end
  function addonMethods:Disable()
    self:SetEnabledState(false)
    return disable_object(self)
  end
  function addonMethods:GetName() return self.name end

  local AceAddon = {}
  function AceAddon:NewAddon(objectOrName, ...)
    local name = objectOrName
    local obj
    if type(objectOrName) == "table" then
      obj = objectOrName
      name = obj.name
    end
    if addons[name] then error(("Addon %q already exists."):format(tostring(name)), 2) end
    local fresh = new_object_with_methods(name, nil, ...)
    if obj then
      for k, v in pairs(fresh) do if obj[k] == nil then obj[k] = v end end
      -- Re-embed so closures bind to the caller's table.
      embed_libs(obj, ...)
    else
      obj = fresh
    end
    addons[name] = obj
    addonOrder[#addonOrder + 1] = obj
    return obj
  end
  function AceAddon:GetAddon(name, silent)
    local a = addons[name]
    if not a and not silent then error(("Cannot find an AceAddon called %q."):format(tostring(name)), 2) end
    return a
  end
  function AceAddon:IterateAddons() return pairs(addons) end
  libs["AceAddon-3.0"] = AceAddon

  -- Boot: OnInitialize (addon, then its modules depth-first in creation order), then OnEnable.
  local function initialize(obj)
    if obj.initialized then return end
    obj.initialized = true
    if obj.OnInitialize then obj:OnInitialize() end
    for _, m in ipairs(obj.orderedModules) do initialize(m) end
  end

  function W.boot()
    for _, a in ipairs(addonOrder) do initialize(a) end
    for _, a in ipairs(addonOrder) do enable_object(a) end
  end

  -- AceDB
  local AceDB = {}
  local function fill_defaults(dst, defaults)
    for k, v in pairs(defaults) do
      if dst[k] == nil then
        dst[k] = deep_copy(v)
      elseif type(v) == "table" and type(dst[k]) == "table" then
        fill_defaults(dst[k], v)
      end
    end
  end
  local databases = {}
  function AceDB:New(sv, defaults)
    if type(sv) == "string" then
      if _G[sv] == nil then _G[sv] = {} end
      sv = _G[sv]
    end
    sv.global = sv.global or {}
    if defaults and defaults.global then fill_defaults(sv.global, defaults.global) end
    local db = { sv = sv, global = sv.global, defaults = defaults }
    databases[#databases + 1] = db
    return db
  end
  libs["AceDB-3.0"] = AceDB

  -- AceDB's removeDefaults: values equal to their default go, then tables the strip left empty.
  local function strip_defaults(dst, defaults)
    for k, v in pairs(defaults) do
      if type(v) == "table" and type(dst[k]) == "table" then
        strip_defaults(dst[k], v)
        if next(dst[k]) == nil then dst[k] = nil end
      elseif dst[k] == v then
        dst[k] = nil
      end
    end
  end

  -- Simulates PLAYER_LOGOUT: strips the defaults from every database AceDB:New created.
  function W.logout()
    for _, db in ipairs(databases) do
      if db.defaults and db.defaults.global and type(db.sv.global) == "table" then
        strip_defaults(db.sv.global, db.defaults.global)
      end
    end
  end

  -- AceGUI
  local AceGUI = {}
  function AceGUI:Create(widgetType)
    local w = setmetatable({ type = widgetType, frame = CreateFrame("Frame") }, method_stub_meta())
    return w
  end
  libs["AceGUI-3.0"] = AceGUI

  -- AceConfig family
  local AceConfigRegistry = {}
  function AceConfigRegistry:RegisterOptionsTable(app, options)
    W.config.registered[app] = options
  end
  function AceConfigRegistry:NotifyChange() W.config.notified = W.config.notified + 1 end
  function AceConfigRegistry:GetOptionsTable(app)
    local o = W.config.registered[app]
    if type(o) == "function" then return function() return o("dialog", "AceConfigDialog-3.0") end end
    if o then return function() return o end end
  end
  libs["AceConfigRegistry-3.0"] = AceConfigRegistry

  local AceConfig = {}
  function AceConfig:RegisterOptionsTable(app, options) AceConfigRegistry:RegisterOptionsTable(app, options) end
  libs["AceConfig-3.0"] = AceConfig

  local AceConfigDialog = {}
  function AceConfigDialog:Open(app, container)
    W.config.opened[#W.config.opened + 1] = { app = app, container = container }
  end
  function AceConfigDialog:Close() end
  function AceConfigDialog:SelectGroup(app, ...)
    W.config.selected = { app = app, path = { ... } }
  end
  function AceConfigDialog:AddToBlizOptions(app, name)
    W.config.blizOptions[#W.config.blizOptions + 1] = { app = app, name = name }
    return CreateFrame("Frame")
  end
  function AceConfigDialog:SetDefaultSize() end
  libs["AceConfigDialog-3.0"] = AceConfigDialog

  -- LibDataBroker and LibDBIcon
  local LDB = {}
  function LDB:NewDataObject(name, obj)
    if W.ldb.objects[name] then return nil end
    obj = obj or {}
    W.ldb.objects[name] = obj
    return obj
  end
  function LDB:GetDataObjectByName(name) return W.ldb.objects[name] end
  libs["LibDataBroker-1.1"] = LDB

  local DBIcon = {}
  function DBIcon:Register(name, obj, db)
    W.dbicon.registered[name] = { obj = obj, db = db }
    W.dbicon.shown[name] = not (db and db.hide)
  end
  function DBIcon:Show(name) W.dbicon.shown[name] = true end
  function DBIcon:Hide(name) W.dbicon.shown[name] = false end
  function DBIcon:IsRegistered(name) return W.dbicon.registered[name] ~= nil end
  function DBIcon:Refresh() end
  function DBIcon:GetMinimapButton() return nil end
  libs["LibDBIcon-1.0"] = DBIcon

  -- AceComm: the default is inert (RegisterComm stores nothing, SendCommMessage sends nothing). phase4_stubs.lua
  -- replaces Embed with the recording, controllable version.
  local AceComm = {}
  function AceComm.Embed(_, target)
    function target:RegisterComm() end
    function target:UnregisterComm() end
    function target:UnregisterAllComm() end
    function target:SendCommMessage() end
    return target
  end
  libs["AceComm-3.0"] = AceComm

  -- AceLocale, "silent" semantics: a missing key reads as the key itself (no error report); `L[key] = true` stores
  -- the key as its own text. NewLocale returns nil for a non-default locale other than the client's (W.gameLocale).
  W.gameLocale = "enUS"
  local AceLocale, localeApps = {}, {}
  function AceLocale:NewLocale(app, locale, isDefault)
    if not isDefault and locale ~= W.gameLocale then return nil end
    local t = localeApps[app]
    if not t then
      t = setmetatable({}, {
        __index = function(tbl, key) rawset(tbl, key, key); return key end,
        __newindex = function(tbl, key, value) rawset(tbl, key, value == true and key or value) end,
      })
      localeApps[app] = t
    end
    return t
  end
  function AceLocale:GetLocale(app, silent)
    local t = localeApps[app]
    if not t and not silent then error(('Cannot find locale for application "%s".'):format(tostring(app)), 2) end
    return t
  end
  libs["AceLocale-3.0"] = AceLocale

  ---------------------------------------------------------------------------
  -- Auctionator v1 (signatures from Auctionator v321; see plan "Verified facts")
  ---------------------------------------------------------------------------
  local function check_caller(callerID)
    if type(callerID) ~= "string" or callerID == "" then error("Invalid callerID", 3) end
    W.auctionator.lastCallerID = callerID
  end
  local function check_item_id(itemID)
    if type(itemID) ~= "number" then error("Invalid itemID", 3) end
    return itemID
  end
  local function item_id_from_link(link)
    if type(link) ~= "string" then error("Invalid itemLink", 3) end
    return tonumber(link:match("item:(%d+)"))
  end

  local v1 = {}
  function v1.GetAuctionPriceByItemID(callerID, itemID)
    check_caller(callerID); return W.auctionator.prices[check_item_id(itemID)]
  end
  function v1.GetAuctionPriceByItemLink(callerID, itemLink)
    check_caller(callerID); return W.auctionator.prices[item_id_from_link(itemLink)]
  end
  function v1.GetAuctionAgeByItemID(callerID, itemID)
    check_caller(callerID); return W.auctionator.ages[check_item_id(itemID)]
  end
  function v1.GetVendorPriceByItemID(callerID, itemID)
    check_caller(callerID); return W.auctionator.vendor[check_item_id(itemID)]
  end
  function v1.IsAuctionDataExactByItemID(callerID, itemID)
    check_caller(callerID); return W.auctionator.exact[check_item_id(itemID)] and true or false
  end
  function v1.RegisterForDBUpdate(callerID, callback)
    check_caller(callerID)
    if type(callback) ~= "function" then error("Invalid callback", 2) end
    W.auctionator.dbCallbacks[#W.auctionator.dbCallbacks + 1] = callback
  end
  function v1.CreateShoppingList(callerID, name, searchStrings)
    check_caller(callerID)
    if type(name) ~= "string" or type(searchStrings) ~= "table" then error("Invalid shopping list", 2) end
    W.auctionator.lists[name] = searchStrings
  end
  function v1.ConvertToSearchString(callerID, term)
    check_caller(callerID)
    if type(term) ~= "table" or type(term.searchString) ~= "string" then error("Invalid search term", 2) end
    -- The real format is richer; tests only need a deterministic string.
    local s = term.searchString
    if term.isExact then s = '"' .. s .. '"' end
    return s
  end

  function W.removeAuctionator() _G.Auctionator = nil end

  ---------------------------------------------------------------------------
  -- Default globals
  ---------------------------------------------------------------------------
  local emptyList = function() return {} end
  local retNil = function() return nil end
  local retFalse = function() return false end
  local retZero = function() return 0 end

  local TooltipDataProcessor = { postCalls = {} }
  function TooltipDataProcessor.AddTooltipPostCall(dataType, fn)
    TooltipDataProcessor.postCalls[#TooltipDataProcessor.postCalls + 1] = { dataType = dataType, fn = fn }
  end

  -- hooksecurefunc([tbl,] name, fn): replaces tbl[name] (or _G[name]) with a function that calls the
  -- original, then fn with the same arguments, and returns the original's results. Like the client it
  -- errors when the target is not a function; hooks cannot be removed. The replacement is rawset: the
  -- client's secure hook is not an addon write, so fakes that record field writes (professions_frame.lua)
  -- do not see it.
  local function pack(...) return { n = select("#", ...), ... } end
  local function hooksecurefunc(a, b, c)
    local tbl, name, fn
    if type(a) == "table" then tbl, name, fn = a, b, c else name, fn = a, b end
    local usage = 'Usage: hooksecurefunc([table,] "function", hookfunc)'
    if type(name) ~= "string" or type(fn) ~= "function" then error(usage, 2) end
    local target = tbl or _G
    local original = target[name]
    if type(original) ~= "function" then error(usage .. ": " .. name .. " is not a function", 2) end
    rawset(target, name, function(...)
      local results = pack(original(...))
      fn(...)
      return unpack(results, 1, results.n)
    end)
    W.hooks[#W.hooks + 1] = { tbl, name, fn }
  end

  -- ScrollUtil (Blizzard_SharedXML, always loaded): like ScrollUtil.lua, AddAcquiredFrameCallback /
  -- AddInitializedFrameCallback / AddReleasedFrameCallback register callback(owner, frame, elementData[, new]) on the
  -- box's OnAcquiredFrame / OnInitializedFrame / OnReleasedFrame event (ScrollBoxListMixin.Event when a fake
  -- Professions frame defined it). A box without RegisterCallback (a plain table) is ignored. iterateExisting is not
  -- supported.
  local function scroll_event(key)
    local mixin = rawget(_G, "ScrollBoxListMixin")
    return type(mixin) == "table" and type(mixin.Event) == "table" and mixin.Event[key] or key
  end
  local function add_scroll_callback(key)
    return function(scrollBox, callback, owner)
      if type(scrollBox) ~= "table" or type(scrollBox.RegisterCallback) ~= "function" then return end
      scrollBox:RegisterCallback(scroll_event(key), function(o, ...) callback(o, ...) end, owner)
    end
  end
  local ScrollUtil = {
    AddAcquiredFrameCallback = add_scroll_callback("OnAcquiredFrame"),
    AddInitializedFrameCallback = add_scroll_callback("OnInitializedFrame"),
    AddReleasedFrameCallback = add_scroll_callback("OnReleasedFrame"),
  }

  local globals = {
    C_TradeSkillUI = {
      GetRecipeSchematic = retNil, GetRecipeInfo = retNil, GetCraftingOperationInfo = retNil,
      GetConcentrationCurrencyID = retZero, GetChildProfessionInfo = retNil, GetChildProfessionInfos = emptyList,
      GetProfessionInfoByRecipeID = retNil, GetProfessionInfoBySkillLineID = retNil, GetProfessionSlots = emptyList,
      GetItemReagentQualityByItemInfo = retNil, IsNPCCrafting = retFalse, GetRecipeCooldown = retNil,
      GetFilteredRecipeIDs = emptyList, IsTradeSkillReady = retFalse, IsTradeSkillLinked = retFalse,
      IsTradeSkillGuild = retFalse, CraftRecipe = noop, GetItemCraftedQualityByItemInfo = retNil,
      -- the other craft entry points the Ledger post-hooks (it logs a missing target once)
      RecraftRecipe = noop, RecraftRecipeForOrder = noop, CraftEnchant = noop, CraftSalvage = noop,
    },
    C_CraftingOrders = {
      ClaimOrder = retNil, FulfillOrder = retNil, GetClaimedOrder = retNil, GetCrafterOrders = emptyList,
      GetCraftingOrderTime = retZero, GetPersonalOrdersInfo = emptyList, GetOrderClaimInfo = retNil,
    },
    C_DateAndTime = { GetSecondsUntilWeeklyReset = retZero, GetCurrentCalendarTime = retNil },
    -- phase 3 (preflight row 14): safe defaults so full loads boot Alts/Planner without errors.
    C_QuestLog = { IsQuestFlaggedCompleted = retFalse },
    C_Spell = { GetSpellName = retNil },
    GetCurrentRegion = function() return 1 end,
    C_Item = { GetItemCount = retZero, GetItemNameByID = retNil, RequestLoadItemDataByID = noop },
    C_CurrencyInfo = {
      GetCurrencyInfo = retNil, GetCurrencyListInfo = retNil, GetCurrencyListLink = retNil,
      GetCurrencyListSize = retZero,
    },
    C_ProfSpecs = {
      GetConfigIDForSkillLine = retZero, GetSpecTabIDsForSkillLine = emptyList, SkillLineHasSpecialization = retFalse,
      GetTabInfo = retNil, GetChildrenForPath = emptyList, GetPerksForPath = emptyList,
      GetUnlockRankForPerk = retNil,
    },
    C_Traits = { GetNodeInfo = retNil, GetEntryInfo = retNil, GetDefinitionInfo = retNil, GetTreeCurrencyInfo = emptyList },
    C_Container = { GetContainerNumSlots = retZero, GetContainerItemInfo = retNil },
    C_Bank = { CanViewBank = retFalse },
    C_AddOns = { IsAddOnLoaded = retFalse, DoesAddOnExist = retFalse, GetAddOnMetadata = function() return "@project-version@" end },
    -- phase 4 (preflight row 3): safe-empty defaults so full loads boot Guild, ChatScan and Onboarding.
    C_ChatInfo = {
      InChatMessagingLockdown = retFalse, AreOutgoingAddonChatMessagesRestricted = retFalse,
      RegisterAddonMessagePrefix = function() return true end,
      SendChatMessage = function() error("auto-send forbidden", 2) end,
    },
    C_RestrictedActions = { IsAddOnRestrictionActive = retFalse },
    C_EncodingUtil = {},  -- no codec: Codec.IsAvailable() is false until phase4_stubs.lua installs the reversible fake
    C_GuildInfo = { GuildRoster = noop, MemberExistsByName = function() return true end, QueryGuildMembersForRecipe = retNil },
    C_FriendList = { IsIgnored = retFalse },
    IsInGuild = retFalse, GetGuildInfo = retNil, GetNumGuildMembers = retZero, InCombatLockdown = retFalse,
    IsInInstance = function() return false, "none" end,
    issecretvalue = retFalse,
    Ambiguate = function(name) return name end,
    SendChatMessage = function() error("auto-send forbidden", 2) end,
    ChatFrameUtil = {
      SendTell = function(name) W.tells[#W.tells + 1] = { name } end,
      SendTellWithMessage = function(name, text) W.tells[#W.tells + 1] = { name, text } end,
    },
    C_Timer = C_Timer,
    Enum = {
      CraftingReagentType = { Modifying = 0, Basic = 1, Finishing = 2, Automatic = 3 },
      TradeskillSlotDataType = { Reagent = 1, ModifiedReagent = 2 },
      BagIndex = {
        Backpack = 0, Bag_1 = 1, Bag_2 = 2, Bag_3 = 3, Bag_4 = 4, ReagentBag = 5,
        CharacterBankTab_1 = 6, CharacterBankTab_2 = 7, CharacterBankTab_3 = 8, CharacterBankTab_4 = 9,
        CharacterBankTab_5 = 10, CharacterBankTab_6 = 11,
        AccountBankTab_1 = 12, AccountBankTab_2 = 13, AccountBankTab_3 = 14, AccountBankTab_4 = 15,
        AccountBankTab_5 = 16,
      },
      BankType = { Character = 0, Account = 2 },
      ProfessionsSpecPathState = { Locked = 0, Progressing = 1, Completed = 2 },
      ProfessionsSpecPerkState = { Unearned = 0, Earned = 1, Pending = 2 },
      TooltipDataType = { Item = 0 },
      -- phase 4, from wow-ui-source live @ 12.1.5 (70688)
      CompressionMethod = { Deflate = 0, Zlib = 1, Gzip = 2 },
      AddOnRestrictionType = { Combat = 0, Encounter = 1, ChallengeMode = 2, PvPMatch = 3, Map = 4, Chat = 5 },
      AddOnRestrictionState = { Inactive = 0, Activating = 1, Active = 2 },
      SendAddonMessageResult = { Success = 0, InvalidPrefix = 1, InvalidMessage = 2, AddonMessageThrottle = 3,
        InvalidChatType = 4, NotInGroup = 5, TargetRequired = 6, InvalidChannel = 7, ChannelThrottle = 8,
        GeneralError = 9, NotInGuild = 10, AddOnMessageLockdown = 11, TargetOffline = 12 },
    },
    TooltipDataProcessor = TooltipDataProcessor,
    hooksecurefunc = hooksecurefunc,
    GetInboxInvoiceInfo = retNil, GetInboxHeaderInfo = retNil, TakeInboxMoney = noop, AutoLootMailItem = noop,
    PlaySound = noop,
    SOUNDKIT = { RAID_WARNING = 8959, TELL_MESSAGE = 3081 },
    ScrollUtil = ScrollUtil,
    LibStub = LibStub,
    ButtonFrameTemplate_HidePortrait = noop,
    ButtonFrameTemplate_HideButtonBar = noop,
    -- Unfloored on purpose; see "Deliberate divergences" at the top of this file.
    time = function() return W.now end,
    GetServerTime = function() return W.now end,
    GetBuildInfo = function() return "12.1.5", "70575", "Oct 23 2026", 120105 end,
    UnitName = function() return "Thrall" end,
    UnitClass = function() return "Mage", "MAGE", 8 end,
    GetRealmName = function() return "Argent Dawn" end,
    GetNormalizedRealmName = function() return "ArgentDawn" end,
    GetMoney = retZero,
    GetInventoryItemLink = retNil,
    CreateFrame = CreateFrame,
    UIParent = CreateFrame("Frame", "UIParent"),
    UISpecialFrames = {},
    print = function(...) W.printed[#W.printed + 1] = join_args(...) end,
    debugstack = function() return "stack traceback:\n\t[stub]" end,
    date = os.date,
    strsplit = strsplit,
    strtrim = strtrim,
    geterrorhandler = function() return function(err) W.errors[#W.errors + 1] = err end end,
    wipe = function(t) for k in pairs(t) do t[k] = nil end return t end,
    tinsert = table.insert,
    tremove = table.remove,
    Auctionator = { API = { v1 = v1 } },
  }
  framesByName.UIParent = nil  -- UIParent is installed through `globals` and tracked below

  deep_merge(globals, overrides)
  for name, value in pairs(globals) do
    installedNames[name] = true
    _G[name] = value
  end
  -- Frames created by CreateFrame while building defaults/overrides are tracked in framesByName.
  return W
end

return install
