-- Math.Profit: expected sale and profit per craft, the pure entry points EvaluateCraft and EvaluateAllocation.
-- Pure Lua 5.1: no WoW globals, no ns.FS. Plain tables in, plain tables out.
-- Formula reference: CraftSim (MIT, github.com/derfloh205/CraftSim) Classes/ResultData.lua (concentration adds one quality)
-- Formula reference: CraftSim (MIT, github.com/derfloh205/CraftSim) Classes/RecipeData.lua (GetConcentrationValue)
--
-- A "plan" is one allocation and the quality it crafts: a plain plan for every quality the reagents can land on
-- (Optimizer.CheapestByQuality), and a concentration plan for every such quality q below the top, crafting q + 1
-- with plan q's reagents at Concentration.Cost(curve, skill_q, difficulty, less).
local ADDON_NAME, ns = ...

ns.Math = ns.Math or {}
local Math = ns.Math

local Profit = {}
Math.Profit = Profit

-- Share of the sale price the seller keeps after the auction house cut.
Profit.AH_CUT = 0.95

local Round = Math.Round

-- Expected copper from selling one craft's output: sum(chance_q * price_q) * expectedYield * AH_CUT.
-- nil when a quality with a positive chance has no price.
function Profit.ExpectedSale(qualityChances, outputPrices, expectedYield)
  local total = 0
  for q, chance in pairs(qualityChances or {}) do
    if chance > 0 then
      local price = (outputPrices or {})[q]
      if type(price) ~= "number" then return nil end
      total = total + chance * price
    end
  end
  return Round(total * (expectedYield or 0) * Profit.AH_CUT)
end

-- Optionals, resolved stats and the numbers every plan of this input shares.
local function prepare(input, optionalItemIDs)
  local optionals = input.optionals or {}
  local unknownOptional = false
  if optionalItemIDs then
    local wanted, picked = {}, {}
    for _, id in ipairs(optionalItemIDs) do wanted[id] = true end
    for _, opt in ipairs(optionals) do
      if wanted[opt.itemID] then picked[#picked + 1] = opt; wanted[opt.itemID] = nil end
    end
    -- A requested optional the input does not describe has unknown cost and effects: never price it as free.
    unknownOptional = next(wanted) ~= nil
    optionals = picked
  end
  local stats, skillBonus, difficultyBonus, optLess = Math.Stats.ApplyOptionals(input.stats, optionals)

  local optionalCost = (not unknownOptional) and 0 or nil
  for _, opt in ipairs(optionals) do
    if optionalCost and type(opt.price) == "number" then
      optionalCost = optionalCost + opt.price
    else
      optionalCost = nil
    end
  end

  local less = {}
  local conc = input.concentration or {}
  for _, f in ipairs(conc.lessFactors or {}) do less[#less + 1] = f end
  for _, f in ipairs(optLess) do less[#less + 1] = f end

  -- Slots resourcefulness does not save (required modifying reagents); their cost is taken off the saving's base.
  local unsavedSlots = {}
  for _, slot in ipairs(input.slots or {}) do
    if slot.noResourcefulness then unsavedSlots[#unsavedSlots + 1] = slot end
  end

  local baseDifficulty = input.baseDifficulty or 0
  local yield = input.yield or {}
  local baseYield = ((yield.min or 1) + (yield.max or yield.min or 1)) / 2
  return {
    input = input,
    stats = stats,
    skill = (input.baseSkill or 0) + skillBonus,
    difficulty = baseDifficulty + difficultyBonus,
    -- The default reagent skill scales with base difficulty, not the total with optionals.
    maxReagentSkill = input.maxReagentSkill or Math.Quality.DEFAULT_REAGENT_SKILL_FACTOR * baseDifficulty,
    optionalCost = optionalCost,
    unknownOptional = unknownOptional,
    -- A curve without points cannot price anything: treated as no curve (concentration numbers unknown).
    curve = Math.Concentration.IsUsable(conc.curve) and conc.curve or nil,
    unsavedSlots = unsavedSlots,
    less = less,
    baseYield = baseYield,
    expectedYield = (Math.Stats.ExpectedYield(baseYield, stats.multicraft, stats.multicraftExtra)),
    refund = Math.Concentration.BASE_INGENUITY_REFUND + (stats.ingenuityExtra or 0),
  }
end

-- Concentration to craft at `skill`: nil without a curve, 0 when the skill already makes the top quality.
local function concentrationAt(ctx, skill)
  if ctx.curve == nil then return nil end
  local q = Math.Quality.Predict(skill, ctx.difficulty, ctx.input.maxQuality, ctx.input.thresholdFractions)
  if q >= (ctx.input.maxQuality or 1) then return 0 end
  return Math.Concentration.Cost(ctx.curve, skill, ctx.difficulty, ctx.less)
end

-- One plan's money. requiredCost nil = some required reagent has no price.
local function makePlan(ctx, quality, allocation, requiredCost, skill, concentrated, concentrationCost)
  local stats = ctx.stats
  local reagentCost = requiredCost and ctx.optionalCost and requiredCost + ctx.optionalCost or nil
  local savable = requiredCost
  if savable and #ctx.unsavedSlots > 0 then
    savable = savable - (Math.Optimizer.AllocationCost(ctx.unsavedSlots, allocation) or 0)
  end
  local saving = savable and Math.Stats.ResourcefulnessSaving(savable, stats.resourcefulness, stats.resourcefulnessExtra)
  local price = (ctx.input.outputPrices or {})[quality]
  local expectedSale = Profit.ExpectedSale({ [quality] = 1 }, ctx.input.outputPrices, ctx.expectedYield)
  local profit = expectedSale and reagentCost and Round(expectedSale - (reagentCost - saving)) or nil
  return {
    quality = quality,
    allocation = allocation,
    skill = skill,
    requiredCost = requiredCost and Round(requiredCost) or nil,
    reagentCost = reagentCost and Round(reagentCost) or nil,
    resourcefulnessValue = saving and Round(saving) or nil,
    expectedSale = expectedSale,
    profit = profit,
    multicraftValue = type(price) == "number" and Round(price * (ctx.expectedYield - ctx.baseYield) * Profit.AH_CUT) or nil,
    concentrated = concentrated or nil,
    concentrationCost = concentrationCost,
  }
end

-- The concentration plan built on plain plan p (which lands below the top quality).
local function concentrate(ctx, p)
  return makePlan(ctx, p.quality + 1, p.allocation, p.requiredCost, p.skill, true, concentrationAt(ctx, p.skill))
end

-- true when plan a should be chosen over plan b: priced beats unpriced, then more profit, then higher quality,
-- then no concentration spent.
local function better(a, b)
  if b == nil then return true end
  if a.profit and not b.profit then return true end
  if b.profit and not a.profit then return false end
  if a.profit and a.profit ~= b.profit then return a.profit > b.profit end
  if a.quality ~= b.quality then return a.quality > b.quality end
  return (not a.concentrated) and b.concentrated == true
end

local function bestOf(plans)
  local best
  for _, p in pairs(plans) do
    if better(p, best) then best = p end
  end
  return best
end

-- Builds the MathResult for `chosen`. `concPlan` is the concentration plan the concentration fields describe
-- (nil when there is none) and `plainBest` the plain plan goldPerConcentration compares it with.
local function result(ctx, chosen, concPlan, plainBest, perQuality, missingPrice, flags)
  local input = ctx.input
  local stats = ctx.stats
  local _, nextThreshold, lowerThreshold = Math.Quality.Predict(chosen.skill, ctx.difficulty, input.maxQuality, input.thresholdFractions)

  local concentrationCost, expectedConcentrationCost, ingenuityValue, goldPerConcentration
  if ctx.curve ~= nil then
    if concPlan and concPlan.concentrationCost then
      concentrationCost = concPlan.concentrationCost
      expectedConcentrationCost = Math.Concentration.Expected(concentrationCost, stats.ingenuity, ctx.refund)
      ingenuityValue = concentrationCost * (stats.ingenuity or 0) * ctx.refund
      if concPlan.profit and plainBest and plainBest.profit then
        goldPerConcentration = Math.Concentration.GoldPerPoint(concPlan.profit, plainBest.profit, expectedConcentrationCost)
      end
    else
      concentrationCost, expectedConcentrationCost, ingenuityValue = 0, 0, 0
    end
  end

  -- The chosen plan's own output price missing makes the result unpriced whatever else is known.
  if type((input.outputPrices or {})[chosen.quality]) ~= "number" then missingPrice = true end
  if chosen.reagentCost == nil then missingPrice = true end
  flags = flags or {}
  flags.noPrice = missingPrice
  if ctx.unknownOptional then flags.unknownOptional = true end

  return {
    expectedQuality = chosen.quality,
    qualityChances = { [chosen.quality] = 1 },
    skill = chosen.skill,
    difficulty = ctx.difficulty,
    thresholds = Math.Quality.Thresholds(input.maxQuality, ctx.difficulty, input.thresholdFractions) or {},
    lowerThreshold = lowerThreshold,
    nextThreshold = nextThreshold,
    allocation = chosen.allocation,
    reagentCost = chosen.reagentCost,
    requiredCost = chosen.requiredCost,
    expectedSale = chosen.expectedSale,
    profit = chosen.profit,
    concentrationCost = concentrationCost,
    expectedConcentrationCost = expectedConcentrationCost,
    goldPerConcentration = goldPerConcentration,
    ingenuityValue = ingenuityValue,
    concentrationCostForAllocation = concentrationAt(ctx, chosen.skill),
    multicraftValue = chosen.multicraftValue,
    resourcefulnessValue = chosen.resourcefulnessValue,
    expectedYield = ctx.expectedYield,
    perQuality = perQuality,
    missingPrice = missingPrice,
    flags = flags,
  }
end

local function perQualityEntry(p)
  return { allocation = p.allocation, reagentCost = p.reagentCost, skill = p.skill, profit = p.profit }
end

-- Expected profit of the best plan for `input` (RecipeInput). See the header for plans; the choice:
--   targetQuality set: that quality's plan (its concentration plan when useConcentration, else or when there is
--     none, its plain plan); when no plan of the allowed kinds lands on it, the plan for the highest reachable
--     quality, with flags.unreachableTarget = true.
--   otherwise the most profitable concentration plan when useConcentration (the plain one when no quality can
--     be concentrated), else the most profitable plain plan. Unpriced plans never beat priced ones.
-- Concentration fields describe the chosen plan when it uses concentration, otherwise the most profitable
-- concentration plan; goldPerConcentration compares it with the plain plan at targetQuality when there is one,
-- else with the most profitable plain plan. Without a curve
-- they are nil; with a curve and nothing to concentrate, 0 (goldPerConcentration nil).
-- missingPrice: a required slot or optional has no price, a plainly reachable quality's output has no price,
-- or the chosen plan's own output has no price. profit/expectedSale are nil only for the chosen plan's gaps.
function Profit.EvaluateCraft(input)
  local ctx = prepare(input)
  local optInput = {}
  for k, v in pairs(input) do optInput[k] = v end
  optInput.baseSkill, optInput.baseDifficulty, optInput.maxReagentSkill = ctx.skill, ctx.difficulty, ctx.maxReagentSkill

  local raw, slotMissing = Math.Optimizer.CheapestByQuality(optInput)
  local missingPrice = slotMissing or ctx.optionalCost == nil
  local plain, conc, perQuality = {}, {}, {}
  local maxQuality = input.maxQuality or 1
  for q, r in pairs(raw) do
    local p = makePlan(ctx, q, r.allocation, r.reagentCost, r.skill)
    plain[q], perQuality[q] = p, perQualityEntry(p)
    if type((input.outputPrices or {})[q]) ~= "number" then missingPrice = true end
    if q < maxQuality then conc[q + 1] = concentrate(ctx, p) end
  end

  local plainBest, concBest = bestOf(plain), bestOf(conc)
  local chosen
  local flags = {}
  local target = input.targetQuality
  if target then
    chosen = input.useConcentration and conc[target] or plain[target]
    if not chosen then
      local top = 0
      for q in pairs(plain) do top = math.max(top, q) end
      if input.useConcentration then
        for q in pairs(conc) do top = math.max(top, q) end
      end
      if top > 0 then
        chosen = bestOf({ plain[top], input.useConcentration and conc[top] or nil })
        flags.unreachableTarget = true
      end
    end
  else
    chosen = input.useConcentration and concBest or plainBest
  end
  if not chosen then
    -- Nothing reachable (no thresholds and no plans): an empty quality-1 plan, unpriced.
    chosen = makePlan(ctx, 1, {}, nil, ctx.skill)
    missingPrice = true
  end

  local concPlan = chosen.concentrated and chosen or concBest
  -- With a target, concentration is worth comparing with crafting that same quality plainly, when possible.
  local plainRef = target and plain[target] or plainBest
  return result(ctx, chosen, concPlan, plainRef, perQuality, missingPrice, flags)
end

-- Prediction for a given allocation (no optimisation): live prediction, golden fixtures and the self-check.
-- optionalItemIDs picks which of input.optionals are applied (nil = all of them); an ID input.optionals does not
-- list makes the cost unknown (reagentCost/profit nil, missingPrice) and sets flags.unknownOptional. With useConcentration the
-- allocation crafts one quality higher (capped at the top); skill and thresholds still describe the allocation.
-- The concentration fields describe concentrating this allocation.
function Profit.EvaluateAllocation(input, allocation, optionalItemIDs)
  local ctx = prepare(input, optionalItemIDs)
  allocation = allocation or {}
  local skill = ctx.skill + Math.Quality.ReagentSkill(input.slots, allocation, ctx.maxReagentSkill)
  local quality = Math.Quality.Predict(skill, ctx.difficulty, input.maxQuality, input.thresholdFractions)
  local requiredCost = Math.Optimizer.AllocationCost(input.slots, allocation)

  local plain = makePlan(ctx, quality, allocation, requiredCost, skill)
  local concPlan = quality < (input.maxQuality or 1) and concentrate(ctx, plain) or nil
  local chosen = input.useConcentration and concPlan or plain
  local missingPrice = requiredCost == nil or ctx.optionalCost == nil
    or type((input.outputPrices or {})[quality]) ~= "number"
  return result(ctx, chosen, concPlan, plain, { [quality] = perQualityEntry(plain) }, missingPrice, {})
end
