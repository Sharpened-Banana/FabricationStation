-- Math fixture exporter: SavedVariables (/fs capture and the craft log) -> golden fixtures for
-- tests/math/golden_spec.lua. Plain Lua 5.1, run outside the game.
--
-- Usage (from the repository root):
--   lua tools/export_math_fixtures.lua [--force] <path/to/WTF/Account/<account>/SavedVariables/FabricationStation.lua> [outDir]
-- outDir defaults to tests/fixtures/math. The SavedVariables file runs in an empty environment (as
-- tools/export_captures.lua), so it cannot reach any global. The committed Data/GameData_*.lua files run in an empty
-- environment against a minimal collector (ns = { GameData = { Define = fn(name, build, tbl) } }).
--
-- Two kinds of fixture, both written through tools/lib/serialize.lua (sorted keys, so the output is deterministic):
--   * capture_<recipeID>_<id>.lua, one per `/fs capture` (captures.list) that kept its calibration (capture.calib):
--     { source = "capture", recipeID, schematic, calib, reagents, operationInfo, applyConcentration, gameData }. A capture
--     without one is skipped ("no calibration"): today's recipeCalib may hold specialization points it was made without.
--   * craft_<recipeID>_<id>.lua, one per craft log entry (craftLog.entries) that kept its `fixture` and has the game's
--     prediction and the quality it made (game.quality and actual.quality): { source = "craft", recipeID, schematic
--     (the cached one, schematics[recipeID]), calib = fixture.calib, reagents = fixture.reagents, operationInfo = {
--     craftingQuality = game.quality, concentrationCost, baseSkill, bonusSkill, baseDifficulty, bonusDifficulty,
--     lowerSkillThreshold, upperSkillTreshold }, actualQuality = actual.quality, applyConcentration,
--     reagentsMissing? (an order's craft or one spending a currency, logged before the predictions counted those
--     reagents: no fixture.exactReagents), gameData }. An
--     entry is skipped, and counted by its first reason in this order: "no fixture" (older than the newest 100),
--     "no game quality" (no game prediction, or one without a quality), "no actual quality" (the craft's quality is
--     unknown), "no schematic" (none cached), "no calibration" (its fixture holds none).
-- gameData holds only the recipe's rows: the ReagentQuality, ReagentCategories and OptionalReagents of its reagents
-- (the schematic's slots and the reagents of the capture or craft), and the CraftingData, ItemCraftingData,
-- QualityThresholds and ConcentrationCurves rows its crafting data leads to.
--
-- An existing fixture with identical content is fine. One with different content (ids restart when SavedVariables are
-- wiped, so a committed golden fixture could be replaced) stops the export unless --force is given. index.lua in
-- outDir becomes the sorted union of the names it already lists and the ones exported now.
--
-- Prints `exported N fixtures (M captures skipped: no calibration, K crafts skipped: no schematic)`, then adds
-- `, J crafts skipped: <reason>` for each of the other craft reasons above that is not 0. With --force it also prints
-- `replaced <path>` for each existing fixture it overwrote with different content.
-- Exits 0 on success; 1 with a message on stderr when the file is missing, does not parse, fails to run, holds no
-- captures and no crafts, holds a capture or an exportable craft without integer id and recipeID, a calibrated capture
-- without its schematic, reagents or operationInfo, when two fixtures would have the same name, when a fixture cannot
-- be written or would be overwritten, or when
-- the GameData files or an existing index.lua cannot be read. Nothing is written unless every fixture passes.
local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/lib/?.lua;tools/lib/?.lua;" .. package.path

local serialize = require("serialize")

local DEFAULT_OUT = "tests/fixtures/math"
local DATA_DIR = here .. "/../Data"

local function fail(msg)
  io.stderr:write("export_math_fixtures: " .. msg .. "\n")
  os.exit(1)
end

local force, positional = false, {}
for i = 1, #arg do
  if arg[i] == "--force" then force = true else positional[#positional + 1] = arg[i] end
end
local path, outDir = positional[1], positional[2] or DEFAULT_OUT
if not path or path == "" then
  fail("usage: lua tools/export_math_fixtures.lua [--force] <SavedVariables/FabricationStation.lua> [outDir=" .. DEFAULT_OUT .. "]")
end

local function is_integer(n)
  return type(n) == "number" and n == math.floor(n) and n > -math.huge and n < math.huge
end

local function is_number(n)
  return type(n) == "number" and n == n and n > -math.huge and n < math.huge
end

local function read_file(p)
  local h = io.open(p, "rb")
  if not h then return nil end
  local text = h:read("*a")
  h:close()
  return text
end

---------------------------------------------------------------------------
-- Inputs
---------------------------------------------------------------------------

local probe = io.open(path, "rb")
if not probe then fail("file not found: " .. path) end
probe:close()

local chunk, parseErr = loadfile(path)
if not chunk then fail("file does not parse: " .. tostring(parseErr)) end

local env = {}
setfenv(chunk, env)
local ok, runErr = pcall(chunk)
if not ok then fail("error while reading " .. path .. ": " .. tostring(runErr)) end

local db = env.FabricationStationDB
local global = type(db) == "table" and type(db.global) == "table" and db.global or {}
local captures = type(global.captures) == "table" and type(global.captures.list) == "table" and global.captures.list or {}
local crafts = type(global.craftLog) == "table" and type(global.craftLog.entries) == "table" and global.craftLog.entries or {}
if #captures == 0 and #crafts == 0 then fail("no captures or crafts in " .. path) end
local schematics = type(global.schematics) == "table" and global.schematics or {}

-- The committed GameData files, each run in an empty environment against a collector that keeps the defined tables.
local gameData = {}
local collector = { GameData = { Define = function(name, _, tbl) gameData[name] = tbl end } }
local listing = io.popen('ls "' .. DATA_DIR .. '" 2>/dev/null', "r")
if not listing then fail("cannot list " .. DATA_DIR) end
local dataFiles = {}
for name in listing:lines() do
  if name:match("^GameData.+%.lua$") then dataFiles[#dataFiles + 1] = name end
end
listing:close()
table.sort(dataFiles)
if #dataFiles == 0 then fail("no GameData_*.lua files in " .. DATA_DIR) end
for _, name in ipairs(dataFiles) do
  local dataChunk, dataErr = loadfile(DATA_DIR .. "/" .. name)
  if not dataChunk then fail("GameData file does not parse: " .. tostring(dataErr)) end
  setfenv(dataChunk, {})
  local dataOk, dataRunErr = pcall(dataChunk, "FabricationStation", collector)
  if not dataOk then fail("error while reading " .. name .. ": " .. tostring(dataRunErr)) end
end

---------------------------------------------------------------------------
-- Fixtures
---------------------------------------------------------------------------

-- { [key] = row } for the keys of the set that the table has.
local function pick(name, keys)
  local source = type(gameData[name]) == "table" and gameData[name] or {}
  local out = {}
  for key in pairs(keys) do
    if source[key] ~= nil then out[key] = source[key] end
  end
  return out
end

-- Only the GameData rows the recipe's maths reads.
local function recipe_game_data(schematic, reagentInfos, calib)
  local itemIDs = {}
  for _, slot in ipairs(type(schematic.reagentSlots) == "table" and schematic.reagentSlots or {}) do
    for _, itemID in ipairs(type(slot) == "table" and type(slot.reagents) == "table" and slot.reagents or {}) do
      if is_number(itemID) then itemIDs[itemID] = true end
    end
  end
  for _, info in ipairs(type(reagentInfos) == "table" and reagentInfos or {}) do
    local itemID = type(info) == "table" and type(info.reagent) == "table" and info.reagent.itemID or nil
    if is_number(itemID) then itemIDs[itemID] = true end
  end
  local reagentQuality = pick("ReagentQuality", itemIDs)
  local categories = {}
  for _, row in pairs(reagentQuality) do
    if type(row) == "table" and row.categoryID ~= nil then categories[row.categoryID] = true end
  end

  local outputs = {}
  for _, itemID in pairs(type(schematic.outputItemIDs) == "table" and schematic.outputItemIDs or {}) do
    if is_number(itemID) then outputs[itemID] = true end
  end
  local itemCraftingData = pick("ItemCraftingData", outputs)
  local dataIDs = {}
  if is_number(type(calib) == "table" and calib.craftingDataID or nil) then dataIDs[calib.craftingDataID] = true end
  if is_number(schematic.craftingDataID) then dataIDs[schematic.craftingDataID] = true end
  for _, dataID in pairs(itemCraftingData) do
    if is_number(dataID) then dataIDs[dataID] = true end
  end
  local craftingData = pick("CraftingData", dataIDs)
  local difficultyIDs = {}
  for _, row in pairs(craftingData) do
    if type(row) == "table" and row.craftingDifficultyID ~= nil then difficultyIDs[row.craftingDifficultyID] = true end
  end

  return {
    ReagentQuality = reagentQuality,
    ReagentCategories = pick("ReagentCategories", categories),
    OptionalReagents = pick("OptionalReagents", itemIDs),
    CraftingData = craftingData,
    ItemCraftingData = itemCraftingData,
    QualityThresholds = pick("QualityThresholds", difficultyIDs),
    ConcentrationCurves = pick("ConcentrationCurves", difficultyIDs),
  }
end

local GAME_FIELDS = { "concentrationCost", "baseSkill", "bonusSkill", "baseDifficulty", "bonusDifficulty",
  "lowerSkillThreshold", "upperSkillTreshold" }

-- Serialize everything first so a bad fixture leaves the output directory untouched.
local files, names = {}, {}
local skippedCaptures, skippedNoSchematic = 0, 0
local craftSkips = { noFixture = 0, noGame = 0, noActual = 0, noCalibration = 0 }
local chosen = {}   -- [name] = true: the names this run writes

local function spends_currency(reagents)
  for _, info in ipairs(reagents) do
    if type(info) == "table" and type(info.reagent) == "table" and info.reagent.currencyID ~= nil then return true end
  end
  return false
end

local function add(kind, recipeID, id, fixture)
  local okSer, text = pcall(serialize, fixture)
  if not okSer then fail(("%s %d does not serialize: %s"):format(kind, id, tostring(text))) end
  local name = ("%s_%d_%d.lua"):format(kind, recipeID, id)
  if chosen[name] then fail(name .. " would be written twice: the same id appears twice in " .. path) end
  chosen[name] = true
  local file = { path = outDir .. "/" .. name, text = "return " .. text .. "\n" }
  local existing = read_file(file.path)
  if existing and existing ~= file.text then
    if not force then
      fail(file.path .. " already exists with different content; rerun with --force to replace it")
    end
    file.replaced = true
  end
  files[#files + 1] = file
  names[#names + 1] = name
end

for i, capture in ipairs(captures) do
  if type(capture) ~= "table" or not is_integer(capture.recipeID) or not is_integer(capture.id) then
    fail(("capture %d has no integer recipeID and id"):format(i))
  end
  local calib = capture.calib
  if type(calib) ~= "table" then
    skippedCaptures = skippedCaptures + 1
  else
    for _, field in ipairs({ "schematic", "reagents", "operationInfo" }) do
      if type(capture[field]) ~= "table" then fail(("capture %d has no %s"):format(capture.id, field)) end
    end
    add("capture", capture.recipeID, capture.id, {
      source = "capture", recipeID = capture.recipeID, schematic = capture.schematic, calib = calib,
      reagents = capture.reagents, operationInfo = capture.operationInfo,
      applyConcentration = capture.applyConcentration == true,
      gameData = recipe_game_data(capture.schematic, capture.reagents, calib),
    })
  end
end

for i, entry in ipairs(crafts) do
  if type(entry) == "table" then
    local game = type(entry.game) == "table" and entry.game or nil
    local actual = type(entry.actual) == "table" and entry.actual or nil
    -- Only crafts that kept their fixture and have both the game's prediction and the quality they made are fixtures.
    if type(entry.fixture) ~= "table" then
      craftSkips.noFixture = craftSkips.noFixture + 1
    elseif not (game and is_number(game.quality)) then
      craftSkips.noGame = craftSkips.noGame + 1
    elseif not (actual and is_number(actual.quality)) then
      craftSkips.noActual = craftSkips.noActual + 1
    else
      if not is_integer(entry.recipeID) or not is_integer(entry.id) then
        fail(("craft %d has no integer recipeID and id"):format(i))
      end
      local schematic = schematics[entry.recipeID]
      if type(schematic) ~= "table" then
        skippedNoSchematic = skippedNoSchematic + 1
      elseif type(entry.fixture.calib) ~= "table" then
        craftSkips.noCalibration = craftSkips.noCalibration + 1
      else
        local reagents = type(entry.fixture.reagents) == "table" and entry.fixture.reagents or {}
        local operationInfo = { craftingQuality = game.quality }
        for _, field in ipairs(GAME_FIELDS) do operationInfo[field] = game[field] end
        add("craft", entry.recipeID, entry.id, {
          source = "craft", recipeID = entry.recipeID, schematic = schematic, calib = entry.fixture.calib,
          reagents = reagents, operationInfo = operationInfo, actualQuality = actual.quality,
          applyConcentration = entry.applyConcentration == true,
          reagentsMissing = ((entry.orderID ~= nil or spends_currency(reagents)) and entry.fixture.exactReagents ~= true) or nil,
          gameData = recipe_game_data(schematic, reagents, entry.fixture.calib),
        })
      end
    end
  end
end

---------------------------------------------------------------------------
-- Index
---------------------------------------------------------------------------

local indexPath = outDir .. "/index.lua"
local indexNames, seen = {}, {}
local indexText = read_file(indexPath)
if indexText then
  local indexChunk, indexErr = loadfile(indexPath)
  if not indexChunk then fail("index.lua does not parse: " .. tostring(indexErr)) end
  setfenv(indexChunk, {})
  local indexOk, listed = pcall(indexChunk)
  if not indexOk or type(listed) ~= "table" then fail("index.lua does not return a list of file names") end
  for _, name in ipairs(listed) do
    if type(name) ~= "string" then fail("index.lua does not return a list of file names") end
    if not seen[name] then seen[name] = true; indexNames[#indexNames + 1] = name end
  end
end
for _, name in ipairs(names) do
  if not seen[name] then seen[name] = true; indexNames[#indexNames + 1] = name end
end
table.sort(indexNames)
files[#files + 1] = { path = indexPath, text = "return " .. serialize(indexNames) .. "\n" }

---------------------------------------------------------------------------
-- Output
---------------------------------------------------------------------------

for _, f in ipairs(files) do
  local h, openErr = io.open(f.path, "wb")
  if not h then fail("cannot write " .. f.path .. ": " .. tostring(openErr)) end
  h:write(f.text)
  h:close()
  if f.replaced then print("replaced " .. f.path) end
end

local summary = ("%d captures skipped: no calibration, %d crafts skipped: no schematic"):format(skippedCaptures, skippedNoSchematic)
for _, reason in ipairs({ { "noFixture", "no fixture" }, { "noGame", "no game quality" },
  { "noActual", "no actual quality" }, { "noCalibration", "no calibration" } }) do
  if craftSkips[reason[1]] > 0 then
    summary = summary .. (", %d crafts skipped: %s"):format(craftSkips[reason[1]], reason[2])
  end
end
print(("exported %d fixtures (%s)"):format(#names, summary))
