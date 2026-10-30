local _, ns = ...

local FS = LibStub("AceAddon-3.0"):NewAddon("FabricationStation", "AceEvent-3.0", "AceConsole-3.0")
ns.FS = FS

local MAX_ERRORS = 50
FS.MAX_ERRORS = MAX_ERRORS

FS.pendingErrors = {}      -- errors logged before the DB exists; Task 4's InitDB flushes them
FS.failedModules = {}      -- [moduleName] = errText
FS.slashCommands = {}      -- [name] = { fn = function(argString), help = string }

local announced = {}       -- modules already announced as failed this session
local debounceTimers = {}  -- [key] = C_Timer handle
local notify_options_changed  -- defined with the options registry below

---------------------------------------------------------------------------
-- Identity and time
---------------------------------------------------------------------------

function FS:CharKey()
  local realm = GetNormalizedRealmName()
  if not realm then realm = (GetRealmName() or ""):gsub("[%s%-]", "") end
  return UnitName("player") .. "-" .. realm
end

function FS:Now()
  return GetServerTime()
end

---------------------------------------------------------------------------
-- Error isolation
---------------------------------------------------------------------------

-- stack is optional; SafeCall passes the stack captured at the point of the error.
function FS:LogError(source, errText, stack)
  local entry = { time = self:Now(), source = source, err = errText, stack = stack }
  local db = self.db
  local list
  -- A database from a newer version is never written to; errors stay in memory for this session.
  if db and db.global and not self.dbIsNewer then
    db.global.diagnostics = db.global.diagnostics or {}
    list = db.global.diagnostics.errors
    if not list then list = {}; db.global.diagnostics.errors = list end
  else
    list = self.pendingErrors
  end
  ns.Util.PushCapped(list, entry, MAX_ERRORS)
end

-- Records the failure and notifies first, then disables inside pcall, so a throwing OnDisable can
-- never stop the bookkeeping or escape SafeCall.
local function disable_failed_module(self, moduleName, errText)
  local module = self:GetModule(moduleName, true)
  if not (module and module:IsEnabled()) then return end
  self.failedModules[moduleName] = errText
  self:SendMessage(ns.Msg.MODULE_FAILED, moduleName, errText)
  if not announced[moduleName] then
    announced[moduleName] = true
    print(("FabricationStation: %s stopped after an error and was turned off. "
      .. "Turn it back on in /fs settings > Modules > Stopped modules; the error is in Diagnostics."):format(moduleName))
  end
  local ok, disableErr = pcall(module.Disable, module)
  if not ok then self:LogError(moduleName, tostring(disableErr)) end
  notify_options_changed()
end

local function finish(self, moduleName, stack, ok, ...)
  if ok then return true, ... end
  local errText = tostring((...))
  self:LogError(moduleName, errText, stack)
  disable_failed_module(self, moduleName, errText)
  return false, errText
end

-- Runs fn(...) under xpcall. Returns true plus fn's results, or false plus the error text.
-- If moduleName names an enabled module, that module is disabled and announced; any other name
-- (for example "Tab:x") is only logged.
function FS:SafeCall(moduleName, fn, ...)
  local n, args, stack = select("#", ...), { ... }, nil
  local function handler(err)
    stack = debugstack and debugstack(2) or nil
    return err
  end
  local function run(ok, ...)
    return finish(self, moduleName, stack, ok, ...)
  end
  return run(xpcall(function() return fn(unpack(args, 1, n)) end, handler))
end

function FS:Wrap(moduleName, fn)
  return function(...) return self:SafeCall(moduleName, fn, ...) end
end

---------------------------------------------------------------------------
-- Debounce
---------------------------------------------------------------------------

-- Trailing debounce: each call replaces the pending timer for key. Errors in fn are not isolated;
-- callers pass a Wrap()ped function.
function FS:Debounce(key, seconds, fn)
  local pending = debounceTimers[key]
  if pending then pending:Cancel() end
  local timer
  timer = C_Timer.NewTimer(seconds, function()
    if debounceTimers[key] == timer then debounceTimers[key] = nil end
    fn()
  end)
  debounceTimers[key] = timer
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

function FS:RegisterSlash(name, fn, helpText)
  self.slashCommands[name:lower()] = { fn = fn, help = helpText }
end

local function print_help(self)
  local names = {}
  for name in pairs(self.slashCommands) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local cmd = self.slashCommands[name]
    local label = name == "" and "/fs" or ("/fs " .. name)
    print(label .. " - " .. (cmd.help or ""))
  end
end

function FS:HandleSlash(input)
  local word, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
  word = word:lower()
  local cmd = self.slashCommands[word]
  if word == "help" or not cmd then
    print_help(self)
    return
  end
  local ok = self:SafeCall("Slash:" .. word, cmd.fn, rest)
  if not ok then
    print("FabricationStation: /fs " .. word .. " failed. See /fs settings > Diagnostics.")
  end
end

---------------------------------------------------------------------------
-- Options registry
---------------------------------------------------------------------------

FS.optionGroups = {}   -- [key] = AceConfig group table
local optionsLive = false  -- true once the options table is registered with AceConfig

function notify_options_changed()
  if optionsLive then LibStub("AceConfigRegistry-3.0"):NotifyChange("FabricationStation") end
end

function FS:RegisterOptions(key, group)
  self.optionGroups[key] = group
  notify_options_changed()
end

function FS:GetOptionsTable()
  if self.modulesGroup then self.modulesGroup.args = self:BuildModuleToggles() end
  local args = {}
  for key, group in pairs(self.optionGroups) do args[key] = group end
  return { type = "group", name = "FabricationStation", childGroups = "tab", args = args }
end

---------------------------------------------------------------------------
-- Module toggles
---------------------------------------------------------------------------

-- Turns off every module the user switched off in a previous session. Run before modules enable.
function FS:ApplyModuleSettings()
  local stored = self.db.global.settings.modules
  for name, module in self:IterateModules() do
    if stored[name] == false and not module.coreModule then module:SetEnabledState(false) end
  end
end

-- Enables or disables a module now and remembers the choice. Returns false for an unknown module
-- and for an attempt to disable a core module. A core module can be enabled (to recover from a
-- failure); that choice is not stored. Nothing is stored while the saved data is from a newer version.
function FS:SetModuleEnabled(name, enabled)
  local module = self:GetModule(name, true)
  if not module then return false end
  enabled = enabled and true or false
  if module.coreModule and not enabled then return false end
  if not module.coreModule and not self.dbIsNewer then self.db.global.settings.modules[name] = enabled end
  if enabled then
    self.failedModules[name] = nil
    module:Enable()
  else
    module:Disable()
  end
  notify_options_changed()
  return true
end

local STOPPED_ORDER = 1000  -- the stopped-modules section goes after every toggle

-- Adds the "Stopped modules" section: every module in failedModules, core modules included, with
-- its error and a "Turn on again" button. Nothing is added while no module has failed.
local function add_stopped_modules(self, args)
  local names = {}
  for name in pairs(self.failedModules) do
    if self:GetModule(name, true) then names[#names + 1] = name end
  end
  if #names == 0 then return end
  table.sort(names)
  args.stoppedHeader = { type = "header", order = STOPPED_ORDER, name = "Stopped modules" }
  for i, name in ipairs(names) do
    local order = STOPPED_ORDER + i * 2
    args["stopped_" .. name] = {
      type = "description", order = order, width = "double",
      name = ("%s stopped after an error: %s"):format(name, tostring(self.failedModules[name])),
    }
    -- Wrapped under the module's name: if it fails again while enabling, it is stopped again and
    -- listed here again instead of the error escaping into the options dialog.
    args["turnOn_" .. name] = {
      type = "execute", order = order + 1, name = "Turn on again",
      func = self:Wrap(name, function() self:SetModuleEnabled(name, true) end),
    }
  end
end

-- The Modules group's args: a toggle per optional module (or a note that there are none yet),
-- then the stopped-modules section.
function FS:BuildModuleToggles()
  local names = {}
  for name, module in self:IterateModules() do
    if not module.coreModule then names[#names + 1] = name end
  end
  table.sort(names)
  local args = {}
  for i, name in ipairs(names) do
    args[name] = {
      type = "toggle", order = i,
      name = self.failedModules[name] and (name .. " (stopped after an error)") or name,
      get = function() return self:GetModule(name):IsEnabled() end,
      set = function(_, value) self:SetModuleEnabled(name, value) end,
    }
  end
  if #names == 0 then args.none = { type = "description", order = 1, name = "No optional modules yet." } end
  add_stopped_modules(self, args)
  return args
end

---------------------------------------------------------------------------
-- General options
---------------------------------------------------------------------------

-- One line describing the generated game data. "Not generated" is checked first: the checked-in
-- generated tables carry no build while GameData_Manual is stamped, so Build() can equal the
-- client build while the generated tables are still missing.
function FS:GameDataStatusText()
  local gameData = ns.GameData
  local clientBuild = tonumber((select(2, GetBuildInfo())))
  local status = gameData and gameData.Status(clientBuild)
  if not status or status.missing then return "GameData not generated" end
  if status.outdated then
    return ("GameData is outdated: data build %s, game build %s"):format(tostring(status.build), tostring(clientBuild))
  end
  if #status.mismatched > 0 then
    return "GameData tables are from different builds: " .. table.concat(status.mismatched, ", ")
  end
  return ("GameData: build %s, up to date"):format(tostring(status.build))
end

local function build_general_group(self)
  return {
    type = "group", name = "General", order = 10,
    args = {
      minimap = {
        type = "toggle", order = 1, width = "full", name = "Show minimap button",
        get = function()
          local launcher = self:GetModule("Launcher", true)
          return launcher == nil or launcher:IsMinimapShown()
        end,
        set = function(_, value)
          local launcher = self:GetModule("Launcher", true)
          if launcher then launcher:SetMinimapShown(value) end
        end,
      },
      gamedata = {
        type = "description", order = 2, fontSize = "medium",
        name = function() return self:GameDataStatusText() end,
      },
    },
  }
end

function FS:OnInitialize()
  self:RegisterChatCommand("fs", "HandleSlash")
  self:RegisterChatCommand("fabstation", "HandleSlash")
  self:InitDB()
  self:ApplyModuleSettings()
  self:RegisterOptions("general", build_general_group(self))
  self.modulesGroup = { type = "group", name = "Modules", order = 90, args = {} }
  self:RegisterOptions("modules", self.modulesGroup)
  LibStub("AceConfig-3.0"):RegisterOptionsTable("FabricationStation", function() return ns.FS:GetOptionsTable() end)
  optionsLive = true
end
