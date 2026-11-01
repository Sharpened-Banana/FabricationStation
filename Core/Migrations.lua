local _, ns = ...

-- Schema migrations for db.global. Version N's function brings data from layout N-1 to layout N.
local Migrations = {}
ns.Migrations = Migrations

local registry = {}  -- [version] = fn(global)
local latest = 0

function Migrations.Register(version, fn)
  if type(version) ~= "number" or version < 1 or version % 1 ~= 0 then
    error("migration version must be a positive integer, got " .. tostring(version), 2)
  end
  if registry[version] then error("duplicate migration version " .. version, 2) end
  if type(fn) ~= "function" then error("migration " .. version .. " needs a function", 2) end
  registry[version] = fn
  if version > latest then latest = version end
end

function Migrations.Latest()
  return latest
end

-- Returns ok, fromVersion, toVersion, err. Stops at the first failure, leaving schemaVersion at the
-- last migration that succeeded. A database from a newer addon version is returned untouched with
-- err == "newer"; a stored schemaVersion that is not a number is returned untouched with
-- err == "bad schemaVersion".
function Migrations.Run(global)
  local from = rawget(global, "schemaVersion")
  if from == nil then from = 0 end
  if type(from) ~= "number" then return false, from, from, "bad schemaVersion" end
  if from > latest then return false, from, from, "newer" end
  local current = from
  for version = from + 1, latest do
    local fn = registry[version]
    local ok, err
    if fn then ok, err = pcall(fn, global) else ok, err = false, "missing migration " .. version end
    if not ok then return false, from, current, tostring(err) end
    current = version
    global.schemaVersion = version
  end
  return true, from, current
end

-- 1: initial layout (see ns.DBDefaults). Nothing to convert.
Migrations.Register(1, function() end)

-- 2: guildmates' stored profiles move to the compact shape of Modules/Social/ProfileStore.lua (packed recipe strings
-- instead of three per-recipe maps), with the per-guild cap applied. Runs at InitDB, after every file has loaded.
Migrations.Register(2, function(global)
  local dirs = rawget(global, "guildDirectory")
  if type(dirs) ~= "table" then return end
  local store = ns.Social and ns.Social.ProfileStore
  if not store then error("ProfileStore is not loaded") end
  store.MigrateDirectory(dirs)
end)
