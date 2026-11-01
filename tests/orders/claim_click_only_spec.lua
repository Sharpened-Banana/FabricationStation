-- Structural rule (design rule 3; C_CraftingOrders.ClaimOrder is HasRestrictions): ClaimOrder is referenced only
-- inside `function Orders:ClaimBest` in Modules/Orders.lua, and Orders:ClaimBest is referenced (outside its own
-- definition) only in UI/OrdersPanel.lua, as a `:ClaimBest(` call directly inside a SetScript("OnClick", function
-- ... end) handler: never in a closure nested in it (a timer or a pcall(function() ... end) would run it outside the
-- click) and never passed on as a value.
-- "Referenced" covers calls, passing the function on (pcall(C_CraftingOrders.ClaimOrder, ...),
-- Wrap(name, Orders.ClaimBest)), aliases (local claim = C_CraftingOrders.ClaimOrder) and string keys
-- (C_CraftingOrders["ClaimOrder"]). Identifiers match as exact tokens (OnClaimOrderResponse is another name); string
-- contents match as substrings. Comments (-- and --[[ ]]) do not count.
local click_only = require("tests.helpers.click_only")

local CLAIM_HEADER = "function Orders:ClaimBest("

-- The tag a reference's enclosing function had in the scanner's own unit cases: "claimBest" inside Orders:ClaimBest,
-- "onClick" for the function passed to SetScript("OnClick", ...), nil otherwise.
local function tag(r)
  if r.fn == nil then return nil end
  if click_only.header_matches(r.fn, CLAIM_HEADER) then return "claimBest" end
  return r.fn.onClick and "onClick" or nil
end

-- References to ClaimOrder and ClaimBest in `text`, in source order, as { name, line, fn = tag, call }.
local function refs_of(text)
  local out, depth = {}, 0
  for _, name in ipairs({ "ClaimOrder", "ClaimBest" }) do
    local refs, open = click_only.references_in(text, name)
    depth = math.max(depth, open)
    for _, r in ipairs(refs) do out[#out + 1] = { name = r.name, line = r.line, fn = tag(r), call = r.call, order = #out } end
  end
  table.sort(out, function(a, b) if a.line ~= b.line then return a.line < b.line end return a.order < b.order end)
  for _, r in ipairs(out) do r.order = nil end
  return out, depth
end

-- The rule for one reference found in `path`.
local function accepted(path, r)
  if r.name == "ClaimOrder" then return path == "Modules/Orders.lua" and r.fn == "claimBest" end
  return path == "UI/OrdersPanel.lua" and r.fn == "onClick" and r.call
end

describe("click-only claiming", function()
  describe("the scanner", function()
    it("tokenizes past comments and strings, keeping line numbers", function()
      local tokens = click_only.tokens("a --[[ x\ny ]] b -- c\nd --[==[ ]] ]==] 'e' [[f\ng]] h")
      local out = {}
      for _, t in ipairs(tokens) do out[#out + 1] = t.kind .. ":" .. t.text .. ":" .. t.line end
      assert.same({ "name:a:1", "name:b:2", "name:d:3", "string:e:3", "string:f\ng:3", "name:h:4" }, out)
    end)
    it("accepts a direct call in an OnClick handler and a ClaimOrder call in Orders:ClaimBest", function()
      local refs, depth = refs_of([==[
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
      local refs = refs_of([==[
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
      local refs = refs_of([==[
function Orders:OnClaimOrderResponse(_, result, orderID) end
self:RegisterEvent("CRAFTINGORDERS_CLAIM_ORDER_RESPONSE", function(...) self:OnClaimOrderResponse(...) end)
local ClaimBestOrder, x = 1, "call ClaimOrder now"
]==])
      assert.same({ { name = "ClaimOrder", line = 3, call = false } }, refs)
    end)
  end)

  it("references C_CraftingOrders.ClaimOrder only inside Orders:ClaimBest", function()
    local ok, message, hits = click_only.only_inside("ClaimOrder", "Modules/Orders.lua", CLAIM_HEADER)
    assert.is_true(ok, message)
    assert.equal(1, #hits, "expected exactly one ClaimOrder reference, got: " .. table.concat(hits, ", "))
  end)

  it("references Orders:ClaimBest only as a call directly inside UI/OrdersPanel.lua OnClick handlers", function()
    local ok, message = click_only.referenced_only_from_onclick("ClaimBest", { "UI/OrdersPanel.lua" })
    assert.is_true(ok, message)
  end)

  it("has exactly one :ClaimBest( caller, in UI/OrdersPanel.lua", function()
    local _, _, calls = click_only.referenced_only_from_onclick("ClaimBest", { "UI/OrdersPanel.lua" })
    assert.equal(1, #calls, "expected exactly one :ClaimBest( call, got: " .. table.concat(calls, ", "))
    assert.truthy(calls[1]:find("^UI/OrdersPanel%.lua:"))
  end)

  it("defines Orders:ClaimBest in Modules/Orders.lua", function()
    assert.truthy(click_only.read("Modules/Orders.lua"):find("\nfunction Orders:ClaimBest%("))
  end)
end)
