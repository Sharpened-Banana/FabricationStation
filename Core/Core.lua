local _, ns = ...

local FS = LibStub("AceAddon-3.0"):NewAddon("FabricationStation", "AceEvent-3.0", "AceConsole-3.0")
ns.FS = FS

local MAX_ERRORS = 50

FS.pendingErrors = {}      -- errors logged before the DB exists; Task 4's InitDB flushes them
FS.failedModules = {}      -- [moduleName] = errText
FS.slashCommands = {}      -- [name] = { fn = function(argString), help = string }

local announced = {}       -- modules already announced as failed this session
local debounceTimers = {}  -- [key] = C_Timer handle

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
  if db and db.global then
    db.global.diagnostics = db.global.diagnostics or {}
    list = db.global.diagnostics.errors
    if not list then list = {}; db.global.diagnostics.errors = list end
  else
    list = self.pendingErrors
  end
  ns.Util.PushCapped(list, entry, MAX_ERRORS)
end

local function disable_failed_module(self, moduleName, errText)
  local module = self:GetModule(moduleName, true)
  if not (module and module:IsEnabled()) then return end
  module:Disable()
  self.failedModules[moduleName] = errText
  self:SendMessage(ns.Msg.MODULE_FAILED, moduleName, errText)
  if not announced[moduleName] then
    announced[moduleName] = true
    print(("FabricationStation: %s stopped after an error and was turned off. See /fs settings > Diagnostics.")
      :format(moduleName))
  end
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

function FS:OnInitialize()
  self:RegisterChatCommand("fs", "HandleSlash")
  self:RegisterChatCommand("fabstation", "HandleSlash")
end
