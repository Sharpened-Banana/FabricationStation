local _, ns = ...

-- Orders tab: the last crafting-order board seen (Orders:GetSnapshot), so it can be read away from the profession
-- table and on another character. A header says when and on which character the board was seen; a checkbox row
-- holds the same filters as the side panel on the order board (Orders:Settings().filters, shared, so a change here
-- hides the same orders there); the list shows Type, Item, Customer, Tip, Net, Score, Risk and Expires per order,
-- best first (Orders:Filter), tinted by the customer highlight (OrdersPanel.RowModel), with an Add to Queue button
-- (OrdersPanel.QueueEntry / AddToQueue: the same entry and duplicate check as the board's row cells) and a tooltip
-- with the risks, the reasons numbers are missing and the player's own tip history for the recipe
-- (Ledger:Benchmark). The list is a pooled virtual list in a plain scroll frame, as in the Recipes and Queue tabs.
-- Own frames only; handlers run isolated.
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

local TAB_ID, SOURCE = "orders", "Tab:orders"
local REFRESH_KEY, REFRESH_DELAY = "ordersTab.refresh", 0.5
local ROW_HEIGHT, HEADER_HEIGHT, LINE_HEIGHT, CHECK_SIZE = 22, 20, 18, 24
local PAD, GAP = 6, 4
local CHECKS_PER_LINE, CHECK_COLUMN = 3, 180
local CHECK_LINES = 2
local FILTER_TOP = 4 + LINE_HEIGHT
local HEADERS_TOP = FILTER_TOP + CHECK_LINES * CHECK_SIZE + 2
local SCROLL_TOP = HEADERS_TOP + HEADER_HEIGHT + 2
local DEFAULT_VIEW_HEIGHT = 400   -- before the scroll frame has a size
local SCROLL_STEP = ROW_HEIGHT * 3
local DIM, WARN, GOOD, BAD = "|cff9d9d9d", "|cffffd100", "|cff40ff40", "|cffff4040"
local TONES = { good = GOOD, warn = WARN, bad = BAD }
local WHITE, RED, GREY, GOLD = { 1, 1, 1 }, { 1, 0.25, 0.25 }, { 0.62, 0.62, 0.62 }, { 1, 0.82, 0 }

local TYPE_LABELS = { public = "Public", guild = "Guild", personal = "Personal", npc = "NPC" }

-- Left to right. The flexible item column takes the width the fixed ones leave over.
local COLUMNS = {
  { key = "type", label = "Type", width = 52 },
  { key = "item", label = "Item", flex = true },
  { key = "customer", label = "Customer", width = 96 },
  { key = "tip", label = "Tip", width = 84, right = true },
  { key = "net", label = "Net", width = 60, right = true },
  { key = "score", label = "Score", width = 56, right = true },
  { key = "risk", label = "Risk", width = 84 },
  { key = "expires", label = "Expires", width = 48, right = true },
  { key = "action", label = "", width = 52 },
}
local ACTION = #COLUMNS

local view            -- built frames and the displayed rows, nil before the tab is built
local status          -- one line of feedback after an Add to Queue click (with its colour code)
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
-- seconds -> { header, total, rows }. header: "Orders seen <age> ago on <charKey>", or "No orders seen yet" before any
-- board was seen. total: the orders in the snapshot. rows: the orders the filters leave, best first (Orders:Filter),
-- each { orderID, type, item = itemID, customer, tip, net, score, risks, expiresIn = seconds left|nil, view }.
function Tab.Model(snapshot, filters, now)
  snapshot = type(snapshot) == "table" and snapshot or {}
  local orders = type(snapshot.orders) == "table" and snapshot.orders or {}
  local header = "No orders seen yet"
  if type(snapshot.time) == "number" then
    header = "Orders seen " .. ns.UI.FormatAge(now - snapshot.time) .. " ago"
    if snapshot.charKey ~= nil then header = header .. " on " .. tostring(snapshot.charKey) end
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
  return { header = header, total = #orders, rows = rows }
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

local function sign_color(copper, text)
  if is_money(copper) and copper > 0 then return color(GOOD, text) end
  if is_money(copper) and copper < 0 then return color(BAD, text) end
  return text
end

local function risk_labels(risks)
  local O = module("Orders")
  local labels = O and O.RISK_LABELS or {}
  local out = {}
  for i, risk in ipairs(risks or {}) do out[i] = labels[risk] or tostring(risk) end
  return out
end

local function has_risk(row, name)
  for _, risk in ipairs(row.risks or {}) do
    if risk == name then return true end
  end
  return false
end

-- The display text of one row's cells, by column key. Net and score use the board's cell texts
-- (OrdersPanel.ProfitText / ScoreText); a "?" there (unknown) reads "no price" when a price is missing.
function Tab.CellTexts(row)
  local P = panel()
  local v = row.view or {}
  local flags = flags_of(v)

  local net = P.ProfitText(v)
  if net == "?" then
    net = color(DIM, "no price")
  elseif flags.recraft then
    net = color(DIM, net)
  else
    net = sign_color(v.net, net)
  end

  local score = P.ScoreText(v)
  if score == "?" then
    score = color(DIM, flags.noPrice and "no price" or "?")
  elseif flags.recraft then
    score = color(DIM, score)
  elseif flags.unknownConcentrationValue then
    score = color(WARN, score)
  else
    score = sign_color(v.score, score)
  end

  local expires = "--"
  if type(row.expiresIn) == "number" then
    expires = row.expiresIn > 0 and ns.UI.FormatAge(row.expiresIn) or "expired"
    if has_risk(row, "expiringSoon") or row.expiresIn <= 0 then expires = color(BAD, expires) end
  end

  local risks = table.concat(risk_labels(row.risks), ", ")
  return {
    type = TYPE_LABELS[row.type] or (row.type ~= nil and tostring(row.type) or "--"),
    item = item_name(row),
    customer = row.customer or (row.type == "npc" and "Patron" or "--"),
    tip = ns.UI.FormatMoney(row.tip),
    net = net,
    score = score,
    risk = risks ~= "" and color(BAD, risks) or "",
    expires = expires,
  }
end

-- Ledger:Benchmark's result -> "Your tips: median <m> (p25 <a>, p75 <b>, n=<n>)", or "Your tips: no history yet".
function Tab.BenchmarkText(benchmark)
  local b = benchmark
  if not (type(b) == "table" and is_money(b.median) and is_money(b.p25) and is_money(b.p75)) then
    return "Your tips: no history yet"
  end
  return ("Your tips: median %s (p25 %s, p75 %s, n=%s)"):format(ns.UI.FormatMoney(b.median),
    ns.UI.FormatMoney(b.p25), ns.UI.FormatMoney(b.p75), tostring(b.n))
end

-- A row's tooltip, as { { text, color = {r, g, b} } }: the item, the risk labels (red), why numbers are missing or
-- uncertain (OrdersPanel.Notes, grey) and the tip benchmark.
function Tab.TooltipLines(row, benchmark)
  local lines = { { text = item_name(row), color = WHITE } }
  for _, label in ipairs(risk_labels(row.risks)) do lines[#lines + 1] = { text = label, color = RED } end
  for _, note in ipairs(panel().Notes(row.view or {})) do lines[#lines + 1] = { text = note, color = GREY } end
  lines[#lines + 1] = { text = Tab.BenchmarkText(benchmark), color = GOLD }
  return lines
end

-- The benchmark for a row's order: its recipe at its minimum quality (all qualities when it has no minimum).
local function benchmark_for(row)
  local ledger = module("Ledger")
  local v = row.view or {}
  if not (ledger and ledger.Benchmark and v.recipeID ~= nil) then return nil end
  local quality = type(v.minQuality) == "number" and v.minQuality > 1 and v.minQuality or nil
  return ledger:Benchmark(v.recipeID, quality)
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

local function schedule_refresh()
  ns.FS:Debounce(REFRESH_KEY, REFRESH_DELAY, ns.FS:Wrap("OrdersTab", request_refresh))
end

-- Add to Queue: the order as it is now (live, else saved) through the board's own path.
local function add_to_queue(row)
  local O = module("Orders")
  local current = O and row.orderID ~= nil and O:GetView(row.orderID) or nil
  local message, tone
  if current then
    message, tone = panel().AddToQueue(current)
  else
    message, tone = "That order is gone or has expired", "warn"
  end
  if message then status = color(TONES[tone] or "", message) end
  if view then view.status:SetText(status or "") end
end

local function show_tooltip(owner, row)
  if type(GameTooltip) ~= "table" or not row then return end
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  for i, line in ipairs(Tab.TooltipLines(row, benchmark_for(row))) do
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
-- List
---------------------------------------------------------------------------

local function place_cells(parent, cells)
  local previous
  for i = #COLUMNS, 1, -1 do
    local col, cell = COLUMNS[i], cells[i]
    cell:ClearAllPoints()
    if previous then
      cell:SetPoint("RIGHT", previous, "LEFT", -GAP, 0)
    else
      cell:SetPoint("RIGHT", parent, "RIGHT", -PAD, 0)
    end
    if col.flex then
      cell:SetPoint("LEFT", parent, "LEFT", PAD, 0)
    else
      cell:SetWidth(col.width)
    end
    previous = cell
  end
end

local function create_row()
  local row = CreateFrame("Frame", nil, view.child)
  row:SetHeight(ROW_HEIGHT)
  row:EnableMouse(true)
  row.background = row:CreateTexture(nil, "BACKGROUND")
  row.background:SetAllPoints(row)
  row.cells = {}
  local placed = {}
  for i = 1, ACTION - 1 do
    local cell = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cell:SetJustifyH(COLUMNS[i].right and "RIGHT" or "LEFT")
    cell:SetWordWrap(false)
    row.cells[COLUMNS[i].key] = cell
    placed[i] = cell
  end
  local button = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  button:SetHeight(ROW_HEIGHT - 2)
  button:SetText("Queue")
  -- SetScript is deliberate: the row and the button are our own.
  button:SetScript("OnClick", ns.FS:Wrap(SOURCE, function() if row.data then add_to_queue(row.data) end end))
  row.queue = button
  placed[ACTION] = button
  place_cells(row, placed)
  row:SetScript("OnEnter", ns.FS:Wrap(SOURCE, function(self) show_tooltip(self, self.data) end))
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
  row.highlight, row.tintColor = model.highlight, tint
  if tint then
    row.background:SetColorTexture(tint[1], tint[2], tint[3], tint[4])
  else
    row.background:SetColorTexture(1, 1, 1, index % 2 == 0 and 0.04 or 0)
  end

  request_item(data.item)
  local texts = Tab.CellTexts(data)
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
  if model.header == "No orders seen yet" then
    return "Open the crafting orders board at a profession table; the orders seen there are kept here."
  end
  if model.total == 0 then return "No open orders were on the last board seen." end
  return "Every order is hidden by the filters."
end

local function refresh()
  if not view then return end
  local O = module("Orders")
  local f = filters()
  local model = Tab.Model(O and O:GetSnapshot() or {}, f, ns.FS:Now())
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
  view.status:SetText(status or "")
  local total = #view.rows * ROW_HEIGHT
  view.child:SetHeight(math.max(total, 1))
  local viewHeight = view.scroll:GetHeight()
  if type(viewHeight) == "number" and viewHeight > 0 then
    local offset = view.scroll:GetVerticalScroll()
    local limit = math.max(0, total - viewHeight)
    if type(offset) == "number" and offset > limit then view.scroll:SetVerticalScroll(limit) end
  end
  update_rows()
end

---------------------------------------------------------------------------
-- Build
---------------------------------------------------------------------------

-- A filter checkbox on the shared Orders filters. A click flips the stored value, tells the order board's
-- additions (FS_ORDERS_CHANGED) and refreshes this tab at once.
local function create_check(bar, index, label, get, set)
  local line, column = math.floor((index - 1) / CHECKS_PER_LINE), (index - 1) % CHECKS_PER_LINE
  local button = CreateFrame("CheckButton", nil, bar, "UICheckButtonTemplate")
  button:SetSize(CHECK_SIZE, CHECK_SIZE)
  button:SetPoint("TOPLEFT", bar, "TOPLEFT", column * CHECK_COLUMN, -(FILTER_TOP + line * CHECK_SIZE))
  local text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  text:SetPoint("LEFT", button, "RIGHT", 2, 0)
  text:SetText(label)
  local check = { button = button, label = text, get = get }
  button:SetScript("OnClick", ns.FS:Wrap(SOURCE, function(self)
    local f = filters()
    if not f then return end
    local on = not get(f)
    set(f, on)
    self:SetChecked(on)
    status = nil
    OrdersTab:SendMessage(ns.Msg.ORDERS_CHANGED)
    request_refresh()
  end))
  return check
end

local function create_checks(bar)
  local checks = {}
  local O = module("Orders")
  for _, risk in ipairs(O and O.RISKS or {}) do
    local check = create_check(bar, #checks + 1, "Hide " .. ((O.RISK_LABELS or {})[risk] or risk):lower(),
      function(f) return type(f.hideRisks) == "table" and f.hideRisks[risk] == true end,
      function(f, on)
        if type(f.hideRisks) ~= "table" then f.hideRisks = {} end
        f.hideRisks[risk] = on or nil
      end)
    check.risk = risk
    checks[#checks + 1] = check
  end
  checks[#checks + 1] = create_check(bar, #checks + 1, "Hide unscored",
    function(f) return f.hideUnscored == true end,
    function(f, on) f.hideUnscored = on end)
  return checks
end

local function create_headers(container)
  local bar = CreateFrame("Frame", nil, container)
  bar:SetHeight(HEADER_HEIGHT)
  bar:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -HEADERS_TOP)
  bar:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, -HEADERS_TOP)
  local headers = {}
  for i, col in ipairs(COLUMNS) do
    local text = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetHeight(HEADER_HEIGHT)
    text:SetJustifyH(col.right and "RIGHT" or "LEFT")
    text:SetText(col.label)
    headers[i] = text
  end
  place_cells(bar, headers)
  return headers
end

local function build(container)
  local bar = CreateFrame("Frame", nil, container)
  bar:SetPoint("TOPLEFT", container, "TOPLEFT", PAD, 0)
  bar:SetPoint("TOPRIGHT", container, "TOPRIGHT", -PAD, 0)
  bar:SetHeight(HEADERS_TOP)

  local created = { container = container, rows = {}, pool = {}, shown = 0 }
  created.header = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  created.header:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, -4)
  created.header:SetJustifyH("LEFT")
  created.status = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  created.status:SetPoint("TOPRIGHT", bar, "TOPRIGHT", 0, -4)
  created.status:SetJustifyH("RIGHT")
  created.checks = create_checks(bar)
  created.headers = create_headers(container)

  local scroll = CreateFrame("ScrollFrame", nil, container)
  scroll:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -SCROLL_TOP)
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
  created.empty:SetPoint("TOPLEFT", container, "TOPLEFT", PAD + 4, -(SCROLL_TOP + 8))
  created.empty:SetPoint("TOPRIGHT", container, "TOPRIGHT", -PAD - 4, -(SCROLL_TOP + 8))
  created.empty:SetJustifyH("LEFT")
  created.empty:Hide()

  view = created
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
      label = "Orders", icon = "Interface\\Icons\\INV_Misc_Note_06", order = 40, phase = 2,
      build = build,
      refresh = refresh,
    })
  end
end

function OrdersTab:OnEnable()
  -- One refresh follows 0.5 s after the last of a burst; MainWindow only refreshes a selected, visible tab.
  local handler = ns.FS:Wrap("OrdersTab", schedule_refresh)
  self:RegisterMessage(ns.Msg.ORDERS_CHANGED, handler)
  self:RegisterMessage(ns.Msg.CUSTOMERS_CHANGED, handler)
  self:RegisterEvent("GET_ITEM_INFO_RECEIVED", ns.FS:Wrap(SOURCE, on_item_info))
end

function OrdersTab:OnDisable()
  self:UnregisterAllMessages()
  self:UnregisterAllEvents()
  ns.FS:CancelDebounce(REFRESH_KEY)
end
