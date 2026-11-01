local ADDON_NAME, ns = ...
local L = ns.L

-- OrdersOptions: the "Orders & Ledger" settings group (Settings tab and Blizzard's AddOns panel, through 1a's
-- RegisterOptions). Four subgroups:
--   Order scoring          Orders:Settings(): money in gold (stored as integer copper), the expiring-soon window in
--                          minutes, the Claim Best minimum score and one toggle per claim-blocking risk; the most
--                          you pay per knowledge point and per Moxie (empty = no limit); and a group "Unknown
--                          rewards" with one gold input per reward Orders could not value (rewardOverrides).
--   Crafting-orders window shortcuts to 1a's module switches for OrdersRowAddons, OrdersSidePanel and
--                          OrderViewWarning (ns.FS:SetModuleEnabled; the same switches Settings > Modules shows), and
--                          the Orders:Settings() toggle for the reward and reagent icons on the order rows.
--   Alerts                 OrderAlert:Settings(): sound and toast on a personal order, which sound, toast seconds.
--   Ledger                 Ledger:Settings(): benchmark sample minimum and how many days of entries to keep; under a
--                          "Sale log" header SaleLog:Settings(): the history window (7..365 days, for the Ledger's
--                          Auctions page and the item tooltip) and whether item tooltips show your sales.
--
-- Every setter writes through the owning module's Settings() table, never into db.global directly: while the saved
-- data is from a newer version (ns.FS.dbIsNewer) Settings() is a session-only copy, so nothing is saved, and the
-- editable options are shown disabled so the user can see why. Values are checked (a number, finite) and clamped to
-- the option's range. A scoring change rescores the board (Orders:ScheduleRescore: one Orders:Rescore 0.5 s after the
-- last change, which also refreshes the Orders views); it runs through ns.FS:Wrap("Orders", ...) so a failure turns
-- off Orders instead of escaping into the dialog.
-- A ledger change only asks the Ledger views to redraw (FS_LEDGER_CHANGED): a shorter keepDays never deletes rows
-- here (the Ledger prunes on its own schedule).
local M = {}
ns.UI = ns.UI or {}
ns.UI.OrdersOptions = M

local COPPER_PER_GOLD = 10000
local SECONDS_PER_MINUTE = 60
local DEFAULT_SOUND = "RAID_WARNING"

-- SOUNDKIT keys offered for the alert, with their labels; only the ones the client has are listed.
M.SOUNDS = {
  { key = "RAID_WARNING", label = L["Raid warning"] },
  { key = "READY_CHECK", label = L["Ready check"] },
  { key = "UI_PROFESSIONS_NEW_RECIPE_LEARNED", label = L["New recipe learned"] },
}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function module_of(name) return ns.FS:GetModule(name, true) end

-- The module's settings table (Settings() fills defaults; a session-only copy while read-only), or nil.
local function settings_of(name)
  local module = module_of(name)
  if module and module.Settings then return module:Settings() end
end

local function read_only() return ns.FS.dbIsNewer == true end

local function is_finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

local function round(v) return math.floor(v + 0.5) end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- Editable while the saved data is ours and the owning module exists.
local function disabled_for(name)
  return function() return read_only() or module_of(name) == nil end
end

-- After a scoring change: rescore the board while Orders is on, through Orders:ScheduleRescore (0.5 s after the last
-- change, sharing Orders' own debounce key, so a slider drag costs one rescore). Orders checks it is still on when
-- the rescore runs; a failure turns off Orders (1a's SafeCall through Wrap).
local function rescore()
  local orders = module_of("Orders")
  if orders and orders.ScheduleRescore and orders:IsEnabled() then orders:ScheduleRescore() end
end

local function ledger_changed()
  local ledger = module_of("Ledger")
  if ledger and ledger.SendMessage then ledger:SendMessage(ns.Msg.LEDGER_CHANGED) end
end

-- A shorter or longer sale history window changes the Auctions page: ask its views to redraw.
local function salelog_changed()
  local saleLog = module_of("SaleLog")
  if saleLog and saleLog.SendMessage then saleLog:SendMessage(ns.Msg.SALELOG_CHANGED) end
end

-- A range option over settings_of(moduleName)[key]. scale converts stored -> shown (shown = stored / scale);
-- stored values are rounded to whole units. after() runs once a value was stored.
local function range(spec)
  local scale = spec.scale or 1
  return {
    type = "range", order = spec.order, name = spec.name, desc = spec.desc, width = "full",
    min = spec.min, max = spec.max, softMin = spec.softMin, softMax = spec.softMax,
    step = spec.step or 1, bigStep = spec.bigStep,
    disabled = disabled_for(spec.module),
    get = function()
      local s = settings_of(spec.module)
      local v = s and s[spec.key]
      if type(v) ~= "number" then return nil end
      return v / scale
    end,
    set = function(_, value)
      if not is_finite(value) then return end
      local s = settings_of(spec.module)
      if not s then return end
      s[spec.key] = round(clamp(value, spec.min, spec.max) * scale)
      if spec.after then spec.after() end
    end,
  }
end

-- A toggle over settings_of(moduleName)[key] (or a nested table chosen by path(settings)).
local function toggle(spec)
  local function target()
    local s = settings_of(spec.module)
    if s and spec.path then return spec.path(s) end
    return s
  end
  return {
    type = "toggle", order = spec.order, name = spec.name, desc = spec.desc, width = "full",
    disabled = disabled_for(spec.module),
    get = function()
      local t = target()
      return t ~= nil and t[spec.key] == true
    end,
    set = function(_, value)
      local t = target()
      if not t then return end
      t[spec.key] = value and true or false
      if spec.after then spec.after() end
    end,
  }
end

---------------------------------------------------------------------------
-- Order scoring
---------------------------------------------------------------------------

local function gold(order, key, name, desc, limits)
  return range({
    module = "Orders", key = key, order = order, name = name, desc = desc, scale = COPPER_PER_GOLD,
    min = limits.min or 0, max = limits.max or 100000, softMin = limits.softMin, softMax = limits.softMax,
    step = 0.01, bigStep = limits.bigStep or 1, after = rescore,
  })
end

-- Copper -> the text a money input shows, always plain (never GetMoneyString's coin markup): whole gold as "50",
-- else "2g 50s" (the non-zero units). ns.UI.ParseMoney reads both back.
local function money_text(copper)
  if type(copper) ~= "number" then return "" end
  copper = math.floor(copper)
  if copper % COPPER_PER_GOLD == 0 then return tostring(copper / COPPER_PER_GOLD) end
  local whole = math.floor(copper / COPPER_PER_GOLD)
  local silver = math.floor((copper % COPPER_PER_GOLD) / 100)
  local rest = copper % 100
  local parts = {}
  if whole > 0 then parts[#parts + 1] = ("%dg"):format(whole) end
  if silver > 0 then parts[#parts + 1] = ("%ds"):format(silver) end
  if rest > 0 then parts[#parts + 1] = ("%dc"):format(rest) end
  return table.concat(parts, " ")
end

-- A text input over a copper amount kept by store(settings, copper|nil). `name` is a string or a function. Empty clears it; text that is not money
-- (or is negative) is ignored. `current(settings)` gives the stored copper. after() runs once a change was stored.
local function money_input(spec)
  return {
    type = "input", order = spec.order, name = spec.name, desc = spec.desc, width = "full",
    disabled = disabled_for("Orders"),
    get = function()
      local s = settings_of("Orders")
      return s and money_text(spec.current(s)) or ""
    end,
    set = function(_, text)
      local s = settings_of("Orders")
      if not s then return end
      local copper
      if type(text) == "string" and text:match("^%s*$") then
        copper = nil
      else
        copper = ns.UI.ParseMoney(text)
        if copper == nil then return end
      end
      spec.store(s, copper)
      if spec.after then spec.after() end
    end,
  }
end

local function reward_limit(order, kind, name, desc)
  return money_input({
    order = order, name = name, desc = desc, after = rescore,
    current = function(s) return type(s.rewardCostLimits) == "table" and s.rewardCostLimits[kind] or nil end,
    store = function(s, copper)
      if type(s.rewardCostLimits) ~= "table" then s.rewardCostLimits = {} end
      s.rewardCostLimits[kind] = copper
    end,
  })
end

local MAX_UNKNOWN = 20   -- unknown rewards listed (the most often seen first)

-- "item:<id>" / "currency:<id>" -> its name from the client, else the key itself. Asked when the option is drawn
-- (the name option is a function), so a name that was not cached yet shows once it is.
local function reward_name(key)
  local kind, id = tostring(key):match("^(%a+):(%d+)$")
  id = tonumber(id)
  local name
  if kind == "item" and id and C_Item and C_Item.GetItemNameByID then
    local ok, result = pcall(C_Item.GetItemNameByID, id)
    name = ok and result or nil
  elseif kind == "currency" and id and C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
    local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, id)
    name = ok and type(info) == "table" and info.name or nil
  end
  if type(name) == "string" and name ~= "" then return name end
  return tostring(key)
end

-- The inputs of the unknown rewards group: one per key of db.global.ordersUnknownRewards (at most MAX_UNKNOWN, the
-- most seen first, then by key), each setting rewardOverrides[key] in gold per unit.
local function unknown_list()
  local g = ns.FS.db and ns.FS.db.global
  local seen = g and type(g.ordersUnknownRewards) == "table" and g.ordersUnknownRewards or {}
  local list = {}
  for key, info in pairs(seen) do
    list[#list + 1] = { key = key, count = type(info) == "table" and tonumber(info.count) or 0 }
  end
  table.sort(list, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return tostring(a.key) < tostring(b.key)
  end)
  while #list > MAX_UNKNOWN do list[#list] = nil end
  return list
end

-- What the options show of that list, as one string: the list changed when this did.
local function signature(list)
  local parts = {}
  for i, item in ipairs(list) do parts[i] = tostring(item.key) .. "=" .. item.count end
  return table.concat(parts, ",")
end

local function unknown_args(list)
  local args = {}
  for i = 1, #list do
    local key = list[i].key
    args[key] = money_input({
      order = i, name = function() return reward_name(key) end,
      desc = (list[i].count == 1 and L["seen on %d order"] or L["seen on %d orders"]):format(list[i].count),
      after = rescore,
      current = function(s) return type(s.rewardOverrides) == "table" and s.rewardOverrides[key] or nil end,
      store = function(s, copper)
        if type(s.rewardOverrides) ~= "table" then s.rewardOverrides = {} end
        s.rewardOverrides[key] = copper
      end,
    })
  end
  return args
end

local lastUnknown, lastSignature   -- the unknown rewards subgroup Build() made last, and the list it shows

-- Lists the unknown rewards again (the group's args are fixed tables, so it replaces them) and asks the options
-- dialog to redraw, only when a key or a count changed. Runs when the orders change and whenever a test asks.
function M.RefreshUnknown()
  if not lastUnknown then return end
  local list = unknown_list()
  local sig = signature(list)
  if sig == lastSignature then return end
  lastSignature = sig
  lastUnknown.args = unknown_args(list)
  LibStub("AceConfigRegistry-3.0"):NotifyChange("FabricationStation")
end

local function unknown_group()
  local list = unknown_list()
  lastSignature = signature(list)
  lastUnknown = {
    type = "group", order = 30, name = L["Unknown rewards"], inline = true,
    disabled = disabled_for("Orders"),
    args = unknown_args(list),
  }
  return lastUnknown
end

-- claimBlockingRisks keys in Orders.RISKS order, then any other key, sorted.
local function risk_keys(orders)
  local defaults = orders.SETTINGS_DEFAULTS and orders.SETTINGS_DEFAULTS.claimBlockingRisks or {}
  local keys, seen = {}, {}
  for _, risk in ipairs(orders.RISKS or {}) do
    if defaults[risk] ~= nil then keys[#keys + 1] = risk; seen[risk] = true end
  end
  local rest = {}
  for risk in pairs(defaults) do
    if not seen[risk] then rest[#rest + 1] = risk end
  end
  table.sort(rest)
  for _, risk in ipairs(rest) do keys[#keys + 1] = risk end
  return keys
end

local function scoring_group()
  local args = {
    lowTipMargin = gold(1, "lowTipMargin", L["Low tip margin (gold)"],
      L["An order with no materials provided is flagged \"No mats, low tip\" when its commission (the tip after the cut) is less than the reagent cost plus this much."], { softMax = 1000 }),
    knowledgePointValue = gold(2, "knowledgePointValue", L["Value of one knowledge point (gold)"],
      L["What a knowledge point from a patron order reward is worth to you."], { softMax = 5000, bigStep = 10 }),
    moxieValue = gold(3, "moxieValue", L["Value of one Moxie (gold)"],
      L["What one Moxie from a patron order reward is worth to you."], { softMax = 100, bigStep = 0.5 }),
    knowledgeLimit = reward_limit(3.1, "knowledge", L["Most you pay per knowledge point (gold)"],
      L["The most an order may cost you for each knowledge point it pays (reagents and concentration beyond the tip). Leave empty for no limit. An order over it is flagged \"Reward costs too much\"."]),
    moxieLimit = reward_limit(3.2, "moxie", L["Most you pay per Moxie (gold)"],
      L["The most an order may cost you for each Moxie it pays (reagents and concentration beyond the tip). Leave empty for no limit. An order over it is flagged \"Reward costs too much\"."]),
    expiringSoonSeconds = range({
      module = "Orders", key = "expiringSoonSeconds", order = 4, scale = SECONDS_PER_MINUTE,
      name = L["Expiring soon (minutes)"], desc = L["An order with less time left than this is flagged \"Expiring soon\"."],
      min = 0, max = 2880, softMax = 720, step = 1, bigStep = 5, after = rescore,
    }),
    claimMinScore = gold(5, "claimMinScore", L["Claim Best: minimum score (gold)"],
      L["Claim Best Order only picks an order whose score is above this."],
      { min = -100000, softMin = -1000, softMax = 5000, bigStep = 10 }),
    claimHeader = { type = "header", order = 10, name = L["Claim Best skips orders with"] },
    unknownNote = { type = "description", order = 29,
      name = L["Rewards FabricationStation could not value. Give one a value and orders with it are scored."] },
    unknownRewards = unknown_group(),
  }
  local orders = module_of("Orders")
  if orders then
    for i, risk in ipairs(risk_keys(orders)) do
      args["block_" .. risk] = toggle({
        module = "Orders", key = risk, order = 10 + i, name = (orders.RISK_LABELS or {})[risk] or risk,
        path = function(s)
          if type(s.claimBlockingRisks) ~= "table" then s.claimBlockingRisks = {} end
          return s.claimBlockingRisks
        end,
        after = rescore,
      })
    end
  end
  return { type = "group", order = 1, name = L["Order scoring"], args = args }
end

---------------------------------------------------------------------------
-- Crafting-orders window (1a module switches)
---------------------------------------------------------------------------

local function module_toggle(order, moduleName, name, desc)
  return {
    type = "toggle", order = order, name = name, desc = desc, width = "full",
    get = function()
      local module = module_of(moduleName)
      return module ~= nil and module:IsEnabled()
    end,
    set = function(_, value) ns.FS:SetModuleEnabled(moduleName, value) end,
  }
end

-- The row-icons toggle redraws the rows on screen: the row cells refresh on FS_ORDERS_CHANGED.
local function rows_changed()
  local orders = module_of("Orders")
  if orders and orders.SendMessage then orders:SendMessage(ns.Msg.ORDERS_CHANGED) end
end

local function panel_group()
  return {
    type = "group", order = 2, name = L["Crafting-orders window"],
    args = {
      note = { type = "description", order = 0,
        name = L["Additions to Blizzard's crafting-orders window. The same switches are in Settings > Modules."] },
      rows = module_toggle(1, "OrdersRowAddons", L["Profit, score and risk on each order row"],
        L["Module OrdersRowAddons: cells on each row of Blizzard's order list, a tint for VIP, repeat and blocked customers, and a dark overlay on orders your filters hide."]),
      sidePanel = module_toggle(2, "OrdersSidePanel", L["Side panel with filters and Claim Best Order"],
        L["Module OrdersSidePanel: risk filters, claims remaining, the best claimable order and its button."]),
      orderViewWarning = module_toggle(3, "OrderViewWarning", L["Warning for blocked and VIP customers"],
        L["Module OrderViewWarning: a line above the order details when the customer is blocked or a VIP."]),
      rowIcons = toggle({ module = "Orders", key = "showRowIcons", order = 4,
        name = L["Show reward and reagent icons on order rows"],
        desc = L["Icons on each order row: a patron order's rewards in the Commission column, and in the Reagents column the reagents you still lack (red when you have too few)."],
        after = rows_changed }),
    },
  }
end

---------------------------------------------------------------------------
-- Alerts
---------------------------------------------------------------------------

-- { [key] = label } for the offered sounds the client's SOUNDKIT has.
local function sound_values()
  local kit = SOUNDKIT
  local values = {}
  if type(kit) ~= "table" then return values end
  for _, sound in ipairs(M.SOUNDS) do
    if kit[sound.key] ~= nil then values[sound.key] = sound.label end
  end
  return values
end

local function alerts_group()
  local function alerts() return settings_of("OrderAlert") end
  return {
    type = "group", order = 3, name = L["Alerts"],
    args = {
      personalOrderSound = toggle({ module = "OrderAlert", key = "personalOrderSound", order = 1,
        name = L["Play a sound when a personal order arrives"] }),
      personalOrderToast = toggle({ module = "OrderAlert", key = "personalOrderToast", order = 2,
        name = L["Show a message when a personal order arrives"] }),
      sound = {
        type = "select", order = 3, name = L["Sound"], values = sound_values,
        disabled = disabled_for("OrderAlert"),
        get = function()
          local s = alerts()
          local current = s and s.sound
          if current ~= nil and sound_values()[current] then return current end
          return DEFAULT_SOUND
        end,
        set = function(_, value)
          local s = alerts()
          if s and sound_values()[value] then s.sound = value end
        end,
      },
      toastSeconds = range({ module = "OrderAlert", key = "toastSeconds", order = 4,
        name = L["Show the message for (seconds)"], min = 1, max = 60, step = 1 }),
    },
  }
end

---------------------------------------------------------------------------
-- Ledger
---------------------------------------------------------------------------

local function ledger_group()
  return {
    type = "group", order = 4, name = L["Ledger"],
    args = {
      benchmarkMinSamples = range({ module = "Ledger", key = "benchmarkMinSamples", order = 1,
        name = L["Commissions needed for a benchmark"],
        desc = L["A recipe's typical commission is shown once you have been paid for it at least this many times."],
        min = 1, max = 20, step = 1, after = ledger_changed }),
      keepDays = range({ module = "Ledger", key = "keepDays", order = 2, name = L["Keep ledger entries for (days)"],
        desc = L["Older entries are removed when the Ledger starts."],
        min = 30, max = 1095, step = 1, bigStep = 30, after = ledger_changed }),
      saleLogHeader = { type = "header", order = 10, name = L["Sale log"] },
      saleLogWindow = range({ module = "SaleLog", key = "windowDays", order = 11,
        name = L["Sale history window (days)"],
        desc = L["How far back the Auctions page and the item tooltip count your posts, sales, expiries and cancels."],
        min = 7, max = 365, step = 1, bigStep = 7, after = salelog_changed }),
      saleLogTooltip = toggle({ module = "SaleLog", key = "tooltip", order = 12,
        name = L["Show your sales in item tooltips"],
        desc = L["Adds how many of an item you sold, its last sale price and how many you have listed now."] }),
    },
  }
end

---------------------------------------------------------------------------
-- Group
---------------------------------------------------------------------------

-- The AceConfig group. Getters and setters look modules up when they run, so a test can replace them.
function M.Build()
  return {
    type = "group", name = L["Orders & Ledger"], order = 40,
    args = {
      scoring = scoring_group(),
      panel = panel_group(),
      alerts = alerts_group(),
      ledger = ledger_group(),
    },
  }
end

ns.FS:RegisterOptions("orders", M.Build())

-- The unknown rewards list follows the orders: Orders counts a new unknown reward while it scores a board.
LibStub("AceEvent-3.0"):Embed(M)
M:RegisterMessage(ns.Msg.ORDERS_CHANGED, ns.FS:Wrap("OrdersOptions:unknown", function() M.RefreshUnknown() end))
