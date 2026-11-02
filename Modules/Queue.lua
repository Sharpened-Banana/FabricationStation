local ADDON_NAME, ns = ...

-- Queue: the crafts the player wants to make (entries), restock targets that top an item up to a
-- count, and what the queue needs (missing reagents, costs). Entries live in db.global.queue
-- = { entries, restock, nextID (lazy) }; restock entries are computed on every read and never stored.
-- Nothing is written while the saved data is from a newer version (ns.FS.dbIsNewer).
local Queue = ns.FS:NewModule("Queue", "AceEvent-3.0")
Queue.coreModule = true

local RECOMPUTE_DEBOUNCE = 0.5  -- seconds
local DEBOUNCE_KEY = "Queue:recompute"
local RESTOCK_PREFIX = "restock:"

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function global()
  return ns.FS.db and ns.FS.db.global
end

local function writable()
  return global() ~= nil and not ns.FS.dbIsNewer
end

-- db.global.queue with its tables present (AceDB defaults supply them; a damaged save may not), for
-- writes. Nil while the saved data is read-only: callers check writable() first, this re-checks.
local function store()
  if not writable() then return nil end
  local g = global()
  g.queue = type(g.queue) == "table" and g.queue or {}
  local q = g.queue
  q.entries = type(q.entries) == "table" and q.entries or {}
  q.restock = type(q.restock) == "table" and q.restock or {}
  return q
end

-- The saved queue for reads: { entries, restock, restockMinProfit } without repairing or reassigning anything in
-- the saved data (a newer or damaged save stays as it is; missing or malformed parts read as empty).
local function view()
  local g = global()
  local q = g and g.queue
  if type(q) ~= "table" then return { entries = {}, restock = {}, restockMinProfit = {} } end
  return { entries = type(q.entries) == "table" and q.entries or {},
    restock = type(q.restock) == "table" and q.restock or {},
    restockMinProfit = type(q.restockMinProfit) == "table" and q.restockMinProfit or {} }
end

local function recipes()
  return ns.FS:GetModule("Recipes")
end

local function scanner()
  return ns.FS:GetModule("Scanner")
end

local function copy_map(t)
  local out = {}
  for k, v in pairs(type(t) == "table" and t or {}) do out[k] = v end
  return out
end

-- A caller's copy of a stored entry.
local function copy_entry(e)
  local out = {}
  for k, v in pairs(e) do out[k] = v end
  if type(e.providedReagents) == "table" then out.providedReagents = copy_map(e.providedReagents) end
  if type(e.optionalItemIDs) == "table" then
    out.optionalItemIDs = {}
    for i, itemID in ipairs(e.optionalItemIDs) do out.optionalItemIDs[i] = itemID end
  end
  return out
end

-- [phase 7 Task 12] The optional/finishing itemIDs an entry carries: positive whole finite numbers, each once, ascending, at most
-- MAX_OPTIONALS (the lowest); nil when none are left.
local MAX_OPTIONALS = 8
local function clean_optionals(list)
  if type(list) ~= "table" then return nil end
  local out, seen = {}, {}
  for _, itemID in ipairs(list) do
    if type(itemID) == "number" and itemID >= 1 and itemID < math.huge and itemID == math.floor(itemID)
      and not seen[itemID] then
      seen[itemID] = true
      out[#out + 1] = itemID
    end
  end
  if #out == 0 then return nil end
  table.sort(out)
  while #out > MAX_OPTIONALS do out[#out] = nil end
  return out
end

local function positive_int(n)
  if type(n) ~= "number" or n ~= n or n == math.huge then return nil end
  n = math.floor(n)
  return n >= 1 and n or nil
end

local function changed(self)
  self:SendMessage(ns.Msg.QUEUE_CHANGED)
end

---------------------------------------------------------------------------
-- Restock
---------------------------------------------------------------------------

-- The profit Evaluate predicts, nil when unknown (no result, or an unpriced one).
local function profit_of(result)
  return result and result.profit or nil
end

-- How many of itemID count as held for a restock target: the owned total (every character and the warband), plus the
-- mail attachments while settings.crafting.restockCountMail, plus the player's own auction listings while
-- restockCountListed and SaleLog is on. An outside count that cannot be known (no mailbox or Auctions tab visit
-- recorded yet) stays nil in held.mail / held.listed and sets held.mailUnknown / held.listedUnknown: it adds nothing to
-- total (the total is what is known), but it is never shown as none. A source that is not counted is simply absent.
-- mailAge / listedAge: seconds since the snapshot data behind those counts.
local function held_of(itemID)
  local owned = scanner():GetItemCount(itemID, nil).total
  local held = { owned = owned, total = owned }
  if recipes():GetSetting("restockCountMail") then
    local count, age = scanner():GetMailCount(itemID, nil)
    if count == nil then held.mailUnknown = true else held.mail, held.mailAge = count, age end
  end
  local saleLog = recipes():GetSetting("restockCountListed") and ns.FS:IsModuleEnabled("SaleLog")
    and ns.FS:GetModule("SaleLog", true)
  if saleLog then
    local count, age = saleLog:GetListedCount(itemID, nil)
    if count == nil then held.listedUnknown = true else held.listed, held.listedAge = count, age end
  end
  held.total = owned + (held.mail or 0) + (held.listed or 0)
  return held
end

-- The one decision behind a restock target, used by the entry and by GetRestockStatus. `real` is the stored entries
-- (crafts already queued count towards the target). Returns a RestockStatus (see GetRestockStatus) plus the entry when
-- status is "queued". A crafter whose result cannot reach the item's quality (flags.unreachableTarget) is skipped: it
-- would craft a lower quality, the count of this item would never rise and the entry would stay forever. With no
-- crafter reaching it there is no entry. With a min profit set, the chosen crafter's profit must be a number at or
-- above it; an unknown profit makes no entry.
local function restock_decision(itemID, target, minProfit, real)
  local status = { itemID = itemID, target = target, minProfit = minProfit, held = held_of(itemID) }
  local found = recipes():FindRecipesForItem(itemID)[1]
  if not found then status.status = "noRecipe"; return status end
  local crafter, best, bestResult
  for _, charKey in ipairs(recipes():WhoCanCraft(found.recipeID)) do
    local result = recipes():Evaluate(found.recipeID, charKey, { targetQuality = found.quality })
    if result and type(result.flags) == "table" and result.flags.unreachableTarget then result = nil end
    local profit = profit_of(result)
    -- The first crafter with a result starts the comparison; a later one must beat it. Profit nil loses to any number.
    if result and (crafter == nil or (profit ~= nil and (best == nil or profit > best))) then
      crafter, best, bestResult = charKey, profit, result
    end
  end
  if not crafter then status.status = "noCrafter"; return status end
  status.crafter, status.profit = crafter, profit_of(bestResult)
  local yield = bestResult.expectedYield
  if type(yield) ~= "number" or yield <= 0 then yield = 1 end
  local crafts = math.ceil((target - status.held.total) / yield)
  for _, e in ipairs(real) do
    if e.recipeID == found.recipeID and e.targetQuality == found.quality then crafts = crafts - e.quantity end
  end
  if crafts <= 0 then status.status, status.crafts = "stocked", 0; return status end
  status.crafts = crafts
  if minProfit ~= nil then
    if status.profit == nil then status.status = "unknownProfit"; return status end
    if status.profit < minProfit then status.status = "belowMinProfit"; return status end
  end
  status.status = "queued"
  return status, { id = RESTOCK_PREFIX .. itemID, recipeID = found.recipeID, quantity = crafts, charKey = crafter,
    targetQuality = found.quality, isRestock = true, itemID = itemID }
end

-- The restock entry for itemID topped up to target, or nil when nothing needs crafting.
local function restock_entry(itemID, target, minProfit, real)
  local _, entry = restock_decision(itemID, target, minProfit, real)
  return entry
end

---------------------------------------------------------------------------
-- Entries
---------------------------------------------------------------------------

-- Adds a craft. entry = { recipeID, quantity (>= 1), charKey (default: current), targetQuality?,
-- useConcentration?, orderID?, providedReagents? = { [itemID] = qty }, optionalItemIDs? = { itemID } (optional and
-- finishing reagents to craft with: number IDs, each once, sorted, at most 8; stored only when any are left) }.
-- Returns the new id, or nil
-- for an invalid entry or while the saved data is read-only. An entry with an orderID belongs to that crafting
-- order: Craft Next crafts it only while the order is claimed, and FS_ORDER_FULFILLED removes it.
-- [phase 7 Task 14] entry.parentID (stored only when it is a number): the id of the entry this one makes a reagent
-- for (Intermediates' sub-crafts). opts.before = a stored entry's id inserts the new entry at that entry's index, so
-- it comes first in queue order (Craft Next's order); an unknown id appends, as without opts.
function Queue:Add(entry, opts)
  if type(entry) ~= "table" or type(entry.recipeID) ~= "number" then return nil end
  local quantity = positive_int(entry.quantity)
  if not quantity or not writable() then return nil end
  local q = store()
  local nextID = q.nextID
  if type(nextID) ~= "number" then
    nextID = 1
    for _, e in ipairs(q.entries) do
      if type(e.id) == "number" and e.id >= nextID then nextID = e.id + 1 end
    end
  end
  q.nextID = nextID + 1
  local stored = {
    id = nextID, recipeID = entry.recipeID, quantity = quantity, charKey = entry.charKey or ns.FS:CharKey(),
    targetQuality = entry.targetQuality, useConcentration = entry.useConcentration, orderID = entry.orderID,
    providedReagents = type(entry.providedReagents) == "table" and copy_map(entry.providedReagents) or nil,
    optionalItemIDs = clean_optionals(entry.optionalItemIDs),
    parentID = type(entry.parentID) == "number" and entry.parentID or nil,
  }
  local at
  if type(opts) == "table" and opts.before ~= nil then
    for i, e in ipairs(q.entries) do
      if type(e) == "table" and e.id == opts.before then at = i; break end
    end
  end
  table.insert(q.entries, at or #q.entries + 1, stored)
  changed(self)
  return nextID
end

local function find_index(q, id)
  for i, e in ipairs(q.entries) do
    if type(e) == "table" and e.id == id then return i end
  end
  return nil
end

-- Removes the stored entry `id`; unknown ids (and restock entries) are ignored.
function Queue:Remove(id)
  local q = store()
  if not q then return end
  local i = find_index(q, id)
  if not i then return end
  table.remove(q.entries, i)
  changed(self)
end

-- Sets the number of crafts of a stored entry; 0 or less removes it.
function Queue:SetQuantity(id, n)
  if type(n) ~= "number" or n ~= n then return end
  local q = store()
  if not q then return end
  local i = find_index(q, id)
  if not i then return end
  local quantity = positive_int(n)
  if not quantity then
    table.remove(q.entries, i)
  elseif q.entries[i].quantity ~= quantity then
    q.entries[i].quantity = quantity
  else
    return
  end
  changed(self)
end

-- Removes every stored entry; restock targets stay.
function Queue:Clear()
  local q = store()
  if not q or #q.entries == 0 then return end
  q.entries = {}
  changed(self)
end

-- Entries in insertion order, then the computed restock entries (by itemID). Copies: changing them
-- changes nothing.
-- The stored entries that look like entries (a damaged or newer save may hold anything).
local function stored_entries(q)
  local out = {}
  for _, e in ipairs(q.entries) do
    if type(e) == "table" and type(e.recipeID) == "number" and type(e.quantity) == "number" then out[#out + 1] = e end
  end
  return out
end

local function restock_target(q, itemID)
  local target = q.restock[itemID]
  return type(target) == "number" and target or nil
end

local function restock_min_profit(q, itemID)
  local n = q.restockMinProfit[itemID]
  return type(n) == "number" and n == n and n >= 0 and n or nil
end

function Queue:GetEntries()
  local q = view()
  local real = stored_entries(q)
  local out = {}
  for i, e in ipairs(real) do out[i] = copy_entry(e) end
  local itemIDs = {}
  for itemID in pairs(q.restock) do
    if type(itemID) == "number" and restock_target(q, itemID) then itemIDs[#itemIDs + 1] = itemID end
  end
  table.sort(itemIDs)
  for _, itemID in ipairs(itemIDs) do
    local e = restock_entry(itemID, restock_target(q, itemID), restock_min_profit(q, itemID), real)
    if e then out[#out + 1] = e end
  end
  return out
end

-- One entry by id (a copy): stored entries are looked up directly; only a "restock:<itemID>" id
-- computes its one restock entry.
local function find_entry(id)
  local q = view()
  if type(id) == "string" and id:sub(1, #RESTOCK_PREFIX) == RESTOCK_PREFIX then
    local itemID = tonumber(id:sub(#RESTOCK_PREFIX + 1))
    local target = itemID and restock_target(q, itemID)
    return target and restock_entry(itemID, target, restock_min_profit(q, itemID), stored_entries(q)) or nil
  end
  for _, e in ipairs(stored_entries(q)) do
    if e.id == id then return copy_entry(e) end
  end
  return nil
end

---------------------------------------------------------------------------
-- Restock targets
---------------------------------------------------------------------------

-- Keeps `target` of itemID in stock across all characters and the warband; nil (or less than 1) removes it, and its
-- min profit with it.
function Queue:SetRestock(itemID, target)
  if type(itemID) ~= "number" then return end
  local q = store()
  if not q then return end
  local value = type(target) == "number" and positive_int(target) or nil
  local dirty = false
  if q.restock[itemID] ~= value then q.restock[itemID] = value; dirty = true end
  if value == nil and type(q.restockMinProfit) == "table" and q.restockMinProfit[itemID] ~= nil then
    q.restockMinProfit[itemID] = nil
    dirty = true
  end
  if dirty then changed(self) end
end

function Queue:GetRestockTargets()
  return copy_map(view().restock)
end

-- Requires a craft of itemID's restock target to profit at least `copper` (floored); nil removes the requirement. A
-- negative or non-number (other than nil) is ignored.
function Queue:SetRestockMinProfit(itemID, copper)
  if type(itemID) ~= "number" then return end
  local value
  if copper ~= nil then
    if type(copper) ~= "number" or copper ~= copper or copper < 0 or copper == math.huge then return end
    value = math.floor(copper)
  end
  local q = store()
  if not q then return end
  if type(q.restockMinProfit) ~= "table" then
    if value == nil then return end
    q.restockMinProfit = {}
  end
  if q.restockMinProfit[itemID] == value then return end
  q.restockMinProfit[itemID] = value
  changed(self)
end

-- The min profit per craft set for itemID's restock target, copper; nil when none.
function Queue:GetRestockMinProfit(itemID)
  return restock_min_profit(view(), itemID)
end

-- RestockStatus = { itemID, target, held = { owned, mail?, listed?, total, mailAge?, listedAge?, mailUnknown?,
-- listedUnknown? }, minProfit?, profit?, crafter?, crafts?, status } for itemID's restock target; nil without one.
-- status: "queued" (a restock entry of `crafts` exists), "stocked" (held plus queued crafts reach the target),
-- "belowMinProfit" / "unknownProfit" (the chosen crafter's `profit` fails the min profit, or is unknown; no entry; `crafts`
-- is what would be needed), "noRecipe" (no recipe makes the item), "noCrafter" (no one reaches the item's quality).
-- It decides exactly as the computed restock entry does. held is explained at held_of.
function Queue:GetRestockStatus(itemID)
  local q = view()
  local target = type(itemID) == "number" and restock_target(q, itemID)
  if not target then return nil end
  return (restock_decision(itemID, target, restock_min_profit(q, itemID), stored_entries(q)))
end

---------------------------------------------------------------------------
-- Reagents and costs
---------------------------------------------------------------------------

-- The Recipes:Evaluate opts the queue plans one craft of `entry` with (Craft Next, missing reagents, the
-- shopping list): owned reagents free, so held reagents are used first, and the warband's counted as owned only
-- when settings.crafting.queueUseWarband is on (what Craft Next and the missing reagents count as held).
function Queue:CraftEvaluateOpts(entry)
  return {
    targetQuality = entry.targetQuality, useConcentration = entry.useConcentration,
    providedReagents = entry.providedReagents, ownedReagentsFree = true,
    excludeWarband = not recipes():GetSetting("queueUseWarband"),
    optionalItemIDs = entry.optionalItemIDs,
  }
end

-- [phase 7 Task 12] The entry's queued optional itemIDs (ascending) that the evaluation `result` did not place in a
-- slot (RecipeResult.optionalAllocation): the schematic no longer lets them fit, so a craft would leave them out. {} for
-- an entry without optionals or a result that is not a table. Pure: Craft Next and the Queue tab both read it.
function Queue.UnplacedOptionals(entry, result)
  local out = {}
  if type(entry) ~= "table" or type(entry.optionalItemIDs) ~= "table" or type(result) ~= "table" then return out end
  local placed = {}
  for _, row in ipairs(result.optionalAllocation or {}) do placed[row.itemID] = true end
  for _, itemID in ipairs(entry.optionalItemIDs) do
    if not placed[itemID] then out[#out + 1] = itemID end
  end
  return out
end

-- What one craft of the entry needs: { [itemID] = qty } from the evaluated allocation, less what the
-- customer provides. Nil when the recipe cannot be evaluated (schematic not cached). Evaluated as Craft Next
-- does (Queue:CraftEvaluateOpts), so the allocation uses held reagents first and the shopping list does not buy
-- a rank the character already holds an alternative for.
local function per_craft(entry)
  local result = recipes():Evaluate(entry.recipeID, entry.charKey, Queue:CraftEvaluateOpts(entry))
  if not result then return nil end
  local need = {}
  for _, a in ipairs(result.allocation or {}) do
    need[a.itemID] = (need[a.itemID] or 0) + (a.quantity or 0)
  end
  -- [phase 7 Task 12] The optionals the evaluation placed (RecipeResult.optionalAllocation) are needed too.
  for _, a in ipairs(result.optionalAllocation or {}) do
    need[a.itemID] = (need[a.itemID] or 0) + (a.quantity or 0)
  end
  for itemID, n in pairs(entry.providedReagents or {}) do
    if need[itemID] then need[itemID] = math.max(0, need[itemID] - n) end
  end
  return need
end

-- Per character, what entries need beyond bags + bank + reagent bank: { [charKey] = { [itemID] = qty } }. The current
-- character's holdings are the game's own count, other characters' their snapshots (Scanner:GetOwnedCount).
local function shortfalls(entries)
  local required = {}
  for _, e in ipairs(entries) do
    local need = per_craft(e)
    if need then
      local r = required[e.charKey] or {}
      required[e.charKey] = r
      for itemID, n in pairs(need) do r[itemID] = (r[itemID] or 0) + n * e.quantity end
    end
  end
  local out = {}
  for charKey, r in pairs(required) do
    local short = {}
    for itemID, n in pairs(r) do
      local missing = n - scanner():GetOwnedCount(itemID, charKey, false)   -- the warband is taken off once, below
      if missing > 0 then short[itemID] = missing end
    end
    out[charKey] = short
  end
  return out
end

-- Sums the per-character shortfalls and, when queueUseWarband, takes the warband's count off each item once.
local function missing_total(entries)
  local sum = {}
  for _, short in pairs(shortfalls(entries)) do
    for itemID, n in pairs(short) do sum[itemID] = (sum[itemID] or 0) + n end
  end
  if recipes():GetSetting("queueUseWarband") then
    for itemID, n in pairs(sum) do
      local left = n - scanner():GetWarbandCount(itemID)
      sum[itemID] = left > 0 and left or nil
    end
  end
  return sum
end

-- { [itemID] = qty } still to get for the queue: charKey's entries, or everyone's (nil). Each character's
-- own items count for that character only; the warband count is subtracted once from the total when the
-- queueUseWarband setting is on. Entries whose recipe cannot be evaluated are left out.
function Queue:GetMissingReagents(charKey)
  local entries = {}
  for _, e in ipairs(self:GetEntries()) do
    if charKey == nil or e.charKey == charKey then entries[#entries + 1] = e end
  end
  return missing_total(entries)
end

-- The same for any list of entries (not the stored queue): { [itemID] = qty } still to get. Only entries with a number
-- recipeID, a quantity of 1 or more and a charKey count (the others are skipped). Each character's own holdings count
-- for that character; the warband count is taken off once when queueUseWarband is on. Reads only.
function Queue:GetMissingForEntries(entries)
  local usable = {}
  for _, e in ipairs(type(entries) == "table" and entries or {}) do
    if type(e) == "table" and type(e.recipeID) == "number" and type(e.quantity) == "number" and e.quantity >= 1
      and e.charKey ~= nil then
      usable[#usable + 1] = e
    end
  end
  return missing_total(usable)
end

-- The same for one entry (real or restock) on its own; empty for an unknown id.
function Queue:GetEntryMissing(id)
  local e = find_entry(id)
  return e and missing_total({ e }) or {}
end

-- The RecipeResult one craft of the entry is costed with (market prices, the entry's options), or nil for an
-- unknown id or a recipe that cannot be evaluated. Its flags and priceAgeDays describe GetEntryCost. Read-only.
-- Second return: the entry (a copy).
function Queue:GetEntryResult(id)
  local e = find_entry(id)
  if not e then return nil end
  return recipes():Evaluate(e.recipeID, e.charKey, {
    targetQuality = e.targetQuality, useConcentration = e.useConcentration, providedReagents = e.providedReagents,
    optionalItemIDs = e.optionalItemIDs,
  }), e
end

-- Copper to craft the entry: the per-craft reagent cost times the quantity. Nil when it is unknown
-- (no price, or the recipe cannot be evaluated), never 0 for those.
function Queue:GetEntryCost(id)
  local result, e = self:GetEntryResult(id)
  if not result or result.reagentCost == nil then return nil end
  return result.reagentCost * e.quantity
end

---------------------------------------------------------------------------
-- Gathering plan (phase 7, Task 15)
---------------------------------------------------------------------------

local DAY = 86400

local function is_number(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

-- The module when it exists and is on, else nil.
local function enabled_module(name)
  if not ns.FS:IsModuleEnabled(name) then return nil end
  return ns.FS:GetModule(name, true)
end

-- The characters the phase 3 surfaces show: every saved character except those hidden through Alts (hidden characters
-- are left out of the plan's mail and alt sources alike). Sorted by charKey.
local function visible_characters()
  local S = scanner()
  local alts = enabled_module("Alts")
  local hidden = alts and alts:Settings().hidden
  if type(hidden) ~= "table" then hidden = {} end
  local out = {}
  for _, charKey in ipairs(S and S:GetCharacters() or {}) do
    if type(charKey) == "string" and not hidden[charKey] then out[#out + 1] = charKey end
  end
  return out
end

-- Seconds since the oldest snapshot behind charKey's bag / bank counts of an item (its Scanner record's itemsTime, each
-- part falling back to lastSeen); 0 for the logged-in character (the game's own counts); nil when no time is known.
local function snapshot_age(charKey, counts)
  if charKey == ns.FS:CharKey() then return 0 end
  local c = scanner():GetCharacter(charKey)
  if type(c) ~= "table" then return nil end
  local times = type(c.itemsTime) == "table" and c.itemsTime or {}
  local lastSeen = is_number(c.lastSeen) and c.lastSeen or nil
  local oldest
  local function seen(t)
    if t and (oldest == nil or t < oldest) then oldest = t end
  end
  if (counts.bags or 0) > 0 then seen(is_number(times.bags) and times.bags or lastSeen) end
  if (counts.bank or 0) + (counts.reagentBank or 0) > 0 then seen(is_number(times.bank) and times.bank or lastSeen) end
  return oldest and math.max(0, ns.FS:Now() - oldest) or nil
end

-- The queued crafts' expected output of itemID: for every queued entry (sub-crafts, crafts queued from the gathering
-- plan, restock entries) of a recipe that makes the item at the entry's target quality, floor(quantity * expected
-- yield) (a yield that is not known counts 1). A reagent such a craft will make is not missing.
local function queued_output(itemID, entries)
  local found = recipes():FindRecipesForItem(itemID)
  if #found == 0 then return 0 end
  local made = 0
  for _, e in ipairs(entries) do
    for _, f in ipairs(found) do
      if e.recipeID == f.recipeID and (e.targetQuality or 1) == f.quality then
        local result = recipes():Evaluate(e.recipeID, e.charKey, { targetQuality = e.targetQuality })
        local yield = result and result.expectedYield
        if not (is_number(yield) and yield >= 1) then yield = 1 end
        made = made + math.floor(e.quantity * yield)
        break
      end
    end
  end
  return made
end

-- The sources of one missing reagent, in the order mail, alt, warband, craft, vendor, auction house (see GetGatheringPlan).
local function gather_sources(itemID, characters, planners)
  local S = scanner()
  local alts, out = enabled_module("Alts"), {}

  -- Mail: each character with attachments of the item (the mailbox snapshot's count and age).
  local mail = {}
  for _, charKey in ipairs(characters) do
    local count, age = S:GetMailCount(itemID, charKey)
    if is_number(count) and count > 0 then mail[#mail + 1] = { kind = "mail", charKey = charKey, count = count, ageSeconds = age } end
  end
  table.sort(mail, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.charKey < b.charKey
  end)
  for _, source in ipairs(mail) do out[#out + 1] = source end

  -- Alts: every other visible character holding the item (not a crafter the plan is for).
  local holdings = alts and alts:GetHoldings(itemID)
  if holdings then
    for _, entry in ipairs(holdings.chars or {}) do
      if not planners[entry.charKey] then
        out[#out + 1] = { kind = "alt", charKey = entry.charKey, count = entry.total, ageSeconds = entry.dataAgeSeconds }
      end
    end
  else
    local held = {}
    for _, charKey in ipairs(characters) do
      if not planners[charKey] then
        local count = S:GetOwnedCount(itemID, charKey, false)
        if is_number(count) and count > 0 then
          held[#held + 1] = { kind = "alt", charKey = charKey, count = count,
            ageSeconds = snapshot_age(charKey, S:GetItemCount(itemID, charKey)) }
        end
      end
    end
    table.sort(held, function(a, b)
      if a.count ~= b.count then return a.count > b.count end
      return a.charKey < b.charKey
    end)
    for _, source in ipairs(held) do out[#out + 1] = source end
  end

  -- Warband bank: a source only while the queue does not already count it as held.
  if not recipes():GetSetting("queueUseWarband") then
    local count, age
    if holdings then
      count, age = holdings.warband, holdings.warbandAgeSeconds
    else
      count = S:GetWarbandCount(itemID)
      local g = global()
      local w = g and g.warband
      if S:GetLiveOwnedCount(itemID, true) ~= nil then
        age = 0
      elseif type(w) == "table" and is_number(w.time) then
        age = math.max(0, ns.FS:Now() - w.time)
      end
    end
    if is_number(count) and count > 0 then out[#out + 1] = { kind = "warband", count = count, ageSeconds = age } end
  end

  -- Craft: the cheapest crafter's craft of one item (Intermediates).
  local intermediates = enabled_module("Intermediates")
  local option = intermediates and intermediates:CraftOption(itemID)
  if option then
    out[#out + 1] = { kind = "craft", charKey = option.charKey, unitPrice = option.unit, recipeID = option.recipeID,
      quality = option.quality, yield = option.yield }
  end

  -- Vendor and auction house: the one price Prices:Get answers.
  local P = ns.FS:GetModule("Prices", true)
  local price = P and P:Get(itemID)
  if type(price) == "table" and price.source == "vendor" then
    out[#out + 1] = { kind = "vendor", unitPrice = price.value }
  elseif type(price) == "table" and price.source == "auction" then
    out[#out + 1] = { kind = "ah", unitPrice = price.value,
      ageSeconds = is_number(price.ageDays) and price.ageDays * DAY or nil }
  end
  return out
end

local function plan_name(itemID)
  local fn = type(C_Item) == "table" and C_Item.GetItemNameByID
  local ok, name = false, nil
  if type(fn) == "function" then ok, name = pcall(fn, itemID) end
  if ok and type(name) == "string" and name ~= "" then return name:lower() end
  return "item:" .. itemID
end

-- GatherRow = { itemID, need, sources = { GatherSource }, choice = "craft"|"buy"|nil } for each reagent the queue is still
-- short of (GetMissingReagents(charKey): after everything the crafter holds, bank and warband included) that no queued
-- craft will make, sorted by item name (the cached name, else item:<id>; case ignored), then itemID. need = the missing
-- count less what queued crafts of the item will produce (queued_output; a reagent they cover leaves the plan).
-- GatherSource = { kind, charKey?, count?, unitPrice?, ageSeconds?, recipeID?, quality?, yield? }, in this order:
--   "mail"    each visible character with attachments of the item: count, ageSeconds of its mailbox snapshot.
--   "alt"     each visible character holding the item in bags, bank or reagent bank, except the characters the plan is for
--             (charKey; nil = every character with a queued craft): count, ageSeconds (Alts:GetHoldings while Alts is on,
--             else the Scanner snapshots).
--   "warband" only while settings.crafting.queueUseWarband is off and the warband bank holds some: count, ageSeconds.
--   "craft"   only while Intermediates is on and someone can make the item (Intermediates:CraftOption): charKey = the
--             crafter, unitPrice = the cost of one item (nil = unknown), recipeID, quality, yield (items per craft, nil =
--             unknown).
--   "vendor"  Prices:Get says source "vendor": unitPrice.
--   "ah"      Prices:Get says source "auction": unitPrice, ageSeconds = ageDays * 86400 (nil = unknown).
-- A count, price or age that is not known stays nil (shown "?"), never 0. choice is the player's saved Craft / Buy choice
-- for the item (Intermediates:GetChoice); nil = the cheaper one. Reads only.
function Queue:GetGatheringPlan(charKey)
  local entries, own = self:GetEntries(), {}
  for _, e in ipairs(entries) do
    if charKey == nil or e.charKey == charKey then own[#own + 1] = e end
  end
  local missing = missing_total(own)   -- what GetMissingReagents(charKey) answers
  local characters = visible_characters()
  -- The characters the plan is for: charKey, or (nil) every character with a queued craft. Their holdings are the
  -- plan's own, so they are not alt sources.
  local planners = {}
  if charKey ~= nil then
    planners[charKey] = true
  else
    for _, e in ipairs(own) do planners[e.charKey] = true end
  end
  local intermediates = ns.FS:GetModule("Intermediates", true)
  local rows = {}
  for itemID, qty in pairs(missing) do
    local need = qty - queued_output(itemID, entries)
    if need > 0 then
      rows[#rows + 1] = { itemID = itemID, need = need, sources = gather_sources(itemID, characters, planners),
        choice = intermediates and intermediates:GetChoice(itemID) or nil }
    end
  end
  local names = {}
  for _, row in ipairs(rows) do names[row.itemID] = plan_name(row.itemID) end
  table.sort(rows, function(a, b)
    if names[a.itemID] ~= names[b.itemID] then return names[a.itemID] < names[b.itemID] end
    return a.itemID < b.itemID
  end)
  return rows
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

-- Recipes, prices-derived results or counts changed: what the queue shows may differ. One announcement
-- per quiet 0.5 s, whatever the number of messages.
local function schedule_recompute()
  ns.FS:Debounce(DEBOUNCE_KEY, RECOMPUTE_DEBOUNCE, ns.FS:Wrap("Queue:Recompute", function()
    changed(Queue)
  end))
end

-- Removes every stored entry with this orderID (one FS_QUEUE_CHANGED); nothing is written while the saved data is
-- read-only, and nothing is sent when no entry belongs to the order. Craft Next would otherwise keep sending
-- CraftRecipe for an order that no longer exists. Both triggers below call it, so whichever comes second finds nothing.
local function remove_order_entries(orderID)
  if orderID == nil then return end
  local q = store()
  if not q then return end
  local kept, removed = {}, false
  for _, e in ipairs(q.entries) do
    if type(e) == "table" and e.orderID == orderID then removed = true else kept[#kept + 1] = e end
  end
  if not removed then return end
  q.entries = kept
  changed(Queue)
end

-- ns.Msg.ORDER_FULFILLED(fulfilled): sent by Orders for a fulfilment it saw clicked.
local function on_order_fulfilled(_, fulfilled)
  remove_order_entries(type(fulfilled) == "table" and fulfilled.orderID or nil)
end

-- CRAFTINGORDERS_FULFILL_ORDER_RESPONSE(result, orderID): Blizzard's own answer, so the entries go even when the
-- Orders module is off or never saw the click. Any result but Ok leaves the order (and its entries) alone.
local function on_fulfill_response(_, result, orderID)
  local results = Enum and Enum.CraftingOrderResult
  if result ~= (type(results) == "table" and results.Ok or 0) then return end
  remove_order_entries(orderID)
end

function Queue:OnEnable()
  local handler = ns.FS:Wrap("Queue:Recompute", schedule_recompute)
  self:RegisterMessage(ns.Msg.RECIPES_CHANGED, handler)
  self:RegisterMessage(ns.Msg.DATA_CHANGED, handler)   -- includes (charKey, "mail")
  self:RegisterMessage(ns.Msg.SALELOG_CHANGED, handler) -- own listings count as held
  -- A source name, not the module's: Queue is a core module and an error here must not turn it off.
  self:RegisterMessage(ns.Msg.ORDER_FULFILLED, ns.FS:Wrap("Queue:OrderFulfilled", on_order_fulfilled))
  self:RegisterEvent("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", ns.FS:Wrap("Queue:OrderFulfilled", on_fulfill_response))
end

function Queue:OnDisable()
  self:UnregisterAllMessages()
  self:UnregisterAllEvents()
  ns.FS:CancelDebounce(DEBOUNCE_KEY)
end
