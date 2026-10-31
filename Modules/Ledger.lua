local ADDON_NAME, ns = ...

-- Ledger: what the player earned and spent crafting. db.global.ledger = { entries = { LedgerEntry }, costBasis, nameIndex }
-- (entries is a 1a default; costBasis and nameIndex belong to the capture code and are created when first used).
-- LedgerEntry = { time, type = "craft"|"sale"|"commission", amount (integer copper, negative for craft), charKey,
-- recipeID?, quality?, quantity?, cost?, incomplete?, customer?, tip?, recraft?, ... }.
--
-- Profit counts "sale" and "commission" entries only: income = amount, cost = the entry's cost. "craft" entries are
-- cost-basis records and are left out (counting them would charge a cost twice). An entry whose cost is unknown keeps
-- cost = nil in the saved data; in a sum it adds nothing to cost but is counted in `incomplete`, as is an entry
-- flagged incomplete (a cost made from partly missing prices). So a profit with incomplete > 0 is partial: the real
-- cost is higher, so the real profit may be lower than shown. NPC reward values are shown elsewhere and are never
-- gold income here.
-- Nothing is written while the saved data is from a newer version (ns.FS.dbIsNewer); saved rows are never wiped
-- (a damaged row is skipped when reading, and kept when pruning).
local Ledger = ns.FS:NewModule("Ledger", "AceEvent-3.0")

Ledger.SETTINGS_DEFAULTS = { benchmarkMinSamples = 3, keepDays = 365 }
Ledger.TYPES = { craft = true, sale = true, commission = true }

local WEEK_SECONDS = 604800
local DAY_SECONDS = 86400
local DEFAULT_WEEKS = 4

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function global()
  return ns.FS.db and ns.FS.db.global
end

local function writable()
  return global() ~= nil and not ns.FS.dbIsNewer
end

local function number_or(v, default)
  if type(v) == "number" then return v end
  return default
end

-- A finite whole number (money is integer copper).
local function is_integer(v)
  return type(v) == "number" and v == math.floor(v) and v ~= math.huge and v ~= -math.huge
end

local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copy(x) end
  return out
end

-- Fills every default `target` is missing (or holds with the wrong type), keeping what it has.
local function fill(target, defaults)
  for k, v in pairs(defaults) do
    if type(target[k]) ~= type(v) or (type(v) == "number" and target[k] ~= target[k]) then target[k] = v end
  end
  return target
end

local settingsTable = ns.Util.SettingsAccessor("ledger")  -- a session-only copy while the saved data is read-only

-- The saved entries list for reads (nil when there is none; nothing is created).
local function entries_view()
  local g = global()
  local ledger = g and g.ledger
  local list = type(ledger) == "table" and ledger.entries
  if type(list) == "table" then return list end
end

-- The saved entries that are tables, in order, skipping holes and damaged rows (for reads).
local function each_saved()
  local list = entries_view() or {}
  local last = 0
  for key in pairs(list) do
    if type(key) == "number" and key > last then last = key end
  end
  local out = {}
  for i = 1, last do
    if type(list[i]) == "table" then out[#out + 1] = { entry = list[i], index = i } end
  end
  return out
end

-- The saved entries list for writes (created when missing). Nil while the saved data is read-only.
local function entries_store()
  if not writable() then return nil end
  local g = global()
  if type(g.ledger) ~= "table" then g.ledger = {} end
  if type(g.ledger.entries) ~= "table" then g.ledger.entries = {} end
  return g.ledger.entries
end

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

-- The ledger settings table with defaults filled in: db.global.settings.ledger (created on first use). While the
-- saved data is missing or read-only it is a session-only copy, so callers can always read and set it.
function Ledger:Settings()
  return settingsTable(self.SETTINGS_DEFAULTS, fill)
end

---------------------------------------------------------------------------
-- Add / Query / Prune
---------------------------------------------------------------------------

-- Stores one LedgerEntry (a copy; `time` defaults to now, `charKey` to this character) and sends FS_LEDGER_CHANGED.
-- Raises an error only for a `type` other than craft|sale|commission or an `amount` that is not an integer. A bad
-- optional field never loses the entry: a `cost` that is not an integer is stored as nil with `incomplete = true`, a
-- bad `tip` is stored as nil, a bad `time` becomes now; each is logged once (ns.FS:LogError "Ledger:Add").
-- An unknown cost stays nil. Returns the stored entry, or nil while the saved data is read-only (nothing is
-- written or sent).
function Ledger:Add(entry)
  if type(entry) ~= "table" then error("Ledger:Add: entry must be a table", 2) end
  if not Ledger.TYPES[entry.type] then error("Ledger:Add: bad type " .. tostring(entry.type), 2) end
  if not is_integer(entry.amount) then error("Ledger:Add: amount must be an integer, got " .. tostring(entry.amount), 2) end

  local list = entries_store()
  if not list then return nil end
  local stored = {}
  for k, v in pairs(entry) do stored[k] = v end
  if stored.cost ~= nil and not is_integer(stored.cost) then
    ns.FS:LogError("Ledger:Add", "cost is not an integer (" .. tostring(stored.cost) .. "); stored as unknown")
    stored.cost = nil
    stored.incomplete = true
  end
  if stored.tip ~= nil and not is_integer(stored.tip) then
    ns.FS:LogError("Ledger:Add", "tip is not an integer (" .. tostring(stored.tip) .. "); stored as unknown")
    stored.tip = nil
  end
  if stored.time ~= nil and not (type(stored.time) == "number" and stored.time == stored.time) then
    ns.FS:LogError("Ledger:Add", "time is not a number (" .. tostring(stored.time) .. "); used now")
    stored.time = nil
  end
  if stored.time == nil then stored.time = ns.FS:Now() end
  if stored.charKey == nil then stored.charKey = ns.FS:CharKey() end
  list[#list + 1] = stored
  self:SendMessage(ns.Msg.LEDGER_CHANGED)
  return stored
end

local function matches(entry, filter)
  if filter.type ~= nil and entry.type ~= filter.type then return false end
  if filter.recipeID ~= nil and entry.recipeID ~= filter.recipeID then return false end
  if filter.charKey ~= nil and entry.charKey ~= filter.charKey then return false end
  if filter.customer ~= nil and entry.customer ~= filter.customer then return false end
  local time = number_or(entry.time, 0)
  if filter.since ~= nil and time < filter.since then return false end
  if filter.before ~= nil and time >= filter.before then return false end
  return true
end

-- The entries that match `filter = {type?, since?, before?, recipeID?, charKey?, customer?}`, newest first
-- (`since` is inclusive, `before` exclusive; entries with the same time come newest-added first). These are the
-- saved entries themselves, so treat them as read-only. Damaged saved rows are skipped.
function Ledger:Query(filter)
  filter = type(filter) == "table" and filter or {}
  local found = {}
  for _, saved in ipairs(each_saved()) do
    local entry = saved.entry
    if matches(entry, filter) then
      found[#found + 1] = { entry = entry, index = saved.index, time = number_or(entry.time, 0) }
    end
  end
  table.sort(found, function(a, b)
    if a.time ~= b.time then return a.time > b.time end
    return a.index > b.index
  end)
  local out = {}
  for i, item in ipairs(found) do out[i] = item.entry end
  return out
end

-- Removes entries older than the keepDays setting. A row with no usable time is kept. Sends FS_LEDGER_CHANGED
-- when something was removed. Does nothing while the saved data is read-only.
function Ledger:Prune(now)
  local list = entries_store()
  if not list then return 0 end
  now = number_or(now, ns.FS:Now())
  local cutoff = now - math.max(0, self:Settings().keepDays) * DAY_SECONDS
  local kept, removed, last = {}, 0, 0
  for key in pairs(list) do
    if type(key) == "number" and key > last then last = key end
  end
  for i = 1, last do  -- a hole in the saved list must not hide the rows after it
    local entry = list[i]
    if entry ~= nil then
      if type(entry) == "table" and type(entry.time) == "number" and entry.time < cutoff then
        removed = removed + 1
      else
        kept[#kept + 1] = entry
      end
    end
  end
  if removed == 0 then return 0 end
  for i = 1, last do list[i] = kept[i] end
  self:SendMessage(ns.Msg.LEDGER_CHANGED)
  return removed
end

---------------------------------------------------------------------------
-- Weekly and per-recipe profit
---------------------------------------------------------------------------

-- Start of the weekly-reset week that contains `now`: now + seconds until the reset - one week. `now` must be the
-- current time (default: now); the game only tells the time until the next reset, so for a past `now` the result is
-- not a reset boundary. Nil when the game gives no reset time (the week boundary is then unknown, not guessed).
function Ledger:WeekStart(now)
  now = number_or(now, ns.FS:Now())
  local api = C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset
  if type(api) ~= "function" then return nil end
  local ok, seconds = pcall(api)
  if not ok or type(seconds) ~= "number" then return nil end
  return now + seconds - WEEK_SECONDS
end

local function new_totals()
  return { income = 0, cost = 0, profit = 0, n = 0, incomplete = 0 }
end

-- Adds a sale or commission to a running total (see the profit rule at the top of this file). A damaged saved
-- entry (amount or cost not an integer) adds nothing for the damaged part but counts in `incomplete`. An entry whose
-- cost was estimated counts in `estimated` (left nil while there are none).
local function accumulate(totals, entry)
  local income, cost = entry.amount, entry.cost
  local damaged = false
  if not is_integer(income) then income = 0; damaged = true end
  if cost ~= nil and not is_integer(cost) then cost = nil; damaged = true end
  totals.income = totals.income + income
  totals.cost = totals.cost + (cost or 0)
  totals.profit = totals.income - totals.cost
  if totals.n then totals.n = totals.n + 1 end
  if damaged or cost == nil or entry.incomplete then totals.incomplete = totals.incomplete + 1 end
  if entry.estimated then totals.estimated = (totals.estimated or 0) + 1 end
end

local function counts_as_profit(entry)
  return entry.type == "sale" or entry.type == "commission"
end

-- Weekly profit for the last `weeks` reset weeks (default 4), newest first: a row for every week, empty ones
-- included: { weekStart, income, cost, profit, incomplete, estimated? }. `incomplete` is how many of that week's
-- entries had no known (or a partial) cost, so a non-zero value means the profit is partial; `estimated` (nil when
-- none) is how many had an estimated cost, so the cost and profit are estimates. An entry newer than the current
-- week's start lands in the current week; an older one than the window is left out. Empty when the week boundary is
-- unknown.
function Ledger:Weekly(now, weeks)
  now = number_or(now, ns.FS:Now())
  weeks = math.max(1, math.floor(number_or(weeks, DEFAULT_WEEKS)))
  local current = self:WeekStart(now)
  if not current then return {} end
  local rows = {}
  for i = 1, weeks do
    rows[i] = { weekStart = current - (i - 1) * WEEK_SECONDS, income = 0, cost = 0, profit = 0, incomplete = 0 }
  end
  for _, saved in ipairs(each_saved()) do
    local entry = saved.entry
    if type(entry.time) == "number" and counts_as_profit(entry) then
      local back = entry.time >= current and 0 or math.ceil((current - entry.time) / WEEK_SECONDS)
      local row = rows[back + 1]
      if row then accumulate(row, entry) end
    end
  end
  return rows
end

-- Profit per recipe over the entries that match `filter` (same filter as Query): { [recipeID] = {income, cost,
-- profit, n, incomplete, estimated?} } (incomplete and estimated as in Weekly). Entries with no recipeID cannot be
-- attributed; Ledger:Unattributed adds them up.
function Ledger:ByRecipe(filter)
  local result = {}
  for _, entry in ipairs(self:Query(filter)) do
    if counts_as_profit(entry) and entry.recipeID ~= nil then
      local totals = result[entry.recipeID]
      if not totals then totals = new_totals(); result[entry.recipeID] = totals end
      accumulate(totals, entry)
    end
  end
  return result
end

-- The same totals for the matching sales and commissions that have no recipeID (e.g. a mail sale whose item could
-- not be matched to a recipe).
function Ledger:Unattributed(filter)
  local totals = new_totals()
  for _, entry in ipairs(self:Query(filter)) do
    if counts_as_profit(entry) and entry.recipeID == nil then accumulate(totals, entry) end
  end
  return totals
end

---------------------------------------------------------------------------
-- Benchmarks
---------------------------------------------------------------------------

-- Percentile p (0..1) of an ascending list: linear interpolation at h = (n - 1) * p + 1, rounded to an integer
-- (half up). Nil for an empty list.
function Ledger.Percentile(sorted, p)
  local n = type(sorted) == "table" and #sorted or 0
  if n == 0 then return nil end
  p = math.min(1, math.max(0, number_or(p, 0)))
  local h = (n - 1) * p + 1
  local lo = math.floor(h)
  local hi = math.min(n, lo + 1)
  return math.floor(sorted[lo] + (h - lo) * (sorted[hi] - sorted[lo]) + 0.5)
end

-- What this recipe's commissions have tipped: { median, p25, p75, n } of the gross `tip` of the player's
-- commission entries for the recipe (`quality` nil = all qualities; otherwise the delivered (crafted) quality stored
-- on the commission, which callers derive with ns.UI.OrdersPanel.BenchmarkQuality). Entries with no known (or a negative) tip are
-- not samples, and neither are recraft commissions (recraft = true: a recraft is not the fresh craft benchmarked).
-- Nil when there are fewer than the benchmarkMinSamples setting.
function Ledger:Benchmark(recipeID, quality)
  local tips = {}
  for _, saved in ipairs(each_saved()) do
    local entry = saved.entry
    if entry.type == "commission" and entry.recipeID == recipeID and not entry.recraft
      and (quality == nil or entry.quality == quality) and is_integer(entry.tip) and entry.tip >= 0 then
      tips[#tips + 1] = entry.tip
    end
  end
  if #tips == 0 or #tips < self:Settings().benchmarkMinSamples then return nil end
  table.sort(tips)
  return {
    median = Ledger.Percentile(tips, 0.5), p25 = Ledger.Percentile(tips, 0.25), p75 = Ledger.Percentile(tips, 0.75),
    n = #tips,
  }
end

---------------------------------------------------------------------------
-- Capture: craft cost basis, order commissions, AH sale mail
---------------------------------------------------------------------------
-- Crafts: the post-hook on C_TradeSkillUI.CraftRecipe remembers what is being crafted; each
-- TRADE_SKILL_ITEM_CRAFTED_RESULT then records a "craft" entry (amount = -cost). A craft for no order also feeds
-- costBasis[itemID] = {totalCost, totalQty, recipeID} and nameIndex[itemName] = {itemID, ambiguous}, which price the
-- AH sales read from mail later.
-- Ruling P3: recrafts and enchants on existing items are not tracked by the Ledger in phase 2. They do not go
-- through CraftRecipe (Blizzard calls RecraftRecipe, RecraftRecipeForOrder or CraftEnchant), so their hooks only
-- drop the pending craft (a result after them is not charged to an earlier, unfinished multi-cast craft), an
-- enchant result (data.isEnchant) is ignored, and a recraft order records no craft. Its commission is real gold, so
-- it is recorded with recraft = true and cost = nil (counted in `incomplete`, left out of Benchmark). A recraft order
-- is known from FulfilledOrder.isRecraft, else from the RecraftRecipeForOrder hook or the claimed order (session).
-- Salvage is no fresh craft either and is handled the same way.
-- An interrupted cast (the player's UNIT_SPELLCAST_INTERRUPTED for the pending recipe) drops the pending craft: the
-- rest of a multi-cast craft never comes.
-- Every amount is rounded to whole copper here (Ledger:Add raises for anything else); a cost that is not a finite
-- number is skipped and logged once, so a hook never turns the Ledger off.

local pendingCraft      -- { recipeID, craftingReagents, orderID, provided, castsLeft } from the last CraftRecipe
local lastCraft         -- { operationID, entry, fedBasis, itemID }: the last recorded craft (kept after pendingCraft)
local untrackedOrders = {}  -- [orderID] = true: recraft orders (Ruling P3), for this session
local skippedOrderCrafts = {}  -- [orderID] = true: an order craft whose cost could not be recorded (session)
local seenMail = {}         -- [signature] = true: mail money already recorded this session
local loggedOnce = {}

local DEFAULT_SOLD_SUBJECT = "Auction successful: %s"

local function log_once(key, text)
  if loggedOnce[key] then return end
  loggedOnce[key] = true
  ns.FS:LogError("Ledger:Capture", text)
end

-- Whole copper (half up), or nil for anything that is not a finite number.
local function to_copper(x)
  if type(x) ~= "number" or x ~= x or x == math.huge or x == -math.huge then return nil end
  return math.floor(x + 0.5)
end

-- db.global.ledger[key] for reads (nil when missing; nothing is created).
local function store_view(key)
  local g = global()
  local ledger = g and g.ledger
  local t = type(ledger) == "table" and ledger[key]
  if type(t) == "table" then return t end
end

-- db.global.ledger[key] for writes (created when missing). Nil while the saved data is read-only.
local function store_for_write(key)
  if not writable() then return nil end
  local g = global()
  if type(g.ledger) ~= "table" then g.ledger = {} end
  if type(g.ledger[key]) ~= "table" then g.ledger[key] = {} end
  return g.ledger[key]
end

local function price_of(itemID)
  local prices = ns.FS:GetModule("Prices", true)
  if not prices or type(itemID) ~= "number" then return nil end
  local result = prices:Get(itemID)
  local value = type(result) == "table" and result.value or nil
  if type(value) == "number" and value == value and value >= 0 then return value end
end

local function modified_reagent_type()
  local types = Enum and Enum.TradeskillSlotDataType
  return type(types) == "table" and types.ModifiedReagent or 2
end

-- The item text of a link or invoice name: atlas (quality icon) and colour markup removed, spaces trimmed.
local function clean_name(text)
  if type(text) ~= "string" then return nil end
  text = text:gsub("|A.-|a", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cn[^:]*:", ""):gsub("|r", "")
  text = text:match("^%s*(.-)%s*$")
  if text ~= "" then return text end
end

-- The item name inside a link's [...], without the quality icon. Nil when there is none.
function Ledger.ItemNameFromLink(link)
  if type(link) ~= "string" then return nil end
  return clean_name(link:match("|h%[(.-)%]|h") or link:match("%[(.-)%]"))
end

-- The itemID last crafted (for no order) under this name, and whether more than one itemID was crafted under it
-- (quality ranks of one item have different IDs but the same name). Nil when the name is unknown.
function Ledger:ResolveItemName(name)
  local index = store_view("nameIndex")
  local found = index and type(name) == "string" and index[name]
  if type(found) ~= "table" or found.itemID == nil then return nil end
  return found.itemID, found.ambiguous == true
end

local function reagent_item(r)
  local reagent = type(r) == "table" and r.reagent
  local itemID = type(reagent) == "table" and reagent.itemID or nil
  if type(itemID) == "number" then return itemID end
end

-- What one craft cost: cost (whole copper, nil when not a finite number), incomplete, estimated.
-- craftingReagents = { {reagent = {itemID?, currencyID?}, dataSlotIndex, quantity} } (ModifiedReagent slots only),
-- provided = { [itemID] = n } customer-provided items (free), returned = { {reagent = {itemID?}, quantity} }.
-- Each schematic slot uses the entries with its dataSlotIndex. A required slot with none is a fixed reagent
-- (lowest rank × quantity, exact) or a ModifiedReagent slot (same, but estimated), unless the customer provided it:
-- Blizzard leaves customer-provided slots out of an order's craftingReagents. Optional slots with no entry and
-- currency costs add nothing. A provided item is free once (max(0, used - provided)). Returned reagents are
-- subtracted at their price. An item with no price makes the cost incomplete (the cost then sums the priced
-- items only); so does a missing schematic (fixed reagents are then unknown).
function Ledger:CostOfCraft(recipeID, craftingReagents, provided, returned)
  local remaining = {}
  if type(provided) == "table" then
    for itemID, n in pairs(provided) do
      if type(n) == "number" and n > 0 then remaining[itemID] = n end
    end
  end
  local cost, incomplete, estimated = 0, false, false

  -- Charges the part of `quantity` not covered by provided items.
  local function charge(itemID, quantity)
    if type(itemID) ~= "number" or type(quantity) ~= "number" or quantity <= 0 then return end
    local free = math.min(quantity, remaining[itemID] or 0)
    if free > 0 then remaining[itemID] = remaining[itemID] - free end
    local paid = quantity - free
    if paid <= 0 then return end
    local price = price_of(itemID)
    if price == nil then incomplete = true else cost = cost + price * paid end
  end

  local entries = type(craftingReagents) == "table" and craftingReagents or {}
  local scanner = ns.FS:GetModule("Scanner", true)
  local schematic = scanner and type(recipeID) == "number" and scanner:GetSchematic(recipeID) or nil
  local slots = type(schematic) == "table" and type(schematic.reagentSlots) == "table" and schematic.reagentSlots
  local used = {}  -- [entry index] = true once charged through a slot
  if not slots then incomplete = true; slots = {} end
  local modified = modified_reagent_type()
  for _, slot in ipairs(slots) do
    local items = type(slot) == "table" and type(slot.reagents) == "table" and slot.reagents or {}
    if type(slot) == "table" and not (slot.currencyID ~= nil and #items == 0) then
      local found = false
      for i, r in ipairs(entries) do
        if type(r) == "table" and r.dataSlotIndex ~= nil and r.dataSlotIndex == slot.dataSlotIndex then
          found, used[i] = true, true
          charge(reagent_item(r), r.quantity)
        end
      end
      if not found and slot.required and type(items[1]) == "number" then
        local quantity = number_or(slot.quantity, 0)
        local covered = 0   -- customer-provided items of this slot, any rank
        for _, itemID in ipairs(items) do
          local free = math.min(quantity - covered, remaining[itemID] or 0)
          if free > 0 then remaining[itemID] = remaining[itemID] - free; covered = covered + free end
        end
        if quantity - covered > 0 then
          charge(items[1], quantity - covered)
          if slot.dataSlotType == modified then estimated = true end
        end
      end
    end
  end
  for i, r in ipairs(entries) do  -- entries the schematic does not know (or no schematic) were still used
    if not used[i] then charge(reagent_item(r), type(r) == "table" and r.quantity or nil) end
  end

  if type(returned) == "table" then
    for _, r in ipairs(returned) do
      local itemID, quantity = reagent_item(r), type(r) == "table" and r.quantity or nil
      if itemID and type(quantity) == "number" and quantity > 0 then
        local price = price_of(itemID)
        if price == nil then incomplete = true else cost = cost - price * quantity end
      end
    end
  end
  local copper = to_copper(cost)  -- checked before clamping: math.max(0, NaN) would give 0
  if copper and copper < 0 then copper = 0 end
  return copper, incomplete, estimated
end

-- Post-hook on C_TradeSkillUI.CraftRecipe (Blizzard's UI and Queue:CraftNext alike): remembers the craft until its
-- results arrive. The claimed order's customer-provided reagents are free; a recraft order is not tracked (P3).
function Ledger:OnCraftRecipe(recipeID, numCasts, craftingReagents, _recipeLevel, orderID, _applyConcentration)
  pendingCraft = nil
  if type(recipeID) ~= "number" then return end
  local provided = {}
  if orderID ~= nil then
    if untrackedOrders[orderID] then return end
    local orders = ns.FS:GetModule("Orders", true)
    local ok, claimed = pcall(function() return orders and orders:GetClaimedOrder() end)
    if ok and type(claimed) == "table" and claimed.orderID == orderID then
      if claimed.isRecraft then untrackedOrders[orderID] = true; return end
      if type(claimed.provided) == "table" then provided = copy(claimed.provided) end
    end
  end
  local casts = math.max(1, math.floor(number_or(numCasts, 1)))
  pendingCraft = {
    recipeID = recipeID, craftingReagents = copy(type(craftingReagents) == "table" and craftingReagents or {}),
    orderID = orderID, provided = provided, castsLeft = casts,
  }
end

-- Post-hook on RecraftRecipe / RecraftRecipeForOrder(orderID) / CraftEnchant / CraftSalvage (Ruling P3): what
-- follows is not the pending craft, and a recraft order's commission is not recorded.
function Ledger:OnUntrackedCraft(orderID)
  pendingCraft = nil
  if orderID ~= nil then untrackedOrders[orderID] = true end
end

local function add_cost_basis(itemID, cost, quantity, recipeID)
  local basis = store_for_write("costBasis")
  if not basis then return false end
  local row = basis[itemID]
  if type(row) ~= "table" or type(row.totalCost) ~= "number" or type(row.totalQty) ~= "number" then
    row = { totalCost = 0, totalQty = 0 }
    basis[itemID] = row
  end
  row.totalCost = row.totalCost + cost
  row.totalQty = row.totalQty + quantity
  row.recipeID = recipeID
  return true
end

local function index_name(name, itemID)
  local index = name and store_for_write("nameIndex")
  if not index then return end
  local old = index[name]
  local ambiguous = type(old) == "table" and (old.ambiguous == true or (old.itemID ~= nil and old.itemID ~= itemID))
  index[name] = { itemID = itemID, ambiguous = ambiguous or false }
end

-- A multicraft extra (same operationID as the last recorded craft): more items, no new cost, no cast used.
local function add_extra(self, quantity)
  if type(quantity) ~= "number" or quantity <= 0 or not writable() then return end
  local entry = lastCraft.entry
  entry.quantity = number_or(entry.quantity, 0) + quantity
  if lastCraft.fedBasis then
    local basis = store_view("costBasis")
    local row = basis and basis[lastCraft.itemID]
    if type(row) == "table" and type(row.totalQty) == "number" then row.totalQty = row.totalQty + quantity end
  end
  self:SendMessage(ns.Msg.LEDGER_CHANGED)
end

-- TRADE_SKILL_ITEM_CRAFTED_RESULT(data): records one cast of the pending craft as a "craft" entry.
function Ledger:OnCraftResult(_, data)
  if type(data) ~= "table" or data.isEnchant then return end  -- Ruling P3: enchants are not tracked
  local operationID = data.operationID
  if operationID == 0 then operationID = nil end
  if operationID ~= nil and lastCraft and lastCraft.operationID == operationID then
    add_extra(self, data.quantity)
    return
  end
  local craft = pendingCraft
  if not craft then return end
  craft.castsLeft = craft.castsLeft - 1
  if craft.castsLeft <= 0 then pendingCraft = nil end

  local cost, incomplete, estimated =
    self:CostOfCraft(craft.recipeID, craft.craftingReagents, craft.provided, data.resourcesReturned)
  if cost == nil then
    if craft.orderID ~= nil then skippedOrderCrafts[craft.orderID] = true end
    log_once("craftCost", "craft cost of recipe " .. tostring(craft.recipeID) .. " is not a number; craft not recorded")
    return
  end
  local stored = self:Add({
    type = "craft", amount = 0 - cost, itemID = data.itemID, quantity = data.quantity, quality = data.craftingQuality,
    recipeID = craft.recipeID, ref = craft.orderID, operationID = operationID,
    incomplete = incomplete or nil, estimated = estimated or nil,
  })
  if not stored then return end
  store_for_write("costBasis"); store_for_write("nameIndex")  -- created with the first craft, even an order's
  local fedBasis = false
  local quantity = data.quantity
  if craft.orderID == nil and not incomplete and type(data.itemID) == "number"
    and type(quantity) == "number" and quantity > 0 then
    fedBasis = add_cost_basis(data.itemID, cost, quantity, craft.recipeID)
    index_name(Ledger.ItemNameFromLink(data.hyperlink), data.itemID)
  end
  lastCraft = operationID ~= nil
    and { operationID = operationID, entry = stored, fedBasis = fedBasis, itemID = data.itemID } or nil
end

-- The player's UNIT_SPELLCAST_INTERRUPTED(unit, castGUID, spellID): an interrupted cast of the pending recipe (or of
-- an unnamed spell) drops the pending craft. Recipe IDs are the craft spells' IDs.
function Ledger:OnSpellcastInterrupted(_, unit, _, spellID)
  if not pendingCraft or unit ~= "player" then return end
  if spellID == nil or spellID == pendingCraft.recipeID then pendingCraft = nil end
end

-- ns.Msg.ORDER_FULFILLED(fulfilled): records the commission. Its cost is what this order's craft entries cost
-- (nil when there are none); an incomplete, estimated or unrecorded (skipped) craft makes the commission
-- incomplete or estimated too, even with a partial cost. A recraft order's commission has recraft = true and no cost.
function Ledger:OnOrderFulfilled(_, fulfilled)
  if type(fulfilled) ~= "table" then return end
  local orderID = fulfilled.orderID
  local recraft = fulfilled.isRecraft == true or (orderID ~= nil and untrackedOrders[orderID] == true)
  local amount = to_copper(fulfilled.commission)
  if amount == nil then
    log_once("commission", "commission of order " .. tostring(orderID) .. " is unknown; not recorded")
    return
  end
  local cost, incomplete, estimated = nil, false, false
  if orderID ~= nil and not recraft then
    incomplete = skippedOrderCrafts[orderID] == true
    for _, entry in ipairs(self:Query({ type = "craft" })) do
      if entry.ref == orderID and is_integer(entry.amount) then
        cost = (cost or 0) - entry.amount
        incomplete = incomplete or entry.incomplete == true
        estimated = estimated or entry.estimated == true
      end
    end
  end
  self:Add({
    type = "commission", amount = amount, tip = fulfilled.tip, recipeID = fulfilled.recipeID,
    itemID = fulfilled.itemID, quality = fulfilled.quality, customer = fulfilled.customer,
    orderType = fulfilled.orderType, ref = orderID, rewardsValue = fulfilled.rewardsValue, cost = cost,
    incomplete = incomplete or nil, estimated = estimated or nil, recraft = recraft or nil, time = fulfilled.time,
    charKey = fulfilled.charKey,
  })
end

-- Lua pattern for the sold-mail subject (AUCTION_SOLD_MAIL_SUBJECT, English fallback), capturing the item text.
local function sold_subject_pattern()
  local format = AUCTION_SOLD_MAIL_SUBJECT
  if type(format) ~= "string" or not format:find("%%%d?%$?s") then format = DEFAULT_SOLD_SUBJECT end
  local pattern = format:gsub("%%%d?%$?s", "\0", 1):gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"):gsub("%z", "(.+)")
  return "^" .. pattern .. "$"
end

-- Item name and quantity from a sold-mail subject ("Potion of Foo" or "Potion of Foo (5)"), or nil.
local function parse_sold_subject(subject)
  if type(subject) ~= "string" then return nil end
  local text = subject:match(sold_subject_pattern())
  if not text then return nil end
  local name, count = text:match("^(.-)%s*%((%d+)%)$")
  if name and name ~= "" then return clean_name(name), tonumber(count) end
  return clean_name(text), 1
end

-- Post-hook on TakeInboxMoney(index) and AutoLootMailItem(index): records an AH sale ("sale" entry) from the mail's
-- seller invoice, or, without an invoice, from its "Auction successful" subject. Mail with no money left (already
-- taken, or none) and mail already recorded this session (same signature) are skipped.
function Ledger:OnTakeMoney(index)
  local _, _, _, subject, money, _, daysLeft = GetInboxHeaderInfo(index)
  if type(money) ~= "number" or money <= 0 then return end
  local invoiceType, itemName, playerName, bid, _, deposit, consignment, _, _, _, count = GetInboxInvoiceInfo(index)
  local sale
  if invoiceType ~= nil then
    if invoiceType ~= "seller" then return end
    local amount = type(bid) == "number" and to_copper(bid - number_or(consignment, 0)) or to_copper(money)
    sale = {
      source = "invoice", itemName = clean_name(itemName), quantity = type(count) == "number" and count or 1,
      amount = amount, buyer = playerName, deposit = type(deposit) == "number" and deposit or nil,
    }
  else
    local name, quantity = parse_sold_subject(subject)
    if not name then return end
    sale = { source = "subject", itemName = name, quantity = quantity, amount = to_copper(money) }
  end
  if sale.amount == nil then return end

  local minutes = type(daysLeft) == "number" and math.floor(daysLeft * 1440) or nil
  local signature = table.concat({ tostring(itemName or sale.itemName), tostring(bid or money), tostring(count),
    tostring(playerName), tostring(minutes) }, "|")
  if seenMail[signature] then return end
  seenMail[signature] = true

  local itemID, ambiguous = self:ResolveItemName(sale.itemName)
  local basis = store_view("costBasis")
  local row = itemID and basis and basis[itemID]
  if type(row) == "table" then
    sale.recipeID = row.recipeID
    if not ambiguous and type(row.totalCost) == "number" and type(row.totalQty) == "number" and row.totalQty > 0 then
      sale.cost = to_copper(row.totalCost / row.totalQty * sale.quantity)
    end
  end
  sale.type, sale.itemID, sale.ambiguous = "sale", itemID, ambiguous or nil
  self:Add(sale)
end

function Ledger:OnEnable()
  local function wrap(fn) return ns.FS:Wrap("Ledger", fn) end
  wrap(function() self:Prune(ns.FS:Now()) end)()
  self:RegisterEvent("TRADE_SKILL_ITEM_CRAFTED_RESULT", wrap(function(event, data) self:OnCraftResult(event, data) end))
  self:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED", wrap(function(...) self:OnSpellcastInterrupted(...) end))
  self:RegisterMessage(ns.Msg.ORDER_FULFILLED, wrap(function(message, fulfilled)
    self:OnOrderFulfilled(message, fulfilled)
  end))

  -- hooksecurefunc cannot be undone: install once per session; the bodies do nothing while the Ledger is off.
  if self.hooked then return end
  self.hooked = true
  local function body(fn)
    return wrap(function(...)
      if self:IsEnabled() then fn(...) end
    end)
  end
  local function hook(tbl, name, fn)  -- optional targets: skipped when the client does not have them
    if type(tbl) == "table" and type(tbl[name]) == "function" then hooksecurefunc(tbl, name, body(fn)) end
  end
  local function hook_global(name, fn)
    if type(_G[name]) == "function" then hooksecurefunc(name, body(fn)) end
  end
  wrap(function()
    -- A post-hook only: FabricationStation calls CraftRecipe nowhere but Queue:CraftNext (tests/queue/craft_spec.lua
    -- allows exactly this line).
    hook(C_TradeSkillUI, "CraftRecipe", function(...) self:OnCraftRecipe(...) end)
    hook(C_TradeSkillUI, "RecraftRecipe", function() self:OnUntrackedCraft() end)
    hook(C_TradeSkillUI, "RecraftRecipeForOrder", function(orderID) self:OnUntrackedCraft(orderID) end)
    hook(C_TradeSkillUI, "CraftEnchant", function() self:OnUntrackedCraft() end)
    hook(C_TradeSkillUI, "CraftSalvage", function() self:OnUntrackedCraft() end)
    hook_global("TakeInboxMoney", function(index) self:OnTakeMoney(index) end)
    hook_global("AutoLootMailItem", function(index) self:OnTakeMoney(index) end)
  end)()
end

-- Hooks stay installed (their bodies return early); a pending craft is dropped.
function Ledger:OnDisable()
  pendingCraft = nil
  lastCraft = nil
end
