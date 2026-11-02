-- Math.Concentration: concentration cost from the difficulty curve, ingenuity expectation, gold per point.
-- Pure Lua 5.1: no WoW globals, no ns.FS. Plain tables in, plain tables out.
-- Formula reference: CraftSim (MIT, github.com/derfloh205/CraftSim) Classes/RecipeData.lua (GetConcentrationCostForSkill, GetConcentrationValue)
-- Formula reference: CraftSim (MIT, github.com/derfloh205/CraftSim) Util/Util.lua (CalculateConcentrationCost, FindBracketData)
local ADDON_NAME, ns = ...

ns.Math = ns.Math or {}
local Math = ns.Math

local Concentration = {}
Math.Concentration = Concentration

-- Share of the concentration spent that an ingenuity proc gives back (before extra refund from stats).
Concentration.BASE_INGENUITY_REFUND = 0.5

-- Returns the point at or below x and the next point (nil past the last one) from pts, sorted ascending by x.
local function bracket(x, pts)
  for i = 1, #pts do
    if x >= pts[i][1] then
      local nxt = pts[i + 1]
      if not nxt then return pts[i], nil end
      if x <= nxt[1] then return pts[i], nxt end
    end
  end
end

local function lerp(p0, p1, x)
  if not p1 or p1[1] == p0[1] then return p0[2] end
  return p0[2] + (p1[2] - p0[2]) * (x - p0[1]) / (p1[1] - p0[1])
end

-- Whether a curve can price concentration: both point lists are present and non-empty.
function Concentration.IsUsable(curve)
  return type(curve) == "table" and type(curve.curve) == "table" and #curve.curve > 0
    and type(curve.constant) == "table" and #curve.constant > 0
end

-- The curve's cost before any discount and before rounding. The curve must be usable and the difficulty positive.
local function curve_cost(curve, skill, difficulty)
  skill = math.min(skill, difficulty)
  local s, e = bracket(skill / difficulty, curve.curve)
  s, e = s or { 0, 0 }, e or { 1, 1 }
  local c0, c1 = bracket(difficulty, curve.constant)
  local k = lerp(c0 or curve.constant[1], c1, difficulty)
  local value = lerp({ difficulty * s[1], s[2] }, { difficulty * e[1], e[2] }, skill)
  return value * k
end

-- Concentration needed to craft at `skill` against `difficulty`.
-- curve = { constant = { {difficulty, k}... }, curve = { {skill/difficulty, value}... } }; nil curve costs 0.
-- A curve without points (either list empty or missing) has an unknown cost: nil.
-- lessFactors: fractions of the cost each saved (e.g. {0.1}); they are summed before rounding.
function Concentration.Cost(curve, skill, difficulty, lessFactors)
  if not curve or difficulty <= 0 then return 0 end
  if not Concentration.IsUsable(curve) then return nil end
  local cost = curve_cost(curve, skill, difficulty)
  local less = 0
  for _, f in ipairs(lessFactors or {}) do less = less + cost * f end
  return Math.Round(cost - less)
end

-- Below this the game's whole-point cost says too little about a percentage.
local LEARN_MIN_COST = 20
-- More than any specialization gives: the curve does not fit this recipe, so the numbers say nothing.
local LEARN_MAX_LESS = 0.5

-- The share of the cost the character's specialization saves on this recipe, from what the game charged (gameCost) at
-- `skill` against `difficulty`: a whole percent as a fraction, for Cost's lessFactors. The game has no field for it
-- (it is not among the operation info's bonus stats), and it differs per recipe; logged in game: 2, 5, 7 and 10 %. The
-- game's cost is a whole number, so the plain ratio is noisy on small costs (132.111 charged at 2 % is 129, 2.35 %);
-- the snap takes that noise away. nil when nothing is saved, or when this cannot tell: no usable curve, no cost.
function Concentration.LearnLess(curve, skill, difficulty, gameCost)
  if type(gameCost) ~= "number" or gameCost <= 0 or type(difficulty) ~= "number" or difficulty <= 0 then return nil end
  if type(skill) ~= "number" or not Concentration.IsUsable(curve) then return nil end
  local cost = curve_cost(curve, skill, difficulty)
  if cost < LEARN_MIN_COST then return nil end
  local less = Math.Round((1 - gameCost / cost) * 100) / 100
  if less <= 0 or less > LEARN_MAX_LESS then return nil end
  return less
end

-- Expected concentration spent when ingenuity gives back `refundFraction` of the cost with chance `ingenuityChance`.
function Concentration.Expected(cost, ingenuityChance, refundFraction)
  return cost * (1 - (ingenuityChance or 0) * refundFraction)
end

-- Copper of extra profit per concentration point; nil when nothing is spent.
function Concentration.GoldPerPoint(profitWith, profitWithout, expectedCost)
  if not expectedCost or expectedCost <= 0 then return nil end
  return Math.Round((profitWith - profitWithout) / expectedCost)
end
