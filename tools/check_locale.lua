-- Locale checker for FabricationStation (plain Lua 5.1, io/os only; knows nothing about the addon's `ns`).
--
--   local C = dofile("tools/check_locale.lua")
--   C.collect_keys(paths)               -> set of every L["..."] key that appears in the .lua files under `paths`
--   C.defined_keys(enUSPath)            -> set of keys the enUS file assigns (`L["key"] = ...`)
--   C.missing_keys(codePaths, enUSPath) -> sorted list of keys used in code but not defined in enUS
--   C.unused_keys(codePaths, enUSPath)  -> sorted list of keys enUS defines that no code uses
--   C.find_literals(paths, allowlist)   -> { {file, line, text} } user-facing string literals not routed through L
--   C.find_concatenations(paths, allowlist) -> { {file, line, text} } display sentences built with `..` or plurals,
--                                              brackets / dashes / signs joined with `..`, and (in UI files) comma
--                                              lists built with table.concat instead of ns.UI.JoinList
--   C.stale_allowlist(paths, allowlist) -> sorted list of allowlist entries that no longer match anything
--
-- A "use" of a key is `L["key"]` or the call form `L("key")` (GuildDirectory's `local function L(key)`).
--
-- As a script (`lua tools/check_locale.lua [codePath ... enUSPath]`) it prints the missing keys (`missing from
-- enUS: ...`) and the unused ones (`unused in code: ...`) and exits 1 when there are any; otherwise it prints
-- `locale keys OK`. Defaults: Core, Modules, UI against Locales/enUS.lua, relative to the repository root.
--
-- `paths` entries are .lua files or directories (searched recursively with `find`, so run from a POSIX shell).
-- The allowlist has one entry per line, `file:literal` (that literal in that file is fine) or `file:*` (skip the
-- whole file); blank lines and lines starting with `#` are ignored. `file` is spelled as the walked path, for
-- example `Core/Core.lua`.
--
-- Known limits: lines are scanned one at a time (keys are parsed per line, a literal split over lines is seen only
-- where a rule looks at the neighbouring line); `--[[ ]]` block comments are scanned as code; `text_constants` reads
-- only column-0, single-line `local` assignments; and format strings that do not go through `L`
-- (`("%s  %s"):format(a, b)`) are not seen.

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

-- Calls fn(key, hasAssign, line) for each L["key"] or L("key") on a line. L must start an identifier (so IL[...]
-- and ns.L[...] differ: the latter counts, the former does not). Only the bracket form can be an assignment.
local function each_key(line, fn)
  for _, form in ipairs({ { "%f[%w_]L%[%s*", "%]" }, { "%f[%w_]L%(%s*", "%)" } }) do
    local init = 1
    while true do
      local s, e = line:find(form[1], init)
      if not s then break end
      local key, after = parse_string(line, e + 1)
      init = e + 1
      if key then
        local close = line:match("^%s*" .. form[2] .. "()", after)
        if close then
          init = close
          fn(key, form[2] == "%]" and line:match("^%s*=[^=]", close) ~= nil)
        end
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

function M.unused_keys(codePaths, enUSPath)
  local used, unused = M.collect_keys(codePaths), {}
  for key in pairs(M.defined_keys(enUSPath)) do
    if not used[key] then unused[#unused + 1] = key end
  end
  table.sort(unused)
  return unused
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
-- Not localized on purpose, and therefore not flagged by find_literals or find_concatenations: Util.LogError /
-- Diagnostics texts, slash command names, saved-data and setting keys, message names, module ids, Auctionator
-- search terms, CSV field names, and Ledger's mail-subject and invoice matching (compared against the client's
-- own text). A line outside these calls that must stay joined carries `-- locale: joined (<reason>)`.
local NON_DISPLAY_LINE = {
  "%f[%w_]error%(", "%f[%w_]assert%(", "LogError%(", "SafeCall%(", "Debounce%(", "RegisterEvent%(", "RegisterMessage%(",
  "SendMessage%(", "NewModule%(", "GetModule%(", "LibStub%(", "CreateFrame%(", "hooksecurefunc%(", "%f[%w_]require%(",
  ":find%(", ":match%(", ":gmatch%(", ":gsub%(", "string%.find%(", "string%.match%(", "string%.gsub%(",
  "RegisterCallback%(", "UnregisterCallback%(", "Msg%.", "IsAddOnLoaded%(", "GetAddOnMetadata%(", "SetScript%(",
  "SetAtlas%(", "SetTexture%(", "SetNormalTexture%(", "SetFont%(", "PlaySound%(",
}

-- Fields of row/cell tables that hold the text shown in a cell.
local DISPLAY_FIELDS = { age = true, lastSeen = true, when = true, right = true, note = true, expires = true,
  affordable = true }

-- One-word status values that are shown to the player (a bare `return "now"` or `or "none"`).
local DISPLAY_WORDS = { now = true, online = true, never = true, none = true, estimate = true, partial = true,
  full = true, done = true, unknown = true, expired = true }

-- Names of constant tables that hold display text: LABELS, TEXTS, NOTES, REFUSED, NONE, MESSAGES, ...
local function is_text_table_name(name)
  return name:find("LABEL") or name:find("TEXT") or name:find("NOTE") or name:find("NAMES") or name:find("REFUSED")
    or name:find("_NONE") or name:find("MESSAGE") or name:find("TITLE") or name:find("HINT") or name:find("WORDS")
end

-- The source text between the end of literal a and the start of literal b on one line.
local function line_between(line, a, b) return line:sub(a[2], b[1] - 1) end

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
          local labelLine = false   -- a one-line `X_LABELS = { a = "...", ... }`: every string value is display text
          local name = code:match("^%s*local%s+([%w_]+)%s*=%s*{") or code:match("^%s*([%w_%.]+)%s*=%s*{")
          if name then
            if not textDepth and opens > 0 and is_text_table_name(name) then textDepth = depth + 1 end
            if opens == 0 and name:find("_LABELS$") and code:find("}%s*$") then labelLine = true end
          end
          local lits = line_literals(line)
          for k, lit in ipairs(lits) do
            local before, after, text = lit[4], lit[5], lit[3]
            -- A chain of literals joined by `..` (across lines too) with no other operand is one complete literal.
            local chainText
            local startsChain = not (before:match("%.%.%s*$") or (before:match("^%s*$") and prev:match("%.%.%s*$")))
            if startsChain and not before:match("%f[%w_]L%[%s*$") and (after:match("^%s*%.%.") or after:match("^%s*$")) then
              local parts, pure = { text }, true
              local li, ll, lk = idx, lits, k
              while true do
                local cur = ll[lk]
                local rest = cur[5]
                local nextLit
                if rest:match("^%s*%.%.%s*[\"']") then
                  local nxt = ll[lk + 1]
                  if nxt and line_between(lines[li], cur, nxt):match("^%s*%.%.%s*$") then nextLit = nxt; lk = lk + 1 end
                  if not nextLit then pure = false end
                elseif rest:match("^%s*%.%.%s*$") or (rest:match("^%s*$") and (lines[li + 1] or ""):match("^%s*%.%.%s*[\"']")) then
                  li = li + 1
                  ll = line_literals(lines[li] or "")
                  lk = 1
                  nextLit = ll[1]
                  if not (nextLit and nextLit[4]:match("^%s*%.?%.?%s*$")) then pure = false; nextLit = nil end
                elseif rest:match("^%s*%.%.") then
                  pure = false
                end
                if not nextLit then break end
                parts[#parts + 1] = nextLit[3]
              end
              if pure and #parts >= 2 then chainText = table.concat(parts) end
            end
            if chainText and not skipLine and has_words(chainText) and words_of(chainText) >= 2 then
              hit(file, lineNo, chainText)
            end
            local concat = before:match("%.%.%s*$") or after:match("^%s*%.%.")
              or (before:match("^%s*$") and prev:match("%.%.%s*$"))
              or (after:match("^%s*[,%)]?%s*$") and nextLine:match("^%s*%.%."))
            local direct = before:match("%f[%w_]L%[%s*$") or before:match("%f[%w_]L%(%s*$") or before:match("[=~]=%s*$")
            local ctxKey = before:match("([%w_]+)%s*=%s*$")
            local keyed = false
            if ctxKey then
              for _, key in ipairs(KEYED) do if ctxKey == key then keyed = true end end
            end
            -- A literal handed to a display helper, or stored in a display field, is display text even as one word.
            local helperArg = before:match("%f[%w_]color%(%s*[%w_%.]+%s*,%s*$")
              or (before:match("%f[%w_][%w_]*[bB]utton%([^\"']*$") and not before:find("cycle", 1, true))
              or DISPLAY_FIELDS[ctxKey or ""]
            -- A capitalised word, or a status word, picked by `and` / `or` / `return`: a one-word display value.
            local picked = (before:match("%f[%w_]and%s*$") or before:match("%f[%w_]or%s*$") or before:match("%f[%w_]return%s*$"))
              and (text:find("^%u%l+$") or DISPLAY_WORDS[text])
            local inTextTable = (textDepth or labelLine) and (ctxKey or before:match('%[%s*"[%w_]+"%s*%]%s*=%s*$'))
            if not concat and not direct and not skipLine and not text:find("^Interface") and not text:find("://") then
              if (words_of(text) >= 2 and text:find("%a%a+[ ]+[%a%d%(%[]"))
                  or text:find("^%u[%a ]+:$")
                  or ((keyed or inTextTable or helperArg or picked) and has_words(text)) then
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
-- Concatenated display sentences
---------------------------------------------------------------------------

-- `-- locale: joined (<reason>)` at the end of a line marks a join that has to stay (an id built for code, a value
-- the game compares).
local JOINED_MARK = "%-%-%s*locale:%s*joined"

-- The code part of a line: string-aware, cut at the first `--` outside a string.
local function code_of(line)
  local i = 1
  while i <= #line do
    local c = line:sub(i, i)
    if c == '"' or c == "'" then
      local _, after = parse_string(line, i)
      if not after then return line end
      i = after
    elseif c == "-" and line:sub(i, i + 1) == "--" then
      return line:sub(1, i - 1)
    else
      i = i + 1
    end
  end
  return line
end

-- A literal that is only colour codes, only newlines, or the " · " separator is not a sentence piece.
local function is_plain_literal(text)
  if text == " \194\183 " then return true end
  local rest = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  return rest == "" or rest:match("^\n+$") ~= nil
end

-- Names the file assigns at top level a string that is text, not a colour code or separator (AH_HINT, ELLIPSIS, ...).
-- Any other all-caps name (GOLD, DIM, WARN, a colour table, an imported constant) is not a sentence piece.
local function text_constants(codes)
  local texty = {}
  for _, code in ipairs(codes) do
    local names, rhs = code:match("^local%s+([%w_,%s]-)%s*=%s*(.-)%s*$")
    if names and rhs then
      local lits = line_literals(rhs)
      if #lits > 0 then
        local bare, last = {}, 1
        for _, lit in ipairs(lits) do bare[#bare + 1] = rhs:sub(last, lit[1] - 1); last = lit[2] end
        bare[#bare + 1] = rhs:sub(last)
        local list = {}
        for name in names:gmatch("[%w_]+") do list[#list + 1] = name end
        if (table.concat(bare)):gsub("[%s,]", "") == "" and #list == #lits then
          for i, name in ipairs(list) do
            if not is_plain_literal(lits[i][3]) then texty[name] = true end
          end
        else
          for _, name in ipairs(list) do texty[name] = true end   -- an expression with text in it
        end
      end
    end
  end
  return texty
end

-- Previous / next line that has code, for operands that start or end a line.
local function code_before(codes, i)
  local j = i - 1
  while j >= 1 and codes[j]:match("^%s*$") do j = j - 1 end
  return codes[j] or ""
end

local function code_after(codes, i)
  local j = i + 1
  while j <= #codes and codes[j]:match("^%s*$") do j = j + 1 end
  return codes[j] or ""
end

-- The text before position pos / from position pos on, continued across a line break when the line has no more code.
local function left_of(codes, i, pos)
  local before = codes[i]:sub(1, pos - 1)
  if before:match("^%s*$") then before = code_before(codes, i) .. " " .. before end
  return before
end

local function right_of(codes, i, pos)
  local after = codes[i]:sub(pos)
  if after:match("^%s*$") then after = after .. " " .. code_after(codes, i) end
  return after
end

local function ends_with_concat(before) return before:match("%.%.%s*$") ~= nil and before:match("%.%.%.%s*$") == nil end
local function starts_with_concat(after) return after:match("^%s*%.%.") ~= nil and after:match("^%s*%.%.%.") == nil end

-- The operand just left of a trailing `..`: ("literal", text), ("name", identifier) or ("other").
local function left_operand(before)
  local head = before:gsub("%s*%.%.%s*$", "")
  local lits = line_literals(head)
  local last = lits[#lits]
  if last and last[2] == #head + 1 then return "literal", last[3] end
  local name = head:match("([%w_]+)$")
  if name then
    local prev = head:sub(-#name - 1, -#name - 1)
    if prev ~= "." and prev ~= ":" then return "name", name end
  end
  return "other"
end

-- The operand just right of a leading `..`.
local function right_operand(after)
  local tail = after:gsub("^%s*%.%.%s*", "")
  local first = tail:sub(1, 1)
  if first == '"' or first == "'" then
    local text = parse_string(tail, 1)
    if text then return "literal", text end
  end
  local name = tail:match("^([%w_]+)")
  if name then
    local rest = tail:sub(#name + 1)
    if not (rest:match("^%s*[%(:%[{]") or rest:match("^%.[^%.]")) then return "name", name end
  end
  return "other"
end

-- A neighbour that does not make the key part of a sentence: colour code, separator, or a constant of those.
local function plain_neighbour(kind, value, texty)
  if kind == "literal" then return is_plain_literal(value) end
  if kind == "name" then
    return value == "DOT" or value == "SEP" or value == "NL" or (value:match("^%u[%u%d_]*$") ~= nil and not texty[value])
  end
  return false
end

-- Positions of every L["key"] / L("key") on a code line, each extended over a following :format(...) call:
-- { startPos, endPos (after the last char) }.
local function l_calls(code)
  local out = {}
  for _, form in ipairs({ { "%f[%w_]L%[%s*", "%]" }, { "%f[%w_]L%(%s*", "%)" } }) do
    local init = 1
    while true do
      local s, e = code:find(form[1], init)
      if not s then break end
      init = e + 1
      local key, after = parse_string(code, e + 1)
      local close = key and code:match("^%s*" .. form[2] .. "()", after)
      if close then
        local stop = close
        local open = code:match("^:format%(()", close)
        if open then
          local depth, k = 1, open
          while k <= #code and depth > 0 do
            local c = code:sub(k, k)
            if c == '"' or c == "'" then
              local _, aft = parse_string(code, k)
              k = aft or #code + 1
            else
              if c == "(" then depth = depth + 1 elseif c == ")" then depth = depth - 1 end
              k = k + 1
            end
          end
          stop = k
        end
        out[#out + 1] = { s, stop }
        init = stop
      end
    end
  end
  return out
end

local function is_id_like(text) return text:match("^[%l%d_%.:/%-]*$") ~= nil end

local EM_DASH = "\226\128\148"

-- A literal that only holds spaces and ( ) [ ] : - + and the em dash, and joins a sentence: " (+", ")", "[", " - ",
-- " — ". A lone "+" / "-" sign and an id separator (":", "-") are not.
local function is_punctuation_join(text)
  if text == "+" or text == "-" or text == "" then return false end
  if is_id_like(text) and not text:find(" ", 1, true) then return false end
  local t = text:gsub(EM_DASH, "(")
  if not t:match("^[ %(%)%[%]:%-%+]+$") then return false end
  return t:find("[%(%)%[%]%+]") ~= nil or (t:find(" ", 1, true) ~= nil and t:find("[:%-]") ~= nil)
end

-- Is this file one of the UI files whose comma lists have to go through ns.UI.JoinList (not UI/Util.lua itself)?
local function is_ui_list_file(file)
  local f = "/" .. file
  return f:find("/UI/", 1, true) ~= nil and f:find("/UI/Util%.lua$") == nil
end

-- True when the line calls table.concat(<expr>, <comma separator>) where the separator is ", ", L[", "] or L(", ").
local function comma_list(code)
  local init = 1
  while true do
    local _, e = code:find("table%.concat%(", init)
    if not e then return false end
    init = e + 1
    -- the top-level arguments of the call (to the closing parenthesis, or the end of the line)
    local args, depth, k, from, n = {}, 1, e + 1, e + 1, #code
    while k <= n do
      local c = code:sub(k, k)
      if c == '"' or c == "'" then
        local _, after = parse_string(code, k)
        k = after or n + 1
      else
        if c == "(" or c == "[" or c == "{" then
          depth = depth + 1
        elseif c == ")" or c == "]" or c == "}" then
          depth = depth - 1
          if depth == 0 then break end
        elseif c == "," and depth == 1 then
          args[#args + 1] = code:sub(from, k - 1)
          from = k + 1
        end
        k = k + 1
      end
    end
    args[#args + 1] = code:sub(from, k - 1)
    local sep = args[2] and args[2]:match("^%s*(.-)%s*$")
    if sep then
      local key = sep:match("^L%[%s*(.-)%s*%]$") or sep:match("^L%(%s*(.-)%s*%)$") or sep
      local text, after = parse_string(key, 1)
      if text == ", " and after == #key + 1 then return true end
    end
  end
end

-- Does any display piece on code line i look like a joined sentence? Returns true on the first reason found.
local function joined_sentence(codes, i, texty)
  local code = codes[i]
  -- 1. a literal with words that is an operand of `..` (a chain of nothing but literals is one literal split over lines)
  for _, lit in ipairs(line_literals(code)) do
    local text = lit[3]
    if has_words(text) and not is_id_like(text) and not text:find("^Interface[\\/]") and not text:find("://") then
      local before, after = left_of(codes, i, lit[1]), right_of(codes, i, lit[2])
      local joinedLeft, joinedRight = ends_with_concat(before), starts_with_concat(after)
      if joinedLeft or joinedRight then
        local lk = joinedLeft and left_operand(before) or "literal"
        local rk = joinedRight and right_operand(after) or "literal"
        if lk ~= "literal" or rk ~= "literal" then return true end
      end
    end
  end
  -- 1b. a bracket, sign or dash piece that is an operand of `..`: " (+", ")", "[", " - ", " — "
  for _, lit in ipairs(line_literals(code)) do
    if is_punctuation_join(lit[3]) then
      local before, after = left_of(codes, i, lit[1]), right_of(codes, i, lit[2])
      local joinedLeft, joinedRight = ends_with_concat(before), starts_with_concat(after)
      if joinedLeft or joinedRight then
        local lk = joinedLeft and left_operand(before) or "literal"
        local rk = joinedRight and right_operand(after) or "literal"
        if lk ~= "literal" or rk ~= "literal" then return true end
      end
    end
  end
  -- 2. an L key (with or without :format) that is an operand of `..` next to something that is not plain
  for _, call in ipairs(l_calls(code)) do
    local before, after = left_of(codes, i, call[1]), right_of(codes, i, call[2])
    local bad = false
    if ends_with_concat(before) then
      local kind, value = left_operand(before)
      bad = not plain_neighbour(kind, value, texty)
    end
    if not bad and starts_with_concat(after) then
      local kind, value = right_operand(after)
      bad = not plain_neighbour(kind, value, texty)
    end
    if bad then return true end
  end
  -- 3. a plural choice between words: `n == 1 and " item" or " items"`
  local init = 1
  while true do
    local _, e = code:find("[=~]=%s*1%s+and%s+", init)
    if not e then break end
    init = e + 1
    local text = parse_string(code, e + 1)
    if text and has_words(text) then return true end
  end
  return false
end

function M.find_concatenations(paths, allowlistPath)
  local _, allowFile = load_allowlist(allowlistPath)
  local hits = {}
  for _, file in ipairs(lua_files(paths)) do
    local src = not allowFile[file] and read_file(file)
    if src then
      local lines, codes = {}, {}
      for line in (src .. "\n"):gmatch("(.-)\r?\n") do
        lines[#lines + 1] = line
        codes[#codes + 1] = is_comment(line) and "" or code_of(line)
      end
      local texty = text_constants(codes)
      local uiFile = is_ui_list_file(file)
      for i, line in ipairs(lines) do
        local skip = codes[i]:match("^%s*$") ~= nil or line:find(JOINED_MARK) ~= nil
        if not skip then
          for _, p in ipairs(NON_DISPLAY_LINE) do
            if codes[i]:find(p) then skip = true; break end
          end
        end
        if not skip and ((uiFile and comma_list(codes[i])) or joined_sentence(codes, i, texty)) then
          hits[#hits + 1] = { file = file, line = i, text = (line:gsub("^%s+", ""):gsub("%s+$", "")) }
        end
      end
    end
  end
  return hits
end

-- Allowlist entries that cannot match any more: a `file:literal` whose literal is no longer a string literal of that
-- file (alone or as a whole `..` chain of literals), and any entry whose file does not exist.
function M.stale_allowlist(paths, allowlistPath)
  local src = read_file(allowlistPath or "")
  if not src then error("cannot read allowlist " .. tostring(allowlistPath), 2) end
  local present = {}
  for _, file in ipairs(lua_files(paths)) do present[file] = true end
  local cache = {}
  local function literals_of(file)
    if cache[file] == nil then
      local text = read_file(file)
      if not text then
        cache[file] = false
      else
        local set = {}
        local prevJoin = nil
        for line in (text .. "\n"):gmatch("(.-)\r?\n") do
          if not is_comment(line) then
            local lits = line_literals(line)
            local chain = prevJoin
            for _, lit in ipairs(lits) do
              set[lit[3]] = true
              local between = chain and lit[4]:match("^%s*%.?%.?%s*$")
              if between then chain = chain .. lit[3]; set[chain] = true else chain = lit[3] end
            end
            local code = code_of(line)
            prevJoin = (#lits > 0 and code:match("%.%.%s*$")) and chain or nil
          end
        end
        cache[file] = set
      end
    end
    return cache[file]
  end
  local stale = {}
  for line in (src .. "\n"):gmatch("(.-)\r?\n") do
    if line:match("%S") and not line:match("^%s*#") then
      local file, literal = line:match("^([^:]+):(.*)$")
      if file then
        local set = (present[file] or read_file(file)) and literals_of(file)
        local ok
        if literal == "*" then ok = set ~= nil and set ~= false else ok = set and set[literal] end
        if not ok then stale[#stale + 1] = line end
      end
    end
  end
  table.sort(stale)
  return stale
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
  local unused = M.unused_keys(codePaths, enUS)
  for _, key in ipairs(missing) do print("missing from enUS: " .. key) end
  for _, key in ipairs(unused) do print("unused in code: " .. key) end
  if #missing > 0 or #unused > 0 then
    print(("%d locale key(s) missing, %d unused"):format(#missing, #unused))
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
