local ADDON_NAME, ns = ...

-- Tooltips: extra lines on item tooltips, produced by line providers. A provider is registered as
-- Tooltips:RegisterLineProvider(id, fn(itemID) -> { {left, right}, ... }); CollectLines(itemID) runs them in
-- registration order and the hook adds the lines with tooltip:AddDoubleLine. Phases 3 and 4 add their own
-- providers (holdings, guild crafters) through the same call. Switched on and off by 1a's module toggle.
--
-- Built-in providers (registered first):
--   "craftCost" -> { "Craft cost", "<money> (<character>)" } for the cheapest way to craft the item (every recipe
--                  and quality that produces it, every character who knows the recipe). Ties go to a cost that is
--                  not an estimate, then to the earlier character. "no price" when nothing has a cost, never 0g.
--   "crafters"  -> { "Crafters", "Main, Alt" }, cheapest first, characters without a cost last.
-- Both are gated by the "tooltipCraftCost" setting and nothing else is. Their analysis is cached per item until a
-- recipe, price or data change (FS_RECIPES_CHANGED, FS_PRICES_CHANGED, FS_DATA_CHANGED); providers registered by other modules run on every tooltip, so their lines never go stale.
--
-- No taint: TooltipDataProcessor.AddTooltipPostCall is a post-call that only appends lines. It cannot be removed,
-- so it is registered once and checks the module's enabled state. The body runs in SafeCall("Tooltips"); an
-- erroring provider is disabled for the session and logged as "Tooltips:<id>" without turning the module off.
local Tooltips = ns.FS:NewModule("Tooltips", "AceEvent-3.0")

local SOURCE = "Tooltips"

local providers = {}   -- ordered list of { id, fn, failed }
local byID = {}        -- [id] = entry
local hooked = false
local analysisCache = {}   -- [itemID] = analyse() result (or false: nobody crafts it); shared by the built-in providers

---------------------------------------------------------------------------
-- Providers
---------------------------------------------------------------------------

-- Registers (or replaces in place, keeping its position and clearing a session-long failure) the provider `id`.
function Tooltips:RegisterLineProvider(id, fn)
  if type(id) ~= "string" or id == "" then error("RegisterLineProvider: id must be a non-empty string", 2) end
  if type(fn) ~= "function" then error("RegisterLineProvider: fn must be a function", 2) end
  local entry = byID[id]
  if entry then
    entry.fn, entry.failed = fn, false
  else
    entry = { id = id, fn = fn, failed = false }
    byID[id] = entry
    providers[#providers + 1] = entry
  end
end

-- { {left, right} } from every provider that has not failed, in registration order. A provider that raises is
-- logged as "Tooltips:<id>" and skipped for the rest of the session; malformed results are ignored.
function Tooltips:CollectLines(itemID)
  local out = {}
  for _, entry in ipairs(providers) do
    if not entry.failed then
      local ok, lines = pcall(entry.fn, itemID)
      if not ok then
        entry.failed = true
        ns.FS:LogError(SOURCE .. ":" .. entry.id, tostring(lines))
      elseif type(lines) == "table" then
        for _, line in ipairs(lines) do
          if type(line) == "table" then out[#out + 1] = { line[1], line[2] } end
        end
      end
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Built-in providers: craft cost and crafters
---------------------------------------------------------------------------

local function recipes() return ns.FS:GetModule("Recipes", true) end

local function short_name(charKey)
  return tostring(charKey):match("^([^-]+)") or tostring(charKey)
end

-- better(a, b): candidate a beats b (lower cost; a tie goes to a non-estimated cost; then the earlier one).
local function better(a, b)
  if b == nil then return true end
  if a.cost ~= b.cost then return a.cost < b.cost end
  if a.estimated ~= b.estimated then return not a.estimated end
  return false
end

-- { cheapest = candidate|nil, crafters = { charKey ordered cheapest first } } for itemID, or nil when nobody
-- crafts it. Candidates are { cost, estimated, charKey }.
local function analyse(itemID)
  local R = recipes()
  if not R then return nil end
  local best, order, seen = {}, {}, {}   -- best[charKey] = cheapest candidate of that character
  for _, e in ipairs(R:FindRecipesForItem(itemID)) do
    for _, charKey in ipairs(R:WhoCanCraft(e.recipeID)) do
      if not seen[charKey] then
        seen[charKey] = true
        order[#order + 1] = charKey
      end
      local result = R:Evaluate(e.recipeID, charKey, { targetQuality = e.quality })
      local cost = type(result) == "table" and result.reagentCost or nil
      if type(cost) == "number" and cost == cost then
        local flags = result.flags
        local candidate = { cost = cost, estimated = type(flags) == "table" and flags.estimated and true or false,
          charKey = charKey }
        if better(candidate, best[charKey]) then best[charKey] = candidate end
      end
    end
  end
  if #order == 0 then return nil end
  local rank = {}
  for i, charKey in ipairs(order) do rank[charKey] = i end
  table.sort(order, function(a, b)
    local ca, cb = best[a], best[b]
    if ca and cb then
      if better(ca, cb) then return true end
      if better(cb, ca) then return false end
    elseif ca or cb then
      return ca ~= nil
    end
    return rank[a] < rank[b]
  end)
  return { cheapest = best[order[1]], crafters = order }
end

local function enabled_setting()
  local R = recipes()
  return R ~= nil and R:GetSetting("tooltipCraftCost") and true or false
end

local function analysis(itemID)
  local a = analysisCache[itemID]
  if a == nil then
    a = analyse(itemID) or false
    analysisCache[itemID] = a
  end
  return a or nil
end

local function craft_cost_lines(itemID)
  if not enabled_setting() then return {} end
  local a = analysis(itemID)
  if not a then return {} end
  if a.cheapest then
    local text = ns.UI.FormatMoney(a.cheapest.cost) .. " (" .. short_name(a.cheapest.charKey) .. ")"
    return { { "Craft cost", text } }
  end
  return { { "Craft cost", "no price" } }
end

local function crafters_lines(itemID)
  if not enabled_setting() then return {} end
  local a = analysis(itemID)
  if not a then return {} end
  local names = {}
  for i, charKey in ipairs(a.crafters) do names[i] = short_name(charKey) end
  return { { "Crafters", table.concat(names, ", ") } }
end

local function clear_cache() analysisCache = {} end

Tooltips:RegisterLineProvider("craftCost", craft_cost_lines)
Tooltips:RegisterLineProvider("crafters", crafters_lines)

---------------------------------------------------------------------------
-- Hook
---------------------------------------------------------------------------

local function add_lines(tooltip, data)
  if type(data) ~= "table" or type(data.id) ~= "number" then return end
  for _, line in ipairs(Tooltips:CollectLines(data.id)) do
    tooltip:AddDoubleLine(line[1], line[2])
  end
end

local function on_tooltip(tooltip, data)
  if not Tooltips:IsEnabled() then return end
  ns.FS:SafeCall(SOURCE, add_lines, tooltip, data)
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Tooltips:OnEnable()
  clear_cache()
  self:RegisterMessage(ns.Msg.RECIPES_CHANGED, clear_cache)
  self:RegisterMessage(ns.Msg.PRICES_CHANGED, clear_cache)
  self:RegisterMessage(ns.Msg.DATA_CHANGED, clear_cache)
  if not hooked then
    hooked = true
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, on_tooltip)
  end
end
