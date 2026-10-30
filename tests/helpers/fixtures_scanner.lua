-- Scanner test world: an open Midnight Blacksmithing window (child skill line 2871, base 164).
--   local fixture = require("fixtures_scanner")
--   W = install_wow_stubs(fixture({ C_TradeSkillUI = { IsTradeSkillLinked = function() return true end } }))
-- fixture(overrides) returns an overrides table for install_wow_stubs; `overrides` is deep-merged
-- into it the same way install_wow_stubs merges (plain tables key by key, anything else replaces).
-- Every API returns fresh tables, so a test may mutate what it gets back.
--
-- World:
--   recipes 1001 (learned, Midnight Blacksmithing 2871), 1002 (learned, filed under 2822),
--   1003 (not learned, no profession info).
--   Schematic 1001 slots: 1 Basic (ModifiedReagent data slot) items {2002, 2001} x5, 2 Modifying 4001,
--   3 Finishing 5001, 4 Basic (plain Reagent data slot) 6001 x2, 5 Automatic 7001.
--   Reagent quality ranks: 2001 -> 1, 2002 -> 2.
--   Specialization (2871 only): configID 55, 3 unspent "Knowledge", tab 10 (state 1, root path 100);
--   paths 100 -> {101, 102}, 102 -> {100} (a cycle); path state 1, spend entry pathID * 10;
--   node ranks 100 = 11/31, 101 = 1/31, 102 = 0/31; perks of 101 = {900} (state 2, entry 9000, unlock rank 5).
--   Concentration currency 3256 (2871 only): 500 / 1000, 360000 ms per cycle, 1 per cycle.
--   Moxie currency 3300: 42 (GameData MoxieCurrency is empty until a test maps it).
--   Cooldowns: 1001 -> 3600 s, no charges; 1002 -> no cooldown, 1 of 2 charges.
--   Tools: GetProfessionSlots(1) -> {20, 21}; slot 20 holds "link20", 21 is empty.

local function is_plain_table(v) return type(v) == "table" and getmetatable(v) == nil end

local function deep_merge(dst, src)
  for k, v in pairs(src) do
    if is_plain_table(v) and is_plain_table(dst[k]) then deep_merge(dst[k], v) else dst[k] = v end
  end
  return dst
end

local CHILD = 2871
local RECIPE_LINE = { [1001] = 2871, [1002] = 2822 }
local REAGENT_QUALITY = { [2001] = 1, [2002] = 2 }

local function child_info()
  return { professionID = CHILD, professionName = "Midnight Blacksmithing", skillLevel = 75, maxSkillLevel = 100,
    skillModifier = 5, parentProfessionID = 164, expansionName = "Midnight", profession = 1 }
end

local function recipe_info(id)
  if id == 1001 then
    return { recipeID = 1001, name = "Midnight Blade", learned = true, supportsQualities = true, maxQuality = 2,
      qualityItemIDs = { 3001, 3002 } }
  elseif id == 1002 then
    return { recipeID = 1002, name = "Khaz Algar Hammer", learned = true, supportsQualities = false }
  elseif id == 1003 then
    return { recipeID = 1003, name = "Unlearned Plate", learned = false, supportsQualities = false }
  end
end

local function slot(slotIndex, reagentType, dataSlotType, itemIDs, quantity, required)
  local reagents = {}
  for i, itemID in ipairs(itemIDs) do reagents[i] = { itemID = itemID } end
  return { slotIndex = slotIndex, dataSlotIndex = slotIndex, reagentType = reagentType, dataSlotType = dataSlotType,
    reagents = reagents, quantityRequired = quantity, required = required, hiddenInCraftingForm = false,
    variableQuantities = {} }
end

local function schematic(id)
  if id ~= 1001 then return nil end
  local T = { Modifying = 0, Basic = 1, Finishing = 2, Automatic = 3 }
  return {
    recipeID = 1001, name = "Midnight Blade", icon = 135274, recipeType = 1, quantityMin = 1, quantityMax = 1,
    outputItemID = 3001, isRecraft = false, hasCraftingOperationInfo = true,
    reagentSlotSchematics = {
      slot(1, T.Basic, 2, { 2002, 2001 }, 5, true),
      slot(2, T.Modifying, 2, { 4001 }, 1, false),
      slot(3, T.Finishing, 2, { 5001 }, 1, false),
      slot(4, T.Basic, 1, { 6001 }, 2, true),
      slot(5, T.Automatic, 1, { 7001 }, 1, true),
    },
  }
end

local function operation_info(id)
  if id ~= 1001 then return nil end
  return { recipeID = 1001, baseDifficulty = 300, bonusDifficulty = 0, baseSkill = 80, bonusSkill = 0,
    craftingDataID = 777, concentrationCurrencyID = 3256, concentrationCost = 20, bonusStats = {} }
end

local CONFIG = 55
local CHILDREN = { [100] = { 101, 102 }, [102] = { 100 } }
local NODE_RANKS = { [100] = 11, [101] = 1, [102] = 0 }
local PERKS = { [101] = { 900 } }

local CURRENCIES = {
  [3256] = { quantity = 500, maxQuantity = 1000, rechargingCycleDurationMS = 360000, rechargingAmountPerCycle = 1 },
  [3300] = { quantity = 42, maxQuantity = 0, rechargingCycleDurationMS = 0, rechargingAmountPerCycle = 0 },
}

local function copy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

local function recipe_cooldown(id)
  if id == 1001 then return 3600, true, 0, 0 end
  if id == 1002 then return nil, false, 1, 2 end
end

local function fixture(overrides)
  local world = {
    C_TradeSkillUI = {
      IsTradeSkillReady = function() return true end,
      IsTradeSkillLinked = function() return false end,
      IsTradeSkillGuild = function() return false end,
      IsNPCCrafting = function() return false end,
      GetChildProfessionInfo = child_info,
      GetAllRecipeIDs = function() return { 1001, 1002, 1003 } end,
      GetFilteredRecipeIDs = function() return { 1001, 1002, 1003 } end,
      GetRecipeInfo = recipe_info,
      GetProfessionInfoByRecipeID = function(id)
        local line = RECIPE_LINE[id]
        if line then return { professionID = line, parentProfessionID = 164 } end
      end,
      GetProfessionInfoBySkillLineID = function(id)
        if id == CHILD then return child_info() end
        if id == 2822 then return { skillLevel = 100, maxSkillLevel = 100 } end
      end,
      GetRecipeSchematic = schematic,
      GetItemReagentQualityByItemInfo = function(itemID) return REAGENT_QUALITY[itemID] end,
      GetCraftingOperationInfo = operation_info,
      GetConcentrationCurrencyID = function(id) return id == CHILD and 3256 or 0 end,
      GetRecipeCooldown = recipe_cooldown,
      GetProfessionSlots = function(profession) return profession == 1 and { 20, 21 } or {} end,
    },
    C_ProfSpecs = {
      SkillLineHasSpecialization = function(id) return id == CHILD end,
      GetConfigIDForSkillLine = function(id) return id == CHILD and CONFIG or 0 end,
      GetSpecTabIDsForSkillLine = function(id) return id == CHILD and { 10 } or {} end,
      GetStateForTab = function() return 1 end,
      GetRootPathForTab = function(tab) if tab == 10 then return 100 end end,
      GetChildrenForPath = function(path) return CHILDREN[path] and copy(CHILDREN[path]) or {} end,
      GetStateForPath = function() return 1 end,
      GetSpendEntryForPath = function(path) return path * 10 end,
      GetPerksForPath = function(path)
        local out = {}
        for i, perkID in ipairs(PERKS[path] or {}) do out[i] = { perkID = perkID, isMajorPerk = false } end
        return out
      end,
      GetStateForPerk = function() return 2 end,
      GetEntryIDForPerk = function(perkID) return perkID * 10 end,
      GetUnlockRankForPerk = function() return 5 end,
      GetCurrencyInfoForSkillLine = function() return { numAvailable = 3, currencyName = "Knowledge" } end,
    },
    C_Traits = {
      GetNodeInfo = function(configID, nodeID)
        if configID == CONFIG and NODE_RANKS[nodeID] then return { currentRank = NODE_RANKS[nodeID], maxRanks = 31 } end
      end,
    },
    C_CurrencyInfo = {
      GetCurrencyInfo = function(id) return CURRENCIES[id] and copy(CURRENCIES[id]) end,
    },
    GetInventoryItemLink = function(_, invSlot) if invSlot == 20 then return "link20" end end,
    ProfessionsFrame = { IsShown = function() return true end },
  }
  return deep_merge(world, overrides or {})
end

return fixture
