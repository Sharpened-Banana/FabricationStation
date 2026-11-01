local _, ns = ...
local L = ns.L

-- Ledger tab: a row of section buttons (Tab.SECTIONS: Profit, Auctions, Crafts; the choice is kept for the session only,
-- default Profit) above one scrolling page. Profit is what the player earned crafting (Ledger module), in four parts:
--   * Weekly profit for the last WEEKS reset weeks plus their total (Ledger:Weekly): week, income, cost, profit and a
--     note "partial: <n> with missing or partial cost" when some of the week's sales or commissions had no known (or
--     a partial) cost.
--   * Profit by recipe over the same WEEKS weeks (Ledger:ByRecipe since the oldest shown week, best first) and an
--     "Unattributed sales" row (Ledger:Unattributed, same period: sales whose item could not be matched to a recipe),
--     so the rows add up to the weekly total. When the week boundary is unknown it covers every recorded entry and
--     says so ("all recorded").
--   * The player's own tips by recipe and quality (Ledger:Benchmark for every recipe and quality of a commission; a
--     recipe whose commissions carry no quality gets one all-qualities row).
--   * Every entry, newest first (Ledger:Query): date, type, item, amount, customer (or AH buyer).
-- Auctions (phase 7) is the player's own auction history over the sale log's window (SaleLog:GetAllStats): one row per
-- item with Posted, Sold, Expired, Cancelled, Rate (sold of everything that ended, "?" while unknown), Last sale (per
-- item, after the AH cut) and Listed now ("?" while no listing was read), best sellers first. Sales come from the
-- Ledger's sold mail, so with the Ledger off Sold and Rate are "?" and the row tooltip says why. Cancelled, Expired and
-- Posted are hidden first when narrow. A status line says when the sale log is off (what was recorded still shows).
-- Crafts (phase 7) is the craft log over the last WEEKS weeks (CraftLog:Summary), one row per recipe, most crafted first:
-- Crafts, Quality ("2 of 3 as predicted": the crafts whose quality matched FabricationStation's prediction, of those
-- where both are known), Multicraft (the extra items seen next to the expected ones), Resourcefulness (crafts that
-- returned reagents) and Concentration (spent next to predicted). A number the game did not report is "?", never 0, and
-- the row tooltip says how many crafts it leaves out. Concentration and Resourcefulness are hidden first when narrow.
-- The page is one pooled virtual list in a plain scroll frame, as in the Orders and Queue tabs; each list item is a
-- heading, a column header, a data row, a note or a spacer, and a pooled row keeps one set of cells per section.
--
-- Profit rule (Ledger): only sales and commissions count; crafts are cost records. A sale or commission with no
-- known cost adds nothing to the cost, so a profit with such entries is partial and the real profit may be LOWER
-- than shown (its cost is missing, not zero). Such a profit is never shown as exact: the note says "partial" and
-- the tooltip explains it. A cost that includes an estimated craft cost starts with "~", as does its profit. A
-- recraft commission says "recraft" (its cost is not tracked). Unknown money is "?", never 0g. In the entries list
-- only a craft's amount (its cost) can be an estimate; a sale's or commission's amount is exact gold.
--
-- Width: every section's flexible column (Week note, Recipe, Item) keeps at least MIN_FLEX px; below that its
-- low-priority columns are hidden in order (Tab.Layout, applied again on every size change). Money cells are compact
-- ("1,234g", OrdersPanel.CompactMoney; under a copper shows "0g" in grey); each row's tooltip has the full amounts.
-- The status line (read-only data, Ledger turned off) leads with its key word and has a tooltip with the full text.
--
-- FS_LEDGER_CHANGED refreshes the page, debounced, through MainWindow:RefreshTab (a no-op unless the tab is shown).
-- Nothing here writes: the Ledger records on its own, and records nothing while the saved data is read-only.
--
-- ns.UI.OrdersPanel (CompactMoney, Sign) loads after this file, so it is looked up at call time, like every module.
local LedgerTab = ns.FS:NewModule("LedgerTab", "AceEvent-3.0")
LedgerTab.coreModule = true

local Tab = {}
ns.UI = ns.UI or {}
ns.UI.LedgerTab = Tab

local TAB_ID, SOURCE, REFRESH_SOURCE = "ledger", "Tab:ledger", "LedgerTab"
local REFRESH_KEY, REFRESH_DELAY = "ledgerTab.refresh", 0.5
local WEEKS = 8
local WEEK_SECONDS = 7 * 86400
local ROW_HEIGHT, BAR_HEIGHT = 18, 22
local PAD, GAP = 6, 4
local MIN_FLEX = 120
local STATUS_SHARE = 0.45
local DEFAULT_VIEW_HEIGHT = 400   -- before the scroll frame has a size
local SCROLL_STEP = ROW_HEIGHT * 3
local DIM, WARN, GOOD, BAD = "|cff9d9d9d", "|cffffd100", "|cff40ff40", "|cffff4040"
local WHITE, GREY, GOLD = { 1, 1, 1 }, { 0.62, 0.62, 0.62 }, { 1, 0.82, 0 }

-- The page buttons above the list.
Tab.SECTIONS = {
  { id = "profit", label = L["Profit"] },
  { id = "auctions", label = L["Auctions"] },
  { id = "crafts", label = L["Crafts"] },
}
local DEFAULT_SECTION = "profit"
local SECTION_BAR_HEIGHT, SECTION_BUTTON_WIDTH, SECTION_BUTTON_HEIGHT = 24, 90, 20
local current = DEFAULT_SECTION   -- the page shown; session only (nothing is saved)
local EM_DASH = "\226\128\148"   -- UTF-8 for the dash that stands for "no sale yet"

local READ_ONLY_NOTICE = L["Read-only: saved data is from a newer addon version"]
local READ_ONLY_DETAIL = L["Nothing new is recorded until the addon is updated."]
local OFF_NOTICE = L["Ledger off: nothing new is recorded"]
local OFF_DETAIL = L["Turn the Ledger on again in /fs settings > Modules."]
local PARTIAL_DETAIL = L["Their cost is not subtracted, so the real profit may be lower than shown."]
local SALELOG_OFF_NOTICE = L["Sale log off: nothing new is recorded"]
local SALELOG_OFF_DETAIL = L["Turn the Sale log on again in /fs settings > Modules."]
local CRAFTLOG_OFF_NOTICE = L["Craft log off: nothing new is recorded"]
local CRAFTLOG_OFF_DETAIL = L["Turn the Craft log on again in /fs settings > Modules."]

local TYPE_LABELS = { craft = L["craft"], sale = L["sale"], commission = L["commission"] }
local TYPE_NAMES = { craft = L["Craft (cost record)"], sale = L["Auction sale"], commission = L["Order commission"] }

-- Per section, left to right. The flexible column takes the width the fixed ones leave; the columns before it are
-- laid out from the left edge, the ones after it from the right edge. `hide` lists the columns dropped, in order,
-- when the flexible column would get under MIN_FLEX px.
local SECTIONS = {   -- column definitions per list section (not the Profit / Auctions page buttons: Tab.SECTIONS)
  weekly = {
    columns = {
      { key = "week", label = L["Week"], width = 64 },
      { key = "income", label = L["Income"], width = 72, right = true },
      { key = "cost", label = L["Cost"], width = 72, right = true },
      { key = "profit", label = L["Profit"], width = 80, right = true },
      { key = "note", label = "", flex = true },
    },
    hide = { "cost" },
  },
  recipe = {
    columns = {
      { key = "recipe", label = L["Recipe"], flex = true },
      { key = "n", label = L["Count"], width = 36, right = true },
      { key = "income", label = L["Income"], width = 72, right = true },
      { key = "cost", label = L["Cost"], width = 72, right = true },
      { key = "profit", label = L["Profit"], width = 80, right = true },
      { key = "note", label = "", width = 48 },
    },
    hide = { "n", "cost" },
  },
  benchmark = {
    columns = {
      { key = "recipe", label = L["Recipe"], flex = true },
      { key = "quality", label = "Q", width = 24, right = true },
      { key = "p25", label = L["Low (p25)"], width = 64, right = true },
      { key = "median", label = L["Median"], width = 64, right = true },
      { key = "p75", label = L["High (p75)"], width = 64, right = true },
      { key = "n", label = "n", width = 32, right = true },
    },
    hide = { "p25", "p75" },
  },
  entry = {
    columns = {
      { key = "date", label = L["Date"], width = 36 },
      { key = "type", label = L["Type"], width = 64 },
      { key = "item", label = L["Item"], flex = true },
      { key = "amount", label = L["Amount"], width = 72, right = true },
      { key = "customer", label = L["Customer"], width = 90 },
    },
    hide = { "customer", "type" },
  },
}
SECTIONS.auction = {
  columns = {
    { key = "item", label = L["Item"], flex = true },
    { key = "posted", label = L["Posted"], width = 44, right = true },
    { key = "sold", label = L["Sold"], width = 40, right = true },
    { key = "expired", label = L["Expired"], width = 48, right = true },
    { key = "cancelled", label = L["Cancelled"], width = 56, right = true },
    { key = "rate", label = L["Rate"], width = 40, right = true },
    { key = "last", label = L["Last sale"], width = 72, right = true },
    { key = "listed", label = L["Listed"], width = 44, right = true },
  },
  hide = { "cancelled", "expired", "posted" },
}
-- Crafts: at 516 px the fixed columns leave 28 px for Recipe, so Concentration goes first (144 px), Resourcefulness next.
SECTIONS.craft = {
  columns = {
    { key = "recipe", label = L["Recipe"], flex = true },
    { key = "crafts", label = L["Crafts"], width = 40, right = true },
    { key = "quality", label = L["Quality"], width = 112 },
    { key = "multicraft", label = L["Multicraft"], width = 104 },
    { key = "resourcefulness", label = L["Resourcefulness"], width = 88 },
    { key = "concentration", label = L["Concentration"], width = 112 },
  },
  hide = { "concentration", "resourcefulness" },
}
for _, def in pairs(SECTIONS) do
  def.widths, def.hideable, def.used = {}, {}, 2 * PAD + (#def.columns - 1) * GAP
  for i, col in ipairs(def.columns) do
    if col.flex then
      def.flex = i
    else
      def.widths[col.key] = col.width
      def.used = def.used + col.width
    end
  end
  for _, key in ipairs(def.hide) do def.hideable[key] = true end
end

local view            -- built frames and the displayed items, nil before the tab is built
local requested = {}  -- [itemID] = true while its data is requested, "done" after; asked once per session

local function module(name)
  return ns.FS:GetModule(name, true)
end

local function color(code, text)
  return code .. text .. "|r"
end

local function is_money(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function count(v)
  return type(v) == "number" and v or 0
end

-- Numbers in numeric order, anything else after them by its text (so damaged saved keys still sort).
local function id_less(a, b)
  if type(a) == "number" and type(b) == "number" then return a < b end
  if type(a) == "number" then return true end
  if type(b) == "number" then return false end
  return tostring(a) < tostring(b)
end

local function counts_as_profit(entry)
  return entry.type == "sale" or entry.type == "commission"
end

---------------------------------------------------------------------------
-- Models (pure apart from reading the Ledger and Scanner modules)
---------------------------------------------------------------------------

-- Ledger:ByRecipe's { [recipeID] = {income, cost, profit, n, incomplete} } -> { {recipeID, income, cost, profit, n,
-- incomplete, estimated?} } (copies), highest profit first; an unknown profit sorts last, equal ones by recipeID.
function Tab.RecipeRows(byRecipe)
  local rows = {}
  for recipeID, t in pairs(type(byRecipe) == "table" and byRecipe or {}) do
    if type(t) == "table" then
      rows[#rows + 1] = { recipeID = recipeID, income = t.income, cost = t.cost, profit = t.profit, n = t.n,
        incomplete = t.incomplete, estimated = t.estimated }
    end
  end
  table.sort(rows, function(a, b)
    local pa, pb = is_money(a.profit), is_money(b.profit)
    if pa ~= pb then return pa end
    if pa and a.profit ~= b.profit then return a.profit > b.profit end
    return id_less(a.recipeID, b.recipeID)
  end)
  return rows
end

-- Ledger entries -> { {recipeID, quality, median, p25, p75, n} }: the benchmark (Ledger:Benchmarks) of every
-- distinct (recipeID, quality) of a commission, sorted by recipeID, then quality. Pairs without enough samples are
-- skipped, and so are recrafts (Benchmark leaves them out) and commissions with no recipeID. A commission with no
-- numeric quality is left out of a recipe that has commissions with one (an all-qualities row would repeat those);
-- a recipe whose commissions have no quality at all gets one Benchmark(recipeID, nil) row with quality nil (shown
-- as "-").
function Tab.BenchmarkRows(entries)
  local ledger = module("Ledger")
  if not ledger then return {} end
  local seen, pairsList, withQuality, noQuality = {}, {}, {}, {}
  for _, e in ipairs(type(entries) == "table" and entries or {}) do
    if type(e) == "table" and e.type == "commission" and e.recipeID ~= nil and not e.recraft then
      if type(e.quality) == "number" then
        withQuality[e.recipeID] = true
        local key = tostring(e.recipeID) .. ":" .. tostring(e.quality)
        if not seen[key] then
          seen[key] = true
          pairsList[#pairsList + 1] = { recipeID = e.recipeID, quality = e.quality }
        end
      elseif noQuality[e.recipeID] == nil then
        noQuality[e.recipeID] = { recipeID = e.recipeID }
      end
    end
  end
  for recipeID, pair in pairs(noQuality) do
    if not withQuality[recipeID] then pairsList[#pairsList + 1] = pair end
  end
  table.sort(pairsList, function(a, b)
    if a.recipeID ~= b.recipeID then return id_less(a.recipeID, b.recipeID) end
    return (a.quality or 0) < (b.quality or 0)
  end)
  -- One Ledger:Benchmarks pass for every pair (same rules as Benchmark); Benchmark per pair only without it.
  local all = ledger.Benchmarks and ledger:Benchmarks() or nil
  local function benchmark(recipeID, quality)
    if not all then return ledger:Benchmark(recipeID, quality) end
    local byQuality = all[recipeID]
    return byQuality and byQuality[quality == nil and "all" or quality] or nil
  end
  local rows = {}
  for _, p in ipairs(pairsList) do
    local b = benchmark(p.recipeID, p.quality)
    if type(b) == "table" then
      rows[#rows + 1] = { recipeID = p.recipeID, quality = p.quality, median = b.median, p25 = b.p25, p75 = b.p75,
        n = b.n }
    end
  end
  return rows
end

-- A section's columns for a content width -> { hidden = { [columnKey] = true }, flex = flexible column width|nil }.
-- The flexible column keeps at least MIN_FLEX px; the section's `hide` columns go first, in order. An unknown width
-- (not laid out yet) hides nothing.
function Tab.Layout(section, width)
  local def = SECTIONS[section]
  local hidden = {}
  if not def or type(width) ~= "number" or width <= 0 then return { hidden = hidden } end
  local flex = width - def.used
  for _, key in ipairs(def.hide) do
    if flex >= MIN_FLEX then break end
    hidden[key] = true
    flex = flex + def.widths[key] + GAP
  end
  return { hidden = hidden, flex = flex }
end

local function copy_totals(t, extra)
  local row = { income = t.income, cost = t.cost, profit = t.profit, n = t.n, incomplete = t.incomplete,
    estimated = t.estimated }
  for k, v in pairs(extra or {}) do row[k] = v end
  return row
end

-- ledger = the Ledger module (or nil), now = server seconds -> {
--   available, count = entries, newest = newest entry time|nil, entries = Ledger:Query({}) (live, read-only),
--   weekly = { rows = { {weekStart, income, cost, profit, incomplete, estimated?, index} }, total } | nil when the
--     week boundary is unknown,
--   since = the oldest shown week's start | nil (unknown week: every entry),
--   recipes = RecipeRows since `since`, unattributed = Ledger:Unattributed totals since `since` | nil when none,
--   benchmarks = BenchmarkRows (all entries), minSamples }.
-- `estimated` (from the Ledger; nil when none) counts the sales and commissions whose cost was estimated (they make
-- the cost and profit "~").
function Tab.Model(ledger, now)
  if not ledger then return { available = false, count = 0, entries = {}, recipes = {}, benchmarks = {} } end
  local entries = ledger:Query({})
  local model = { available = true, count = #entries, entries = entries }
  for _, e in ipairs(entries) do
    if is_money(e.time) then model.newest = e.time; break end
  end

  local weekly = ledger:Weekly(now, WEEKS)
  if type(weekly) == "table" and #weekly > 0 then
    local rows, total = {}, { income = 0, cost = 0, profit = 0, incomplete = 0, estimated = 0, total = true }
    for i, w in ipairs(weekly) do
      rows[i] = copy_totals(w, { weekStart = w.weekStart, index = i })
      for _, key in ipairs({ "income", "cost", "profit", "incomplete", "estimated" }) do
        total[key] = total[key] + count(w[key])
      end
    end
    model.weekly = { rows = rows, total = total }
    model.since = rows[#rows].weekStart
  end

  -- The recipe table covers the weeks shown above (every entry when the week boundary is unknown).
  local filter = { since = model.since }
  model.recipes = Tab.RecipeRows(ledger:ByRecipe(filter))
  local unattributed = ledger:Unattributed(filter)
  if type(unattributed) == "table" and count(unattributed.n) > 0 then
    model.unattributed = copy_totals(unattributed, { unattributed = true })
  end

  model.benchmarks = Tab.BenchmarkRows(entries)
  local settings = ledger.Settings and ledger:Settings() or {}
  model.minSamples = settings.benchmarkMinSamples
  return model
end

-- The model as list items, top to bottom: { kind = "heading"|"note", text } | { kind = "header", section } |
-- { kind = "row", section, data } | { kind = "spacer" }. Empty when the ledger has no entries (or is missing).
function Tab.DisplayRows(model)
  local items = {}
  if not model or model.count == 0 then return items end
  local function add(item) items[#items + 1] = item end
  local function rows(section, list)
    add({ kind = "header", section = section })
    for _, data in ipairs(list) do add({ kind = "row", section = section, data = data }) end
  end

  add({ kind = "heading", text = (L["Weekly profit (last %d reset weeks)"]):format(WEEKS) })
  if model.weekly then
    local list = {}
    for i, row in ipairs(model.weekly.rows) do list[i] = row end
    list[#list + 1] = model.weekly.total
    rows("weekly", list)
  else
    add({ kind = "note", text = L["Week boundary unknown: the game gave no weekly reset time"] })
  end

  add({ kind = "spacer" })
  add({ kind = "heading", text = model.weekly and (L["Profit by recipe (last %d reset weeks)"]):format(WEEKS)
    or L["Profit by recipe (all recorded)"] })
  if #model.recipes > 0 or model.unattributed then
    local list = {}
    for i, row in ipairs(model.recipes) do list[i] = row end
    if model.unattributed then list[#list + 1] = model.unattributed end
    rows("recipe", list)
  else
    add({ kind = "note", text = model.weekly and (L["No sales or commissions in the last %d reset weeks"]):format(WEEKS)
      or L["No sales or commissions yet: only crafts (cost records) are recorded"] })
  end

  add({ kind = "spacer" })
  add({ kind = "heading", text = L["Your tips by recipe and quality"] })
  if #model.benchmarks > 0 then
    rows("benchmark", model.benchmarks)
  else
    add({ kind = "note", text = (L["No tip history yet: %s commissions per recipe and quality are needed"])
      :format(tostring(model.minSamples or "a few")) })
  end

  add({ kind = "spacer" })
  add({ kind = "heading", text = (L["Entries (%d)"]):format(#model.entries) })
  rows("entry", model.entries)
  return items
end

-- The recipe's name from the cached schematic, else "Recipe <id>".
local function recipe_name(recipeID)
  local scanner = module("Scanner")
  local schematic = scanner and scanner.GetSchematic and recipeID ~= nil and scanner:GetSchematic(recipeID) or nil
  if type(schematic) == "table" and type(schematic.name) == "string" then return schematic.name end
  return (L["Recipe %s"]):format(tostring(recipeID))
end

-- An entry's item: the client's cached name, else the sale mail's item text, else the recipe's name, else
-- "item:<id>" ("--" with nothing to go on).
local function item_name(entry)
  local api = C_Item
  local id = entry.itemID
  local name = id ~= nil and type(api) == "table" and type(api.GetItemNameByID) == "function"
    and api.GetItemNameByID(id) or nil
  if type(name) == "string" and name ~= "" then return name end
  if type(entry.itemName) == "string" and entry.itemName ~= "" then return entry.itemName end
  if entry.recipeID ~= nil then
    local scanner = module("Scanner")
    local schematic = scanner and scanner.GetSchematic and scanner:GetSchematic(entry.recipeID) or nil
    if type(schematic) == "table" and type(schematic.name) == "string" then return schematic.name end
  end
  if id ~= nil then return "item:" .. tostring(id) end
  return "--"
end

local function customer_of(entry)
  if entry.customer ~= nil then return tostring(entry.customer) end
  if entry.buyer ~= nil then return tostring(entry.buyer) end
  if entry.orderType == "npc" then return L["Patron"] end
  return nil
end

local function type_label(entry)
  if entry.type == "commission" and entry.recraft then return L["recraft"] end
  return TYPE_LABELS[entry.type] or tostring(entry.type or "?")
end

local function date_text(time, format)
  if not is_money(time) then return "--" end
  return date(format, time)
end

-- A compact money cell: "?" (grey) for unknown money, never 0g; grey when it shows as "0g"; coloured green / red by
-- sign when `signed`; "~" before an estimate.
local function money_cell(copper, signed, estimated)
  if not is_money(copper) then return color(DIM, "?") end
  local P = ns.UI.OrdersPanel
  local text = P and P.CompactMoney and P.CompactMoney(copper) or ns.UI.FormatMoney(copper)
  if estimated then text = "~" .. text end
  local sign = P and P.Sign and P.Sign(copper) or (copper > 0 and 1 or copper < 0 and -1 or 0)
  if sign == 0 then return color(DIM, text) end
  if signed then return color(sign > 0 and GOOD or BAD, text) end
  return text
end

local function partial_note(incomplete)
  return (L["partial: %d with missing or partial cost"]):format(incomplete)
end

-- SaleLog:GetAllStats' { [itemID] = ItemSaleStats } -> one row per item: { itemID, name, posted, sold|nil, expired,
-- cancelled, rate|nil (whole percent, floored), lastSale = { time, unitPrice }|nil, lastAge|nil (seconds before
-- `now`), listed|nil }. Best sellers first: `sold` descending (unknown last), then the item's name, then itemID.
-- Unknown is nil, never 0: sold and rate are nil while the Ledger is off (rate also with nothing ended), listed while
-- no listing was read.
function Tab.AuctionRows(stats, now)
  local rows = {}
  for itemID, s in pairs(type(stats) == "table" and stats or {}) do
    if type(s) == "table" then
      local row = { itemID = itemID, name = item_name({ itemID = itemID }), posted = count(s.posted),
        sold = is_money(s.sold) and s.sold or nil, expired = count(s.expired), cancelled = count(s.cancelled),
        listed = is_money(s.listed) and s.listed or nil }
      if is_money(s.saleRate) then
        -- The epsilon keeps 29 / 100 (28.999999999999996 after the multiplication) at 29.
        row.rate = math.max(0, math.min(100, math.floor(s.saleRate * 100 + 1e-9)))
      end
      if type(s.lastSale) == "table" and is_money(s.lastSale.unitPrice) then
        row.lastSale = { time = s.lastSale.time, unitPrice = s.lastSale.unitPrice }
        if is_money(s.lastSale.time) and is_money(now) then row.lastAge = math.max(0, now - s.lastSale.time) end
      end
      rows[#rows + 1] = row
    end
  end
  table.sort(rows, function(a, b)
    if (a.sold ~= nil) ~= (b.sold ~= nil) then return a.sold ~= nil end
    if a.sold ~= b.sold then return a.sold > b.sold end
    local na, nb = tostring(a.name):lower(), tostring(b.name):lower()
    if na ~= nb then return na < nb end
    return id_less(a.itemID, b.itemID)
  end)
  return rows
end

-- The Auctions page as list items: the column header, a row per item, a spacer and the footer note. Empty without rows.
function Tab.AuctionDisplayRows(rows, windowDays)
  local items = {}
  if type(rows) ~= "table" or #rows == 0 then return items end
  items[1] = { kind = "header", section = "auction" }
  for _, data in ipairs(rows) do items[#items + 1] = { kind = "row", section = "auction", data = data } end
  items[#items + 1] = { kind = "spacer" }
  items[#items + 1] = { kind = "note", text = (L["Your own auctions over the last %d days. Sales come from the Ledger's sold mail; prices are after the AH cut."])
    :format(windowDays) }
  return items
end

-- CraftLog:Summary's { [recipeID] = RecipeCraftStats } -> one row per recipe: { recipeID, name, <the stats> } (copies),
-- most crafts first, then by name (case-insensitive), then recipeID. `names` = { [recipeID] = name } for the recipes it
-- knows; the others use the cached schematic's name, else "Recipe <id>". Unknown stats stay nil.
function Tab.CraftRows(summary, names)
  local rows = {}
  names = type(names) == "table" and names or {}
  for recipeID, s in pairs(type(summary) == "table" and summary or {}) do
    if type(s) == "table" then
      local row = { recipeID = recipeID, name = names[recipeID] or recipe_name(recipeID) }
      for k, v in pairs(s) do row[k] = v end
      rows[#rows + 1] = row
    end
  end
  table.sort(rows, function(a, b)
    local ca, cb = count(a.crafts), count(b.crafts)
    if ca ~= cb then return ca > cb end
    local na, nb = tostring(a.name):lower(), tostring(b.name):lower()
    if na ~= nb then return na < nb end
    return id_less(a.recipeID, b.recipeID)
  end)
  return rows
end

-- The Crafts page as list items: the column header, a row per recipe, a spacer and the footer note. Empty without rows.
function Tab.CraftDisplayRows(rows)
  local items = {}
  if type(rows) ~= "table" or #rows == 0 then return items end
  items[1] = { kind = "header", section = "craft" }
  for _, data in ipairs(rows) do items[#items + 1] = { kind = "row", section = "craft", data = data } end
  items[#items + 1] = { kind = "spacer" }
  items[#items + 1] = { kind = "note", text = (L["Your crafts over the last %d weeks, next to the predictions."]):format(WEEKS) }
  return items
end

-- The item's icon as texture markup ("" when the client has none cached), then its name.
local function icon_markup(itemID)
  local api = type(C_Item) == "table" and C_Item.GetItemIconByID
  if type(api) ~= "function" then return "" end
  local ok, icon = pcall(api, itemID)
  if ok and icon ~= nil and icon ~= "" then return ("|T%s:14|t "):format(tostring(icon)) end
  return ""
end

local function rounded(v)
  return string.format("%d", math.floor(v + 0.5))
end

local function procs_text(n)
  return (n == 1 and L["%d proc"] or L["%d procs"]):format(n)
end

-- The Multicraft cell: the extras seen next to the expected ones; "?" for a part nobody reported, and a trailing "?"
-- when some of the crafts did not report theirs.
local function multicraft_text(data)
  local expected = is_money(data.expectedExtra) and string.format("%.1f", data.expectedExtra) or "?"
  if not is_money(data.actualExtra) then return (L["? (expected +%s)"]):format(expected) end
  local text = (L["+%d (expected +%s)"]):format(math.floor(data.actualExtra + 0.5), expected)
  if count(data.multicraftReported) < count(data.crafts) then text = text .. " " .. color(DIM, "?") end
  return text
end

-- The display text of one data row's cells, by column key.
function Tab.CellTexts(section, data)
  data = type(data) == "table" and data or {}
  if section == "craft" then
    local known = count(data.qualityKnown) > 0
    return {
      recipe = tostring(data.name or recipe_name(data.recipeID)),
      crafts = tostring(count(data.crafts)),
      quality = known and (L["%d of %d as predicted"]):format(count(data.asPredicted), data.qualityKnown) or color(DIM, "?"),
      multicraft = multicraft_text(data),
      resourcefulness = procs_text(count(data.resourcefulnessProcs)),
      concentration = (is_money(data.concentrationSpent) and is_money(data.concentrationPredicted))
        and (L["%s of %s predicted"]):format(rounded(data.concentrationSpent), rounded(data.concentrationPredicted))
        or color(DIM, EM_DASH),
    }
  end
  if section == "auction" then
    local function known(v) return v ~= nil and tostring(v) or color(DIM, "?") end
    return {
      item = icon_markup(data.itemID) .. tostring(data.name),
      posted = tostring(count(data.posted)), sold = known(data.sold),
      expired = tostring(count(data.expired)), cancelled = tostring(count(data.cancelled)),
      rate = data.rate ~= nil and (L["%d%%"]):format(data.rate) or color(DIM, "?"),
      last = data.lastSale and money_cell(data.lastSale.unitPrice, false, false) or color(DIM, EM_DASH),
      listed = known(data.listed),
    }
  end
  if section == "weekly" or section == "recipe" then
    local est = count(data.estimated) > 0
    local cells = {
      income = money_cell(data.income, false, false),
      cost = money_cell(data.cost, false, est),
      profit = money_cell(data.profit, true, est),
      note = "",
    }
    if section == "weekly" then
      if data.total then
        cells.week = (L["%d weeks"]):format(WEEKS)
      elseif data.index == 1 then
        cells.week = L["This week"]
      else
        cells.week = date_text(data.weekStart, "%m-%d")
      end
      if count(data.incomplete) > 0 then
        cells.note = color(WARN, partial_note(data.incomplete))
      elseif est then
        cells.note = color(DIM, L["estimate"])
      end
    else
      cells.recipe = data.unattributed and L["Unattributed sales"] or recipe_name(data.recipeID)
      cells.n = tostring(count(data.n))
      if count(data.incomplete) > 0 then
        cells.note = color(WARN, L["partial"])
      elseif est then
        cells.note = color(DIM, L["estimate"])
      end
    end
    return cells
  elseif section == "benchmark" then
    return {
      recipe = recipe_name(data.recipeID),
      quality = data.quality ~= nil and tostring(data.quality) or "-",
      p25 = money_cell(data.p25, false, false),
      median = money_cell(data.median, false, false),
      p75 = money_cell(data.p75, false, false),
      n = tostring(count(data.n)),
    }
  elseif section == "entry" then
    return {
      date = date_text(data.time, "%m-%d"),
      type = type_label(data),
      item = item_name(data),
      -- Only a craft's amount is its (possibly estimated) cost; a sale or commission amount is exact gold.
      amount = money_cell(data.amount, true, data.type == "craft" and data.estimated == true),
      customer = customer_of(data) or "",
    }
  end
  return {}
end

local function full_money(copper, estimated)
  if not is_money(copper) then return L["unknown"] end
  return (estimated and "~" or "") .. ns.UI.FormatMoney(copper)
end

local function line(text, rgb)
  return { text = text, color = rgb or WHITE }
end

-- The income / cost / profit lines of a weekly or recipe row, with what makes them partial or estimated.
local function totals_lines(lines, data)
  local est = count(data.estimated) > 0
  lines[#lines + 1] = line((L["Income: %s"]):format(full_money(data.income)))
  lines[#lines + 1] = line((L["Cost: %s"]):format(full_money(data.cost, est)))
  lines[#lines + 1] = line((L["Profit: %s"]):format(full_money(data.profit, est)))
  if count(data.incomplete) > 0 then
    lines[#lines + 1] = line((L["Partial: %d with missing or partial cost"]):format(data.incomplete), GOLD)
    lines[#lines + 1] = line(PARTIAL_DETAIL, GOLD)
  end
  if est then
    lines[#lines + 1] = line((L["Estimate: %d with an estimated craft cost"]):format(data.estimated), GREY)
  end
end

local function entry_lines(lines, e)
  lines[#lines + 1] = line(item_name(e))
  lines[#lines + 1] = line(date_text(e.time, "%Y-%m-%d %H:%M"), GREY)
  local kind = TYPE_NAMES[e.type] or tostring(e.type)
  if e.type == "commission" and e.recraft then kind = (L["%s (recraft)"]):format(kind) end
  lines[#lines + 1] = line(kind)
  lines[#lines + 1] = line((L["Amount: %s"]):format(full_money(e.amount, e.type == "craft" and e.estimated == true)))
  if counts_as_profit(e) then
    if e.recraft then
      lines[#lines + 1] = line(L["Cost: not tracked for recrafts"], GREY)
    elseif is_money(e.cost) then
      lines[#lines + 1] = line((L["Cost: %s"]):format(full_money(e.cost, e.estimated == true)))
      if e.incomplete then lines[#lines + 1] = line(L["Cost is partial: some reagent prices were missing"], GOLD) end
    else
      lines[#lines + 1] = line(L["Cost: unknown (no cost basis)"], GOLD)
    end
  elseif e.incomplete then
    lines[#lines + 1] = line(L["Cost is partial: some reagent prices were missing"], GOLD)
  end
  if e.type == "commission" and e.tip ~= nil then lines[#lines + 1] = line((L["Tip: %s"]):format(full_money(e.tip))) end
  if e.customer ~= nil then
    lines[#lines + 1] = line((L["Customer: %s"]):format(tostring(e.customer)))
  elseif e.buyer ~= nil then
    lines[#lines + 1] = line((L["Buyer: %s"]):format(tostring(e.buyer)))
  elseif e.orderType == "npc" then
    lines[#lines + 1] = line(L["Customer: Patron (NPC order)"])
  end
  if e.quality ~= nil then lines[#lines + 1] = line((L["Quality: %s"]):format(tostring(e.quality)), GREY) end
  if type(e.quantity) == "number" and e.quantity ~= 1 then
    lines[#lines + 1] = line((L["Quantity: %s"]):format(tostring(e.quantity)), GREY)
  end
  if e.charKey ~= nil then lines[#lines + 1] = line((L["Character: %s"]):format(tostring(e.charKey)), GREY) end
  if e.ambiguous then lines[#lines + 1] = line(L["Several items share this name; no cost was matched"], GREY) end
end

-- A list item's tooltip, as { { text, color = {r, g, b} } }: the full values the compact cells may cut, and why a
-- number is partial or estimated. Empty for headers and spacers.
function Tab.TooltipLines(item)
  local lines = {}
  if type(item) ~= "table" then return lines end
  if item.kind == "note" or item.kind == "heading" then
    lines[1] = line(tostring(item.text))
    return lines
  end
  if item.kind ~= "row" then return lines end
  local data = type(item.data) == "table" and item.data or {}
  if item.section == "weekly" then
    if data.total then
      lines[1] = line((L["Last %d reset weeks"]):format(WEEKS))
    else
      lines[1] = line((L["Week starting %s"]):format(date_text(data.weekStart, "%Y-%m-%d %H:%M")))
    end
    totals_lines(lines, data)
  elseif item.section == "recipe" then
    if data.unattributed then
      lines[1] = line(L["Unattributed sales"])
      lines[2] = line(L["Sales whose item could not be matched to a recipe you crafted"], GREY)
    else
      lines[1] = line(recipe_name(data.recipeID))
    end
    lines[#lines + 1] = line((L["Sales and commissions: %s"]):format(tostring(count(data.n))))
    totals_lines(lines, data)
  elseif item.section == "benchmark" then
    local title = data.quality ~= nil and (L["%s (quality %s)"]):format(recipe_name(data.recipeID), tostring(data.quality))
      or (L["%s (all qualities)"]):format(recipe_name(data.recipeID))
    lines[1] = line(title)
    lines[2] = line((L["Median tip: %s"]):format(full_money(data.median)))
    lines[3] = line((L["A quarter of your tips were below %s"]):format(full_money(data.p25)))
    lines[4] = line((L["A quarter of your tips were above %s"]):format(full_money(data.p75)))
    lines[5] = line((L["From %d of your commissions (recrafts not counted)"]):format(count(data.n)), GREY)
  elseif item.section == "entry" then
    entry_lines(lines, data)
  elseif item.section == "craft" then
    lines[1] = line(tostring(data.name or recipe_name(data.recipeID)))
    lines[2] = line((L["Crafts: %d"]):format(count(data.crafts)), GREY)
    if count(data.qualityKnown) > 0 then
      lines[#lines + 1] = line((L["Quality: %d of %d as predicted, %d above, %d below"]):format(count(data.asPredicted),
        data.qualityKnown, count(data.above), count(data.below)))
    else
      lines[#lines + 1] = line(L["Quality: no craft has both a prediction and a result yet"], GREY)
    end
    lines[#lines + 1] = line((L["The game's own prediction matched the result in %d"]):format(count(data.gameAgreed)), GREY)
    lines[#lines + 1] = line((L["Multicraft: %s extra items seen, %s expected"]):format(
      is_money(data.actualExtra) and tostring(data.actualExtra) or "?",
      is_money(data.expectedExtra) and string.format("%.1f", data.expectedExtra) or "?"))
    if count(data.multicraftReported) < count(data.crafts) then
      lines[#lines + 1] = line((L["Multicraft reported for %d of %d crafts"]):format(count(data.multicraftReported),
        count(data.crafts)), GOLD)
    end
    lines[#lines + 1] = line((L["Resourcefulness: %s"]):format(procs_text(count(data.resourcefulnessProcs))))
    if is_money(data.concentrationSpent) and is_money(data.concentrationPredicted) then
      lines[#lines + 1] = line((L["Concentration: %s spent, %s predicted"]):format(rounded(data.concentrationSpent),
        rounded(data.concentrationPredicted)))
    else
      lines[#lines + 1] = line(L["Concentration: no data yet"], GREY)
    end
  elseif item.section == "auction" then
    lines[1] = line(tostring(data.name))
    lines[2] = line((L["Posted %d, expired %d, cancelled %d"]):format(count(data.posted), count(data.expired),
      count(data.cancelled)), GREY)
    if data.sold == nil then
      lines[#lines + 1] = line(L["Sales unknown: the Ledger is off"], GOLD)
    elseif data.rate == nil then
      lines[#lines + 1] = line(L["No auction has ended yet in this period"], GREY)
    else
      lines[#lines + 1] = line((L["%d of %d sold (%d%%)"]):format(data.sold,
        data.sold + count(data.expired) + count(data.cancelled), data.rate))
    end
    if data.lastSale then
      lines[#lines + 1] = line((L["Last sale: %s each, %s ago"]):format(full_money(data.lastSale.unitPrice),
        ns.UI.FormatAge(data.lastAge)))
    end
    lines[#lines + 1] = line((L["Listed now: %s"]):format(data.listed ~= nil and tostring(data.listed) or "?"))
  end
  return lines
end

---------------------------------------------------------------------------
-- Tooltips and item data
---------------------------------------------------------------------------

local function show_lines(owner, lines)
  if type(GameTooltip) ~= "table" or #lines == 0 then return end
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  for i, l in ipairs(lines) do
    local c = l.color or WHITE
    if i == 1 then
      GameTooltip:SetText(l.text, c[1], c[2], c[3])
    else
      GameTooltip:AddLine(l.text, c[1], c[2], c[3], true)
    end
  end
  GameTooltip:Show()
end

local function hide_tooltip()
  if type(GameTooltip) == "table" then GameTooltip:Hide() end
end

local function show_row_tooltip(owner)
  if owner.item then show_lines(owner, Tab.TooltipLines(owner.item)) end
end

local function request_refresh()
  local window = module("MainWindow")
  if window and window.RefreshTab then window:RefreshTab(TAB_ID) end
end

local refreshLater = ns.FS:Wrap(REFRESH_SOURCE, request_refresh)

local function schedule_refresh()
  ns.FS:Debounce(REFRESH_KEY, REFRESH_DELAY, refreshLater)
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
-- Rows
---------------------------------------------------------------------------

-- Anchors a section's cells (by column index) in parent: the columns before the flexible one from the left edge
-- rightwards, the ones after it from the right edge leftwards, and the flexible one between them. Hidden columns
-- are left out of the chain.
local function place_cells(parent, cells, section, hidden)
  local def = SECTIONS[section]
  local columns, flexIndex = def.columns, def.flex
  local left
  for i = 1, flexIndex - 1 do
    local cell = cells[i]
    cell:ClearAllPoints()
    if not hidden[columns[i].key] then
      if left then
        cell:SetPoint("LEFT", left, "RIGHT", GAP, 0)
      else
        cell:SetPoint("LEFT", parent, "LEFT", PAD, 0)
      end
      cell:SetWidth(columns[i].width)
      left = cell
    end
  end
  local right
  for i = #columns, flexIndex + 1, -1 do
    local cell = cells[i]
    cell:ClearAllPoints()
    if not hidden[columns[i].key] then
      if right then
        cell:SetPoint("RIGHT", right, "LEFT", -GAP, 0)
      else
        cell:SetPoint("RIGHT", parent, "RIGHT", -PAD, 0)
      end
      cell:SetWidth(columns[i].width)
      right = cell
    end
  end
  local flex = cells[flexIndex]
  flex:ClearAllPoints()
  if left then flex:SetPoint("LEFT", left, "RIGHT", GAP, 0) else flex:SetPoint("LEFT", parent, "LEFT", PAD, 0) end
  if right then flex:SetPoint("RIGHT", right, "LEFT", -GAP, 0) else flex:SetPoint("RIGHT", parent, "RIGHT", -PAD, 0) end
end

local function layout_key(section, hidden)
  local keys = {}
  for _, key in ipairs(SECTIONS[section].hide) do if hidden[key] then keys[#keys + 1] = key end end
  return table.concat(keys, ",")
end

local function hidden_for(section)
  local layout = view and view.layouts[section]
  return layout and layout.hidden or {}
end

-- A pooled row's cells for one section (data cells, or with `header` the column labels), created on first use.
local function group_for(row, section, header)
  local id = header and (section .. ":header") or section
  local group = row.groups[id]
  if group then return group end
  group = { section = section, cells = {}, placed = {} }
  for i, col in ipairs(SECTIONS[section].columns) do
    local cell = row:CreateFontString(nil, "OVERLAY", header and "GameFontNormalSmall" or "GameFontHighlightSmall")
    cell:SetJustifyH(col.right and "RIGHT" or "LEFT")
    cell:SetWordWrap(false)
    if header then cell:SetText(col.label) end
    group.cells[col.key] = cell
    group.placed[i] = cell
  end
  row.groups[id] = group
  return group
end

local function show_group(group, on)
  local hidden = hidden_for(group.section)
  for _, col in ipairs(SECTIONS[group.section].columns) do
    local cell = group.cells[col.key]
    if on and not hidden[col.key] then cell:Show() else cell:Hide() end
  end
end

local function create_row()
  local row = CreateFrame("Frame", nil, view.child)
  row:SetHeight(ROW_HEIGHT)
  row:EnableMouse(true)
  row.background = row:CreateTexture(nil, "BACKGROUND")
  row.background:SetAllPoints(row)
  row.heading = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  row.note = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  for _, text in ipairs({ row.heading, row.note }) do
    text:SetPoint("LEFT", row, "LEFT", PAD, 0)
    text:SetPoint("RIGHT", row, "RIGHT", -PAD, 0)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    text:Hide()
  end
  row.groups = {}
  -- SetScript is deliberate: the row is our own.
  row:SetScript("OnEnter", ns.FS:Wrap(SOURCE, show_row_tooltip))
  row:SetScript("OnLeave", hide_tooltip)
  return row
end

local function bind_row(row, item, index)
  row.item = item
  row:ClearAllPoints()
  row:SetPoint("TOPLEFT", view.child, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
  row:SetPoint("TOPRIGHT", view.child, "TOPRIGHT", 0, -(index - 1) * ROW_HEIGHT)

  local active
  if item.kind == "header" or item.kind == "row" then
    active = group_for(row, item.section, item.kind == "header")
    local key = view.layoutKeys[item.section]
    if active.layoutKey ~= key then
      place_cells(row, active.placed, item.section, hidden_for(item.section))
      active.layoutKey = key
    end
  end
  for _, group in pairs(row.groups) do
    if group ~= active then show_group(group, false) end
  end
  if active then show_group(active, true) end

  row.heading:SetText(item.kind == "heading" and item.text or "")
  if item.kind == "heading" then row.heading:Show() else row.heading:Hide() end
  row.note:SetText(item.kind == "note" and color(DIM, item.text) or "")
  if item.kind == "note" then row.note:Show() else row.note:Hide() end

  if item.kind == "row" then
    if item.section == "entry" or item.section == "auction" then request_item(item.data.itemID) end
    local texts = Tab.CellTexts(item.section, item.data)
    for key, cell in pairs(active.cells) do cell:SetText(texts[key] or "") end
    local total = item.data.total or item.data.unattributed
    row.background:SetColorTexture(1, 1, 1, total and 0.08 or (index % 2 == 0 and 0.04 or 0))
  else
    row.background:SetColorTexture(1, 1, 1, 0)
  end
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
    local item = view.items[first + slot - 1]
    if not item then break end
    local row = view.pool[slot]
    if not row then
      row = create_row()
      view.pool[slot] = row
    end
    bind_row(row, item, first + slot - 1)
    used = slot
  end
  for slot = used + 1, #view.pool do
    view.pool[slot].item = nil
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
-- Layout and refresh
---------------------------------------------------------------------------

-- Lays every section out for the container's width (the rows are re-anchored when they are bound) and sizes the
-- header and status lines: the header takes the whole line without a status, else the status takes STATUS_SHARE.
local function apply_layout()
  if not view then return end
  local width = view.container:GetWidth()
  for section in pairs(SECTIONS) do
    local layout = Tab.Layout(section, width)
    view.layouts[section] = layout
    view.layoutKeys[section] = layout_key(section, layout.hidden)
  end
  if type(width) == "number" and width > 0 then
    local inner = width - 2 * PAD
    local text = view.status:GetText()
    if type(text) == "string" and text ~= "" then
      local statusWidth = math.floor(inner * STATUS_SHARE)
      view.status:SetWidth(statusWidth)
      view.statusArea:SetWidth(statusWidth)
      view.header:SetWidth(inner - statusWidth - GAP)
    else
      view.status:SetWidth(0)
      view.statusArea:SetWidth(0)
      view.header:SetWidth(inner)
    end
  end
  update_rows()
end

-- The status line and its tooltip's second line, for the page shown.
local function status_text(ledger)
  if ns.FS.dbIsNewer then return color(BAD, READ_ONLY_NOTICE), READ_ONLY_DETAIL end
  if current == "auctions" then
    local saleLog = module("SaleLog")
    if saleLog and saleLog.IsEnabled and not saleLog:IsEnabled() then
      return color(WARN, SALELOG_OFF_NOTICE), SALELOG_OFF_DETAIL
    end
    return "", OFF_DETAIL
  end
  if current == "crafts" then
    local craftLog = module("CraftLog")
    if craftLog and craftLog.IsEnabled and not craftLog:IsEnabled() then
      return color(WARN, CRAFTLOG_OFF_NOTICE), CRAFTLOG_OFF_DETAIL
    end
    return "", OFF_DETAIL
  end
  if ledger and ledger.IsEnabled and not ledger:IsEnabled() then return color(WARN, OFF_NOTICE), OFF_DETAIL end
  return "", OFF_DETAIL
end

local function empty_text(ledger)
  if not ledger then return L["The Ledger is not available."] end
  return L["No sales recorded yet. Commissions from the crafting orders you fulfil and the auction sales you collect from the mailbox show here; crafts are kept as their cost."]
end

-- The Auctions page: the sale log's stats as rows, the header line and the text for an empty page.
local function auctions_page(now)
  local saleLog = module("SaleLog")
  if not saleLog or not saleLog.GetAllStats then
    return {}, L["No auctions yet"], L["The sale log is not available."]
  end
  local rows = Tab.AuctionRows(saleLog:GetAllStats(now), now)
  local header = #rows == 0 and L["No auctions yet"]
    or (#rows == 1 and (L["%d item"]):format(1) or (L["%d items"]):format(#rows))
  return Tab.AuctionDisplayRows(rows, saleLog:Settings().windowDays), header,
    L["No auctions recorded yet. Posts, cancels and expiries are recorded as you use the auction house and open your mailbox."]
end

-- The Crafts page: the craft log of the last WEEKS weeks as rows, the header line and the text for an empty page.
local function crafts_page(now)
  local craftLog = module("CraftLog")
  if not craftLog or not craftLog.Summary then
    return {}, L["No crafts yet"], L["The craft log is not available."]
  end
  local rows = Tab.CraftRows(craftLog:Summary({ since = now - WEEKS * WEEK_SECONDS }))
  local total = 0
  for _, row in ipairs(rows) do total = total + count(row.crafts) end
  local header = total == 0 and L["No crafts yet"]
    or (total == 1 and (L["%d craft"]):format(1) or (L["%d crafts"]):format(total))
  return Tab.CraftDisplayRows(rows), header,
    L["No crafts logged yet. Each craft you make is logged with the result it gave, next to the prediction."]
end

local function refresh()
  if not view then return end
  local now = ns.FS:Now()
  local ledger = module("Ledger")
  for id, button in pairs(view.sections) do
    if id == current then button:LockHighlight() else button:UnlockHighlight() end
  end
  local headerText, emptyMessage
  if current == "auctions" then
    view.model = nil
    view.items, headerText, emptyMessage = auctions_page(now)
  elseif current == "crafts" then
    view.model = nil
    view.items, headerText, emptyMessage = crafts_page(now)
  else
    local model = Tab.Model(ledger, now)
    view.model = model
    view.items = Tab.DisplayRows(model)
    if model.count == 0 then
      headerText = L["No entries yet"]
    else
      headerText = model.newest
        and (L["%d entries, newest %s ago"]):format(model.count, ns.UI.FormatAge(now - model.newest))
        or (L["%d entries"]):format(model.count)
    end
    emptyMessage = empty_text(ledger)
  end
  view.header:SetText(headerText)
  local status, detail = status_text(ledger)
  view.status:SetText(status)
  view.statusDetail = detail
  if #view.items == 0 then
    view.empty:SetText(color(DIM, emptyMessage))
    view.empty:Show()
  else
    view.empty:SetText("")
    view.empty:Hide()
  end

  local total = #view.items * ROW_HEIGHT
  view.child:SetHeight(math.max(total, 1))
  local viewHeight = view.scroll:GetHeight()
  if type(viewHeight) == "number" and viewHeight > 0 then
    local offset = view.scroll:GetVerticalScroll()
    local limit = math.max(0, total - viewHeight)
    if type(offset) == "number" and offset > limit then view.scroll:SetVerticalScroll(limit) end
  end
  apply_layout()
end

---------------------------------------------------------------------------
-- Pages
---------------------------------------------------------------------------

local PAGE_IDS = {}
for _, s in ipairs(Tab.SECTIONS) do PAGE_IDS[s.id] = true end

function Tab.GetSection()
  return current
end

-- Shows the page `id` (one of Tab.SECTIONS); an unknown id or the page already shown changes nothing. The choice is
-- session only. The list starts at the top again.
function Tab.SetSection(id)
  if not PAGE_IDS[id] or id == current then return false end
  current = id
  if view then
    view.scroll:SetVerticalScroll(0)
    refresh()
  end
  return true
end

---------------------------------------------------------------------------
-- Build
---------------------------------------------------------------------------

local function build_section_buttons(container, created)
  local bar = CreateFrame("Frame", nil, container)
  bar:SetPoint("TOPLEFT", container, "TOPLEFT", PAD, 0)
  bar:SetPoint("TOPRIGHT", container, "TOPRIGHT", -PAD, 0)
  bar:SetHeight(SECTION_BAR_HEIGHT)
  created.sectionBar, created.sections = bar, {}
  local x = 0
  for _, s in ipairs(Tab.SECTIONS) do
    local button = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
    button:SetSize(SECTION_BUTTON_WIDTH, SECTION_BUTTON_HEIGHT)
    button:SetPoint("TOPLEFT", bar, "TOPLEFT", x, -2)
    button:SetText(s.label)
    button:SetScript("OnClick", ns.FS:Wrap(SOURCE, function() Tab.SetSection(s.id) end))
    created.sections[s.id] = button
    x = x + SECTION_BUTTON_WIDTH + GAP
  end
end

local function build(container)
  local created = { container = container, items = {}, pool = {}, shown = 0, layouts = {}, layoutKeys = {} }
  build_section_buttons(container, created)

  local bar = CreateFrame("Frame", nil, container)
  bar:SetPoint("TOPLEFT", container, "TOPLEFT", PAD, -SECTION_BAR_HEIGHT)
  bar:SetPoint("TOPRIGHT", container, "TOPRIGHT", -PAD, -SECTION_BAR_HEIGHT)
  bar:SetHeight(BAR_HEIGHT)
  created.header = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  created.header:SetPoint("LEFT", bar, "LEFT", 0, 0)
  created.header:SetJustifyH("LEFT")
  created.header:SetWordWrap(false)
  created.status = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  created.status:SetPoint("RIGHT", bar, "RIGHT", 0, 0)
  created.status:SetJustifyH("RIGHT")
  created.status:SetWordWrap(false)
  -- The status line may be cut; its own mouse area shows the full text and what it means.
  created.statusArea = CreateFrame("Frame", nil, bar)
  created.statusArea:SetPoint("RIGHT", bar, "RIGHT", 0, 0)
  created.statusArea:SetHeight(BAR_HEIGHT)
  created.statusArea:EnableMouse(true)
  created.statusArea:SetScript("OnEnter", ns.FS:Wrap(SOURCE, function(self)
    local text = created.status:GetText()
    if type(text) ~= "string" or text == "" then return end
    show_lines(self, { line(text), line(created.statusDetail or OFF_DETAIL, GREY) })
  end))
  created.statusArea:SetScript("OnLeave", hide_tooltip)

  local scrollTop = SECTION_BAR_HEIGHT + BAR_HEIGHT + 2
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
  -- The columns follow the window's width.
  container:HookScript("OnSizeChanged", ns.FS:Wrap(SOURCE, apply_layout))
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

-- Test and diagnostics access: the built view (nil before the tab is built).
function LedgerTab:GetView()
  return view
end

function LedgerTab:OnInitialize()
  local window = module("MainWindow")
  if window then
    window:RegisterTab(TAB_ID, {
      label = L["Ledger"], icon = "Interface\\Icons\\INV_Misc_Coin_02", order = 60, phase = 2,
      build = build,
      refresh = refresh,
    })
  end
end

function LedgerTab:OnEnable()
  -- One refresh follows REFRESH_DELAY after the last change of a burst; MainWindow only refreshes a selected,
  -- visible tab.
  self:RegisterMessage(ns.Msg.LEDGER_CHANGED, ns.FS:Wrap(REFRESH_SOURCE, schedule_refresh))
  -- The Auctions page: posts, cancels, expiries and listings (a sale arrives as a Ledger change).
  self:RegisterMessage(ns.Msg.SALELOG_CHANGED, ns.FS:Wrap(REFRESH_SOURCE, schedule_refresh))
  -- The Crafts page: a craft was logged or got a Multicraft extra.
  self:RegisterMessage(ns.Msg.CRAFTLOG_CHANGED, ns.FS:Wrap(REFRESH_SOURCE, schedule_refresh))
  self:RegisterEvent("GET_ITEM_INFO_RECEIVED", ns.FS:Wrap(REFRESH_SOURCE, on_item_info))
end

function LedgerTab:OnDisable()
  self:UnregisterAllMessages()
  self:UnregisterAllEvents()
  ns.FS:CancelDebounce(REFRESH_KEY)
end
