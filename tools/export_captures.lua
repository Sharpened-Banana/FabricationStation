-- Capture exporter: SavedVariables captures (/fs capture) -> test fixtures. Plain Lua 5.1, run
-- outside the game.
--
-- Usage (from the repository root):
--   lua tools/export_captures.lua <path/to/WTF/Account/<account>/SavedVariables/FabricationStation.lua> [outDir]
-- outDir defaults to tests/fixtures/captures. Each capture becomes <outDir>/capture_<recipeID>_<id>.lua
-- holding `return <capture>` (deterministic: keys sorted).
--
-- The SavedVariables file runs in an empty environment, so it cannot reach any global (os, io, ...).
-- Exits 0 on success; 1 with a message on stderr when the file is missing, does not parse, fails to
-- run, holds no captures, or a fixture cannot be written. Nothing is written unless every capture
-- serializes.
local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/lib/?.lua;tools/lib/?.lua;" .. package.path

local serialize = require("serialize")

local DEFAULT_OUT = "tests/fixtures/captures"

local function fail(msg)
  io.stderr:write("export_captures: " .. msg .. "\n")
  os.exit(1)
end

local path, outDir = arg[1], arg[2] or DEFAULT_OUT
if not path or path == "" then
  fail("usage: lua tools/export_captures.lua <SavedVariables/FabricationStation.lua> [outDir=" .. DEFAULT_OUT .. "]")
end

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
local global = type(db) == "table" and db.global
local captures = type(global) == "table" and global.captures
local list = type(captures) == "table" and captures.list
if type(list) ~= "table" or #list == 0 then fail("no captures in " .. path) end

-- Serialize everything first so a bad capture leaves the output directory untouched.
local files = {}
for i, capture in ipairs(list) do
  if type(capture) ~= "table" or type(capture.recipeID) ~= "number" or type(capture.id) ~= "number" then
    fail(("capture %d has no numeric recipeID and id"):format(i))
  end
  local okSer, text = pcall(serialize, capture)
  if not okSer then fail(("capture %d does not serialize: %s"):format(capture.id, tostring(text))) end
  files[#files + 1] = {
    path = ("%s/capture_%d_%d.lua"):format(outDir, capture.recipeID, capture.id),
    text = "return " .. text .. "\n",
  }
end

for _, f in ipairs(files) do
  local h, openErr = io.open(f.path, "wb")
  if not h then fail("cannot write " .. f.path .. ": " .. tostring(openErr)) end
  h:write(f.text)
  h:close()
end

print(("exported %d captures to %s"):format(#files, outDir))
