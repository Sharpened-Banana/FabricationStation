local _, ns = ...
local L = ns.L

-- FeatureLines: the core registrar that puts the phase 7 features' lines where the player looks. A small always-on
-- module (as AltsTooltips and OrdersWidgets): it registers its providers in OnInitialize, and a registration cannot be
-- undone, so each provider itself returns {} while the feature's module is off (the module's own method says so).
--
-- Item tooltips: Tooltips:RegisterLineProvider(id, fn(itemID) -> { {left, right} }) for
--   "saleLog"  SaleLog:TooltipLines(itemID): "Your sales", "Last sale", "Listed now".
-- Crafting side panel (ProfessionPanel:RegisterLineProvider / RegisterLineAction), registered in this order: Task 12's
-- "optionals" row and "queueOptionals" button, then Task 14's "intermediates".
--
-- Errors: a provider runs under pcall; a failure is logged once per session per provider as source
-- "FeatureLines:<id>" (Diagnostics lists it under that name; a tooltip that fails again every hover would otherwise
-- push older errors out of the capped list) and the tooltip shows nothing from the provider. The next tooltip tries
-- again, and neither the feature's module nor Tooltips is turned off.
-- This file is listed after UI/Tooltips.lua and the modules it reads (TOC); a world without Tooltips registers nothing.
local FeatureLines = ns.FS:NewModule("FeatureLines")
FeatureLines.coreModule = true

-- id -> { module name, method }: the lines come from module:method(itemID).
FeatureLines.TOOLTIP_PROVIDERS = {
  { id = "saleLog", module = "SaleLog", method = "TooltipLines" },
}

local logged = {}   -- [id] = true once its first failure of the session was logged

-- fn() under pcall: its value, or nil when it raises. The first failure of an id in a session is logged as
-- "FeatureLines:<id>" with the stack.
local function guarded(id, fn)
  local stack
  -- A closure, not xpcall(f, handler, ...): PUC Lua 5.1 (the CI) takes no extra arguments.
  local ok, value = xpcall(fn, function(err)
    stack = debugstack and debugstack(2) or nil
    return err
  end)
  if ok then return value end
  if not logged[id] then
    logged[id] = true
    ns.FS:LogError("FeatureLines:" .. id, tostring(value), stack)
  end
  return nil
end

-- The lines of one provider, or {} when its module or method is missing or it fails.
local function lines_of(spec, itemID)
  local module = ns.FS:GetModule(spec.module, true)
  local method = module and module[spec.method]
  if type(method) ~= "function" then return {} end
  local lines = guarded(spec.id, function() return method(module, itemID) end)
  return type(lines) == "table" and lines or {}
end

---------------------------------------------------------------------------
-- Crafting side panel: optionals (phase 7, Task 12)
---------------------------------------------------------------------------

local function item_name(itemID)
  local name = C_Item.GetItemNameByID(itemID)
  if type(name) == "string" and name ~= "" then return name end
  return "item:" .. tostring(itemID)
end

local function names_of(itemIDs)
  local names = {}
  for i, itemID in ipairs(itemIDs) do names[i] = item_name(itemID) end
  return ns.UI.JoinList(names)
end

-- Recipes:BestOptionals for the panel's recipe: nil when the search is off or the recipe has no optional slot. The
-- result is memoised by Recipes, and it runs for the one recipe the panel shows, never for a list.
local function best_optionals(recipeID, charKey)
  local recipes = ns.FS:GetModule("Recipes", true)
  if not recipes then return nil end
  return recipes:BestOptionals(recipeID, charKey, {})
end

local function writable()
  return ns.FS.db ~= nil and not ns.FS.dbIsNewer
end

-- The "Best optionals" rows: the pick with its gain (or that none adds profit), then how many were left out.
function FeatureLines.OptionalLines(recipeID, charKey)
  local best = best_optionals(recipeID, charKey)
  if not best then return {} end
  local out = {}
  if #best.itemIDs > 0 then
    out[1] = { L["Best optionals"], L["%s (+%s)"]:format(names_of(best.itemIDs), ns.UI.FormatMoney(best.gain)) }
  else
    out[1] = { L["Best optionals"], L["none adds profit"] }
  end
  local skipped = best.skipped or {}
  local count = (skipped.unknownPrice or 0) + (skipped.noEffect or 0)
  if count > 0 then out[#out + 1] = { "", L["%d skipped: no price or no known effect"]:format(count) } end
  return out
end

-- What the panel last queued, for the status next to the button: { recipeID, charKey, text }. Session only.
local lastQueued

-- The "Queue with best optionals" button: nil without a search result. Enabled with a pick and a writable queue; the
-- click queues one craft with the pick (Queue:Add), nothing else.
function FeatureLines.OptionalAction(recipeID, charKey)
  local best = best_optionals(recipeID, charKey)
  if not best then return nil end
  local pick = {}
  for i, itemID in ipairs(best.itemIDs) do pick[i] = itemID end
  local canWrite = writable()
  local spec = { text = L["Queue with best optionals"], enabled = #pick > 0 and canWrite,
    onClick = function()
      local queue = ns.FS:GetModule("Queue", true)
      if #pick == 0 or not queue or not writable() then return end
      if queue:Add({ recipeID = recipeID, quantity = 1, charKey = charKey, optionalItemIDs = pick }) then
        lastQueued = { recipeID = recipeID, charKey = charKey, text = L["Queued with %s"]:format(names_of(pick)) }
      end
    end }
  if not canWrite then
    spec.status = L["Saved data is from a newer version of FabricationStation; the queue is read-only."]
  elseif lastQueued and lastQueued.recipeID == recipeID and lastQueued.charKey == charKey then
    spec.status = lastQueued.text
  end
  return spec
end

function FeatureLines:OnInitialize()
  local tooltips = ns.FS:GetModule("Tooltips", true)
  if tooltips then
    for _, spec in ipairs(self.TOOLTIP_PROVIDERS) do
      tooltips:RegisterLineProvider(spec.id, function(itemID) return lines_of(spec, itemID) end)
    end
  end
  local panel = ns.FS:GetModule("ProfessionPanel", true)
  if panel then
    -- Guarded here, so a failure is logged once as "FeatureLines:<id>" and the panel keeps the provider (its own
    -- catch would drop it for the session).
    panel:RegisterLineProvider("optionals", function(recipeID, charKey)
      local lines = guarded("optionals", function() return FeatureLines.OptionalLines(recipeID, charKey) end)
      return type(lines) == "table" and lines or {}
    end)
    panel:RegisterLineAction("queueOptionals", function(recipeID, charKey)
      return guarded("queueOptionals", function() return FeatureLines.OptionalAction(recipeID, charKey) end)
    end)
  end
end
