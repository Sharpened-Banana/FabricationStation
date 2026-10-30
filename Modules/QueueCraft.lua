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

-- Crafts Craft Next started that have not produced a result yet, oldest first:
-- { entryID, outputs = { [itemID] = true } }. Session only.
local pending = {}
-- operationIDs already counted (a multicraft sends several results for one operation).
local seenOperations, seenCount = {}, 0

local function recipes() return ns.FS:GetModule("Recipes") end
local function scanner() return ns.FS:GetModule("Scanner") end
local function prices() return ns.FS:GetModule("Prices") end

---------------------------------------------------------------------------
-- Shopping list
---------------------------------------------------------------------------

-- [itemID] = rank index of the item in its schematic slot, for the queued recipes' slots that offer
-- two or more reagents.
local function reagent_tiers(entries)
  local tiers = {}
  for _, e in ipairs(entries) do
    local schematic = scanner():GetSchematic(e.recipeID)
    for _, slot in ipairs(schematic and schematic.reagentSlots or {}) do
      local reagents = slot.reagents or {}
      if #reagents >= 2 then
        for i, itemID in ipairs(reagents) do
          if tiers[itemID] == nil then tiers[itemID] = i end
        end
      end
    end
  end
  return tiers
end

-- Sends the queue's missing reagents (every character) to Auctionator as the list "FabricationStation".
-- Returns true, { added, skipped } (skipped: names not cached yet, their load is requested), or false
-- plus "noAuctionator" | "empty" | "auctionatorError". No list is made when every name is still loading.
function Queue:ExportShoppingList()
  local api = prices():AuctionatorAPI()
  if not (api and type(api.ConvertToSearchString) == "function" and type(api.CreateShoppingList) == "function") then
    return false, "noAuctionator"
  end
  local missing = self:GetMissingReagents(nil)
  local itemIDs = {}
  for itemID, n in pairs(missing) do
    if n > 0 then itemIDs[#itemIDs + 1] = itemID end
  end
  if #itemIDs == 0 then return false, "empty" end
  table.sort(itemIDs)

  local tiers = reagent_tiers(self:GetEntries())
  local searchStrings, skipped = {}, 0
  for _, itemID in ipairs(itemIDs) do
    local name = C_Item.GetItemNameByID(itemID)
    if type(name) ~= "string" or name == "" then
      skipped = skipped + 1
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
-- character lacks for it ({ [itemID] = qty }; bags, bank and reagent bank, plus the warband when
-- queueUseWarband; reagents a crafting order provides are not needed).
local function one_craft(entry)
  local result = recipes():Evaluate(entry.recipeID, entry.charKey, {
    targetQuality = entry.targetQuality, useConcentration = entry.useConcentration,
    providedReagents = entry.providedReagents,
  })
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
      local c = scanner():GetItemCount(itemID, entry.charKey)
      local have = c.bags + c.bank + c.reagentBank + (useWarband and c.warband or 0)
      if n > have then missing[itemID] = n - have end
    end
  end
  return result, missing
end

local function outputs_of(schematic)
  local set = {}
  for _, itemID in pairs(schematic and schematic.outputItemIDs or {}) do set[itemID] = true end
  return set
end

-- Crafts one of the first queue entry that can be crafted now: not on cooldown, on the current
-- character, its profession window open, nothing missing for one craft. Returns a CraftNextResult:
-- { status = "crafted"|"open"|"missing"|"cooldown"|"empty", entryID?, charKey?, skillLineID?,
-- missing?, readyAt? }. With nothing craftable it reports the first blocker in queue order ("open"
-- for another character or a closed/other profession window, "missing"), "cooldown" with the
-- earliest readyAt when every entry waits, "empty" without entries.
-- A protected action: call it only from an OnClick handler.
function Queue:CraftNext()
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
    elseif not blocker then
      if e.charKey ~= me or not scanner():IsProfessionOpen(profession_of(e.recipeID, schematic)) then
        blocker = { status = "open", entryID = e.id, charKey = e.charKey, skillLineID = skillLineID }
      else
        local result, missing = one_craft(e)
        if result and next(missing) == nil then
          C_TradeSkillUI.CraftRecipe(e.recipeID, 1, scanner():ToCraftingReagentInfo(e.recipeID, result.allocation),
            nil, e.orderID, e.useConcentration and true or false)
          if not e.isRestock then pending[#pending + 1] = { entryID = e.id, outputs = outputs_of(schematic) } end
          return { status = "crafted", entryID = e.id, charKey = e.charKey, skillLineID = skillLineID }
        end
        blocker = { status = "missing", entryID = e.id, charKey = e.charKey, skillLineID = skillLineID, missing = missing }
      end
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

local function stored_quantity(id)
  for _, e in ipairs(Queue:GetEntries()) do
    if e.id == id then return e.quantity end
  end
  return nil
end

-- One result of a craft: the oldest pending craft that makes this item loses one from its entry,
-- once per operationID.
local function on_crafted(_, resultData)
  if type(resultData) ~= "table" then return end
  local operationID = resultData.operationID
  if operationID ~= nil and seenOperations[operationID] then return end
  for i, p in ipairs(pending) do
    if p.outputs[resultData.itemID] then
      table.remove(pending, i)
      if operationID ~= nil then remember_operation(operationID) end
      local quantity = stored_quantity(p.entryID)
      if quantity then Queue:SetQuantity(p.entryID, quantity - 1) end
      return
    end
  end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function QueueCraft:OnEnable()
  self:RegisterEvent("TRADE_SKILL_ITEM_CRAFTED_RESULT", ns.FS:Wrap("QueueCraft:CraftResult", on_crafted))
end

function QueueCraft:OnDisable()
  self:UnregisterAllEvents()
  pending = {}
end
