local ADDON_NAME, ns = ...

-- Ledger: what the player earned and spent crafting. db.global.ledger = { entries = { LedgerEntry }, costBasis, nameIndex }
-- (entries is a 1a default; costBasis and nameIndex belong to the capture code and are created when first used).
-- LedgerEntry = { time, type = "craft"|"sale"|"commission", amount (integer copper, negative for craft), charKey,
-- recipeID?, quality?, quantity?, cost?, incomplete?, customer?, tip?, ... }.
--
-- Profit counts "sale" and "commission" entries only: income = amount, cost = the entry's cost. "craft" entries are
-- cost-basis records and are left out (counting them would charge a cost twice). An entry whose cost is unknown keeps
-- cost = nil in the saved data; in a sum it adds nothing to cost but is counted in `incomplete`, as is an entry
-- flagged incomplete (a cost made from partly missing prices). So a profit with incomplete > 0 is "at least" a
-- profit, never a complete one. NPC reward values are shown elsewhere and are never gold income here.
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

local sessionSettings  -- used while there is no writable saved data (before InitDB, or a newer save)

-- The saved entries list for reads (nil when there is none; nothing is created).
local function entries_view()
  local g = global()
  local ledger = g and g.ledger
  local list = type(ledger) == "table" and ledger.entries
  if type(list) == "table" then return list end
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
  if writable() then
    local g = global()
    if type(g.settings) ~= "table" then g.settings = {} end
    if type(g.settings.ledger) ~= "table" then g.settings.ledger = {} end
    return fill(g.settings.ledger, self.SETTINGS_DEFAULTS)
  end
  if not sessionSettings then
    local g = global()
    local stored = g and type(g.settings) == "table" and g.settings.ledger
    sessionSettings = type(stored) == "table" and copy(stored) or {}
  end
  return fill(sessionSettings, self.SETTINGS_DEFAULTS)
end

---------------------------------------------------------------------------
-- Add / Query / Prune
---------------------------------------------------------------------------

-- Stores one LedgerEntry (a copy; `time` defaults to now, `charKey` to this character) and sends FS_LEDGER_CHANGED.
-- Raises an error for a `type` other than craft|sale|commission, an `amount` that is not an integer, a given
-- `time` that is not a number, or a `cost`/`tip` that is not an integer when given. An unknown cost stays nil.
-- Returns the stored entry, or nil while the saved data is read-only (nothing is written or sent).
function Ledger:Add(entry)
  if type(entry) ~= "table" then error("Ledger:Add: entry must be a table", 2) end
  if not Ledger.TYPES[entry.type] then error("Ledger:Add: bad type " .. tostring(entry.type), 2) end
  if not is_integer(entry.amount) then error("Ledger:Add: amount must be an integer, got " .. tostring(entry.amount), 2) end
  if entry.cost ~= nil and not is_integer(entry.cost) then error("Ledger:Add: cost must be an integer or nil", 2) end
  if entry.tip ~= nil and not is_integer(entry.tip) then error("Ledger:Add: tip must be an integer or nil", 2) end
  if entry.time ~= nil and type(entry.time) ~= "number" then error("Ledger:Add: time must be a number", 2) end

  local list = entries_store()
  if not list then return nil end
  local stored = {}
  for k, v in pairs(entry) do stored[k] = v end
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
  for index, entry in ipairs(entries_view() or {}) do
    if type(entry) == "table" and matches(entry, filter) then
      found[#found + 1] = { entry = entry, index = index, time = number_or(entry.time, 0) }
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
  local kept, removed = {}, 0
  for _, entry in ipairs(list) do
    if type(entry) == "table" and type(entry.time) == "number" and entry.time < cutoff then
      removed = removed + 1
    else
      kept[#kept + 1] = entry
    end
  end
  if removed == 0 then return 0 end
  for i = 1, math.max(#list, #kept) do list[i] = kept[i] end
  self:SendMessage(ns.Msg.LEDGER_CHANGED)
  return removed
end

---------------------------------------------------------------------------
-- Weekly and per-recipe profit
---------------------------------------------------------------------------

-- Start of the weekly-reset week that contains `now` (default: now): now + seconds until the reset - one week.
-- Nil when the game gives no reset time (the week boundary is then unknown, not guessed).
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

-- Adds a sale or commission to a running total (see the profit rule at the top of this file).
local function accumulate(totals, entry)
  local income = entry.amount
  local cost = entry.cost
  totals.income = totals.income + income
  totals.cost = totals.cost + (cost or 0)
  totals.profit = totals.income - totals.cost
  if totals.n then totals.n = totals.n + 1 end
  if cost == nil or entry.incomplete then totals.incomplete = totals.incomplete + 1 end
end

local function counts_as_profit(entry)
  return (entry.type == "sale" or entry.type == "commission") and is_integer(entry.amount)
    and (entry.cost == nil or is_integer(entry.cost))
end

-- Weekly profit for the last `weeks` reset weeks (default 4), newest first: a row for every week, empty ones
-- included: { weekStart, income, cost, profit, incomplete }. `incomplete` is how many of that week's entries had no
-- known cost, so a non-zero value means the profit is partial. An entry newer than the current week's start lands in
-- the current week; an older one than the window is left out. Empty when the week boundary is unknown.
function Ledger:Weekly(now, weeks)
  now = number_or(now, ns.FS:Now())
  weeks = math.max(1, math.floor(number_or(weeks, DEFAULT_WEEKS)))
  local current = self:WeekStart(now)
  if not current then return {} end
  local rows = {}
  for i = 1, weeks do
    rows[i] = { weekStart = current - (i - 1) * WEEK_SECONDS, income = 0, cost = 0, profit = 0, incomplete = 0 }
  end
  for _, entry in ipairs(entries_view() or {}) do
    if type(entry) == "table" and type(entry.time) == "number" and counts_as_profit(entry) then
      local back = entry.time >= current and 0 or math.ceil((current - entry.time) / WEEK_SECONDS)
      local row = rows[back + 1]
      if row then accumulate(row, entry) end
    end
  end
  return rows
end

-- Profit per recipe over the entries that match `filter` (same filter as Query): { [recipeID] = {income, cost,
-- profit, n, incomplete} }. Entries with no recipeID cannot be attributed; Ledger:Unattributed adds them up.
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
-- commission entries for the recipe (`quality` nil = all qualities). Entries with no known tip are not samples.
-- Nil when there are fewer than the benchmarkMinSamples setting.
function Ledger:Benchmark(recipeID, quality)
  local tips = {}
  for _, entry in ipairs(entries_view() or {}) do
    if type(entry) == "table" and entry.type == "commission" and entry.recipeID == recipeID
      and (quality == nil or entry.quality == quality) and is_integer(entry.tip) then
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

function Ledger:OnEnable()
  ns.FS:Wrap("Ledger", function() self:Prune(ns.FS:Now()) end)()
end
