-- Structural rule (design rule 3; C_CraftingOrders.ClaimOrder is HasRestrictions): ClaimOrder is referenced only
-- inside `function Orders:ClaimBest` in Modules/Orders.lua, and Orders:ClaimBest is referenced (outside its own
-- definition) only in UI/OrdersPanel.lua, as a `:ClaimBest(` call directly inside a SetScript("OnClick", function
-- ... end) handler: never in a closure nested in it (a timer or a pcall(function() ... end) would run it outside the
-- click) and never passed on as a value.
-- "Referenced" covers calls, passing the function on (pcall(C_CraftingOrders.ClaimOrder, ...),
-- Wrap(name, Orders.ClaimBest)), aliases (local claim = C_CraftingOrders.ClaimOrder) and string keys
-- (C_CraftingOrders["ClaimOrder"]). Identifiers match as exact tokens (OnClaimOrderResponse is another name); string
-- contents match as substrings. Comments (-- and --[[ ]]) do not count.
local DIRS = "Core Data Math Modules UI"

-- Every .lua file in the TOC plus every .lua file under DIRS (a file missing from the TOC still counts).
local function lua_files()
  local seen, out = {}, {}
  local function add(path)
    if not seen[path] then seen[path] = true; out[#out + 1] = path end
  end
  for _, path in ipairs(read_toc("FabricationStation.toc").files) do
    if path:match("%.lua$") then add(path) end
  end
  local p = io.popen("find " .. DIRS .. " -name '*.lua' | sort")
  for line in p:lines() do add(line) end
  p:close()
  table.sort(out)
  return out
end

-- Lua source -> tokens { kind = "name"|"string"|"punct", text, line }. Comments (line and long), numbers and
-- whitespace are dropped; long strings ([[ ]], [==[ ]==]) and quoted strings become "string" tokens.
local function tokenize(text)
  local tokens, i, n, line = {}, 1, #text, 1
  local function add(kind, s) tokens[#tokens + 1] = { kind = kind, text = s, line = line } end
  local function count_lines(s) local _, k = s:gsub("\n", ""); line = line + k end
  local function long_bracket(at)  -- at points at "[" ; returns content, index after close
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
      add("string", content); count_lines(raw); i = after
    elseif c == '"' or c == "'" then
      local j, buf = i + 1, {}
      while j <= n and text:sub(j, j) ~= c and text:sub(j, j) ~= "\n" do
        if text:sub(j, j) == "\\" then buf[#buf + 1] = text:sub(j, j + 1); j = j + 2
        else buf[#buf + 1] = text:sub(j, j); j = j + 1 end
      end
      add("string", table.concat(buf)); i = j + 1
    elseif c:match("[%a_]") then
      local w = text:match("^[%a_][%w_]*", i)
      add("name", w); i = i + #w
    elseif c:match("%d") then
      i = i + #text:match("^[%w%.]+", i)
    else
      add("punct", c); i = i + 1
    end
  end
  return tokens
end

-- Walks the tokens, tracking blocks (function/do/if/repeat ... end/until) and parentheses. Returns every reference
-- to ClaimOrder or ClaimBest (a name or string token containing it) as { name, line, fn = tag of the innermost
-- enclosing function }, where a function's tag is "claimBest" for `function Orders:ClaimBest(`, "onClick" for the
-- first function inside the argument list of SetScript("OnClick", ...), and nil otherwise. The ClaimBest name in
-- its own definition is not a reference.
local function references(text)
  local tokens = tokenize(text)
  local stack, refs, parens, onClickAt = {}, {}, 0, nil
  local function innermost()
    for k = #stack, 1, -1 do
      if stack[k].kind == "function" then return stack[k].tag end
    end
  end
  local function is(k, kind, s) local t = tokens[k]; return t ~= nil and t.kind == kind and t.text == s end
  for k, t in ipairs(tokens) do
    if t.kind == "punct" and t.text == "(" then
      parens = parens + 1
      if is(k - 1, "name", "SetScript") and is(k + 1, "string", "OnClick") then onClickAt = parens end
    elseif t.kind == "punct" and t.text == ")" then
      parens = parens - 1
      if onClickAt and parens < onClickAt then onClickAt = nil end
    elseif t.kind == "name" and t.text == "function" then
      local tag
      if is(k + 1, "name", "Orders") and is(k + 2, "punct", ":") and is(k + 3, "name", "ClaimBest") and is(k + 4, "punct", "(") then
        tag = "claimBest"
      elseif onClickAt then
        tag, onClickAt = "onClick", nil
      end
      stack[#stack + 1] = { kind = "function", tag = tag }
    elseif t.kind == "name" and (t.text == "do" or t.text == "if" or t.text == "repeat") then
      stack[#stack + 1] = { kind = "block" }
    elseif t.kind == "name" and (t.text == "end" or t.text == "until") then
      stack[#stack] = nil
    end
    for _, name in ipairs({ "ClaimOrder", "ClaimBest" }) do
      if (t.kind == "name" and t.text == name) or (t.kind == "string" and t.text:find(name, 1, true)) then
        local definition = name == "ClaimBest" and t.kind == "name" and is(k - 3, "name", "function")
          and is(k - 2, "name", "Orders") and is(k - 1, "punct", ":")
        if not definition then
          local call = t.kind == "name" and is(k - 1, "punct", ":") and is(k + 1, "punct", "(")
          refs[#refs + 1] = { name = name, line = t.line, fn = innermost(), call = call }
        end
      end
    end
  end
  return refs, #stack
end

-- The rule for one reference found in `path`.
local function accepted(path, r)
  if r.name == "ClaimOrder" then return path == "Modules/Orders.lua" and r.fn == "claimBest" end
  return path == "UI/OrdersPanel.lua" and r.fn == "onClick" and r.call
end

local function read(path)
  local f = assert(io.open(path, "r"))
  local text = f:read("*a")
  f:close()
  return text
end

describe("click-only claiming", function()
  describe("the scanner", function()
    it("tokenizes past comments and strings, keeping line numbers", function()
      local tokens = tokenize("a --[[ x\ny ]] b -- c\nd --[==[ ]] ]==] 'e' [[f\ng]] h")
      local out = {}
      for _, t in ipairs(tokens) do out[#out + 1] = t.kind .. ":" .. t.text .. ":" .. t.line end
      assert.same({ "name:a:1", "name:b:2", "name:d:3", "string:e:3", "string:f\ng:3", "name:h:4" }, out)
    end)
    it("accepts a direct call in an OnClick handler and a ClaimOrder call in Orders:ClaimBest", function()
      local refs, depth = references([==[
function Orders:ClaimBest()
  if x then C_CraftingOrders.ClaimOrder(id, p) end
end
button:SetScript("OnClick", ns.FS:Wrap("OrdersSidePanel", function(self)
  for i = 1, 2 do f() end
  local view = Orders:ClaimBest()
end))
]==])
      assert.equal(0, depth)
      assert.same({ { name = "ClaimOrder", line = 2, fn = "claimBest", call = false },
                    { name = "ClaimBest", line = 6, fn = "onClick", call = true } }, refs)
      assert.is_true(accepted("Modules/Orders.lua", refs[1])); assert.is_true(accepted("UI/OrdersPanel.lua", refs[2]))
    end)
    it("flags timers, pcall forms, aliases, string keys and other handlers", function()
      local refs = references([==[
button:SetScript("OnClick", function() C_Timer.After(1, function() Orders:ClaimBest() end) end)
button:SetScript("OnEnter", function() Orders:ClaimBest() end)
local ok = pcall(Orders.ClaimBest, Orders)
local claim = C_CraftingOrders["ClaimOrder"]
function Orders:ClaimBest() C_Timer.After(0, function() C_CraftingOrders.ClaimOrder(1, 2) end) end
button:SetScript("OnClick", f) local g = function() Orders:ClaimBest() end
--[[ Orders:ClaimBest() C_CraftingOrders.ClaimOrder() ]] -- Orders:ClaimBest()
button:SetScript("OnClick", function() local f = Orders.ClaimBest; f(Orders) end)
button:SetScript("OnClick", function() Orders["ClaimBest"](Orders); C_Timer.After(0, Orders.ClaimBest) end)
]==])
      local lines = {}
      for _, r in ipairs(refs) do
        lines[#lines + 1] = r.name .. ":" .. r.line .. ":" .. tostring(r.fn) .. ":" .. (r.call and "call" or "value")
        assert.is_false(accepted("UI/OrdersPanel.lua", r), "line " .. r.line .. " should be flagged")
        assert.is_false(accepted("Modules/Orders.lua", r), "line " .. r.line .. " should be flagged")
      end
      assert.same({ "ClaimBest:1:nil:call", "ClaimBest:2:nil:call", "ClaimBest:3:nil:value", "ClaimOrder:4:nil:value",
        "ClaimOrder:5:nil:value", "ClaimBest:6:nil:call", "ClaimBest:8:onClick:value", "ClaimBest:9:onClick:value",
        "ClaimBest:9:onClick:value" }, lines)
    end)
    it("matches identifiers as exact tokens and strings as substrings", function()
      local refs = references([==[
function Orders:OnClaimOrderResponse(_, result, orderID) end
self:RegisterEvent("CRAFTINGORDERS_CLAIM_ORDER_RESPONSE", function(...) self:OnClaimOrderResponse(...) end)
local ClaimBestOrder, x = 1, "call ClaimOrder now"
]==])
      assert.same({ { name = "ClaimOrder", line = 3, call = false } }, refs)
    end)
  end)

  it("references C_CraftingOrders.ClaimOrder only inside Orders:ClaimBest", function()
    local hits = {}
    for _, path in ipairs(lua_files()) do
      local refs, depth = references(read(path))
      assert.equal(0, depth, path .. ": unbalanced blocks (scanner out of step)")
      for _, r in ipairs(refs) do
        if r.name == "ClaimOrder" then
          hits[#hits + 1] = path .. ":" .. r.line
          assert.is_true(accepted(path, r), path .. ":" .. r.line .. " references ClaimOrder outside Orders:ClaimBest")
        end
      end
    end
    assert.equal(1, #hits, "expected exactly one ClaimOrder reference, got: " .. table.concat(hits, ", "))
  end)

  it("references Orders:ClaimBest only as a call directly inside UI/OrdersPanel.lua OnClick handlers", function()
    for _, path in ipairs(lua_files()) do
      for _, r in ipairs(references(read(path))) do
        if r.name == "ClaimBest" then
          assert.is_true(accepted(path, r),
            path .. ":" .. r.line .. " references ClaimBest other than as a :ClaimBest( call directly in an OnClick "
            .. "handler in UI/OrdersPanel.lua")
        end
      end
    end
  end)

  it("has exactly one :ClaimBest( caller, in UI/OrdersPanel.lua", function()
    local calls = {}
    for _, path in ipairs(lua_files()) do
      for _, r in ipairs(references(read(path))) do
        if r.name == "ClaimBest" and r.call then calls[#calls + 1] = path .. ":" .. r.line end
      end
    end
    assert.equal(1, #calls, "expected exactly one :ClaimBest( call, got: " .. table.concat(calls, ", "))
    assert.truthy(calls[1]:find("^UI/OrdersPanel%.lua:"))
  end)

  it("defines Orders:ClaimBest in Modules/Orders.lua", function()
    assert.truthy(read("Modules/Orders.lua"):find("\nfunction Orders:ClaimBest%("))
  end)
end)
