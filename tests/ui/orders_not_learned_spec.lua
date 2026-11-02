local P2 = require("tests.helpers.phase2")

local FILES = { "Modules/Customers.lua", "Data/OrderRewards.lua", "Modules/Orders.lua", "Modules/Ledger.lua",
  "UI/OrdersPanel.lua" }
local CROSS = "\195\151"   -- the multiplication sign, as the concentration cell's unreachable mark
local RED = { 1, 0.25, 0.25 }

-- A recipe the character has not learned (the notLearned risk) gets a red "×" in place of the profit, which stays when
-- the profit cell gives way and, with the risk count, when even the core of the strip has no room (a long item name
-- such as "Thalassian Competitor's Mail Links" with minimum-quality pips, which showed no cells at all).
describe("OrdersPanel: a recipe you have not learned", function()
  local ns, W, form, tooltip, unknownRecipe, board

  local function boot()
    unknownRecipe = true
    tooltip = { lines = {} }
    local GameTooltip = {
      SetOwner = function(_, owner) tooltip.owner = owner; tooltip.lines = {} end,
      SetText = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
      AddLine = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
      Show = function() tooltip.shown = true end,
      Hide = function() tooltip.shown = false end,
    }
    board = {}
    ns, W = P2.boot({ GameTooltip = GameTooltip,
      C_CraftingOrders = { GetCrafterOrders = function() return board end, GetCraftingOrderTime = function() return 5000 end },
      C_TradeSkillUI = { GetChildProfessionInfo = function() return { profession = 7 } end },
      C_Item = { GetItemInfo = function() end, RequestLoadItemDataByID = function() end } })
    P2.fake_module(ns, "Recipes", {
      Evaluate = function() return { expectedQuality = 3, reagentCost = 200000, flags = { unknownRecipe = unknownRecipe } } end,
      GetRanked = function() return {} end })
    P2.fake_module(ns, "Prices", { Get = function() return {} end })
    P2.fake_module(ns, "Scanner", { GetSchematic = function() return { skillLineID = 2900 } end,
      ProjectConcentration = function() return 500 end })
    P2.fake_module(ns, "Queue", { Add = function() return 1 end, GetEntries = function() return {} end })
    form = fake_professions_frame()
    P2.load(ns, FILES)
    W.fire("ADDON_LOADED", "Blizzard_Professions")
    ns.FS.db.global.recipeCatalog = { [2900] = { [10] = { name = "Mail Links", sourceText = "Vendor: Mirvedon", time = 1 } } }
  end

  after_each(function() fake_professions_frame.reset() end)

  local function rows() return ns.FS:GetModule("OrdersRowAddons") end
  local function LY() return ns.UI.OrdersPanel.LAYOUT end
  -- Row geometry as in orders_panel_spec: the strip's right edge is 294 from the row's left, the name ends at
  -- 22 + textWidth and keeps a GAP. Name widths that leave room for each tier derive from the module's LAYOUT.
  local function room_for(width) return 294 - LY().GAP - 22 - width end
  local function w_short() return room_for(LY().CORE_WIDTH + LY().PROFIT_SLOT) - 20 end     -- everything fits
  local function w_medium() return room_for(LY().CORE_WIDTH + LY().PROFIT_SLOT) + 10 end    -- no room for the profit
  local function w_long() return room_for(LY().CORE_WIDTH) + 10 end                          -- no room for the core
  local function w_huge() return room_for(LY().MINIMAL_WIDTH + LY().LEARN_SLOT) + 2 end     -- room for the × alone
  local function geometry(textWidth)
    return { left = 100, width = 760, itemRight = 400, textLeft = 122, textWidth = textWidth }
  end
  local function show(textWidth, recipeID)
    local raw = P2.raw_order({ orderID = 10, spellID = recipeID or 10 })
    local row = form.newOrderRow(geometry(textWidth))
    form.acquireOrderRow(row, form.orderElement(raw), true)
    board = { raw }
    form.ordersPage:ShowOrders(0, false)
    return rows():GetCells(row)
  end
  local function cross(c)
    return { c.learn:IsShown(), c.learnText:GetText(), { c.learnText:GetTextColor() } }
  end

  it("shows a red × instead of the profit", function()
    boot()
    local c = show(w_short())
    assert.equal("all", c.fit)
    assert.same({ true, CROSS, RED }, cross(c))
    assert.is_false(c.profit:IsShown())
    assert.is_false(c.score:IsShown())                      -- no "?" beside it
    assert.is_true(c.risk:IsShown()); assert.equal("1", c.riskCount:GetText())   -- the red risk count stays
  end)

  it("keeps the × when the profit cell gives way", function()
    boot()
    local c = show(w_medium())
    assert.equal("noProfit", c.fit)
    assert.same({ true, CROSS, RED }, cross(c))
    assert.is_true(c.strip:IsShown()); assert.is_true(c.risk:IsShown())
  end)

  it("keeps the × and the risk count when the core has no room, and gives way only when not even they fit", function()
    boot()
    local c = show(w_long())
    assert.equal("minimal", c.fit)
    assert.is_true(c.strip:IsShown())
    assert.same({ true, CROSS, RED }, cross(c))
    assert.is_true(c.risk:IsShown()); assert.equal("1", c.riskCount:GetText())
    assert.is_false(c.conc:IsShown()); assert.is_false(c.profit:IsShown()); assert.is_false(c.score:IsShown())
  end)

  it("keeps the × alone when not even the risk count and the + fit beside it", function()
    -- Seen in game: "Thalassian Competitor's Mail Links" with its pips left too little for [×] [risk] [+], and the row
    -- showed nothing.
    boot()
    local c = show(w_huge())
    assert.equal("cross", c.fit)
    assert.is_true(c.strip:IsShown())
    assert.same({ true, CROSS, RED }, cross(c))
    assert.is_false(c.risk:IsShown()); assert.is_false(c.add:IsShown())
    assert.is_false(c.conc:IsShown()); assert.is_false(c.profit:IsShown()); assert.is_false(c.score:IsShown())
    local point, relativeTo, relativePoint, x = c.learn:GetPoint(1)
    assert.same({ "RIGHT", c.strip, "RIGHT", 0 }, { point, relativeTo, relativePoint, x })
  end)

  it("gives the risk count back when the name turns out shorter", function()
    boot()
    local c = show(w_huge())
    assert.equal("cross", c.fit)
    local again = show(w_long())
    assert.equal("minimal", again.fit)
    assert.is_true(again.risk:IsShown())
    local _, _, _, x = again.learn:GetPoint(1)
    assert.is_true(x < 0)
  end)

  it("gives way only when not even the × fits", function()
    boot()
    local tight = show(room_for(LY().LEARN_WIDTH) + 2)
    assert.equal("none", tight.fit)
    assert.is_false(tight.strip:IsShown())
  end)

  it("shows no cross-only tier for a recipe you know", function()
    boot()
    unknownRecipe = false
    local c = show(w_huge())
    assert.equal("none", c.fit)
    assert.is_false(c.learn:IsShown())
  end)

  it("the × says the recipe is not learned and where to get it", function()
    boot()
    local c = show(w_short())
    c.learn:GetScript("OnEnter")(c.learn)
    assert.same({ "You have not learned this recipe", "Vendor: Mirvedon" }, tooltip.lines)
    assert.equal(c.learn, tooltip.owner)
    c.learn:GetScript("OnLeave")(c.learn)
    assert.is_false(tooltip.shown)
  end)

  it("shows no × without the risk, and the profit as before", function()
    boot()
    unknownRecipe = false
    local c = show(w_short())
    assert.is_false(c.learn:IsShown())
    assert.is_true(c.profit:IsShown())
    local tight = show(w_medium())
    assert.is_false(tight.learn:IsShown())
    assert.is_true(tight.score:IsShown())
  end)

  it("keeps the info cell of a row with notes when the core has no room", function()
    boot()
    unknownRecipe = false
    -- An estimate gives the row a note (the grey "i") but no risk.
    ns.FS:GetModule("Recipes").Evaluate = function()
      return { expectedQuality = 3, reagentCost = 200000, flags = { estimated = true } }
    end
    local c = show(w_long())
    assert.equal("minimal", c.fit)
    assert.is_true(c.risk:IsShown()); assert.equal("i", c.riskCount:GetText())
    assert.is_false(c.learn:IsShown())
  end)
end)
