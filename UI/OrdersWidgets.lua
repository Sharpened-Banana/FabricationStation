local _, ns = ...
local L = ns.L

-- Two Dashboard widgets for phase 2, registered through 1b's Dashboard:RegisterWidget and filled with its SetLines:
--   * "Open orders" (order 40): the last order board seen (Orders:GetSnapshot): how many orders were on it, how many
--     personal, the best score among the orders the filters leave (Orders:Filter, so a hidden order is never "best";
--     "~" for an estimate), why orders have no score (recraft, conc?, no price, as on the board) and how long ago the
--     board was seen.
--   * "Gold this week" (order 50): this reset week's profit and income (Ledger:Weekly; "~" when a cost was
--     estimated). A week with sales or commissions whose cost is missing or partial is "partial" (that cost is not
--     subtracted, so the real profit may be lower);
--     an empty ledger says "No sales recorded yet". While the saved data is read-only the numbers still show, with a
--     read-only line; a Ledger turned off says so.
-- Each widget's frame shows all its lines in a tooltip, so a line cut at the dashboard's narrow width can be read.
-- 1b's Dashboard refreshes only on its own three messages; FS_ORDERS_CHANGED and FS_LEDGER_CHANGED refresh it here,
-- debounced, through MainWindow:RefreshTab("dashboard") (a no-op unless the dashboard is shown).
local OrdersWidgets = ns.FS:NewModule("OrdersWidgets", "AceEvent-3.0")
OrdersWidgets.coreModule = true

local M = {}
ns.UI = ns.UI or {}
ns.UI.OrdersWidgets = M

local REFRESH_SOURCE = "OrdersWidgets"
local REFRESH_KEY, REFRESH_DELAY = "ordersWidgets.refresh", 0.5
local DIM, WARN, GOOD, BAD = "|cff9d9d9d", "|cffffd100", "|cff40ff40", "|cffff4040"

local READ_ONLY_LINE = L["Read-only: saved data is from a newer addon version"]
local OFF_LINE = L["Ledger off: nothing new is recorded"]

local function module(name)
  return ns.FS:GetModule(name, true)
end

local function color(code, text)
  return code .. text .. "|r"
end

local function is_money(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function flags_of(v)
  return type(v) == "table" and type(v.flags) == "table" and v.flags or {}
end

local function orders_of(snapshot)
  return type(snapshot) == "table" and type(snapshot.orders) == "table" and snapshot.orders or {}
end

---------------------------------------------------------------------------
-- Models (pure)
---------------------------------------------------------------------------

-- The order view with the highest score (nil when none has one; a nil score is never "best").
function M.BestOrder(orders)
  local best
  for _, v in ipairs(type(orders) == "table" and orders or {}) do
    if type(v) == "table" and is_money(v.score) and (best == nil or v.score > best.score) then best = v end
  end
  return best
end

-- snapshot = Orders:GetSnapshot() ({ time, charKey, orders }), now = server seconds -> { total, personal,
-- bestScore|nil, age|nil } (age = now - snapshot.time, nil before a board was seen).
function M.OpenOrdersModel(snapshot, now)
  local total, personal = 0, 0
  local orders = orders_of(snapshot)
  for _, v in ipairs(orders) do
    if type(v) == "table" then
      total = total + 1
      if v.orderType == "personal" then personal = personal + 1 end
    end
  end
  local best = M.BestOrder(orders)
  local time = type(snapshot) == "table" and snapshot.time or nil
  return {
    total = total, personal = personal, bestScore = best and best.score or nil,
    age = (is_money(time) and is_money(now)) and now - time or nil,
  }
end

-- Why the orders without a score have none, counted as the board's score cell shows them: { recraft, conc, noPrice,
-- other }.
function M.UnscoredReasons(orders)
  local out = { recraft = 0, conc = 0, noPrice = 0, other = 0 }
  for _, v in ipairs(type(orders) == "table" and orders or {}) do
    if type(v) == "table" and not is_money(v.score) then
      local flags = flags_of(v)
      if flags.recraft then
        out.recraft = out.recraft + 1
      elseif flags.unknownConcentrationValue then
        out.conc = out.conc + 1
      elseif flags.noPrice then
        out.noPrice = out.noPrice + 1
      else
        out.other = out.other + 1
      end
    end
  end
  return out
end

-- Ledger:Weekly(now) (newest first) -> { profit, income, incomplete, estimated? } of the current week; profit and
-- income are nil when the week is unknown (no rows); estimated (the count of estimated costs) is nil when none.
function M.GoldThisWeekModel(weekly)
  local week = type(weekly) == "table" and weekly[1] or nil
  if type(week) ~= "table" then return { incomplete = 0 } end
  return { profit = week.profit, income = week.income, estimated = week.estimated,
    incomplete = type(week.incomplete) == "number" and week.incomplete or 0 }
end

---------------------------------------------------------------------------
-- Lines
---------------------------------------------------------------------------

local function money(copper, estimated)
  if not is_money(copper) then return "?" end
  return (estimated and "~" or "") .. ns.UI.FormatMoney(copper)
end

local function signed(copper, text)
  if not is_money(copper) or copper == 0 then return color(DIM, text) end
  return color(copper > 0 and GOOD or BAD, text)
end

-- The orders the user's filters leave (Orders:Filter), or all of them without the Orders module.
local function filtered(orders)
  local O = module("Orders")
  if O and O.Filter then return O:Filter(orders) end
  return orders
end

function M.OpenOrdersLines(snapshot, now)
  local model = M.OpenOrdersModel(snapshot, now)
  if model.age == nil then
    return { color(DIM, L["No orders seen yet"]), color(DIM, L["Open the crafting orders board at a profession table."]) }
  end
  local lines = {}
  if model.total == 0 then
    lines[1] = L["No open orders on the last board"]
  else
    local personal = (L["%d personal"]):format(model.personal)
    lines[1] = (L["%d on the board, %s"]):format(model.total, model.personal > 0 and color(GOOD, personal) or personal)
    local orders = orders_of(snapshot)
    local best = M.BestOrder(filtered(orders))
    if best then
      lines[#lines + 1] = "Best score: " .. signed(best.score, money(best.score, flags_of(best).estimated))
    else
      lines[#lines + 1] = "Best score: " .. color(DIM, "none")
    end
    local why = M.UnscoredReasons(orders)
    local parts = {}
    if why.recraft > 0 then parts[#parts + 1] = why.recraft .. " recraft" end
    if why.conc > 0 then parts[#parts + 1] = why.conc .. " conc?" end
    if why.noPrice > 0 then parts[#parts + 1] = why.noPrice .. " no price" end
    if why.other > 0 then parts[#parts + 1] = why.other .. " ?" end
    if #parts > 0 then lines[#lines + 1] = color(DIM, "Not scored: " .. table.concat(parts, ", ")) end
  end
  local seen = "Seen " .. ns.UI.FormatAge(model.age) .. " ago"
  if type(snapshot) == "table" and snapshot.charKey ~= nil then seen = seen .. " on " .. tostring(snapshot.charKey) end
  lines[#lines + 1] = color(DIM, seen)
  return lines
end

-- True when the ledger holds at least one sale or commission: Ledger:HasIncome (stops at the first one), else a
-- pass over Query for a Ledger without it.
local function has_sales(ledger)
  if ledger.HasIncome then return ledger:HasIncome() end
  for _, entry in ipairs(ledger:Query({})) do
    if entry.type == "sale" or entry.type == "commission" then return true end
  end
  return false
end

function M.GoldThisWeekLines(ledger, now)
  local lines = {}
  if not ledger then
    lines[1] = color(DIM, L["The Ledger is not available"])
    return lines
  end
  if not has_sales(ledger) then
    lines[1] = color(DIM, L["No sales recorded yet"])
    lines[2] = color(DIM, L["Order commissions and auction sales from the mailbox show here."])
  else
    local model = M.GoldThisWeekModel(ledger:Weekly(now, 1))
    if model.profit == nil then
      lines[1] = color(DIM, L["Week unknown: the game gave no weekly reset time"])
    else
      local partial = model.incomplete > 0
      local estimated = type(model.estimated) == "number" and model.estimated > 0
      lines[1] = "Profit: " .. signed(model.profit, money(model.profit, estimated))
        .. (partial and color(WARN, " (partial)") or "")
      lines[2] = "Income: " .. money(model.income)
      if partial then lines[3] = color(WARN, (L["Partial: %d with missing or partial cost"]):format(model.incomplete)) end
    end
  end
  if ns.FS.dbIsNewer then
    lines[#lines + 1] = color(BAD, READ_ONLY_LINE)
  elseif ledger.IsEnabled and not ledger:IsEnabled() then
    lines[#lines + 1] = color(WARN, OFF_LINE)
  end
  return lines
end

---------------------------------------------------------------------------
-- Widgets
---------------------------------------------------------------------------

local function set_lines(frame, lines)
  frame.fullLines = lines
  local dashboard = module("Dashboard")
  if dashboard and dashboard.SetLines then dashboard.SetLines(frame, lines) end
end

local function show_tooltip(frame)
  if type(GameTooltip) ~= "table" or type(frame.fullLines) ~= "table" then return end
  GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
  GameTooltip:SetText(frame.widgetTitle or "", 1, 0.82, 0)
  for _, text in ipairs(frame.fullLines) do GameTooltip:AddLine(text, 1, 1, 1, true) end
  GameTooltip:Show()
end

local function hide_tooltip()
  if type(GameTooltip) == "table" then GameTooltip:Hide() end
end

-- The widget frame is the Dashboard's (our own); hooks keep any handler it has. Errors are logged under the same
-- source as the Dashboard's own build / refresh calls for the widget.
local function builder(id, title)
  return function(frame)
    frame.widgetTitle = title
    frame:EnableMouse(true)
    frame:HookScript("OnEnter", ns.FS:Wrap("Dashboard:" .. id, show_tooltip))
    frame:HookScript("OnLeave", hide_tooltip)
    set_lines(frame, {})
  end
end

local function refresh_open_orders(frame)
  local orders = module("Orders")
  if not orders then
    set_lines(frame, { color(DIM, L["Orders are not available"]) })
    return
  end
  set_lines(frame, M.OpenOrdersLines(orders:GetSnapshot(), ns.FS:Now()))
end

local function refresh_gold(frame)
  set_lines(frame, M.GoldThisWeekLines(module("Ledger"), ns.FS:Now()))
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local function request_refresh()
  local window = module("MainWindow")
  if window and window.RefreshTab then window:RefreshTab("dashboard") end
end

local refreshLater = ns.FS:Wrap(REFRESH_SOURCE, request_refresh)

local function schedule_refresh()
  ns.FS:Debounce(REFRESH_KEY, REFRESH_DELAY, refreshLater)
end

function OrdersWidgets:OnInitialize()
  local dashboard = module("Dashboard")
  if not dashboard then return end
  dashboard:RegisterWidget("openOrders", { order = 40, title = L["Open orders"], build = builder("openOrders", L["Open orders"]),
    refresh = refresh_open_orders })
  dashboard:RegisterWidget("goldThisWeek", { order = 50, title = L["Gold this week"], build = builder("goldThisWeek", L["Gold this week"]),
    refresh = refresh_gold })
end

function OrdersWidgets:OnEnable()
  -- Orders and the Ledger send in bursts; one dashboard refresh follows REFRESH_DELAY after the last.
  local handler = ns.FS:Wrap(REFRESH_SOURCE, schedule_refresh)
  self:RegisterMessage(ns.Msg.ORDERS_CHANGED, handler)
  self:RegisterMessage(ns.Msg.LEDGER_CHANGED, handler)
end

function OrdersWidgets:OnDisable()
  self:UnregisterAllMessages()
  ns.FS:CancelDebounce(REFRESH_KEY)
end
