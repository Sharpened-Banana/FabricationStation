local ADDON_NAME, ns = ...
local L = ns.L

-- MailGold (phase 7 Task 21): tells the player in chat how much gold they took from the mailbox.
--
-- While the mailbox is open (MAIL_SHOW .. MAIL_CLOSED, or the interaction manager hiding the mail frame) every
-- positive change of GetMoney() seen on PLAYER_MONEY is gold taken from mail. A fall (a COD payment, postage) is never
-- counted and never subtracted: the baseline just follows it down. Nothing outside an open mailbox counts, and an
-- unknown GetMoney() is never 0: the next known value only becomes the new baseline.
--
-- Gains are summed and printed once, 1.5 s after the last one, as "Took <money> from the mail" (the money formatter the
-- header gold uses). Closing the mailbox prints a pending line first, then, when more than one line was printed during
-- the visit and `showTotal` is on, "Mail total this visit: <money>". A visit without a gain prints nothing.
--
-- A pickup is the player's own click on Blizzard's mail window. This module only reads events and GetMoney(): it hooks
-- no mail function and sends no chat (the line goes through ns.FS:Print, which only the player sees). It saves nothing
-- but its settings, which are read through ns.Util.SettingsAccessor (a session-only copy while the saved data is from a
-- newer version, so nothing is created or written then). Every handler runs through ns.FS:Wrap("MailGold", ...); the
-- one timer is the Debounce key "mailGold.print", cancelled in OnDisable.
--
-- A MAIL_SHOW while the mailbox is already open ends that visit first (its pending line and total are printed). Turned
-- off, the module drops a gain it has not printed yet. Turned on while the mailbox is already open, the module starts
-- counting at the next MAIL_SHOW. In game: P7-37.
local MailGold = ns.FS:NewModule("MailGold", "AceEvent-3.0")

MailGold.SETTINGS_DEFAULTS = { showTotal = true }
MailGold.PRINT_DELAY = 1.5

local PRINT_KEY = "mailGold.print"

local open = false       -- MAIL_SHOW seen and no close since
local baseline           -- GetMoney() at the last read (nil: unknown)
local pendingGain = 0    -- gold taken since the last printed line
local lines = 0          -- lines printed this visit
local visitTotal = 0     -- gold in the lines printed this visit

local settingsTable = ns.Util.SettingsAccessor("mailGold")

local function fill(target, defaults)
  for key, default in pairs(defaults) do
    if type(target[key]) ~= type(default) then target[key] = default end
  end
  return target
end

function MailGold:Settings()
  return settingsTable(self.SETTINGS_DEFAULTS, fill)
end

local function money_now()
  if type(GetMoney) ~= "function" then return nil end
  local ok, value = pcall(GetMoney)
  if ok and type(value) == "number" and value == value then return value end
  return nil
end

-- The header gold's formatter (ns.UI loads after the modules, so it is looked up when needed).
local function format_money(copper)
  local ui = ns.UI
  if type(ui) == "table" and type(ui.FormatMoney) == "function" then return ui.FormatMoney(copper) end
  return tostring(copper) .. "c"
end

local function reset_visit()
  baseline, pendingGain, lines, visitTotal = nil, 0, 0, 0
  ns.FS:CancelDebounce(PRINT_KEY)
end

-- Prints the gold taken since the last line (nothing when there is none).
local function flush()
  ns.FS:CancelDebounce(PRINT_KEY)
  if pendingGain <= 0 then return end
  local amount = pendingGain
  pendingGain = 0
  lines = lines + 1
  visitTotal = visitTotal + amount
  ns.FS:Print(L["Took %s from the mail"]:format(format_money(amount)))
end

local on_close

-- MAIL_SHOW: a new visit. Shown again while still open (no close event came), the old visit ends first, so its
-- pending gain and its total are printed, not dropped.
local function on_show()
  if open then on_close() end
  reset_visit()
  open = true
  baseline = money_now()
end

local function on_money()
  if not open then return end
  local now = money_now()
  if now and baseline and now > baseline then
    pendingGain = pendingGain + (now - baseline)
    ns.FS:Debounce(PRINT_KEY, MailGold.PRINT_DELAY, ns.FS:Wrap("MailGold", flush))
  end
  baseline = now
end

on_close = function()
  if not open then return end
  open = false
  flush()
  if lines > 1 and MailGold:Settings().showTotal then
    ns.FS:Print(L["Mail total this visit: %s"]:format(format_money(visitTotal)))
  end
  reset_visit()
end

-- The mailbox type of PLAYER_INTERACTION_MANAGER_FRAME_HIDE, when the client has it.
local function is_mailbox_type(kind)
  local types = type(Enum) == "table" and Enum.PlayerInteractionType
  return type(types) == "table" and types.MailInfo ~= nil and kind == types.MailInfo
end

function MailGold:OnEnable()
  local function wrap(fn) return ns.FS:Wrap("MailGold", fn) end
  -- Registered protected: a client that does not know an event must not stop the module.
  local function register(event, handler)
    if not pcall(self.RegisterEvent, self, event, wrap(handler)) then
      ns.FS:LogError("MailGold", event .. " not found in this client; what depends on that event is not shown")
    end
  end
  register("MAIL_SHOW", on_show)
  register("PLAYER_MONEY", on_money)
  register("MAIL_CLOSED", on_close)
  register("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(_, kind)
    if is_mailbox_type(kind) then on_close() end
  end)
end

function MailGold:OnDisable()
  self:UnregisterAllEvents()
  open = false
  reset_visit()
end

---------------------------------------------------------------------------
-- Options (Settings tab and Blizzard's AddOns panel), just after "Orders & Ledger" (order 40)
---------------------------------------------------------------------------

local function read_only() return ns.FS.dbIsNewer == true end

function MailGold.BuildOptions()
  return {
    type = "group", name = L["Mail gold"], order = 41,
    args = {
      enabled = {
        type = "toggle", order = 1, width = "full", name = L["Show the gold you take from the mailbox in chat"],
        get = function()
          local module = ns.FS:GetModule("MailGold", true)
          return module ~= nil and module:IsEnabled()
        end,
        set = function(_, value) ns.FS:SetModuleEnabled("MailGold", value) end,
      },
      showTotal = {
        type = "toggle", order = 2, width = "full", name = L["Show a total when you close the mailbox"],
        desc = L["Adds one line with all the gold you took during the visit, when you took gold more than once."],
        disabled = read_only,
        get = function() return MailGold:Settings().showTotal == true end,
        set = function(_, value) MailGold:Settings().showTotal = value and true or false end,
      },
    },
  }
end

ns.FS:RegisterOptions("mailGold", MailGold.BuildOptions())
