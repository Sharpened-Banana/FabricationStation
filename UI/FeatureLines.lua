local _, ns = ...
local L = ns.L

-- FeatureLines: the core registrar that puts the phase 7 features' lines where the player looks. A small always-on
-- module (as AltsTooltips and OrdersWidgets): it registers its providers in OnInitialize, and a registration cannot be
-- undone, so each provider itself returns {} while the feature's module is off (the module's own method says so).
--
-- Item tooltips: Tooltips:RegisterLineProvider(id, fn(itemID) -> { {left, right} }) for
--   "saleLog"  SaleLog:TooltipLines(itemID): "Your sales", "Last sale", "Listed now".
-- Crafting side panel (ProfessionPanel:RegisterLineProvider / RegisterLineAction), registered in this order: Task 12's
-- "optionals" row and "queueOptionals" button, then Task 14's "intermediates" rows and "queueSubCrafts" button.
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

-- The "Best optionals" rows: the pick with its gain, or that none adds profit (only when the search ran: with an
-- unknown plain profit it says so instead), then how many were left out.
function FeatureLines.OptionalLines(recipeID, charKey)
  local best = best_optionals(recipeID, charKey)
  if not best then return {} end
  local out = {}
  local base = best.base
  if type(base) ~= "table" or type(base.profit) ~= "number" then
    -- The plain craft has no profit (a price is missing), so the search could not rank anything: unknown, not "none".
    out[1] = { L["Best optionals"], L["profit unknown (prices missing)"] }
  elseif #best.itemIDs > 0 then
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

---------------------------------------------------------------------------
-- Crafting side panel: intermediates (phase 7, Task 14)
---------------------------------------------------------------------------

FeatureLines.MAX_INTERMEDIATE_ROWS = 6
local DOT = " \194\183 "

local function money_or_unknown(copper)
  if type(copper) ~= "number" then return "?" end
  return ns.UI.FormatMoney(copper)
end

-- Intermediates:Resolve for the panel's recipe, or nil while the module is off or without a schematic.
local function resolution(recipeID, charKey)
  local intermediates = ns.FS:GetModule("Intermediates", true)
  if not intermediates or not intermediates:IsEnabled() then return nil end
  return intermediates:Resolve(recipeID, charKey), intermediates
end

local function row_state(row)
  if row.cycle then return L["buy only (cycle)"] end
  if row.choice == "craft" then return L["crafting"] end
  return L["buying"]
end

-- One row per craftable reagent (at most MAX_INTERMEDIATE_ROWS, then "+N more"): its craft cost, its buy price and
-- what the plan does; then the saving per craft when crafting some of them is cheaper.
function FeatureLines.IntermediateLines(recipeID, charKey)
  local res = resolution(recipeID, charKey)
  if not res or #res.rows == 0 then return {} end
  local out = {}
  for i, row in ipairs(res.rows) do
    if i > FeatureLines.MAX_INTERMEDIATE_ROWS then
      out[#out + 1] = { L["+%d more"]:format(#res.rows - FeatureLines.MAX_INTERMEDIATE_ROWS), "" }
      break
    end
    out[#out + 1] = { item_name(row.itemID), L["craft %s \194\183 buy %s \194\183 %s"]:format(
      money_or_unknown(row.craft and row.craft.unit), money_or_unknown(row.buy), row_state(row)) }
  end
  if type(res.saving) == "number" and res.saving > 0 then
    out[#out + 1] = { L["With intermediates"], L["saves %s per craft"]:format(ns.UI.FormatMoney(res.saving)) }
  end
  return out
end

local lastSubCrafts   -- { recipeID, charKey, text }: what the panel last queued with sub-crafts (session only)

local function short_name(charKey)
  return tostring(charKey):match("^([^-]+)") or tostring(charKey)
end

-- The status after a click: how many sub-crafts went first, and which of them another character makes.
local function sub_crafts_text(queued, charKey)
  local n = #queued.subIDs
  local text = n == 1 and L["Queued 1 sub-craft first"] or L["Queued %d sub-crafts first"]:format(n)
  local queue = ns.FS:GetModule("Queue", true)
  local scanner = ns.FS:GetModule("Scanner", true)
  local wanted = {}
  for _, id in ipairs(queued.subIDs) do wanted[id] = true end
  local items, chars, seenChar = {}, {}, {}
  for _, e in ipairs(queue and queue:GetEntries() or {}) do
    if wanted[e.id] and e.charKey ~= charKey then
      local schematic = scanner and scanner:GetSchematic(e.recipeID)
      local outputs = schematic and schematic.outputItemIDs or {}
      local itemID = outputs[e.targetQuality or 1] or outputs[1]
      items[#items + 1] = itemID and item_name(itemID) or (schematic and schematic.name) or tostring(e.recipeID)
      if not seenChar[e.charKey] then
        seenChar[e.charKey] = true
        chars[#chars + 1] = short_name(e.charKey)
      end
    end
  end
  if #items > 0 then
    text = text .. DOT .. L["%s crafts on %s: mail the reagents"]:format(ns.UI.JoinList(items), ns.UI.JoinList(chars))
  end
  return text
end

-- The "Queue with sub-crafts" button: nil while the module is off or without a craftable reagent. Enabled when a
-- reagent is chosen to craft and the queue is writable; the click queues one craft of the recipe with its sub-crafts
-- ahead of it (Intermediates:QueueSubCrafts), nothing else.
function FeatureLines.SubCraftAction(recipeID, charKey)
  local res, intermediates = resolution(recipeID, charKey)
  if not res or #res.rows == 0 then return nil end
  local crafting = false
  for _, row in ipairs(res.rows) do
    if row.choice == "craft" and row.craft then crafting = true end
  end
  local canWrite = writable()
  local spec = { text = L["Queue with sub-crafts"], enabled = crafting and canWrite,
    onClick = function()
      if not crafting or not writable() then return end
      local queued, reason = intermediates:QueueSubCrafts({ recipeID = recipeID, quantity = 1, charKey = charKey })
      if queued then
        lastSubCrafts = { recipeID = recipeID, charKey = charKey, text = sub_crafts_text(queued, charKey) }
      elseif reason == "nothing" then
        lastSubCrafts = { recipeID = recipeID, charKey = charKey, text = L["No sub-craft needed: the reagents are on hand"] }
      end
    end }
  if not canWrite then
    spec.status = L["Saved data is from a newer version of FabricationStation; the queue is read-only."]
  elseif lastSubCrafts and lastSubCrafts.recipeID == recipeID and lastSubCrafts.charKey == charKey then
    spec.status = lastSubCrafts.text
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
    panel:RegisterLineProvider("intermediates", function(recipeID, charKey)
      local lines = guarded("intermediates", function() return FeatureLines.IntermediateLines(recipeID, charKey) end)
      return type(lines) == "table" and lines or {}
    end)
    panel:RegisterLineAction("queueSubCrafts", function(recipeID, charKey)
      return guarded("queueSubCrafts", function() return FeatureLines.SubCraftAction(recipeID, charKey) end)
    end)
  end
end
