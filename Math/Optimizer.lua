-- Math.Optimizer: cheapest mix of required-reagent quality ranks for each reachable quality.
-- Pure Lua 5.1: no WoW globals, no ns.FS. Plain tables in, plain tables out.
-- Formula reference: CraftSim (MIT, github.com/derfloh205/CraftSim) Modules/ReagentOptimization/ReagentOptimization.lua
--
-- Each slot's rank mixes ("compositions") are enumerated and the cheapest kept per unit count, where a slot's
-- units are sum(2 * RankFactor(rank) * n): 2 ranks give {0, 2} per item, 3 ranks {0, 1, 2}. A knapsack over the
-- slots (unit counts scaled by weight / GCD of the weights) gives the cheapest cost for every reachable weighted
-- unit total u; reagent skill is maxReagentSkill * u / Umax, the same value Quality.ReagentSkill gives.
-- Every composition uses exactly the slot's quantity, so reagent skill never exceeds maxReagentSkill.
local ADDON_NAME, ns = ...

ns.Math = ns.Math or {}
local Math = ns.Math

local Optimizer = {}
Math.Optimizer = Optimizer

-- The slot's items sorted by rank, each with its unit value 2 * RankFactor.
local function rankedItems(slot)
  local list = {}
  local items = slot.items or {}
  for i, item in ipairs(items) do list[#list + 1] = { item = item, rank = item.rank or i } end
  table.sort(list, function(a, b) return a.rank < b.rank end)
  for _, e in ipairs(list) do e.uv = 2 * Math.Quality.RankFactor(e.rank, #list) end
  return list
end

-- A slot gives skill only with a positive weight and more than one rank.
local function isFixed(slot)
  return (slot.weight or 0) <= 0 or #(slot.items or {}) <= 1
end

-- Calls visit(counts) for every way to fill the slot's quantity from its ranks (counts[i] for list[i]).
-- Provided reagents (crafting orders) are a lower bound per rank; when they cover the quantity they fix the
-- slot, taken from the top rank down.
local function enumerate(list, quantity, visit)
  local n = #list
  if n == 0 then return end
  local lb, suffix = {}, {}
  for i, e in ipairs(list) do lb[i] = math.max(0, e.item.provided or 0) end
  suffix[n + 1] = 0
  for i = n, 1, -1 do suffix[i] = suffix[i + 1] + lb[i] end
  local counts = {}
  if suffix[1] >= quantity then
    local left = quantity
    for i = n, 1, -1 do counts[i] = math.min(lb[i], left); left = left - counts[i] end
    visit(counts)
    return
  end
  local function fill(i, left)
    if i == n then
      counts[i] = left
      visit(counts)
      return
    end
    for c = lb[i], left - suffix[i + 1] do
      counts[i] = c
      fill(i + 1, left - c)
    end
  end
  fill(1, quantity)
end

-- Copper cost and units of one composition; cost nil when it buys an item that has no price.
local function costAndUnits(list, counts)
  local cost, units = 0, 0
  for i, e in ipairs(list) do
    local n = counts[i] or 0
    local buy = n - (e.item.owned or 0) - (e.item.provided or 0)
    if buy > 0 then
      if type(e.item.price) ~= "number" then return nil, nil end
      cost = cost + buy * e.item.price
    end
    units = units + e.uv * n
  end
  return cost, units
end

local function rankCounts(list, counts)
  local out = {}
  for i, e in ipairs(list) do
    if (counts[i] or 0) > 0 then out[e.rank] = counts[i] end
  end
  return out
end

-- { [units] = { cost, counts = {[rank] = n} } }: the cheapest composition per unit count.
-- units = sum(2 * RankFactor(rank) * n) before weighting; cost = sum(max(0, n - owned - provided) * price).
-- An item with no price is usable only up to owned + provided. A slot with one item or weight 0 gets a single
-- composition (its cheapest) at 0 units. {} when nothing is usable.
function Optimizer.Compositions(slot)
  local out = {}
  local list = rankedItems(slot)
  local fixed = isFixed(slot)
  enumerate(list, slot.quantity or 0, function(counts)
    local cost, units = costAndUnits(list, counts)
    if cost == nil then return end
    cost = Math.Round(cost)
    if fixed then units = 0 end
    local cur = out[units]
    if cur == nil or cost < cur.cost then out[units] = { cost = cost, counts = rankCounts(list, counts) } end
  end)
  return out
end

-- Fill for a slot with no usable composition (every option buys an unpriced item): provided and owned
-- reagents first (top rank down), the rest at the lowest rank. Its cost is unknown (nil).
local function fallbackComposition(slot)
  local list = rankedItems(slot)
  local counts, left = {}, slot.quantity or 0
  for i = #list, 1, -1 do
    local have = math.max(0, (list[i].item.owned or 0) + (list[i].item.provided or 0))
    counts[i] = math.min(have, left)
    left = left - counts[i]
  end
  if list[1] then counts[1] = counts[1] + left end
  local units = 0
  if not isFixed(slot) then
    for i, e in ipairs(list) do units = units + e.uv * counts[i] end
  end
  return units, { cost = nil, counts = rankCounts(list, counts) }
end

local function gcd(a, b)
  while b ~= 0 do a, b = b, a % b end
  return a
end

local function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

-- input: RecipeInput (maxQuality, baseDifficulty, baseSkill, maxReagentSkill|nil, thresholdFractions|nil, slots).
-- Returns perQuality, missingPrice:
--   perQuality[q] = { allocation = { {slotIndex, itemID, quantity}... }, reagentCost = copper|nil, skill,
--                     missingPrice = true|nil } for each quality some allocation lands on (others absent).
--   A plan is the cheapest allocation whose predicted quality is exactly q (ties: more skill), so a plan's
--   skill never already reaches q + 1. Allocation rows are in slot order then rank order, zero counts left out.
--   missingPrice is true when a required slot has no priced option; that slot is then filled with what is
--   owned/provided plus its lowest rank, and every plan has reagentCost nil and missingPrice = true.
-- maxReagentSkill nil -> Quality.DEFAULT_REAGENT_SKILL_FACTOR * baseDifficulty. Thresholds come from
-- baseDifficulty: a caller adding difficulty from optionals passes the total there and maxReagentSkill resolved.
function Optimizer.CheapestByQuality(input)
  local Quality = Math.Quality
  local slots = input.slots or {}
  local baseSkill = input.baseSkill or 0
  local baseDifficulty = input.baseDifficulty or 0
  local maxReagentSkill = input.maxReagentSkill or Quality.DEFAULT_REAGENT_SKILL_FACTOR * baseDifficulty
  local thresholds = Quality.Thresholds(input.maxQuality, baseDifficulty, input.thresholdFractions) or {}

  -- Weights divided by their GCD keep the unit totals small; non-integer weights are used as they are.
  local g = 0
  for _, s in ipairs(slots) do
    local w = s.weight or 0
    if w > 0 then
      if w ~= math.floor(w) then g = -1; break end
      g = gcd(g, w)
    end
  end
  if g <= 0 then g = 1 end

  local prepared, umax, missingPrice = {}, 0, false
  for i, s in ipairs(slots) do
    local w = (s.weight or 0) > 0 and s.weight / g or 0
    umax = umax + (s.quantity or 0) * 2 * w
    local comps = Optimizer.Compositions(s)
    if next(comps) == nil then
      local units, comp = fallbackComposition(s)
      comps = { [units] = comp }
      missingPrice = true
    end
    prepared[i] = { slot = s, w = w, comps = comps, keys = sortedKeys(comps) }
  end

  -- Knapsack: best[u] = cheapest known cost reaching exactly u weighted units; choice[i][u] rebuilds it.
  -- An unknown (fallback) cost counts as 0 here; such a slot has one composition, so it is in every plan.
  local best, choice = { [0] = 0 }, {}
  for i, p in ipairs(prepared) do
    local nb, pick = {}, {}
    for _, u in ipairs(sortedKeys(best)) do
      local c = best[u]
      for _, cu in ipairs(p.keys) do
        local comp = p.comps[cu]
        local nu, nc = u + cu * p.w, c + (comp.cost or 0)
        if nb[nu] == nil or nc < nb[nu] then nb[nu], pick[nu] = nc, { prev = u, comp = comp } end
      end
    end
    best, choice[i] = nb, pick
  end

  -- Classify every reachable total by the quality its skill predicts (skill >= threshold, as Quality.Predict).
  local chosen = {}
  for _, u in ipairs(sortedKeys(best)) do
    local c = best[u]
    local skill = baseSkill + (umax > 0 and maxReagentSkill * u / umax or 0)
    local q = 1
    for _, t in ipairs(thresholds) do
      if skill >= t then q = q + 1 end
    end
    local cur = chosen[q]
    if cur == nil or c < cur.cost or (c == cur.cost and u > cur.u) then
      chosen[q] = { u = u, cost = c, skill = skill }
    end
  end

  local perQuality = {}
  for q, pick in pairs(chosen) do
    local comps, u = {}, pick.u
    for i = #prepared, 1, -1 do
      local step = choice[i][u]
      comps[i], u = step.comp, step.prev
    end
    local allocation = {}
    for i, p in ipairs(prepared) do
      for _, e in ipairs(rankedItems(p.slot)) do
        local n = comps[i].counts[e.rank]
        if n and n > 0 then
          allocation[#allocation + 1] = { slotIndex = p.slot.slotIndex, itemID = e.item.itemID, quantity = n }
        end
      end
    end
    perQuality[q] = {
      allocation = allocation,
      reagentCost = (not missingPrice) and Math.Round(pick.cost) or nil,
      skill = pick.skill,
      missingPrice = missingPrice or nil,
    }
  end
  return perQuality, missingPrice
end

-- Copper to buy what `allocation` uses beyond owned + provided, priced per item; nil when that needs an item
-- with no price or names an item the slot does not list. Rows for slots not in `slots` are ignored.
function Optimizer.AllocationCost(slots, allocation)
  local bySlot = {}
  for _, s in ipairs(slots or {}) do bySlot[s.slotIndex] = s end
  local used = {}
  for _, row in ipairs(allocation or {}) do
    if bySlot[row.slotIndex] then
      local t = used[row.slotIndex]
      if not t then t = {}; used[row.slotIndex] = t end
      t[row.itemID] = (t[row.itemID] or 0) + (row.quantity or 0)
    end
  end
  local total = 0
  for slotIndex, t in pairs(used) do
    local byID = {}
    for _, item in ipairs(bySlot[slotIndex].items or {}) do byID[item.itemID] = item end
    for itemID, n in pairs(t) do
      local item = byID[itemID]
      if not item then return nil end
      local buy = n - (item.owned or 0) - (item.provided or 0)
      if buy > 0 then
        if type(item.price) ~= "number" then return nil end
        total = total + buy * item.price
      end
    end
  end
  return Math.Round(total)
end
