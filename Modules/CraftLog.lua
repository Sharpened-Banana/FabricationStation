local _, ns = ...

-- CraftLog: every craft's actual result next to FabricationStation's prediction and the game's, in
-- db.global.craftLog = { nextID, entries = { CraftLogEntry } } (created on the first logged craft; at most 1000
-- entries, oldest dropped; only the newest 100 keep their `fixture`):
--   CraftLogEntry = { id, time, charKey, recipeID, orderID?, operationID?, applyConcentration,
--     predicted = { quality, qualityChances, yield, concentrationCost?, multicraftValue?,
--                   resourcefulnessValue? } | nil,
--     game = { quality, concentrationCost?, baseSkill?, bonusSkill?, baseDifficulty?, bonusDifficulty?,
--              lowerSkillThreshold?, upperSkillTreshold? } | nil,
--     actual = { quality?, quantity?, baseQuantity?,
--                multicraft? (extra items: the game's number, else the extras seen; nil = unknown),
--                resourcesReturned = { [itemID] = qty }, concentrationSpent?, ingenuityRefund?, ingenuityProc? },
--     fixture = { reagents, calib, build } | nil }
-- CraftLog:Summary(filter) totals the entries per recipe for the Ledger's Crafts page.
--
-- It only watches. A post-hook on C_TradeSkillUI.CraftRecipe (Blizzard's own button and Queue:CraftNext alike; this
-- file never calls it, tests/queue/craft_spec.lua allows exactly that hook line) remembers the pending craft with
-- both predictions, made right then from the reagents the call passed. The recipe is the one the call crafted, never
-- the profession window's selection. TRADE_SKILL_ITEM_CRAFTED_RESULT then logs one entry per cast:
--   * a result with the operationID of the last logged one is a Multicraft extra: it adds to that entry only;
--   * else it is the pending craft's next cast when the craft is at most 60 s old (counted from the call, then from
--     each logged cast) and the item is one of its schematic's outputs; any other result is not logged.
-- The player's UNIT_SPELLCAST_INTERRUPTED or UNIT_SPELLCAST_FAILED for the pending recipe (or for no spellID) drops the
-- pending craft.
-- Recrafts, enchants and salvage are not logged, as in the Ledger (Ruling P3): clear-only post-hooks on RecraftRecipe,
-- RecraftRecipeForOrder, CraftEnchant and CraftSalvage drop the pending craft (so a recraft after a multi-cast craft
-- that stopped early is not taken for its next cast), and an enchant result (data.isEnchant) is ignored.
-- The Ledger keeps its own pending craft; the two modules share no state.
--
-- Every handler and the hook body run through ns.FS:Wrap("CraftLog", ...), so a failure turns off only this module.
-- The hooks are installed once per session (hooksecurefunc cannot be undone) and do nothing while the module is off.
-- Nothing is written while the saved data is from a newer version (ns.FS.dbIsNewer); saved rows are never wiped (a
-- damaged part is replaced by an empty one, a damaged row is skipped when reading). Unknown values stay nil.
-- Unverified (P7-16): the payload's multicraft, concentrationSpent, ingenuityRefund and hasIngenuityProc fields.
local CraftLog = ns.FS:NewModule("CraftLog", "AceEvent-3.0")

CraftLog.ENTRY_CAP = 1000
CraftLog.FIXTURE_KEEP = 100
CraftLog.PENDING_SECONDS = 60

-- { recipeID, castsLeft, orderID, applyConcentration, at, reagents, calib, predicted, game } from the last hook call
local pending
-- { operationID, entry|nil, multicraftGiven }: the last logged cast (entry is nil when it was not written)
local last

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function global()
  return ns.FS.db and ns.FS.db.global
end

local function writable()
  return global() ~= nil and not ns.FS.dbIsNewer
end

local function is_finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

local function number_or_nil(v)
  if is_finite(v) then return v end
  return nil
end

-- A step that fails (a module missing, an API changing shape) is logged once per session and leaves its part nil.
local loggedOnce = {}
local function log_once(key, text)
  if loggedOnce[key] then return end
  loggedOnce[key] = true
  ns.FS:LogError("CraftLog", text)
end

local function call(key, fn)
  local ok, a, b = pcall(fn)
  if ok then return a, b end
  log_once(key, key .. " failed: " .. tostring(a))  -- locale: joined (log text)
  return nil
end

-- The saved log for reads (nil when there is none; nothing is created).
local function log_view()
  local g = global()
  local log = g and g.craftLog
  if type(log) == "table" and type(log.entries) == "table" then return log end
  return nil
end

-- The saved log for writes, with every part present (created or repaired). Nil while the saved data is read-only.
local function log_store()
  if not writable() then return nil end
  local g = global()
  if type(g.craftLog) ~= "table" then g.craftLog = {} end
  local log = g.craftLog
  if type(log.entries) ~= "table" then log.entries = {} end
  if not (is_finite(log.nextID) and log.nextID >= 1) then
    local maxID = 0
    for _, e in pairs(log.entries) do
      if type(e) == "table" and is_finite(e.id) and e.id > maxID then maxID = e.id end
    end
    log.nextID = maxID + 1
  end
  log.nextID = math.floor(log.nextID)
  return log
end

local function build_number()
  if type(GetBuildInfo) ~= "function" then return nil end
  local ok, _, build = pcall(GetBuildInfo)
  if ok then return build end
  return nil
end

local function is_output(schematic, itemID)
  local outputs = type(schematic) == "table" and schematic.outputItemIDs
  if type(outputs) ~= "table" or itemID == nil then return false end
  for _, id in pairs(outputs) do
    if id == itemID then return true end
  end
  return false
end

-- Adds a resourcesReturned list ({ { reagent = { itemID }, quantity } }) into `into` ([itemID] = qty).
local function add_returned(into, list)
  if type(list) ~= "table" then return into end
  for _, r in ipairs(list) do
    local itemID = type(r) == "table" and type(r.reagent) == "table" and r.reagent.itemID or nil
    local quantity = type(r) == "table" and r.quantity or nil
    if is_finite(itemID) and is_finite(quantity) and quantity > 0 then
      into[itemID] = (into[itemID] or 0) + quantity
    end
  end
  return into
end

local GAME_NUMBERS = { "concentrationCost", "baseSkill", "bonusSkill", "baseDifficulty", "bonusDifficulty",
  "lowerSkillThreshold", "upperSkillTreshold" }

local function game_of(info)
  if type(info) ~= "table" then return nil end
  local game = { quality = number_or_nil(info.craftingQuality) }
  for _, key in ipairs(GAME_NUMBERS) do game[key] = number_or_nil(info[key]) end
  return game
end

local function predicted_of(result, applyConcentration)
  if type(result) ~= "table" then return nil end
  return {
    quality = number_or_nil(result.expectedQuality),
    qualityChances = type(result.qualityChances) == "table" and ns.Util.DeepCopy(result.qualityChances) or nil,
    yield = number_or_nil(result.expectedYield),
    concentrationCost = applyConcentration and number_or_nil(result.concentrationCostForAllocation) or nil,
    multicraftValue = number_or_nil(result.multicraftValue),
    resourcefulnessValue = number_or_nil(result.resourcefulnessValue),
  }
end

local function actual_of(data, schematic)
  local baseQuantity
  if is_finite(schematic.quantityMin) and schematic.quantityMin == schematic.quantityMax then
    baseQuantity = schematic.quantityMin
  end
  return {
    quality = number_or_nil(data.craftingQuality),
    quantity = number_or_nil(data.quantity),
    baseQuantity = baseQuantity,
    multicraft = number_or_nil(data.multicraft),
    resourcesReturned = add_returned({}, data.resourcesReturned),
    concentrationSpent = number_or_nil(data.concentrationSpent),
    ingenuityRefund = number_or_nil(data.ingenuityRefund),
    ingenuityProc = type(data.hasIngenuityProc) == "boolean" and data.hasIngenuityProc or nil,
  }
end

---------------------------------------------------------------------------
-- Capture
---------------------------------------------------------------------------

-- Post-hook on C_TradeSkillUI.CraftRecipe: remembers the craft and both predictions until its results arrive. Each
-- step is protected; a failed one leaves its part nil.
function CraftLog:OnCraftRecipe(recipeID, numCasts, craftingReagents, _, orderID, applyConcentration)
  pending = nil
  if not is_finite(recipeID) then return end
  local concentration = applyConcentration == true
  local recipes = ns.FS:GetModule("Recipes", true)
  local scanner = ns.FS:GetModule("Scanner", true)
  local p = {
    recipeID = recipeID, castsLeft = math.max(1, math.floor(number_or_nil(numCasts) or 1)), orderID = orderID,
    applyConcentration = concentration, at = ns.FS:Now(),
    reagents = type(craftingReagents) == "table" and ns.Util.DeepCopy(craftingReagents) or nil,
  }
  p.calib = call("GetCalibration", function()
    return ns.Util.DeepCopy(recipes:GetCalibration(ns.FS:CharKey(), recipeID))
  end)
  local allocation, optionalItemIDs = call("FromCraftingReagentInfo", function()
    return recipes:FromCraftingReagentInfo(recipeID, craftingReagents)
  end)
  if type(allocation) == "table" then
    p.predicted = predicted_of(call("PredictLive", function()
      return recipes:PredictLive(recipeID, allocation, optionalItemIDs, concentration)
    end), concentration)
    p.game = game_of(call("GetLiveOperationInfo", function()
      return scanner:GetLiveOperationInfo(recipeID, allocation, concentration, optionalItemIDs)
    end))
  end
  pending = p
end

-- A Multicraft extra (same operationID as the last logged cast): more items for that entry, no new entry.
local function add_extra(self, data)
  local entry = last.entry
  if type(entry) ~= "table" or type(entry.actual) ~= "table" or not writable() then return end
  local actual = entry.actual
  local quantity = number_or_nil(data.quantity)
  if quantity and quantity > 0 then
    -- An unknown base quantity stays unknown; the extras still count as Multicraft items.
    if number_or_nil(actual.quantity) then actual.quantity = actual.quantity + quantity end
    if not last.multicraftGiven then actual.multicraft = (number_or_nil(actual.multicraft) or 0) + quantity end
  end
  if type(actual.resourcesReturned) ~= "table" then actual.resourcesReturned = {} end
  add_returned(actual.resourcesReturned, data.resourcesReturned)
  self:SendMessage(ns.Msg.CRAFTLOG_CHANGED)
end

-- TRADE_SKILL_ITEM_CRAFTED_RESULT(data): logs one cast of the pending craft, or adds a Multicraft extra.
function CraftLog:OnCraftResult(data)
  if type(data) ~= "table" or data.isEnchant then return end
  local operationID = data.operationID
  if operationID == 0 then operationID = nil end
  if operationID ~= nil and last and last.operationID == operationID then
    add_extra(self, data)
    return
  end
  local p = pending
  if not p then return end
  local now = ns.FS:Now()
  if now - p.at > CraftLog.PENDING_SECONDS then
    pending = nil
    return
  end
  local scanner = ns.FS:GetModule("Scanner", true)
  local schematic = scanner and scanner:GetSchematic(p.recipeID)
  if not is_output(schematic, data.itemID) then return end
  p.castsLeft = p.castsLeft - 1
  if p.castsLeft <= 0 then pending = nil else p.at = now end

  local log = log_store()
  if not log then
    last = operationID ~= nil and { operationID = operationID } or nil   -- its extras are not counted as casts
    return
  end
  local entry = {
    id = log.nextID, time = now, charKey = ns.FS:CharKey(), recipeID = p.recipeID, orderID = p.orderID,
    operationID = operationID, applyConcentration = p.applyConcentration,
    predicted = ns.Util.DeepCopy(p.predicted), game = ns.Util.DeepCopy(p.game),
    actual = actual_of(data, schematic),
    fixture = { reagents = ns.Util.DeepCopy(p.reagents), calib = ns.Util.DeepCopy(p.calib), build = build_number() },
  }
  log.nextID = log.nextID + 1
  local entries = ns.Util.PushCapped(log.entries, entry, CraftLog.ENTRY_CAP)
  for i = 1, #entries - CraftLog.FIXTURE_KEEP do
    if type(entries[i]) == "table" then entries[i].fixture = nil end
  end
  last = operationID ~= nil
    and { operationID = operationID, entry = entry, multicraftGiven = number_or_nil(data.multicraft) ~= nil } or nil
  self:SendMessage(ns.Msg.CRAFTLOG_CHANGED)
end

-- The player's UNIT_SPELLCAST_INTERRUPTED / UNIT_SPELLCAST_FAILED(unit, castGUID, spellID): an interrupted or failed
-- cast of the pending recipe (or of an unnamed spell) drops the pending craft. Recipe IDs are the craft spells' IDs.
function CraftLog:OnSpellcastInterrupted(unit, _, spellID)
  if not pending or unit ~= "player" then return end
  if spellID == nil or spellID == pending.recipeID then pending = nil end
end

-- Post-hook body for RecraftRecipe, RecraftRecipeForOrder, CraftEnchant and CraftSalvage: what follows is not the
-- pending craft. It only forgets it (tests/queue/craft_spec.lua pins this body).
function CraftLog:OnUntrackedCraft()
  pending = nil
end

---------------------------------------------------------------------------
-- Reads
---------------------------------------------------------------------------

-- The logged crafts, newest first. filter = { since? (inclusive), charKey?, recipeID? }. The stored rows: read-only.
function CraftLog:GetEntries(filter)
  filter = type(filter) == "table" and filter or {}
  local out = {}
  local log = log_view()
  if not log then return out end
  local entries = log.entries
  for i = #entries, 1, -1 do
    local e = entries[i]
    if type(e) == "table"
      and (filter.since == nil or (is_finite(e.time) and e.time >= filter.since))
      and (filter.charKey == nil or e.charKey == filter.charKey)
      and (filter.recipeID == nil or e.recipeID == filter.recipeID) then
      out[#out + 1] = e
    end
  end
  return out
end

-- RecipeCraftStats per recipe over GetEntries(filter): { [recipeID] = { crafts, qualityKnown, asPredicted, above,
-- below, gameAgreed, expectedExtra|nil, actualExtra|nil, multicraftReported, multicraftProcs, resourcefulnessProcs,
-- concentrationSpent|nil, concentrationPredicted|nil } }. A part an entry does not have is unknown and left out of
-- that sum, never counted as 0:
--   * qualityKnown: entries with both actual.quality and predicted.quality, split into asPredicted / above / below;
--     gameAgreed: entries whose game.quality and actual.quality are both known and equal;
--   * expectedExtra = sum of (predicted.yield - (actual.baseQuantity or predicted.yield)) over the entries with a
--     predicted yield; actualExtra = sum of actual.multicraft over the entries that have one. Each is nil when no
--     entry has the number (P7-16: the payload's multicraft may be absent); multicraftReported counts the entries
--     that have one, so a page can say when the sum leaves crafts out;
--   * multicraftProcs: entries with extras (actual.multicraft > 0); resourcefulnessProcs: entries that returned reagents;
--   * the concentration sums count only entries with both predicted.concentrationCost and actual.concentrationSpent,
--     and are nil when there are none.
function CraftLog:Summary(filter)
  local out = {}
  for _, e in ipairs(self:GetEntries(filter)) do
    if is_finite(e.recipeID) then
      local s = out[e.recipeID]
      if not s then
        s = { crafts = 0, qualityKnown = 0, asPredicted = 0, above = 0, below = 0, gameAgreed = 0,
          multicraftReported = 0, multicraftProcs = 0, resourcefulnessProcs = 0 }
        out[e.recipeID] = s
      end
      local predicted = type(e.predicted) == "table" and e.predicted or {}
      local game = type(e.game) == "table" and e.game or {}
      local actual = type(e.actual) == "table" and e.actual or {}
      s.crafts = s.crafts + 1

      local actualQuality, predictedQuality = number_or_nil(actual.quality), number_or_nil(predicted.quality)
      if actualQuality and predictedQuality then
        s.qualityKnown = s.qualityKnown + 1
        if actualQuality == predictedQuality then s.asPredicted = s.asPredicted + 1
        elseif actualQuality > predictedQuality then s.above = s.above + 1
        else s.below = s.below + 1 end
      end
      if actualQuality and number_or_nil(game.quality) == actualQuality then s.gameAgreed = s.gameAgreed + 1 end

      local yield = number_or_nil(predicted.yield)
      if yield then s.expectedExtra = (s.expectedExtra or 0) + (yield - (number_or_nil(actual.baseQuantity) or yield)) end
      local multicraft = number_or_nil(actual.multicraft)
      if multicraft then
        s.actualExtra = (s.actualExtra or 0) + multicraft
        s.multicraftReported = s.multicraftReported + 1
        if multicraft > 0 then s.multicraftProcs = s.multicraftProcs + 1 end
      end
      if type(actual.resourcesReturned) == "table" then
        for _, qty in pairs(actual.resourcesReturned) do
          if type(qty) == "number" and qty > 0 then s.resourcefulnessProcs = s.resourcefulnessProcs + 1; break end
        end
      end

      local spent, cost = number_or_nil(actual.concentrationSpent), number_or_nil(predicted.concentrationCost)
      if spent and cost then
        s.concentrationSpent = (s.concentrationSpent or 0) + spent
        s.concentrationPredicted = (s.concentrationPredicted or 0) + cost
      end
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

-- A hook target the client does not have is logged once per session and skipped.
local loggedMissing = {}
local function log_missing(name, effect)
  if loggedMissing[name] then return end
  loggedMissing[name] = true
  ns.FS:LogError("CraftLog", name .. " not found in this client; " .. effect)  -- locale: joined (log text)
end

function CraftLog:OnEnable()
  local function wrap(fn) return ns.FS:Wrap("CraftLog", fn) end
  self:RegisterEvent("TRADE_SKILL_ITEM_CRAFTED_RESULT", wrap(function(_, data) self:OnCraftResult(data) end))
  self:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED", wrap(function(_, ...) self:OnSpellcastInterrupted(...) end))
  self:RegisterEvent("UNIT_SPELLCAST_FAILED", wrap(function(_, ...) self:OnSpellcastInterrupted(...) end))

  -- hooksecurefunc cannot be undone: install once per session; the bodies do nothing while the module is off.
  if self.hooked then return end
  self.hooked = true
  local function body(fn)
    return wrap(function(...)
      if self:IsEnabled() then fn(...) end
    end)
  end
  local function hook(tbl, name, fn)
    if type(tbl) == "table" and type(tbl[name]) == "function" then
      hooksecurefunc(tbl, name, body(fn))
    else
      log_missing(name, "crafts are not logged correctly")
    end
  end
  wrap(function()
    -- A post-hook only: FabricationStation calls CraftRecipe nowhere but Queue:CraftNext (tests/queue/craft_spec.lua
    -- allows exactly this line in this file and in the Ledger).
    hook(C_TradeSkillUI, "CraftRecipe", function(...) self:OnCraftRecipe(...) end)
    -- Clear-only post-hooks: crafts that do not go through CraftRecipe end the pending craft (they are not logged).
    hook(C_TradeSkillUI, "RecraftRecipe", function() self:OnUntrackedCraft() end)
    hook(C_TradeSkillUI, "RecraftRecipeForOrder", function() self:OnUntrackedCraft() end)
    hook(C_TradeSkillUI, "CraftEnchant", function() self:OnUntrackedCraft() end)
    hook(C_TradeSkillUI, "CraftSalvage", function() self:OnUntrackedCraft() end)
  end)()
end

-- The hook stays installed (its body returns early); the pending craft and the last cast are forgotten.
function CraftLog:OnDisable()
  pending = nil
  last = nil
end
