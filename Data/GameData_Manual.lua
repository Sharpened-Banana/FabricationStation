-- Hand-maintained GameData (not generated). Keep it Lua 5.1 with no WoW globals.
local ADDON_NAME, ns = ...

-- [skillLineID] = currencyID; Midnight skill lines (tools/gamedata/sources/skill_lines.csv) to the generator's
-- "Artisan <profession>'s Moxie" candidates, build 12.1.5.70688. Cooking has no Moxie.
ns.GameData.Define("MoxieCurrency", 70688, {
  [2906] = 3256, -- Alchemy
  [2907] = 3257, -- Blacksmithing
  [2909] = 3258, -- Enchanting
  [2910] = 3259, -- Engineering
  [2912] = 3260, -- Herbalism
  [2913] = 3261, -- Inscription
  [2914] = 3262, -- Jewelcrafting
  [2915] = 3263, -- Leatherworking
  [2916] = 3264, -- Mining
  [2917] = 3265, -- Skinning
  [2918] = 3266, -- Tailoring
})
