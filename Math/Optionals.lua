-- Math.Optionals: which optional and finishing reagents to add to a craft for the most profit.
-- Pure Lua 5.1: no WoW globals, no ns.FS. Plain tables in, plain tables out.
--
-- Best(input, opts) works on a RecipeInput whose optionalSlots list the slots that may take an optional
-- (CraftingData.BuildInput with optionalItemIDs) and whose optionals describe their items. Every pick is valued with
-- Profit.EvaluateCraft on a shallow copy of the input holding only the picked optionals.
local ADDON_NAME, ns = ...

ns.Math = ns.Math or {}
local Math = ns.Math

local Optionals = {}
Math.Optionals = Optionals

Optionals.MAX_COMBINATIONS = 64

-- Whether a stats table has at least one non-zero number.
local function has_effect(stats)
  if type(stats) ~= "table" then return false end
  for _, v in pairs(stats) do
    if type(v) == "number" and v ~= 0 then return true end
  end
  return false
end

-- true when pick a (sorted itemIDs ids, MathResult r) beats pick b: a number profit beats nil, a higher profit
-- wins, then fewer items, then the smaller sorted itemID list.
local function better(aIDs, a, bIDs, b)
  if b == nil then return true end
  local pa, pb = a.profit, b.profit
  if type(pa) == "number" and type(pb) ~= "number" then return true end
  if type(pb) == "number" and type(pa) ~= "number" then return false end
  if type(pa) == "number" and pa ~= pb then return pa > pb end
  if #aIDs ~= #bIDs then return #aIDs < #bIDs end
  for i = 1, #aIDs do
    if aIDs[i] ~= bIDs[i] then return aIDs[i] < bIDs[i] end
  end
  return false
end

local function sorted_ids(entries)
  local ids = {}
  for i, e in ipairs(entries) do ids[i] = e.itemID end
  table.sort(ids)
  return ids
end

local function contains(entries, itemID)
  for _, e in ipairs(entries) do
    if e.itemID == itemID then return true end
  end
  return false
end

local function with(entries, extra)
  local out = {}
  for i, e in ipairs(entries) do out[i] = e end
  out[#out + 1] = extra
  return out
end

-- OptionalsResult = { itemIDs (sorted), result = MathResult, base = MathResult, mode = "simple"|"permutation",
-- evaluated (EvaluateCraft calls, the base included), skipped = { unknownPrice, noEffect } }.
-- opts = { mode = "simple"|"permutation" (default "simple"), maxCombinations = 64 }.
-- Candidates per slot: its items whose optionals entry has a number price and a stats table with a non-zero value;
-- the others are counted once per itemID (no price first, then no modelled effect). "permutation" tries every
-- combination of at most one item per slot when prod(1 + #candidates) <= maxCombinations, else it runs "simple" and
-- says so; "simple" goes through the slots in order and keeps, for each, the best of "the current pick plus one
-- candidate" when it beats the current pick. An item is never picked twice. A base without a profit is returned as
-- the result (nothing can be ranked). The input is not changed.
function Optionals.Best(input, opts)
  opts = opts or {}
  local maxCombinations = type(opts.maxCombinations) == "number" and opts.maxCombinations or Optionals.MAX_COMBINATIONS

  local byID = {}
  for _, opt in ipairs(input.optionals or {}) do
    if opt.itemID ~= nil and byID[opt.itemID] == nil then byID[opt.itemID] = opt end
  end

  local skipped, counted = { unknownPrice = 0, noEffect = 0 }, {}
  local slots = {}
  for _, slot in ipairs(input.optionalSlots or {}) do
    local candidates = {}
    for _, itemID in ipairs(slot.itemIDs or {}) do
      local opt = byID[itemID]
      if opt and type(opt.price) == "number" and has_effect(opt.stats) then
        candidates[#candidates + 1] = opt
      elseif not counted[itemID] then
        counted[itemID] = true
        if not opt or type(opt.price) ~= "number" then
          skipped.unknownPrice = skipped.unknownPrice + 1
        else
          skipped.noEffect = skipped.noEffect + 1
        end
      end
    end
    if #candidates > 0 then slots[#slots + 1] = candidates end
  end

  local combinations = 1
  for _, candidates in ipairs(slots) do combinations = combinations * (1 + #candidates) end
  local mode = (opts.mode == "permutation" and combinations <= maxCombinations) and "permutation" or "simple"

  local evaluated = 0
  local function evaluate(picked)
    local copy = {}
    for k, v in pairs(input) do copy[k] = v end
    copy.optionals = picked
    evaluated = evaluated + 1
    return Math.Profit.EvaluateCraft(copy)
  end

  local base = evaluate({})
  local bestPick, bestIDs, best = {}, {}, base
  if type(base.profit) == "number" then
    if mode == "permutation" then
      local function walk(i, picked)
        if i > #slots then
          if #picked == 0 then return end
          local ids = sorted_ids(picked)
          local r = evaluate(picked)
          if better(ids, r, bestIDs, best) then bestIDs, best = ids, r end
          return
        end
        walk(i + 1, picked)
        for _, c in ipairs(slots[i]) do
          if not contains(picked, c.itemID) then walk(i + 1, with(picked, c)) end
        end
      end
      walk(1, {})
    else
      for _, candidates in ipairs(slots) do
        local slotPick, slotIDs, slotBest
        for _, c in ipairs(candidates) do
          if not contains(bestPick, c.itemID) then
            local picked = with(bestPick, c)
            local ids = sorted_ids(picked)
            local r = evaluate(picked)
            if better(ids, r, slotIDs, slotBest) then slotPick, slotIDs, slotBest = picked, ids, r end
          end
        end
        if slotBest and better(slotIDs, slotBest, bestIDs, best) then
          bestPick, bestIDs, best = slotPick, slotIDs, slotBest
        end
      end
    end
  end

  return { itemIDs = bestIDs, result = best, base = base, mode = mode, evaluated = evaluated, skipped = skipped }
end
