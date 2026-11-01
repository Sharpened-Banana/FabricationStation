local ADDON_NAME, ns = ...
local L = ns.L

-- OrdersPanel: our additions to Blizzard's crafting-orders list (ProfessionsFrame.OrdersPage), as three modules that
-- are each switched on and off by 1a's module toggles (Settings > Modules) and fail on their own:
--   OrdersRowAddons   per order row: a tint for VIP / repeat / blocked customers, a dark overlay on rows the filters
--                     hide, a strip of cells (net profit, concentration, score, risk count with a tooltip, Add to Queue;
--                     the concentration cell is a small icon and the concentration the order needs to reach its minimum
--                     quality, red when you have less, a red cross when it cannot be reached, empty when none is
--                     needed; the score cell is blank while it would only repeat the profit shown beside it), a cover over
--                     Blizzard's Commission cell that replaces its gold with the compact commission and 20 px icons
--                     for the rewards of a patron order ("+N" counts those that do not fit; its tooltip gives the
--                     full commission, the rewards and what the order costs per knowledge point or Moxie; the info
--                     tooltip of the row lists the rewards too), and a cover over Blizzard's Reagents
--                     cell that replaces its "Some" / "None" / "All" with the reagents the crafter must supply (the
--                     allocation minus what the customer provides) that the character is short of: 20 px icons with
--                     the count needed in red (white when the owned count is unknown; a reagent already owned gets no
--                     icon), a green check when the customer provides every reagent or the character owns them all,
--                     or "?" when they are not known (a recraft, no result). Both have tooltips, the cover's listing
--                     every reagent (setting Orders.showRowIcons turns them off).
--   OrdersSidePanel   a panel docked at ProfessionsFrame's right edge while the order list is shown: risk filters,
--                     public claims remaining, the best claimable order and the Claim Best Order button; and, above the
--                     order list's top-left corner, the character's concentration for the profession shown (icon and
--                     current / max, the game's own quantity while readable, else the snapshot projected to now; a
--                     tooltip with the time to full), refreshed on show, on ORDERS_CHANGED / CUSTOMERS_CHANGED,
--                     on CURRENCY_DISPLAY_UPDATE (debounced) and once a minute, only while the page is shown.
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
-- first, then the whole strip; our cells never cover Blizzard's item name. The rewards are not in this column:
-- they are in the Commission cover (a column identified like the Reagents column, failing closed: no column, no cover,
-- and Blizzard's gold shows), the icons that fit right of the amount, the last visible slot becoming "+N".
-- The Reagents cover is replaced, not edited: Blizzard's cell and its text are never written (no SetText, SetAlpha or
-- Hide on them). Our own frame, in our own container, is anchored over the cell (measured read-only from the row's
-- column header, or its own cells when there is no header) with an opaque background of COVER_COLOR, so the word underneath cannot be seen. It fails closed: the cover goes only over a column
-- identified as Reagents (the header's own text, else the known five-column layout, headers sorted by position); on any
-- other layout, or on a row with no view of ours, there is no cover and Blizzard's text shows. Because the cover hides
-- the row's tint and Blizzard's hover highlight in that cell, it repaints both itself (the hover through post-hooks on
-- the row's OnEnter / OnLeave, installed once per row frame).
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
local DOT, EM_DASH = "\194\183", "\226\128\148"
local COPPER_PER_SILVER, COPPER_PER_GOLD = 100, 10000

-- Row layout. Blizzard's flat order table (ProfessionsCraftingOrderPageMixin:SetupTable, 12.1.5) is the item-name
-- fill column, then fixed columns Customer 160, Tip 160, Reagents 90 and Expiration 60: 470 after the item name when
-- the row cannot be measured yet.
local FIXED_COLUMNS = 470
local STRIP_HEIGHT, CELL_WIDTH, RISK_WIDTH, ADD_SIZE, WARN_SIZE, CELL_GAP = 16, 44, 22, 16, 14, 2
local CONC_WIDTH, CONC_ICON_SIZE = 34, 12   -- the concentration cell: a small icon and the amount
local SCORE_CORE = ADD_SIZE + CELL_GAP + RISK_WIDTH + CELL_GAP + CELL_WIDTH   -- [score] [risk] [+]
local CONC_SLOT = CONC_WIDTH + CELL_GAP
-- The strip, left to right: [profit] [conc] [warning] [score] [risk] [+]. [conc] [score] [risk] [+] are the core and
-- always stay together (the concentration an order needs matters more than a profit that repeats the score); the
-- warning icon and then the profit cell give way first.
local CORE_WIDTH = SCORE_CORE + CONC_SLOT
local WARN_SLOT, PROFIT_SLOT = WARN_SIZE + CELL_GAP, CELL_WIDTH + CELL_GAP
local STRIP_WIDTH = CORE_WIDTH + WARN_SLOT + PROFIT_SLOT
local PAD, GAP = 6, 4
local ICON_SIZE, ICON_GAP, MORE_WIDTH = 20, 2, 24   -- row icons: 20 px, 2 px apart; the "+N" slot has a width of its own
M.ICON_SIZE, M.ICON_GAP, M.MORE_WIDTH = ICON_SIZE, ICON_GAP, MORE_WIDTH   -- read-only (the specs derive their geometry)
-- The strip's measures, read-only (the specs derive their geometry from them).
M.LAYOUT = { CORE_WIDTH = CORE_WIDTH, SCORE_CORE = SCORE_CORE, CONC_SLOT = CONC_SLOT, WARN_SLOT = WARN_SLOT,
  PROFIT_SLOT = PROFIT_SLOT, STRIP_WIDTH = STRIP_WIDTH, PAD = PAD, GAP = GAP, CELL_GAP = CELL_GAP, FIXED_COLUMNS = FIXED_COLUMNS }
local TOOLTIP_ICON = 14                               -- the inline icon in a tooltip line (keeps the line height)
local UNKNOWN_ICON = 134400                           -- the question mark, for an icon the client cannot give
-- The Reagents cover's padding inside Blizzard's cell.
local COVER_PAD = 4
-- The cover goes only over a column that is identified as Reagents: by the header's own text (the global string below),
-- else by the known layout: five columns (name, Customer, Tip, Reagents, Expiration) whose fourth is 80 to 100 px wide
-- and ends where the last begins. Anything else gets no cover, and Blizzard's text shows.
local KNOWN_COLUMNS, REAGENTS_MIN, REAGENTS_MAX = 5, 80, 100
local REAGENTS_HEADER_GLOBAL = "PROFESSIONS_COLUMN_HEADER_REAGENTS"   -- unverified name, see the in-game checklist (P5-11)
-- The Commission (Tip) column is covered the same way and shows the commission and the reward icons: identified by the
-- header's own text (the unverified global names below), else as the third of the known five columns (about 160 px,
-- touching the Reagents column).
local TIP_HEADER_GLOBALS = { "PROFESSIONS_COLUMN_HEADER_TIP", "PROFESSIONS_COLUMN_HEADER_COMMISSION" }
local TIP_MIN, TIP_MAX = 120, 200
local AMOUNT_WIDTH = 44   -- the compact commission at the left of the Commission cover
local HOVER_COLOR = { 1, 1, 1, 0.1 }   -- the cover's own highlight while its row is hovered
-- The cover's opaque background, a dark colour close to the order list's own. (The list's background atlas cannot be
-- read from Blizzard's region without relying on its layout, so this is the one value to adjust.)
local COVER_COLOR = { 0.06, 0.05, 0.04, 1 }
M.COVER_COLOR = COVER_COLOR
local CHECK_ICON = "Interface\\RaidFrame\\ReadyCheck-Ready"
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
  disabled = L["Orders module is off"],
  noProfession = L["open a profession"],
  alreadyClaimed = L["you already have a claimed order"],
  none = L["none claimable"],
}
local CLAIM_REFUSED = {
  disabled = L["The Orders module is off"],
  noProfession = L["Open a profession first"],
  alreadyClaimed = L["You already have a claimed order"],
  busy = L["Still waiting for the last claim"],
  none = L["No order meets your claim rules"],
  stale = L["That order is gone; the list was refreshed"],
}
local REFRESH_REFUSED = {
  noProfession = CLAIM_REFUSED.noProfession,
  busy = L["Still waiting for the order list"],
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

-- Unsigned compact money for a narrow cell (a tip): "1,234g", "45s" under 1g, "7c" under 1s, rounded down as in
-- compact; nil for unknown money. A negative amount keeps compact's signed text.
function M.CompactMoney(copper)
  local text = compact(copper)
  if not text or copper < 0 then return text end
  local digits, unit = text:match("^%+?(%d+)(%a)$")
  if not digits then return text end
  local grouped = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  return grouped .. unit
end

-- The colour sign of an amount as its compact cell shows it: 1 (gain), -1 (loss), 0 (shown as "0g", e.g. under a
-- copper, or unknown). The board's cells and the Orders tab colour by it.
function M.Sign(copper)
  if not is_money(copper) or compact(copper) == "0g" then return 0 end
  return copper > 0 and 1 or -1
end

local function sign_color(copper)
  local sign = M.Sign(copper)
  if sign == 0 then return TEXT_COLORS.grey end
  return sign > 0 and TEXT_COLORS.green or TEXT_COLORS.red
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

-- What a patron order costs per knowledge point or Moxie it pays, as lines (none when the order pays for itself).
function M.CostNotes(view)
  local notes = {}
  local cost = type(view) == "table" and type(view.costPerReward) == "table" and view.costPerReward or {}
  if is_money(cost.knowledge) and cost.knowledge > 0 then
    notes[#notes + 1] = (L["Pays %s per knowledge point"]):format(ns.UI.FormatMoney(cost.knowledge))
  end
  if is_money(cost.moxie) and cost.moxie > 0 then
    notes[#notes + 1] = (L["Pays %s per Moxie"]):format(ns.UI.FormatMoney(cost.moxie))
  end
  return notes
end

-- Why a row's numbers are missing or uncertain, in full, for the risk tooltip. A recraft says only that.
function M.Notes(view)
  local flags, notes = flags_of(view), {}
  if flags.recraft then
    notes[1] = L["Recraft \226\128\148 judge manually"]
    return notes
  end
  if flags.unknownConcentrationValue then notes[#notes + 1] = L["Concentration value unknown"] end
  if flags.noPrice then notes[#notes + 1] = is_money(view.net) and L["Some prices missing"] or L["No price"] end
  if flags.unknownRecipe then
    -- With the notLearned risk the red label already says it; the grey line gives where to get the recipe (if known).
    local learnedRisk = false
    for _, risk in ipairs(type(view.risks) == "table" and view.risks or {}) do
      if risk == "notLearned" then learnedRisk = true end
    end
    local O = orders()
    local source = learnedRisk and O and O.RecipeSource and O.RecipeSource(view.recipeID) or nil
    if source then
      notes[#notes + 1] = source
    elseif not learnedRisk then
      notes[#notes + 1] = L["Recipe not learned"]
    end
  end
  if flags.estimated then notes[#notes + 1] = L["Estimate (no calibration)"] end
  if flags.unpricedReward then notes[#notes + 1] = L["Some rewards have no price"] end
  if flags.stalePrice then notes[#notes + 1] = L["Prices are old"] end
  for _, note in ipairs(M.CostNotes(view)) do notes[#notes + 1] = note end
  return notes
end

-- The quality an order's tip benchmark (Ledger:Benchmark) is asked for: the quality the order will be delivered at,
-- which is what the Ledger stores on a commission (the crafted quality). That is the evaluated expectedQuality, raised
-- to the order's minimum (an order is only delivered at its minimum or better), or the minimum alone without an
-- evaluation. Nil (all qualities) for a recipe without qualities (1 or less). The board and the Orders tab both use it.
function M.BenchmarkQuality(view)
  if type(view) ~= "table" then return nil end
  local result = type(view.result) == "table" and view.result or nil
  local expected = result and tonumber(result.expectedQuality) or nil
  local minimum = tonumber(view.minQuality)
  local q = (expected ~= nil and expected > 1) and expected or nil
  if minimum ~= nil and minimum > 1 and (q == nil or q < minimum) then q = minimum end
  return q
end

-- "<itemText> · net <money> · tip vs your median <+N%|-N%|n/a>", N = floor((tip / median - 1) * 100 + 0.5). An
-- estimated net gets "~"; an unknown one is "no price". The caller passes the item's hyperlink when it is cached,
-- otherwise tostring(itemID), and Ledger:Benchmark's result (nil: no benchmark yet).
function M.BestText(itemText, view, benchmark)
  local net = view.net
  local netText = L["no price"]
  if is_money(net) then netText = (flags_of(view).estimated and "~" or "") .. ns.UI.FormatMoney(net) end
  local pct = "n/a"
  local tip, median = view.tip, type(benchmark) == "table" and benchmark.median or nil
  if is_money(tip) and is_money(median) and median > 0 then
    pct = ("%+d%%"):format(math.floor((tip / median - 1) * 100 + 0.5))
  end
  return (L["%s %s net %s %s tip vs your median %s"]):format(tostring(itemText), DOT, netText, DOT, pct)
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
    if e.orderID ~= nil and e.orderID == entry.orderID then return L["Already in the queue"], "warn" end
  end
  if queue:Add(entry) then return L["Added to the queue"], "good" end
  return L["Could not add to the queue (saved data is read-only)"], "bad"
end

-- The order filters as checkbox descriptors, in display order: one per Orders.RISKS ({ key = risk, risk, label =
-- its RISK_LABELS text }) then "Hide unscored" ({ key = "hideUnscored" }). get(filters) -> bool, set(filters, on)
-- write Orders:Settings().filters in place. The side panel and the Orders tab build their checkboxes from it.
function M.FilterChecks()
  local O = orders()
  local list = {}
  for _, risk in ipairs(O and O.RISKS or {}) do
    list[#list + 1] = {
      key = risk, risk = risk, label = (O.RISK_LABELS or {})[risk] or risk,
      get = function(f) return type(f.hideRisks) == "table" and f.hideRisks[risk] == true end,
      set = function(f, on)
        if type(f.hideRisks) ~= "table" then f.hideRisks = {} end
        f.hideRisks[risk] = on or nil
      end,
    }
  end
  list[#list + 1] = {
    key = "hideUnscored", label = L["Hide unscored"],
    get = function(f) return f.hideUnscored == true end,
    set = function(f, on) f.hideUnscored = on end,
  }
  return list
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
    print((L["FabricationStation: %s disabled (Blizzard UI changed)"]):format(name))
  end
  module:Disable()
end

-- Side panel result line, used by the row cells' Add to Queue too (defined with the side panel below).
local set_result

---------------------------------------------------------------------------
-- Reward and reagent icons (pure helpers)
---------------------------------------------------------------------------

-- The concentration cell of a row: { mode, amount, available, charge } from the view and the points the character has
-- now (nil: unknown). mode: "amount" (the concentration the order needs to reach its minimum quality, in white),
-- "short" (more than is available: Orders' noConcentration risk, or amount > available; red), "unreachable" (the
-- minimum quality cannot be reached even with concentration: the risk unreachableQuality; a red cross), or nil (no
-- concentration is used: an empty cell). The amount is what Orders charges: view.concentrationCost, set only when
-- view.usedConcentration; charge = what it is worth in copper (nil while the rate is unknown).
-- [Task 10b] When the order is crafted without concentration but Orders recorded the concentration route it did not
-- take (view.concentrationAlternative), mode "alternative" (muted): amount = its points, charge and reagentCost =
-- that route's, plainCost = the reagent cost of the route taken (view.result.reagentCost); unknown ones are nil.
function M.ConcentrationCell(view, available)
  if type(view) ~= "table" then return {} end
  local have = type(available) == "number" and available == available and available or nil
  if view.usedConcentration ~= true then
    local alt = view.concentrationAlternative
    if type(alt) ~= "table" or type(alt.cost) ~= "number" or alt.cost <= 0 then return {} end
    local result = type(view.result) == "table" and view.result or {}
    return { mode = "alternative", amount = alt.cost, available = have,
      charge = is_money(alt.charge) and alt.charge or nil,
      reagentCost = is_money(alt.reagentCost) and alt.reagentCost or nil,
      plainCost = is_money(result.reagentCost) and result.reagentCost or nil }
  end
  local unreachable, noConcentration = false, false
  for _, risk in ipairs(type(view.risks) == "table" and view.risks or {}) do
    if risk == "unreachableQuality" then unreachable = true end
    if risk == "noConcentration" then noConcentration = true end
  end
  if unreachable then return { mode = "unreachable", available = have } end
  local amount = view.concentrationCost
  if type(amount) ~= "number" or amount <= 0 then return {} end
  local charge = is_money(view.concentrationCharge) and view.concentrationCharge or nil
  local short = noConcentration or (have ~= nil and amount > have)
  return { mode = short and "short" or "amount", amount = amount, available = have, charge = charge }
end

-- The concentration the character has now for the recipe's profession (Orders' own figure: the context's
-- concentrationFor, which projects the snapshot to now), or nil when unknown or unreadable.
local function available_concentration(view)
  local O = orders()
  if not (O and O.BuildContext and type(view) == "table" and view.charKey ~= nil and view.recipeID ~= nil) then return nil end
  local ok, value = pcall(function() return O:BuildContext(view.charKey).concentrationFor(view.recipeID) end)
  if ok and type(value) == "number" and value == value then return value end
  return nil
end

-- A fixed stand-in for the concentration icon, used while the profession's concentration currency cannot be asked.
local CONCENTRATION_ICON = "Interface\\Icons\\Spell_Holy_PowerInfusion"
local concentrationIcons = {}   -- [skillLineID] = texture, per session

-- The icon of a profession's concentration currency (C_TradeSkillUI.GetConcentrationCurrencyID(skillLine) then
-- C_CurrencyInfo.GetCurrencyInfo(id).iconFileID), else the fixed one. Never raises.
local function concentration_icon_for_line(line)
  if line and concentrationIcons[line] then return concentrationIcons[line] end
  local icon
  local trade, currencies = C_TradeSkillUI, C_CurrencyInfo
  if line and type(trade) == "table" and type(trade.GetConcentrationCurrencyID) == "function"
    and type(currencies) == "table" and type(currencies.GetCurrencyInfo) == "function" then
    local okID, id = pcall(trade.GetConcentrationCurrencyID, line)
    local okInfo, info = false, nil
    if okID and type(id) == "number" and id ~= 0 then okInfo, info = pcall(currencies.GetCurrencyInfo, id) end
    if okInfo and type(info) == "table" and type(info.iconFileID) == "number" then icon = info.iconFileID end
  end
  if icon then concentrationIcons[line] = icon end   -- only the currency's own answer is kept
  return icon or CONCENTRATION_ICON
end

-- The same for a recipe (its schematic's skill line).
local function concentration_icon(recipeID)
  local scanner = ns.FS:GetModule("Scanner", true)
  local ok, schematic = pcall(function() return scanner and scanner:GetSchematic(recipeID) end)
  return concentration_icon_for_line(ok and type(schematic) == "table" and schematic.skillLineID or nil)
end

-- How many of itemID the logged-in character owns (bags, bank, reagent bank and the warband bank: the game's own
-- count through Scanner), or nil when the game cannot tell (unknown is nil, never 0, so no snapshot stands in).
local function owned_count(itemID)
  local scanner = ns.FS:GetModule("Scanner", true)
  if not (scanner and type(scanner.GetLiveOwnedCount) == "function") then return nil end
  local ok, n = pcall(scanner.GetLiveOwnedCount, scanner, itemID, true)
  if ok and type(n) == "number" and n == n then return n end
  return nil
end

-- OrderView -> the rewards of its row: { kind = "reward", itemID? | currencyID?, count }, one per entry of view.rewards
-- that has an ID, in order.
function M.RewardEntries(view)
  local out = {}
  if type(view) ~= "table" then return out end
  for _, reward in ipairs(type(view.rewards) == "table" and view.rewards or {}) do
    local itemID = type(reward) == "table" and type(reward.itemID) == "number" and reward.itemID or nil
    local currencyID = type(reward) == "table" and not itemID and type(reward.currencyID) == "number"
      and reward.currencyID or nil
    if itemID or currencyID then
      out[#out + 1] = { kind = "reward", itemID = itemID, currencyID = currencyID,
        count = type(reward.count) == "number" and reward.count or 1 }
    end
  end
  return out
end

-- OrderView + owned(itemID) -> count|nil (nil: not asked) -> the reagents the crafter must supply:
-- { kind = "reagent", itemID, count = still to supply, have = owned|nil }, one per itemID: the result's allocation
-- summed by itemID minus what the customer provides (view.input.provided), positive remainders only, in the order the
-- allocation names them. An empty list: nothing to supply (also when the order's reagent state is "all"). nil: not
-- known (a recraft, an order without a result).
function M.ReagentEntries(view, owned)
  if type(view) ~= "table" then return nil end
  local input = type(view.input) == "table" and view.input or {}
  local result = type(view.result) == "table" and view.result or nil
  if flags_of(view).recraft or input.isRecraft then return nil end
  if input.reagentState == "all" then return {} end   -- Blizzard's own word for it: the customer provides everything
  if not (result and type(result.allocation) == "table") then return nil end
  local provided = type(input.provided) == "table" and input.provided or {}
  local need, order, out = {}, {}, {}
  for _, slot in ipairs(result.allocation) do
    if type(slot) == "table" and type(slot.itemID) == "number" then
      if need[slot.itemID] == nil then order[#order + 1] = slot.itemID end
      need[slot.itemID] = (need[slot.itemID] or 0) + (type(slot.quantity) == "number" and slot.quantity or 0)
    end
  end
  for _, itemID in ipairs(order) do
    local count = need[itemID] - (type(provided[itemID]) == "number" and provided[itemID] or 0)
    if count > 0 then
      out[#out + 1] = { kind = "reagent", itemID = itemID, count = count, have = owned and owned(itemID) or nil }
    end
  end
  return out
end

-- The reagents you must supply and are short of: owned < need, or owned unknown (nil: we cannot confirm you have it).
-- These are the ones the Reagents cover draws as icons; the tooltip lists them all.
function M.ShortEntries(entries)
  local out = {}
  for _, entry in ipairs(entries or {}) do
    if entry.have == nil or entry.have < entry.count then out[#out + 1] = entry end
  end
  return out
end

-- ReagentEntries -> what the Reagents cover shows: "reagents" (icons for those you are short of), "stocked" (a check:
-- you own every reagent you must supply), "provided" (a check: the customer provides every reagent) or "unsure" ("?").
local function reagent_state(entries)
  if entries == nil then return "unsure" end
  if #entries == 0 then return "provided" end
  return #M.ShortEntries(entries) == 0 and "stocked" or "reagents"
end

function M.ReagentState(view)
  if type(view) ~= "table" then return nil end
  return reagent_state(M.ReagentEntries(view))
end

local function icon_slot_x(i)
  return (i - 1) * (ICON_SIZE + ICON_GAP)
end

-- A list of icons + the room for them in pixels (nil: unlimited) -> { shown = icons drawn, more = N|nil, width }.
-- With room for all of them: all drawn. Otherwise the slots that fit (k) draw k-1 icons and the last one becomes "+N"
-- (N = the entries not drawn; a slot of its own width MORE_WIDTH); no room for one slot: nothing (width 0). Icons are
-- ICON_SIZE (20 px), ICON_GAP (2 px) apart.
function M.IconLayout(entries, room)
  local total = #entries
  if total == 0 then return { shown = 0, width = 0 } end
  local all = icon_slot_x(total) + ICON_SIZE
  if room == nil or all <= room then return { shown = total, width = all } end
  for k = total - 1, 1, -1 do
    local width = icon_slot_x(k) + MORE_WIDTH
    if width <= room then return { shown = k - 1, more = total - (k - 1), width = width } end
  end
  return { shown = 0, width = 0 }
end

-- The texture for a reward or reagent: C_Item.GetItemIconByID (else GetItemIcon) for an item, the currency's
-- iconFileID for a currency; the question mark when the client gives none. Never raises.
local function icon_of(entry)
  local icon
  if entry.itemID then
    local api = C_Item
    for _, fn in ipairs({ type(api) == "table" and api.GetItemIconByID or false, GetItemIcon or false }) do
      if type(fn) == "function" and not icon then
        local ok, value = pcall(fn, entry.itemID)
        if ok and (type(value) == "number" or (type(value) == "string" and value ~= "")) then icon = value end
      end
    end
  elseif entry.currencyID then
    local api = C_CurrencyInfo
    if type(api) == "table" and type(api.GetCurrencyInfo) == "function" then
      local ok, info = pcall(api.GetCurrencyInfo, entry.currencyID)
      if ok and type(info) == "table" and type(info.iconFileID) == "number" then icon = info.iconFileID end
    end
  end
  return icon or UNKNOWN_ICON
end

local requestedItems = {}   -- [itemID] = true once its data was asked for (the row tooltips ask once per session)

-- The item's hyperlink when cached; otherwise "item:<id>" while its data is requested once (GET_ITEM_INFO_RECEIVED
-- re-fits the rows, which redraws an open tooltip).
local function item_label(itemID)
  local link = cached_link(itemID)
  if link then return link end
  local api = C_Item
  if not requestedItems[itemID] and type(api) == "table" and type(api.RequestLoadItemDataByID) == "function" then
    requestedItems[itemID] = true
    pcall(api.RequestLoadItemDataByID, itemID)
  end
  return ("item:%d"):format(itemID)
end

local function currency_label(currencyID)
  local api = C_CurrencyInfo
  local ok, info = false, nil
  if type(api) == "table" and type(api.GetCurrencyInfo) == "function" then ok, info = pcall(api.GetCurrencyInfo, currencyID) end
  if ok and type(info) == "table" and type(info.name) == "string" and info.name ~= "" then return info.name end
  return ("currency:%d"):format(currencyID)
end

-- The tooltip over the reward icons, the full list whatever the strip had room for: a "Rewards" header with "<icon>
-- <name> x<count>" lines, then a "Reagents to supply" header with "<name>: need N, have M" lines (red while M < N;
-- "need N" when M is unknown).
local function icon_lines(entries)
  local lines, section = {}, nil
  for _, entry in ipairs(entries) do
    if entry.kind ~= section then
      section = entry.kind
      lines[#lines + 1] = { text = section == "reward" and L["Rewards"] or L["Reagents to supply"], color = TEXT_COLORS.gold }
    end
    if entry.kind == "reward" then
      local name = entry.itemID and item_label(entry.itemID) or currency_label(entry.currencyID)
      lines[#lines + 1] = { text = L["%s x%d"]:format(("|T%s:%d|t %s"):format(tostring(icon_of(entry)), TOOLTIP_ICON, name),
        entry.count), color = TEXT_COLORS.white }
    else
      local name, have = item_label(entry.itemID), entry.have
      if have == nil then
        lines[#lines + 1] = { text = L["%s: need %d"]:format(name, entry.count), color = TEXT_COLORS.white }
      else
        lines[#lines + 1] = { text = L["%s: need %d, have %d"]:format(name, entry.count, have),
          color = have < entry.count and TEXT_COLORS.red or TEXT_COLORS.white }
      end
    end
  end
  return lines
end

---------------------------------------------------------------------------
-- OrdersRowAddons: cells on the order rows
---------------------------------------------------------------------------

local rowsAttached     -- hooks installed (once per session)
local rowsBox          -- the order list's ScrollBox
local rowsHeader       -- the order list's column header container (read only), or nil
local container        -- our clipping container over it
local rowsOwner = {}   -- owner token of our ScrollBox callbacks
local cells = setmetatable({}, { __mode = "k" })  -- [Blizzard row] = our cell set
local REFIT_KEY = "ordersRowAddons.refit"
local BAGS_KEY = "ordersRowAddons.bags"
local apply_fit, schedule_refit, refresh_current_rows   -- defined below

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
  -- The rewards are always listed here too (whatever the setting, and whether or not the icons found room).
  for _, line in ipairs(icon_lines(c.rewardAll or {})) do lines[#lines + 1] = line end
  show_tooltip(c.risk, lines)
end

-- The Commission cover's tooltip: the full commission (tip, the consortium's cut, commission), the "Rewards" lines and
-- what the order costs per knowledge point or Moxie. c.tipping ("tip" | "cover") keeps an open tooltip fresh while the
-- pointer is on the cover, and is cleared when that cover hides.
local function tip_tooltip(c)
  local view = c.view
  local lines = {}
  if type(view) == "table" then
    if is_money(view.tip) then
      lines[#lines + 1] = { text = (L["Tip: %s"]):format(ns.UI.FormatMoney(view.tip)), color = TEXT_COLORS.white }
    end
    if is_money(view.consortiumCut) then
      lines[#lines + 1] = { text = (L["Consortium cut: %s"]):format(ns.UI.FormatMoney(view.consortiumCut)),
        color = TEXT_COLORS.white }
    end
    if is_money(view.commission) then
      lines[#lines + 1] = { text = (L["Commission: %s"]):format(ns.UI.FormatMoney(view.commission)),
        color = TEXT_COLORS.white }
    end
  end
  for _, line in ipairs(icon_lines(c.rewardAll or {})) do lines[#lines + 1] = line end
  for _, note in ipairs(M.CostNotes(view)) do lines[#lines + 1] = { text = note, color = TEXT_COLORS.grey } end
  show_tooltip(c.tipCover, lines)
end

-- The Reagents cover's tooltip: every reagent to supply (owned ones too), or why there is a check or a "?".
local function cover_tooltip(c)
  local lines
  if c.coverMode == "reagents" then
    lines = icon_lines(c.reagentEntries)
  elseif c.coverMode == "stocked" then
    lines = icon_lines(c.reagentEntries)
    table.insert(lines, 1, { text = L["You have every reagent this order needs from you"], color = TEXT_COLORS.white })
  elseif c.coverMode == "provided" then
    lines = { { text = L["The customer provides every reagent"], color = TEXT_COLORS.white } }
  elseif c.coverMode == "unsure" then
    lines = { { text = L["Reagents unknown for this order"], color = TEXT_COLORS.white } }
  else
    return
  end
  show_tooltip(c.cover, lines)
end

local function refresh_tooltip(c)
  if c.tipping == "tip" then tip_tooltip(c) elseif c.tipping == "cover" then cover_tooltip(c) end
end

local function hover_enter(c, which)
  c.tipping = which
  refresh_tooltip(c)
end

local function hover_leave(c)
  c.tipping = nil
  hide_tooltip()
end

-- Stops following the pointer (when `which` is given, only if it is that part's tooltip) and hides the tooltip when it
-- is still ours: a frame that hides may not get its OnLeave.
local function clear_tipping(c, which)
  local current = c.tipping
  if not current or (which and current ~= which) then return end
  c.tipping = nil
  if type(GameTooltip) ~= "table" then return end
  if type(GameTooltip.GetOwner) == "function" then
    local ok, owner = pcall(GameTooltip.GetOwner, GameTooltip)
    if ok and owner ~= (current == "tip" and c.tipCover or c.cover) then return end
  end
  hide_tooltip()
end

-- The cover's own hover highlight: lit while the row or the cover has the pointer (Blizzard's highlight is under it).
local function update_hover(c)
  set_shown(c.coverHover, c.rowHover == true or c.coverHovered == true)
  set_shown(c.tipHover, c.rowHover == true or c.tipHovered == true)
end

local function row_hover(c, on)
  c.rowHover = on
  update_hover(c)
end

local function cover_hover(c, on)
  c.coverHovered = on
  update_hover(c)
end

local function tip_hover(c, on)
  c.tipHovered = on
  update_hover(c)
end

-- Our overlay frames let clicks and hover through to Blizzard's row beneath (unverified API names: pcall-guarded).
local function pass_through(frame)
  for _, method in ipairs({ "SetPropagateMouseClicks", "SetPropagateMouseMotion" }) do
    if type(frame[method]) == "function" then pcall(frame[method], frame, true) end
  end
end

-- The concentration cell's tooltip: what the order needs, what you have, what it is worth, and why it is red.
local function conc_tooltip(c)
  local cell, lines = c.concCell or {}, {}
  if cell.mode == "unreachable" then
    lines[1] = { text = L["The minimum quality cannot be reached, even with concentration"], color = TEXT_COLORS.red }
  elseif cell.mode == "alternative" then
    -- The concentration route Orders did not take: why (cheaper reagents, compared in copper), or that it could not
    -- be compared because the value of concentration is unknown.
    local amount = tostring(cell.amount)
    if cell.charge and cell.reagentCost and cell.plainCost then
      lines[1] = { text = L["Buying better reagents is cheaper than %s concentration (%s vs %s)"]:format(amount,
        ns.UI.FormatMoney(cell.plainCost), ns.UI.FormatMoney(cell.reagentCost + cell.charge)), color = TEXT_COLORS.grey }
    elseif cell.charge == nil then
      lines[1] = { text = L["Could use %s concentration instead of better reagents (value of concentration unknown)"]:format(amount),
        color = TEXT_COLORS.grey }
    end
  elseif cell.mode then
    lines[1] = { text = L["Needs %d concentration to reach the minimum quality"]:format(cell.amount), color = TEXT_COLORS.white }
    if cell.available then
      lines[#lines + 1] = { text = L["You have %d"]:format(cell.available), color = TEXT_COLORS.white }
    end
    if cell.charge then
      lines[#lines + 1] = { text = L["Worth %s at your best gold per concentration"]:format(ns.UI.FormatMoney(cell.charge)),
        color = TEXT_COLORS.white }
    end
    if cell.mode == "short" then
      lines[#lines + 1] = { text = L["Not enough concentration"], color = TEXT_COLORS.red }
    end
  end
  show_tooltip(c.conc, lines)
end

local function add_to_queue(c)
  local O = orders()
  local view = O and c.orderID ~= nil and O:GetView(c.orderID) or nil
  local message, tone = M.AddToQueue(view)
  if message then set_result(message, tone) end
end

-- A pool of icon slots in a frame (texture and count text each, created when first needed) and its "+N" text.
local function new_bank(frame)
  local more = text(frame)
  more:SetJustifyH("LEFT")
  more:SetWidth(MORE_WIDTH)
  more:SetWordWrap(false)
  more:Hide()
  return { frame = frame, slots = {}, more = more }
end

local function bank_slot(bank, i)
  local slot = bank.slots[i]
  if not slot then
    slot = { icon = bank.frame:CreateTexture(nil, "ARTWORK"), count = text(bank.frame, "NumberFontNormal") }
    slot.icon:SetSize(ICON_SIZE, ICON_SIZE)
    slot.count:SetPoint("BOTTOMRIGHT", slot.icon, "BOTTOMRIGHT", 1, -1)
    bank.slots[i] = slot
  end
  return slot
end

-- Draws `entries` per `layout` (IconLayout) into the bank, the first icon x0 pixels from the frame's left edge; every
-- slot is set or hidden, so a recycled row shows no leftovers. Returns whether anything was drawn.
local function draw_bank(bank, entries, layout, x0)
  for _, slot in ipairs(bank.slots) do
    slot.icon:Hide()
    slot.count:Hide()
  end
  bank.more:Hide()
  if layout.width == 0 then return false end
  for i = 1, layout.shown do
    local slot, entry = bank_slot(bank, i), entries[i]
    slot.icon:SetTexture(icon_of(entry))
    slot.icon:ClearAllPoints()
    slot.icon:SetPoint("LEFT", bank.frame, "LEFT", x0 + icon_slot_x(i), 0)
    slot.icon:Show()
    if entry.kind == "reagent" or entry.count > 1 then
      slot.count:SetText(tostring(entry.count))
      color_text(slot.count, entry.kind == "reagent" and entry.have ~= nil and entry.have < entry.count
        and TEXT_COLORS.red or TEXT_COLORS.white)
      slot.count:Show()
    else
      slot.count:SetText("")
      slot.count:Hide()   -- (a new slot starts shown)
    end
  end
  if layout.more then
    bank.more:ClearAllPoints()
    bank.more:SetPoint("LEFT", bank.frame, "LEFT", x0 + icon_slot_x(layout.shown + 1), 0)
    bank.more:SetText("+" .. layout.more)
    bank.more:Show()
  end
  return true
end

local function new_cells(row)
  local c = { dimmed = false, warnShown = false, fit = "all", iconEntries = {}, reagentEntries = {}, shortEntries = {} }
  local frame = CreateFrame("Frame", nil, container)
  frame:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
  frame:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
  c.frame = frame
  c.tintTexture = frame:CreateTexture(nil, "BACKGROUND")
  c.tintTexture:SetAllPoints(frame)
  c.dimTexture = frame:CreateTexture(nil, "OVERLAY")
  c.dimTexture:SetAllPoints(frame)
  c.dimTexture:SetColorTexture(DIM[1], DIM[2], DIM[3], DIM[4])

  -- The strip, left to right: [profit] [conc] [warning] [score] [risk] [+]. Positions are fixed offsets from its right
  -- edge; conc and profit move left by the warning icon's slot when it shows.
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
    M.Guard(ROWS, show_tooltip, button, { { text = L["Add to queue"], color = TEXT_COLORS.white } })
  end)
  c.add:SetScript("OnLeave", function() M.Guard(ROWS, hide_tooltip) end)

  c.risk = CreateFrame("Frame", nil, strip)
  c.risk:SetSize(RISK_WIDTH, STRIP_HEIGHT)
  c.risk:SetPoint("RIGHT", strip, "RIGHT", -(ADD_SIZE + CELL_GAP), 0)
  c.risk:EnableMouse(true)
  c.riskCount = text(c.risk, "GameFontNormalSmall")
  c.riskCount:SetAllPoints(c.risk)
  c.risk:SetScript("OnEnter", function() M.Guard(ROWS, risk_tooltip, c) end)
  c.risk:SetScript("OnLeave", function() M.Guard(ROWS, hide_tooltip) end)

  c.score = text(strip)
  c.score:SetSize(CELL_WIDTH, STRIP_HEIGHT)
  c.score:SetJustifyH("RIGHT")
  c.score:SetPoint("RIGHT", strip, "RIGHT", -(ADD_SIZE + CELL_GAP + RISK_WIDTH + CELL_GAP), 0)

  -- The concentration cell: a small icon and the amount (a red cross when the minimum quality cannot be reached),
  -- empty when the order needs none. Its right edge is set in apply_fit (it moves with the warning icon).
  c.conc = CreateFrame("Frame", nil, strip)
  c.conc:SetSize(CONC_WIDTH, STRIP_HEIGHT)
  c.conc:EnableMouse(true)
  c.concIcon = c.conc:CreateTexture(nil, "ARTWORK")
  c.concIcon:SetSize(CONC_ICON_SIZE, CONC_ICON_SIZE)
  c.concIcon:SetPoint("LEFT", c.conc, "LEFT", 0, 0)
  c.concText = text(c.conc)
  c.concText:SetPoint("RIGHT", c.conc, "RIGHT", 0, 0)
  c.concText:SetJustifyH("RIGHT")
  c.conc:SetScript("OnEnter", function() M.Guard(ROWS, conc_tooltip, c) end)
  c.conc:SetScript("OnLeave", function() M.Guard(ROWS, hide_tooltip) end)

  c.warn = strip:CreateTexture(nil, "OVERLAY")
  c.warn:SetTexture(WARNING_ICON)
  c.warn:SetSize(WARN_SIZE, WARN_SIZE)
  c.warn:SetPoint("RIGHT", strip, "RIGHT", -SCORE_CORE - CELL_GAP, 0)

  c.profit = text(strip)
  c.profit:SetSize(CELL_WIDTH, STRIP_HEIGHT)
  c.profit:SetJustifyH("RIGHT")

  -- The Commission cover: like the Reagents cover below, an opaque background over Blizzard's Commission cell (its
  -- gold amount must not show) with the row's tint and hover highlight repainted on it and a dark overlay of its own
  -- for a dimmed row. Its content frame (alpha follows the strip's) holds the compact commission and the reward icons
  -- (the same pooled slots as the Reagents cover: created when first needed and reused by whatever order the recycled
  -- row shows next; "+N" in its own fixed-width slot when not every icon fits).
  c.tipCover = CreateFrame("Frame", nil, frame)
  c.tipCover:SetClipsChildren(true)
  c.tipCover:EnableMouse(true)
  pass_through(c.tipCover)
  c.tipCover:SetScript("OnEnter", function()
    M.Guard(ROWS, function()
      tip_hover(c, true)
      hover_enter(c, "tip")
    end)
  end)
  c.tipCover:SetScript("OnLeave", function()
    M.Guard(ROWS, function()
      tip_hover(c, false)
      hover_leave(c)
    end)
  end)
  c.tipBg = c.tipCover:CreateTexture(nil, "BACKGROUND")
  c.tipBg:SetAllPoints(c.tipCover)
  c.tipBg:SetColorTexture(COVER_COLOR[1], COVER_COLOR[2], COVER_COLOR[3], COVER_COLOR[4])
  c.tipTint = c.tipCover:CreateTexture(nil, "BORDER")
  c.tipTint:SetAllPoints(c.tipCover)
  c.tipTint:Hide()
  c.tipHover = c.tipCover:CreateTexture(nil, "BORDER", nil, 1)
  c.tipHover:SetAllPoints(c.tipCover)
  c.tipHover:SetColorTexture(HOVER_COLOR[1], HOVER_COLOR[2], HOVER_COLOR[3], HOVER_COLOR[4])
  c.tipHover:Hide()
  c.tipDim = c.tipCover:CreateTexture(nil, "BORDER", nil, 2)
  c.tipDim:SetAllPoints(c.tipCover)
  c.tipDim:SetColorTexture(DIM[1], DIM[2], DIM[3], DIM[4])
  c.tipDim:Hide()
  c.tipContent = CreateFrame("Frame", nil, c.tipCover)
  c.tipContent:SetAllPoints(c.tipCover)
  c.tipAmount = text(c.tipContent)
  c.tipAmount:SetSize(AMOUNT_WIDTH, STRIP_HEIGHT)
  c.tipAmount:SetJustifyH("LEFT")
  c.tipAmount:SetPoint("LEFT", c.tipCover, "LEFT", COVER_PAD, 0)
  color_text(c.tipAmount, TEXT_COLORS.white)
  c.tipBank = new_bank(c.tipContent)
  c.tipSlots, c.tipMore = c.tipBank.slots, c.tipBank.more
  c.tipCover:Hide()

  -- The Reagents cover: an opaque background over Blizzard's Reagents cell (its word must not show), the row's tint and
  -- hover highlight repainted on it (they are drawn under the cover), a dark overlay of its own for a dimmed row, and
  -- a content frame (the reagent icons in the same pooled slots, the check and the "?") whose alpha follows the strip's.
  c.cover = CreateFrame("Frame", nil, frame)
  c.cover:SetClipsChildren(true)
  c.cover:EnableMouse(true)
  pass_through(c.cover)
  c.cover:SetScript("OnEnter", function()
    M.Guard(ROWS, function()
      cover_hover(c, true)
      hover_enter(c, "cover")
    end)
  end)
  c.cover:SetScript("OnLeave", function()
    M.Guard(ROWS, function()
      cover_hover(c, false)
      hover_leave(c)
    end)
  end)
  c.coverBg = c.cover:CreateTexture(nil, "BACKGROUND")
  c.coverBg:SetAllPoints(c.cover)
  c.coverBg:SetColorTexture(COVER_COLOR[1], COVER_COLOR[2], COVER_COLOR[3], COVER_COLOR[4])
  c.coverTint = c.cover:CreateTexture(nil, "BORDER")
  c.coverTint:SetAllPoints(c.cover)
  c.coverTint:Hide()
  c.coverHover = c.cover:CreateTexture(nil, "BORDER", nil, 1)
  c.coverHover:SetAllPoints(c.cover)
  c.coverHover:SetColorTexture(HOVER_COLOR[1], HOVER_COLOR[2], HOVER_COLOR[3], HOVER_COLOR[4])
  c.coverHover:Hide()
  c.coverDim = c.cover:CreateTexture(nil, "BORDER", nil, 2)
  c.coverDim:SetAllPoints(c.cover)
  c.coverDim:SetColorTexture(DIM[1], DIM[2], DIM[3], DIM[4])
  c.coverDim:Hide()
  c.coverContent = CreateFrame("Frame", nil, c.cover)
  c.coverContent:SetAllPoints(c.cover)
  c.coverCheck = c.coverContent:CreateTexture(nil, "ARTWORK")
  c.coverCheck:SetTexture(CHECK_ICON)
  c.coverCheck:SetSize(ICON_SIZE + 2, ICON_SIZE + 2)
  c.coverCheck:SetPoint("LEFT", c.cover, "LEFT", COVER_PAD, 0)
  c.coverQuestion = text(c.coverContent, "GameFontNormal")
  c.coverQuestion:SetText("?")
  color_text(c.coverQuestion, TEXT_COLORS.grey)
  c.coverQuestion:SetPoint("LEFT", c.cover, "LEFT", COVER_PAD + 3, 0)
  c.coverBank = new_bank(c.coverContent)
  c.coverSlots, c.coverMore = c.coverBank.slots, c.coverBank.more
  c.cover:Hide()

  -- The pointer on Blizzard's row lights the cover (a post-hook on the row's own scripts, once per row frame: this
  -- table is made once per row and reused when the row is recycled).
  c.hoverRow = row
  if type(row.HookScript) == "function" then
    row:HookScript("OnEnter", function() M.Guard(ROWS, row_hover, c, true) end)
    row:HookScript("OnLeave", function() M.Guard(ROWS, row_hover, c, false) end)
  end
  cells[row] = c
  return c
end

-- Places the strip at the right of the item-name column (measured read-only; Blizzard's fixed columns otherwise) and
-- makes it give way to Blizzard's item name (hotfix H1-6 rule: our cells never cover the name). With room for
-- everything: "all"; else without the profit cell (score, risk and the warning icon stay): "noProfit"; else no strip
-- at all: "none" (the side panel and the Orders tab still carry the numbers). A row that cannot be measured keeps
-- everything. Also returns the space reserved right of the item-name column. Only getters are called on Blizzard's
-- row, its item-name cell and that cell's Text.
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
  if not (rowLeft and rowWidth and textLeft and textWidth) then return "all", reserve end
  local nameEnd = textLeft + textWidth - rowLeft         -- from the row's left edge
  local stripRight = rowWidth - reserve - PAD
  local core = CORE_WIDTH + (warn and WARN_SLOT or 0)
  local function fits(width) return nameEnd + GAP <= stripRight - width end
  if fits(core + PROFIT_SLOT) then return "all", reserve end
  if fits(core) then return "noProfit", reserve end
  return "none", reserve
end

-- Whether left..right look like a real column span (a cell that was not laid out reads 0 or reversed).
local function plausible_span(left, right)
  return left ~= nil and right ~= nil and right - left >= 20 and right - left <= 300
end

-- The frames (tables) among `...`, as a list.
local function tables_of(...)
  local list = {}
  for i = 1, select("#", ...) do
    local value = select(i, ...)
    if type(value) == "table" then list[#list + 1] = value end
  end
  return list
end

-- { span = { left, right, frame }... } for the frames whose edges can be read, sorted by their left edge (creation
-- order says nothing), and how many could not be read.
local function column_spans(frames)
  local spans, unreadable = {}, 0
  for _, frame in ipairs(frames) do
    local left, right = read_number(frame, "GetLeft"), read_number(frame, "GetRight")
    if left and right and right > left then
      spans[#spans + 1] = { left = left, right = right, frame = frame }
    else
      unreadable = unreadable + 1
    end
  end
  table.sort(spans, function(a, b) return a.left < b.left end)
  return spans, unreadable
end

-- The known layout: five columns, the fourth 80 to 100 px wide and ending where the last begins.
local function known_reagents_span(spans)
  if #spans ~= KNOWN_COLUMNS then return nil end
  local reagents, last = spans[KNOWN_COLUMNS - 1], spans[KNOWN_COLUMNS]
  local width = reagents.right - reagents.left
  if width >= REAGENTS_MIN and width <= REAGENTS_MAX and math.abs(last.left - reagents.right) <= GAP then
    return reagents.left, reagents.right
  end
  return nil
end

local function header_frames()
  if not (rowsHeader and type(rowsHeader.GetChildren) == "function") then return {} end
  return tables_of(select(2, pcall(rowsHeader.GetChildren, rowsHeader)))
end

-- A header's text (read only), or nil.
local function header_text(header)
  local source = type(header.GetText) == "function" and header or child(header, "Text")
  if not (source and type(source.GetText) == "function") then return nil end
  local ok, value = pcall(source.GetText, source)
  return ok and type(value) == "string" and value or nil
end

-- The known layout's third column, the Commission (Tip): about 160 px, touching the Reagents column, in a layout whose
-- Reagents and last columns are the known ones.
local function known_tip_span(spans)
  if not known_reagents_span(spans) then return nil end
  local tip, reagents = spans[3], spans[KNOWN_COLUMNS - 1]
  local width = tip.right - tip.left
  if width >= TIP_MIN and width <= TIP_MAX and math.abs(reagents.left - tip.right) <= GAP then
    return tip.left, tip.right
  end
  return nil
end

-- Which column is the wanted one, read-only, or nil when it cannot be told (then there is nothing drawn over or in it).
-- In order: the header whose text is one of Blizzard's header strings (`globals`: names of global strings); the known
-- five-column layout read from the headers (sorted by their left edge) by `known`; with no headers to read, the same
-- from the row's own cells. Returns left, right (screen coordinates). There is no assumed layout to fall back on: while
-- a header or cell cannot be read (not laid out yet) nothing is identified, and a later re-fit pass tries again.
local function identify_column(row, globals, known)
  local headers = header_frames()
  if #headers > 0 then
    local spans, unreadable = column_spans(headers)
    for _, name in ipairs(globals) do
      local want = rawget(_G, name)
      if type(want) == "string" and want ~= "" then
        for _, span in ipairs(spans) do
          if plausible_span(span.left, span.right) and header_text(span.frame) == want then return span.left, span.right end
        end
      end
    end
    if unreadable == 0 then return known(spans) end
    return nil
  end
  local cellList = {}
  if type(row.cells) == "table" then
    for i = 1, 12 do
      if type(row.cells[i]) == "table" then cellList[#cellList + 1] = row.cells[i] end
    end
  end
  local spans, unreadable = column_spans(cellList)
  if unreadable == 0 then return known(spans) end
  return nil
end

local function reagents_column(row) return identify_column(row, { REAGENTS_HEADER_GLOBAL }, known_reagents_span) end
local function tip_column(row) return identify_column(row, TIP_HEADER_GLOBALS, known_tip_span) end

-- Anchors the cover over the identified Reagents column and returns its width, or nil (nothing identified, or the row's
-- right edge is unknown) when there is to be no cover.
local function place_over(cover, row, column)
  local left, right = column(row)
  if not left then return nil end
  local rowRight = read_number(row, "GetRight")
  if not rowRight or rowRight < right then return nil end
  local offset, width = rowRight - right, right - left
  cover:ClearAllPoints()
  cover:SetPoint("TOPRIGHT", row, "TOPRIGHT", -offset, 0)
  cover:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -offset, 0)
  cover:SetWidth(width)
  return width
end

local function place_cover(c, row) return place_over(c.cover, row, reagents_column) end

-- Shows the Commission cover (c.tipOn: the setting is on and the row has a view of ours) over the column
-- tip_column identifies: the compact commission ("?" while unknown) and the reward icons that fit right of it, "+N"
-- counting the rest. No cover where the column cannot be told: Blizzard's amount shows, and the rewards are in the
-- row's info tooltip.
local function render_tip_cover(c, row)
  local width = c.tipOn and place_over(c.tipCover, row, tip_column) or nil
  if not width then
    c.tipCover:Hide()
    clear_tipping(c, "tip")
    return
  end
  set_shown(c.tipDim, c.dimmed)
  c.tipContent:SetAlpha(c.dimmed and 0.6 or 1)
  c.tipAmount:SetText(c.tipAmountText or "?")
  local x0 = COVER_PAD + AMOUNT_WIDTH + GAP
  draw_bank(c.tipBank, c.iconEntries, M.IconLayout(c.iconEntries, width - x0 - COVER_PAD), x0)
  c.tipCover:Show()
end

-- Shows the Reagents cover for the row's mode (c.coverMode: "reagents" | "stocked" | "provided" | "unsure" | nil), over
-- the column place_cover identifies; no cover when there is none to show or the column cannot be told.
local function render_cover(c, row)
  local width = c.coverMode and place_cover(c, row) or nil
  if not width then
    c.cover:Hide()
    clear_tipping(c, "cover")
    return
  end
  local mode = c.coverMode
  set_shown(c.coverDim, c.dimmed)
  c.coverContent:SetAlpha(c.dimmed and 0.6 or 1)
  set_shown(c.coverCheck, mode == "provided" or mode == "stocked")
  set_shown(c.coverQuestion, mode == "unsure")
  local entries = mode == "reagents" and c.shortEntries or {}
  draw_bank(c.coverBank, entries, M.IconLayout(entries, width - 2 * COVER_PAD), COVER_PAD)
  c.cover:Show()
end

local function hide_cells(c)
  c.frame:Hide()
  c.tipCover:Hide()
  c.cover:Hide()
  clear_tipping(c)
  c.rowHover, c.coverHovered, c.tipHovered = false, false, false
  update_hover(c)
end

local function hide_row(row)
  local c = cells[row]
  if c then hide_cells(c) end
end

local function hide_all_cells()
  for _, c in pairs(cells) do hide_cells(c) end
end

-- Fits a row's strip to Blizzard's item name as it is now (see fit) and shows the parts that have room.
function apply_fit(c, row)
  c.fit = fit(c, row, c.blocked)
  c.warnShown = c.blocked == true and c.fit ~= "none"
  set_shown(c.warn, c.warnShown)
  c.conc:ClearAllPoints()
  c.conc:SetPoint("RIGHT", c.strip, "RIGHT", -(SCORE_CORE + CELL_GAP + (c.warnShown and WARN_SLOT or 0)), 0)
  c.profit:ClearAllPoints()
  c.profit:SetPoint("RIGHT", c.strip, "RIGHT", -(CORE_WIDTH + CELL_GAP + (c.warnShown and WARN_SLOT or 0)), 0)
  set_shown(c.profit, c.fit == "all")
  -- The score cell repeats the profit when no concentration is charged: blank it (it keeps its slot) while the profit
  -- cell is shown beside it with the same text. Otherwise it keeps its text, the only number left once the profit gives way.
  c.score:SetText(c.fit == "all" and c.scoreText == c.profitText and "" or c.scoreText)
  set_shown(c.strip, c.fit ~= "none")
  render_tip_cover(c, row)
  render_cover(c, row)
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
    if c and c.frame:IsShown() then
      apply_fit(c, row)
      refresh_tooltip(c)   -- an open tooltip learns names that arrived
    end
  end)
end

local refitPass = ns.FS:Wrap(ROWS, function()
  if RowAddons:IsEnabled() then refit_rows() end
end)

function schedule_refit()
  ns.FS:Debounce(REFIT_KEY, 0, refitPass)
end

local bagsPass = ns.FS:Wrap(ROWS, function()
  if RowAddons:IsEnabled() then refresh_current_rows() end
end)

-- ITEM_DATA_LOAD_RESULT / GET_ITEM_INFO_RECEIVED (the names) and BAG_UPDATE_DELAYED (the owned counts, which the reagent
-- icons colour by) are listened to only while the cells are attached and the order list is on screen (the ScrollBox's
-- OnShow / OnHide), and never while the module is off. A bag change redoes the rows on screen (a re-fit pass does not
-- recompute the entries), coalesced into the next frame.
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
  if on then
    RowAddons:RegisterEvent("BAG_UPDATE_DELAYED", function()
      M.Guard(ROWS, function() ns.FS:Debounce(BAGS_KEY, 0, bagsPass) end)
    end)
  else
    RowAddons:UnregisterEvent("BAG_UPDATE_DELAYED")
    ns.FS:CancelDebounce(BAGS_KEY)
  end
end

-- Shows the cells of one row for its element, or hides them when it holds no order or the order is not scored.
-- Runs once Blizzard has filled the row (OnInitializedFrame), so a recycled row is measured with its new item name.
-- While Orders is off nothing captures or rescores the board, so its saved views would show stale scores: no cells.
local function show_row(row, elementData)
  local O = orders()
  if O and O.IsEnabled and not O:IsEnabled() then O = nil end
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
  if tint then
    c.coverTint:SetColorTexture(tint[1], tint[2], tint[3], tint[4])
    c.tipTint:SetColorTexture(tint[1], tint[2], tint[3], tint[4])
  end
  set_shown(c.coverTint, tint ~= nil)
  set_shown(c.tipTint, tint ~= nil)
  c.dimmed = model.dimmed
  set_shown(c.dimTexture, model.dimmed)
  c.strip:SetAlpha(model.dimmed and 0.6 or 1)
  -- The rewards, and what the Reagents cover shows (none while the setting is off: Blizzard's column shows as usual).
  local on = O:Settings().showRowIcons ~= false
  local reagents = M.ReagentEntries(view, owned_count)
  c.iconEntries = on and M.RewardEntries(view) or {}
  c.reagentEntries = on and reagents or {}
  c.shortEntries = M.ShortEntries(c.reagentEntries)
  c.coverMode = on and reagent_state(reagents) or nil
  -- The Commission cover's amount and the view its tooltip reads (the setting turns this cover off as well).
  c.tipOn, c.view = on, view
  c.tipAmountText = M.CompactMoney(view.commission) or "?"

  -- The concentration cell keeps its slot; it is empty when the order needs none.
  c.concCell = M.ConcentrationCell(view, available_concentration(view))
  if c.concCell.mode == "unreachable" then
    c.concText:SetText("\195\151")   -- a multiplication sign
    color_text(c.concText, TEXT_COLORS.red)
  elseif c.concCell.mode then
    c.concText:SetText(tostring(c.concCell.amount))
    local mode = c.concCell.mode
    color_text(c.concText, mode == "short" and TEXT_COLORS.red or mode == "alternative" and TEXT_COLORS.grey
      or TEXT_COLORS.white)
  else
    c.concText:SetText("")
  end
  if c.concCell.mode then c.concIcon:SetTexture(concentration_icon(view.recipeID)) end
  set_shown(c.concIcon, c.concCell.mode ~= nil)

  c.profitText, c.scoreText = M.ProfitText(view), M.ScoreText(view)
  c.profit:SetText(c.profitText)
  color_text(c.profit, sign_color(view.net))
  c.score:SetText(c.scoreText)   -- (apply_fit blanks it when it would only repeat the profit shown beside it)
  color_text(c.score, sign_color(view.score))
  c.rewardAll = M.RewardEntries(view)
  if model.riskCount > 0 or #c.notes > 0 or #c.rewardAll > 0 then
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

-- The rows on screen redone in place (values, icons, owned counts), without hiding them first.
function refresh_current_rows()
  if rowsBox and type(rowsBox.ForEachFrame) == "function" then
    rowsBox:ForEachFrame(function(row, elementData) show_row(row, elementData) end)
  end
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
  rowsHeader = child(child(child(page, "BrowseFrame"), "OrderList"), "HeaderContainer")

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
  ns.FS:CancelDebounce(BAGS_KEY)
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
    print(L["FabricationStation: %s"]:format(message))
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
-- for the session, so the ID is shown without asking again); the wait ends either way. The event is synchronous and
-- can fire inside RequestLoadItemDataByID: the refresh in progress then reads the link itself.
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

---------------------------------------------------------------------------
-- The concentration display (OrdersSidePanel): your concentration, above the order list
---------------------------------------------------------------------------

-- Where the display sits: just above the top-left corner of the order list (BrowseFrame), clear of the search box.
-- Adjust here if it overlaps Blizzard's UI in game (in-game checklist).
M.CONC_ANCHOR = { point = "BOTTOMLEFT", relPoint = "TOPLEFT", x = 8, y = 2 }
local CONC_ICON_SHOWN, CONC_REFRESH_SECONDS, CONC_DEBOUNCE_SECONDS = 16, 60, 0.2
-- A black backdrop behind the icon and the number, so they read on any window art; it reaches this far past them.
M.CONC_BACKDROP = { 0, 0, 0, 0.85 }
local CONC_BACKDROP_PAD_X, CONC_BACKDROP_PAD_Y = 4, 3
local CONC_KEY = "ordersSidePanel.concentration"
local concDisplay      -- { frame, icon, text, state } once built
local concTicker       -- the once-a-minute timer, while the page is shown
local concListening = false

local function finite_number(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

-- The character's concentration for the profession whose orders are shown: { value, max|nil, secondsToFull|nil,
-- full, line } or nil when nothing is known. The game's own quantity of the profession's concentration currency is
-- used while it can be read (the window is open), else the Scanner snapshot projected to now. The regeneration rate
-- comes from the same source (per cycle, cycle length); the time to full is PlanCalc's estimate, and nil when the
-- rate is unknown.
function M.ConcentrationState()
  local trade = C_TradeSkillUI
  local okInfo, profession = pcall(function() return trade.GetChildProfessionInfo() end)
  local line = okInfo and type(profession) == "table" and profession.professionID or nil
  if line == nil then return nil end
  local now = ns.FS:Now()
  local value, max, perCycle, cycleSeconds
  local okID, id = pcall(function() return trade.GetConcentrationCurrencyID(line) end)
  if okID and type(id) == "number" and id ~= 0 and type(C_CurrencyInfo) == "table" then
    local okCur, info = pcall(C_CurrencyInfo.GetCurrencyInfo, id)
    if okCur and type(info) == "table" and finite_number(info.quantity) then
      value = info.quantity
      max = finite_number(info.maxQuantity) and info.maxQuantity > 0 and info.maxQuantity or nil
      perCycle = info.rechargingAmountPerCycle
      cycleSeconds = finite_number(info.rechargingCycleDurationMS) and info.rechargingCycleDurationMS / 1000 or nil
    end
  end
  if value == nil then
    local scanner = ns.FS:GetModule("Scanner", true)
    local ok, projected, projectedMax = pcall(function() return scanner:ProjectConcentration(ns.FS:CharKey(), line, now) end)
    if ok and finite_number(projected) then
      value = projected
      max = finite_number(projectedMax) and projectedMax > 0 and projectedMax or nil
      local okRec, record = pcall(function() return scanner:GetProfession(ns.FS:CharKey(), line) end)
      local c = okRec and type(record) == "table" and type(record.concentration) == "table" and record.concentration or {}
      perCycle, cycleSeconds = c.perCycle, c.cycleSeconds
    end
  end
  if value == nil then return nil end
  local state = { value = value, max = max, line = line, full = max ~= nil and value >= max }
  if state.full then
    state.secondsToFull = 0
  elseif max and finite_number(perCycle) and perCycle > 0 and finite_number(cycleSeconds) and cycleSeconds > 0
    and ns.PlanCalc and ns.PlanCalc.TimeToFull then
    state.secondsToFull = ns.PlanCalc.TimeToFull(function(t)
      return math.min(max, value + math.floor((t - now) / cycleSeconds) * perCycle), max
    end, now)
  end
  return state
end

local function conc_display_tooltip()
  local state = concDisplay and concDisplay.state
  if not state then return end
  local lines = {}
  if state.max then
    lines[1] = { text = L["Concentration: %d / %d"]:format(state.value, state.max), color = TEXT_COLORS.white }
  else
    lines[1] = { text = L["Concentration: %d"]:format(state.value), color = TEXT_COLORS.white }
  end
  if state.full then
    lines[#lines + 1] = { text = L["Already full"], color = TEXT_COLORS.green }
  elseif state.secondsToFull then
    local view = ns.UI.CharactersView
    if view and view.FormatDuration then
      lines[#lines + 1] = { text = L["Full in %s"]:format(view.FormatDuration(state.secondsToFull)), color = TEXT_COLORS.grey }
    end
  end
  show_tooltip(concDisplay.frame, lines)
end

-- Redraws the display from the current state; hidden while nothing is known.
local function refresh_conc()
  if not concDisplay then return end
  local state = M.ConcentrationState()
  concDisplay.state = state
  if not state then
    concDisplay.frame:Hide()
    return
  end
  concDisplay.icon:SetTexture(concentration_icon_for_line(state.line))
  concDisplay.text:SetText(state.max and L["%d / %d"]:format(state.value, state.max) or tostring(state.value))
  concDisplay.frame:Show()
end

local function build_conc(browse)
  if concDisplay then return end
  local frame = CreateFrame("Frame", nil, browse)
  local A = M.CONC_ANCHOR
  frame:SetPoint(A.point, browse, A.relPoint, A.x, A.y)
  frame:SetSize(120, CONC_ICON_SHOWN)
  frame:EnableMouse(true)
  frame:Hide()
  local icon = frame:CreateTexture(nil, "ARTWORK")
  icon:SetSize(CONC_ICON_SHOWN, CONC_ICON_SHOWN)
  icon:SetPoint("LEFT", frame, "LEFT", 0, 0)
  local label = text(frame, "GameFontHighlight")
  label:SetPoint("LEFT", icon, "RIGHT", 4, 0)
  label:SetJustifyH("LEFT")
  local background = frame:CreateTexture(nil, "BACKGROUND")
  local B = M.CONC_BACKDROP
  background:SetColorTexture(B[1], B[2], B[3], B[4])
  background:SetPoint("TOPLEFT", icon, "TOPLEFT", -CONC_BACKDROP_PAD_X, CONC_BACKDROP_PAD_Y)
  background:SetPoint("BOTTOM", icon, "BOTTOM", 0, -CONC_BACKDROP_PAD_Y)
  background:SetPoint("RIGHT", label, "RIGHT", CONC_BACKDROP_PAD_X, 0)
  frame:SetScript("OnEnter", function() M.Guard(SIDE, conc_display_tooltip) end)
  frame:SetScript("OnLeave", function() M.Guard(SIDE, hide_tooltip) end)
  concDisplay = { frame = frame, icon = icon, text = label, background = background }
end

-- Built once: the debounce takes this function, so an event does not build a new wrapper.
local refreshWrapped = ns.FS:Wrap(SIDE, refresh_conc)

-- Starts what keeps the display fresh while the page is shown: CURRENCY_DISPLAY_UPDATE (debounced) and a minute timer
-- (the regeneration estimate moves with time); stops both when hidden or the module turns off.
local function start_conc()
  if not concListening then
    concListening = true
    SidePanel:RegisterEvent("CURRENCY_DISPLAY_UPDATE", function()
      M.Guard(SIDE, function() ns.FS:Debounce(CONC_KEY, CONC_DEBOUNCE_SECONDS, refreshWrapped) end)
    end)
  end
  if not concTicker then
    concTicker = C_Timer.NewTicker(CONC_REFRESH_SECONDS, function() M.Guard(SIDE, refresh_conc) end)
  end
  refresh_conc()
end

local function stop_conc()
  if concListening then
    concListening = false
    SidePanel:UnregisterEvent("CURRENCY_DISPLAY_UPDATE")
  end
  ns.FS:CancelDebounce(CONC_KEY)
  if concTicker then
    concTicker:Cancel()
    concTicker = nil
  end
  if concDisplay then concDisplay.frame:Hide() end
end

function refresh_side()
  if not (side and side.frame:IsShown()) then return end
  refresh_conc()   -- (the profession shown may have changed)
  local f = filters()
  for _, check in ipairs(side.checks) do check.button:SetChecked(f ~= nil and check.get(f) or false) end

  local profession = current_profession()
  local info = profession ~= nil and C_CraftingOrders.GetOrderClaimInfo(profession) or nil
  local remaining = type(info) == "table" and info.claimsRemaining or nil
  side.claims:SetText(L["Claims remaining: %s"]:format(type(remaining) == "number" and tostring(remaining) or "--"))

  local O = orders()
  local view, reason
  if O and O.GetBestCandidate then view, reason = O:GetBestCandidate() end
  if view then
    local ledger = ns.FS:GetModule("Ledger", true)
    local benchmark = ledger and ledger.Benchmark and ledger:Benchmark(view.recipeID, M.BenchmarkQuality(view)) or nil
    side.best:SetText(L["Best: %s"]:format(M.BestText(best_item_text(view.itemID), view, benchmark)))
  else
    stop_waiting()
    side.best:SetText(L["Best: %s"]:format(BEST_NONE[reason] or L["none claimable"]))
  end
  side.claimEnabled = view ~= nil
  side.claim:SetEnabled(side.claimEnabled)

  -- Refresh: shown while Orders can ask the server at all, disabled while an answer is awaited; the line under it
  -- counts the new matching orders the last Refresh found (cleared by the next board show).
  local state = O and O.GetRequestState and O:GetRequestState() or "unavailable"
  set_shown(side.refresh, state ~= "unavailable")
  side.refreshEnabled = state ~= "busy"
  side.refresh:SetEnabled(side.refreshEnabled)
  local fresh = O and O.GetRefreshFresh and O:GetRefreshFresh() or nil
  side.fresh:SetText(fresh and L["%d new matching orders: press Search on the board to see them"]:format(fresh) or "")
  set_shown(side.fresh, fresh ~= nil)
end

local function on_claim_clicked(view, reason)
  if view then
    pendingClaim = view.orderID
    set_result(L["Claiming %s\226\128\166"]:format(item_text(view.itemID)), "plain")
  else
    set_result(CLAIM_REFUSED[reason] or L["Nothing claimed (%s)"]:format(tostring(reason)), "warn")
  end
  refresh_side()
end

local function on_refresh_clicked(ok, reason)
  if not ok then set_result(REFRESH_REFUSED[reason] or L["Nothing refreshed (%s)"]:format(tostring(reason)), "warn") end
  refresh_side()
end

-- CRAFTINGORDERS_CLAIM_ORDER_RESPONSE(result, orderID) for the claim our button started (Blizzard's own Start Order
-- claims are not ours to report).
local function on_claim_response(_, result, orderID)
  if pendingClaim == nil or (orderID ~= nil and orderID ~= pendingClaim) then return end
  pendingClaim = nil
  if result == ok_result() then
    set_result(L["Claimed \226\128\148 open it from the order list"], "good")
  else
    set_result((L["Claim failed (%s)"]):format(result_name(result)), "bad")
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
  v.filterHeader:SetText(L["Hide orders with:"])

  local anchor = v.filterHeader
  for _, d in ipairs(M.FilterChecks()) do
    local check = make_check(frame, anchor, d.label, d.get, d.set)
    v.checks[#v.checks + 1] = check
    anchor = check.button
  end

  v.claims = text(frame)
  v.claims:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -10)
  v.claims:SetPoint("RIGHT", frame, "RIGHT", -SIDE_PAD, 0)
  v.claims:SetJustifyH("LEFT")

  v.claim = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  v.claim:SetSize(SIDE_WIDTH - 2 * SIDE_PAD, 22)
  v.claim:SetPoint("TOPLEFT", v.claims, "BOTTOMLEFT", 0, -6)
  v.claim:SetText(L["Claim Best Order"])
  -- The only caller of Orders:ClaimBest, directly in this click handler (design rule 3).
  v.claim:SetScript("OnClick", ns.FS:Wrap(SIDE, function()
    if not SidePanel:IsEnabled() then return end
    local O2 = orders()
    if not O2 then return end
    local view, reason = O2:ClaimBest()
    on_claim_clicked(view, reason)
  end))

  v.refresh = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  v.refresh:SetSize(SIDE_WIDTH - 2 * SIDE_PAD, 22)
  v.refresh:SetPoint("TOPLEFT", v.claim, "BOTTOMLEFT", 0, -4)
  v.refresh:SetText(L["Refresh"])
  -- The only caller of Orders:RequestBoard, directly in this click handler (design rule 3;
  -- tests/orders/refresh_click_only_spec.lua enforces it). Nothing refreshes by itself.
  v.refresh:SetScript("OnClick", ns.FS:Wrap(SIDE, function()
    if not SidePanel:IsEnabled() then return end
    local O2 = orders()
    if not O2 then return end
    local ok, reason = O2:RequestBoard()
    on_refresh_clicked(ok, reason)
  end))

  v.fresh = text(frame)
  v.fresh:SetPoint("TOPLEFT", v.refresh, "BOTTOMLEFT", 0, -4)
  v.fresh:SetPoint("RIGHT", frame, "RIGHT", -SIDE_PAD, 0)
  v.fresh:SetJustifyH("LEFT")
  v.fresh:SetWordWrap(true)

  v.best = text(frame)
  v.best:SetPoint("TOPLEFT", v.fresh, "BOTTOMLEFT", 0, -6)
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
  start_conc()
  refresh_side()
end

local function hide_side()
  stop_waiting()
  stop_conc()
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
    build_conc(browse)
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
function SidePanel:GetConcDisplay() return concDisplay end

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
    message, tone = L["Blocked customer: %s"]:format(name), "red"
  elseif name then
    local record = cust:Get(name)
    local tags = type(record) == "table" and type(record.tags) == "table" and record.tags or {}
    if tags.VIP then
      local n = type(record.orders) == "table" and #record.orders or 0
      message, tone = (n == 1 and L["VIP customer \194\183 %d previous order"] or L["VIP customer \194\183 %d previous orders"])
        :format(n), "gold"
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
