-- CraftingData: pure adapter from GameData tables to the shapes ns.Math consumes. No WoW globals, no ns.FS.
-- Every function takes the GameData registry first (ns.GameData in the addon, a fixture in tests) and
-- returns an empty/nil result, never an error, when a table is empty, missing or has no entry.
local ADDON_NAME, ns = ...

local CraftingData = {}
ns.CraftingData = CraftingData

-- GameData effect type -> the stat name Math.Stats uses. Ingenuity and the concentration-reduction
-- "type<N>" keys are added once golden fixtures identify them.
CraftingData.EFFECT_MAP = { skill = "skill", multicraft = "multicraft", resourcefulness = "resourcefulness" }

local EMPTY = {}

-- The named GameData table, or an empty table when the registry or the table is absent.
local function tbl(gd, name)
  local t = gd and gd.Get and gd.Get(name)
  if type(t) == "table" then return t end
  return EMPTY
end

-- x / 100 rounded to 12 significant digits, so 99.99 gives exactly 0.9999 (the data is decimal).
local function percentToFraction(x)
  return tonumber(string.format("%.12g", x / 100))
end

local function copyPoints(points, convertX)
  local out = {}
  for i, p in ipairs(points or EMPTY) do out[i] = { convertX and convertX(p[1]) or p[1], p[2] } end
  return out
end

-- matQualityWeight of the item's reagent category; 0 when unknown.
function CraftingData.ReagentWeight(gd, itemID)
  local quality = tbl(gd, "ReagentQuality")[itemID]
  local category = quality and tbl(gd, "ReagentCategories")[quality.categoryID]
  return category and category.matQualityWeight or 0
end

-- { curve = skill points with x as a fraction, constant = difficulty points } for the recipe's
-- crafting data; nil when it is unknown or has no skill points or no difficulty points (a cost needs both).
function CraftingData.Curve(gd, craftingDataID)
  local data = tbl(gd, "CraftingData")[craftingDataID]
  local curves = data and tbl(gd, "ConcentrationCurves")[data.craftingDifficultyID]
  if not curves or type(curves.skill) ~= "table" or #curves.skill == 0 then return nil end
  if type(curves.difficulty) ~= "table" or #curves.difficulty == 0 then return nil end
  return { curve = copyPoints(curves.skill, percentToFraction), constant = copyPoints(curves.difficulty) }
end

-- Quality-tier thresholds for tiers 2..maxQuality as ascending fractions of the difficulty;
-- nil when the crafting data or any tier is missing, or maxQuality is not a number.
function CraftingData.ThresholdFractions(gd, craftingDataID, maxQuality)
  if type(maxQuality) ~= "number" then return nil end
  local data = tbl(gd, "CraftingData")[craftingDataID]
  local tiers = data and tbl(gd, "QualityThresholds")[data.craftingDifficultyID]
  if not tiers then return nil end
  local fractions = {}
  for tier = 2, maxQuality do
    local pct = tiers[tier]
    if type(pct) ~= "number" then return nil end
    fractions[#fractions + 1] = percentToFraction(pct)
  end
  return fractions
end

-- The schematic's own craftingDataID, else the one GameData lists for its first output item.
function CraftingData.CraftingDataIDFor(gd, schematic)
  if not schematic then return nil end
  if schematic.craftingDataID then return schematic.craftingDataID end
  local outputs = schematic.outputItemIDs
  local itemID = outputs and outputs[1]
  if itemID == nil then return nil end
  return tbl(gd, "ItemCraftingData")[itemID]
end

-- Stats an optional or finishing reagent adds: increasedifficulty from the item's
-- maxDifficultyAdjustment, plus its mapped OptionalReagents effects summed by stat. Effect types
-- without an EFFECT_MAP entry are ignored. Finishing reagents scale their effects by
-- reagentEffectPct / 100 when the item has a positive percentage, else the effects apply as listed.
function CraftingData.OptionalStats(gd, itemID, kind)
  local stats = {}
  local quality = tbl(gd, "ReagentQuality")[itemID]
  if quality and type(quality.maxDifficultyAdjustment) == "number" and quality.maxDifficultyAdjustment > 0 then
    stats.increasedifficulty = quality.maxDifficultyAdjustment
  end
  local scale = 1
  if kind == "finishing" and quality and type(quality.reagentEffectPct) == "number" and quality.reagentEffectPct > 0 then
    scale = quality.reagentEffectPct / 100
  end
  local reagent = tbl(gd, "OptionalReagents")[itemID]
  for _, effect in ipairs(reagent and reagent.effects or EMPTY) do
    local stat = CraftingData.EFFECT_MAP[effect.type]
    if stat and type(effect.amount) == "number" then
      stats[stat] = (stats[stat] or 0) + effect.amount * scale
    end
  end
  return stats
end

-- Whether a schematic slot is part of the required allocation (a Math slot): every basic slot, and every
-- required optional/finishing slot (a "spark": a modifying reagent the recipe cannot be crafted without).
-- A slot whose reagents list is empty (currency-only, or nothing listed) never is.
function CraftingData.IsAllocated(slot)
  if type(slot) ~= "table" then return false end
  if type(slot.reagents) == "table" and #slot.reagents == 0 then return false end
  return slot.kind == "basic" or slot.required == true
end

-- Converts Blizzard-style reagent infos ({ reagent = { itemID }, dataSlotIndex, quantity }) back to a
-- ReagentAllocation over the schematic's slotIndex (basic slots and required optional/finishing slots, see
-- IsAllocated) and a list of the other optional/finishing itemIDs. Infos for unknown data slots or without an
-- itemID are skipped, as are slots with a currencyID or an empty reagents list (Scanner:ToCraftingReagentInfo
-- never emits those).
function CraftingData.AllocationFromReagentInfo(schematic, infos)
  local slotByData = {}
  for _, slot in ipairs(schematic and schematic.reagentSlots or EMPTY) do
    local empty = type(slot.reagents) == "table" and #slot.reagents == 0
    if slot.dataSlotIndex ~= nil and slot.currencyID == nil and not empty then
      slotByData[slot.dataSlotIndex] = slot
    end
  end
  local allocation, optionalItemIDs = {}, {}
  for _, info in ipairs(infos or EMPTY) do
    local slot = slotByData[info.dataSlotIndex]
    local itemID = info.reagent and info.reagent.itemID
    if slot and itemID then
      if CraftingData.IsAllocated(slot) then
        allocation[#allocation + 1] = { slotIndex = slot.slotIndex, itemID = itemID, quantity = info.quantity }
      else
        optionalItemIDs[#optionalItemIDs + 1] = itemID
      end
    end
  end
  return allocation, optionalItemIDs
end

-- Price of an optional reagent: the copies the slot needs beyond owned + provided at `price` each,
-- 0 when none must be bought, nil when some must and the price is unknown.
local function optional_price(price, quantity, owned, provided)
  local buy = (quantity or 1) - (owned or 0) - (provided or 0)
  if buy <= 0 then return 0 end
  if type(price) ~= "number" then return nil end
  return buy * price
end

-- RecipeInput for Math.Profit from a cached schematic. args:
--   schematic, calib|nil (CalibRecord), professionSkill (used without calib), prices = {[itemID] = copper|nil},
--   owned|nil and provided|nil = {[itemID] = count}, optionalItemIDs|nil, useConcentration, targetQuality.
-- With calib its baseSkill, baseDifficulty (else the schematic's), maxReagentSkill and stats are used; without,
-- baseSkill = professionSkill, the schematic's baseDifficulty, maxReagentSkill nil (Math's default) and no stats.
-- Basic slots with reagents become slots (currency-only and empty slots are left out); a slot's weight is
-- its first reagent's ReagentWeight and its items are ranked in the schematic's order. Required optional and
-- finishing slots with reagents (sparks) become slots too: weight 0 (fixed: the optimiser takes the cheapest
-- usable item, which then is in the allocation, the cost, missing reagents and CraftRecipe's reagents) and
-- noResourcefulness = true (resourcefulness saves basic reagents only). Their items' stats are not applied.
-- missingWeights = true when a basic slot offers two or more ranks but GameData has no weight for it (the
-- ranks then add no skill: the result is an estimate).
-- optionals: with optionalItemIDs (a list, possibly empty), every item of every other optional and finishing
-- slot with its OptionalStats and price, so EvaluateAllocation(input, allocation, optionalItemIDs) can pick the
-- selected ones; without, none (EvaluateCraft applies every listed optional).
-- A non-number maxQuality becomes nil (Math treats it as 1, with no thresholds).
function CraftingData.BuildInput(gd, args)
  local schematic = args.schematic or EMPTY
  local calib = args.calib
  local prices, owned, provided = args.prices or EMPTY, args.owned or EMPTY, args.provided or EMPTY
  local maxQuality = type(schematic.maxQuality) == "number" and schematic.maxQuality or nil
  local craftingDataID = calib and calib.craftingDataID or CraftingData.CraftingDataIDFor(gd, schematic)

  local slots, optionals, seen = {}, {}, {}
  local missingWeights = false
  for _, slot in ipairs(schematic.reagentSlots or EMPTY) do
    local reagents = type(slot.reagents) == "table" and slot.reagents or EMPTY
    if #reagents > 0 and CraftingData.IsAllocated(slot) then
      local basic = slot.kind == "basic"
      local items = {}
      for rank, itemID in ipairs(reagents) do
        items[rank] = { itemID = itemID, rank = rank, price = prices[itemID], owned = owned[itemID] or 0,
          provided = provided[itemID] or 0 }
      end
      local weight = basic and CraftingData.ReagentWeight(gd, reagents[1]) or 0
      if basic and #reagents >= 2 and weight <= 0 then missingWeights = true end
      slots[#slots + 1] = { slotIndex = slot.slotIndex, quantity = slot.quantity or 0, weight = weight, items = items,
        noResourcefulness = (not basic) or nil }
    elseif args.optionalItemIDs and (slot.kind == "optional" or slot.kind == "finishing") then
      for _, itemID in ipairs(reagents) do
        if not seen[itemID] then
          seen[itemID] = true
          optionals[#optionals + 1] = { itemID = itemID,
            price = optional_price(prices[itemID], slot.quantity, owned[itemID], provided[itemID]),
            stats = CraftingData.OptionalStats(gd, itemID, slot.kind) }
        end
      end
    end
  end

  local stats = {}
  for k, v in pairs(calib and calib.stats or EMPTY) do stats[k] = v end
  local outputPrices = {}
  for q, itemID in pairs(schematic.outputItemIDs or EMPTY) do outputPrices[q] = prices[itemID] end

  return {
    maxQuality = maxQuality,
    baseDifficulty = calib and calib.baseDifficulty or schematic.baseDifficulty,
    baseSkill = calib and calib.baseSkill or args.professionSkill,
    maxReagentSkill = calib and calib.maxReagentSkill or nil,
    thresholdFractions = CraftingData.ThresholdFractions(gd, craftingDataID, maxQuality),
    slots = slots,
    missingWeights = missingWeights,
    optionals = optionals,
    stats = stats,
    yield = { min = schematic.quantityMin, max = schematic.quantityMax },
    outputPrices = outputPrices,
    concentration = { curve = CraftingData.Curve(gd, craftingDataID), lessFactors = {} },
    useConcentration = args.useConcentration,
    targetQuality = args.targetQuality,
  }
end
