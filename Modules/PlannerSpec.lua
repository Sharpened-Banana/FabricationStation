local ADDON_NAME, ns = ...

-- PlannerSpec: specialization advice, on the Planner module object (Modules/Planner.lua creates it). Which next
-- spec node of a character's profession would earn the most, per knowledge point, on the character's most
-- profitable recipes?
--
-- For each path of the character's spec snapshot (Alts:GetSpecSnapshot, display ranks) PlanCalc.RankSpecNodes picks
-- the next step (next perk, else 5 ranks) and asks gainFn for its gain: the bonus of the ranks and perks crossed
-- (_nodeBonus, from 1a's SpecEntryEffects / RecipeLabels GameData; unlabelled entries apply to every recipe, labelled
-- ones only to recipes sharing a label) is applied as a what-if to each of the top
-- Settings().specTopRecipes profitable Recipes results it covers (_evaluateWithBonus = Recipes:Evaluate with
-- opts.extraStats, which 1b feeds through its own optional-reagent path), and the profit increases are summed.
--
-- What-if evaluations bypass Recipes' cache (paths × top recipes full optimiser runs), so GetSpecAdvice is computed
-- on demand only (never from a message handler) and memoised per character and line until its inputs change
-- (preflight row 30).
local Planner = ns.FS:GetModule("Planner")

local MAX_ROWS = 5

-- The stats the what-if models: what CraftingData.EFFECT_MAP can give today. Ingenuity has no mapping yet (1b Task 9
-- deferred, preflight row 28); once it has, adding "ingenuity" here is the only change (Recipes' extraStats and
-- Stats.ApplyOptionals already take it).
local STATS = { "skill", "multicraft", "resourcefulness" }
local IS_STAT = {}
for _, k in ipairs(STATS) do IS_STAT[k] = true end

local function is_finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

local function alts()
  local A = ns.FS:GetModule("Alts", true)
  if A and A:IsEnabled() then return A end
end

local function recipes()
  local R = ns.FS:GetModule("Recipes", true)
  if R and R:IsEnabled() then return R end
end

local function scanner() return ns.FS:GetModule("Scanner", true) end

local function spec_record(charKey, skillLineID)
  local S = scanner()
  local p = S and type(charKey) == "string" and S:GetProfession(charKey, skillLineID)
  if type(p) == "table" and not p.dropped then return p end
end

local function gd_table(name)
  local t = ns.GameData.Get(name)
  return type(t) == "table" and t or {}
end

---------------------------------------------------------------------------
-- Adapters
---------------------------------------------------------------------------

-- The entry's modelled effects (each × times) as { [stat] = amount } (only STATS mapped through
-- CraftingData.EFFECT_MAP; unmapped types are left out, as 1b does), and its labels as a set (nil when its labels
-- list is missing or empty: it applies to every recipe of the line, preflight row 29). nil for a non-table entry.
local function entry_parts(entry, times)
  if type(entry) ~= "table" then return nil end
  local map = ns.CraftingData and ns.CraftingData.EFFECT_MAP or {}
  local stats, any = {}, false
  for _, effect in ipairs(type(entry.effects) == "table" and entry.effects or {}) do
    local stat = type(effect) == "table" and map[effect.type]
    if stat and IS_STAT[stat] and is_finite(effect.amount) and effect.amount ~= 0 then
      stats[stat] = (stats[stat] or 0) + effect.amount * times
      any = true
    end
  end
  if not any then return nil end
  local labels
  if type(entry.labels) == "table" then
    for _, label in ipairs(entry.labels) do
      labels = labels or {}
      labels[label] = true
    end
  end
  return stats, labels
end

-- The bonus of raising pathID from fromRank to toRank (display ranks), as raw ProfessionEffect amounts:
--   { skill?, multicraft?, resourcefulness?   the sums of the contributing entries WITHOUT labels (every recipe)
--     scoped = { { skill?, multicraft?, resourcefulness?, labels = { [labelID] = true } } } | nil
--                                             one part per contributing entry WITH labels (recipes sharing a label)
--     recipes = { [recipeID] = true } | nil } coverage: nil when an unlabelled entry contributes (or none does),
--                                             else the recipes whose RecipeLabels share a label of a scoped part
-- The path's spend entry's SpecEntryEffects count once per rank ((toRank - fromRank) times; per-rank amounts are
-- unverified, see the in-game checklist), and each perk of the path with fromRank < unlockRank <= toRank adds its
-- entry's effects once. An entry contributes when it has a modelled effect (STATS). {} when the spec record, the
-- path or the data is missing.
function Planner:_nodeBonus(charKey, skillLineID, pathID, fromRank, toRank)
  local bonus = {}
  local p = spec_record(charKey, skillLineID)
  local spec = p and type(p.spec) == "table" and p.spec or {}
  local paths = type(spec.paths) == "table" and spec.paths or {}
  local path = type(paths[pathID]) == "table" and paths[pathID] or nil
  if not path or not is_finite(fromRank) or not is_finite(toRank) or toRank <= fromRank then return bonus end
  local E, unlabelled = gd_table("SpecEntryEffects"), false
  local function add(entryID, times)
    if entryID == nil then return end
    local stats, labels = entry_parts(E[entryID], times)
    if not stats then return end
    if labels then
      stats.labels = labels
      bonus.scoped = bonus.scoped or {}
      bonus.scoped[#bonus.scoped + 1] = stats
    else
      unlabelled = true
      for k, v in pairs(stats) do bonus[k] = (bonus[k] or 0) + v end
    end
  end
  add(path.spendEntryID, toRank - fromRank)
  for _, perk in pairs(type(spec.perks) == "table" and spec.perks or {}) do
    if type(perk) == "table" and perk.pathID == pathID and is_finite(perk.unlockRank)
        and perk.unlockRank > fromRank and perk.unlockRank <= toRank then
      add(perk.entryID, 1)
    end
  end
  if bonus.scoped and not unlabelled then
    local set = {}
    for recipeID, list in pairs(gd_table("RecipeLabels")) do
      for _, label in ipairs(type(list) == "table" and list or {}) do
        local hit = false
        for _, part in ipairs(bonus.scoped) do
          if part.labels[label] then hit = true; break end
        end
        if hit then set[recipeID] = true; break end
      end
    end
    bonus.recipes = set
  end
  return bonus
end

-- Recipes:Evaluate(recipeID, charKey, { extraStats = stats }): the what-if RecipeResult (nil without a schematic).
-- stats = the per-recipe { skill?, multicraft?, resourcefulness? } (only STATS are passed on).
function Planner:_evaluateWithBonus(recipeID, charKey, stats)
  local R = ns.FS:GetModule("Recipes", true)
  if not R then return nil end
  local extra = {}
  for _, k in ipairs(STATS) do extra[k] = stats[k] end
  return R:Evaluate(recipeID, charKey, { extraStats = extra })
end

---------------------------------------------------------------------------
-- Advice
---------------------------------------------------------------------------

local function nonzero(t)
  for _, k in ipairs(STATS) do
    if is_finite(t[k]) and t[k] ~= 0 then return true end
  end
  return false
end

-- Whether the bonus models any stat: its unlabelled sums or one of its scoped parts.
local function has_stat(bonus)
  if nonzero(bonus) then return true end
  for _, part in ipairs(type(bonus.scoped) == "table" and bonus.scoped or {}) do
    if type(part) == "table" and nonzero(part) then return true end
  end
  return false
end

-- The labels of one recipe as a list (RecipeLabels), or nil when it has no entry.
local function recipe_labels(recipeID)
  local list = gd_table("RecipeLabels")[recipeID]
  if type(list) == "table" then return list end
end

-- The bonus' stats for one recipe: the unlabelled sums plus every scoped part sharing one of the recipe's labels.
local function stats_for(bonus, labels)
  local out = {}
  for _, k in ipairs(STATS) do if is_finite(bonus[k]) then out[k] = bonus[k] end end
  for _, part in ipairs(type(bonus.scoped) == "table" and bonus.scoped or {}) do
    local applies = false
    for _, label in ipairs(labels or {}) do
      if type(part.labels) == "table" and part.labels[label] then applies = true; break end
    end
    if applies then
      for _, k in ipairs(STATS) do
        if is_finite(part[k]) then out[k] = (out[k] or 0) + part[k] end
      end
    end
  end
  return out
end

-- The character's top n profitable results on the line (Recipes' order: profit desc); results of another
-- character are dropped even if Recipes returned them.
local function top_results(R, charKey, skillLineID, n)
  local ranked = R:GetRanked({ charKey = charKey, skillLineID = skillLineID, onlyProfitable = true, sortBy = "profit" })
  local out = {}
  for _, r in ipairs(type(ranked) == "table" and ranked or {}) do
    if #out >= n then break end
    if type(r) == "table" and r.charKey == charKey and is_finite(r.profit) then out[#out + 1] = r end
  end
  return out
end

local function candidates(snapshot)
  local out = {}
  for pathID, path in pairs(type(snapshot.paths) == "table" and snapshot.paths or {}) do
    if type(path) == "table" then
      out[#out + 1] = { pathID = pathID, name = path.name, rank = path.rank, maxRank = path.maxRank,
        available = path.available, perkRanks = path.perkRanks }
    end
  end
  return out
end

-- The memo key: everything the advice is computed from. Result tables are compared by identity (a Recipes rescan or
-- re-evaluation makes new ones); the data stamp and price version cover what the what-if evaluations read.
local function memo_key(R, charKey, snapshot, top, n)
  local parts = { tostring(n), tostring(snapshot.unspent) }
  if type(R.GetDataStamp) == "function" then parts[#parts + 1] = tostring(R:GetDataStamp(charKey)) end
  local P = ns.FS:GetModule("Prices", true)
  if P and type(P.GetVersion) == "function" then parts[#parts + 1] = tostring(P:GetVersion()) end
  parts[#parts + 1] = tostring(ns.GameData.Get("SpecEntryEffects"))
  parts[#parts + 1] = tostring(ns.GameData.Get("RecipeLabels"))
  for _, r in ipairs(top) do parts[#parts + 1] = tostring(r) .. "=" .. tostring(r.profit) end
  local ids = {}
  for _, c in ipairs(candidates(snapshot)) do ids[#ids + 1] = c.pathID end
  table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
  for _, id in ipairs(ids) do
    local path = snapshot.paths[id]
    -- The memo key is a cache signature of the spec data; none of it is shown.
    parts[#parts + 1] = table.concat({ tostring(id), tostring(path.rank), tostring(path.maxRank),
      tostring(path.available), table.concat(path.perkRanks or {}, ",") }, ":")
  end
  return table.concat(parts, "|")
end

local memo = {}   -- [charKey .. "|" .. skillLineID] = { key, rows }

-- { SpecAdviceRow } (PlanCalc.RankSpecNodes, at most 5): the next step on each available path of the character's
-- spec, ranked by profit gain per knowledge point. gain = Σ over the top Settings().specTopRecipes profitable results
-- of (charKey, skillLineID) that the step's bonus covers of max(0, what-if profit − plain profit), the what-if using
-- the unlabelled stats plus the scoped parts sharing a label with that recipe (a what-if without a profit counts as
-- no change; the plain profit is the cached Recipes:Evaluate(id, charKey, {}), else the ranked profit). A bonus
-- without a modelled stat (no SpecEntryEffects data, or only effects 1b does not map, such as ingenuity), or a
-- labelled-only bonus when none of the top recipes has RecipeLabels, gives an unknown gain: gain/gainPerPoint nil,
-- sorted after the known ones (UIs show "?"); a known gain <= 0 is dropped. Rows are memoised (shared, read-only)
-- until the inputs change.
-- Second return, a status the view shows instead of an empty list (design rule 6):
--   "off"          Alts or Recipes is missing or turned off ({}).
--   "hidden"       the character is hidden ({}).
--   "noProfession" no record, or only a dropped one, for the character and line; also an unknown character ({}).
--   "noSpec"       the record has no spec snapshot yet ({}; the view says "open this profession on <character>").
--   "noRecipes"    no profitable result for the character and line ({}; no prices, or the scan has not run).
--   "ok"           the rows; {} then means no path has a step left or none would earn more.
-- Like every Planner getter it ignores Planner's own enabled state: the Planner tab checks Planner:IsEnabled() itself.
-- Never call it from a message handler: it can run paths × specTopRecipes uncached evaluations.
function Planner:GetSpecAdvice(charKey, skillLineID)
  local A, R = alts(), recipes()
  if not A or not R then return {}, "off" end
  local hidden = A:Settings().hidden
  if charKey ~= nil and type(hidden) == "table" and hidden[charKey] == true then return {}, "hidden" end
  if not spec_record(charKey, skillLineID) then return {}, "noProfession" end
  local snapshot = A:GetSpecSnapshot(charKey, skillLineID)
  if type(snapshot) ~= "table" then return {}, "noSpec" end
  local n = self:Settings().specTopRecipes
  local top = top_results(R, charKey, skillLineID, n)
  if #top == 0 then return {}, "noRecipes" end

  local slot = tostring(charKey) .. "|" .. tostring(skillLineID)
  local key = memo_key(R, charKey, snapshot, top, n)
  local hit = memo[slot]
  if hit and hit.key == key then return hit.rows, "ok" end

  -- Unknown (nil) when the bonus models no stat, or when it is limited to labelled recipes but none of the top
  -- recipes has a RecipeLabels entry (the labels are missing, not known to differ). The baseline is the cached plain
  -- evaluation (falling back to the ranked profit), so a price change since the last scan is not counted as gain.
  local function gainFn(pathID, fromRank, toRank)
    local bonus = self:_nodeBonus(charKey, skillLineID, pathID, fromRank, toRank)
    if type(bonus) ~= "table" or not has_stat(bonus) then return nil end
    local labelsOf, anyLabels = {}, false
    for _, r in ipairs(top) do
      labelsOf[r] = recipe_labels(r.recipeID)
      if labelsOf[r] then anyLabels = true end
    end
    if bonus.recipes ~= nil and type(bonus.scoped) == "table" and #bonus.scoped > 0 and not anyLabels then
      return nil
    end
    local gain = 0
    for _, r in ipairs(top) do
      if bonus.recipes == nil or bonus.recipes[r.recipeID] then
        local stats = stats_for(bonus, labelsOf[r])
        if nonzero(stats) then
          local plain = R:Evaluate(r.recipeID, charKey, {})
          local base = type(plain) == "table" and is_finite(plain.profit) and plain.profit or r.profit
          local what = self:_evaluateWithBonus(r.recipeID, charKey, stats)
          local profit = type(what) == "table" and is_finite(what.profit) and what.profit or base
          gain = gain + math.max(0, profit - base)
        end
      end
    end
    return gain
  end

  local ranked = ns.PlanCalc.RankSpecNodes(candidates(snapshot), gainFn, snapshot.unspent)
  local rows = {}
  for i = 1, math.min(MAX_ROWS, #ranked) do rows[i] = ranked[i] end
  -- top is kept so the result tables named in the key stay alive (their addresses cannot be reused by new ones).
  memo[slot] = { key = key, rows = rows, top = top }
  return rows, "ok"
end
