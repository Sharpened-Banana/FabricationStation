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
-- crafting data; nil when it is unknown or has no skill points.
function CraftingData.Curve(gd, craftingDataID)
  local data = tbl(gd, "CraftingData")[craftingDataID]
  local curves = data and tbl(gd, "ConcentrationCurves")[data.craftingDifficultyID]
  if not curves or not curves.skill or #curves.skill == 0 then return nil end
  return { curve = copyPoints(curves.skill, percentToFraction), constant = copyPoints(curves.difficulty) }
end

-- Quality-tier thresholds for tiers 2..maxQuality as ascending fractions of the difficulty;
-- nil when the crafting data or any tier is missing.
function CraftingData.ThresholdFractions(gd, craftingDataID, maxQuality)
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

-- Converts Blizzard-style reagent infos ({ reagent = { itemID }, dataSlotIndex, quantity }) back to a
-- ReagentAllocation over the schematic's slotIndex (basic slots) and a list of optional/finishing
-- itemIDs. Infos for unknown data slots or without an itemID are skipped.
function CraftingData.AllocationFromReagentInfo(schematic, infos)
  local slotByData = {}
  for _, slot in ipairs(schematic and schematic.reagentSlots or EMPTY) do
    if slot.dataSlotIndex ~= nil then slotByData[slot.dataSlotIndex] = slot end
  end
  local allocation, optionalItemIDs = {}, {}
  for _, info in ipairs(infos or EMPTY) do
    local slot = slotByData[info.dataSlotIndex]
    local itemID = info.reagent and info.reagent.itemID
    if slot and itemID then
      if slot.kind == "basic" then
        allocation[#allocation + 1] = { slotIndex = slot.slotIndex, itemID = itemID, quantity = info.quantity }
      else
        optionalItemIDs[#optionalItemIDs + 1] = itemID
      end
    end
  end
  return allocation, optionalItemIDs
end
