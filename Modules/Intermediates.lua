local _, ns = ...

-- Intermediates (phase 7, Task 14): crafts made from the player's own crafted reagents. For a recipe, every reagent of
-- its plain plan that some recipe makes gets a craft-or-buy decision: the cost of crafting one (the cheapest crafter's
-- sub-recipe, with its own reagents decided the same way and passed down as Recipes opts.reagentPrices) against the
-- price of buying one. The cheaper side wins unless the player chose one; the choice is saved per item in
-- db.global.intermediateChoices = { [itemID] = "craft"|"buy" } (absent = the cheaper one; created on the first write,
-- never while ns.FS.dbIsNewer, a damaged table is replaced on the next write and read as empty).
--
-- Recursion bounds (Review Focus 3: a reagent graph with a cycle or a long chain):
--   MAX_DEPTH = 3: sub-crafts at most three levels below the craft being planned; a fourth-level reagent is buy only.
--   Cycle guard: the resolution carries the itemIDs and recipeIDs on the path from the root (the root recipe and its
--     outputs included). A reagent is buy only for that branch (cycle = true) when its itemID or one of the recipes
--     making it is on the path, or one of those recipes takes an item on the path as a reagent (a transmute pair is cut
--     where it would close the loop).
--   MAX_NODES = 50 sub-recipe evaluations (Recipes:Evaluate calls) per resolution; past it every further reagent is
--     buy only and the resolution says truncated = true.
--   Memo: per resolution, keyed itemID .. ":" .. depth, so a reagent shared by several parents is evaluated once. An
--     entry is reused only where the path cannot change it (nothing in its subtree is on the current path, and every
--     cycle it cut is still on the path), so the memo never lets a cycle through.
-- A sub-craft is evaluated without concentration, at the quality FindRecipesForItem gives for the item, by the
-- cheapest crafter of WhoCanCraft (the character that needs the item first on a tie, then WhoCanCraft's order). Cost
-- of one crafted item = (reagentCost - (resourcefulnessValue or 0)) / expectedYield, rounded to copper; nil when the
-- reagent cost or the yield is unknown.
--
-- Optionals are never searched here (Recipes:BestOptionals is synchronous): sub-crafts are plain evaluations.
-- The API answers while the module is off (FeatureLines checks IsEnabled itself). QueueSubCrafts is called only from
-- the profession panel's "Queue with sub-crafts" click; it registers no event, message or timer.
local Intermediates = ns.FS:NewModule("Intermediates")

Intermediates.MAX_DEPTH = 3
Intermediates.MAX_NODES = 50

local CHOICES = { craft = true, buy = true }

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function global()
  return ns.FS.db and ns.FS.db.global
end

local function writable()
  return global() ~= nil and not ns.FS.dbIsNewer
end

local function module(name)
  return ns.FS:GetModule(name, true)
end

local function recipes() return module("Recipes") end
local function scanner() return module("Scanner") end

local function is_number(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

local function copy(t)
  local out = {}
  for k, v in pairs(type(t) == "table" and t or {}) do out[k] = v end
  return out
end

local function buy_price(itemID)
  local P = module("Prices")
  local result = P and P:Get(itemID)
  local value = type(result) == "table" and result.value or nil
  return is_number(value) and value or nil
end

-- Cost of one crafted item from a sub-recipe's RecipeResult.
local function unit_cost(result)
  if type(result) ~= "table" then return nil end
  local cost, yield, saving = result.reagentCost, result.expectedYield, result.resourcefulnessValue
  if not is_number(cost) or not is_number(yield) or yield <= 0 then return nil end
  if not is_number(saving) then saving = 0 end
  return math.floor((cost - saving) / yield + 0.5)
end

-- The allocation's reagents as { { itemID, quantity } }, one per item, in allocation order.
local function needs_of(allocation)
  local out, byID = {}, {}
  for _, a in ipairs(type(allocation) == "table" and allocation or {}) do
    if type(a) == "table" and type(a.itemID) == "number" and is_number(a.quantity) and a.quantity > 0 then
      local row = byID[a.itemID]
      if row then
        row.quantity = row.quantity + a.quantity
      else
        row = { itemID = a.itemID, quantity = a.quantity }
        byID[a.itemID] = row
        out[#out + 1] = row
      end
    end
  end
  return out
end

-- The basic-slot reagents a recipe's cached schematic lists.
local function schematic_reagents(recipeID)
  local schematic = scanner():GetSchematic(recipeID)
  local out = {}
  for _, slot in ipairs(schematic and schematic.reagentSlots or {}) do
    -- A not-required basic slot (the Automatic socket slot) is never crafted for: leave its items out.
    if (slot.kind == "basic" or slot.kind == nil) and slot.required ~= false then
      for _, itemID in ipairs(type(slot.reagents) == "table" and slot.reagents or {}) do out[#out + 1] = itemID end
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Choices
---------------------------------------------------------------------------

-- "craft" or "buy" when the player chose one for itemID; nil = the cheaper one.
function Intermediates:GetChoice(itemID)
  local g = global()
  local choices = g and g.intermediateChoices
  local value = type(choices) == "table" and choices[itemID] or nil
  return CHOICES[value] and value or nil
end

-- Saves the choice for itemID ("craft", "buy", or nil to go back to the cheaper one). Anything else is ignored;
-- nothing is written while the saved data is from a newer version.
function Intermediates:SetChoice(itemID, choice)
  if type(itemID) ~= "number" or (choice ~= nil and not CHOICES[choice]) or not writable() then return end
  local g = global()
  if type(g.intermediateChoices) ~= "table" then
    if choice == nil then return end
    g.intermediateChoices = {}
  end
  g.intermediateChoices[itemID] = choice
end

---------------------------------------------------------------------------
-- Resolution
---------------------------------------------------------------------------

local function new_state()
  return { nodes = 0, memo = {}, truncated = false }
end

-- The path from the root: items and recipes, each counted (pushed and popped around a branch).
local function new_path() return { items = {}, recipes = {} } end

local function on_path(path, kind, id) return (path[kind][id] or 0) > 0 end
local function push(path, kind, id) path[kind][id] = (path[kind][id] or 0) + 1 end
local function pop(path, kind, id) path[kind][id] = path[kind][id] - 1 end

-- A dependency record: `deps` (everything a subtree looked at that the path could cut), `cuts` (what was cut because
-- it was on the path). Merged upwards so a memo entry knows when the path could change it.
local function new_trace() return { deps = {}, cuts = {} } end

local function merge(into, from)
  if not into then return end
  for k in pairs(from.deps) do into.deps[k] = true end
  for k in pairs(from.cuts) do into.cuts[k] = true end
end

local function memo_valid(entry, path)
  for k in pairs(entry.trace.deps) do
    if on_path(path, k:sub(1, 1) == "i" and "items" or "recipes", tonumber(k:sub(2))) then return false end
  end
  for k in pairs(entry.trace.cuts) do
    if not on_path(path, k:sub(1, 1) == "i" and "items" or "recipes", tonumber(k:sub(2))) then return false end
  end
  return true
end

-- One counted Recipes:Evaluate; nil when the budget is spent (the resolution is then truncated).
local function counted_evaluate(state, recipeID, charKey, opts)
  if state.nodes >= Intermediates.MAX_NODES then
    state.truncated = true
    return nil, true
  end
  state.nodes = state.nodes + 1
  return recipes():Evaluate(recipeID, charKey, opts), false
end

-- The reagent costs a list of rows passes up: the chosen-to-craft rows with a known unit cost.
local function chosen_prices(rows)
  local out = {}
  for _, row in ipairs(rows) do
    if row.choice == "craft" and row.craft and is_number(row.craft.unit) then out[row.itemID] = row.craft.unit end
  end
  return out
end

-- choice / chosenBy of a row: the player's choice ("craft" only when a craft exists), else the cheaper known side.
local function choose(self, row)
  local user = self:GetChoice(row.itemID)
  if user == "buy" or (user == "craft" and row.craft) then
    row.choice, row.chosenBy = user, "user"
    return
  end
  row.chosenBy = "cheaper"
  local craft, buy = row.craft and row.craft.unit, row.buy
  if is_number(craft) and (buy == nil or craft < buy) then
    row.choice = "craft"
  elseif buy ~= nil then
    row.choice = "buy"
  end
end

local resolve_item

-- ReagentRows for the reagents of an allocation that some recipe makes; their crafts at `depth`.
local function build_rows(self, allocation, depth, needer, path, state, trace)
  local rows = {}
  for _, need in ipairs(needs_of(allocation)) do
    local found = recipes():FindRecipesForItem(need.itemID)
    if #found > 0 then
      local row = { itemID = need.itemID, quantity = need.quantity, buy = buy_price(need.itemID), cycle = false }
      row.craft, row.cycle = resolve_item(self, need.itemID, found, depth, needer, path, state, trace)
      choose(self, row)
      rows[#rows + 1] = row
    end
  end
  return rows
end

-- Whether making itemID with `found` would close a loop on the path; marks what decided it in the trace.
local function cycles(itemID, found, path, trace)
  local cut = false
  local function look(kind, id)
    local key = (kind == "items" and "i" or "r") .. id
    if on_path(path, kind, id) then
      trace.cuts[key] = true
      cut = true
    else
      trace.deps[key] = true
    end
  end
  look("items", itemID)
  for _, f in ipairs(found) do
    look("recipes", f.recipeID)
    for _, reagentID in ipairs(schematic_reagents(f.recipeID)) do look("items", reagentID) end
  end
  return cut
end

-- The craft of one item at `depth` (nil = buy only) and whether a cycle made it buy only.
resolve_item = function(self, itemID, found, depth, needer, path, state, parentTrace)
  local trace = new_trace()
  if cycles(itemID, found, path, trace) then
    merge(parentTrace, trace)
    return nil, true
  end
  if depth > Intermediates.MAX_DEPTH then return nil, false end
  local key = itemID .. ":" .. depth
  local memo = state.memo[key]
  if memo and memo_valid(memo, path) then
    merge(parentTrace, memo.trace)
    return memo.craft, false
  end
  if state.nodes >= Intermediates.MAX_NODES then
    state.truncated = true
    return nil, false
  end

  local best
  push(path, "items", itemID)
  for _, f in ipairs(found) do
    push(path, "recipes", f.recipeID)
    -- The character that needs the item first (no mail on a tie), then WhoCanCraft's order.
    local crafters = {}
    for _, c in ipairs(recipes():WhoCanCraft(f.recipeID)) do
      if c == needer then table.insert(crafters, 1, c) else crafters[#crafters + 1] = c end
    end
    for _, charKey in ipairs(crafters) do
      local plain, stopped = counted_evaluate(state, f.recipeID, charKey, { targetQuality = f.quality })
      if stopped then break end
      if plain and not (type(plain.flags) == "table" and plain.flags.unreachableTarget) then
        local children = build_rows(self, plain.allocation, depth + 1, charKey, path, state, trace)
        local result = plain
        local passed = chosen_prices(children)
        if next(passed) ~= nil then
          local priced = counted_evaluate(state, f.recipeID, charKey, { targetQuality = f.quality, reagentPrices = passed })
          if priced then result = priced end
        end
        local unit = unit_cost(result)
        if best == nil or (unit ~= nil and (best.unit == nil or unit < best.unit)) then
          best = { recipeID = f.recipeID, quality = f.quality, charKey = charKey, unit = unit,
            yield = is_number(result.expectedYield) and result.expectedYield or nil, depth = depth, children = children }
        end
      end
    end
    pop(path, "recipes", f.recipeID)
  end
  pop(path, "items", itemID)

  merge(parentTrace, trace)
  -- A truncated subtree is not remembered: a later parent may still have budget for it.
  if not state.truncated then state.memo[key] = { craft = best, trace = trace } end
  return best, false
end

-- Resolution = { rows = { ReagentRow }, reagentPrices = { [itemID] = copper }, result = RecipeResult|nil,
-- base = RecipeResult, saving = copper|nil, truncated = boolean } for recipeID crafted by charKey (nil = current) with
-- Evaluate opts; nil without a schematic.
-- ReagentRow = { itemID, quantity (per craft), buy = copper|nil, craft = { recipeID, quality, charKey, unit =
-- copper|nil, yield, depth, children = { ReagentRow } } | nil, choice = "craft"|"buy"|nil, chosenBy =
-- "user"|"cheaper", cycle = boolean }. Rows are the reagents of base's plan that Recipes:FindRecipesForItem knows.
-- result = Evaluate with opts + { reagentPrices } when any row is crafted at a known cost; saving = base.reagentCost -
-- result.reagentCost when both are numbers.
function Intermediates:Resolve(recipeID, charKey, opts)
  charKey = charKey or ns.FS:CharKey()
  local base = recipes():Evaluate(recipeID, charKey, opts)
  if not base then return nil end
  local state, path = new_state(), new_path()
  push(path, "recipes", recipeID)
  local schematic = scanner():GetSchematic(recipeID)
  for _, itemID in pairs(schematic and schematic.outputItemIDs or {}) do push(path, "items", itemID) end
  local rows = build_rows(self, base.allocation, 1, charKey, path, state, nil)
  local reagentPrices = chosen_prices(rows)
  local result, saving
  if next(reagentPrices) ~= nil then
    local o = copy(opts)
    o.reagentPrices = reagentPrices
    result = recipes():Evaluate(recipeID, charKey, o)
    if result and is_number(base.reagentCost) and is_number(result.reagentCost) then
      saving = base.reagentCost - result.reagentCost
    end
  end
  return { rows = rows, reagentPrices = reagentPrices, result = result, base = base, saving = saving,
    truncated = state.truncated }
end

-- The depth-0 craft of one item: { recipeID, quality, charKey, unit, yield } (its reagents resolved below it, the
-- current character first on a tie), or nil when no recipe makes it or nobody can craft it.
function Intermediates:CraftOption(itemID)
  if type(itemID) ~= "number" then return nil end
  local found = recipes():FindRecipesForItem(itemID)
  if #found == 0 then return nil end
  local craft = resolve_item(self, itemID, found, 0, ns.FS:CharKey(), new_path(), new_state(), nil)
  if not craft then return nil end
  return { recipeID = craft.recipeID, quality = craft.quality, charKey = craft.charKey, unit = craft.unit,
    yield = craft.yield }
end

---------------------------------------------------------------------------
-- Queueing
---------------------------------------------------------------------------

local function positive_int(n)
  if not is_number(n) then return nil end
  n = math.floor(n)
  return n >= 1 and n or nil
end

local function stored_entry(queue, id)
  if id == nil then return nil end
  for _, e in ipairs(queue:GetEntries()) do
    if e.id == id and not e.isRestock then return e end
  end
  return nil
end

-- The sub-crafts a resolution needs for `quantity` crafts: { { row, crafts, children } }, depth first. What a character
-- already holds (Scanner:GetOwnedCount, the warband per queueUseWarband) is used before anything is crafted, and each
-- unit only once.
local function plan_sub_crafts(rows, multiplier, needer, held)
  local useWarband = recipes():GetSetting("queueUseWarband") and true or false
  local out = {}
  for _, row in ipairs(rows) do
    if row.choice == "craft" and row.craft then
      local key = tostring(needer) .. ":" .. row.itemID
      if held[key] == nil then held[key] = scanner():GetOwnedCount(row.itemID, needer, useWarband) or 0 end
      local need = row.quantity * multiplier
      local short = need - held[key]
      held[key] = math.max(0, held[key] - need)
      if short > 0 then
        local yield = row.craft.yield
        if not is_number(yield) or yield <= 0 then yield = 1 end
        local crafts = math.ceil(short / yield)
        out[#out + 1] = { row = row, crafts = crafts,
          children = plan_sub_crafts(row.craft.children, crafts, row.craft.charKey, held) }
      end
    end
  end
  return out
end

-- Queues spec's recipe with the sub-crafts its chosen-to-craft reagents need, each ahead of the entry that needs it,
-- so Craft Next (queue order) makes it first. spec = { recipeID, quantity, charKey, targetQuality?,
-- useConcentration?, queueID? }: the parent is spec.queueID when that is a stored entry, else it is added first. Then,
-- depth first and post-order, each row chosen to craft that the needing character does not hold enough of gets
-- Queue:Add({ recipeID, quantity = ceil(short / yield), charKey = its crafter, targetQuality = its quality, parentID },
-- { before = parentID }). Returns { parentID, subIDs } (subIDs in queue order), or nil and "readonly", "noSchematic",
-- "nothing" (no sub-craft is needed: nothing is queued) or "invalid" (no recipeID or quantity).
-- Called only from the profession panel's "Queue with sub-crafts" click (one click queues them all).
function Intermediates:QueueSubCrafts(spec)
  if not writable() then return nil, "readonly" end
  if type(spec) ~= "table" or type(spec.recipeID) ~= "number" then return nil, "invalid" end
  local quantity = positive_int(spec.quantity)
  if not quantity then return nil, "invalid" end
  local queue = module("Queue")
  local charKey = spec.charKey or ns.FS:CharKey()
  local existing = queue and stored_entry(queue, spec.queueID)
  if existing then charKey = existing.charKey end
  local res = self:Resolve(spec.recipeID, charKey,
    { targetQuality = spec.targetQuality, useConcentration = spec.useConcentration })
  if not res then return nil, "noSchematic" end
  local plan = plan_sub_crafts(res.rows, quantity, charKey, {})
  if #plan == 0 then return nil, "nothing" end

  local parentID = existing and existing.id or queue:Add({ recipeID = spec.recipeID, quantity = quantity,
    charKey = charKey, targetQuality = spec.targetQuality, useConcentration = spec.useConcentration })
  if not parentID then return nil, "readonly" end
  local subIDs = {}
  local function add(nodes, parent)
    for _, node in ipairs(nodes) do
      local craft = node.row.craft
      local id = queue:Add({ recipeID = craft.recipeID, quantity = node.crafts, charKey = craft.charKey,
        targetQuality = craft.quality, parentID = parent }, { before = parent })
      if id then
        add(node.children, id)
        subIDs[#subIDs + 1] = id
      end
    end
  end
  add(plan, parentID)
  -- Post-order adds put children first: list the ids in the queue's order.
  local position = {}
  for i, e in ipairs(queue:GetEntries()) do position[e.id] = i end
  table.sort(subIDs, function(a, b) return (position[a] or 0) < (position[b] or 0) end)
  return { parentID = parentID, subIDs = subIDs }
end
