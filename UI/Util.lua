local _, ns = ...

-- Display and input helpers shared by every tab. Money is integer copper everywhere else; it is
-- formatted and parsed only here.
local UI = ns.UI or {}
ns.UI = UI

local COPPER_PER_SILVER, COPPER_PER_GOLD = 100, 10000
local MAX_COPPER = 99999990000  -- 9,999,999 gold, the game's gold cap
local UNIT_RANK = { g = 1, s = 2, c = 3 }

-- Formats copper for display; "--" for nil. In game this is GetMoneyString (with coin icons); the
-- fallback is plain text starting at the highest non-zero unit.
function UI.FormatMoney(copper)
  if type(copper) ~= "number" or copper ~= copper then return "--" end
  local abs = math.floor(math.abs(copper))
  local negative = copper < 0 and abs > 0
  if type(GetMoneyString) == "function" then
    return (negative and "-" or "") .. GetMoneyString(abs, true)
  end
  local gold = math.floor(abs / COPPER_PER_GOLD)
  local silver = math.floor((abs % COPPER_PER_GOLD) / COPPER_PER_SILVER)
  local copperPart = abs % COPPER_PER_SILVER
  local text
  if gold > 0 then
    text = ("%dg %ds %dc"):format(gold, silver, copperPart)
  elseif silver > 0 then
    text = ("%ds %dc"):format(silver, copperPart)
  else
    text = ("%dc"):format(copperPart)
  end
  return (negative and "-" or "") .. text
end

-- Parses "12g 34s 5c" (any subset, in that order, any case; whitespace only between tokens) or a
-- plain decimal number meaning gold ("1.5"). Returns copper, or nil for empty, negative, garbage
-- or above-the-gold-cap input.
function UI.ParseMoney(text)
  if type(text) ~= "string" then return nil end
  local s = text:lower():match("^%s*(.-)%s*$")
  if s == "" then return nil end

  local total
  if s:match("^%d+%.?%d*$") or s:match("^%.%d+$") then
    total = tonumber(s) * COPPER_PER_GOLD
  else
    total = 0
    local lastRank, pos = 0, 1
    while pos <= #s do
      local number, unit, nextPos = s:match("^(%d+%.?%d*)([gsc])%s*()", pos)
      if not number then return nil end
      local rank = UNIT_RANK[unit]
      if rank <= lastRank then return nil end
      if unit ~= "g" and number:find(".", 1, true) then return nil end
      local factor = unit == "g" and COPPER_PER_GOLD or unit == "s" and COPPER_PER_SILVER or 1
      total = total + tonumber(number) * factor
      lastRank, pos = rank, nextPos
    end
  end
  total = math.floor(total + 0.5)
  if total > MAX_COPPER then return nil end
  return total
end

-- An item id from plain digits or from an item link ("|Hitem:191460::::|h[Ore]|h"). nil otherwise.
function UI.ParseItemID(text)
  if type(text) ~= "string" then return nil end
  local s = strtrim(text)
  local id = s:match("^%d+$") or s:match("item:(%d+)")
  id = tonumber(id)
  if id and id > 0 then return id end
  return nil
end

-- A coarse age: "never" for nil, then "<1m", "Nm", "Nh", "Nd".
function UI.FormatAge(seconds)
  if type(seconds) ~= "number" then return "never" end
  if seconds < 60 then return "<1m" end
  if seconds < 3600 then return math.floor(seconds / 60) .. "m" end
  if seconds < 86400 then return math.floor(seconds / 3600) .. "h" end
  return math.floor(seconds / 86400) .. "d"
end
