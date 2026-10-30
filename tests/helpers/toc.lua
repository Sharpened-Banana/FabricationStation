-- Parses a WoW .toc file into { meta = { [key] = value }, files = { ... } }.
-- Backslashes in file paths are converted to forward slashes.
local M = {}

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

function M.read_toc(path)
  local fh = assert(io.open(path, "r"), "cannot open " .. tostring(path))
  local toc = { meta = {}, files = {} }
  for line in fh:lines() do
    line = trim(line:gsub("\r", ""))
    if line:sub(1, 2) == "##" then
      local key, value = line:match("^##%s*([^:]+):%s*(.-)%s*$")
      if key then toc.meta[trim(key)] = value end
    elseif line ~= "" and line:sub(1, 1) ~= "#" then
      toc.files[#toc.files + 1] = (line:gsub("\\", "/"))
    end
  end
  fh:close()
  return toc
end

return M
