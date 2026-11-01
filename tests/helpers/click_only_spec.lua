local click_only = require("tests.helpers.click_only")

describe("click_only helper", function()
  local function names(refs)
    local out = {}
    for _, r in ipairs(refs) do
      out[#out + 1] = r.line .. ":" .. tostring(r.fn and r.fn.header) .. ":" .. tostring(r.fn and r.fn.onClick) .. ":" .. tostring(r.call)
    end
    return out
  end
  it("records the enclosing function's header, the OnClick tag and the call flag", function()
    local refs, depth = click_only.references_in([==[
function Orders:RequestBoard(a, b)
  C_CraftingOrders.Ask(a)
end
button:SetScript("OnClick", ns.FS:Wrap(S, function(self)
  O:Ask()
  C_Timer.After(1, function() O:Ask() end)
end))
local alias = O.Ask
]==], "Ask")
    assert.equal(0, depth)
    assert.same({ "2:function Orders:RequestBoard(a, b):nil:false", "5:function(self):true:true",
      "6:function():nil:true", "8:nil:nil:false" }, names(refs))
  end)
  it("marks definitions instead of hiding them", function()
    local refs = click_only.references_in("function A.b:Ask() end\nlocal function Ask() end\nfunction Ask() end\nx = Ask", "Ask")
    assert.same({ true, true, true, false }, (function()
      local out = {}
      for i, r in ipairs(refs) do out[i] = r.definition == true end
      return out
    end)())
    assert.equal(4, refs[4].line)
  end)
  it("flags a redefinition of a guarded name anywhere but the owner's own header", function()
    local owner = os.tmpname()
    local f = assert(io.open(owner, "w"))
    f:write("function Orders:ClaimBest()\n  C_CraftingOrders.ClaimOrder(1)\nend\n"); f:close()
    local good = click_only.only_inside("ClaimOrder", owner, "function Orders:ClaimBest(", { files = { owner } })
    local redefined = io.open(owner, "w")
    redefined:write("function Orders:ClaimBest()\n  C_CraftingOrders.ClaimOrder(1)\nend\n"
      .. "function C_CraftingOrders.ClaimOrder(id) end\n")
    redefined:close()
    local bad, message = click_only.only_inside("ClaimOrder", owner, "function Orders:ClaimBest(", { files = { owner } })
    os.remove(owner)
    assert.is_true(good)
    assert.is_false(bad)
    assert.truthy(message:find("references ClaimOrder outside"))
  end)
  it("lets only the owner's own definition of a guarded name through", function()
    local path = os.tmpname()
    local f = assert(io.open(path, "w"))
    f:write("function Orders:ClaimBest()\nend\nbutton:SetScript(\"OnClick\", function() O:ClaimBest() end)\n"); f:close()
    local ok = click_only.referenced_only_from_onclick("ClaimBest", { path }, { files = { path }, definedIn = path })
    local elsewhere = click_only.referenced_only_from_onclick("ClaimBest", { path }, { files = { path }, definedIn = "x.lua" })
    os.remove(path)
    assert.is_true(ok)
    assert.is_false(elsewhere)   -- a definition outside the owning file
  end)
  it("matches headers by prefix", function()
    local _, _, funcs = click_only.references_in("local function shop_selected()\nend", "x")
    assert.is_true(click_only.header_matches(funcs[1], "function shop_selected("))
    assert.is_false(click_only.header_matches(funcs[1], "function shop("))
    assert.is_false(click_only.header_matches(nil, "function"))
  end)
  it("finds the body of a function by its header", function()
    local path = os.tmpname()
    local f = assert(io.open(path, "w"))
    f:write("local x = 1\nfunction A:Go(a)\n  if a then return 1 end\nend\nfunction A:Other() end\n")
    f:close()
    local body = click_only.body_of(path, "function A:Go(")
    os.remove(path)
    assert.equal("function A:Go(a)\n  if a then return 1 end\nend", body)
  end)
end)
