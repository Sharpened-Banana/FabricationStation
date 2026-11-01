-- Structural checks for "click only" rules (design rule 3: nothing acts for the player without a click or key press).
-- A protected or acting call is referenced only inside one function (`only_inside`), and that function is referenced
-- only as a direct call inside a SetScript("OnClick", function ... end) handler (`referenced_only_from_onclick`).
-- Used by tests/orders/claim_click_only_spec.lua, shop_click_only_spec.lua and refresh_click_only_spec.lua; later
-- tasks add their rows through the same two checks.
--
-- "Referenced" covers calls, passing the function on (pcall(C_CraftingOrders.ClaimOrder, ...),
-- Wrap(name, Orders.ClaimBest)), aliases (local claim = C_CraftingOrders.ClaimOrder) and string keys
-- (C_CraftingOrders["ClaimOrder"]). Identifiers match as exact tokens (OnClaimOrderResponse is another name); string
-- contents match as substrings. Comments (-- and --[[ ]]) do not count. The name in its own definition
-- (`function Orders:ClaimBest(`, `local function shop_selected(`) is not a reference.
local M = {}

M.DIRS = "Core Data Math Modules UI"

function M.read(path)
  local f = assert(io.open(path, "r"), "cannot open " .. tostring(path))
  local text = f:read("*a")
  f:close()
  return text
end

-- Every .lua file in the TOC plus every .lua file under DIRS (a file missing from the TOC still counts).
function M.lua_files()
  local seen, out = {}, {}
  local function add(path)
    if not seen[path] then seen[path] = true; out[#out + 1] = path end
  end
  for _, path in ipairs(read_toc("FabricationStation.toc").files) do
    if path:match("%.lua$") then add(path) end
  end
  local p = io.popen("find " .. M.DIRS .. " -name '*.lua' | sort")
  for line in p:lines() do add(line) end
  p:close()
  table.sort(out)
  return out
end

-- Lua source -> tokens { kind = "name"|"string"|"punct", text, line, pos }. Comments (line and long), numbers and
-- whitespace are dropped; long strings ([[ ]], [==[ ]==]) and quoted strings become "string" tokens. pos is the
-- index of the token's first character in the text.
function M.tokens(text)
  local tokens, i, n, line = {}, 1, #text, 1
  local function add(kind, s, at) tokens[#tokens + 1] = { kind = kind, text = s, line = line, pos = at } end
  local function count_lines(s) local _, k = s:gsub("\n", ""); line = line + k end
  local function long_bracket(at)  -- at points at "[" ; returns content, index after close, raw text
    local eqs = text:match("^%[(=*)%[", at)
    if not eqs then return nil end
    local open = at + 2 + #eqs
    local close = "]" .. eqs .. "]"
    local e = text:find(close, open, true)
    local stop = e and (e + #close - 1) or n
    return text:sub(open, (e or n + 1) - 1), stop + 1, text:sub(at, stop)
  end
  while i <= n do
    local c = text:sub(i, i)
    if c == "\n" then
      line = line + 1; i = i + 1
    elseif c:match("%s") then
      i = i + 1
    elseif text:sub(i, i + 1) == "--" then
      local _, after, raw = long_bracket(i + 2)
      if after then
        count_lines(raw); i = after
      else
        i = text:find("\n", i, true) or (n + 1)
      end
    elseif c == "[" and text:match("^%[=*%[", i) then
      local content, after, raw = long_bracket(i)
      add("string", content, i); count_lines(raw); i = after
    elseif c == '"' or c == "'" then
      local j, buf = i + 1, {}
      while j <= n and text:sub(j, j) ~= c and text:sub(j, j) ~= "\n" do
        if text:sub(j, j) == "\\" then buf[#buf + 1] = text:sub(j, j + 1); j = j + 2
        else buf[#buf + 1] = text:sub(j, j); j = j + 1 end
      end
      add("string", table.concat(buf), i); i = j + 1
    elseif c:match("[%a_]") then
      local w = text:match("^[%a_][%w_]*", i)
      add("name", w, i); i = i + #w
    elseif c:match("%d") then
      i = i + #text:match("^[%w%.]+", i)
    else
      add("punct", c, i); i = i + 1
    end
  end
  return tokens
end

-- Walks the tokens, tracking blocks (function/do/if/repeat ... end/until) and parentheses. Returns every reference
-- to `name` (a name token equal to it, or a string token containing it) as
--   { name, line, call, fn }
-- where call is true for `:name(` and fn is the innermost enclosing function as { header, onClick, first, last }
-- (nil outside any function): header is the source text from `function` to the closing parenthesis of its
-- parameters ("function Orders:ClaimBest()"), onClick is true for the first function inside the argument list of
-- SetScript("OnClick", ...), first/last are the text positions of the function's `function` and closing `end`.
-- Second return: the number of blocks left open (0 when the scanner stayed in step). Third: every function record.
function M.references_in(text, name)
  local tokens = M.tokens(text)
  local stack, refs, funcs, parens, onClickAt = {}, {}, {}, 0, nil
  local function innermost()
    for k = #stack, 1, -1 do
      if stack[k].kind == "function" then return stack[k].fn end
    end
  end
  local function is(k, kind, s) local t = tokens[k]; return t ~= nil and t.kind == kind and t.text == s end
  local function header_of(k)   -- text from the `function` token to the ")" closing its parameter list
    local depth, j = 0, k + 1
    while tokens[j] do
      if tokens[j].kind == "punct" and tokens[j].text == "(" then depth = depth + 1
      elseif tokens[j].kind == "punct" and tokens[j].text == ")" then
        depth = depth - 1
        if depth <= 0 then return text:sub(tokens[k].pos, tokens[j].pos) end
      end
      j = j + 1
    end
    return text:sub(tokens[k].pos)
  end
  local function is_definition(k)   -- `function name(`, `function A:name(`, `function A.b:name(`
    local j = k - 1
    while (is(j, "punct", ":") or is(j, "punct", ".")) and tokens[j - 1] and tokens[j - 1].kind == "name" do
      j = j - 2
    end
    return is(j, "name", "function")
  end
  for k, t in ipairs(tokens) do
    if t.kind == "punct" and t.text == "(" then
      parens = parens + 1
      if is(k - 1, "name", "SetScript") and is(k + 1, "string", "OnClick") then onClickAt = parens end
    elseif t.kind == "punct" and t.text == ")" then
      parens = parens - 1
      if onClickAt and parens < onClickAt then onClickAt = nil end
    elseif t.kind == "name" and t.text == "function" then
      local fn = { header = header_of(k), first = t.pos, line = t.line }
      if onClickAt then fn.onClick, onClickAt = true, nil end
      funcs[#funcs + 1] = fn
      stack[#stack + 1] = { kind = "function", fn = fn }
    elseif t.kind == "name" and (t.text == "do" or t.text == "if" or t.text == "repeat") then
      stack[#stack + 1] = { kind = "block" }
    elseif t.kind == "name" and (t.text == "end" or t.text == "until") then
      local top = stack[#stack]
      if top and top.fn then top.fn.last = t.pos + #t.text - 1 end
      stack[#stack] = nil
    end
    if (t.kind == "name" and t.text == name) or (t.kind == "string" and t.text:find(name, 1, true)) then
      if not (t.kind == "name" and is_definition(k)) then
        refs[#refs + 1] = { name = name, line = t.line, fn = innermost(),
          call = t.kind == "name" and is(k - 1, "punct", ":") and is(k + 1, "punct", "(") }
      end
    end
  end
  return refs, #stack, funcs
end

-- references_in over a file.
function M.references(path, name)
  return M.references_in(M.read(path), name)
end

-- True when function record `fn` is the function whose header starts with `header` ("function Orders:RequestBoard(").
local function header_matches(fn, header)
  return fn ~= nil and fn.header:sub(1, #header) == header
end
M.header_matches = header_matches

-- The text of the (first) function in `path` whose header starts with `header`, from `function` to its `end`;
-- nil when there is none.
function M.body_of(path, header)
  local text = M.read(path)
  local _, _, funcs = M.references_in(text, "\0")
  for _, fn in ipairs(funcs) do
    if header_matches(fn, header) and fn.last then return text:sub(fn.first, fn.last) end
  end
end

-- Every reference to `token` in every Lua file (or only `files`) is inside the function whose header starts with
-- `header` in `path`, directly (never in a closure nested in it, which could run later). -> ok, message, hits where
-- hits is the list of "path:line" references found. Fails when there are none (the rule would be vacuous).
function M.only_inside(token, path, header, files)
  local hits, bad = {}, {}
  for _, file in ipairs(files or M.lua_files()) do
    local refs, depth = M.references(file, token)
    if depth ~= 0 then bad[#bad + 1] = file .. ": unbalanced blocks (scanner out of step)" end
    for _, r in ipairs(refs) do
      hits[#hits + 1] = file .. ":" .. r.line
      if not (file == path and header_matches(r.fn, header)) then
        bad[#bad + 1] = file .. ":" .. r.line .. " references " .. token .. " outside " .. header
      end
    end
  end
  if #hits == 0 then bad[#bad + 1] = "no reference to " .. token .. " found" end
  return #bad == 0, table.concat(bad, "\n"), hits
end

-- Every reference to `name` in every Lua file (or only `files`) is a `:name(` call directly inside a
-- SetScript("OnClick", function ... end) handler in one of `allowedPaths`: never in a closure nested in the handler
-- (a timer or a pcall(function() ... end) would run it outside the click) and never passed on as a value.
-- -> ok, message, calls where calls is the list of "path:line" of the calls. Fails when there are none.
function M.referenced_only_from_onclick(name, allowedPaths, files)
  local allowed = {}
  for _, p in ipairs(allowedPaths) do allowed[p] = true end
  local calls, bad = {}, {}
  for _, file in ipairs(files or M.lua_files()) do
    local refs, depth = M.references(file, name)
    if depth ~= 0 then bad[#bad + 1] = file .. ": unbalanced blocks (scanner out of step)" end
    for _, r in ipairs(refs) do
      if r.call then calls[#calls + 1] = file .. ":" .. r.line end
      if not (allowed[file] and r.fn and r.fn.onClick and r.call) then
        bad[#bad + 1] = file .. ":" .. r.line .. " references " .. name
          .. " other than as a :" .. name .. "( call directly in an OnClick handler"
      end
    end
  end
  if #calls == 0 then bad[#bad + 1] = "no :" .. name .. "( call found" end
  return #bad == 0, table.concat(bad, "\n"), calls
end

return M
