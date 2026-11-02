-- Structural rule (design rule 3, no automation): the Orders tab's Shop selected export. Queue:ExportShoppingList with
-- entries is referenced in UI/Tabs/Orders.lua only inside `local function shop_selected`, and shop_selected only as the
-- action of the Shop button, which create_button binds to a wrapped OnClick script. Nothing else in the tab (a timer,
-- a refresh, an event handler) can start the export. Comments do not count; the scan is tests/helpers/click_only.lua's.
-- The Queue tab's own Export (UI/Tabs/Queue.lua) is another caller, so the first check is limited to this file.
local click_only = require("tests.helpers.click_only")

local PATH = "UI/Tabs/Orders.lua"
local SHOP = "function shop_selected("

describe("Orders tab shopping is click-only", function()
  it("references ExportShoppingList once, inside shop_selected", function()
    local ok, message, hits = click_only.only_inside("ExportShoppingList", PATH, SHOP, { files = { PATH } })
    assert.is_true(ok, message)
    assert.is_true(#hits >= 1)   -- the availability check and the call
    local refs = click_only.references(PATH, "ExportShoppingList")
    local calls = 0
    for _, r in ipairs(refs) do if r.call then calls = calls + 1 end end
    assert.equal(1, calls)
  end)

  it("references shop_selected only in its definition and as the Shop button's action", function()
    assert.is_truthy(click_only.body_of(PATH, SHOP), "shop_selected is not defined")
    local refs = {}
    for _, r in ipairs(click_only.references(PATH, "shop_selected")) do
      if not r.definition then refs[#refs + 1] = r end
    end
    assert.equal(1, #refs)
    local lines = {}
    for line in (click_only.read(PATH) .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
    local use = lines[refs[1].line]
    assert.is_truthy(use:find("created.shop = create_button(", 1, true))
    assert.is_truthy(use:match("create_button%(.-, shop_selected%)%s*$"))
  end)

  it("binds a create_button action to a wrapped OnClick script and nothing else", function()
    local body = click_only.body_of(PATH, "function create_button(")
    assert.is_truthy(body, "create_button is not defined")
    assert.is_truthy(body:find('button:SetScript("OnClick", ns.FS:Wrap(SOURCE, action))', 1, true))
    local first, last = click_only.span_of(PATH, "function create_button(")
    local uses = 0
    for _, r in ipairs(click_only.references(PATH, "action")) do
      if r.pos >= first and r.pos <= last then uses = uses + 1 end   -- also a use in a closure nested in it
    end
    assert.equal(2, uses)   -- the parameter and its single use
    assert.is_nil(body:find("C_Timer", 1, true)); assert.is_nil(body:find("Debounce", 1, true))
  end)
end)
