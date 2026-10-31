local ADDON_NAME, ns = ...

-- QueueCraft: the queue's actions. Adds to the Queue module:
--   Queue:ExportShoppingList      the missing reagents as an Auctionator shopping list
--   Queue:CraftNext               crafts one of the next craftable entry (player click only)
--   Queue:GetCooldownReadyAt      when an entry's recipe is ready again
-- and counts finished crafts (TRADE_SKILL_ITEM_CRAFTED_RESULT) against the entry Craft Next started.
--
-- Rules: C_TradeSkillUI.CraftRecipe is called only inside Queue:CraftNext, and Queue:CraftNext is
-- called only from OnClick handlers (tests/queue/craft_spec.lua checks both). Auctionator is reached
-- only through Prices:AuctionatorAPI. Saved data changes go through Queue:SetQuantity, which writes
-- nothing while the saved data is from a newer version.
--
-- Auctionator v1 names used here (ConvertToSearchString, CreateShoppingList and the search term
-- fields searchString/isExact/quantity/tier) follow CraftSim Modules/Shopping/Shopping.lua and the
-- stub layer; they could not be checked against Auctionator's source in this environment.
local QueueCraft = ns.FS:NewModule("QueueCraft", "AceEvent-3.0")
QueueCraft.coreModule = true

local Queue = ns.FS:GetModule("Queue")

local CALLER_ID = "FabricationStation"
local LIST_NAME = "FabricationStation"
local MAX_SEEN_OPERATIONS = 100
local PENDING_TIMEOUT = 30   -- seconds a started craft may take before it is forgotten
local PENDING_KEY = "QueueCraft:pending"

-- The one craft Craft Next started that has not finished yet, or nil. Session only:
-- { entryID, recipeID, charKey, skillLineID, isRestock, outputs = { [itemID] = true }, hasOutputs }.
-- While it is set Craft Next answers "busy". It is cleared by its craft result (or, for a recipe that
-- makes no item, its UNIT_SPELLCAST_SUCCEEDED), by an interrupted or failed cast, after
-- PENDING_TIMEOUT seconds, and when its entry no longer exists.
local pending
-- operationIDs already counted (a multicraft sends several results for one operation).
local seenOperations, seenCount = {}, 0
-- The export waiting for item names, or nil: { items = { [itemID] = true } still loading, onRetry = fn|nil }. Session
-- only; replaced by the next export, dropped by OnDisable.
local waitingNames

local function recipes() return ns.FS:GetModule("Recipes") end
local function scanner() return ns.FS:GetModule("Scanner") end
local function prices() return ns.FS:GetModule("Prices") end

---------------------------------------------------------------------------
-- Shopping list
---------------------------------------------------------------------------

-- [itemID] = rank index of the item in its schematic slot, for the queued recipes' quality slots: basic slots
-- that offer two or more reagents (quality ranks). Other slots (sparks, optional reagents) list different items,
-- not ranks of one, so they get no tier.
local function reagent_tiers(entries)
  local tiers = {}
  for _, e in ipairs(entries) do
    local schematic = scanner():GetSchematic(e.recipeID)
    for _, slot in ipairs(schematic and schematic.reagentSlots or {}) do
      local reagents = type(slot.reagents) == "table" and slot.reagents or {}
      if slot.kind == "basic" and #reagents >= 2 then
        for i, itemID in ipairs(reagents) do
          if tiers[itemID] == nil then tiers[itemID] = i end
        end
      end
    end
  end
  return tiers
end

local export

-- GET_ITEM_INFO_RECEIVED(itemID, success): one of the awaited names arrived (or cannot load: success false, the item is
-- then left out). When none is left the export runs once more (a continuation of the player's click; it waits for
-- nothing further) and its result goes to the waiting onRetry.
local function on_item_info(_, itemID)
  local w = waitingNames
  if not w or not w.items[itemID] then return end
  w.items[itemID] = nil
  if next(w.items) ~= nil then return end
  waitingNames = nil
  QueueCraft:UnregisterEvent("GET_ITEM_INFO_RECEIVED")
  local ok, info = export(false)
  if w.onRetry then w.onRetry(ok, info) end
end

-- Sends the queue's missing reagents (every character) to Auctionator as the list "FabricationStation".
-- Returns true, { added, skipped, loading? } or false plus "noAuctionator" | "empty" | "auctionatorError".
-- skipped: reagents whose names the client has not cached; their load is requested, and while waiting
-- (loading = true) the export runs again by itself once every requested name has arrived, creating or updating the
-- list then and calling onRetry(ok, info) with that result. No list is made now when every name is still loading.
function Queue:ExportShoppingList(onRetry)
  -- A new export replaces any earlier one still waiting for names.
  if waitingNames then
    waitingNames = nil
    QueueCraft:UnregisterEvent("GET_ITEM_INFO_RECEIVED")
  end
  return export(true, onRetry)
end

export = function(wait, onRetry)
  local api = prices():AuctionatorAPI()
  if not (api and type(api.ConvertToSearchString) == "function" and type(api.CreateShoppingList) == "function") then
    return false, "noAuctionator"
  end
  local missing = Queue:GetMissingReagents(nil)
  local itemIDs = {}
  for itemID, n in pairs(missing) do
    if n > 0 then itemIDs[#itemIDs + 1] = itemID end
  end
  if #itemIDs == 0 then return false, "empty" end
  table.sort(itemIDs)

  local tiers = reagent_tiers(Queue:GetEntries())
  local searchStrings, skipped, loading = {}, 0, {}
  for _, itemID in ipairs(itemIDs) do
    local name = C_Item.GetItemNameByID(itemID)
    if type(name) ~= "string" or name == "" then
      skipped = skipped + 1
      loading[itemID] = true
      C_Item.RequestLoadItemDataByID(itemID)
    else
      local term = { searchString = name, isExact = true, quantity = missing[itemID], tier = tiers[itemID] }
      local ok, result = pcall(api.ConvertToSearchString, CALLER_ID, term)
      if not ok or type(result) ~= "string" then
        ns.FS:LogError("Queue:ShoppingList", "ConvertToSearchString: " .. tostring(result))
        return false, "auctionatorError"
      end
      searchStrings[#searchStrings + 1] = result
    end
  end
  if #searchStrings > 0 then
    local ok, err = pcall(api.CreateShoppingList, CALLER_ID, LIST_NAME, searchStrings)
    if not ok then
      ns.FS:LogError("Queue:ShoppingList", "CreateShoppingList: " .. tostring(err))
      return false, "auctionatorError"
    end
  end
  if skipped > 0 and wait and QueueCraft:IsEnabled() then
    waitingNames = { items = loading, onRetry = onRetry }
    QueueCraft:RegisterEvent("GET_ITEM_INFO_RECEIVED", ns.FS:Wrap("QueueCraft:ShoppingRetry", on_item_info))
    return true, { added = #searchStrings, skipped = skipped, loading = true }
  end
  return true, { added = #searchStrings, skipped = skipped }
end

---------------------------------------------------------------------------
-- Cooldowns
---------------------------------------------------------------------------

-- Server time the entry's recipe is ready again for its character, or nil when it is ready now: no
-- cooldown record, readyAt has passed, or a charge is left.
function Queue:GetCooldownReadyAt(entry)
  if type(entry) ~= "table" then return nil end
  local schematic = scanner():GetSchematic(entry.recipeID)
  if not schematic then return nil end
  local profession = scanner():GetProfession(entry.charKey or ns.FS:CharKey(), schematic.skillLineID)
  local cooldowns = profession and profession.cooldowns
  local cd = type(cooldowns) == "table" and cooldowns[entry.recipeID] or nil
  if type(cd) ~= "table" or type(cd.readyAt) ~= "number" then return nil end
  if cd.readyAt <= ns.FS:Now() then return nil end
  if type(cd.charges) == "number" and cd.charges > 0 then return nil end
  return cd.readyAt
end

---------------------------------------------------------------------------
-- Craft Next
---------------------------------------------------------------------------

-- The child skill line whose window must be open to craft the recipe.
local function profession_of(recipeID, schematic)
  local info = C_TradeSkillUI.GetProfessionInfoByRecipeID(recipeID)
  return info and info.professionID or (schematic and schematic.skillLineID)
end

-- One craft of the entry: the evaluation (nil when the recipe cannot be evaluated) and what the
-- character lacks for it ({ [itemID] = qty }; bags, bank and reagent bank as the game counts them for the current
-- character (Scanner:GetOwnedCount), plus the warband when
-- queueUseWarband; reagents a crafting order provides are not needed). The evaluation costs owned
-- reagents at zero, so the allocation uses what the character holds first (a held rank that prices have
-- made dearer is still crafted with rather than reported missing); it counts the same holdings as `have`
-- below (Queue:CraftEvaluateOpts: no warband while queueUseWarband is off).
local function one_craft(entry)
  local result = recipes():Evaluate(entry.recipeID, entry.charKey, Queue:CraftEvaluateOpts(entry))
  if not result then return nil, {} end
  local need = {}
  for _, a in ipairs(result.allocation or {}) do
    need[a.itemID] = (need[a.itemID] or 0) + (a.quantity or 0)
  end
  for itemID, n in pairs(entry.providedReagents or {}) do
    if need[itemID] then need[itemID] = need[itemID] - n end
  end
  local useWarband = recipes():GetSetting("queueUseWarband")
  local missing = {}
  for itemID, n in pairs(need) do
    if n > 0 then
      local have = scanner():GetOwnedCount(itemID, entry.charKey, useWarband)
      if n > have then missing[itemID] = n - have end
    end
  end
  return result, missing
end

local function outputs_of(schematic)
  local set, any = {}, false
  for _, itemID in pairs(schematic and schematic.outputItemIDs or {}) do set[itemID] = true; any = true end
  return set, any
end

local function entry_exists(id)
  for _, e in ipairs(Queue:GetEntries()) do
    if e.id == id then return e end
  end
  return nil
end

local function clear_pending()
  pending = nil
  ns.FS:CancelDebounce(PENDING_KEY)
end

local function start_pending(e, schematic, skillLineID)
  local outputs, hasOutputs = outputs_of(schematic)
  pending = { entryID = e.id, recipeID = e.recipeID, charKey = e.charKey, skillLineID = skillLineID,
    isRestock = e.isRestock and true or false, outputs = outputs, hasOutputs = hasOutputs }
  ns.FS:Debounce(PENDING_KEY, PENDING_TIMEOUT, ns.FS:Wrap("QueueCraft:PendingTimeout", clear_pending))
end

-- The pending craft finished: its entry (a real one that still exists) loses one craft.
-- Restock entries are not decremented; they recompute from item counts.
local function complete_pending()
  local p = pending
  clear_pending()
  if not p or p.isRestock then return end
  local e = entry_exists(p.entryID)
  if e then Queue:SetQuantity(p.entryID, e.quantity - 1) end
end

-- Crafts one of the first queue entry that can be crafted now: not on cooldown, on the current
-- character, its profession window open, nothing missing for one craft. Returns a CraftNextResult:
-- { status = "crafted"|"busy"|"open"|"missing"|"cooldown"|"empty", entryID?, charKey?, skillLineID?,
-- missing?, readyAt? }. "busy" while the craft it started last has not finished (see `pending`).
-- With nothing craftable it reports the first blocker in queue order ("open" for another character
-- or a closed/other profession window, "missing"), "cooldown" with the earliest readyAt when every
-- entry waits, "empty" without entries.
-- A protected action: call it only from an OnClick handler.
function Queue:CraftNext()
  if pending and not entry_exists(pending.entryID) then clear_pending() end
  if pending then
    return { status = "busy", entryID = pending.entryID, charKey = pending.charKey, skillLineID = pending.skillLineID }
  end
  local entries = self:GetEntries()
  if #entries == 0 then return { status = "empty" } end
  local me = ns.FS:CharKey()
  local blocker, waiting
  for _, e in ipairs(entries) do
    local schematic = scanner():GetSchematic(e.recipeID)
    local skillLineID = schematic and schematic.skillLineID or profession_of(e.recipeID, nil)
    local readyAt = self:GetCooldownReadyAt(e)
    if readyAt then
      if not waiting or readyAt < waiting.readyAt then
        waiting = { status = "cooldown", entryID = e.id, charKey = e.charKey, skillLineID = skillLineID, readyAt = readyAt }
      end
    else
      local blocked
      if e.charKey ~= me or not scanner():IsProfessionOpen(profession_of(e.recipeID, schematic)) then
        blocked = { status = "open", entryID = e.id, charKey = e.charKey, skillLineID = skillLineID }
      else
        local result, missing = one_craft(e)
        if result and next(missing) == nil then
          C_TradeSkillUI.CraftRecipe(e.recipeID, 1, scanner():ToCraftingReagentInfo(e.recipeID, result.allocation),
            nil, e.orderID, e.useConcentration and true or false)
          start_pending(e, schematic, skillLineID)
          return { status = "crafted", entryID = e.id, charKey = e.charKey, skillLineID = skillLineID }
        end
        blocked = { status = "missing", entryID = e.id, charKey = e.charKey, skillLineID = skillLineID, missing = missing }
      end
      blocker = blocker or blocked   -- the first blocker in queue order; later entries may still craft
    end
  end
  return blocker or waiting or { status = "empty" }
end

---------------------------------------------------------------------------
-- Craft results
---------------------------------------------------------------------------

local function remember_operation(operationID)
  if seenCount >= MAX_SEEN_OPERATIONS then seenOperations, seenCount = {}, 0 end
  seenOperations[operationID] = true
  seenCount = seenCount + 1
end

-- One result of a craft: completes the pending craft when it makes this item, once per operationID
-- (a multicraft sends several results for one operation).
local function on_crafted(_, resultData)
  if not pending or type(resultData) ~= "table" then return end
  local operationID = resultData.operationID
  if operationID ~= nil and seenOperations[operationID] then return end
  if not pending.outputs[resultData.itemID] then return end
  if operationID ~= nil then remember_operation(operationID) end
  complete_pending()
end

-- The player's casts: an interrupted or failed cast of the pending recipe (or of an unnamed spell)
-- forgets the pending craft; a succeeded cast completes it for a recipe that makes no item (an
-- enchant, say), which sends no craft result. Recipe IDs are the craft spells' IDs.
local function on_spellcast(event, unit, _, spellID)
  if not pending or unit ~= "player" then return end
  if event == "UNIT_SPELLCAST_SUCCEEDED" then
    if not pending.hasOutputs and spellID == pending.recipeID then complete_pending() end
  elseif spellID == nil or spellID == pending.recipeID then
    clear_pending()
  end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function QueueCraft:OnEnable()
  self:RegisterEvent("TRADE_SKILL_ITEM_CRAFTED_RESULT", ns.FS:Wrap("QueueCraft:CraftResult", on_crafted))
  local spellcast = ns.FS:Wrap("QueueCraft:Spellcast", on_spellcast)
  self:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED", spellcast)
  self:RegisterEvent("UNIT_SPELLCAST_FAILED", spellcast)
  self:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", spellcast)
end

function QueueCraft:OnDisable()
  self:UnregisterAllEvents()
  waitingNames = nil
  clear_pending()
end
