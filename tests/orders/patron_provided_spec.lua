-- Reagents a patron (NPC) order provides, from a real board (tests/fixtures/orders/rootbound_vat.lua): the Rootbound
-- Vat order whose Reagents cover asked for Composite Flora x4 although the patron provides the Flora, and the crafter
-- supplies only 4 Wondrous Synergist (which they own).
local VAT = require("tests.fixtures.orders.rootbound_vat")

describe("patron-provided reagents (Rootbound Vat, real data)", function()
  local ns, world, O, P

  before_each(function()
    ns, _, world = make_world({ last = "UI/OrdersPanel.lua" })
    world.schematics[VAT.schematic.recipeID] = VAT.schematic
    -- Prices: Composite Flora has none (the saved view's noPrice), the rest do.
    for _, itemID in ipairs({ 236950, 256963, VAT.SYNERGIST[1], VAT.SYNERGIST[2], 253506 }) do
      world.prices[itemID] = { value = 10000, source = "auction", ageDays = 1 }
    end
    world.bumpPriceVersion()
    O, P = ns.FS:GetModule("Orders"), ns.UI.OrdersPanel
  end)

  local function owned(itemID)
    local counts = { [236950] = 981, [256963] = 224, [VAT.SYNERGIST[1]] = 4, [VAT.SYNERGIST[2]] = 4 }
    return counts[itemID] or 0
  end

  it("Normalize keeps every reagent the order lists as provided, whatever its source", function()
    assert.same(VAT.provided, O:Normalize(VAT.rawOrder()).provided)
  end)

  it("the Reagents cover asks only for the Synergist, which is owned, and the profit is known", function()
    local view = O:ScoreInput(O:Normalize(VAT.rawOrder()), { charKey = "Main-Realm", now = ns.FS:Now(), bestGPC = 0 })
    local entries = P.ReagentEntries(view, owned)
    assert.equal(1, #entries)
    assert.equal(4, entries[1].count)
    assert.is_true(entries[1].itemID == VAT.SYNERGIST[1] or entries[1].itemID == VAT.SYNERGIST[2])
    assert.same({}, P.ShortEntries(entries))   -- nothing to draw: the cover shows its check
    -- The unpriced Flora is the patron's, so the reagent cost and the profit are known ...
    assert.is_number(view.net); assert.is_false(view.flags.noPrice)
    assert.are_not.equal("?", P.ProfitText(view))
    -- ... and the score stays unknown only because the character has not learned the recipe.
    assert.is_true(view.flags.unknownRecipe); assert.is_nil(view.score)
  end)
end)
