-- GameData runtime: registry for generated and manual data tables. Pure Lua 5.1, no WoW globals.
-- Generated data files call ns.GameData.Define("<Name>", <build>, <table>); a nil build means
-- the table has not been generated yet.
local ADDON_NAME, ns = ...

local GameData = {}
ns.GameData = GameData

local tables = {} -- name -> table
local builds = {} -- name -> integer build (absent when the table is not generated)

function GameData.Define(name, build, tbl)
  if type(name) ~= "string" then error("GameData.Define: name must be a string", 2) end
  if build ~= nil and type(build) ~= "number" then error("GameData.Define: build must be a number or nil", 2) end
  if type(tbl) ~= "table" then error("GameData.Define: tbl must be a table", 2) end
  tables[name] = tbl
  builds[name] = build
end

function GameData.Get(name)
  return tables[name]
end

-- The build a single table was defined with; nil for an ungenerated (nil build) or undefined table.
function GameData.TableBuild(name)
  return builds[name]
end

local function sortedNames()
  local names = {}
  for name in pairs(tables) do names[#names + 1] = name end
  table.sort(names)
  return names
end

-- The build shared by the defined tables; when they disagree, the most common build
-- (ties go to the newest). Tables without a build are ignored.
function GameData.Build()
  local counts, best, bestCount = {}, nil, 0
  for _, build in pairs(builds) do
    counts[build] = (counts[build] or 0) + 1
  end
  for build, count in pairs(counts) do
    if count > bestCount or (count == bestCount and best and build > best) then
      best, bestCount = build, count
    end
  end
  return best
end

function GameData.Status(clientBuild)
  local build = GameData.Build()
  local names = sortedNames()
  local missing = #names == 0
  local mismatched = {}
  for _, name in ipairs(names) do
    local b = builds[name]
    if b == nil then
      missing = true
    elseif b ~= build then
      mismatched[#mismatched + 1] = name
    end
  end
  return { build = build, missing = missing, outdated = build ~= clientBuild, mismatched = mismatched }
end
