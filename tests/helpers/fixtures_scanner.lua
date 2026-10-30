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
    },
    ProfessionsFrame = { IsShown = function() return true end },
  }
  return deep_merge(world, overrides or {})
end

return fixture
