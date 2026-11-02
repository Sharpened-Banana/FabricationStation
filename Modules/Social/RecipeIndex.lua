local ADDON_NAME, ns = ...

-- RecipeIndex: recipeID -> the characters whose stored profile lists it, built from the compact stored profiles
-- (Modules/Social/ProfileStore.lua). A directory read (tooltip, profession panel) asks it who crafts a recipe instead of
-- scanning every stored guild profile. A plain object, no timers and no saved state: Guild's directory code fills it in
-- its index ticks and decides, by comparing HashOf with the stored profile's h, whether an entry is still current.
--
-- An entry is a code, lineIndex * 100 + q * 10 + qc: the index of the first pr line that lists the recipe (the one
-- ProfileStore.Find answers) and that recipe's two qualities (0 = unknown, always 0 for lv = "r").
ns.Social = ns.Social or {}
local RecipeIndex = {}
ns.Social.RecipeIndex = RecipeIndex

local ProfileStore = ns.Social.ProfileStore
local floor = math.floor

local Index = {}
Index.__index = Index

function RecipeIndex.Code(lineIndex, q, qc)
  return lineIndex * 100 + q * 10 + qc
end

function RecipeIndex.Decode(code)
  return floor(code / 100), floor(code / 10) % 10, code % 10
end

function RecipeIndex.New()
  return setmetatable({ byRecipe = {}, byChar = {} }, Index)
end

-- Replaces everything indexed for charKey with the recipes of profile ({ h, lv, pr }). false, and nothing indexed for
-- charKey, when profile.pr is not a table (or charKey is not a string).
function Index:Set(charKey, profile)
  if type(charKey) ~= "string" then return false end
  self:Remove(charKey)
  if type(profile) ~= "table" or type(profile.pr) ~= "table" then return false end
  local ids, byRecipe = {}, self.byRecipe
  for lineIndex, line in ipairs(profile.pr) do
    if type(line) == "table" then
      ProfileStore.Each(line, profile.lv, function(recipeID, q, qc)
        local owners = byRecipe[recipeID]
        if not owners then owners = {}; byRecipe[recipeID] = owners end
        if not owners[charKey] then         -- the first line that lists it, as ProfileStore.Find answers
          owners[charKey] = RecipeIndex.Code(lineIndex, q, qc)
          ids[#ids + 1] = recipeID
        end
      end)
    end
  end
  self.byChar[charKey] = { h = profile.h, ids = ids }
  return true
end

function Index:Remove(charKey)
  local entry = self.byChar[charKey]
  if not entry then return end
  for _, recipeID in ipairs(entry.ids) do
    local owners = self.byRecipe[recipeID]
    if owners then
      owners[charKey] = nil
      if next(owners) == nil then self.byRecipe[recipeID] = nil end
    end
  end
  self.byChar[charKey] = nil
end

-- The hash the character's entries were built from, or nil when nothing is indexed for it.
function Index:HashOf(charKey)
  local entry = self.byChar[charKey]
  return entry and entry.h or nil
end

-- { [charKey] = code } for recipeID, or nil. The live table: callers never change it.
function Index:Lookup(recipeID)
  return self.byRecipe[recipeID]
end

-- Every indexed charKey, sorted.
function Index:Keys()
  local out = {}
  for charKey in pairs(self.byChar) do out[#out + 1] = charKey end
  table.sort(out)
  return out
end
