local P2 = require("tests.helpers.phase2")

local FILES = { "Modules/Customers.lua", "Data/OrderRewards.lua", "Modules/Orders.lua", "Modules/Ledger.lua",
  "UI/OrdersPanel.lua", "UI/OrdersOptions.lua" }
local QUESTION_MARK = 134400
local RED, WHITE = { 1, 0.25, 0.25 }, { 1, 1, 1 }

-- Reward and reagent icons on the order rows (OrdersRowAddons): which icons an order gets, where they sit beside the
-- item name, what the tooltip says, the setting that turns them off.
describe("OrdersPanel row icons", function()
  local ns, W, form, tooltip, owned, ownedCalls, evalResult, board, cached, requests

  -- Order 10 as the rest of the specs build it: a personal order from Bob, 500000 tip.
  local function order(overrides) return P2.raw_order(P2.merge({ orderID = 10 }, overrides or {})) end
  local function reagent(itemID, quantity)
    return { reagentInfo = { reagent = { itemID = itemID }, quantity = quantity }, source = 1 }
  end
  local function item_reward(itemID, count) return { itemLink = ("|Hitem:%d|h[x]|h"):format(itemID), count = count } end
  local function allocation(...) return { expectedQuality = 3, reagentCost = 200000, flags = {}, allocation = { ... } } end

  local function boot(stubs)
    board, owned, ownedCalls, cached, requests = {}, {}, {}, {}, {}
    evalResult = allocation()
    tooltip = { lines = {} }
    local GameTooltip = {
      SetOwner = function(_, owner) tooltip.owner = owner; tooltip.lines = {} end,
      SetText = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
      AddLine = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
      Show = function() tooltip.shown = true end,
      Hide = function() tooltip.shown = false end,
    }
    ns, W = P2.boot(P2.merge({ GameTooltip = GameTooltip,
      C_CraftingOrders = { GetCrafterOrders = function() return board end, GetCraftingOrderTime = function() return 5000 end },
      C_TradeSkillUI = { GetChildProfessionInfo = function() return { profession = 7 } end },
      C_Item = {
        GetItemInfo = function(id)
          local name = cached[id]
          if name then return name, ("|Hitem:%d|h[%s]|h"):format(id, name) end
        end,
        GetItemIconByID = function(id) if id < 9000 then return 900000 + id end end,
        RequestLoadItemDataByID = function(id) requests[#requests + 1] = id end,
      },
      C_CurrencyInfo = { GetCurrencyInfo = function(id)
        if id == 3001 then return { name = "Resonance Crystals", iconFileID = 700001 } end
      end },
    }, stubs))
    P2.fake_module(ns, "Recipes", { Evaluate = function() return evalResult end, GetRanked = function() return {} end })
    P2.fake_module(ns, "Prices", { Get = function() return {} end })
    P2.fake_module(ns, "Scanner", { GetSchematic = function() return { skillLineID = 2900 } end,
      ProjectConcentration = function() return 500 end,
      GetOwnedCount = function(_, itemID, charKey, includeWarband)
        ownedCalls[#ownedCalls + 1] = { charKey, includeWarband }
        return owned[itemID]
      end })
    P2.fake_module(ns, "Queue", { Add = function() return 1 end, GetEntries = function() return {} end })
    form = fake_professions_frame()
    P2.load(ns, FILES)
    W.fire("ADDON_LOADED", "Blizzard_Professions")
  end

  local function rows() return ns.FS:GetModule("OrdersRowAddons") end
  local function show_board(orders)
    board = orders
    form.ordersPage:ShowOrders(0, false)
  end
  local function row_for(option, geometry)
    local row = form.newOrderRow(geometry)
    form.acquireOrderRow(row, form.orderElement(option), true)
    return row
  end
  -- Row geometry as in orders_panel_spec: the strip's right edge is 294 from the row's left, the name ends at
  -- 22 + textWidth. With the whole strip (132 wide) the icons end 4 px left of it: room = 132 - textWidth.
  local function geometry(textWidth)
    return { left = 100, width = 760, itemRight = 400, textLeft = 122, textWidth = textWidth }
  end
  local function cells_of(row) return rows():GetCells(row) end
  -- The icons that show, in slot order ({ slot index, texture, count text }); the "+N" slot is not one of them.
  local function shown_slots(c)
    local out = {}
    for i, slot in ipairs(c.slots) do
      if slot.icon:IsShown() then out[#out + 1] = { i = i, file = slot.icon:GetTexture(), count = slot.count:IsShown() and slot.count:GetText() or nil } end
    end
    return out
  end
  local function files_of(c)
    local out = {}
    for i, s in ipairs(shown_slots(c)) do out[i] = s.file end
    return out
  end
  local function count_color(slot) return { slot.count:GetTextColor() } end

  after_each(function() fake_professions_frame.reset() end)

  describe("which icons an order gets", function()
    it("shows the rewards in order with their counts: items and currencies", function()
      boot()
      local raw = order({ orderType = 3, npcOrderRewards = { item_reward(2001, 3), { currencyType = 3001, count = 1 },
        item_reward(2002, 1) } })
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.same({ { i = 1, file = 902001, count = "3" }, { i = 2, file = 700001, count = nil },
        { i = 3, file = 902002, count = nil } }, shown_slots(c))
      assert.is_true(c.icons:IsShown())
      assert.same({ "reward", "reward", "reward" }, { c.iconEntries[1].kind, c.iconEntries[2].kind, c.iconEntries[3].kind })
    end)
    it("falls back to the question mark for a missing icon, never an error", function()
      boot()
      local raw = order({ orderType = 3, npcOrderRewards = { item_reward(9999, 1), { currencyType = 3999, count = 2 } } })
      show_board({ raw })
      assert.same({ { i = 1, file = QUESTION_MARK, count = nil }, { i = 2, file = QUESTION_MARK, count = "2" } },
        shown_slots(cells_of(row_for(raw))))
      assert.is_true(rows():IsEnabled())
    end)
    it("uses GetItemIcon when C_Item.GetItemIconByID is missing, and the question mark when neither answers", function()
      boot({ C_Item = { GetItemIconByID = P2.NIL }, GetItemIcon = function(id) if id == 2001 then return 555 end end })
      local raw = order({ orderType = 3, npcOrderRewards = { item_reward(2001, 1), item_reward(2002, 1) } })
      show_board({ raw })
      assert.same({ 555, QUESTION_MARK }, files_of(cells_of(row_for(raw))))
      boot({ C_Item = { GetItemIconByID = P2.NIL } })
      show_board({ raw })
      assert.same({ QUESTION_MARK, QUESTION_MARK }, files_of(cells_of(row_for(raw))))
    end)
    it("shows the reagents you must supply: the allocation summed by itemID minus what the customer provides", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 }, { itemID = 1002, quantity = 4 },
        { itemID = 1001, quantity = 2 }, { itemID = 1003, quantity = 5 })
      local raw = order({ reagents = { reagent(1001, 2), reagent(1003, 7) } })   -- 1003 fully provided (7 > 5)
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.same({ { i = 1, file = 901001, count = "3" }, { i = 2, file = 901002, count = "4" } }, shown_slots(c))
      assert.same({ "reagent", "reagent" }, { c.iconEntries[1].kind, c.iconEntries[2].kind })
    end)
    it("colours a reagent count red when you own less than it needs, white otherwise or when unknown", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 }, { itemID = 1002, quantity = 4 }, { itemID = 1003, quantity = 2 },
        { itemID = 1004, quantity = 1 })
      owned[1001], owned[1002], owned[1003] = 2, 4, 0   -- short, exactly enough, none at all; 1004 unknown (nil)
      local raw = order()
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.same({ RED, WHITE, RED, WHITE }, { count_color(c.slots[1]), count_color(c.slots[2]), count_color(c.slots[3]),
        count_color(c.slots[4]) })
      assert.same({ 2, 4, 0 }, { c.iconEntries[1].have, c.iconEntries[2].have, c.iconEntries[3].have })
      assert.is_nil(c.iconEntries[4].have)
      -- the logged-in character's count, the warband bank included
      assert.is_true(#ownedCalls > 0)
      for _, call in ipairs(ownedCalls) do assert.same({ nil, true }, { call[1], call[2] }) end
    end)
    it("treats an unreadable owned count as unknown, not as none", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      ns.FS:GetModule("Scanner").GetOwnedCount = function() error("boom") end
      local raw = order()
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.is_nil(c.iconEntries[1].have); assert.same(WHITE, count_color(c.slots[1]))
      assert.is_true(rows():IsEnabled())
    end)
    it("is white and unknown without a Scanner", function()
      boot()
      ns.FS:GetModule("Scanner").GetOwnedCount = nil
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      local raw = order()
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.is_nil(c.iconEntries[1].have); assert.same(WHITE, count_color(c.slots[1]))
    end)
    it("shows rewards first, then reagents, with a small gap between", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      local raw = order({ orderType = 3, npcOrderRewards = { item_reward(2001, 1), { currencyType = 3001, count = 5 } } })
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.same({ 902001, 700001, 901001 }, files_of(c))
      -- 14 px icons, 1 px apart, a 4 px gap between the rewards and the reagents
      local function x(i) local _, _, _, px = c.slots[i].icon:GetPoint(1); return px end
      assert.same({ 0, 15, 34 }, { x(1), x(2), x(3) })
      assert.same({ 14, 14 }, { c.slots[1].icon:GetSize() })
      assert.equal(48, c.icons:GetWidth())
    end)
    it("gives a recraft and an order that provides everything no reagent icons", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      local recraft, provided = order({ orderID = 11, isRecraft = true }), order({ orderID = 12, reagents = { reagent(1001, 3) } })
      show_board({ recraft, provided })
      for _, raw in ipairs({ recraft, provided }) do
        local c = cells_of(row_for(raw))
        assert.same({}, c.iconEntries); assert.is_false(c.icons:IsShown())
        assert.is_true(c.frame:IsShown())
      end
    end)
    it("gives an order without a result (the recipe is not known) no reagent icons, but keeps its rewards", function()
      boot()
      evalResult = nil
      local raw = order({ orderType = 3, npcOrderRewards = { item_reward(2001, 1) } })
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.same({ "reward" }, { c.iconEntries[1].kind }); assert.equal(1, #c.iconEntries)
    end)
    it("shows a reward-only order with no group gap", function()
      boot()
      local raw = order({ orderType = 3, npcOrderRewards = { item_reward(2001, 2) } })
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.same({ { i = 1, file = 902001, count = "2" } }, shown_slots(c))
      assert.equal(14, c.icons:GetWidth())
    end)
  end)

  describe("fitting beside the item name", function()
    -- Two rewards and three reagents: five icons need 78 px (15 per icon less 1, plus the 4 px group gap).
    local function five(textWidth)
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 1 }, { itemID = 1002, quantity = 1 }, { itemID = 1003, quantity = 1 })
      local raw = order({ orderType = 3, npcOrderRewards = { item_reward(2001, 1), item_reward(2002, 1) } })
      show_board({ raw })
      local row = row_for(raw, geometry(textWidth))
      return cells_of(row), row
    end
    local function state(c)
      return { c.fit, c.icons:IsShown(), #shown_slots(c), c.more:IsShown() and c.more:GetText() or nil }
    end

    it("shows every icon when they all fit", function()
      local c = five(50)   -- room 82
      assert.same({ "all", true, 5, nil }, state(c))
      assert.equal(78, c.icons:GetWidth())
    end)
    it("shows as many as fit and turns the last slot into +N", function()
      local c = five(80)   -- room 52: 3 slots; 2 icons + "+3"
      assert.same({ "all", true, 2, "+3" }, state(c))
      assert.equal(48, c.icons:GetWidth())
      assert.same({ "LEFT", c.icons, "LEFT", 34, 0 }, { c.more:GetPoint(1) })   -- in the third slot, after the group gap
      assert.same({ "all", true, 3, "+2" }, state(five(60)))   -- room 72: 4 slots
    end)
    it("shows only +N when one slot fits, and hides the icons when none does", function()
      assert.same({ "noProfit", true, 1, "+4" }, state(five(140)))   -- no profit cell: room 38 -> 2 slots
      assert.same({ "noProfit", true, 0, "+5" }, state(five(150)))   -- room 28 -> 1 slot
      assert.same({ "all", false, 0, nil }, state(five(125)))   -- room 7: not even one
    end)
    it("hides the icons with the main strip", function()
      local c = five(200)
      assert.same({ "none", false, 0, nil }, state(c))
      assert.is_true(c.frame:IsShown())   -- the row tint and dimming stay
    end)
    it("sits left of the visible cells and moves with the profit cell", function()
      local c, row = five(50)
      assert.same({ "RIGHT", row, "RIGHT", -(460 + 6 + 132 + 4), 0 }, { c.icons:GetPoint(1) })
      local c2, row2 = five(140)   -- without the profit cell
      assert.same({ "RIGHT", row2, "RIGHT", -(460 + 6 + 86 + 4), 0 }, { c2.icons:GetPoint(1) })
    end)
    it("leaves room for the blocked warning icon too", function()
      boot()
      ns.FS:GetModule("Customers"):SetTag("Bob-Silvermoon", "blocked", true)
      evalResult = allocation({ itemID = 1001, quantity = 1 })
      local raw = order()
      show_board({ raw })
      local row = row_for(raw, geometry(50))
      local c = cells_of(row)
      assert.is_true(c.warnShown)
      assert.same({ "RIGHT", row, "RIGHT", -(460 + 6 + 132 + 16 + 4), 0 }, { c.icons:GetPoint(1) })
    end)
    it("shows everything on a row that cannot be measured", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 1 }, { itemID = 1002, quantity = 1 }, { itemID = 1003, quantity = 1 },
        { itemID = 1004, quantity = 1 }, { itemID = 1005, quantity = 1 })
      local raw = order()
      show_board({ raw })
      local row = row_for(raw)
      local c = cells_of(row)
      assert.same({ "all", true, 5, nil }, state(c))
      assert.same({ "RIGHT", row, "RIGHT", -(470 + 6 + 132 + 4), 0 }, { c.icons:GetPoint(1) })
    end)
    it("re-fits the icons with the strip when Blizzard writes the name after our callback", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 1 }, { itemID = 1002, quantity = 1 }, { itemID = 1003, quantity = 1 })
      local raw = order()
      show_board({ raw })
      local g = geometry(50)
      local row = form.newOrderRow(g)
      form.acquireOrderRow(row, form.orderElement(raw), true)
      local c = cells_of(row)
      assert.same({ 3, false }, { #shown_slots(c), c.more:IsShown() })   -- 3 icons: 44 <= room 82
      g.textWidth = 110   -- room 22: one slot, so only "+3"
      W.advance(0)
      assert.same({ 0, true, "+3" }, { #shown_slots(c), c.more:IsShown(), c.more:GetText() })
      g.textWidth = 50
      W.fire("GET_ITEM_INFO_RECEIVED", 1001, true)
      W.advance(0)
      assert.same({ 3, false }, { #shown_slots(c), c.more:IsShown() })
      assert.same({}, form.assignedFields)
    end)
  end)

  describe("tooltip", function()
    it("lists the rewards and the reagents to supply as whole-sentence lines", function()
      boot()
      cached[2001], cached[1001], cached[1002] = "Sword", "Ore", "Silk"
      evalResult = allocation({ itemID = 1001, quantity = 3 }, { itemID = 1002, quantity = 4 })
      owned[1001] = 2
      local raw = order({ orderType = 3, npcOrderRewards = { item_reward(2001, 3), { currencyType = 3001, count = 1 } } })
      show_board({ raw })
      local c = cells_of(row_for(raw))
      c.icons:GetScript("OnEnter")(c.icons)
      assert.same({ "Rewards", "|T902001:14|t |Hitem:2001|h[Sword]|h x3", "|T700001:14|t Resonance Crystals x1",
        "Reagents to supply", "|Hitem:1001|h[Ore]|h: need 3, have 2", "|Hitem:1002|h[Silk]|h: need 4" }, tooltip.lines)
      assert.is_true(tooltip.shown); assert.equal(c.icons, tooltip.owner)
      c.icons:GetScript("OnLeave")(c.icons)
      assert.is_false(tooltip.shown)
    end)
    it("starts with the reagent header when there are no rewards, and lists icons the strip had no room for", function()
      boot()
      cached[1001] = "Ore"
      evalResult = allocation({ itemID = 1001, quantity = 3 }, { itemID = 1002, quantity = 1 })
      local raw = order()
      show_board({ raw })
      local none = cells_of(row_for(raw, geometry(125)))   -- no room for any icon
      assert.is_false(none.icons:IsShown())
      local c = cells_of(row_for(raw, geometry(110)))   -- room 22: only "+2"
      assert.same({ 0, "+2" }, { #shown_slots(c), c.more:GetText() })
      c.icons:GetScript("OnEnter")(c.icons)
      assert.same({ "Reagents to supply", "|Hitem:1001|h[Ore]|h: need 3", "item:1002: need 1" }, tooltip.lines)
    end)
    it("shows an uncached item as item:<id>, asks for its data and refreshes when it arrives", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      local raw = order()
      show_board({ raw })
      local c = cells_of(row_for(raw))
      c.icons:GetScript("OnEnter")(c.icons)
      assert.same({ "Reagents to supply", "item:1001: need 3" }, tooltip.lines)
      assert.same({ 1001 }, requests)
      c.icons:GetScript("OnEnter")(c.icons)
      assert.same({ 1001 }, requests)   -- asked once
      cached[1001] = "Ore"
      W.fire("GET_ITEM_INFO_RECEIVED", 1001, true)
      W.advance(0)
      assert.same({ "Reagents to supply", "|Hitem:1001|h[Ore]|h: need 3" }, tooltip.lines)
      c.icons:GetScript("OnLeave")(c.icons)
      tooltip.lines = {}
      W.fire("GET_ITEM_INFO_RECEIVED", 1001, true)
      W.advance(0)
      assert.same({}, tooltip.lines)   -- not hovering: the tooltip is left alone
    end)
    it("turns off only OrdersRowAddons when the tooltip fails", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      local raw = order()
      show_board({ raw })
      local c = cells_of(row_for(raw))
      _G.GameTooltip = { SetOwner = function() error("boom") end, Hide = function() end }
      c.icons:GetScript("OnEnter")(c.icons)
      assert.is_false(rows():IsEnabled())
      assert.is_true(ns.FS:GetModule("OrdersSidePanel"):IsEnabled())
      local errs = ns.FS.db.global.diagnostics.errors
      assert.equal("OrdersRowAddons", errs[#errs].source)
    end)
  end)

  describe("the setting", function()
    local function options() return ns.UI.OrdersOptions.Build().args.panel.args.rowIcons end
    local function rewards_order()
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      return order({ orderType = 3, npcOrderRewards = { item_reward(2001, 2) } })
    end

    it("is on by default and offered in Settings > Orders", function()
      boot()
      local opt = options()
      assert.equal("toggle", opt.type)
      assert.equal("Show reward and reagent icons on order rows", opt.name)
      assert.is_true(ns.FS:GetModule("Orders").SETTINGS_DEFAULTS.showRowIcons)
      assert.is_true(ns.FS:GetModule("Orders"):Settings().showRowIcons)
      assert.is_true(opt.get())
    end)
    it("hides the icons on the rows on screen as soon as it is turned off, and shows them again", function()
      boot()
      local raw = rewards_order()
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.is_true(c.icons:IsShown())
      options().set(nil, false)
      assert.is_false(ns.FS:GetModule("Orders"):Settings().showRowIcons)
      assert.is_false(c.icons:IsShown()); assert.same({}, c.iconEntries)
      assert.is_true(c.strip:IsShown())   -- the cells stay
      options().set(nil, true)
      assert.is_true(c.icons:IsShown()); assert.equal(2, #c.iconEntries)
    end)
    it("keeps a new row's icons off while it is off", function()
      boot()
      local raw = rewards_order()
      ns.FS:GetModule("Orders"):Settings().showRowIcons = false
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.is_false(c.icons:IsShown()); assert.is_true(c.frame:IsShown())
    end)
    it("is not written while the saved data is from a newer version", function()
      boot()
      ns.FS.dbIsNewer = true
      assert.is_true(options().disabled())
      options().set(nil, false)
      local saved = ns.FS.db.global.settings.orders
      assert.is_true(saved == nil or saved.showRowIcons ~= false)
    end)
    it("is filled in as true when the saved value is missing or not a boolean", function()
      boot()
      local orders = ns.FS:GetModule("Orders")
      orders:Settings().showRowIcons = "no"
      assert.is_true(orders:Settings().showRowIcons)
      orders:Settings().showRowIcons = nil
      assert.is_true(orders:Settings().showRowIcons)
    end)
  end)

  describe("dimming and recycling", function()
    it("gives the icon strip the strip's alpha: 0.6 on a dimmed row", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      local raw = order({ expirationTime = 5100 })   -- expires in 100 s
      local row = row_for(raw)
      show_board({ raw })
      local c = cells_of(row)
      assert.same({ 1, 1 }, { c.strip:GetAlpha(), c.icons:GetAlpha() })
      ns.FS:GetModule("Orders"):Settings().filters.hideRisks.expiringSoon = true
      ns.FS:SendMessage("FS_ORDERS_CHANGED")
      assert.is_true(c.dimmed)
      assert.same({ 0.6, 0.6 }, { c.strip:GetAlpha(), c.icons:GetAlpha() })
    end)
    it("shows a recycled row's new order's icons only", function()
      boot()
      local first = order({ orderID = 10, orderType = 3, npcOrderRewards = { item_reward(2001, 2), item_reward(2002, 1) } })
      local second = order({ orderID = 11, orderType = 3, npcOrderRewards = { { currencyType = 3001, count = 4 } } })
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      show_board({ first, second })
      local row = form.newOrderRow(geometry(50))
      form.acquireOrderRow(row, form.orderElement(first), true)
      local c = cells_of(row)
      assert.equal(3, #shown_slots(c))
      form.releaseOrderRow(row)
      assert.is_false(c.frame:IsShown())
      form.acquireOrderRow(row, form.orderElement(second), false)
      assert.same({ { i = 1, file = 700001, count = "4" }, { i = 2, file = 901001, count = "3" } }, shown_slots(c))
      assert.is_false(c.more:IsShown())
      assert.equal(2, #c.iconEntries)
      -- a count shown for the last order is gone when the next one needs none
      local third = order({ orderID = 12, orderType = 3, npcOrderRewards = { item_reward(2002, 1) } })
      evalResult = allocation()
      show_board({ first, second, third })
      form.releaseOrderRow(row)
      form.acquireOrderRow(row, form.orderElement(third), false)
      assert.same({ { i = 1, file = 902002, count = nil } }, shown_slots(c))
      assert.equal("", c.slots[1].count:GetText())
      assert.same({}, form.assignedFields)
    end)
    it("pools the icon textures: a row reuses its slots", function()
      boot()
      local first = order({ orderID = 10, orderType = 3, npcOrderRewards = { item_reward(2001, 2), item_reward(2002, 1) } })
      local second = order({ orderID = 11, orderType = 3, npcOrderRewards = { item_reward(2001, 1) } })
      show_board({ first, second })
      local row = row_for(first)
      local c = cells_of(row)
      local one, two = c.slots[1].icon, c.slots[2].icon
      form.releaseOrderRow(row)
      form.acquireOrderRow(row, form.orderElement(second), false)
      assert.same({ true, true, 2 }, { c.slots[1].icon == one, c.slots[2].icon == two, #c.slots })
      assert.is_true(one:IsShown()); assert.is_false(two:IsShown())
    end)
    it("hides the icons with the cells when the order list shows buckets", function()
      boot()
      local raw = order({ orderType = 3, npcOrderRewards = { item_reward(2001, 2) } })
      show_board({ raw })
      local c = cells_of(row_for(raw))
      form.ordersPage:ShowBuckets(0, false)
      assert.is_false(c.frame:IsShown())
    end)
  end)

  describe("pure helpers", function()
    it("IconEntries needs a table view", function()
      boot()
      local P = ns.UI.OrdersPanel
      assert.same({}, P.IconEntries(nil)); assert.same({}, P.IconEntries({}))
      assert.same({}, P.IconEntries({ rewards = "x", result = { allocation = "y" } }))
    end)
    it("IconEntries takes the customer-provided counts from the order input", function()
      boot()
      local P = ns.UI.OrdersPanel
      local view = { result = { allocation = { { itemID = 5, quantity = 4 } } }, input = { provided = { [5] = 1 } } }
      assert.same({ { kind = "reagent", itemID = 5, count = 3, have = 9 } }, P.IconEntries(view, function() return 9 end))
    end)
    it("IconLayout counts the slots that fit", function()
      boot()
      local P = ns.UI.OrdersPanel
      local entries = { { kind = "reward" }, { kind = "reagent" }, { kind = "reagent" } }
      assert.same({ shown = 3, width = 48 }, P.IconLayout(entries, nil))
      assert.same({ shown = 3, width = 48 }, P.IconLayout(entries, 48))
      assert.same({ shown = 1, more = 2, width = 33 }, P.IconLayout(entries, 47))   -- 2 slots: 1 icon + "+2"
      assert.same({ shown = 0, more = 3, width = 14 }, P.IconLayout(entries, 14))
      assert.same({ shown = 0, width = 0 }, P.IconLayout(entries, 13))
      assert.same({ shown = 0, width = 0 }, P.IconLayout({}, 100))
    end)
  end)
end)
