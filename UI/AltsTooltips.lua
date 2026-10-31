local _, ns = ...

-- The "holdings" item-tooltip line provider (phase 3): what the visible characters and the warband bank hold of the
-- item (Alts:HoldingsLines). A small core registrar module, as phase 2's OrdersWidgets: it registers the provider
-- with 1b's Tooltips:RegisterLineProvider in OnInitialize (registration cannot be undone, so the provider itself
-- returns {} while the Alts module is off; Alts:HoldingsLines returns {} while its tooltipHoldings setting is off).
-- 1b caches and gates only its own built-in providers, so these lines are computed on every tooltip and follow bag,
-- bank and warband changes without a cache to clear. No "crafters" provider here: 1b already shows that line.
-- This file is listed after UI/Tooltips.lua (TOC) so 1b-only test worlds never load it (preflight rows 22-23).
local AltsTooltips = ns.FS:NewModule("AltsTooltips")
AltsTooltips.coreModule = true

local function holdings_lines(itemID)
  local alts = ns.FS:GetModule("Alts", true)
  if not (alts and alts:IsEnabled()) then return {} end
  return alts:HoldingsLines(itemID)
end

function AltsTooltips:OnInitialize()
  local tooltips = ns.FS:GetModule("Tooltips", true)
  if tooltips then tooltips:RegisterLineProvider("holdings", holdings_lines) end
end
