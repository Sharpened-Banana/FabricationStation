local _, ns = ...

-- FeatureLines: the core registrar that puts the phase 7 features' lines where the player looks. A small always-on
-- module (as AltsTooltips and OrdersWidgets): it registers its providers in OnInitialize, and a registration cannot be
-- undone, so each provider itself returns {} while the feature's module is off (the module's own method says so).
--
-- Item tooltips: Tooltips:RegisterLineProvider(id, fn(itemID) -> { {left, right} }) for
--   "saleLog"  SaleLog:TooltipLines(itemID): "Your sales", "Last sale", "Listed now".
-- Tasks 12 and 14 add their crafting-panel providers here, in that order ("optionals", then "intermediates").
--
-- Errors: a provider runs through ns.FS:SafeCall("FeatureLines:<id>", ...). That source is not a module, so a failure
-- is only logged (Diagnostics lists it under that name) and the tooltip shows nothing from the provider; the next
-- tooltip tries again, and neither the feature's module nor Tooltips is turned off.
-- This file is listed after UI/Tooltips.lua and the modules it reads (TOC); a world without Tooltips registers nothing.
local FeatureLines = ns.FS:NewModule("FeatureLines")
FeatureLines.coreModule = true

-- id -> { module name, method }: the lines come from module:method(itemID).
FeatureLines.TOOLTIP_PROVIDERS = {
  { id = "saleLog", module = "SaleLog", method = "TooltipLines" },
}

-- The lines of one provider, or {} when its module or method is missing or it fails.
local function lines_of(spec, itemID)
  local module = ns.FS:GetModule(spec.module, true)
  local method = module and module[spec.method]
  if type(method) ~= "function" then return {} end
  local ok, lines = ns.FS:SafeCall("FeatureLines:" .. spec.id, method, module, itemID)
  if ok and type(lines) == "table" then return lines end
  return {}
end

function FeatureLines:OnInitialize()
  local tooltips = ns.FS:GetModule("Tooltips", true)
  if not tooltips then return end
  for _, spec in ipairs(self.TOOLTIP_PROVIDERS) do
    tooltips:RegisterLineProvider(spec.id, function(itemID) return lines_of(spec, itemID) end)
  end
end
