local P2 = require("tests.helpers.phase2")
local LATCH = require("tests.fixtures.orders.evercore_wrist_latch")

local FILES = { "Modules/CraftingData.lua", "Modules/Customers.lua", "Data/OrderRewards.lua", "Modules/Orders.lua",
  "Modules/Ledger.lua", "UI/OrdersPanel.lua" }
local RANK1, RANK2 = LATCH.EVERCORE[1], LATCH.EVERCORE[2]
local GREY, RED, WHITE = { 0.62, 0.62, 0.62 }, { 1, 0.25, 0.25 }, { 1, 1, 1 }

-- The Reagents cover counts what you own of a reagent across every rank its slot lists (the cached schematic's slot,
-- found by the allocation's slotIndex): any rank fills the order's slot, the rank only changes the quality. The
-- Evercore Wrist Latch (tests/fixtures/orders/evercore_wrist_latch.lua) plans Evercore at rank 1; you own rank 2.
describe("OrdersPanel Reagents cover: owned counts across ranks", function()
  local ns, W, form, tooltip, owned, board, evalResult, P

  local function boot()
    owned, board = {}, {}
    evalResult = { expectedQuality = 1, reagentCost = 10000, flags = {},
      allocation = { { slotIndex = 1, itemID = RANK1, quantity = 1 } } }
    tooltip = { lines = {}, colors = {} }
    local function add(t, r, g, b)
      tooltip.lines[#tooltip.lines + 1] = t
      tooltip.colors[#tooltip.colors + 1] = { r, g, b }
    end
    local GameTooltip = {
      SetOwner = function(_, owner) tooltip.owner = owner; tooltip.lines = {}; tooltip.colors = {} end,
      GetOwner = function() return tooltip.owner end,
      SetText = function(_, t, r, g, b) add(t, r, g, b) end,
      AddLine = function(_, t, r, g, b) add(t, r, g, b) end,
      Show = function() tooltip.shown = true end,
      Hide = function() tooltip.shown = false end,
    }
    ns, W = P2.boot({ GameTooltip = GameTooltip,
      C_CraftingOrders = { GetCrafterOrders = function() return board end, GetCraftingOrderTime = function() return 5000 end },
      C_TradeSkillUI = { GetChildProfessionInfo = function() return { profession = 8 } end },
      C_Item = {
        GetItemInfo = function(id) if id == RANK1 then return "Evercore", "|Hitem:243581|h[Evercore]|h" end end,
        GetItemIconByID = function(id) return 900000 + id end,
        RequestLoadItemDataByID = function() end,
      } })
    P2.fake_module(ns, "Recipes", { Evaluate = function() return evalResult end, GetRanked = function() return {} end })
    P2.fake_module(ns, "Prices", { Get = function() return {} end })
    P2.fake_module(ns, "Scanner", {
      GetSchematic = function(_, recipeID) if recipeID == LATCH.schematic.recipeID then return LATCH.schematic end end,
      ProjectConcentration = function() return 500 end,
      GetLiveOwnedCount = function(_, itemID) return owned[itemID] end,
      GetOwnedCount = function() return 0 end })
    P2.fake_module(ns, "Queue", { Add = function() return 1 end, GetEntries = function() return {} end })
    form = fake_professions_frame()
    P2.load(ns, FILES)
    W.fire("ADDON_LOADED", "Blizzard_Professions")
    P = ns.UI.OrdersPanel
  end

  after_each(function() fake_professions_frame.reset() end)

  local function show()
    local raw = LATCH.rawOrder()
    local row = form.newOrderRow()
    form.acquireOrderRow(row, form.orderElement(raw), true)
    board = { raw }
    form.ordersPage:ShowOrders(0, false)
    return ns.FS:GetModule("OrdersRowAddons"):GetCells(row)
  end
  local function hover(c)
    c.cover:GetScript("OnEnter")(c.cover)
    local lines, colors = tooltip.lines, tooltip.colors
    c.cover:GetScript("OnLeave")(c.cover)
    return lines, colors
  end

  it("planned at rank 1, owned at rank 2 only: the entry is stocked and the tooltip says so in grey", function()
    boot()
    owned[RANK1], owned[RANK2] = 0, 36
    local c = show()
    assert.equal("stocked", c.coverMode)
    assert.same({}, c.shortEntries)
    assert.is_true(c.coverCheck:IsShown())
    local lines, colors = hover(c)
    assert.same({ "You have every reagent this order needs from you", "Reagents to supply",
      "|Hitem:243581|h[Evercore]|h: need 1, have 36", "You have 36 of a different rank (quality may differ)" }, lines)
    assert.same(GREY, colors[4])
  end)

  it("no different-rank line when the planned rank is owned", function()
    boot()
    owned[RANK1], owned[RANK2] = 2, 5
    local c = show()
    assert.equal("stocked", c.coverMode)
    local lines = hover(c)
    assert.same({ "You have every reagent this order needs from you", "Reagents to supply",
      "|Hitem:243581|h[Evercore]|h: need 1, have 7" }, lines)
  end)

  it("owning less than needed across ranks still shows the reagent in red", function()
    boot()
    evalResult.allocation = { { slotIndex = 1, itemID = RANK1, quantity = 4 } }
    owned[RANK1], owned[RANK2] = 1, 2
    local c = show()
    assert.equal("reagents", c.coverMode)
    assert.equal(1, #c.shortEntries)
    assert.same({ RANK1, 4, 3 }, { c.shortEntries[1].itemID, c.shortEntries[1].count, c.shortEntries[1].have })
    local lines, colors = hover(c)
    assert.equal("|Hitem:243581|h[Evercore]|h: need 4, have 3", lines[2])
    assert.same(RED, colors[2])
    assert.equal("You have 2 of a different rank (quality may differ)", lines[3])
  end)

  it("keeps an unknown count nil (white) when the game cannot count any rank", function()
    boot()
    local c = show()
    assert.equal("reagents", c.coverMode)
    assert.is_nil(c.reagentEntries[1].have)
    local lines, colors = hover(c)
    assert.same({ "Reagents to supply", "|Hitem:243581|h[Evercore]|h: need 1" }, lines)
    assert.same(WHITE, colors[2])
  end)

  it("counts what the customer provides of any rank of the slot", function()
    boot()
    owned[RANK1], owned[RANK2] = 0, 0
    local view = { recipeID = LATCH.schematic.recipeID, input = { provided = { [RANK2] = 1 } },
      result = { allocation = { { slotIndex = 1, itemID = RANK1, quantity = 1 } } } }
    assert.same({}, P.ReagentEntries(view, function(id) return owned[id] end))
  end)
end)
