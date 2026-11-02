local _, ns = ...
local L = ns.L

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

-- A comma list of display words ("a, b, c"). The separator is a key, so a translation can use its own; the lookup
-- happens at call time. Each part is already a whole phrase (or data such as a name).
function UI.JoinList(parts)
  return table.concat(parts, ns.L[", "])
end

-- The generated skill lines { [skillLineID] = { expansionID, ... } }, or nil without that data.
local function profession_lines()
  local GD = ns.GameData
  local lines = GD and type(GD.Get) == "function" and GD.Get("ProfessionLines") or nil
  return type(lines) == "table" and lines or nil
end

-- The expansionID of a skill line (generated ProfessionLines); nil for an unknown line or without that data.
function UI.ExpansionOfSkillLine(skillLineID)
  local lines = profession_lines()
  local info = lines and skillLineID ~= nil and lines[skillLineID]
  return type(info) == "table" and type(info.expansionID) == "number" and info.expansionID or nil
end

-- recipeID -> skillLineID from the generated RecipeSources (bySkillLine), built once per RecipeSources table (specs and
-- a data update may define another). Only lines with a known expansion count; a recipe on several lines takes the lowest.
local recipeLineIndex = { source = nil, map = nil }
local function recipe_line(recipeID)
  local GD = ns.GameData
  local sources = GD and type(GD.Get) == "function" and GD.Get("RecipeSources") or nil
  local by = type(sources) == "table" and sources.bySkillLine
  if type(by) ~= "table" then return nil end
  if recipeLineIndex.source ~= by then
    local lines, map = {}, {}
    for skillLine in pairs(by) do
      if type(skillLine) == "number" and UI.ExpansionOfSkillLine(skillLine) then lines[#lines + 1] = skillLine end
    end
    table.sort(lines)
    for i = #lines, 1, -1 do   -- the lowest line is written last, so it wins
      if type(by[lines[i]]) == "table" then
        for id in pairs(by[lines[i]]) do map[id] = lines[i] end
      end
    end
    recipeLineIndex.source, recipeLineIndex.map = by, map
  end
  return recipeLineIndex.map[recipeID]
end

-- recipeID -> expansionID over the recipes the scanned characters list on a line of a known expansion (a dropped
-- profession is skipped). A recipe on lines of two expansions takes the lowest expansionID, so the answer does not depend
-- on table order.
local function scanned_recipe_expansions()
  local map = {}
  local scanner = ns.FS:GetModule("Scanner", true)
  if not (scanner and scanner.GetCharacters and scanner.GetCharacter) then return map end
  for _, charKey in ipairs(scanner:GetCharacters() or {}) do
    local record = scanner:GetCharacter(charKey)
    local professions = type(record) == "table" and record.professions
    if type(professions) == "table" then
      for skillLine, p in pairs(professions) do
        local expansion = type(p) == "table" and not p.dropped and type(p.recipes) == "table"
          and UI.ExpansionOfSkillLine(skillLine)
        if expansion then
          for recipeID in pairs(p.recipes) do
            if map[recipeID] == nil or expansion < map[recipeID] then map[recipeID] = expansion end
          end
        end
      end
    end
  end
  return map
end

-- The expansionID a recipe belongs to: the one rule behind every view that sorts recipes by expansion (the Dashboard's
-- "Top crafts by profit" filter, the Ledger's and the header's expansion profit). In order: the generated RecipeSources
-- skill line of the recipe (static; no scan needed); only when that has no entry, the skill line of the schematic
-- already cached (never fetched here: this runs over every ranked result); only then the recipes the scanned characters
-- list on a line with a known expansion (what the header has always counted; the lowest expansion when two lines list
-- it). nil when none of these knows it: such a recipe is in no expansion's filter and counted nowhere, never guessed.
-- `memo` (optional): a table the caller makes once per pass over many recipes (one filter, one summary). The scanned map
-- is built into it on the first recipe that needs it and reused for the rest of the pass, instead of once per recipe.
-- Only that map is kept, never an answer, and a new pass (a new memo) reads the characters again; without a memo each
-- call reads them itself.
function UI.ExpansionOfRecipe(recipeID, memo)
  if recipeID == nil then return nil end
  local line = recipe_line(recipeID)
  if line then return UI.ExpansionOfSkillLine(line) end
  local scanner = ns.FS:GetModule("Scanner", true)
  if scanner and scanner.GetCachedSchematic then
    local schematic = scanner:GetCachedSchematic(recipeID)
    local expansion = type(schematic) == "table" and UI.ExpansionOfSkillLine(schematic.skillLineID) or nil
    if expansion then return expansion end
  end
  memo = memo or {}
  if memo.scanned == nil then memo.scanned = scanned_recipe_expansions() end
  return memo.scanned[recipeID]
end

-- The display name of an expansion, shared by every place that names one (the header's profit, the Dashboard filter):
-- what the client told the Scanner for one of its skill lines (a profession record's expansionName), else the client's
-- own EXPANSION_NAME<id> when it is a string, else the known name of the ID (Midnight is 11). nil when none is known;
-- the caller picks its own last resort.
function UI.ExpansionName(expansionID)
  if type(expansionID) ~= "number" then return nil end
  local lines = profession_lines()
  local ids = {}
  for skillLine, info in pairs(lines or {}) do
    if type(skillLine) == "number" and type(info) == "table" and info.expansionID == expansionID then
      ids[#ids + 1] = skillLine
    end
  end
  table.sort(ids)
  local scanner = ns.FS:GetModule("Scanner", true)
  if scanner and scanner.GetCharacters and scanner.GetCharacter then
    for _, charKey in ipairs(scanner:GetCharacters() or {}) do
      local record = scanner:GetCharacter(charKey)
      local professions = type(record) == "table" and record.professions
      if type(professions) == "table" then
        for _, skillLine in ipairs(ids) do
          local p = professions[skillLine]
          if type(p) == "table" and not p.dropped and type(p.expansionName) == "string" and p.expansionName ~= "" then
            return p.expansionName
          end
        end
      end
    end
  end
  local client = _G["EXPANSION_NAME" .. expansionID]   -- locale: joined (a client global name)
  if type(client) == "string" and client ~= "" then return client end
  if expansionID == 11 then return L["Midnight"] end
  return nil
end

-- A coarse age: "never" for nil, then "<1m", "Nm", "Nh", "Nd" (each unit letter is a key).
function UI.FormatAge(seconds)
  if type(seconds) ~= "number" then return L["never"] end
  if seconds < 60 then return L["<1m"] end
  if seconds < 3600 then return L["%dm"]:format(math.floor(seconds / 60)) end
  if seconds < 86400 then return L["%dh"]:format(math.floor(seconds / 3600)) end
  return L["%dd"]:format(math.floor(seconds / 86400))
end
