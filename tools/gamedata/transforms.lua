-- Pure transforms from wago.tools DB2 CSV rows (csv.parse output) to GameData tables.
-- Plain Lua 5.1, run outside the game. One function per GameData Define; see generate.lua.
local csv = require("csv")

local T = {}

-- ProfessionEffectType enum (0-based). Ids not listed here become "type<N>".
local EFFECT_TYPES = { [0] = "skill", "inspiration", "resourcefulness", "finesse", "deftness", "perception",
  "craftingSpeed", "multicraft", "unlockReagentSlot", "modCraftCrit", "modCraftReduction", "modGatherExtra",
  "modGatherTimeDecrease", "modGatherDiscover", "modCraftTimeDecrease", "modCraftExtra", "modGatherTimeIncrease",
  "modGatherRange", "modCraftExtraQuantity", "modGatherExtraQuantity", "modCraftCritSize", "modCraftReductionQuantity" }

-- Numeric column value; errors naming the column when the export holds something else.
local function num(row, name, index)
  local s = csv.col(row, name, index)
  local n = tonumber(s)
  if n == nil then
    local label = index ~= nil and (name .. "[" .. index .. "]") or name
    error(string.format("column %s is not a number: %q", label, s), 0)
  end
  return n
end

-- Groups rows by a numeric column: { [value] = { row... } } in input order.
local function groupBy(rows, name)
  local groups = {}
  for _, row in ipairs(rows) do
    local key = num(row, name)
    local list = groups[key]
    if not list then list = {}; groups[key] = list end
    list[#list + 1] = row
  end
  return groups
end

local function indexBy(rows, name)
  local index = {}
  for _, row in ipairs(rows) do index[num(row, name)] = row end
  return index
end

function T.effectType(id)
  return EFFECT_TYPES[id] or ("type" .. id)
end

-- { [typeID] = rowCount } for ProfessionEffect rows whose type has no name.
function T.unknownEffectTypes(professionEffects)
  local counts = {}
  for _, row in ipairs(professionEffects) do
    local id = num(row, "ProfessionEffectTypeEnumID")
    if not EFFECT_TYPES[id] then counts[id] = (counts[id] or 0) + 1 end
  end
  return counts
end

local function effect(row)
  return { type = T.effectType(num(row, "ProfessionEffectTypeEnumID")), amount = num(row, "Amount") }
end

-- Effects for a list of link rows (each naming a ProfessionEffectID); unknown effect ids are skipped.
local function effectsFor(links, effectsByID)
  local effects = {}
  for _, link in ipairs(links) do
    local row = effectsByID[num(link, "ProfessionEffectID")]
    if row then effects[#effects + 1] = effect(row) end
  end
  return effects
end

-- Sorts rows by the numeric columns given, comparing in order (all must exist on every row).
local function sortRows(rows, ...)
  local names = { ... }
  table.sort(rows, function(a, b)
    for _, name in ipairs(names) do
      local x, y = num(a, name), num(b, name)
      if x ~= y then return x < y end
    end
    return false
  end)
  return rows
end

-- ProfessionExpansion -> [skillLineID] = { professionID, expansionID, concentrationCurrencyID }
function T.professionLines(rows)
  local out = {}
  for _, row in ipairs(rows) do
    out[num(row, "SkillLineID")] = { professionID = num(row, "ProfessionID"), expansionID = num(row, "ExpansionID"),
      concentrationCurrencyID = num(row, "ConcentrationCurrencyID") }
  end
  return out
end

-- CraftingReagentQuality -> [itemID] = { rank, categoryID, maxDifficultyAdjustment, reagentEffectPct }
function T.reagentQuality(rows)
  local out = {}
  for _, row in ipairs(rows) do
    out[num(row, "ItemID")] = { rank = num(row, "OrderIndex") + 1, categoryID = num(row, "ModifiedCraftingCategoryID"),
      maxDifficultyAdjustment = num(row, "MaxDifficultyAdjustment"), reagentEffectPct = num(row, "ReagentEffectPct") }
  end
  return out
end

-- ModifiedCraftingCategory -> [categoryID] = { matQualityWeight }
function T.reagentCategories(rows)
  local out = {}
  for _, row in ipairs(rows) do out[num(row, "ID")] = { matQualityWeight = num(row, "MatQualityWeight") } end
  return out
end

-- Item -> ModifiedCraftingReagentItem -> CraftingReagentEffect -> ProfessionEffect
-- => [itemID] = { categoryID, effects = { { type, amount } } }, only items with at least one effect.
-- CraftingReagentEffect rows are ordered by Order (when the export has it), then ID.
-- wago.tools exports the column as "_Order" (12.1.5.70688); WoWDBDefs names it "Order".
function T.optionalReagents(items, mcri, effectsByCategory, professionEffects)
  local mcriByID = indexBy(mcri, "ID")
  local effectsByID = indexBy(professionEffects, "ID")
  local linksByCategory = groupBy(effectsByCategory, "ModifiedCraftingCategoryID")
  local categoryEffects = {}
  for categoryID, links in pairs(linksByCategory) do
    local orderCol = links[1].Order ~= nil and "Order" or "_Order"
    local hasOrder = true
    for _, link in ipairs(links) do if link[orderCol] == nil then hasOrder = false end end
    if hasOrder then sortRows(links, orderCol, "ID") else sortRows(links, "ID") end
    categoryEffects[categoryID] = effectsFor(links, effectsByID)
  end

  local out = {}
  for _, item in ipairs(items) do
    local reagent = mcriByID[num(item, "ModifiedCraftingReagentItemID")]
    if reagent then
      local categoryID = num(reagent, "ModifiedCraftingCategoryID")
      local effects = categoryEffects[categoryID]
      if effects and #effects > 0 then
        local copy = {}
        for i, e in ipairs(effects) do copy[i] = { type = e.type, amount = e.amount } end
        out[num(item, "ID")] = { categoryID = categoryID, effects = copy }
      end
    end
  end
  return out
end

-- CraftingData -> [craftingDataID] = { craftingDifficultyID, difficulty, craftedItemID }
function T.craftingData(rows)
  local out = {}
  for _, row in ipairs(rows) do
    out[num(row, "ID")] = { craftingDifficultyID = num(row, "CraftingDifficultyID"),
      difficulty = num(row, "CraftingDifficulty"), craftedItemID = num(row, "CraftedItemID") }
  end
  return out
end

-- CraftingDataItemQuality -> [itemID] = craftingDataID (the first row wins for a repeated item).
function T.itemCraftingData(rows)
  local out = {}
  for _, row in ipairs(rows) do
    local itemID = num(row, "ItemID")
    if out[itemID] == nil then out[itemID] = num(row, "CraftingDataID") end
  end
  return out
end

-- CraftingDifficultyQuality + CraftingQuality.QualityTier
-- => [craftingDifficultyID] = { [qualityTier] = qualityPercentage }
function T.qualityThresholds(cdq, craftingQuality)
  local tierByQuality = {}
  for _, row in ipairs(craftingQuality) do tierByQuality[num(row, "ID")] = num(row, "QualityTier") end
  local out = {}
  for _, row in ipairs(cdq) do
    local tier = tierByQuality[num(row, "CraftingQualityID")]
    if tier then
      local difficultyID = num(row, "CraftingDifficultyID")
      out[difficultyID] = out[difficultyID] or {}
      out[difficultyID][tier] = num(row, "QualityPercentage")
    end
  end
  return out
end

-- CraftingDifficulty.Concentration{Skill,Difficulty}CurveID -> CurvePoint Pos[0], Pos[1]
-- => [craftingDifficultyID] = { skill = { {x,y}... }, difficulty = { {x,y}... } } ordered by OrderIndex.
-- Difficulties whose curves have no points are left out.
function T.concentrationCurves(difficulty, curvePoints)
  local pointsByCurve = groupBy(curvePoints, "CurveID")
  local function curve(id)
    local rows = pointsByCurve[id]
    local points = {}
    if not rows then return points end
    sortRows(rows, "OrderIndex", "ID")
    for i, row in ipairs(rows) do points[i] = { num(row, "Pos", 0), num(row, "Pos", 1) } end
    return points
  end
  local out = {}
  for _, row in ipairs(difficulty) do
    local skill = curve(num(row, "ConcentrationSkillCurveID"))
    local diff = curve(num(row, "ConcentrationDifficultyCurveID"))
    if #skill > 0 or #diff > 0 then out[num(row, "ID")] = { skill = skill, difficulty = diff } end
  end
  return out
end

-- TraitNodeEntry.TraitDefinitionID -> ProfessionTrait -> ProfessionTraitXEffect -> ProfessionEffect,
-- plus ProfessionTraitXLabel => [traitNodeEntryID] = { effects = { { type, amount } }, labels = { labelID... } }.
-- Only entries whose definition is a profession trait; labels are sorted and unique.
function T.specEntryEffects(nodeEntries, professionTraits, traitXEffect, professionEffects, traitXLabel)
  local traitsByDefinition = groupBy(professionTraits, "TraitDefinitionID")
  local effectLinks = groupBy(traitXEffect, "ProfessionTraitID")
  local labelLinks = groupBy(traitXLabel, "ProfessionTraitID")
  local effectsByID = indexBy(professionEffects, "ID")
  local out = {}
  for _, entry in ipairs(nodeEntries) do
    local traits = traitsByDefinition[num(entry, "TraitDefinitionID")]
    if traits then
      local effects, labels, seen = {}, {}, {}
      for _, trait in ipairs(sortRows(traits, "ID")) do
        local traitID = num(trait, "ID")
        for _, e in ipairs(effectsFor(sortRows(effectLinks[traitID] or {}, "ID"), effectsByID)) do effects[#effects + 1] = e end
        for _, link in ipairs(labelLinks[traitID] or {}) do
          local labelID = num(link, "LabelID")
          if not seen[labelID] then seen[labelID] = true; labels[#labels + 1] = labelID end
        end
      end
      table.sort(labels)
      out[num(entry, "ID")] = { effects = effects, labels = labels }
    end
  end
  return out
end

-- SpellLabel + SkillLineAbility => [recipeSpellID] = { labelID... } (sorted, unique), keeping only labels in
-- labelSet and recipes on profession skill lines (professionLines, from T.professionLines) with
-- expansionID >= minExpansion (default 11).
-- Real exports give a recipe's base profession in SkillLine and its expansion line in SkillupSkillLineID.
function T.recipeSkillLine(row)
  local skillup = tonumber(row.SkillupSkillLineID)
  if skillup and skillup ~= 0 then return skillup end
  return num(row, "SkillLine")
end

function T.recipeLabels(spellLabels, skillLineAbilities, professionLines, labelSet, minExpansion)
  minExpansion = minExpansion or 11
  local recipes = {}
  for _, row in ipairs(skillLineAbilities) do
    local line = professionLines[T.recipeSkillLine(row)]
    if line and line.expansionID >= minExpansion then recipes[num(row, "Spell")] = true end
  end
  local out, seen = {}, {}
  for _, row in ipairs(spellLabels) do
    local spellID, labelID = num(row, "SpellID"), num(row, "LabelID")
    if recipes[spellID] and labelSet[labelID] then
      seen[spellID] = seen[spellID] or {}
      if not seen[spellID][labelID] then
        seen[spellID][labelID] = true
        out[spellID] = out[spellID] or {}
        out[spellID][#out[spellID] + 1] = labelID
      end
    end
  end
  for _, labels in pairs(out) do table.sort(labels) end
  return out
end

-- The set of label ids referenced by T.specEntryEffects output.
function T.labelSet(specEntryEffects)
  local set = {}
  for _, entry in pairs(specEntryEffects) do
    for _, labelID in ipairs(entry.labels) do set[labelID] = true end
  end
  return set
end

return T
