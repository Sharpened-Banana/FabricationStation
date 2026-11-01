-- Structural rule (design rule 3, no automation): C_CraftingOrders.RequestCrafterOrders asks the server for orders, so
-- it is referenced only inside `function Orders:RequestBoard` in Modules/Orders.lua, and Orders:RequestBoard is
-- referenced only in UI/OrdersPanel.lua, as a `:RequestBoard(` call directly inside the Refresh button's
-- SetScript("OnClick", function ... end) handler: never in a closure nested in it (a timer, pcall) and never passed
-- on as a value. There is no timer refresh. The scan and its rules are tests/helpers/click_only.lua's.
local click_only = require("tests.helpers.click_only")

describe("click-only board refresh", function()
  it("references RequestCrafterOrders only inside Orders:RequestBoard", function()
    local ok, message, hits = click_only.only_inside("RequestCrafterOrders", "Modules/Orders.lua",
      "function Orders:RequestBoard(")
    assert.is_true(ok, message)
    assert.is_true(#hits >= 1)   -- the availability check and the call
    local _, calls = click_only.read("Modules/Orders.lua"):gsub("RequestCrafterOrders%(", "")
    assert.equal(1, calls)
  end)

  it("references RequestBoard only from an OnClick handler in UI/OrdersPanel.lua", function()
    local ok, message, calls = click_only.referenced_only_from_onclick("RequestBoard", { "UI/OrdersPanel.lua" },
      { definedIn = "Modules/Orders.lua" })
    assert.is_true(ok, message)
    assert.equal(1, #calls, "expected exactly one :RequestBoard( call, got: " .. table.concat(calls, ", "))
    assert.truthy(calls[1]:find("^UI/OrdersPanel%.lua:"))
  end)

  it("defines Orders:RequestBoard in Modules/Orders.lua", function()
    assert.truthy(click_only.body_of("Modules/Orders.lua", "function Orders:RequestBoard("))
  end)
end)
