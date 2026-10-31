local _, ns = ...

-- Small helpers shared by the phase-3 view models (CharactersView, PlannerView): number checks, whole-number text,
-- the dash and separator glyphs, colour wrapping and call-time module lookup. Pure; no frames.
local U = {}
ns.UI = ns.UI or {}
ns.UI.ViewUtil = U

U.EM_DASH = "\226\128\148"   -- "—": unknown
U.DOT = " \194\183 "         -- " · ": separator

-- A real number (not NaN, not ±infinite).
function U.finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

-- A number as whole-number text (rounded down).
function U.whole(v) return tostring(math.floor(v)) end

-- Wraps text in a colour code ("|cffrrggbb").
function U.color(code, text) return code .. text .. "|r" end

-- Another module, looked up at call time (nil when it does not exist).
function U.module(name)
  local m = ns.FS:GetModule(name, true)
  return m
end

-- Narrow-cell money: OrdersPanel's CompactMoney ("1,234g", "45s", "7c") when loaded (it loads after the view files),
-- else the full FormatMoney; "--" for unknown money.
function U.compactMoney(copper)
  local panel = ns.UI.OrdersPanel
  local text = panel and panel.CompactMoney and panel.CompactMoney(copper) or nil
  if text then return text end
  return ns.UI.FormatMoney(copper)
end
