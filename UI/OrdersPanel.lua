local ADDON_NAME, ns = ...

-- OrdersPanel: our additions to Blizzard's crafting-orders list (ProfessionsFrame.OrdersPage), as three modules that
-- are each switched on and off by 1a's module toggles (Settings > Modules) and fail on their own:
--   OrdersRowAddons   per order row: a tint for VIP / repeat / blocked customers, a dark overlay on rows the filters
--                     hide, and a strip of cells (net profit, score, risk count with a tooltip, Add to Queue).
--   OrdersSidePanel   a panel docked at ProfessionsFrame's right edge while the order list is shown: risk filters,
--                     public claims remaining, the best claimable order and the Claim Best Order button.
--   OrderViewWarning  a line above the order detail view for a blocked or VIP customer.
--
-- No taint (design rules 2 and 7): every frame here is our own. The cells live in our own container (a child of the
-- order list's ScrollBox, anchored over it, clipping its children) and are anchored to Blizzard's rows; nothing is
-- ever assigned on a Blizzard frame or table, and no Blizzard method that changes state is called. Blizzard's code
-- gets only post-hooks: hooksecurefunc on OrdersPage:ShowOrders / :ShowBuckets and OrderView:SetOrder,
-- ScrollUtil.AddInitializedFrameCallback / AddReleasedFrameCallback on the ScrollBox, and HookScript OnShow / OnHide on
-- the BrowseFrame. The row layout is measured read-only (zero-touch, as in RecipeListLabels): the item-name cell's
-- right edge and the end of its text (GetRight / GetLeft / GetStringWidth), once Blizzard has filled the row
-- (OnInitializedFrame), and again in a re-fit pass on the next frame (1a's Debounce, coalesced) after rows were
-- initialised or item data arrived while the list is on screen, since Blizzard can write the name after our callback.
-- The cell strip sits at the right of the item-name column and gives way to the name (H1-6): the profit cell goes
-- first, then the whole strip; our cells never cover Blizzard's item name.
--
-- Claiming (design rule 3): Orders:ClaimBest (C_CraftingOrders.ClaimOrder is HasRestrictions) is called only as a
-- direct call inside the Claim Best Order button's OnClick handler (tests/orders/claim_click_only_spec.lua enforces
-- it). The best-order line comes from Orders:GetBestCandidate, which chooses exactly as ClaimBest does, so the button
-- claims what the panel shows.
--
-- Attachment: each module has its own AttachIfReady, run from ADDON_LOADED("Blizzard_Professions") and from OnEnable
-- when that addon is already loaded; hooks are installed once per session (they cannot be removed) and their bodies
-- run through Guard, so they do nothing while their module is off and an error turns off that module only. A missing
-- hook target is logged as "hook target missing: <path>", announced once and turns the module off with :Disable()
-- (the stored setting stays on, so the next session tries again).
--
-- Display rules: unknown money is "?" in a cell and "no price" in text (never 0); an estimate gets "~"; a recraft
-- order shows "recraft" and an unknown concentration value "conc?" in the score cell, with the full reason in the
-- risk tooltip ("Recraft — judge manually", "Concentration value unknown"), never a generic "no price".
local M = {}
ns.UI = ns.UI or {}
ns.UI.OrdersPanel = M

local ROWS, SIDE, WARN = "OrdersRowAddons", "OrdersSidePanel", "OrderViewWarning"
local RowAddons = ns.FS:NewModule(ROWS, "AceEvent-3.0")
local SidePanel = ns.FS:NewModule(SIDE, "AceEvent-3.0")
local Warning = ns.FS:NewModule(WARN, "AceEvent-3.0")

local PROFESSIONS_ADDON = "Blizzard_Professions"
local DOT, EM_DASH, ELLIPSIS = "\194\183", "\226\128\148", "\226\128\166"
local COPPER_PER_SILVER, COPPER_PER_GOLD = 100, 10000

-- Row layout. Blizzard's flat order table (ProfessionsCraftingOrderPageMixin:SetupTable, 12.1.5) is the item-name
-- fill column, then fixed columns Customer 160, Tip 160, Reagents 90 and Expiration 60: 470 after the item name when
-- the row cannot be measured yet.
local FIXED_COLUMNS = 470
local STRIP_HEIGHT, CELL_WIDTH, RISK_WIDTH, ADD_SIZE, WARN_SIZE, CELL_GAP = 16, 44, 22, 16, 14, 2
local CORE_WIDTH = ADD_SIZE + CELL_GAP + RISK_WIDTH + CELL_GAP + CELL_WIDTH   -- [score] [risk] [+]: always together
local WARN_SLOT, PROFIT_SLOT = WARN_SIZE + CELL_GAP, CELL_WIDTH + CELL_GAP
local STRIP_WIDTH = CORE_WIDTH + WARN_SLOT + PROFIT_SLOT
local PAD, GAP = 6, 4
local CONTAINER_LEVELS = 20   -- our container sits this many frame levels above the ScrollBox (rows are ~2-4 above)
local TINTS = {
  vip = { 1, 0.82, 0, 0.18 },
  blocked = { 1, 0.1, 0.1, 0.25 },
  ["repeat"] = { 0.3, 0.7, 1, 0.12 },
}
M.HIGHLIGHT_COLORS = TINTS   -- RowModel highlight -> { r, g, b, a }; read-only (the Orders tab tints rows with it)
local DIM = { 0, 0, 0, 0.55 }
local TEXT_COLORS = { green = { 0.25, 1, 0.25 }, red = { 1, 0.25, 0.25 }, grey = { 0.62, 0.62, 0.62 },
  gold = { 1, 0.82, 0 }, white = { 1, 1, 1 } }
local TONES = { good = TEXT_COLORS.green, bad = TEXT_COLORS.red, warn = TEXT_COLORS.gold, plain = TEXT_COLORS.white }
local WARNING_ICON = "Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew"

-- Side panel.
local SIDE_WIDTH, SIDE_PAD, CHECK_SIZE = 220, 10, 22
local BACKDROP = {
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 },
}
local BEST_NONE = {
  disabled = "Orders module is off",
  noProfession = "open a profession",
  alreadyClaimed = "you already have a claimed order",
  none = "none claimable",
}
local CLAIM_REFUSED = {
  disabled = "The Orders module is off",
  noProfession = "Open a profession first",
  alreadyClaimed = "You already have a claimed order",
  busy = "Still waiting for the last claim",
  none = "No order meets your claim rules",
  stale = "That order is gone; the list was refreshed",
}

---------------------------------------------------------------------------
-- Pure helpers
---------------------------------------------------------------------------

local function orders() return ns.FS:GetModule("Orders", true) end
local function customers() return ns.FS:GetModule("Customers", true) end

local function flags_of(view)
  return type(view) == "table" and type(view.flags) == "table" and view.flags or {}
end

local function is_money(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- Runs fn(...) in ns.FS:SafeCall(moduleName, ...) only while that module exists and is enabled; otherwise does
-- nothing and returns false. Every hook and handler body of the three modules goes through it.
function M.Guard(moduleName, fn, ...)
  local module = ns.FS:GetModule(moduleName, true)
  if not (module and module:IsEnabled()) then return false end
  return ns.FS:SafeCall(moduleName, fn, ...)
end

-- OrderView + CustomerRecord|nil + filters|nil (default: the saved Orders filters) -> { profit, score, riskCount,
-- riskText, highlight, dimmed, estimated }. profit = view.net and score are copper or nil. riskText is the risk labels
-- joined with "\n" ("" without risks). highlight: "blocked" (the blockedCustomer risk, which is group-aware, or the
-- customer's own blocked tag), else "vip" (VIP tag), else "repeat" (2+ orders), else nil. dimmed = Orders:IsHidden.
function M.RowModel(view, customer, filters)
  local O = orders()
  local labels = O and O.RISK_LABELS or {}
  local risks = type(view.risks) == "table" and view.risks or {}
  local texts, blockedRisk = {}, false
  for i, risk in ipairs(risks) do
    texts[i] = labels[risk] or tostring(risk)
    if risk == "blockedCustomer" then blockedRisk = true end
  end
  local tags = type(customer) == "table" and type(customer.tags) == "table" and customer.tags or {}
  local past = type(customer) == "table" and type(customer.orders) == "table" and customer.orders or {}
  local highlight
  if blockedRisk or tags.blocked then
    highlight = "blocked"
  elseif tags.VIP then
    highlight = "vip"
  elseif #past >= 2 then
    highlight = "repeat"
  end
  local dimmed = O ~= nil and O.IsHidden ~= nil and O:IsHidden(view, filters) == true
  return {
    profit = view.net, score = view.score, riskCount = #risks, riskText = table.concat(texts, "\n"),
    highlight = highlight, dimmed = dimmed, estimated = flags_of(view).estimated == true,
  }
end

-- Compact signed money for a narrow cell, in its largest unit: "+12g", "-4g", "+45s", "+7c", "0g"; nil for unknown.
-- Profits are rounded toward zero and losses away from it, so a cell never looks better than the order: +12.9g is
-- "+12g", -3.9g is "-4g" (a loss just under 1g reads "-1g", never "-100s").
local function compact(copper)
  if not is_money(copper) then return nil end
  if copper > 0 then
    local abs = math.floor(copper)
    if abs == 0 then return "0g" end
    if abs >= COPPER_PER_GOLD then return ("+%dg"):format(math.floor(abs / COPPER_PER_GOLD)) end
    if abs >= COPPER_PER_SILVER then return ("+%ds"):format(math.floor(abs / COPPER_PER_SILVER)) end
    return ("+%dc"):format(abs)
  elseif copper < 0 then
    local abs = math.ceil(-copper)
    if abs >= COPPER_PER_GOLD then return ("-%dg"):format(math.ceil(abs / COPPER_PER_GOLD)) end
    if abs >= COPPER_PER_SILVER then
      local silver = math.ceil(abs / COPPER_PER_SILVER)
      if silver * COPPER_PER_SILVER >= COPPER_PER_GOLD then return "-1g" end
      return ("-%ds"):format(silver)
    end
    return ("-%dc"):format(abs)
  end
  return "0g"
end

local function sign_color(copper)
  if not is_money(copper) or compact(copper) == "0g" then return TEXT_COLORS.grey end
  return copper > 0 and TEXT_COLORS.green or TEXT_COLORS.red
end

-- The profit cell: the order's net ("?" when unknown), "~" before an estimate, "?" after it when a price is missing.
-- A recraft is not evaluated at all (judged manually): an em dash, not "?".
function M.ProfitText(view)
  if flags_of(view).recraft then return EM_DASH end
  local text = compact(view.net)
  if not text then return "?" end
  local flags = flags_of(view)
  if flags.noPrice then text = text .. "?" end
  if flags.estimated then text = "~" .. text end
  return text
end

-- The score cell: "recraft" (judged manually), "conc?" (the concentration needed has no known value), "?" (no
-- score), else the score with "~" before an estimate.
function M.ScoreText(view)
  local flags = flags_of(view)
  if flags.recraft then return "recraft" end
  if flags.unknownConcentrationValue then return "conc?" end
  local text = compact(view.score)
  if not text then return "?" end
  if flags.estimated then text = "~" .. text end
  return text
end

-- Why a row's numbers are missing or uncertain, in full, for the risk tooltip. A recraft says only that.
function M.Notes(view)
  local flags, notes = flags_of(view), {}
  if flags.recraft then
    notes[1] = "Recraft " .. EM_DASH .. " judge manually"
    return notes
  end
  if flags.unknownConcentrationValue then notes[#notes + 1] = "Concentration value unknown" end
  if flags.noPrice then notes[#notes + 1] = is_money(view.net) and "Some prices missing" or "No price" end
  if flags.unknownRecipe then notes[#notes + 1] = "Recipe not learned" end
  if flags.estimated then notes[#notes + 1] = "Estimate (no calibration)" end
  if flags.unpricedReward then notes[#notes + 1] = "Some rewards have no price" end
  if flags.stalePrice then notes[#notes + 1] = "Prices are old" end
  return notes
end

-- "<itemText> · net <money> · tip vs your median <+N%|-N%|n/a>", N = floor((tip / median - 1) * 100 + 0.5). An
-- estimated net gets "~"; an unknown one is "no price". The caller passes the item's hyperlink when it is cached,
-- otherwise tostring(itemID), and Ledger:Benchmark's result (nil: no benchmark yet).
function M.BestText(itemText, view, benchmark)
  local net = view.net
  local netText = "no price"
  if is_money(net) then netText = (flags_of(view).estimated and "~" or "") .. ns.UI.FormatMoney(net) end
  local pct = "n/a"
  local tip, median = view.tip, type(benchmark) == "table" and benchmark.median or nil
  if is_money(tip) and is_money(median) and median > 0 then
    pct = ("%+d%%"):format(math.floor((tip / median - 1) * 100 + 0.5))
  end
  return ("%s %s net %s %s tip vs your median %s"):format(tostring(itemText), DOT, netText, DOT, pct)
end

-- The Queue:Add entry for an order (one craft for the order, its customer-provided reagents, the minimum quality as
-- the target when above 1, concentration when the score assumed it and it reaches the target), or nil for a recraft
-- (not a fresh craft), a recipe the character does not know (flags.unknownRecipe) or a view without a recipe.
function M.QueueEntry(view)
  local flags = flags_of(view)
  if type(view) ~= "table" or type(view.recipeID) ~= "number" or flags.recraft or flags.unknownRecipe then return nil end
  local entry = { recipeID = view.recipeID, quantity = 1, orderID = view.orderID, charKey = view.charKey }
  if type(view.minQuality) == "number" and view.minQuality > 1 then entry.targetQuality = view.minQuality end
  local unreachable = false
  for _, risk in ipairs(type(view.risks) == "table" and view.risks or {}) do
    if risk == "unreachableQuality" then unreachable = true end
  end
  -- Concentration that cannot reach the minimum quality anyway is not spent.
  if view.usedConcentration and not unreachable then entry.useConcentration = true end
  local provided = type(view.input) == "table" and view.input.provided or nil
  if type(provided) == "table" and next(provided) ~= nil then
    entry.providedReagents = {}
    for itemID, qty in pairs(provided) do entry.providedReagents[itemID] = qty end
  end
  return entry
end

-- Adds the order's QueueEntry to the queue unless an entry for the same order is already queued (the Add to Queue
-- of the row cells and of the Orders tab). Returns the result line and its tone ("good" | "warn" | "bad"), or nil
-- when the view cannot be queued (QueueEntry nil) or there is no Queue module.
function M.AddToQueue(view)
  local entry = M.QueueEntry(view)
  local queue = ns.FS:GetModule("Queue", true)
  if not (entry and queue) then return nil end
  for _, e in ipairs(queue:GetEntries() or {}) do
    if e.orderID ~= nil and e.orderID == entry.orderID then return "Already in the queue", "warn" end
  end
  if queue:Add(entry) then return "Added to the queue", "good" end
  return "Could not add to the queue (saved data is read-only)", "bad"
end

---------------------------------------------------------------------------
-- Shared frame helpers
---------------------------------------------------------------------------

-- A table field of a Blizzard object (read only), or nil.
local function child(obj, key)
  if type(obj) ~= "table" then return nil end
  local value = obj[key]
  return type(value) == "table" and value or nil
end

-- A number from a read-only getter of a Blizzard object (obj:method()), or nil.
local function read_number(obj, method)
  if type(obj) ~= "table" or type(obj[method]) ~= "function" then return nil end
  local ok, value = pcall(obj[method], obj)
  if ok and type(value) == "number" then return value end
  return nil
end

-- Whether a Blizzard frame is on screen (read only).
local function is_visible(frame)
  if type(frame) ~= "table" or type(frame.IsVisible) ~= "function" then return false end
  local ok, visible = pcall(frame.IsVisible, frame)
  return ok and visible and true or false
end

local function set_shown(region, shown)
  if shown then region:Show() else region:Hide() end
end

local function text(parent, template)
  return parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
end

local function color_text(fontString, color)
  fontString:SetTextColor(color[1], color[2], color[3])
end

local function professions_ready()
  return C_AddOns.IsAddOnLoaded(PROFESSIONS_ADDON) and ProfessionsFrame ~= nil
end

local function current_profession()
  local api = C_TradeSkillUI
  local info = api and api.GetChildProfessionInfo and api.GetChildProfessionInfo()
  return type(info) == "table" and info.profession or nil
end

-- The item's hyperlink when the client has it cached, else nil.
local function cached_link(itemID)
  local api = C_Item
  if itemID == nil or type(api) ~= "table" or type(api.GetItemInfo) ~= "function" then return nil end
  local _, link = api.GetItemInfo(itemID)
  return type(link) == "string" and link or nil
end

-- The item's hyperlink when cached, otherwise its ID as text.
local function item_text(itemID)
  return cached_link(itemID) or tostring(itemID)
end

local announced = {}  -- [module name] = true once its missing hook target was announced this session

-- A hook target is missing (Blizzard's UI changed): log it, say so once, and turn the module off for this session
-- with :Disable() (its stored setting stays on, so the next session tries again).
local function hook_target_missing(module, name, path)
  ns.FS:LogError(name, "hook target missing: " .. path)
  if not announced[name] then
    announced[name] = true
    print(("FabricationStation: %s disabled (Blizzard UI changed)"):format(name))
  end
  module:Disable()
end

-- Side panel result line, used by the row cells' Add to Queue too (defined with the side panel below).
local set_result

---------------------------------------------------------------------------
-- OrdersRowAddons: cells on the order rows
---------------------------------------------------------------------------

local rowsAttached     -- hooks installed (once per session)
local rowsBox          -- the order list's ScrollBox
local container        -- our clipping container over it
local rowsOwner = {}   -- owner token of our ScrollBox callbacks
local cells = setmetatable({}, { __mode = "k" })  -- [Blizzard row] = our cell set
local REFIT_KEY = "ordersRowAddons.refit"
local apply_fit, schedule_refit   -- defined with the re-fit pass below

-- The orderID a list element holds: nil for a bucket (grouped by recipe) or anything else.
local function order_id_of(elementData)
  local data = elementData
  if type(data) == "table" and type(data.GetData) == "function" then data = data:GetData() end
  local option = type(data) == "table" and data.option or nil
  return type(option) == "table" and option.orderID or nil
end

local function show_tooltip(owner, lines)
  if type(GameTooltip) ~= "table" or #lines == 0 then return end
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  for i, line in ipairs(lines) do
    local color = line.color
    if i == 1 then
      GameTooltip:SetText(line.text, color[1], color[2], color[3])
    else
      GameTooltip:AddLine(line.text, color[1], color[2], color[3], true)
    end
  end
  GameTooltip:Show()
end

local function hide_tooltip()
  if type(GameTooltip) == "table" then GameTooltip:Hide() end
end

-- The risk labels (red) then the notes (grey) of the row's view.
local function risk_tooltip(c)
  local lines = {}
  local labels = c.model and c.model.riskText or ""
  for label in labels:gmatch("[^\n]+") do lines[#lines + 1] = { text = label, color = TEXT_COLORS.red } end
  for _, note in ipairs(c.notes or {}) do lines[#lines + 1] = { text = note, color = TEXT_COLORS.grey } end
  show_tooltip(c.risk, lines)
end

local function add_to_queue(c)
  local O = orders()
  local view = O and c.orderID ~= nil and O:GetView(c.orderID) or nil
  local message, tone = M.AddToQueue(view)
  if message then set_result(message, tone) end
end

local function new_cells(row)
  local c = { dimmed = false, warnShown = false, fit = "all" }
  local frame = CreateFrame("Frame", nil, container)
  frame:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
  frame:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
  c.frame = frame
  c.tintTexture = frame:CreateTexture(nil, "BACKGROUND")
  c.tintTexture:SetAllPoints(frame)
  c.dimTexture = frame:CreateTexture(nil, "OVERLAY")
  c.dimTexture:SetAllPoints(frame)
  c.dimTexture:SetColorTexture(DIM[1], DIM[2], DIM[3], DIM[4])

  -- The strip, right to left: [profit] [warning] [score] [risk] [+]. Positions are fixed offsets from its right edge;
  -- only profit moves (left of the warning icon when that shows).
  local strip = CreateFrame("Frame", nil, frame)
  strip:SetSize(STRIP_WIDTH, STRIP_HEIGHT)
  c.strip = strip

  c.add = CreateFrame("Button", nil, strip)
  c.add:SetSize(ADD_SIZE, ADD_SIZE)
  c.add:SetPoint("RIGHT", strip, "RIGHT", 0, 0)
  c.add:SetNormalFontObject("GameFontNormal")
  c.add:SetText("+")
  c.add:SetScript("OnClick", function() M.Guard(ROWS, add_to_queue, c) end)
  c.add:SetScript("OnEnter", function(button)
    M.Guard(ROWS, show_tooltip, button, { { text = "Add to queue", color = TEXT_COLORS.white } })
  end)
  c.add:SetScript("OnLeave", hide_tooltip)

  c.risk = CreateFrame("Frame", nil, strip)
  c.risk:SetSize(RISK_WIDTH, STRIP_HEIGHT)
  c.risk:SetPoint("RIGHT", strip, "RIGHT", -(ADD_SIZE + CELL_GAP), 0)
  c.risk:EnableMouse(true)
  c.riskCount = text(c.risk, "GameFontNormalSmall")
  c.riskCount:SetAllPoints(c.risk)
  c.risk:SetScript("OnEnter", function() M.Guard(ROWS, risk_tooltip, c) end)
  c.risk:SetScript("OnLeave", hide_tooltip)

  c.score = text(strip)
  c.score:SetSize(CELL_WIDTH, STRIP_HEIGHT)
  c.score:SetJustifyH("RIGHT")
  c.score:SetPoint("RIGHT", strip, "RIGHT", -(ADD_SIZE + CELL_GAP + RISK_WIDTH + CELL_GAP), 0)

  c.warn = strip:CreateTexture(nil, "OVERLAY")
  c.warn:SetTexture(WARNING_ICON)
  c.warn:SetSize(WARN_SIZE, WARN_SIZE)
  c.warn:SetPoint("RIGHT", strip, "RIGHT", -CORE_WIDTH - CELL_GAP, 0)

  c.profit = text(strip)
  c.profit:SetSize(CELL_WIDTH, STRIP_HEIGHT)
  c.profit:SetJustifyH("RIGHT")
  cells[row] = c
  return c
end

-- Places the strip at the right of the item-name column (measured read-only; Blizzard's fixed columns otherwise) and
-- makes it give way to Blizzard's item name (hotfix H1-6 rule: our cells never cover the name). With room for
-- everything: "all"; else without the profit cell (score, risk and the warning icon stay): "noProfit"; else no strip
-- at all: "none" (the side panel and the Orders tab still carry the numbers). A row that cannot be measured keeps
-- everything. Only getters are called on Blizzard's row, its item-name cell and that cell's Text.
local function fit(c, row, warn)
  local itemCell = type(row.cells) == "table" and child(row.cells, 1) or nil
  local reserve = FIXED_COLUMNS
  local rowRight, cellRight = read_number(row, "GetRight"), read_number(itemCell, "GetRight")
  if rowRight and cellRight and rowRight >= cellRight then reserve = rowRight - cellRight end
  c.strip:ClearAllPoints()
  c.strip:SetPoint("RIGHT", row, "RIGHT", -(reserve + PAD), 0)

  local nameText = child(itemCell, "Text")
  local rowLeft, rowWidth = read_number(row, "GetLeft"), read_number(row, "GetWidth")
  local textLeft, textWidth = read_number(nameText, "GetLeft"), read_number(nameText, "GetStringWidth")
  if not (rowLeft and rowWidth and textLeft and textWidth) then return "all" end
  local nameEnd = textLeft + textWidth - rowLeft         -- from the row's left edge
  local stripRight = rowWidth - reserve - PAD
  local core = CORE_WIDTH + (warn and WARN_SLOT or 0)
  local function fits(width) return nameEnd + GAP <= stripRight - width end
  if fits(core + PROFIT_SLOT) then return "all" end
  if fits(core) then return "noProfit" end
  return "none"
end

local function hide_row(row)
  local c = cells[row]
  if c then c.frame:Hide() end
end

local function hide_all_cells()
  for _, c in pairs(cells) do c.frame:Hide() end
end

-- Fits a row's strip to Blizzard's item name as it is now (see fit) and shows the parts that have room.
function apply_fit(c, row)
  c.fit = fit(c, row, c.blocked)
  c.warnShown = c.blocked == true and c.fit ~= "none"
  set_shown(c.warn, c.warnShown)
  c.profit:ClearAllPoints()
  c.profit:SetPoint("RIGHT", c.strip, "RIGHT", -(CORE_WIDTH + CELL_GAP + (c.warnShown and WARN_SLOT or 0)), 0)
  set_shown(c.profit, c.fit == "all")
  set_shown(c.strip, c.fit ~= "none")
end

-- Re-fit pass (fit only; values and tint stay): over the ScrollBox's current frames, so a released row is never
-- touched. Our OnInitializedFrame callback can run before Blizzard's table builder writes the item name (callbacks
-- of different owners run in no fixed order), and an uncached name arrives later, so a row measured at
-- initialisation may have seen a stale or empty name. The pass runs on the next frame, coalesced through 1a's
-- Debounce, after rows were initialised and whenever item data arrives while the list is on screen.
local function refit_rows()
  if not (rowsBox and type(rowsBox.ForEachFrame) == "function") then return end
  rowsBox:ForEachFrame(function(row)
    local c = cells[row]
    if c and c.frame:IsShown() then apply_fit(c, row) end
  end)
end

local refitPass = ns.FS:Wrap(ROWS, function()
  if RowAddons:IsEnabled() then refit_rows() end
end)

function schedule_refit()
  ns.FS:Debounce(REFIT_KEY, 0, refitPass)
end

-- ITEM_DATA_LOAD_RESULT / GET_ITEM_INFO_RECEIVED are listened to only while the cells are attached and the order list
-- is on screen (the ScrollBox's OnShow / OnHide), and never while the module is off.
local ITEM_EVENTS = { "ITEM_DATA_LOAD_RESULT", "GET_ITEM_INFO_RECEIVED" }
local listening = false

local function listen_for_items(on)
  on = on and RowAddons:IsEnabled() or false
  if on == listening then return end
  listening = on
  for _, event in ipairs(ITEM_EVENTS) do
    if on then
      RowAddons:RegisterEvent(event, function() M.Guard(ROWS, schedule_refit) end)
    else
      RowAddons:UnregisterEvent(event)
    end
  end
end

-- Shows the cells of one row for its element, or hides them when it holds no order or the order is not scored.
-- Runs once Blizzard has filled the row (OnInitializedFrame), so a recycled row is measured with its new item name.
local function show_row(row, elementData)
  local O = orders()
  local orderID = order_id_of(elementData)
  local view = (O and orderID ~= nil) and O:GetView(orderID) or nil
  if not (view and container) then
    hide_row(row)
    return
  end
  local c = cells[row] or new_cells(row)
  local cust = customers()
  local record = (cust and view.customer) and cust:Get(view.customer) or nil
  local model = M.RowModel(view, record)
  c.orderID, c.model, c.notes = orderID, model, M.Notes(view)

  local tint = model.highlight and TINTS[model.highlight] or nil
  c.tint, c.tintColor = model.highlight, tint
  if tint then c.tintTexture:SetColorTexture(tint[1], tint[2], tint[3], tint[4]) end
  set_shown(c.tintTexture, tint ~= nil)
  c.dimmed = model.dimmed
  set_shown(c.dimTexture, model.dimmed)
  c.strip:SetAlpha(model.dimmed and 0.6 or 1)

  c.profit:SetText(M.ProfitText(view))
  color_text(c.profit, sign_color(view.net))
  c.score:SetText(M.ScoreText(view))
  color_text(c.score, sign_color(view.score))
  if model.riskCount > 0 or #c.notes > 0 then
    c.riskCount:SetText(model.riskCount > 0 and tostring(model.riskCount) or "i")
    color_text(c.riskCount, model.riskCount > 0 and TEXT_COLORS.red or TEXT_COLORS.grey)
    c.risk:Show()
  else
    c.risk:Hide()
  end
  set_shown(c.add, M.QueueEntry(view) ~= nil and ns.FS:GetModule("Queue", true) ~= nil)

  c.blocked = model.highlight == "blocked"
  apply_fit(c, row)
  c.frame:Show()
  -- Blizzard may write the name after us (callback order between owners is not fixed; uncached names come later).
  schedule_refit()
end

-- Every row on screen again (and only those): hides all cells, then shows the ScrollBox's current rows.
local function refresh_rows()
  hide_all_cells()
  if rowsBox and type(rowsBox.ForEachFrame) == "function" then
    rowsBox:ForEachFrame(function(row, elementData) show_row(row, elementData) end)
  end
end

local function attach_rows(self)
  if rowsAttached then
    refresh_rows()
    listen_for_items(is_visible(rowsBox))
    return
  end
  local page = child(ProfessionsFrame, "OrdersPage")
  if not (page and type(page.ShowOrders) == "function") then
    return hook_target_missing(self, ROWS, "ProfessionsFrame.OrdersPage.ShowOrders")
  end
  if type(page.ShowBuckets) ~= "function" then
    return hook_target_missing(self, ROWS, "ProfessionsFrame.OrdersPage.ShowBuckets")
  end
  local box = child(child(child(page, "BrowseFrame"), "OrderList"), "ScrollBox")
  if not (box and type(box.HookScript) == "function") then
    return hook_target_missing(self, ROWS, "ProfessionsFrame.OrdersPage.BrowseFrame.OrderList.ScrollBox")
  end
  local util = ScrollUtil
  if not (type(util) == "table" and type(util.AddInitializedFrameCallback) == "function") then
    return hook_target_missing(self, ROWS, "ScrollUtil.AddInitializedFrameCallback")
  end
  if type(util.AddReleasedFrameCallback) ~= "function" then
    return hook_target_missing(self, ROWS, "ScrollUtil.AddReleasedFrameCallback")
  end

  container = CreateFrame("Frame", nil, box)
  container:SetPoint("TOPLEFT", box, "TOPLEFT", 0, 0)
  container:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", 0, 0)
  container:SetClipsChildren(true)
  container:SetFrameLevel((read_number(box, "GetFrameLevel") or 0) + CONTAINER_LEVELS)
  rowsBox = box

  hooksecurefunc(page, "ShowOrders", function() M.Guard(ROWS, refresh_rows) end)
  hooksecurefunc(page, "ShowBuckets", function() M.Guard(ROWS, hide_all_cells) end)
  -- After Blizzard's initializer has filled the row (ScrollBoxListView: OnAcquiredFrame, the initializer, then
  -- OnInitializedFrame), as RecipeListLabels does; the released row's cells are hidden.
  util.AddInitializedFrameCallback(box, function(_, row, elementData) M.Guard(ROWS, show_row, row, elementData) end,
    rowsOwner)
  util.AddReleasedFrameCallback(box, function(_, row) M.Guard(ROWS, hide_row, row) end, rowsOwner)
  box:HookScript("OnShow", function() M.Guard(ROWS, listen_for_items, true) end)
  box:HookScript("OnHide", function()
    M.Guard(ROWS, function()
      listen_for_items(false)
      ns.FS:CancelDebounce(REFIT_KEY)
    end)
  end)
  rowsAttached = true
  refresh_rows()
  listen_for_items(is_visible(box))
end

function RowAddons:AttachIfReady()
  if rowsAttached or professions_ready() then M.Guard(ROWS, attach_rows, self) end
end

-- Test and diagnostics access: a row's cell set (nil before it was first shown) and our container.
function RowAddons:GetCells(row) return cells[row] end
function RowAddons:GetContainer() return container end

function RowAddons:OnEnable()
  self:RegisterEvent("ADDON_LOADED", function(_, name)
    if name == PROFESSIONS_ADDON then M.Guard(ROWS, attach_rows, self) end
  end)
  local function refresh() M.Guard(ROWS, refresh_rows) end
  self:RegisterMessage(ns.Msg.ORDERS_CHANGED, refresh)
  self:RegisterMessage(ns.Msg.CUSTOMERS_CHANGED, refresh)
  self:AttachIfReady()
end

function RowAddons:OnDisable()
  listen_for_items(false)
  ns.FS:CancelDebounce(REFIT_KEY)
  hide_all_cells()
end

---------------------------------------------------------------------------
-- OrdersSidePanel: filters, claims remaining, best order, Claim Best Order
---------------------------------------------------------------------------

local sideAttached     -- hooks installed (once per session)
local side             -- the built widgets (nil before the first attach)
local pendingClaim     -- orderID of the claim our button started, until its response

function set_result(message, tone)
  local panel = ns.FS:GetModule(SIDE, true)
  if not (side and panel and panel:IsEnabled()) then
    print("FabricationStation: " .. message)
    return
  end
  side.result:SetText(message)
  color_text(side.result, TONES[tone] or TONES.plain)
end

-- The name of a CraftingOrderResult value ("AlreadyClaimed"), else the value itself.
local function result_name(result)
  local results = Enum and Enum.CraftingOrderResult
  if type(results) == "table" then
    for name, value in pairs(results) do
      if value == result then return name end
    end
  end
  return tostring(result)
end

local function ok_result()
  local results = Enum and Enum.CraftingOrderResult
  return type(results) == "table" and results.Ok or 0
end

local function filters()
  local O = orders()
  return O and O:Settings().filters or nil
end

local waitingItem      -- itemID the best line waits for (GET_ITEM_INFO_RECEIVED), or nil
local failedItems = {} -- [itemID] = true: its data failed to load this session; shown as the ID, not asked again
local requesting       -- true while our RequestLoadItemDataByID call runs
local refresh_side

local function stop_waiting()
  if waitingItem == nil then return end
  waitingItem = nil
  SidePanel:UnregisterEvent("GET_ITEM_INFO_RECEIVED")
end

-- GET_ITEM_INFO_RECEIVED(itemID, success): the awaited item's data arrived, or cannot load (success false: remembered
-- for the session, so the ID is shown without asking again); the wait ends either way. The event is synchronous and can fire inside RequestLoadItemDataByID: the refresh in progress then
-- reads the link itself.
local function on_item_info(_, itemID, success)
  if waitingItem == nil or itemID ~= waitingItem then return end
  if success == false then failedItems[itemID] = true end
  stop_waiting()
  if not requesting then refresh_side() end
end

-- The best line's item text: the cached hyperlink, else the item ID while its data is requested. As in hotfix H1's
-- shopping-list retry (Modules/QueueCraft.lua), the wait is registered before the request, so data that arrives
-- inside the request is not missed; one item is awaited at a time and the event is unregistered when the wait ends
-- (arrival, another best order, the panel hiding, the module turning off).
local function best_item_text(itemID)
  local link = cached_link(itemID)
  if link then
    stop_waiting()
    return link
  end
  local api = C_Item
  if waitingItem ~= itemID and itemID ~= nil and not failedItems[itemID] and type(api) == "table"
    and type(api.RequestLoadItemDataByID) == "function" then
    stop_waiting()
    waitingItem = itemID
    SidePanel:RegisterEvent("GET_ITEM_INFO_RECEIVED", function(...) M.Guard(SIDE, on_item_info, ...) end)
    requesting = true
    local ok, err = pcall(api.RequestLoadItemDataByID, itemID)
    requesting = false
    if not ok then error(err, 0) end
  end
  return cached_link(itemID) or tostring(itemID)
end

function refresh_side()
  if not (side and side.frame:IsShown()) then return end
  local f = filters()
  for _, check in ipairs(side.checks) do check.button:SetChecked(f ~= nil and check.get(f) or false) end

  local profession = current_profession()
  local info = profession ~= nil and C_CraftingOrders.GetOrderClaimInfo(profession) or nil
  local remaining = type(info) == "table" and info.claimsRemaining or nil
  side.claims:SetText("Claims remaining: " .. (type(remaining) == "number" and tostring(remaining) or "--"))

  local O = orders()
  local view, reason
  if O and O.GetBestCandidate then view, reason = O:GetBestCandidate() end
  if view then
    local ledger = ns.FS:GetModule("Ledger", true)
    local benchmark = ledger and ledger.Benchmark and ledger:Benchmark(view.recipeID, nil) or nil
    side.best:SetText("Best: " .. M.BestText(best_item_text(view.itemID), view, benchmark))
  else
    stop_waiting()
    side.best:SetText("Best: " .. (BEST_NONE[reason] or "none claimable"))
  end
  side.claimEnabled = view ~= nil
  side.claim:SetEnabled(side.claimEnabled)
end

local function on_claim_clicked(view, reason)
  if view then
    pendingClaim = view.orderID
    set_result("Claiming " .. item_text(view.itemID) .. ELLIPSIS, "plain")
  else
    set_result(CLAIM_REFUSED[reason] or ("Nothing claimed (" .. tostring(reason) .. ")"), "warn")
  end
  refresh_side()
end

-- CRAFTINGORDERS_CLAIM_ORDER_RESPONSE(result, orderID) for the claim our button started (Blizzard's own Start Order
-- claims are not ours to report).
local function on_claim_response(_, result, orderID)
  if pendingClaim == nil or (orderID ~= nil and orderID ~= pendingClaim) then return end
  pendingClaim = nil
  if result == ok_result() then
    set_result("Claimed " .. EM_DASH .. " open it from the order list", "good")
  else
    set_result(("Claim failed (%s)"):format(result_name(result)), "bad")
  end
  refresh_side()
end

local function make_check(parent, anchor, label, get, set)
  local button = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  button:SetSize(CHECK_SIZE, CHECK_SIZE)
  button:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
  local labelText = text(parent)
  labelText:SetPoint("LEFT", button, "RIGHT", 2, 0)
  labelText:SetText(label)
  button:SetScript("OnClick", function(clicked)
    M.Guard(SIDE, function()
      local f = filters()
      if not f then return end
      set(f, clicked:GetChecked() and true or false)
      SidePanel:SendMessage(ns.Msg.ORDERS_CHANGED)
    end)
  end)
  return { button = button, label = labelText, get = get }
end

local function build_side()
  local frame = CreateFrame("Frame", "FabricationStationOrdersPanel", UIParent, "BackdropTemplate")
  frame:SetWidth(SIDE_WIDTH)
  frame:SetPoint("TOPLEFT", ProfessionsFrame, "TOPRIGHT", 2, 0)
  frame:SetPoint("BOTTOMLEFT", ProfessionsFrame, "BOTTOMRIGHT", 2, 0)
  frame:SetBackdrop(BACKDROP)
  frame:SetBackdropColor(0, 0, 0, 0.85)
  frame:Hide()
  local v = { frame = frame, checks = {}, claimEnabled = false }

  v.title = text(frame, "GameFontNormalLarge")
  v.title:SetPoint("TOPLEFT", frame, "TOPLEFT", SIDE_PAD, -SIDE_PAD)
  v.title:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -SIDE_PAD, -SIDE_PAD)
  v.title:SetText("FabricationStation")
  v.filterHeader = text(frame, "GameFontNormal")
  v.filterHeader:SetPoint("TOPLEFT", v.title, "BOTTOMLEFT", 0, -8)
  v.filterHeader:SetText("Hide orders with:")

  local O = orders()
  local anchor = v.filterHeader
  for _, risk in ipairs(O and O.RISKS or {}) do
    local check = make_check(frame, anchor, (O.RISK_LABELS or {})[risk] or risk,
      function(f) return type(f.hideRisks) == "table" and f.hideRisks[risk] == true end,
      function(f, on)
        if type(f.hideRisks) ~= "table" then f.hideRisks = {} end
        f.hideRisks[risk] = on or nil
      end)
    v.checks[#v.checks + 1] = check
    anchor = check.button
  end
  local unscored = make_check(frame, anchor, "Hide unscored",
    function(f) return f.hideUnscored == true end,
    function(f, on) f.hideUnscored = on end)
  v.checks[#v.checks + 1] = unscored

  v.claims = text(frame)
  v.claims:SetPoint("TOPLEFT", unscored.button, "BOTTOMLEFT", 0, -10)
  v.claims:SetPoint("RIGHT", frame, "RIGHT", -SIDE_PAD, 0)
  v.claims:SetJustifyH("LEFT")

  v.claim = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  v.claim:SetSize(SIDE_WIDTH - 2 * SIDE_PAD, 22)
  v.claim:SetPoint("TOPLEFT", v.claims, "BOTTOMLEFT", 0, -6)
  v.claim:SetText("Claim Best Order")
  -- The only caller of Orders:ClaimBest, directly in this click handler (design rule 3).
  v.claim:SetScript("OnClick", ns.FS:Wrap(SIDE, function()
    if not SidePanel:IsEnabled() then return end
    local O2 = orders()
    if not O2 then return end
    local view, reason = O2:ClaimBest()
    on_claim_clicked(view, reason)
  end))

  v.best = text(frame)
  v.best:SetPoint("TOPLEFT", v.claim, "BOTTOMLEFT", 0, -6)
  v.best:SetPoint("RIGHT", frame, "RIGHT", -SIDE_PAD, 0)
  v.best:SetJustifyH("LEFT")
  v.best:SetWordWrap(true)

  v.result = text(frame)
  v.result:SetPoint("TOPLEFT", v.best, "BOTTOMLEFT", 0, -6)
  v.result:SetPoint("RIGHT", frame, "RIGHT", -SIDE_PAD, 0)
  v.result:SetJustifyH("LEFT")
  v.result:SetWordWrap(true)
  side = v
end

local function show_side()
  if not side then return end
  side.frame:Show()
  refresh_side()
end

local function hide_side()
  stop_waiting()
  if side then side.frame:Hide() end
end

local function browse_frame()
  return child(child(ProfessionsFrame, "OrdersPage"), "BrowseFrame")
end

-- Hooks the BrowseFrame's OnShow / OnHide once and shows the panel when the order list is already on screen (also
-- when the module is turned on again).
local function attach_side(self)
  local browse = browse_frame()
  if not sideAttached then
    if not (browse and type(browse.HookScript) == "function") then
      return hook_target_missing(self, SIDE, "ProfessionsFrame.OrdersPage.BrowseFrame")
    end
    if not side then build_side() end
    browse:HookScript("OnShow", function() M.Guard(SIDE, show_side) end)
    browse:HookScript("OnHide", function() M.Guard(SIDE, hide_side) end)
    sideAttached = true
  end
  if is_visible(browse) then show_side() end
end

function SidePanel:AttachIfReady()
  if sideAttached or professions_ready() then M.Guard(SIDE, attach_side, self) end
end

-- Shows a line under the best order (claim results, Add to Queue results). tone: "good" | "bad" | "warn" | "plain".
function SidePanel:SetResult(message, tone)
  set_result(message, tone)
end

-- Test and diagnostics access: the built widgets (nil before the first attach).
function SidePanel:GetView() return side end

function SidePanel:OnEnable()
  self:RegisterEvent("ADDON_LOADED", function(_, name)
    if name == PROFESSIONS_ADDON then M.Guard(SIDE, attach_side, self) end
  end)
  self:RegisterEvent("CRAFTINGORDERS_CLAIM_ORDER_RESPONSE", function(...) M.Guard(SIDE, on_claim_response, ...) end)
  local function refresh() M.Guard(SIDE, refresh_side) end
  self:RegisterMessage(ns.Msg.ORDERS_CHANGED, refresh)
  self:RegisterMessage(ns.Msg.CUSTOMERS_CHANGED, refresh)
  self:AttachIfReady()
end

function SidePanel:OnDisable()
  pendingClaim = nil
  hide_side()
end

---------------------------------------------------------------------------
-- OrderViewWarning: blocked / VIP customer above the order detail view
---------------------------------------------------------------------------

local warnAttached     -- hook installed (once per session)
local warn             -- { frame, text, tone }
local warnOrder        -- the CraftingOrderInfo last passed to OrderView:SetOrder

local function refresh_warning()
  if not warn then return end
  local order, cust, O = warnOrder, customers(), orders()
  local typeName = type(order) == "table" and O and O.ORDER_TYPES and O.ORDER_TYPES[order.orderType] or nil
  local name = type(order) == "table" and typeName ~= "npc" and cust and cust:NormalizeName(order.customerName) or nil
  local message, tone
  if name and cust:IsBlocked(name) then
    message, tone = "Blocked customer: " .. name, "red"
  elseif name then
    local record = cust:Get(name)
    local tags = type(record) == "table" and type(record.tags) == "table" and record.tags or {}
    if tags.VIP then
      local n = type(record.orders) == "table" and #record.orders or 0
      message, tone = ("VIP customer %s %d previous order%s"):format(DOT, n, n == 1 and "" or "s"), "gold"
    end
  end
  warn.tone = tone
  if not message then
    warn.frame:Hide()
    return
  end
  warn.text:SetText(message)
  color_text(warn.text, TEXT_COLORS[tone])
  warn.frame:Show()
end

local function set_warning_order(order)
  warnOrder = order
  refresh_warning()
end

-- The order Blizzard's detail view shows now (OrderView.order, which its SetOrder keeps; read only), or nil when the
-- view is not on screen.
local function open_order(orderView)
  if not is_visible(orderView) then return nil end
  return child(orderView, "order")
end

-- Hooks OrderView:SetOrder once; on every attach (also when the module is turned on again) the warning is rebuilt
-- from the order on screen, or cleared.
local function attach_warning(self)
  local orderView = child(child(ProfessionsFrame, "OrdersPage"), "OrderView")
  if warnAttached then
    warnOrder = open_order(orderView)
    refresh_warning()
    return
  end
  if not (orderView and type(orderView.SetOrder) == "function") then
    return hook_target_missing(self, WARN, "ProfessionsFrame.OrdersPage.OrderView.SetOrder")
  end
  local frame = CreateFrame("Frame", nil, orderView)
  frame:SetSize(400, 18)
  frame:SetPoint("BOTTOMLEFT", orderView, "TOPLEFT", 8, 2)
  frame:SetFrameLevel((read_number(orderView, "GetFrameLevel") or 0) + CONTAINER_LEVELS)
  frame:Hide()
  local line = text(frame, "GameFontNormal")
  line:SetPoint("LEFT", frame, "LEFT", 0, 0)
  line:SetJustifyH("LEFT")
  warn = { frame = frame, text = line }
  hooksecurefunc(orderView, "SetOrder", function(_, order) M.Guard(WARN, set_warning_order, order) end)
  warnAttached = true
  warnOrder = open_order(orderView)
  refresh_warning()
end

function Warning:AttachIfReady()
  if warnAttached or professions_ready() then M.Guard(WARN, attach_warning, self) end
end

-- Test and diagnostics access: { frame, text, tone } (nil before the first attach).
function Warning:GetView() return warn end

function Warning:OnEnable()
  self:RegisterEvent("ADDON_LOADED", function(_, name)
    if name == PROFESSIONS_ADDON then M.Guard(WARN, attach_warning, self) end
  end)
  self:RegisterMessage(ns.Msg.CUSTOMERS_CHANGED, function() M.Guard(WARN, refresh_warning) end)
  self:AttachIfReady()
end

function Warning:OnDisable()
  warnOrder = nil
  if warn then warn.frame:Hide() end
end
