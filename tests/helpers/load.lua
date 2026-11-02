-- Loads addon source files the way the WoW client does: each chunk receives
-- (addonName, namespaceTable) as its varargs.
local toc = require("toc")

local M = {}

-- Compiled chunks of the checked-in Data/ files, which no test rewrites. The generated GameData is over a
-- megabyte, and parsing it again for every addon boot made the suite many times slower. Each call of a
-- cached chunk still builds fresh tables.
local dataChunks = {}

local function load_chunk(path)
  if not path:match("^Data[/\\]") then return loadfile(path) end
  if not dataChunks[path] then
    local chunk, err = loadfile(path)
    if not chunk then return nil, err end
    dataChunks[path] = chunk
  end
  return dataChunks[path]
end

-- Runs loadfile(path)("FabricationStation", ns) for each path; errors with the path on failure.
function M.load_files(ns, paths)
  for _, path in ipairs(paths) do
    local chunk, err = load_chunk(path)
    if not chunk then error("failed to load " .. path .. ": " .. tostring(err), 2) end
    local ok, runErr = pcall(chunk, "FabricationStation", ns)
    if not ok then error("error running " .. path .. ": " .. tostring(runErr), 2) end
  end
  return ns
end

-- Loads the TOC file list in order, skipping .xml entries, stopping after lastFile
-- (or loading everything when lastFile is nil). Errors when lastFile is given but is not a
-- loadable (non-.xml) file in the TOC.
function M.load_addon(ns, lastFile)
  local paths, found = {}, false
  for _, f in ipairs(toc.read_toc("FabricationStation.toc").files) do
    if not f:match("%.xml$") then
      paths[#paths + 1] = f
      if lastFile and f == lastFile then found = true; break end
    end
  end
  if lastFile and not found then error("lastFile not found in FabricationStation.toc: " .. tostring(lastFile), 2) end
  return M.load_files(ns, paths)
end

-- Normalizes os.execute across Lua 5.1 (raw wait status) and 5.2+ (true|nil, "exit", code).
function M.run_cmd(cmd)
  local a, b, c = os.execute(cmd)
  if type(a) == "number" then return math.floor(a / 256) end
  if type(c) == "number" then return c end
  return (a == true or a == 0) and 0 or (b or 1)
end

return M
