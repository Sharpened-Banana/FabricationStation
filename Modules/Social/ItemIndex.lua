local ADDON_NAME, ns = ...

-- ItemIndex: itemID -> recipeIDs, the reverse index the guild tooltip line needs (a tooltip knows an item, the guild
-- data knows recipes). A plain object; the resolver turns a recipeID into the item IDs it produces and is injected
-- (Guild.ResolveOutputs in the addon, a fake in specs). Pure data, no timers, no saved state: Guild rebuilds it from
-- the stored profiles after login and keeps it up to date.
ns.Social = ns.Social or {}
local ItemIndex = {}
ns.Social.ItemIndex = ItemIndex

local Index = {}
Index.__index = Index

-- resolve(recipeID) -> { itemID }. A raising or malformed resolver counts as "nothing resolved".
function ItemIndex.New(resolve)
  return setmetatable({ resolve = resolve, byItem = {}, known = {} }, Index)
end

local function positive_integer(v)
  return type(v) == "number" and v >= 1 and v == math.floor(v) and v < 2 ^ 31
end

-- Indexes recipeID under every item it produces. Idempotent for a recipe that resolved; a recipe that resolved to
-- nothing (its schematic is not cached yet) is not remembered, so a later Add tries again.
function Index:Add(recipeID)
  if not positive_integer(recipeID) or self.known[recipeID] then return end
  local ok, outputs = pcall(self.resolve, recipeID)
  if not ok or type(outputs) ~= "table" then return end
  local any = false
  for _, itemID in ipairs(outputs) do
    if positive_integer(itemID) then
      local list = self.byItem[itemID]
      if not list then list = {}; self.byItem[itemID] = list end
      local present = false
      for _, id in ipairs(list) do
        if id == recipeID then present = true; break end
      end
      if not present then list[#list + 1] = recipeID end
      any = true
    end
  end
  if any then self.known[recipeID] = true end
end

-- A copy of the recipeIDs that produce itemID, in the order they were added ({} when none).
function Index:RecipesFor(itemID)
  local list = self.byItem[itemID]
  local out = {}
  if list then
    for i, id in ipairs(list) do out[i] = id end
  end
  return out
end

function Index:Has(recipeID)
  return self.known[recipeID] == true
end
