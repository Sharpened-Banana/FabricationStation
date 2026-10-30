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

-- db.global.queue with its tables present (AceDB defaults supply them; a damaged save may not).
local function store()
  local g = global()
  if not g then return nil end
  g.queue = type(g.queue) == "table" and g.queue or {}
  local q = g.queue
  q.entries = type(q.entries) == "table" and q.entries or {}
  q.restock = type(q.restock) == "table" and q.restock or {}
  return q
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

-- The restock entry for itemID topped up to target, or nil when nothing needs crafting. `real` is the
-- stored entries (crafts already queued count towards the target).
local function restock_entry(itemID, target, real)
  local found = recipes():FindRecipesForItem(itemID)[1]
  if not found then return nil end
  local crafter, best, bestResult
  for _, charKey in ipairs(recipes():WhoCanCraft(found.recipeID)) do
    local result = recipes():Evaluate(found.recipeID, charKey, { targetQuality = found.quality })
    local profit = profit_of(result)
    -- The first crafter with a result starts the comparison; a later one must beat it. Profit nil loses to any number.
    if result and (crafter == nil or (profit ~= nil and (best == nil or profit > best))) then
      crafter, best, bestResult = charKey, profit, result
    end
  end
  if not crafter then return nil end
  local held = scanner():GetItemCount(itemID, nil).total
  local yield = bestResult.expectedYield
  if type(yield) ~= "number" or yield <= 0 then yield = 1 end
  local crafts = math.ceil((target - held) / yield)
  for _, e in ipairs(real) do
    if e.recipeID == found.recipeID and e.targetQuality == found.quality then crafts = crafts - e.quantity end
  end
  if crafts <= 0 then return nil end
  return { id = RESTOCK_PREFIX .. itemID, recipeID = found.recipeID, quantity = crafts, charKey = crafter,
    targetQuality = found.quality, isRestock = true, itemID = itemID }
end

---------------------------------------------------------------------------
-- Entries
---------------------------------------------------------------------------

-- Adds a craft. entry = { recipeID, quantity (>= 1), charKey (default: current), targetQuality?,
-- useConcentration?, orderID?, providedReagents? = { [itemID] = qty } }. Returns the new id, or nil
-- for an invalid entry or while the saved data is read-only.
function Queue:Add(entry)
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
  q.entries[#q.entries + 1] = {
    id = nextID, recipeID = entry.recipeID, quantity = quantity, charKey = entry.charKey or ns.FS:CharKey(),
    targetQuality = entry.targetQuality, useConcentration = entry.useConcentration, orderID = entry.orderID,
    providedReagents = type(entry.providedReagents) == "table" and copy_map(entry.providedReagents) or nil,
  }
  changed(self)
  return nextID
end

local function find_index(q, id)
  for i, e in ipairs(q.entries) do
    if e.id == id then return i end
  end
  return nil
end

-- Removes the stored entry `id`; unknown ids (and restock entries) are ignored.
function Queue:Remove(id)
  local q = store()
  if not q or not writable() then return end
  local i = find_index(q, id)
  if not i then return end
  table.remove(q.entries, i)
  changed(self)
end

-- Sets the number of crafts of a stored entry; 0 or less removes it.
function Queue:SetQuantity(id, n)
  if type(n) ~= "number" or n ~= n then return end
  local q = store()
  if not q or not writable() then return end
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
  if not q or not writable() or #q.entries == 0 then return end
  q.entries = {}
  changed(self)
end

-- Entries in insertion order, then the computed restock entries (by itemID). Copies: changing them
-- changes nothing.
function Queue:GetEntries()
  local q = store()
  if not q then return {} end
  local out = {}
  for i, e in ipairs(q.entries) do out[i] = copy_entry(e) end
  local itemIDs = {}
  for itemID in pairs(q.restock) do itemIDs[#itemIDs + 1] = itemID end
  table.sort(itemIDs)
  for _, itemID in ipairs(itemIDs) do
    local e = restock_entry(itemID, q.restock[itemID], q.entries)
    if e then out[#out + 1] = e end
  end
  return out
end

local function find_entry(id)
  for _, e in ipairs(Queue:GetEntries()) do
    if e.id == id then return e end
  end
  return nil
end

---------------------------------------------------------------------------
-- Restock targets
---------------------------------------------------------------------------

-- Keeps `target` of itemID in stock across all characters and the warband; nil (or less than 1) removes it.
function Queue:SetRestock(itemID, target)
  if type(itemID) ~= "number" then return end
  local q = store()
  if not q or not writable() then return end
  local value = type(target) == "number" and positive_int(target) or nil
  if q.restock[itemID] == value then return end
  q.restock[itemID] = value
  changed(self)
end

function Queue:GetRestockTargets()
  local q = store()
  return q and copy_map(q.restock) or {}
end

---------------------------------------------------------------------------
-- Reagents and costs
---------------------------------------------------------------------------

-- What one craft of the entry needs: { [itemID] = qty } from the evaluated allocation, less what the
-- customer provides. Nil when the recipe cannot be evaluated (schematic not cached).
local function per_craft(entry)
  local result = recipes():Evaluate(entry.recipeID, entry.charKey, {
    targetQuality = entry.targetQuality, useConcentration = entry.useConcentration,
    providedReagents = entry.providedReagents,
  })
  if not result then return nil end
  local need = {}
  for _, a in ipairs(result.allocation or {}) do
    need[a.itemID] = (need[a.itemID] or 0) + (a.quantity or 0)
  end
  for itemID, n in pairs(entry.providedReagents or {}) do
    if need[itemID] then need[itemID] = math.max(0, need[itemID] - n) end
  end
  return need
end

-- Per character, what entries need beyond bags + bank + reagent bank: { [charKey] = { [itemID] = qty } }.
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
      local c = scanner():GetItemCount(itemID, charKey)
      local missing = n - (c.bags + c.bank + c.reagentBank)   -- not .total: that already holds the warband
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
      local left = n - scanner():GetItemCount(itemID, nil).warband
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

-- The same for one entry (real or restock) on its own; empty for an unknown id.
function Queue:GetEntryMissing(id)
  local e = find_entry(id)
  return e and missing_total({ e }) or {}
end

-- Copper to craft the entry: the per-craft reagent cost times the quantity. Nil when it is unknown
-- (no price, or the recipe cannot be evaluated), never 0 for those.
function Queue:GetEntryCost(id)
  local e = find_entry(id)
  if not e then return nil end
  local result = recipes():Evaluate(e.recipeID, e.charKey, {
    targetQuality = e.targetQuality, useConcentration = e.useConcentration, providedReagents = e.providedReagents,
  })
  if not result or result.reagentCost == nil then return nil end
  return result.reagentCost * e.quantity
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

function Queue:OnEnable()
  local handler = ns.FS:Wrap("Queue:Recompute", schedule_recompute)
  self:RegisterMessage(ns.Msg.RECIPES_CHANGED, handler)
  self:RegisterMessage(ns.Msg.DATA_CHANGED, handler)
end

function Queue:OnDisable()
  self:UnregisterAllMessages()
  ns.FS:CancelDebounce(DEBOUNCE_KEY)
end
