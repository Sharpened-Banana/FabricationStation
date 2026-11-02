local ADDON_NAME, ns = ...
local L = ns.L

-- Recipes: crafting settings, per-character calibration, recipe evaluation (Evaluate, PredictLive) and
-- lookups (WhoCanCraft, FindRecipesForItem). A calibration records what the game
-- reports for the current character's recipe (base skill, the skill full top-rank reagents add,
-- difficulty, bonus stats) so recipes can later be evaluated for any character without the
-- profession window open. Calibration runs automatically when a recipe is selected in Blizzard's
-- Professions frame. Nothing is written while the saved data is from a newer version
-- (ns.FS.dbIsNewer).
local Recipes = ns.FS:NewModule("Recipes", "AceEvent-3.0")
Recipes.coreModule = true

Recipes.DEFAULTS = {
  staleCalibrationDays = 14,
  queueUseWarband = true,
  tooltipCraftCost = true,
  -- Off until the in-game taint check of the profession panel's Apply has passed (phase 1b in-game checklist).
  applyWritesBlizzardSlots = false,
  selfCheck = true,
  scanBudgetMs = 4,
  -- Restock targets count mail attachments and the player's own auction listings as held.
  restockCountMail = true,
  restockCountListed = true,
  -- Which optional and finishing reagents BestOptionals tries: "off", "simple" (one slot at a time) or "permutation"
  -- (every combination, up to Math.Optionals.MAX_COMBINATIONS; more falls back to "simple").
  optionalMode = "simple",
}

-- bonusStatName -> stat key, for Math.Stats.ParseBonusStats. enUS only: other client languages get
-- no bonus stats until their names are added here (known limitation; keep the names in this table).
Recipes.STAT_NAMES = { multicraft = "Multicraft", resourcefulness = "Resourcefulness", ingenuity = "Ingenuity" }

local RECIPE_SELECTED = "ProfessionsRecipeListMixin.Event.OnRecipeSelected"
local PROFESSIONS_ADDON = "Blizzard_Professions"

local stamps = {}          -- [charKey] = integer, bumped when that character's data changes
local settingsVersion = 0  -- bumped on every crafting setting change; part of every data stamp
local attached = false     -- the recipe-selection callback is registered (once per session)

local itemStamps = {}      -- [charKey] = integer, bumped on every "items" message for that character
local warbandStamp = 0     -- bumped on every "warband" message
local cache = {}           -- [cacheKey] = { stamp, itemStamp|nil, day, schematic, build, time, result }
local cachePriceVersion    -- Prices:GetVersion() the cache entries were computed with
local bestCache = {}       -- BestOptionals: [cacheKey] = { stamp, itemStamp|nil, day, schematic, build, time, best|false }
local bestPriceVersion     -- Prices:GetVersion() the bestCache entries were computed with
local itemIndex            -- [itemID] = { { recipeID, quality } }; nil = rebuild on the next lookup

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function global()
  return ns.FS.db and ns.FS.db.global
end

local function writable()
  return global() ~= nil and not ns.FS.dbIsNewer
end

local function scanner()
  return ns.FS:GetModule("Scanner")
end

local function prices()
  return ns.FS:GetModule("Prices")
end

-- 1a's costing setting: owned reagents cost nothing.
function Recipes:IsOwnedReagentsFree()
  local g = global()
  local costing = g and g.settings and g.settings.costing
  return costing and costing.ownedReagentsFree and true or false
end

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

-- settings.crafting[key] when stored (false included), else the default.
function Recipes:GetSetting(key)
  local g = global()
  local stored = g and g.settings and g.settings.crafting
  local value = stored and stored[key]
  if value == nil then return self.DEFAULTS[key] end
  return value
end

-- Stores settings.crafting[key] (created lazily). A change moves every data stamp, so cached
-- evaluations that depend on settings are recomputed.
local function set_setting(key, value)
  if not writable() then return end
  local s = global().settings
  s.crafting = s.crafting or {}
  if s.crafting[key] == value then return end
  s.crafting[key] = value
  settingsVersion = settingsVersion + 1
  -- RecipeScan's hook: results computed under the old setting are stale.
  if Recipes.OnCraftingSettingChanged then Recipes:OnCraftingSettingChanged(key) end
end

local function toggle(order, key, name)
  return {
    type = "toggle", order = order, width = "full", name = name,
    get = function() return Recipes:GetSetting(key) and true or false end,
    set = function(_, value) set_setting(key, value and true or false) end,
  }
end

local function range(order, key, name, min, max)
  return {
    type = "range", order = order, name = name, min = min, max = max, step = 1,
    get = function() return Recipes:GetSetting(key) end,
    set = function(_, value) set_setting(key, value) end,
  }
end

local function choice(order, key, name, values, sorting)
  return {
    type = "select", order = order, width = "double", name = name, values = values, sorting = sorting,
    get = function() return Recipes:GetSetting(key) end,
    set = function(_, value) set_setting(key, value) end,
  }
end

local function build_options()
  return {
    type = "group", name = L["Crafting"], order = 30,
    args = {
      staleCalibrationDays = range(1, "staleCalibrationDays", L["Treat a recipe calibration as old after (days)"], 1, 60),
      queueUseWarband = toggle(2, "queueUseWarband", L["Use reagents in the warband bank for the queue"]),
      tooltipCraftCost = toggle(3, "tooltipCraftCost", L["Show the cost to craft in item tooltips"]),
      applyWritesBlizzardSlots = toggle(4, "applyWritesBlizzardSlots",
        L["Apply fills the reagent slots in Blizzard's crafting window"]),
      selfCheck = toggle(5, "selfCheck", L["Check predictions against the game while the profession window is open"]),
      scanBudgetMs = range(6, "scanBudgetMs", L["Recipe scan time per frame (ms)"], 1, 16),
      restockCountMail = toggle(7, "restockCountMail", L["Count items in mail as held for restock targets"]),
      restockCountListed = toggle(8, "restockCountListed", L["Count my auction listings as held for restock targets"]),
      optionalMode = choice(9, "optionalMode", L["Optional reagents"], {
        off = L["Off"], simple = L["One slot at a time"], permutation = L["Every combination (up to 64)"],
      }, { "off", "simple", "permutation" }),
    },
  }
end

---------------------------------------------------------------------------
-- Data stamps
---------------------------------------------------------------------------

-- An integer that changes whenever the character's crafting data or a crafting setting changes.
function Recipes:GetDataStamp(charKey)
  return (stamps[charKey] or 0) + settingsVersion
end

local function bump_stamp(charKey)
  stamps[charKey] = (stamps[charKey] or 0) + 1
end

-- Every known character's stamp: the scanned characters and any stamped so far.
local function bump_every_stamp()
  local done = {}
  for _, charKey in ipairs(scanner():GetCharacters() or {}) do
    done[charKey] = true
    bump_stamp(charKey)
  end
  for charKey in pairs(stamps) do
    if not done[charKey] then bump_stamp(charKey) end
  end
end

-- FS_DATA_CHANGED(charKey, kind): owned counts only change results while owned reagents are free, so
-- "items" (that character) and "warband" (account-wide: every character) bump stamps only then;
-- "concentration" (the amount the character has), "moxie", "cooldowns" and "mail" (attachments, a phase 7 count
-- other modules read) never do: Evaluate reads none of them.
-- Every other kind bumps the character's stamp. Item stamps always move, for results computed with
-- opts.ownedReagentsFree = true while the setting is off. "recipes" also marks the item index dirty.
local function on_data_changed(_, charKey, kind)
  if kind == "concentration" or kind == "cooldowns" or kind == "moxie" or kind == "mail" then return end
  if kind == "items" then
    if charKey == nil then return end
    itemStamps[charKey] = (itemStamps[charKey] or 0) + 1
    if Recipes:IsOwnedReagentsFree() then bump_stamp(charKey) end
  elseif kind == "warband" then
    warbandStamp = warbandStamp + 1
    if Recipes:IsOwnedReagentsFree() then bump_every_stamp() end
  else
    if kind == "recipes" then itemIndex = nil end
    if charKey ~= nil then bump_stamp(charKey) end
  end
end

---------------------------------------------------------------------------
-- Calibration
---------------------------------------------------------------------------

function Recipes:GetCalibration(charKey, recipeID)
  local g = global()
  local byChar = g and g.recipeCalib and g.recipeCalib[charKey]
  return byChar and byChar[recipeID]
end

-- Every basic slot with two or more reagents, filled with its last (top-rank) reagent.
local function top_rank_allocation(schematic)
  local allocation = {}
  for _, slot in ipairs(schematic.reagentSlots or {}) do
    local reagents = slot.reagents or {}
    if slot.kind == "basic" and #reagents >= 2 then
      allocation[#allocation + 1] = { slotIndex = slot.slotIndex, itemID = reagents[#reagents], quantity = slot.quantity }
    end
  end
  return allocation
end

local function total_skill(info)
  return info.baseSkill + (info.bonusSkill or 0)
end

-- A fraction cut to 12 significant digits (the game's thresholds are whole skill points over the difficulty).
local function fraction(x)
  return tonumber(string.format("%.12g", x))
end

-- Records into `out` ([tier index] = fraction of the difficulty; tier index i is the threshold of quality i + 1)
-- the thresholds one operation info reports: lowerSkillThreshold starts its craftingQuality, upperSkillTreshold
-- (sic, the game's field name) starts the next one. Nothing for a missing or non-positive value, a quality outside
-- 1..maxQuality or a missing difficulty.
local function collect_thresholds(out, info, maxQuality)
  local q = info.craftingQuality
  local difficulty = (info.baseDifficulty or 0) + (info.bonusDifficulty or 0)
  if type(q) ~= "number" or type(maxQuality) ~= "number" or difficulty <= 0 then return end
  local lower, upper = info.lowerSkillThreshold, info.upperSkillTreshold
  if q > 1 and q <= maxQuality and type(lower) == "number" and lower > 0 then
    out[q - 1] = fraction(lower / difficulty)
  end
  if q >= 1 and q < maxQuality and type(upper) == "number" and upper > 0 then
    out[q] = fraction(upper / difficulty)
  end
end

local DAY = 86400

local function older_than(time, now, days)
  return type(time) ~= "number" or now - time > days * DAY
end

-- Whether two calibrations hold the same values (time aside).
local function same_values(a, b)
  if a.baseSkill ~= b.baseSkill or a.baseDifficulty ~= b.baseDifficulty or a.maxReagentSkill ~= b.maxReagentSkill
    or a.craftingDataID ~= b.craftingDataID then
    return false
  end
  for _, key in ipairs({ "stats", "thresholdFractions" }) do
    local ta, tb = type(a[key]) == "table" and a[key] or {}, type(b[key]) == "table" and b[key] or {}
    for k, v in pairs(ta) do if tb[k] ~= v then return false end end
    for k, v in pairs(tb) do if ta[k] ~= v then return false end end
  end
  return true
end

-- Calibrates recipeID for the current character from two live operation infos without
-- concentration: no reagents, and every quality slot at its top rank. thresholdFractions keeps the quality
-- thresholds both infos report, as fractions of the difficulty by tier index (nil when they report none); Evaluate
-- uses them before GameData's and the defaults. Returns the CalibRecord, or
-- nil when the recipe has no schematic or live data is unavailable (profession window closed).
-- The record is stored unless the saved data is from a newer version (then it is only returned). The
-- character's data stamp is bumped only when results can change: no previous record, a stored value
-- changed, or the previous record was old enough to flag staleData. Re-calibrating unchanged values keeps
-- every cached evaluation.
function Recipes:Calibrate(recipeID)
  local S = scanner()
  local schematic = S:GetSchematic(recipeID)
  if not schematic then return nil end
  local empty = S:GetLiveOperationInfo(recipeID, {}, false)
  if not empty or type(empty.baseSkill) ~= "number" then return nil end

  local baseSkill = total_skill(empty)
  local maxReagentSkill
  local thresholds = {}
  collect_thresholds(thresholds, empty, schematic.maxQuality)
  local allocation = top_rank_allocation(schematic)
  if #allocation > 0 then
    local top = S:GetLiveOperationInfo(recipeID, allocation, false)
    if not top or type(top.baseSkill) ~= "number" then return nil end
    maxReagentSkill = total_skill(top) - baseSkill
    collect_thresholds(thresholds, top, schematic.maxQuality)
  end

  local record = {
    time = ns.FS:Now(),
    baseSkill = baseSkill,
    baseDifficulty = empty.baseDifficulty,
    maxReagentSkill = maxReagentSkill,
    craftingDataID = empty.craftingDataID or schematic.craftingDataID,
    stats = ns.Math.Stats.ParseBonusStats(empty.bonusStats, self.STAT_NAMES),
    thresholdFractions = next(thresholds) ~= nil and thresholds or nil,
  }
  -- Newer saved data: the record is returned but not stored, so GetCalibration will not return it.
  if not writable() then return record end

  local charKey = ns.FS:CharKey()
  local g = global()
  g.recipeCalib = g.recipeCalib or {}
  g.recipeCalib[charKey] = g.recipeCalib[charKey] or {}
  local old = g.recipeCalib[charKey][recipeID]
  g.recipeCalib[charKey][recipeID] = record
  if type(old) ~= "table" or not same_values(old, record)
    or older_than(old.time, record.time, self:GetSetting("staleCalibrationDays")) then
    bump_stamp(charKey)
  end
  return record
end

---------------------------------------------------------------------------
-- Known recipes (dropped professions are skipped)
---------------------------------------------------------------------------

-- The character's profession records the character still has.
local function current_professions(charKey)
  local c = scanner():GetCharacter(charKey)
  local out = {}
  for skillLineID, p in pairs(c and c.professions or {}) do
    if type(p) == "table" and not p.dropped then out[skillLineID] = p end
  end
  return out
end

-- The profession record that knows recipeID (the schematic's skill line first), else the record of
-- that skill line (for its skill), else nil. Second return: whether the recipe is known.
local function find_profession(charKey, recipeID, skillLineID)
  local profs = current_professions(charKey)
  local own = skillLineID and profs[skillLineID]
  if own and own.recipes and own.recipes[recipeID] then return own, true end
  for _, p in pairs(profs) do
    if p.recipes and p.recipes[recipeID] then return p, true end
  end
  return own, false
end

-- Characters (sorted) with a current profession that knows recipeID.
function Recipes:WhoCanCraft(recipeID)
  local out = {}
  for _, charKey in ipairs(scanner():GetCharacters() or {}) do
    local _, known = find_profession(charKey, recipeID, nil)
    if known then out[#out + 1] = charKey end
  end
  table.sort(out)
  return out
end

---------------------------------------------------------------------------
-- Item lookup
---------------------------------------------------------------------------

local function build_item_index()
  local index = {}
  local g = global()
  for recipeID, schematic in pairs(g and g.schematics or {}) do
    for quality, itemID in pairs(type(schematic) == "table" and schematic.outputItemIDs or {}) do
      local list = index[itemID] or {}
      index[itemID] = list
      list[#list + 1] = { recipeID = recipeID, quality = quality }
    end
  end
  for _, list in pairs(index) do
    table.sort(list, function(a, b)
      if a.recipeID ~= b.recipeID then return a.recipeID < b.recipeID end
      return a.quality < b.quality
    end)
  end
  return index
end

-- { { recipeID, quality } } of every cached schematic crafting itemID, by recipeID then quality. The index
-- is rebuilt after FS_DATA_CHANGED "recipes" or FS_RECIPES_CHANGED (schematics are cached a chunk at a time
-- after a scan, so an index built in between can miss some until the next message).
function Recipes:FindRecipesForItem(itemID)
  itemIndex = itemIndex or build_item_index()
  local out = {}
  for i, e in ipairs(itemIndex[itemID] or {}) do out[i] = { recipeID = e.recipeID, quality = e.quality } end
  return out
end

---------------------------------------------------------------------------
-- Evaluation
---------------------------------------------------------------------------

-- Deterministic text for a cache key: tables recursively with keys sorted (by type, then value).
local function serialize(v)
  if type(v) ~= "table" then return type(v):sub(1, 1) .. tostring(v) end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta < tb end
    if ta == "number" or ta == "string" then return a < b end
    return tostring(a) < tostring(b)
  end)
  local parts = {}
  for i, k in ipairs(keys) do parts[i] = serialize(k) .. "=" .. serialize(v[k]) end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- The sorted, distinct number itemIDs of a list; nil when it is not a table or holds none.
local function sorted_item_ids(list)
  if type(list) ~= "table" then return nil end
  local out, seen = {}, {}
  for _, itemID in ipairs(list) do
    if type(itemID) == "number" and not seen[itemID] then
      seen[itemID] = true
      out[#out + 1] = itemID
    end
  end
  if #out == 0 then return nil end
  table.sort(out)
  return out
end

-- opts with defaults filled in: the cache key's opts and what the evaluation uses.
local function full_opts(opts)
  opts = opts or {}
  local provided = {}
  for itemID, n in pairs(type(opts.providedReagents) == "table" and opts.providedReagents or {}) do
    if type(n) == "number" and n > 0 then provided[itemID] = n end
  end
  local ownedFree = opts.ownedReagentsFree
  if ownedFree == nil then ownedFree = Recipes:IsOwnedReagentsFree() end
  ownedFree = ownedFree and true or false
  return {
    targetQuality = opts.targetQuality,
    useConcentration = opts.useConcentration and true or false,
    providedReagents = provided,
    ownedReagentsFree = ownedFree,
    -- Only owned counts read it: without owned reagents free it is always false (one cache entry).
    excludeWarband = ownedFree and opts.excludeWarband and true or false,
    -- [phase 7 Task 11] Sorted IDs, nil when absent or empty: a plain call and an empty list share one entry.
    optionalItemIDs = sorted_item_ids(opts.optionalItemIDs),
  }
end

-- Bags, bank, reagent bank and (unless excludeWarband) the warband: the game's own count for the current character,
-- the snapshots for other characters (Scanner:GetOwnedCount).
local function owned_count(itemID, charKey, excludeWarband)
  return scanner():GetOwnedCount(itemID, charKey, not excludeWarband) or 0
end

-- RecipeInput and the PriceResults behind it for recipeID on charKey (schematic nil = fetch it). nil without
-- a schematic.
local function build(recipeID, charKey, o, optionalItemIDs, schematic)
  schematic = schematic or scanner():GetSchematic(recipeID)
  if not schematic then return nil end
  local calib = Recipes:GetCalibration(charKey, recipeID)
  local prof, known = find_profession(charKey, recipeID, schematic.skillLineID)

  local P = prices()
  local results, values, owned = {}, {}, o.ownedReagentsFree and {} or nil
  local function price(itemID, reagent)
    if itemID == nil or results[itemID] then return end
    results[itemID] = P:Get(itemID) or {}
    values[itemID] = results[itemID].value
    if reagent and owned then owned[itemID] = owned_count(itemID, charKey, o.excludeWarband) end
  end
  for _, slot in ipairs(schematic.reagentSlots or {}) do
    for _, itemID in ipairs(type(slot.reagents) == "table" and slot.reagents or {}) do price(itemID, true) end
  end
  for _, itemID in pairs(schematic.outputItemIDs or {}) do price(itemID, false) end

  local input = ns.CraftingData.BuildInput(ns.GameData, {
    schematic = schematic, calib = calib,
    professionSkill = prof and (prof.skill or 0) + (prof.skillModifier or 0) or 0,
    prices = values, owned = owned, provided = o.providedReagents, optionalItemIDs = optionalItemIDs,
    useConcentration = o.useConcentration, targetQuality = o.targetQuality,
  })
  return input, {
    schematic = schematic, calib = calib, known = known, results = results, owned = owned or {},
    provided = o.providedReagents or {},
  }
end

-- Price results the chosen plan relies on: reagents it buys (beyond owned + provided), the requested optionals it
-- buys and its output.
local function used_prices(r, ctx, optionals)
  local used, need = {}, {}
  for _, row in ipairs(r.allocation or {}) do
    need[row.itemID] = (need[row.itemID] or 0) + (row.quantity or 0)
  end
  for itemID, n in pairs(need) do
    if n - (ctx.owned[itemID] or 0) - (ctx.provided[itemID] or 0) > 0 then used[#used + 1] = ctx.results[itemID] end
  end
  for _, opt in ipairs(optionals or {}) do
    if type(opt.price) == "number" and opt.price > 0 and ctx.results[opt.itemID] then
      used[#used + 1] = ctx.results[opt.itemID]
    end
  end
  local outputs = ctx.schematic.outputItemIDs or {}
  used[#used + 1] = ctx.results[outputs[r.expectedQuality]]
  return used
end

-- extraStats (phase 3 spec what-if, nil = none): { skill, multicraft, resourcefulness, ingenuity } added through
-- 1b's own optional-reagent path as a free pseudo-optional (Stats.ApplyOptionals adds skill and converts the
-- ratings with Stats.RATING_PER_UNIT; price 0 adds no cost), so Math needs no change.
local function evaluate(recipeID, charKey, o, schematic, extraStats)
  local input, ctx = build(recipeID, charKey, o, o.optionalItemIDs, schematic)
  if not input then return nil end
  -- [phase 7 Task 11] Only the requested optionals that Math.Optionals.Place puts in a slot are applied (EvaluateCraft
  -- applies every listed one), so the effects and cost are exactly optionalAllocation's. A requested itemID the
  -- schematic lists but no free slot can take is left out (flags.unknownOptional); one the schematic does not list has
  -- unknown cost and effects: unpriced, flagged, never free.
  local unknownOptional = false
  local requested = input.optionals
  local allocation = {}
  if o.optionalItemIDs then
    local byID = {}
    for _, opt in ipairs(input.optionals or {}) do byID[opt.itemID] = opt end
    local unplaced
    allocation, unplaced = ns.Math.Optionals.Place(input.optionalSlots, o.optionalItemIDs)
    requested = {}
    for _, row in ipairs(allocation) do requested[#requested + 1] = byID[row.itemID] end
    for _, itemID in ipairs(unplaced) do
      unknownOptional = true
      if not byID[itemID] then requested[#requested + 1] = { itemID = itemID, price = nil, stats = {} } end
    end
    input.optionals = requested
  end
  if extraStats then
    input.optionals = {}
    for i, opt in ipairs(requested or {}) do input.optionals[i] = opt end
    input.optionals[#input.optionals + 1] = { itemID = 0, price = 0, stats = extraStats }
  end
  local r = ns.Math.Profit.EvaluateCraft(input)
  local mathFlags = r.flags or {}

  local P = prices()
  local stalePrice, priceAgeDays = false, nil
  for _, pr in ipairs(used_prices(r, ctx, o.optionalItemIDs and requested or nil)) do
    if P:IsStale(pr) then stalePrice = true end
    if type(pr.ageDays) == "number" and (priceAgeDays == nil or pr.ageDays > priceAgeDays) then priceAgeDays = pr.ageDays end
  end

  local now, days = ns.FS:Now(), Recipes:GetSetting("staleCalibrationDays")
  local char = scanner():GetCharacter(charKey)
  local calib = ctx.calib
  -- A recipe with qualities (maxQuality > 1; 0, 1 and nil mean none) is an estimate when it has no thresholds
  -- (an unsupported maxQuality predicts quality 1 whatever the skill: never present that as real), or when
  -- default thresholds stand in because GameData and the calibration lack the recipe's (or some tiers of them:
  -- input.thresholdsEstimated). A ranked basic slot without a GameData weight (input.missingWeights) is weighted
  -- equally with the others: an estimate too.
  local hasQualities = (input.maxQuality or 1) > 1
  local noThresholds = hasQualities
    and ns.Math.Quality.Thresholds(input.maxQuality, input.baseDifficulty or 0, input.thresholdFractions) == nil
  local defaultThresholds = hasQualities and input.thresholdFractions == nil

  r.recipeID, r.charKey, r.priceAgeDays = recipeID, charKey, priceAgeDays
  r.flags = {
    noPrice = r.missingPrice == true,
    stalePrice = stalePrice,
    staleData = calib == nil or older_than(calib.time, now, days) or older_than(char and char.lastSeen, now, days),
    unknownRecipe = not ctx.known,
    estimated = calib == nil or noThresholds or defaultThresholds or input.missingWeights == true
      or input.thresholdsEstimated == true,
    unreachableTarget = mathFlags.unreachableTarget == true,
    unknownOptional = mathFlags.unknownOptional == true or unknownOptional,
  }
  r.optionalAllocation = allocation
  return r
end

-- RecipeResult (contract) for recipeID crafted by charKey (nil = current character); nil when the recipe's
-- schematic is not cached. opts = { targetQuality, useConcentration, providedReagents = {[itemID] = n},
-- ownedReagentsFree (nil = 1a's settings.costing.ownedReagentsFree), excludeWarband (owned counts leave out the
-- warband: the queue's evaluations while settings.crafting.queueUseWarband is off) }. Results are cached per recipe,
-- character and opts (defaults filled) while Prices:GetVersion(), GetDataStamp(charKey), the schematic
-- (the cached table and its build and time: schematics are shared by every character) and the day
-- (floor(Now() / 86400), so time-based flags and price ages move) are unchanged; treat them as read-only.
-- [phase 3 Task 11] opts.extraStats = { skill, multicraft, resourcefulness, ingenuity } (each optional; ratings, as
-- optional reagents carry them) evaluates a what-if with those bonuses (spec advice). A non-empty table is read
-- before full_opts (which keeps only the cached opts) and such calls neither read nor write the cache; an empty
-- or non-table value is a plain call.
-- [phase 7 Task 11] opts.optionalItemIDs = { itemID } applies exactly those optional/finishing reagents (a sixth
-- cached key, sorted; absent or empty = a plain call sharing its cache entry). A requested itemID the schematic does
-- not list makes the result unpriced with flags.unknownOptional. RecipeResult.optionalAllocation =
-- { { slotIndex, itemID, quantity } } places them ({} for a plain call).
function Recipes:Evaluate(recipeID, charKey, opts)
  charKey = charKey or ns.FS:CharKey()
  local schematic = scanner():GetSchematic(recipeID)
  if not schematic then return nil end
  local extraStats = type(opts) == "table" and type(opts.extraStats) == "table" and next(opts.extraStats) ~= nil
    and opts.extraStats or nil
  local o = full_opts(opts)
  if extraStats then return evaluate(recipeID, charKey, o, schematic, extraStats) end
  local version = prices():GetVersion()
  if version ~= cachePriceVersion then
    cache, cachePriceVersion = {}, version
  end
  local key = tostring(recipeID) .. "|" .. tostring(charKey) .. "|" .. serialize(o)
  local stamp = self:GetDataStamp(charKey)
  -- Owned-free results also follow item counts when the setting (and so the data stamp) does not.
  local itemStamp = o.ownedReagentsFree and ((itemStamps[charKey] or 0) + warbandStamp) or nil
  local day = math.floor(ns.FS:Now() / DAY)
  local entry = cache[key]
  if entry and entry.stamp == stamp and entry.itemStamp == itemStamp and entry.day == day
    and entry.schematic == schematic and entry.build == schematic.build and entry.time == schematic.time then
    return entry.result
  end

  local result = evaluate(recipeID, charKey, o, schematic)
  if result then
    cache[key] = { stamp = stamp, itemStamp = itemStamp, day = day, schematic = schematic, build = schematic.build,
      time = schematic.time, result = result }
  end
  return result
end

-- Math prediction for `allocation` on the current character (no optimisation): the profession panel and the
-- self-check. optionalItemIDs selects optional/finishing reagents; applyConcentration crafts one quality up.
-- MathResult, or nil when the schematic is not cached.
function Recipes:PredictLive(recipeID, allocation, optionalItemIDs, applyConcentration)
  local o = full_opts({ useConcentration = applyConcentration })
  local input = build(recipeID, ns.FS:CharKey(), o, optionalItemIDs)
  if not input then return nil end
  return ns.Math.Profit.EvaluateAllocation(input, allocation, optionalItemIDs)
end

-- Blizzard-style reagent infos back to a ReagentAllocation and optional itemIDs, over the cached schematic.
function Recipes:FromCraftingReagentInfo(recipeID, infos)
  return ns.CraftingData.AllocationFromReagentInfo(scanner():GetSchematic(recipeID), infos)
end

-- The memo key and validity data BestOptionals and HasBestOptionals share: nil when the call needs no search at all
-- (search off, or no cached schematic); else key, o (the cached opts), stamp, itemStamp, day, schematic.
local function best_lookup(self, recipeID, charKey, opts)
  local mode = self:GetSetting("optionalMode")
  if mode == "off" then return nil end
  local schematic = scanner():GetSchematic(recipeID)
  if not schematic then return nil end
  local o = full_opts(opts)
  o.optionalItemIDs = nil
  local key = tostring(recipeID) .. "|" .. tostring(charKey) .. "|" .. serialize(o) .. "|" .. tostring(mode)
  local itemStamp = o.ownedReagentsFree and ((itemStamps[charKey] or 0) + warbandStamp) or nil
  return key, o, self:GetDataStamp(charKey), itemStamp, math.floor(ns.FS:Now() / DAY), schematic, mode
end

local function best_entry_valid(entry, stamp, itemStamp, day, schematic)
  return entry and entry.stamp == stamp and entry.itemStamp == itemStamp and entry.day == day
    and entry.schematic == schematic and entry.build == schematic.build and entry.time == schematic.time
end

-- [phase 7 Task 13] True when BestOptionals(recipeID, charKey, opts) would cost no search: it is answered from its
-- memo (same validity test: price version, data stamp, owned-free item stamp, day and schematic), or it returns nil at
-- once (optionalMode "off", no cached schematic). False means the call would search. Read-only: it changes no cache.
function Recipes:HasBestOptionals(recipeID, charKey, opts)
  charKey = charKey or ns.FS:CharKey()
  local key, _, stamp, itemStamp, day, schematic = best_lookup(self, recipeID, charKey, opts)
  if not key then return true end
  if prices():GetVersion() ~= bestPriceVersion then return false end
  return best_entry_valid(bestCache[key], stamp, itemStamp, day, schematic) and true or false
end

-- [phase 7 Task 11] The optional and finishing reagents that add the most profit to recipeID on charKey, with
-- opts as for Evaluate (the cached keys; opts.optionalItemIDs is ignored). Returns { itemIDs (sorted), result =
-- RecipeResult with them, base = RecipeResult without, gain = copper|nil (result.profit - base.profit when both are
-- numbers), mode (the one that ran), skipped = { unknownPrice, noEffect } }, or nil with optionalMode "off", no
-- cached schematic or no optional slot. Memoised per recipe, character, opts and mode while the price version, the
-- data stamp (and, as for Evaluate, the schematic, the day and owned-free item counts) are unchanged: treat it as
-- read-only. On demand only; the recipe scan ranks plain results.
function Recipes:BestOptionals(recipeID, charKey, opts)
  charKey = charKey or ns.FS:CharKey()
  local key, o, stamp, itemStamp, day, schematic, mode = best_lookup(self, recipeID, charKey, opts)
  if not key then return nil end

  local version = prices():GetVersion()
  if version ~= bestPriceVersion then
    bestCache, bestPriceVersion = {}, version
  end
  local entry = bestCache[key]
  if best_entry_valid(entry, stamp, itemStamp, day, schematic) then
    return entry.best or nil
  end
  local function remember(best)
    bestCache[key] = { stamp = stamp, itemStamp = itemStamp, day = day, schematic = schematic, build = schematic.build,
      time = schematic.time, best = best }
    return best or nil
  end

  local input = build(recipeID, charKey, o, {}, schematic)
  -- false remembers "no optional slot", so lists asking for every row rebuild nothing.
  if not input or not input.optionalSlots or #input.optionalSlots == 0 then return remember(false) end
  local picked = ns.Math.Optionals.Best(input, { mode = mode, maxCombinations = ns.Math.Optionals.MAX_COMBINATIONS })
  local base = self:Evaluate(recipeID, charKey, o)
  local withOpts = {}
  for k, v in pairs(o) do withOpts[k] = v end
  withOpts.optionalItemIDs = picked.itemIDs
  local result = self:Evaluate(recipeID, charKey, withOpts)
  if not base or not result then return remember(false) end
  local gain
  if type(result.profit) == "number" and type(base.profit) == "number" then gain = result.profit - base.profit end
  return remember({ itemIDs = picked.itemIDs, result = result, base = base, gain = gain, mode = picked.mode,
    skipped = picked.skipped })
end

---------------------------------------------------------------------------
-- Auto-calibration (Blizzard_Professions)
---------------------------------------------------------------------------

-- EventRegistry calls this as fn(owner, recipeInfo, recipeList). Errors are logged under a
-- non-module source, so they never turn off the core Recipes module.
local function on_recipe_selected(_, recipeInfo)
  if not Recipes:IsEnabled() then return end
  ns.FS:SafeCall("Recipes:AutoCalibrate", function()
    if type(recipeInfo) ~= "table" or not recipeInfo.recipeID or recipeInfo.learned == false then return end
    Recipes:Calibrate(recipeInfo.recipeID)
  end)
end

-- Registers the recipe-selection callback once per session.
function Recipes:AttachIfReady()
  if attached or not EventRegistry then return end
  EventRegistry:RegisterCallback(RECIPE_SELECTED, on_recipe_selected, self)
  attached = true
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Recipes:OnInitialize()
  ns.FS:RegisterOptions("crafting", build_options())
end

function Recipes:OnEnable()
  self:RegisterMessage(ns.Msg.DATA_CHANGED, on_data_changed)
  self:RegisterMessage(ns.Msg.RECIPES_CHANGED, function() itemIndex = nil end)
  self:RegisterEvent("ADDON_LOADED", function(_, name)
    -- Log-only source: a failing attach must not turn off the core Recipes module.
    if name == PROFESSIONS_ADDON then ns.FS:SafeCall("Recipes:Attach", self.AttachIfReady, self) end
  end)
  if C_AddOns.IsAddOnLoaded(PROFESSIONS_ADDON) and ProfessionsFrame then
    ns.FS:SafeCall("Recipes:Attach", self.AttachIfReady, self)
  end
end
