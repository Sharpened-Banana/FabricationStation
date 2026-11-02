-- Math.Stats: multicraft and resourcefulness expectations, bonus-stat parsing, optional reagent effects.
-- Pure Lua 5.1: no WoW globals, no ns.FS. Plain tables in, plain tables out.
-- Formula reference: CraftSim (MIT, github.com/derfloh205/CraftSim) CALC:GetExpectedItemAmountMulticraft; Util/Const.lua (MULTICRAFT_CONSTANTS, BASE_RESOURCEFULNESS_AVERAGE_SAVE_FACTOR, PERCENT_DIVISION_FACTORS)
-- Both the multicraft constants and the 0.30 resourcefulness factor are CraftSim approximations.
local ADDON_NAME, ns = ...

ns.Math = ns.Math or {}
local Math = ns.Math

local Stats = {}
Math.Stats = Stats

-- Multicraft constant C by base yield; the default applies to any yield not listed.
Stats.MULTICRAFT_CONSTANTS = { default = 2.5, [1] = 2.1, [2] = 1.83, [5] = 1.875 }

-- Share of the required reagent cost a resourcefulness proc saves (before extra saving from stats).
Stats.RESOURCEFULNESS_SAVE_FACTOR = 0.30

-- Optional-reagent stat rating points that make up 1.0 (100%) of each stat.
Stats.RATING_PER_UNIT = { multicraft = 1100, resourcefulness = 900, ingenuity = 1000 }

local STAT_KEYS = { "multicraft", "resourcefulness", "ingenuity" }

-- A proc chance is a probability: base chance plus optional reagents (a real one carries +1.0 multicraft) can pass 1.
local function clamp_chance(chance)
  if chance > 1 then return 1 end
  return chance
end

-- Expected items from one craft with baseYield and a multicraft proc chance (fraction, clamped to 0..1).
-- Returns expected total yield, and the expected extra items when multicraft procs.
function Stats.ExpectedYield(baseYield, mcChance, mcExtra)
  if not mcChance or mcChance <= 0 then return baseYield, 0 end
  mcChance = clamp_chance(mcChance)
  local C = Stats.MULTICRAFT_CONSTANTS[baseYield] or Stats.MULTICRAFT_CONSTANTS.default
  local maxExtra = C * baseYield * (1 + (mcExtra or 0))
  local extraOnProc = (1 + maxExtra) / 2
  return baseYield + mcChance * extraOnProc, extraOnProc
end

-- Expected reagent cost saved per craft: chance (clamped to 0..1) x requiredCost x factor x (1 + extra).
function Stats.ResourcefulnessSaving(requiredCost, resChance, resExtra)
  if not resChance or resChance <= 0 then return 0 end
  resChance = clamp_chance(resChance)
  return resChance * requiredCost * Stats.RESOURCEFULNESS_SAVE_FACTOR * (1 + (resExtra or 0))
end

-- Reads CraftingOperationInfo.bonusStats ({ bonusStatName, ratingPct }) into stat fractions.
-- names maps a stat key to its localized name. A stat with ratingPct 0 or absent stays nil (unsupported).
function Stats.ParseBonusStats(bonusStats, names)
  local out = {}
  if type(bonusStats) ~= "table" or type(names) ~= "table" then return out end
  for _, info in ipairs(bonusStats) do
    local name, pct = info.bonusStatName, info.ratingPct
    if name and pct and pct ~= 0 then
      for _, key in ipairs(STAT_KEYS) do
        if names[key] == name then out[key] = pct / 100 end
      end
    end
  end
  return out
end

-- Applies optional reagent effects. optionals is a list of { stats = { skill, increasedifficulty,
-- multicraft, resourcefulness, ingenuity, reduceconcentrationcost } } with raw amounts (ratings for the
-- three stats, percent for reduceconcentrationcost). Any such list works, e.g. a pseudo-optional.
-- Returns newStats (a copy of stats with rating / RATING_PER_UNIT added), skillBonus, difficultyBonus,
-- and a list of lessConcentration factors (amount / 100 each).
function Stats.ApplyOptionals(stats, optionals)
  local out = {}
  for k, v in pairs(stats or {}) do out[k] = v end
  local skill, difficulty, less = 0, 0, {}
  for _, opt in ipairs(optionals or {}) do
    local s = opt.stats
    if s then
      skill = skill + (s.skill or 0)
      difficulty = difficulty + (s.increasedifficulty or 0)
      for _, key in ipairs(STAT_KEYS) do
        if s[key] then out[key] = (out[key] or 0) + s[key] / Stats.RATING_PER_UNIT[key] end
      end
      if s.reduceconcentrationcost then less[#less + 1] = s.reduceconcentrationcost / 100 end
    end
  end
  return out, skill, difficulty, less
end
