-- An Automatic reagent slot that is not required (a Midnight socket slot) is not part of the craft: the Evercore Wrist
-- Latch order (tests/fixtures/orders/evercore_wrist_latch.lua, real data) needs Evercore x1 from the crafter and
-- nothing else, so its Reagents cover shows the "stocked" check for a crafter who owns Evercore, not a socket
-- reagent with no icon, and its profit does not wait on a socket's price.
local LATCH = require("tests.fixtures.orders.evercore_wrist_latch")

describe("a not-required Automatic slot (Evercore Wrist Latch, real data)", function()
  local ns, world, O, P, CD

  before_each(function()
    ns, _, world = make_world({ last = "UI/OrdersPanel.lua" })
    world.schematics[LATCH.schematic.recipeID] = LATCH.schematic
    -- The character knows the recipe (Holeehands-Exodar does).
    world.chars["Main-Realm"].professions[2910] = { name = "Midnight Engineering", skill = 100, maxSkill = 100,
      skillModifier = 13, expansionName = "Midnight", recipes = { [LATCH.schematic.recipeID] = true }, cooldowns = {},
      tools = {}, time = ns.FS:Now() }
    -- Evercore and the output have prices; the socket reagents have none.
    for _, itemID in ipairs({ LATCH.EVERCORE[1], LATCH.EVERCORE[2], 245341 }) do
      world.prices[itemID] = { value = 10000, source = "auction", ageDays = 1 }
    end
    world.bumpPriceVersion()
    O, P, CD = ns.FS:GetModule("Orders"), ns.UI.OrdersPanel, ns.CraftingData
  end)

  local function owned(itemID)
    return (itemID == LATCH.EVERCORE[1] or itemID == LATCH.EVERCORE[2]) and 36 or 0
  end
  local function view()
    return O:ScoreInput(O:Normalize(LATCH.rawOrder()), { charKey = "Main-Realm", now = ns.FS:Now(), bestGPC = 0 })
  end

  it("IsAllocated leaves out a basic slot that is Automatic and not required", function()
    assert.is_false(CD.IsAllocated(LATCH.schematic.reagentSlots[6]))
    assert.is_true(CD.IsAllocated(LATCH.schematic.reagentSlots[1]))
    -- A basic slot that does not say whether it is required stays allocated (older and hand-built schematics).
    assert.is_true(CD.IsAllocated({ kind = "basic", reagents = { 1 } }))
  end)

  it("BuildInput gives Math only the Evercore slot", function()
    local input = CD.BuildInput(ns.GameData, { schematic = LATCH.schematic, professionSkill = 113, optionalItemIDs = {} })
    local slots = {}
    for i, slot in ipairs(input.slots) do slots[i] = slot.slotIndex end
    assert.same({ 1 }, slots)
    for _, row in ipairs(input.optionalSlots) do assert.are_not.equal(6, row.slotIndex) end
  end)

  it("the Reagents cover shows the stocked check: Evercore is owned and no socket is asked for", function()
    local v = view()
    for _, row in ipairs(v.result.allocation) do
      for _, socket in ipairs(LATCH.SOCKETS) do assert.are_not.equal(socket, row.itemID) end
    end
    local entries = P.ReagentEntries(v, owned)
    assert.equal(1, #entries)
    assert.is_true(entries[1].itemID == LATCH.EVERCORE[1] or entries[1].itemID == LATCH.EVERCORE[2])
    assert.equal(1, entries[1].count)
    assert.same({}, P.ShortEntries(entries))
    -- The socket's missing price no longer leaves the profit unknown.
    assert.is_false(v.flags.noPrice)
    assert.is_number(v.net)
    assert.are_not.equal("?", P.ProfitText(v))
  end)
end)
