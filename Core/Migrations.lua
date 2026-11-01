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
    if fn then ok, err = pcall(fn, global)
    else ok, err = false, "missing migration " .. version end  -- locale: joined (error code logged, never shown)
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

-- 3: the single order snapshot { time, charKey, orders } becomes one board per character,
-- orderBoards[charKey] = { time, orders = { [orderID] = OrderView }, scopes = {} }. The owner is the snapshot's
-- charKey, else the charKey of its lowest-orderID view that has one. A board already there keeps its views (an
-- existing orderID wins). A snapshot with orders and no owner is kept as ordersSnapshotLegacy (read by nothing).
local function non_empty_string(v)
  return type(v) == "string" and v ~= ""
end

local function snapshot_owner(charKey, orders)
  if non_empty_string(charKey) then return charKey end
  local owner, lowest
  for id, view in pairs(orders) do
    if type(view) == "table" and non_empty_string(view.charKey) and type(id) == "number"
      and (lowest == nil or id < lowest) then
      owner, lowest = view.charKey, id
    end
  end
  return owner
end

Migrations.Register(3, function(global)
  local old = rawget(global, "ordersSnapshot")
  if type(old) ~= "table" then
    global.ordersSnapshot = nil
    return
  end
  local boards = rawget(global, "orderBoards")
  if type(boards) ~= "table" then
    boards = {}
    global.orderBoards = boards
  end
  local orders = type(old.orders) == "table" and old.orders or {}
  if next(orders) ~= nil then
    local owner = snapshot_owner(old.charKey, orders)
    if owner then
      local board = boards[owner]
      if type(board) ~= "table" then
        board = { time = old.time, orders = {}, scopes = {} }
        boards[owner] = board
      end
      if type(board.orders) ~= "table" then board.orders = {} end
      if type(board.scopes) ~= "table" then board.scopes = {} end
      for id, view in pairs(orders) do
        if type(view) == "table" and board.orders[id] == nil then board.orders[id] = view end
      end
    else
      global.ordersSnapshotLegacy = old
    end
  end
  global.ordersSnapshot = nil
end)
