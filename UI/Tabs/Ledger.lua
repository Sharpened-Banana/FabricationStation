local _, ns = ...

-- Ledger tab: what the player earned crafting (Ledger module), in one scrolling page of four sections:
--   * Weekly profit for the last WEEKS reset weeks plus their total (Ledger:Weekly): week, income, cost, profit and a
--     note "partial: <n> without cost basis" when some of the week's sales or commissions had no known cost.
--   * Profit by recipe (Ledger:ByRecipe, best first) and an "Unattributed sales" row (Ledger:Unattributed: sales
--     whose item could not be matched to a recipe), so the rows add up to the weekly totals.
--   * The player's own tips by recipe and quality (Ledger:Benchmark for every recipe and quality of a commission).
--   * Every entry, newest first (Ledger:Query): date, type, item, amount, customer (or AH buyer).
-- The page is one pooled virtual list in a plain scroll frame, as in the Orders and Queue tabs; each list item is a
-- heading, a column header, a data row, a note or a spacer, and a pooled row keeps one set of cells per section.
--
-- Profit rule (Ledger): only sales and commissions count; crafts are cost records. A sale or commission with no
-- known cost adds nothing to the cost, so a profit with such entries is partial and the real profit may be LOWER
-- than shown (its cost is missing, not zero). Such a profit is never shown as exact: the note says "partial" and
-- the tooltip explains it. A cost that includes an estimated craft cost starts with "~", as does its profit. A
-- recraft commission says "recraft" (its cost is not tracked). Unknown money is "?", never 0g.
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
local WEEK_SECONDS = 604800   -- as in the Ledger module
local ROW_HEIGHT, BAR_HEIGHT = 18, 22
local PAD, GAP = 6, 4
local MIN_FLEX = 120
local STATUS_SHARE = 0.45
local DEFAULT_VIEW_HEIGHT = 400   -- before the scroll frame has a size
local SCROLL_STEP = ROW_HEIGHT * 3
local DIM, WARN, GOOD, BAD = "|cff9d9d9d", "|cffffd100", "|cff40ff40", "|cffff4040"
local WHITE, GREY, GOLD = { 1, 1, 1 }, { 0.62, 0.62, 0.62 }, { 1, 0.82, 0 }

local READ_ONLY_NOTICE = "Read-only: saved data is from a newer addon version"
local READ_ONLY_DETAIL = "Nothing new is recorded until the addon is updated."
local OFF_NOTICE = "Ledger off: nothing new is recorded"
local OFF_DETAIL = "Turn the Ledger on again in /fs settings > Modules."
local PARTIAL_DETAIL = "Their cost is not subtracted, so the real profit may be lower than shown."

local TYPE_LABELS = { craft = "craft", sale = "sale", commission = "commission" }
local TYPE_NAMES = { craft = "Craft (cost record)", sale = "Auction sale", commission = "Order commission" }

-- Per section, left to right. The flexible column takes the width the fixed ones leave; the columns before it are
-- laid out from the left edge, the ones after it from the right edge. `hide` lists the columns dropped, in order,
-- when the flexible column would get under MIN_FLEX px.
local SECTIONS = {
  weekly = {
    columns = {
      { key = "week", label = "Week", width = 64 },
      { key = "income", label = "Income", width = 72, right = true },
      { key = "cost", label = "Cost", width = 72, right = true },
      { key = "profit", label = "Profit", width = 80, right = true },
      { key = "note", label = "", flex = true },
    },
    hide = { "cost" },
  },
  recipe = {
    columns = {
      { key = "recipe", label = "Recipe", flex = true },
      { key = "n", label = "Sales", width = 36, right = true },
      { key = "income", label = "Income", width = 72, right = true },
      { key = "cost", label = "Cost", width = 72, right = true },
      { key = "profit", label = "Profit", width = 80, right = true },
      { key = "note", label = "", width = 48 },
    },
    hide = { "n", "cost" },
  },
  benchmark = {
    columns = {
      { key = "recipe", label = "Recipe", flex = true },
      { key = "quality", label = "Q", width = 24, right = true },
      { key = "p25", label = "Low (p25)", width = 64, right = true },
      { key = "median", label = "Median", width = 64, right = true },
      { key = "p75", label = "High (p75)", width = 64, right = true },
      { key = "n", label = "n", width = 32, right = true },
    },
    hide = { "p25", "p75" },
  },
  entry = {
    columns = {
      { key = "date", label = "Date", width = 36 },
      { key = "type", label = "Type", width = 64 },
      { key = "item", label = "Item", flex = true },
      { key = "amount", label = "Amount", width = 72, right = true },
      { key = "customer", label = "Customer", width = 90 },
    },
    hide = { "customer", "type" },
  },
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
-- incomplete} } (copies), highest profit first; an unknown profit sorts last, equal ones by recipeID.
function Tab.RecipeRows(byRecipe)
  local rows = {}
  for recipeID, t in pairs(type(byRecipe) == "table" and byRecipe or {}) do
    if type(t) == "table" then
      rows[#rows + 1] = { recipeID = recipeID, income = t.income, cost = t.cost, profit = t.profit, n = t.n,
        incomplete = t.incomplete }
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

-- Ledger entries -> { {recipeID, quality, median, p25, p75, n} }: Ledger:Benchmark for every distinct (recipeID,
-- quality) of a commission, sorted by recipeID, then quality. Pairs without enough samples (Benchmark nil) are
-- skipped. A commission with no recipeID or no numeric quality has no pair (Benchmark(recipeID, nil) would mix every
-- quality into one row), and neither has a recraft (Benchmark leaves recrafts out).
function Tab.BenchmarkRows(entries)
  local ledger = module("Ledger")
  if not ledger then return {} end
  local seen, pairsList = {}, {}
  for _, e in ipairs(type(entries) == "table" and entries or {}) do
    if type(e) == "table" and e.type == "commission" and e.recipeID ~= nil and type(e.quality) == "number"
      and not e.recraft then
      local key = tostring(e.recipeID) .. ":" .. tostring(e.quality)
      if not seen[key] then
        seen[key] = true
        pairsList[#pairsList + 1] = { recipeID = e.recipeID, quality = e.quality }
      end
    end
  end
  table.sort(pairsList, function(a, b)
    if a.recipeID ~= b.recipeID then return id_less(a.recipeID, b.recipeID) end
    return a.quality < b.quality
  end)
  local rows = {}
  for _, p in ipairs(pairsList) do
    local b = ledger:Benchmark(p.recipeID, p.quality)
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

-- The week row a time falls in, as Ledger:Weekly counts it (1 = the current week; newer times land there too).
local function week_index(time, current)
  if time >= current then return 1 end
  return math.ceil((current - time) / WEEK_SECONDS) + 1
end

local function copy_totals(t, extra)
  local row = { income = t.income, cost = t.cost, profit = t.profit, n = t.n, incomplete = t.incomplete, estimated = 0 }
  for k, v in pairs(extra or {}) do row[k] = v end
  return row
end

-- ledger = the Ledger module (or nil), now = server seconds -> {
--   available, count = entries, newest = newest entry time|nil, entries = Ledger:Query({}) (live, read-only),
--   weekly = { rows = { {weekStart, income, cost, profit, incomplete, estimated, index} }, total } | nil when the
--     week boundary is unknown,
--   recipes = RecipeRows with `estimated`, unattributed = totals with `estimated` | nil when there are none,
--   benchmarks = BenchmarkRows, minSamples }.
-- `estimated` counts the sales and commissions whose cost was estimated (they make the cost and profit "~").
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
      for _, key in ipairs({ "income", "cost", "profit", "incomplete" }) do
        total[key] = total[key] + count(w[key])
      end
    end
    model.weekly = { rows = rows, total = total }
  end

  model.recipes = {}
  local byID = {}
  for i, row in ipairs(Tab.RecipeRows(ledger:ByRecipe({}))) do
    row.estimated = 0
    model.recipes[i] = row
    byID[row.recipeID] = row
  end
  local unattributed = ledger:Unattributed({})
  if type(unattributed) == "table" and count(unattributed.n) > 0 then
    model.unattributed = copy_totals(unattributed, { unattributed = true })
  end

  -- Estimated costs, counted where Weekly / ByRecipe / Unattributed counted the entry.
  local current = model.weekly and model.weekly.rows[1].weekStart
  for _, e in ipairs(entries) do
    if counts_as_profit(e) and e.estimated then
      if current and type(e.time) == "number" then
        local row = model.weekly.rows[week_index(e.time, current)]
        if row then
          row.estimated = row.estimated + 1
          model.weekly.total.estimated = model.weekly.total.estimated + 1
        end
      end
      local target = e.recipeID ~= nil and byID[e.recipeID] or (e.recipeID == nil and model.unattributed) or nil
      if target then target.estimated = target.estimated + 1 end
    end
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

  add({ kind = "heading", text = ("Weekly profit (last %d reset weeks)"):format(WEEKS) })
  if model.weekly then
    local list = {}
    for i, row in ipairs(model.weekly.rows) do list[i] = row end
    list[#list + 1] = model.weekly.total
    rows("weekly", list)
  else
    add({ kind = "note", text = "Week boundary unknown: the game gave no weekly reset time" })
  end

  add({ kind = "spacer" })
  add({ kind = "heading", text = "Profit by recipe" })
  if #model.recipes > 0 or model.unattributed then
    local list = {}
    for i, row in ipairs(model.recipes) do list[i] = row end
    if model.unattributed then list[#list + 1] = model.unattributed end
    rows("recipe", list)
  else
    add({ kind = "note", text = "No sales or commissions yet: only crafts (cost records) are recorded" })
  end

  add({ kind = "spacer" })
  add({ kind = "heading", text = "Your tips by recipe and quality" })
  if #model.benchmarks > 0 then
    rows("benchmark", model.benchmarks)
  else
    add({ kind = "note", text = ("No tip history yet: %s commissions per recipe and quality are needed")
      :format(tostring(model.minSamples or "a few")) })
  end

  add({ kind = "spacer" })
  add({ kind = "heading", text = ("Entries (%d)"):format(#model.entries) })
  rows("entry", model.entries)
  return items
end

-- The recipe's name from the cached schematic, else "Recipe <id>".
local function recipe_name(recipeID)
  local scanner = module("Scanner")
  local schematic = scanner and scanner.GetSchematic and recipeID ~= nil and scanner:GetSchematic(recipeID) or nil
  if type(schematic) == "table" and type(schematic.name) == "string" then return schematic.name end
  return "Recipe " .. tostring(recipeID)
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
  if entry.orderType == "npc" then return "Patron" end
  return nil
end

local function type_label(entry)
  if entry.type == "commission" and entry.recraft then return "recraft" end
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
  return ("partial: %d without cost basis"):format(incomplete)
end

-- The display text of one data row's cells, by column key.
function Tab.CellTexts(section, data)
  data = type(data) == "table" and data or {}
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
        cells.week = ("%d weeks"):format(WEEKS)
      elseif data.index == 1 then
        cells.week = "This week"
      else
        cells.week = date_text(data.weekStart, "%m-%d")
      end
      if count(data.incomplete) > 0 then
        cells.note = color(WARN, partial_note(data.incomplete))
      elseif est then
        cells.note = color(DIM, "estimate")
      end
    else
      cells.recipe = data.unattributed and "Unattributed sales" or recipe_name(data.recipeID)
      cells.n = tostring(count(data.n))
      if count(data.incomplete) > 0 then
        cells.note = color(WARN, "partial")
      elseif est then
        cells.note = color(DIM, "estimate")
      end
    end
    return cells
  elseif section == "benchmark" then
    return {
      recipe = recipe_name(data.recipeID),
      quality = tostring(data.quality or "?"),
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
      amount = money_cell(data.amount, true, data.estimated == true),
      customer = customer_of(data) or "",
    }
  end
  return {}
end

local function full_money(copper, estimated)
  if not is_money(copper) then return "unknown" end
  return (estimated and "~" or "") .. ns.UI.FormatMoney(copper)
end

local function line(text, rgb)
  return { text = text, color = rgb or WHITE }
end

-- The income / cost / profit lines of a weekly or recipe row, with what makes them partial or estimated.
local function totals_lines(lines, data)
  local est = count(data.estimated) > 0
  lines[#lines + 1] = line("Income: " .. full_money(data.income))
  lines[#lines + 1] = line("Cost: " .. full_money(data.cost, est))
  lines[#lines + 1] = line("Profit: " .. full_money(data.profit, est))
  if count(data.incomplete) > 0 then
    lines[#lines + 1] = line("Partial: " .. data.incomplete .. " without cost basis", GOLD)
    lines[#lines + 1] = line(PARTIAL_DETAIL, GOLD)
  end
  if est then
    lines[#lines + 1] = line(("Estimate: %d with an estimated craft cost"):format(data.estimated), GREY)
  end
end

local function entry_lines(lines, e)
  lines[#lines + 1] = line(item_name(e))
  lines[#lines + 1] = line(date_text(e.time, "%Y-%m-%d %H:%M"), GREY)
  local kind = TYPE_NAMES[e.type] or tostring(e.type)
  if e.type == "commission" and e.recraft then kind = kind .. " (recraft)" end
  lines[#lines + 1] = line(kind)
  lines[#lines + 1] = line("Amount: " .. full_money(e.amount, e.type == "craft" and e.estimated == true))
  if counts_as_profit(e) then
    if e.recraft then
      lines[#lines + 1] = line("Cost: not tracked for recrafts", GREY)
    elseif is_money(e.cost) then
      lines[#lines + 1] = line("Cost: " .. full_money(e.cost, e.estimated == true))
      if e.incomplete then lines[#lines + 1] = line("Cost is partial: some reagent prices were missing", GOLD) end
    else
      lines[#lines + 1] = line("Cost: unknown (no cost basis)", GOLD)
    end
  elseif e.incomplete then
    lines[#lines + 1] = line("Cost is partial: some reagent prices were missing", GOLD)
  end
  if e.type == "commission" and e.tip ~= nil then lines[#lines + 1] = line("Tip: " .. full_money(e.tip)) end
  if e.customer ~= nil then
    lines[#lines + 1] = line("Customer: " .. tostring(e.customer))
  elseif e.buyer ~= nil then
    lines[#lines + 1] = line("Buyer: " .. tostring(e.buyer))
  elseif e.orderType == "npc" then
    lines[#lines + 1] = line("Customer: Patron (NPC order)")
  end
  if e.quality ~= nil then lines[#lines + 1] = line("Quality: " .. tostring(e.quality), GREY) end
  if type(e.quantity) == "number" and e.quantity ~= 1 then
    lines[#lines + 1] = line("Quantity: " .. tostring(e.quantity), GREY)
  end
  if e.charKey ~= nil then lines[#lines + 1] = line("Character: " .. tostring(e.charKey), GREY) end
  if e.ambiguous then lines[#lines + 1] = line("Several items share this name; no cost was matched", GREY) end
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
      lines[1] = line(("Last %d reset weeks"):format(WEEKS))
    else
      lines[1] = line("Week starting " .. date_text(data.weekStart, "%Y-%m-%d %H:%M"))
    end
    totals_lines(lines, data)
  elseif item.section == "recipe" then
    if data.unattributed then
      lines[1] = line("Unattributed sales")
      lines[2] = line("Sales whose item could not be matched to a recipe you crafted", GREY)
    else
      lines[1] = line(recipe_name(data.recipeID))
    end
    lines[#lines + 1] = line("Sales and commissions: " .. tostring(count(data.n)))
    totals_lines(lines, data)
  elseif item.section == "benchmark" then
    lines[1] = line(("%s (quality %s)"):format(recipe_name(data.recipeID), tostring(data.quality)))
    lines[2] = line("Median tip: " .. full_money(data.median))
    lines[3] = line("A quarter of your tips were below " .. full_money(data.p25))
    lines[4] = line("A quarter of your tips were above " .. full_money(data.p75))
    lines[5] = line(("From %d of your commissions (recrafts not counted)"):format(count(data.n)), GREY)
  elseif item.section == "entry" then
    entry_lines(lines, data)
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
    if item.section == "entry" then request_item(item.data.itemID) end
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

local function status_text(ledger)
  if ns.FS.dbIsNewer then return color(BAD, READ_ONLY_NOTICE) end
  if ledger and ledger.IsEnabled and not ledger:IsEnabled() then return color(WARN, OFF_NOTICE) end
  return ""
end

local function empty_text(ledger)
  if not ledger then return "The Ledger is not available." end
  return "No sales recorded yet. Commissions from the crafting orders you fulfil and the auction sales you collect "
    .. "from the mailbox show here; crafts are kept as their cost."
end

local function refresh()
  if not view then return end
  local now = ns.FS:Now()
  local ledger = module("Ledger")
  local model = Tab.Model(ledger, now)
  view.model = model
  view.items = Tab.DisplayRows(model)

  if model.count == 0 then
    view.header:SetText("No entries yet")
  else
    local header = ("%d entries"):format(model.count)
    if model.newest then header = header .. ", newest " .. ns.UI.FormatAge(now - model.newest) .. " ago" end
    view.header:SetText(header)
  end
  view.status:SetText(status_text(ledger))
  if #view.items == 0 then
    view.empty:SetText(color(DIM, empty_text(ledger)))
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
-- Build
---------------------------------------------------------------------------

local function build(container)
  local created = { container = container, items = {}, pool = {}, shown = 0, layouts = {}, layoutKeys = {} }

  local bar = CreateFrame("Frame", nil, container)
  bar:SetPoint("TOPLEFT", container, "TOPLEFT", PAD, 0)
  bar:SetPoint("TOPRIGHT", container, "TOPRIGHT", -PAD, 0)
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
    local detail = ns.FS.dbIsNewer and READ_ONLY_DETAIL or OFF_DETAIL
    show_lines(self, { line(text), line(detail, GREY) })
  end))
  created.statusArea:SetScript("OnLeave", hide_tooltip)

  local scrollTop = BAR_HEIGHT + 2
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
      label = "Ledger", icon = "Interface\\Icons\\INV_Misc_Coin_02", order = 60, phase = 2,
      build = build,
      refresh = refresh,
    })
  end
end

function LedgerTab:OnEnable()
  -- One refresh follows REFRESH_DELAY after the last change of a burst; MainWindow only refreshes a selected,
  -- visible tab.
  self:RegisterMessage(ns.Msg.LEDGER_CHANGED, ns.FS:Wrap(REFRESH_SOURCE, schedule_refresh))
  self:RegisterEvent("GET_ITEM_INFO_RECEIVED", ns.FS:Wrap(REFRESH_SOURCE, on_item_info))
end

function LedgerTab:OnDisable()
  self:UnregisterAllMessages()
  self:UnregisterAllEvents()
  ns.FS:CancelDebounce(REFRESH_KEY)
end
