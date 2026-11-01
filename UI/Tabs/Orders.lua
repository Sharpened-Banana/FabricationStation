local _, ns = ...
local L = ns.L

-- Orders tab: the last crafting-order board seen (Orders:GetSnapshot), so it can be read away from the profession
-- table and on another character. A header says when and on which character the board was seen; a checkbox row
-- holds the same filters as the side panel on the order board (OrdersPanel.FilterChecks over
-- Orders:Settings().filters, shared, so a change here hides the same orders there); the list shows Type, Item,
-- Customer, Tip, Net, Score, Risk and Expires per order, best first (Orders:Filter), tinted by the customer highlight
-- (OrdersPanel.RowModel), with an Add to Queue button (OrdersPanel.QueueEntry / AddToQueue: the same entry and
-- duplicate check as the board's row cells) and a tooltip with the customer, the full tip and net, the risks, the
-- reasons numbers are missing and the player's own tip history for the recipe (Ledger:Benchmark). The list is a
-- pooled virtual list in a plain scroll frame, as in the Recipes and Queue tabs. Own frames only; handlers run
-- isolated.
--
-- Width: the Item column keeps at least MIN_ITEM px; when the window is too narrow the Customer column is hidden
-- first, then Type (Tab.Layout, applied to the column headers and the rows again on every size change). The cells
-- are compact (tip "1,234g", risk count "!2"); the tooltip carries the full values.
--
-- While the tab is shown it refreshes every TICK_SECONDS (ages move on, expired orders drop out): each refresh
-- reschedules one debounced tick, which asks MainWindow:RefreshTab, a no-op once the tab is hidden, so the ticking
-- stops by itself; OnDisable cancels it.
--
-- The tab never claims an order (design rule 3): claiming stays on the order board's own button.
--
-- Display rules (as on the board): an unknown net is "no price" (never 0g) and a known net with a missing price
-- ends in "?"; an estimate starts with "~"; a recraft shows an em dash and "recraft", an unknown concentration value
-- "conc?", never a generic "no price"; the full reasons are in the row tooltip.
--
-- ns.UI.OrdersPanel (UI\OrdersPanel.lua) loads after this file, so it is looked up at call time, like every module.
local OrdersTab = ns.FS:NewModule("OrdersTab", "AceEvent-3.0")
OrdersTab.coreModule = true

local Tab = {}
ns.UI = ns.UI or {}
ns.UI.OrdersTab = Tab

local TAB_ID, SOURCE, REFRESH_SOURCE = "orders", "Tab:orders", "OrdersTab"
local REFRESH_KEY, REFRESH_DELAY = "ordersTab.refresh", 0.5
local TICK_KEY, TICK_SECONDS = "ordersTab.tick", 30
local STATUS_SECONDS = 5
local ROW_HEIGHT, HEADER_HEIGHT, LINE_HEIGHT, CHECK_SIZE = 22, 20, 18, 24
local PAD, GAP = 6, 4
local CHECKS_PER_LINE, CHECK_COLUMN = 3, 160
local STATUS_SHARE = 0.45
local MIN_ITEM = 120
local DEFAULT_VIEW_HEIGHT = 400   -- before the scroll frame has a size
local SCROLL_STEP = ROW_HEIGHT * 3
local EM_DASH = "\226\128\148"
local DIM, WARN, GOOD, BAD = "|cff9d9d9d", "|cffffd100", "|cff40ff40", "|cffff4040"
local TONES = { good = GOOD, warn = WARN, bad = BAD }
local WHITE, RED, GREY, GOLD = { 1, 1, 1 }, { 1, 0.25, 0.25 }, { 0.62, 0.62, 0.62 }, { 1, 0.82, 0 }

local TYPE_LABELS = { public = L["Public"], guild = L["Guild"], personal = L["Personal"], npc = L["NPC"] }

-- Left to right. The flexible Item column takes the width the fixed ones leave over; the columns before it are laid
-- out from the left edge, the ones after it from the right edge.
local COLUMNS = {
  { key = "type", label = L["Type"], width = 48 },
  { key = "item", label = L["Item"], flex = true },
  { key = "customer", label = L["Customer"], width = 90 },
  { key = "tip", label = L["Tip"], width = 60, right = true },
  { key = "net", label = L["Net"], width = 56, right = true },
  { key = "score", label = L["Score"], width = 56, right = true },
  { key = "risk", label = L["Risk"], width = 32 },
  { key = "expires", label = L["Expires"], width = 44, right = true },
  { key = "action", label = "", width = 52 },
}
local ACTION = #COLUMNS
local HIDE_ORDER = { "customer", "type" }   -- dropped in this order when the Item column would get under MIN_ITEM
local FLEX, WIDTHS, HIDEABLE = nil, {}, {}
for i, col in ipairs(COLUMNS) do
  if col.flex then FLEX = i else WIDTHS[col.key] = col.width end
end
for _, key in ipairs(HIDE_ORDER) do HIDEABLE[key] = true end

local view            -- built frames and the displayed rows, nil before the tab is built
local OFF_NOTICE = L["Orders off: the board is not captured"]
local status          -- one line of feedback after an Add to Queue click (with its colour code)
local statusAt        -- ns.FS:Now() when it was set
local requested = {}  -- [itemID] = true while its data is requested, "done" after; asked once per session

local function module(name)
  return ns.FS:GetModule(name, true)
end

local function panel()
  return ns.UI.OrdersPanel
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

---------------------------------------------------------------------------
-- Models (pure)
---------------------------------------------------------------------------

-- snapshot = Orders:GetSnapshot() ({ time, charKey, orders }), filters = Orders:Settings().filters shape, now = server
-- seconds -> { header, seen, total, rows }. seen: a board was seen (the snapshot has a time). header: "Orders seen
-- <age> ago on <charKey>", or "No orders seen yet". total: the orders in the snapshot. rows: the orders the filters
-- leave, best first (Orders:Filter), each { orderID, type, item = itemID, customer, tip, net, score, risks,
-- expiresIn = seconds left|nil, view }.
function Tab.Model(snapshot, filters, now)
  snapshot = type(snapshot) == "table" and snapshot or {}
  local orders = type(snapshot.orders) == "table" and snapshot.orders or {}
  local seen = type(snapshot.time) == "number"
  local header = L["No orders seen yet"]
  if seen then
    local age = ns.UI.FormatAge(now - snapshot.time)
    header = snapshot.charKey ~= nil and L["Orders seen %s ago on %s"]:format(age, tostring(snapshot.charKey))
      or L["Orders seen %s ago"]:format(age)
  end
  local O = module("Orders")
  local rows = {}
  for i, v in ipairs(O and O:Filter(orders, filters) or {}) do
    rows[i] = {
      orderID = v.orderID, type = v.orderType, item = v.itemID, customer = v.customer, tip = v.tip, net = v.net,
      score = v.score, risks = type(v.risks) == "table" and v.risks or {},
      expiresIn = type(v.expiresAt) == "number" and v.expiresAt - now or nil,
      view = v,
    }
  end
  return { header = header, seen = seen, total = #orders, rows = rows }
end

-- Content width -> { hidden = { [columnKey] = true }, item = Item column width|nil }. The Item column keeps at least
-- MIN_ITEM px: Customer is hidden first, then Type. An unknown width (not laid out yet) hides nothing.
function Tab.Layout(width)
  local hidden = {}
  if type(width) ~= "number" or width <= 0 then return { hidden = hidden } end
  local used = 2 * PAD + (#COLUMNS - 1) * GAP
  for _, w in pairs(WIDTHS) do used = used + w end
  local item = width - used
  for _, key in ipairs(HIDE_ORDER) do
    if item >= MIN_ITEM then break end
    hidden[key] = true
    item = item + WIDTHS[key] + GAP
  end
  return { hidden = hidden, item = item }
end

-- The item's name from the client cache, else the recipe's cached schematic name, else "item:<id>".
local function item_name(row)
  local api = C_Item
  local name = row.item ~= nil and type(api) == "table" and type(api.GetItemNameByID) == "function"
    and api.GetItemNameByID(row.item) or nil
  if type(name) == "string" and name ~= "" then return name end
  local scanner = module("Scanner")
  local schematic = scanner and scanner.GetSchematic and row.view and row.view.recipeID ~= nil
    and scanner:GetSchematic(row.view.recipeID) or nil
  if type(schematic) == "table" and type(schematic.name) == "string" then return schematic.name end
  return "item:" .. tostring(row.item)
end

local function customer_text(row)
  return row.customer or (row.type == "npc" and L["Patron"] or nil)
end

-- Coloured like the board's cells: green for a gain, red for a loss, grey when it shows as "0g" (OrdersPanel.Sign).
local function sign_color(copper, text)
  local sign = panel().Sign(copper)
  if sign > 0 then return color(GOOD, text) end
  if sign < 0 then return color(BAD, text) end
  return color(DIM, text)
end

local function has_risk(row, name)
  for _, risk in ipairs(row.risks or {}) do
    if risk == name then return true end
  end
  return false
end

local function row_model(row, model)
  return model or panel().RowModel(row.view or {}, nil, {})
end

-- The display text of one row's cells, by column key. model = OrdersPanel.RowModel for the row (computed without a
-- customer when nil). Net and score use the board's cell texts (OrdersPanel.ProfitText / ScoreText); a "?" there
-- (unknown) reads "no price" when a price is missing. Tip is compact (OrdersPanel.CompactMoney); risk is the count.
function Tab.CellTexts(row, model)
  local P = panel()
  local v = row.view or {}
  local flags = flags_of(v)
  model = row_model(row, model)

  local net = P.ProfitText(v)
  if net == "?" then
    net = color(DIM, L["no price"])
  elseif flags.recraft then
    net = color(DIM, net)
  else
    net = sign_color(v.net, net)
  end

  local score = P.ScoreText(v)
  if score == "?" then
    score = color(DIM, flags.noPrice and L["no price"] or "?")
  elseif flags.recraft then
    score = color(DIM, score)
  elseif flags.unknownConcentrationValue then
    score = color(WARN, score)
  else
    score = sign_color(v.score, score)
  end

  local expires = "--"
  if type(row.expiresIn) == "number" then
    expires = row.expiresIn > 0 and ns.UI.FormatAge(row.expiresIn) or L["expired"]
    if has_risk(row, "expiringSoon") or row.expiresIn <= 0 then expires = color(BAD, expires) end
  end

  return {
    type = TYPE_LABELS[row.type] or (row.type ~= nil and tostring(row.type) or "--"),
    item = item_name(row),
    customer = customer_text(row) or "--",
    tip = P.CompactMoney(row.tip) or color(DIM, "?"),   -- unknown money in a compact cell: "?" (board, Ledger tab)
    net = net,
    score = score,
    risk = model.riskCount > 0 and color(BAD, "!" .. model.riskCount) or "",
    expires = expires,
  }
end

-- The quality the tip benchmark is asked for: the delivered quality, as on the board (OrdersPanel.BenchmarkQuality).
local function benchmark_quality(v)
  return panel().BenchmarkQuality(v)
end

-- Ledger:Benchmark's result for quality (nil: all qualities) -> "Your tips (Q3): median <m> (p25 <a>, p75 <b>,
-- n=<n>)", or "Your tips (all qualities): no history yet".
function Tab.BenchmarkText(benchmark, quality)
  local scope = quality ~= nil and ("Q" .. tostring(quality)) or L["all qualities"]
  local b = benchmark
  if not (type(b) == "table" and is_money(b.median) and is_money(b.p25) and is_money(b.p75)) then
    return (L["Your tips (%s): no history yet"]):format(scope)
  end
  return (L["Your tips (%s): median %s (p25 %s, p75 %s, n=%s)"]):format(scope, ns.UI.FormatMoney(b.median),
    ns.UI.FormatMoney(b.p25), ns.UI.FormatMoney(b.p75), tostring(b.n))
end

-- The full net for the tooltip: an em dash for a recraft, "no price" when unknown, "~" before an estimate.
local function net_text(v)
  local flags = flags_of(v)
  if flags.recraft then return EM_DASH end
  if not is_money(v.net) then return L["no price"] end
  return (flags.estimated and "~" or "") .. ns.UI.FormatMoney(v.net)
end

-- A row's tooltip, as { { text, color = {r, g, b} } }: the item, the customer, the full tip and net (what the
-- compact cells may cut), the risk labels (RowModel.riskText, red), why numbers are missing or uncertain
-- (OrdersPanel.Notes, grey) and the tip benchmark for the order's delivered quality.
function Tab.TooltipLines(row, benchmark, model)
  local v = row.view or {}
  model = row_model(row, model)
  local lines = { { text = item_name(row), color = WHITE } }
  local customer = customer_text(row)
  if customer then lines[#lines + 1] = { text = L["Customer: %s"]:format(customer), color = WHITE } end
  lines[#lines + 1] = { text = L["Tip: %s"]:format(ns.UI.FormatMoney(row.tip)), color = WHITE }
  lines[#lines + 1] = { text = L["Net: %s"]:format(net_text(v)), color = WHITE }
  for label in (model.riskText or ""):gmatch("[^\n]+") do lines[#lines + 1] = { text = label, color = RED } end
  for _, note in ipairs(panel().Notes(v)) do lines[#lines + 1] = { text = note, color = GREY } end
  lines[#lines + 1] = { text = Tab.BenchmarkText(benchmark, benchmark_quality(v)), color = GOLD }
  return lines
end

local function benchmark_for(row)
  local ledger = module("Ledger")
  local v = row.view or {}
  if not (ledger and ledger.Benchmark and v.recipeID ~= nil) then return nil end
  return ledger:Benchmark(v.recipeID, benchmark_quality(v))
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

local function filters()
  local O = module("Orders")
  return O and O:Settings().filters or nil
end

local function request_refresh()
  local window = module("MainWindow")
  if window and window.RefreshTab then window:RefreshTab(TAB_ID) end
end

local refreshLater = ns.FS:Wrap(REFRESH_SOURCE, request_refresh)

local function schedule_refresh()
  ns.FS:Debounce(REFRESH_KEY, REFRESH_DELAY, refreshLater)
end

-- The status line while Orders is off (and no action message is showing): the saved board is shown, but nothing new
-- is captured or rescored.
local function off_text(O)
  if O and O.IsEnabled and not O:IsEnabled() then return color(WARN, OFF_NOTICE) end
  return ""
end

local apply_layout   -- below; the status line's width follows its text

local function set_status(message, tone)
  status, statusAt = color(TONES[tone] or "", message), ns.FS:Now()
  if view then
    view.status:SetText(status)
    apply_layout()
  end
end

local function clear_status()
  status, statusAt = nil, nil
  if view then
    view.status:SetText(off_text(module("Orders")))
    apply_layout()
  end
end

-- Add to Queue: the order as it is now (live, else saved) through the board's own path.
local function add_to_queue(row)
  local O = module("Orders")
  local current = O and row.orderID ~= nil and O:GetView(row.orderID) or nil
  if not current then return set_status(L["That order is gone or has expired"], "warn") end
  local message, tone = panel().AddToQueue(current)
  if message then set_status(message, tone) end
end

local function show_tooltip(owner)
  local row = owner.data
  if type(GameTooltip) ~= "table" or not row then return end
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  for i, line in ipairs(Tab.TooltipLines(row, benchmark_for(row), owner.model)) do
    local c = line.color
    if i == 1 then
      GameTooltip:SetText(line.text, c[1], c[2], c[3])
    else
      GameTooltip:AddLine(line.text, c[1], c[2], c[3], true)
    end
  end
  GameTooltip:Show()
end

local function hide_tooltip()
  if type(GameTooltip) == "table" then GameTooltip:Hide() end
end

-- Asks the client once per session for an item it has not cached; GET_ITEM_INFO_RECEIVED then refreshes the tab.
local function request_item(itemID)
  local api = C_Item
  if itemID == nil or requested[itemID] or type(api) ~= "table" then return end
  if type(api.GetItemNameByID) == "function" and api.GetItemNameByID(itemID) then return end
  if type(api.RequestLoadItemDataByID) ~= "function" then return end
  requested[itemID] = true
  pcall(api.RequestLoadItemDataByID, itemID)
end

local function on_item_info(_, itemID)
  if requested[itemID] ~= true then return end
  requested[itemID] = "done"
  schedule_refresh()
end

---------------------------------------------------------------------------
-- Columns and list
---------------------------------------------------------------------------

-- Anchors cells (by column index) in parent: the columns before the flexible one from the left edge rightwards, the
-- ones after it from the right edge leftwards, and the flexible one between them. Hidden columns (layout.hidden)
-- are hidden and left out of the chain; the other hideable ones are shown.
local function place_cells(parent, cells, hidden)
  local function shown(i)
    local key = COLUMNS[i].key
    if HIDEABLE[key] then
      if hidden[key] then cells[i]:Hide() else cells[i]:Show() end
    end
    return not hidden[key]
  end
  local left
  for i = 1, FLEX - 1 do
    local cell = cells[i]
    cell:ClearAllPoints()
    if shown(i) then
      if left then
        cell:SetPoint("LEFT", left, "RIGHT", GAP, 0)
      else
        cell:SetPoint("LEFT", parent, "LEFT", PAD, 0)
      end
      cell:SetWidth(COLUMNS[i].width)
      left = cell
    end
  end
  local right
  for i = #COLUMNS, FLEX + 1, -1 do
    local cell = cells[i]
    cell:ClearAllPoints()
    if shown(i) then
      if right then
        cell:SetPoint("RIGHT", right, "LEFT", -GAP, 0)
      else
        cell:SetPoint("RIGHT", parent, "RIGHT", -PAD, 0)
      end
      cell:SetWidth(COLUMNS[i].width)
      right = cell
    end
  end
  local flex = cells[FLEX]
  flex:ClearAllPoints()
  if left then flex:SetPoint("LEFT", left, "RIGHT", GAP, 0) else flex:SetPoint("LEFT", parent, "LEFT", PAD, 0) end
  if right then flex:SetPoint("RIGHT", right, "LEFT", -GAP, 0) else flex:SetPoint("RIGHT", parent, "RIGHT", -PAD, 0) end
end

local function layout_key(hidden)
  local keys = {}
  for _, key in ipairs(HIDE_ORDER) do if hidden[key] then keys[#keys + 1] = key end end
  return table.concat(keys, ",")
end

-- Lays the columns out for the container's width (header and every pooled row) when the hidden set changed, and
-- sizes the header and status lines so they cannot overlap: the header takes the whole line without a status, else
-- the status takes the right STATUS_SHARE (as in the Ledger tab).
function apply_layout()
  if not view then return end
  local width = view.container:GetWidth()
  local layout = Tab.Layout(width)
  view.layout = layout
  local key = layout_key(layout.hidden)
  if key ~= view.layoutKey then
    view.layoutKey = key
    place_cells(view.headerBar, view.headers, layout.hidden)
    for _, row in ipairs(view.pool) do place_cells(row, row.placed, layout.hidden) end
  end
  if type(width) == "number" and width > 0 then
    local inner = width - 2 * PAD
    local text = view.status:GetText()
    if type(text) == "string" and text ~= "" then
      local statusWidth = math.floor(inner * STATUS_SHARE)
      view.status:SetWidth(statusWidth)
      view.header:SetWidth(inner - statusWidth - GAP)
    else
      view.status:SetWidth(0)
      view.header:SetWidth(inner)
    end
  end
end

local function create_row()
  local row = CreateFrame("Frame", nil, view.child)
  row:SetHeight(ROW_HEIGHT)
  row:EnableMouse(true)
  row.background = row:CreateTexture(nil, "BACKGROUND")
  row.background:SetAllPoints(row)
  row.cells, row.placed = {}, {}
  for i = 1, ACTION - 1 do
    local cell = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cell:SetJustifyH(COLUMNS[i].right and "RIGHT" or "LEFT")
    cell:SetWordWrap(false)
    row.cells[COLUMNS[i].key] = cell
    row.placed[i] = cell
  end
  local button = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  button:SetHeight(ROW_HEIGHT - 2)
  button:SetText(L["Queue"])
  -- SetScript is deliberate: the row and the button are our own.
  button:SetScript("OnClick", ns.FS:Wrap(SOURCE, function() if row.data then add_to_queue(row.data) end end))
  row.queue = button
  row.placed[ACTION] = button
  place_cells(row, row.placed, view.layout and view.layout.hidden or {})
  row:SetScript("OnEnter", ns.FS:Wrap(SOURCE, show_tooltip))
  row:SetScript("OnLeave", hide_tooltip)
  return row
end

local function bind_row(row, data, index)
  row.data = data
  row:ClearAllPoints()
  row:SetPoint("TOPLEFT", view.child, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
  row:SetPoint("TOPRIGHT", view.child, "TOPRIGHT", 0, -(index - 1) * ROW_HEIGHT)

  local P = panel()
  local cust = module("Customers")
  local record = (cust and data.customer ~= nil) and cust:Get(data.customer) or nil
  local model = P.RowModel(data.view, record, filters())
  local tint = model.highlight and P.HIGHLIGHT_COLORS[model.highlight] or nil
  row.model, row.highlight, row.tintColor = model, model.highlight, tint
  if tint then
    row.background:SetColorTexture(tint[1], tint[2], tint[3], tint[4])
  else
    row.background:SetColorTexture(1, 1, 1, index % 2 == 0 and 0.04 or 0)
  end

  request_item(data.item)
  local texts = Tab.CellTexts(data, model)
  for key, cell in pairs(row.cells) do cell:SetText(texts[key]) end
  if P.QueueEntry(data.view) ~= nil and module("Queue") ~= nil then row.queue:Show() else row.queue:Hide() end
  row:Show()
end

-- Binds the pooled rows to the part of the list in view.
local function update_rows()
  if not view then return end
  local height = view.scroll:GetHeight()
  if type(height) ~= "number" or height <= 0 then height = DEFAULT_VIEW_HEIGHT end
  local offset = view.scroll:GetVerticalScroll()
  if type(offset) ~= "number" then offset = 0 end
  local first = math.floor(offset / ROW_HEIGHT) + 1
  local slots = math.ceil(height / ROW_HEIGHT) + 1
  local used = 0
  for slot = 1, slots do
    local index = first + slot - 1
    local data = view.rows[index]
    if not data then break end
    local row = view.pool[slot]
    if not row then
      row = create_row()
      view.pool[slot] = row
    end
    bind_row(row, data, index)
    used = slot
  end
  for slot = used + 1, #view.pool do
    view.pool[slot].data = nil
    view.pool[slot]:Hide()
  end
  view.shown = used
end

local function on_mouse_wheel(scroll, delta)
  local range = scroll:GetVerticalScrollRange() or 0
  local position = scroll:GetVerticalScroll() or 0
  scroll:SetVerticalScroll(math.max(0, math.min(range, position - delta * SCROLL_STEP)))
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------

local function empty_text(model)
  if not model.seen then
    return L["Open the crafting orders board at a profession table; the orders seen there are kept here."]
  end
  if model.total == 0 then return L["No open orders were on the last board seen."] end
  return L["Every order is hidden by the filters."]
end

local function refresh()
  if not view then return end
  local now = ns.FS:Now()
  if statusAt ~= nil and now - statusAt >= STATUS_SECONDS then clear_status() end
  local O = module("Orders")
  local f = filters()
  local model = Tab.Model(O and O:GetSnapshot() or {}, f, now)
  view.rows = model.rows
  view.header:SetText(model.header)
  for _, check in ipairs(view.checks) do check.button:SetChecked(f ~= nil and check.get(f) or false) end
  if #view.rows == 0 then
    view.empty:SetText(color(DIM, empty_text(model)))
    view.empty:Show()
  else
    view.empty:SetText("")
    view.empty:Hide()
  end
  view.status:SetText(status or off_text(O))
  apply_layout()
  local total = #view.rows * ROW_HEIGHT
  view.child:SetHeight(math.max(total, 1))
  local viewHeight = view.scroll:GetHeight()
  if type(viewHeight) == "number" and viewHeight > 0 then
    local offset = view.scroll:GetVerticalScroll()
    local limit = math.max(0, total - viewHeight)
    if type(offset) == "number" and offset > limit then view.scroll:SetVerticalScroll(limit) end
  end
  update_rows()
  -- The next tick (ages, expiry) while the tab stays shown; RefreshTab does nothing once it is hidden.
  ns.FS:Debounce(TICK_KEY, TICK_SECONDS, refreshLater)
end

---------------------------------------------------------------------------
-- Build
---------------------------------------------------------------------------

-- A filter checkbox from an OrdersPanel.FilterChecks descriptor. A click flips the stored value, tells the order
-- board's additions (FS_ORDERS_CHANGED) and refreshes this tab at once.
local function create_check(bar, index, top, d)
  local line, column = math.floor((index - 1) / CHECKS_PER_LINE), (index - 1) % CHECKS_PER_LINE
  local button = CreateFrame("CheckButton", nil, bar, "UICheckButtonTemplate")
  button:SetSize(CHECK_SIZE, CHECK_SIZE)
  button:SetPoint("TOPLEFT", bar, "TOPLEFT", column * CHECK_COLUMN, -(top + line * CHECK_SIZE))
  local text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  text:SetPoint("LEFT", button, "RIGHT", 2, 0)
  text:SetText(d.label)
  local check = { button = button, label = text, get = d.get, key = d.key, risk = d.risk }
  button:SetScript("OnClick", ns.FS:Wrap(SOURCE, function(self)
    local f = filters()
    if not f then return end
    local on = not d.get(f)
    d.set(f, on)
    self:SetChecked(on)
    clear_status()
    OrdersTab:SendMessage(ns.Msg.ORDERS_CHANGED)
    request_refresh()
  end))
  return check
end

local function create_headers(container, top)
  local bar = CreateFrame("Frame", nil, container)
  bar:SetHeight(HEADER_HEIGHT)
  bar:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -top)
  bar:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, -top)
  local headers = {}
  for i, col in ipairs(COLUMNS) do
    local text = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetHeight(HEADER_HEIGHT)
    text:SetJustifyH(col.right and "RIGHT" or "LEFT")
    text:SetWordWrap(false)
    text:SetText(col.label)
    headers[i] = text
  end
  return bar, headers
end

local function build(container)
  local descriptors = panel().FilterChecks()
  local lines = math.max(1, math.ceil(#descriptors / CHECKS_PER_LINE))
  local filterLabelTop = 4 + LINE_HEIGHT
  local checksTop = filterLabelTop + LINE_HEIGHT
  local headersTop = checksTop + lines * CHECK_SIZE + 2
  local scrollTop = headersTop + HEADER_HEIGHT + 2

  local bar = CreateFrame("Frame", nil, container)
  bar:SetPoint("TOPLEFT", container, "TOPLEFT", PAD, 0)
  bar:SetPoint("TOPRIGHT", container, "TOPRIGHT", -PAD, 0)
  bar:SetHeight(headersTop)

  local created = { container = container, rows = {}, pool = {}, shown = 0, checks = {}, filterLines = lines }
  created.header = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  created.header:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, -4)
  created.header:SetJustifyH("LEFT")
  created.header:SetWordWrap(false)
  created.status = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  created.status:SetPoint("TOPRIGHT", bar, "TOPRIGHT", 0, -4)
  created.status:SetJustifyH("RIGHT")
  created.status:SetWordWrap(false)
  created.filterLabel = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  created.filterLabel:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, -(filterLabelTop + 2))
  created.filterLabel:SetText(L["Hide orders with:"])
  for i, d in ipairs(descriptors) do created.checks[i] = create_check(bar, i, checksTop, d) end
  created.headerBar, created.headers = create_headers(container, headersTop)

  local scroll = CreateFrame("ScrollFrame", nil, container)
  scroll:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -scrollTop)
  scroll:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
  local child = CreateFrame("Frame", nil, scroll)
  child:SetSize(1, 1)
  scroll:SetScrollChild(child)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", ns.FS:Wrap(SOURCE, on_mouse_wheel))
  scroll:SetScript("OnVerticalScroll", ns.FS:Wrap(SOURCE, update_rows))
  scroll:HookScript("OnSizeChanged", function(_, width)
    if width and width > 0 then child:SetWidth(width) end
    ns.FS:SafeCall(SOURCE, update_rows)
  end)
  local width = scroll:GetWidth()
  if width and width > 0 then child:SetWidth(width) end
  created.scroll, created.child = scroll, child

  created.empty = container:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  created.empty:SetPoint("TOPLEFT", container, "TOPLEFT", PAD + 4, -(scrollTop + 8))
  created.empty:SetPoint("TOPRIGHT", container, "TOPRIGHT", -PAD - 4, -(scrollTop + 8))
  created.empty:SetJustifyH("LEFT")
  created.empty:Hide()

  view = created
  apply_layout()
  -- Columns follow the window's width; reselecting the tab starts without the last action's status line.
  container:HookScript("OnSizeChanged", ns.FS:Wrap(SOURCE, apply_layout))
  container:HookScript("OnShow", ns.FS:Wrap(SOURCE, clear_status))
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

-- Test and diagnostics access: the built view (nil before the tab is built).
function OrdersTab:GetView()
  return view
end

function OrdersTab:OnInitialize()
  local window = module("MainWindow")
  if window then
    window:RegisterTab(TAB_ID, {
      label = L["Orders"], icon = "Interface\\Icons\\INV_Misc_Note_06", order = 40, phase = 2,
      build = build,
      refresh = refresh,
    })
  end
end

function OrdersTab:OnEnable()
  -- One refresh follows 0.5 s after the last of a burst; MainWindow only refreshes a selected, visible tab.
  local handler = ns.FS:Wrap(REFRESH_SOURCE, schedule_refresh)
  self:RegisterMessage(ns.Msg.ORDERS_CHANGED, handler)
  self:RegisterMessage(ns.Msg.CUSTOMERS_CHANGED, handler)
  self:RegisterEvent("GET_ITEM_INFO_RECEIVED", ns.FS:Wrap(REFRESH_SOURCE, on_item_info))
end

function OrdersTab:OnDisable()
  self:UnregisterAllMessages()
  self:UnregisterAllEvents()
  ns.FS:CancelDebounce(REFRESH_KEY)
  ns.FS:CancelDebounce(TICK_KEY)
end
