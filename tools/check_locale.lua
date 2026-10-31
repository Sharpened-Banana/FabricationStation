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

-- Extra keys whose string value is display text, wherever they appear (option/tab/widget/column tables).
local KEYED = { "tooltip", "text", "long", "hint", "header" }

-- Lines carrying one of these calls hold ids, log sources, developer errors or lookup patterns, not display text.
local NON_DISPLAY_LINE = {
  "%f[%w_]error%(", "%f[%w_]assert%(", "LogError%(", "SafeCall%(", "Debounce%(", "RegisterEvent%(", "RegisterMessage%(",
  "SendMessage%(", "NewModule%(", "GetModule%(", "LibStub%(", "CreateFrame%(", "hooksecurefunc%(", "%f[%w_]require%(",
  ":find%(", ":match%(", ":gmatch%(", ":gsub%(", "string%.find%(", "string%.match%(", "string%.gsub%(",
  "RegisterCallback%(", "UnregisterCallback%(", "Msg%.", "IsAddOnLoaded%(", "GetAddOnMetadata%(", "SetScript%(",
  "SetAtlas%(", "SetTexture%(", "SetNormalTexture%(", "SetFont%(", "PlaySound%(",
}

-- Names of constant tables that hold display text: LABELS, TEXTS, NOTES, REFUSED, NONE, MESSAGES, ...
local function is_text_table_name(name)
  return name:find("LABEL") or name:find("TEXT") or name:find("NOTE") or name:find("NAMES") or name:find("REFUSED")
    or name:find("_NONE") or name:find("MESSAGE") or name:find("TITLE") or name:find("HINT") or name:find("WORDS")
end

-- Every string literal on the line: { startPos, endPos(after quote), text, before, after } (comments skipped).
local function line_literals(line)
  local out, i = {}, 1
  while i <= #line do
    local c = line:sub(i, i)
    if c == '"' or c == "'" then
      local text, after = parse_string(line, i)
      if not text then break end
      out[#out + 1] = { i, after, text, line:sub(1, i - 1), line:sub(after) }
      i = after
    elseif c == "-" and line:sub(i, i + 1) == "--" then
      break
    else
      i = i + 1
    end
  end
  return out
end

local function words_of(text)
  text = text:gsub("%%%%", ""):gsub("%%[%d%.%-%+ #]*%a", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  local n = 0
  for _ in text:gmatch("%a%a+") do n = n + 1 end
  return n
end

function M.find_literals(paths, allowlistPath)
  local allowLiteral, allowFile = load_allowlist(allowlistPath)
  local hits, seen = {}, {}
  local function hit(file, lineNo, t)
    local key = file .. "\0" .. lineNo .. "\0" .. t
    if seen[key] or allowLiteral[file .. "\0" .. t] then return end
    seen[key] = true
    hits[#hits + 1] = { file = file, line = lineNo, text = t }
  end
  for _, file in ipairs(lua_files(paths)) do
    local src = not allowFile[file] and read_file(file)
    if src then
      local prev = ""
      local lines = {}
      for line in (src .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = line end
      local textDepth = nil   -- brace depth inside a display-text constant table
      local depth = 0
      for idx, line in ipairs(lines) do
        local lineNo = idx
        local nextLine = lines[idx + 1] or ""
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
                if has_words(t) then hit(file, lineNo, t) end
              end
            end
          end

          -- Second rule: complete literals (not one piece of a concatenation) that read as display text.
          local skipLine = false
          for _, p in ipairs(NON_DISPLAY_LINE) do
            if line:find(p) then skipLine = true; break end
          end
          local code = line:gsub("%-%-.*$", "")
          local opens = select(2, code:gsub("{", "")) - select(2, code:gsub("}", ""))
          if not textDepth and opens > 0 then
            local name = code:match("^%s*local%s+([%w_]+)%s*=%s*{") or code:match("^%s*([%w_%.]+)%s*=%s*{")
            if name and is_text_table_name(name) then textDepth = depth + 1 end
          end
          for _, lit in ipairs(line_literals(line)) do
            local before, after, text = lit[4], lit[5], lit[3]
            local concat = before:match("%.%.%s*$") or after:match("^%s*%.%.")
              or (before:match("^%s*$") and prev:match("%.%.%s*$"))
              or (after:match("^%s*[,%)]?%s*$") and nextLine:match("^%s*%.%."))
            local direct = before:match("%f[%w_]L%[%s*$") or before:match("%f[%w_]L%(%s*$") or before:match("[=~]=%s*$")
            local ctxKey = before:match("([%w_]+)%s*=%s*$")
            local keyed = false
            if ctxKey then
              for _, k in ipairs(KEYED) do if ctxKey == k then keyed = true end end
            end
            local inTextTable = textDepth and (ctxKey or before:match('%[%s*"[%w_]+"%s*%]%s*=%s*$'))
            if not concat and not direct and not skipLine and not text:find("^Interface") and not text:find("://") then
              if (words_of(text) >= 2 and text:find("%a%a+[ ]+[%a%d%(%[]"))
                  or text:find("^%u[%a ]+:$")
                  or ((keyed or inTextTable) and has_words(text)) then
                hit(file, lineNo, text)
              end
            end
          end
          depth = depth + opens
          if textDepth and depth < textDepth then textDepth = nil end
        end
        prev = line
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
