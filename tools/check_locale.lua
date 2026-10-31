-- Locale checker for FabricationStation (plain Lua 5.1, io/os only; knows nothing about the addon's `ns`).
--
--   local C = dofile("tools/check_locale.lua")
--   C.collect_keys(paths)               -> set of every L["..."] key that appears in the .lua files under `paths`
--   C.defined_keys(enUSPath)            -> set of keys the enUS file assigns (`L["key"] = ...`)
--   C.missing_keys(codePaths, enUSPath) -> sorted list of keys used in code but not defined in enUS
--   C.find_literals(paths, allowlist)   -> { {file, line, text} } user-facing string literals not routed through L
--
-- As a script (`lua tools/check_locale.lua [codePath ... enUSPath]`) it prints the missing keys and exits 1 when
-- there are any. Defaults: Core, Modules, UI against Locales/enUS.lua, relative to the repository root.
--
-- `paths` entries are .lua files or directories (searched recursively with `find`, so run from a POSIX shell).
-- The allowlist has one entry per line, `file:literal` (that literal in that file is fine) or `file:*` (skip the
-- whole file); blank lines and lines starting with `#` are ignored. `file` is spelled as the walked path, for
-- example `Core/Core.lua`.

local M = {}

local ESCAPES = { n = "\n", t = "\t", r = "\r", a = "\a", b = "\b", f = "\f", v = "\v" }

local function shell_quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

-- Expands files and directories to a sorted list of .lua file paths ("./" prefixes dropped).
local function lua_files(paths)
  local out, seen = {}, {}
  local function add(p)
    p = p:gsub("^%./", "")
    if not seen[p] then seen[p] = true; out[#out + 1] = p end
  end
  for _, path in ipairs(paths) do
    if path:match("%.lua$") then
      add(path)
    else
      local h = io.popen("find " .. shell_quote(path) .. " -name '*.lua' -type f 2>/dev/null | sort")
      if h then
        for line in h:lines() do add(line) end
        h:close()
      end
    end
  end
  table.sort(out)
  return out
end

-- Parses a quoted Lua string literal starting at s[pos] (a ' or "). Returns the unescaped text and the position
-- after the closing quote, or nil when the literal is unterminated.
local function parse_string(s, pos)
  local q = s:sub(pos, pos)
  if q ~= '"' and q ~= "'" then return nil end
  local buf, i, n = {}, pos + 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c == "\\" then
      local d = s:sub(i + 1, i + 1)
      local digits = s:match("^%d%d?%d?", i + 1)
      if digits then
        buf[#buf + 1] = string.char(tonumber(digits) % 256)
        i = i + 1 + #digits
      else
        buf[#buf + 1] = ESCAPES[d] or d
        i = i + 2
      end
    elseif c == q then
      return table.concat(buf), i + 1
    elseif c == "\n" then
      return nil
    else
      buf[#buf + 1] = c
      i = i + 1
    end
  end
  return nil
end

local function is_comment(line) return line:match("^%s*%-%-") ~= nil end

-- Calls fn(key, hasAssign, line) for each L["key"] on a line. L must start an identifier (so IL[...] and
-- ns.L[...] differ: the latter counts, the former does not).
local function each_key(line, fn)
  local init = 1
  while true do
    local s, e = line:find("%f[%w_]L%[%s*", init)
    if not s then return end
    local key, after = parse_string(line, e + 1)
    init = e + 1
    if key then
      local close = line:match("^%s*%]()", after)
      if close then
        init = close
        fn(key, line:match("^%s*=[^=]", close) ~= nil)
      end
    end
  end
end

local function scan_keys(paths, assignedOnly)
  local set = {}
  for _, file in ipairs(lua_files(paths)) do
    local src = read_file(file)
    if src then
      for line in (src .. "\n"):gmatch("(.-)\r?\n") do
        if not is_comment(line) then
          each_key(line, function(key, assigned)
            if assigned or not assignedOnly then set[key] = true end
          end)
        end
      end
    end
  end
  return set
end

function M.collect_keys(paths) return scan_keys(paths, false) end

function M.defined_keys(enUSPath) return scan_keys({ enUSPath }, true) end

function M.missing_keys(codePaths, enUSPath)
  local defined, missing = M.defined_keys(enUSPath), {}
  for key in pairs(M.collect_keys(codePaths)) do
    if not defined[key] then missing[#missing + 1] = key end
  end
  table.sort(missing)
  return missing
end

---------------------------------------------------------------------------
-- Bare user-facing literals
---------------------------------------------------------------------------

-- Each pattern ends where the first string literal argument should begin.
local CALL_PATTERNS = {
  { ":SetText%(%s*" },
  { ":AddLine%(%s*" },
  { ":AddDoubleLine%(%s*", second = true },
  { ":Print%(%s*" },
  { "%f[%w_]print%(%s*" },
  { "%f[%w_]GameTooltip_SetTitle%([^,%)]*,%s*" },
  { "%f[%w_]label%s*=%s*" },
  { "%f[%w_]title%s*=%s*" },
  { "%f[%w_]name%s*=%s*" },
  { "%f[%w_]desc%s*=%s*" },
}

-- True when the text has at least two letters once format specifiers and colour codes are removed.
local function has_words(text)
  text = text:gsub("%%%%", ""):gsub("%%[%d%.%-%+ #]*%a", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  local _, letters = text:gsub("%a", "")
  return letters >= 2
end

local function load_allowlist(path)
  local literals, files = {}, {}
  if not path then return literals, files end
  local src = read_file(path)
  if not src then error("cannot read allowlist " .. tostring(path), 2) end
  for line in (src .. "\n"):gmatch("(.-)\r?\n") do
    if line:match("%S") and not line:match("^%s*#") then
      local file, literal = line:match("^([^:]+):(.*)$")
      if file then
        if literal == "*" then
          files[file] = true
        else
          literals[file .. "\0" .. literal] = true
        end
      end
    end
  end
  return literals, files
end

function M.find_literals(paths, allowlistPath)
  local allowLiteral, allowFile = load_allowlist(allowlistPath)
  local hits = {}
  for _, file in ipairs(lua_files(paths)) do
    local src = not allowFile[file] and read_file(file)
    if src then
      local lineNo = 0
      for line in (src .. "\n"):gmatch("(.-)\r?\n") do
        lineNo = lineNo + 1
        if not is_comment(line) then
          for _, spec in ipairs(CALL_PATTERNS) do
            local init = 1
            while true do
              local _, e = line:find(spec[1], init)
              if not e then break end
              init = e + 1
              local text, after = parse_string(line, e + 1)
              local found = {}
              if text then
                found[1] = text
                if spec.second then
                  local second = line:match("^%s*,%s*()", after)
                  local text2 = second and parse_string(line, second)
                  if text2 then found[2] = text2 end
                end
              end
              for _, t in ipairs(found) do
                if has_words(t) and not allowLiteral[file .. "\0" .. t] then
                  hits[#hits + 1] = { file = file, line = lineNo, text = t }
                end
              end
            end
          end
        end
      end
    end
  end
  table.sort(hits, function(a, b)
    if a.file ~= b.file then return a.file < b.file end
    if a.line ~= b.line then return a.line < b.line end
    return a.text < b.text
  end)
  return hits
end

---------------------------------------------------------------------------
-- Script entry point
---------------------------------------------------------------------------

local function main(argv)
  local codePaths, enUS
  if #argv > 0 then
    enUS = argv[#argv]
    codePaths = {}
    for i = 1, #argv - 1 do codePaths[i] = argv[i] end
    if #codePaths == 0 then codePaths = { "Core", "Modules", "UI" } end
  else
    local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
    local root = here .. "/.."
    codePaths = { root .. "/Core", root .. "/Modules", root .. "/UI" }
    enUS = root .. "/Locales/enUS.lua"
  end
  local missing = M.missing_keys(codePaths, enUS)
  for _, key in ipairs(missing) do print("missing from enUS: " .. key) end
  if #missing > 0 then
    print(("%d locale key(s) missing"):format(#missing))
    os.exit(1)
  end
  print("locale keys OK")
end

if arg and arg[0] and arg[0]:match("check_locale%.lua$") then
  local argv = {}
  for i = 1, #arg do argv[i] = arg[i] end
  main(argv)
end

return M
