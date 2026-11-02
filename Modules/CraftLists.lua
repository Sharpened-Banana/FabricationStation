local _, ns = ...

-- CraftLists (phase 7, Task 13): named lists of recipes the player wants made, each with rules, kept in
-- db.global.craftLists = { nextID, lists = { CraftList } } (created on the first write; at most 50 lists with 200 recipes
-- each):
--   CraftList = { id, name, recipes = { { recipeID, charKey?, quantity } },
--                 rules = { minProfit? (copper), minQuality? (1..5), concentration = "off"|"single"|"multi",
--                           useOptionals = false } }
-- A recipe line without a charKey is made by "the best crafter" (the character with the best profit, as for restock
-- targets). Plan(id, now) turns a list into the queue entries its rules allow, without queuing anything; QueueList(id)
-- adds those entries with Queue:Add. The Queue tab calls QueueList from one button's click, and nothing else calls it
-- (design rule 3: no automation; tests/craftlists/craft_lists_spec.lua pins that).
--
-- The API answers while the module is off (like Planner's getters); the Queue tab checks IsEnabled itself.
-- Nothing is written while the saved data is from a newer version (ns.FS.dbIsNewer): writers answer nil, "readonly".
-- A damaged part is replaced by an empty one when it is next written and never wiped otherwise; a damaged list is
-- skipped when reading.
--
-- Optionals: Recipes:BestOptionals is synchronous and can make up to 64 evaluations for one recipe, so a list may not
-- search it for every recipe in one frame. Plan spends a budget of OPTIONAL_SEARCH_LIMIT (4) real searches per call on
-- the recipe/crafter/concentration combinations and leaves the other entries without optionals (plan.optionalsLeftOut
-- counts them). Recipes:HasBestOptionals says whether a call would be served from BestOptionals' own memo (or needs no
-- search at all, with optionalMode "off"); only a call it answers false for uses budget, so each further click on
-- "Queue list" reaches a few more recipes and no data change or new day can make one click search more than the budget.
-- There is no timer: nothing in this module runs unless a caller asks.
local CraftLists = ns.FS:NewModule("CraftLists")

CraftLists.MAX_LISTS = 50
CraftLists.MAX_RECIPES = 200
CraftLists.MAX_NAME = 40
CraftLists.MAX_QUANTITY = 9999
CraftLists.OPTIONAL_SEARCH_LIMIT = 4
CraftLists.MODES = { "off", "single", "multi" }

local MODE_OK = { off = true, single = true, multi = true }

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function global()
  return ns.FS.db and ns.FS.db.global
end

local function writable()
  return global() ~= nil and not ns.FS.dbIsNewer
end

local function is_finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

local function positive(v) return is_finite(v) and v > 0 end

local function module(name)
  return ns.FS:GetModule(name, true)
end

-- A whole number >= 1 (floored), at most MAX_QUANTITY; nil for anything else.
local function quantity_of(n)
  if not is_finite(n) then return nil end
  n = math.floor(n)
  if n < 1 then return nil end
  return math.min(n, CraftLists.MAX_QUANTITY)
end

-- The name trimmed and cut to MAX_NAME characters (whole UTF-8 characters); "" when nothing is left.
local function clean_name(name)
  if type(name) ~= "string" then return "" end
  name = name:match("^%s*(.-)%s*$")
  local count, cut = 0, #name
  for i = 1, #name do
    local byte = name:byte(i)
    if byte < 128 or byte >= 192 then   -- the first byte of a character
      count = count + 1
      if count > CraftLists.MAX_NAME then cut = i - 1; break end
    end
  end
  return (name:sub(1, cut):match("^(.-)%s*$"))
end

local function same_name(a, b)
  return a:lower() == b:lower()
end

-- Rules repaired: minProfit a number >= 0 or nil; minQuality a whole 1..5 or nil; concentration one of the modes
-- (else "off"); useOptionals a boolean.
local function clean_rules(rules)
  rules = type(rules) == "table" and rules or {}
  local out = { concentration = MODE_OK[rules.concentration] and rules.concentration or "off",
    useOptionals = rules.useOptionals == true }
  if is_finite(rules.minProfit) and rules.minProfit >= 0 then out.minProfit = rules.minProfit end
  if is_finite(rules.minQuality) then
    local q = math.floor(rules.minQuality)
    if q >= 1 and q <= 5 then out.minQuality = q end
  end
  return out
end

local function valid_line(line)
  return type(line) == "table" and positive(line.recipeID) and quantity_of(line.quantity) ~= nil
    and (line.charKey == nil or (type(line.charKey) == "string" and line.charKey ~= ""))
end

-- A stored list that looks like one (a damaged or newer save may hold anything).
local function valid_list(list)
  return type(list) == "table" and positive(list.id) and type(list.name) == "string" and list.name ~= ""
    and type(list.recipes) == "table"
end

-- The saved lists for reads: the stored tables themselves, damaged ones left out. Nothing is created.
local function stored_lists()
  local g = global()
  local data = g and g.craftLists
  local out = {}
  if type(data) ~= "table" or type(data.lists) ~= "table" then return out end
  for _, list in ipairs(data.lists) do
    if valid_list(list) then out[#out + 1] = list end
  end
  return out
end

-- The saved data for writes, with every part present (created or replaced when missing or damaged). Nil while the
-- saved data is read-only.
local function store()
  if not writable() then return nil end
  local g = global()
  if type(g.craftLists) ~= "table" then g.craftLists = {} end
  local data = g.craftLists
  if type(data.lists) ~= "table" then data.lists = {} end
  if not positive(data.nextID) then
    local highest = 0
    for _, list in ipairs(data.lists) do
      if type(list) == "table" and positive(list.id) and list.id > highest then highest = list.id end
    end
    data.nextID = highest + 1
  end
  return data
end

local function find_stored(data, id)
  for _, list in ipairs(data.lists) do
    if valid_list(list) and list.id == id then return list end
  end
end

-- A caller's copy of a list: the lines that look like lines, the rules repaired.
local function copy_list(list)
  local out = { id = list.id, name = list.name, recipes = {}, rules = clean_rules(list.rules) }
  for _, line in ipairs(list.recipes) do
    if valid_line(line) then
      out.recipes[#out.recipes + 1] = { recipeID = line.recipeID, charKey = line.charKey,
        quantity = quantity_of(line.quantity) }
    end
  end
  return out
end

local function name_taken(data, name, exceptID)
  for _, list in ipairs(data.lists) do
    if valid_list(list) and list.id ~= exceptID and same_name(list.name, name) then return true end
  end
  return false
end

---------------------------------------------------------------------------
-- Lists
---------------------------------------------------------------------------

-- Creates an empty list. Returns its id, or nil and "empty" (no name), "duplicate" (the name exists, ignoring case),
-- "limit" (50 lists) or "readonly".
function CraftLists:Create(name)
  local data = store()
  if not data then return nil, "readonly" end
  name = clean_name(name)
  if name == "" then return nil, "empty" end
  if name_taken(data, name) then return nil, "duplicate" end
  local count = 0
  for _, list in ipairs(data.lists) do if valid_list(list) then count = count + 1 end end
  if count >= CraftLists.MAX_LISTS then return nil, "limit" end
  local id = data.nextID
  data.nextID = id + 1
  data.lists[#data.lists + 1] = { id = id, name = name, recipes = {}, rules = clean_rules(nil) }
  return id
end

-- Returns true, or nil and "unknown" (no such list), "empty", "duplicate" or "readonly".
function CraftLists:Rename(id, name)
  local data = store()
  if not data then return nil, "readonly" end
  local list = find_stored(data, id)
  if not list then return nil, "unknown" end
  name = clean_name(name)
  if name == "" then return nil, "empty" end
  if name_taken(data, name, id) then return nil, "duplicate" end
  list.name = name
  return true
end

-- True when the list existed and was removed.
function CraftLists:Delete(id)
  local data = store()
  if not data then return false end
  for i, list in ipairs(data.lists) do
    if valid_list(list) and list.id == id then
      table.remove(data.lists, i)
      return true
    end
  end
  return false
end

-- Copies of the lists, by name ignoring case, then id.
function CraftLists:GetLists()
  local out = {}
  for _, list in ipairs(stored_lists()) do out[#out + 1] = copy_list(list) end
  table.sort(out, function(a, b)
    local la, lb = a.name:lower(), b.name:lower()
    if la ~= lb then return la < lb end
    return a.id < b.id
  end)
  return out
end

function CraftLists:Get(id)
  for _, list in ipairs(stored_lists()) do
    if list.id == id then return copy_list(list) end
  end
  return nil
end

-- Replaces the list's rules with `rules` repaired (clean_rules). Returns true, or nil and "unknown" / "readonly".
function CraftLists:SetRules(id, rules)
  local data = store()
  if not data then return nil, "readonly" end
  local list = find_stored(data, id)
  if not list then return nil, "unknown" end
  list.rules = clean_rules(rules)
  return true
end

---------------------------------------------------------------------------
-- Recipes in a list
---------------------------------------------------------------------------

-- Adds `quantity` crafts of recipeID (made by charKey, nil = the best crafter); the same recipe and charKey add up.
-- Returns true, or nil and "unknown", "invalid" (recipeID or quantity), "limit" (200 recipes) or "readonly".
function CraftLists:AddRecipe(id, recipeID, charKey, quantity)
  local data = store()
  if not data then return nil, "readonly" end
  local list = find_stored(data, id)
  if not list then return nil, "unknown" end
  quantity = quantity_of(quantity)
  if not positive(recipeID) or not quantity or (charKey ~= nil and (type(charKey) ~= "string" or charKey == "")) then
    return nil, "invalid"
  end
  if type(list.recipes) ~= "table" then list.recipes = {} end
  for _, line in ipairs(list.recipes) do
    if valid_line(line) and line.recipeID == recipeID and line.charKey == charKey then
      line.quantity = math.min(CraftLists.MAX_QUANTITY, quantity_of(line.quantity) + quantity)
      return true
    end
  end
  if #list.recipes >= CraftLists.MAX_RECIPES then return nil, "limit" end
  list.recipes[#list.recipes + 1] = { recipeID = recipeID, charKey = charKey, quantity = quantity }
  return true
end

-- Sets the crafts of the list's recipe line `index` (as Get(id).recipes numbers them); 0 or less removes the line.
-- Returns true, or nil and "unknown" (no such list or line), "invalid" or "readonly".
function CraftLists:SetQuantity(id, index, n)
  local data = store()
  if not data then return nil, "readonly" end
  local list = find_stored(data, id)
  if not list or type(index) ~= "number" or type(list.recipes) ~= "table" then return nil, "unknown" end
  -- Index into the lines that look like lines, as Get numbers them.
  local at = 0
  for i, line in ipairs(list.recipes) do
    if valid_line(line) then
      at = at + 1
      if at == index then
        if not is_finite(n) then return nil, "invalid" end
        if n < 1 then
          table.remove(list.recipes, i)
        else
          line.quantity = quantity_of(n)
        end
        return true
      end
    end
  end
  return nil, "unknown"
end

-- Makes a list called `name` from the real queue entries (the computed restock entries are not part of it), summed by
-- recipeID and charKey in the order they first appear. Only recipe, character and crafts are kept: the quality,
-- concentration and optionals of a list's entries follow its rules. Returns the new id, or nil and "emptyQueue",
-- "limit" (more than 200 different recipes, or 50 lists), "empty", "duplicate" or "readonly".
function CraftLists:FromQueue(name)
  if not writable() then return nil, "readonly" end
  local queue = module("Queue")
  local lines, byKey = {}, {}
  for _, e in ipairs(queue and queue:GetEntries() or {}) do
    if not e.isRestock and positive(e.recipeID) and quantity_of(e.quantity) then
      local key = tostring(e.recipeID) .. ":" .. tostring(e.charKey)
      local line = byKey[key]
      if line then
        line.quantity = math.min(CraftLists.MAX_QUANTITY, line.quantity + quantity_of(e.quantity))
      else
        line = { recipeID = e.recipeID, charKey = type(e.charKey) == "string" and e.charKey ~= "" and e.charKey or nil,
          quantity = quantity_of(e.quantity) }
        byKey[key] = line
        lines[#lines + 1] = line
      end
    end
  end
  if #lines == 0 then return nil, "emptyQueue" end
  if #lines > CraftLists.MAX_RECIPES then return nil, "limit" end
  local id, err = self:Create(name)
  if not id then return nil, err end
  local data = store()
  find_stored(data, id).recipes = lines
  return id
end

---------------------------------------------------------------------------
-- Planning
---------------------------------------------------------------------------

local function profit_of(result)
  if type(result) ~= "table" or (type(result.flags) == "table" and result.flags.noPrice) then return nil end
  return is_finite(result.profit) and result.profit or nil
end

-- The crafter of a list line and its result for the rules' quality: the line's own charKey, else the best-profit
-- crafter among Recipes:WhoCanCraft (the restock rule: the first with a result starts the comparison, a later one must
-- beat it, an unknown profit loses to any number; a crafter that cannot reach the quality is passed over unless every
-- crafter is such, so the line reports "unreachable" rather than "noCrafter"). Returns charKey, result, or nil and the
-- skip reason "noCrafter" (nobody known, or the recipe cannot be evaluated: no cached schematic).
local function resolve(recipes, line, opts)
  if line.charKey then
    local result = recipes:Evaluate(line.recipeID, line.charKey, opts)
    if type(result) ~= "table" or (type(result.flags) == "table" and result.flags.unknownRecipe) then
      return nil, "noCrafter"
    end
    return line.charKey, result
  end
  local crafter, bestResult, bestProfit, unreachable
  for _, charKey in ipairs(recipes:WhoCanCraft(line.recipeID)) do
    local result = recipes:Evaluate(line.recipeID, charKey, opts)
    if type(result) == "table" then
      if type(result.flags) == "table" and result.flags.unreachableTarget then
        unreachable = unreachable or { charKey = charKey, result = result }
      else
        local profit = profit_of(result)
        if crafter == nil or (profit ~= nil and (bestProfit == nil or profit > bestProfit)) then
          crafter, bestResult, bestProfit = charKey, result, profit
        end
      end
    end
  end
  if crafter then return crafter, bestResult end
  if unreachable then return unreachable.charKey, unreachable.result end
  return nil, "noCrafter"
end

-- The skill line (a key of the character's profession records) whose recipes include recipeID: where its
-- concentration pool is. Nil when none does.
local function skill_line_of(charKey, recipeID)
  local scanner = module("Scanner")
  local character = scanner and scanner:GetCharacter(charKey)
  local professions = type(character) == "table" and character.professions
  if type(professions) ~= "table" then return nil end
  local ids = {}
  for skillLineID, p in pairs(professions) do
    if type(p) == "table" and not p.dropped and type(p.recipes) == "table" and p.recipes[recipeID] then
      ids[#ids + 1] = skillLineID
    end
  end
  table.sort(ids)
  return ids[1]
end

-- The concentration evaluation of a job when it can be scheduled (a positive cost and gold per point, priced), else nil.
local function concentration_result(recipes, job, rules)
  local result = recipes:Evaluate(job.recipeID, job.crafter, { targetQuality = rules.minQuality, useConcentration = true })
  if type(result) ~= "table" then return nil end
  local flags = type(result.flags) == "table" and result.flags or {}
  if flags.noPrice or flags.unknownRecipe or flags.unreachableTarget then return nil end
  if not positive(result.concentrationCost) or not positive(result.goldPerConcentration) then return nil end
  return result
end

-- The pools by "charKey:skillLineID" (the module's own copies: planning spends from them).
local function pools_by_key(now)
  local alts = module("Alts")
  local out = {}
  if not alts or not alts:IsEnabled() then return out end
  for _, pool in ipairs(alts:GetPools(now) or {}) do
    if pool.charKey ~= nil and pool.skillLineID ~= nil then
      local copy = {}
      for k, v in pairs(pool) do copy[k] = v end
      out[tostring(pool.charKey) .. ":" .. tostring(pool.skillLineID)] = copy
    end
  end
  return out
end

local function pool_key(job)
  return job.skillLineID ~= nil and (tostring(job.crafter) .. ":" .. tostring(job.skillLineID)) or nil
end

-- "single": per pool, the job with the highest gold per point gets min(quantity, floor(pool / cost)) crafts with
-- concentration (an unknown pool gives 0). Fills job.concCrafts.
local function split_single(jobs, pools)
  local bestOf = {}
  for _, job in ipairs(jobs) do
    local key = job.conc and pool_key(job)
    if key then
      local best = bestOf[key]
      local rate, bestRate = job.conc.goldPerConcentration, best and best.conc.goldPerConcentration
      if not best or rate > bestRate or (rate == bestRate and job.recipeID < best.recipeID) then bestOf[key] = job end
    end
  end
  for key, job in pairs(bestOf) do
    local pool = pools[key]
    if pool and is_finite(pool.value) and positive(pool.max) then
      job.concCrafts = math.min(job.quantity, math.floor(pool.value / job.conc.concentrationCost))
    end
  end
end

-- "multi": PlanCalc.Schedule over every job that has a concentration result, each recipe capped at its own quantity.
-- Schedule takes one cap for all recipes, so it runs with the largest quantity still open; a recipe it gives more than
-- its quantity is clamped, taken out, and Schedule runs again over what its pool has left, until nothing is clamped.
-- Fills job.concCrafts.
local function split_multi(jobs, pools)
  local PlanCalc = ns.PlanCalc
  if not PlanCalc then return end
  local open, byJob = {}, {}
  for _, job in ipairs(jobs) do
    local key = job.conc and pool_key(job)
    if key and pools[key] then
      local result = {}
      for k, v in pairs(job.conc) do result[k] = v end
      result.charKey, result.skillLineID, result.recipeID = job.crafter, job.skillLineID, job.recipeID
      open[#open + 1] = { job = job, result = result, left = job.quantity }
      byJob[tostring(job.crafter) .. ":" .. tostring(job.recipeID)] = open[#open]
    end
  end
  local poolList = {}
  for _, pool in pairs(pools) do poolList[#poolList + 1] = pool end
  table.sort(poolList, function(a, b)
    if a.charKey ~= b.charKey then return tostring(a.charKey) < tostring(b.charKey) end
    return tostring(a.skillLineID) < tostring(b.skillLineID)
  end)
  for _ = 1, #open + 1 do
    local cap, results = 0, {}
    for _, item in ipairs(open) do
      if item.left > 0 then
        cap = math.max(cap, item.left)
        results[#results + 1] = item.result
      end
    end
    if #results == 0 then break end
    local rows = PlanCalc.Schedule(poolList, results, { maxCraftsPerRecipe = cap })
    local clamped = false
    for _, row in ipairs(rows) do
      local item = byJob[tostring(row.charKey) .. ":" .. tostring(row.recipeID)]
      if item then
        local take = math.min(row.crafts, item.left)
        item.job.concCrafts = (item.job.concCrafts or 0) + take
        item.left = item.left - take
        local pool = pools[tostring(row.charKey) .. ":" .. tostring(row.skillLineID)]
        if pool then pool.value = pool.value - take * item.result.concentrationCost end
        if take < row.crafts then clamped = true end
      end
    end
    -- A recipe that used up its quantity has left = 0 and is not offered again; nothing clamped means nothing is left to share.
    if not clamped then break end
  end
end

-- The BestOptionals pick for a job's entry (a copy of the itemIDs), or nil. A search Recipes would really make costs one
-- of state.budget (the searches this call may still start); a call its memo answers costs nothing. state.leftOut counts
-- the entries that got no search for want of budget.
local function pick_optionals(recipes, job, withConcentration, rules, state)
  if not rules.useOptionals then return nil end
  local opts = { targetQuality = rules.minQuality, useConcentration = withConcentration }
  if not recipes:HasBestOptionals(job.recipeID, job.crafter, opts) then
    if state.budget <= 0 then
      state.leftOut = state.leftOut + 1
      return nil
    end
    state.budget = state.budget - 1
  end
  local best = recipes:BestOptionals(job.recipeID, job.crafter, opts)
  if type(best) ~= "table" or type(best.itemIDs) ~= "table" or #best.itemIDs == 0 then return nil end
  local out = {}
  for i, itemID in ipairs(best.itemIDs) do out[i] = itemID end
  return out
end

-- What the list's rules make of it at `now` (server seconds, default Now()), without queuing or saving anything:
--   { entries = { QueueEntry-shaped: recipeID, quantity, charKey, targetQuality?, useConcentration?, optionalItemIDs? },
--     skipped = { { recipeID, charKey (the line's, nil = best crafter), reason } }, optionalsLeftOut = n }
-- reason: "noCrafter" (no character knows the recipe, or it cannot be evaluated yet), "unreachable" (the crafter cannot
-- reach minQuality), "unknownProfit" or "belowMinProfit" (with minProfit; the profit is the plain craft's, before
-- optionals and concentration). Lines that resolve to the same crafter and recipe are one entry. Concentration:
-- "off" none; "single" the best gold per point of each pool's recipes gets as many concentration crafts as the pool
-- pays for and the rest of its quantity is a second entry; "multi" PlanCalc.Schedule shares the pool among the recipes
-- (each capped at its quantity). A pool that is not known gives no concentration crafts.
function CraftLists:Plan(id, now)
  local plan = { entries = {}, skipped = {}, optionalsLeftOut = 0 }
  local list = self:Get(id)
  local recipes = module("Recipes")
  if not list then return plan end
  now = is_finite(now) and now or ns.FS:Now()
  local rules = list.rules
  if not recipes then
    for _, line in ipairs(list.recipes) do
      plan.skipped[#plan.skipped + 1] = { recipeID = line.recipeID, charKey = line.charKey, reason = "noCrafter" }
    end
    return plan
  end

  local opts = { targetQuality = rules.minQuality }
  local jobs, byKey = {}, {}
  for _, line in ipairs(list.recipes) do
    local crafter, result = resolve(recipes, line, opts)
    local reason
    if not crafter then
      reason = result
    elseif type(result.flags) == "table" and result.flags.unreachableTarget then
      reason = "unreachable"
    elseif rules.minProfit ~= nil then
      local profit = profit_of(result)
      if profit == nil then reason = "unknownProfit" elseif profit < rules.minProfit then reason = "belowMinProfit" end
    end
    if reason then
      plan.skipped[#plan.skipped + 1] = { recipeID = line.recipeID, charKey = line.charKey, reason = reason }
    else
      local key = tostring(crafter) .. ":" .. tostring(line.recipeID)
      local job = byKey[key]
      if job then
        job.quantity = math.min(CraftLists.MAX_QUANTITY, job.quantity + line.quantity)
      else
        job = { recipeID = line.recipeID, crafter = crafter, quantity = line.quantity, concCrafts = 0 }
        byKey[key] = job
        jobs[#jobs + 1] = job
      end
    end
  end

  if rules.concentration ~= "off" and #jobs > 0 then
    local pools = pools_by_key(now)
    for _, job in ipairs(jobs) do
      job.skillLineID = skill_line_of(job.crafter, job.recipeID)
      if job.skillLineID ~= nil and pools[pool_key(job)] then job.conc = concentration_result(recipes, job, rules) end
    end
    if rules.concentration == "single" then split_single(jobs, pools) else split_multi(jobs, pools) end
  end

  local state = { budget = CraftLists.OPTIONAL_SEARCH_LIMIT, leftOut = 0 }
  local function add_entry(job, quantity, withConcentration)
    if quantity < 1 then return end
    plan.entries[#plan.entries + 1] = { recipeID = job.recipeID, quantity = quantity, charKey = job.crafter,
      targetQuality = rules.minQuality, useConcentration = withConcentration or nil,
      optionalItemIDs = pick_optionals(recipes, job, withConcentration, rules, state) }
  end
  for _, job in ipairs(jobs) do
    local conc = math.min(job.concCrafts, job.quantity)
    add_entry(job, conc, true)
    add_entry(job, job.quantity - conc, false)
  end
  plan.optionalsLeftOut = state.leftOut
  return plan
end

-- Adds the entries Plan(id) makes to the queue (Queue:Add). Only the Queue tab's "Queue list" button calls this, from its
-- click handler. Returns added (entries the Queue took), skipped (Plan's skipped list), or nil and "unknown" (no such
-- list), "readonly" or "queueOff".
function CraftLists:QueueList(id)
  if ns.FS.dbIsNewer then return nil, "readonly" end
  if not self:Get(id) then return nil, "unknown" end
  local queue = module("Queue")
  if not queue or not queue:IsEnabled() then return nil, "queueOff" end
  local plan = self:Plan(id)
  local added = 0
  for _, entry in ipairs(plan.entries) do
    if queue:Add(entry) ~= nil then added = added + 1 end
  end
  return added, plan.skipped, plan.optionalsLeftOut
end
