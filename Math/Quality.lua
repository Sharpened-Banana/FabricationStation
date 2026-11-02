-- Math.Quality: pure crafting-quality math (rounding, quality thresholds, predicted quality, reagent skill).
-- Pure Lua 5.1: no WoW globals, no ns.FS. Plain tables in, plain tables out.
-- Formula reference: CraftSim (MIT, github.com/derfloh205/CraftSim) Modules/RecipeInfo/RecipeInfo.lua (GetQualityThresholds)
-- Formula reference: CraftSim (MIT, github.com/derfloh205/CraftSim) Modules/ReagentOptimization/ReagentOptimization.lua (header: reagent skill)
-- Formula reference: CraftSim (MIT, github.com/derfloh205/CraftSim) Classes/ReagentData.lua (GetMaxSkillFactor)
local ADDON_NAME, ns = ...

ns.Math = ns.Math or {}
local Math = ns.Math

-- Half-up rounding to an integer; every copper value Math returns goes through this.
function Math.Round(x)
  return math.floor(x + 0.5)
end

local Quality = {}
Math.Quality = Quality

-- Default quality thresholds as a fraction of total difficulty, by max quality. Used when GameData has none.
-- Quality q+1 is reached when skill >= fractions[q] * difficulty.
Quality.THRESHOLD_FRACTIONS = {
  [1] = {},
  [2] = { 1.0 },
  [3] = { 0.5, 1.0 },
  [5] = { 0.2, 0.5, 0.8, 1.0 },
}

-- Fraction of base difficulty that reagents can add, when it has not been measured live.
Quality.DEFAULT_REAGENT_SKILL_FACTOR = 0.40

-- Skill needed for qualities 2..maxQuality, as an ascending list ({} for maxQuality 1).
-- `fractions` (from GameData) wins over the defaults; nil for an unsupported maxQuality without fractions.
-- Products are cut to 12 significant digits so float noise (3 * 0.2 = 0.6000000000000001, 100 * 0.29 = 28.999999999999996)
-- cannot push a threshold off its intended value and flip a `skill >= threshold` comparison.
function Quality.Thresholds(maxQuality, difficulty, fractions)
  fractions = fractions or Quality.THRESHOLD_FRACTIONS[maxQuality]
  if not fractions then return nil end
  local out = {}
  for i, f in ipairs(fractions) do
    out[i] = tonumber(string.format("%.12g", difficulty * f))
  end
  return out
end

-- Returns quality, nextThreshold|nil, lowerThreshold: the quality `skill` reaches, the skill needed for the
-- next one (nil at max quality), and the skill at which the reached quality starts (0 for quality 1).
-- An unsupported maxQuality without fractions predicts quality 1 with no thresholds.
function Quality.Predict(skill, difficulty, maxQuality, fractions)
  local thresholds = Quality.Thresholds(maxQuality, difficulty, fractions) or {}
  local reached = 0
  for _, t in ipairs(thresholds) do
    if skill >= t then reached = reached + 1 end
  end
  return reached + 1, thresholds[reached + 1], reached > 0 and thresholds[reached] or 0
end

-- How much of a slot's weight an item of `rank` earns: 0 at rank 1 up to 1 at the top rank
-- (2 ranks: {0, 1}; 3 ranks: {0, 0.5, 1}). A slot with a single rank earns nothing.
function Quality.RankFactor(rank, numRanks)
  if not numRanks or numRanks <= 1 then return 0 end
  if rank < 1 then rank = 1 elseif rank > numRanks then rank = numRanks end
  return (rank - 1) / (numRanks - 1)
end

-- Skill the allocated reagents add (unrounded):
--   maxReagentSkill * sum(w*f(rank)*n) / sum(w*quantity)
-- slots: { {slotIndex, quantity, weight, items = { {itemID, rank} ... }} }, allocation: { {slotIndex, itemID, quantity} }.
-- Slots with weight 0 add nothing and are left out of the denominator; allocation rows whose slot or item
-- is unknown are ignored. 0 when no slot has weight.
function Quality.ReagentSkill(slots, allocation, maxReagentSkill)
  local numerator, denominator = 0, 0
  local bySlot = {}
  for _, row in ipairs(allocation or {}) do
    local list = bySlot[row.slotIndex]
    if not list then list = {}; bySlot[row.slotIndex] = list end
    list[#list + 1] = row
  end
  for _, slot in ipairs(slots or {}) do
    local weight = slot.weight or 0
    if weight > 0 then
      local numRanks = #slot.items
      local rankOf = {}
      for _, item in ipairs(slot.items) do rankOf[item.itemID] = item.rank end
      -- A slot with nothing in it is left out, as the game does: it only happens while a window is being filled.
      if bySlot[slot.slotIndex] then denominator = denominator + weight * (slot.quantity or 0) end
      for _, row in ipairs(bySlot[slot.slotIndex] or {}) do
        local rank = rankOf[row.itemID]
        if rank then
          numerator = numerator + weight * Quality.RankFactor(rank, numRanks) * (row.quantity or 0)
        end
      end
    end
  end
  if denominator <= 0 then return 0 end
  -- The game adds whole points, rounded: logged 26.667 -> 27, 135.692 -> 136, 45.231 -> 45, 149.423 -> 149.
  return Math.Round((maxReagentSkill or 0) * numerator / denominator)
end
