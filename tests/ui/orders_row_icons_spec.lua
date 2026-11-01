local P2 = require("tests.helpers.phase2")

local FILES = { "Modules/Customers.lua", "Data/OrderRewards.lua", "Modules/Orders.lua", "Modules/Ledger.lua",
  "UI/OrdersPanel.lua", "UI/OrdersOptions.lua" }
local QUESTION_MARK = 134400
local RED, WHITE = { 1, 0.25, 0.25 }, { 1, 1, 1 }

-- Order rows (OrdersRowAddons): a strip of reward icons in the item-name column, and a cover over Blizzard's Reagents
-- cell that shows the reagents the crafter must supply (a check when the customer provides them all, "?" when they
-- are unknown). Which icons an order gets, where they sit, what the tooltips say, the setting that turns them off.
describe("OrdersPanel row icons", function()
  local ns, W, form, tooltip, owned, ownedCalls, evalResult, board, cached, requests

  -- Order 10 as the rest of the specs build it: a personal order from Bob, 500000 tip.
  local function order(overrides) return P2.raw_order(P2.merge({ orderID = 10 }, overrides or {})) end
  local function reagent(itemID, quantity)
    return { reagentInfo = { reagent = { itemID = itemID }, quantity = quantity }, source = 1 }
  end
  local function item_reward(itemID, count) return { itemLink = ("|Hitem:%d|h[x]|h"):format(itemID), count = count } end
  local function allocation(...) return { expectedQuality = 3, reagentCost = 200000, flags = {}, allocation = { ... } } end
  local function slots_needed(n)
    local list = {}
    for i = 1, n do list[i] = { itemID = 1000 + i, quantity = 1 } end
    return allocation(unpack(list))
  end

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
      -- The game's own count (nil: it cannot answer); the snapshot-backed GetOwnedCount must not be used.
      GetLiveOwnedCount = function(_, itemID, includeWarband)
        ownedCalls[#ownedCalls + 1] = { itemID, includeWarband }
        return owned[itemID]
      end,
      GetOwnedCount = function() return 0 end })
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
  -- Row geometry as in orders_panel_spec: the row spans 100..860, the strip's right edge is 294 from the row's left,
  -- the name ends at 22 + textWidth. With the whole strip (132 wide) the reward icons end 4 px left of it: room =
  -- 132 - textWidth. The Reagents cell is the 90 px before the last 60.
  local function geometry(textWidth)
    return { left = 100, width = 760, itemRight = 400, textLeft = 122, textWidth = textWidth,
      reagentsLeft = 710, reagentsRight = 800 }
  end
  local function cells_of(row) return rows():GetCells(row) end
  -- The icons that show in a slot pool, in order ({ slot index, texture, count text }); the "+N" slot is not one.
  local function shown(pool)
    local out = {}
    for i, slot in ipairs(pool) do
      if slot.icon:IsShown() then out[#out + 1] = { i = i, file = slot.icon:GetTexture(), count = slot.count:IsShown() and slot.count:GetText() or nil } end
    end
    return out
  end
  local function files_of(pool)
    local out = {}
    for i, s in ipairs(shown(pool)) do out[i] = s.file end
    return out
  end
  local function count_color(slot) return { slot.count:GetTextColor() } end

  after_each(function() fake_professions_frame.reset() end)

  describe("reward icons in the name column", function()
    it("shows the rewards in order with their counts: items and currencies", function()
      boot()
      local raw = order({ orderType = 3, npcOrderRewards = { item_reward(2001, 3), { currencyType = 3001, count = 1 },
        item_reward(2002, 1) } })
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.same({ { i = 1, file = 902001, count = "3" }, { i = 2, file = 700001, count = nil },
        { i = 3, file = 902002, count = nil } }, shown(c.slots))
      assert.is_true(c.icons:IsShown())
      assert.same({ "reward", "reward", "reward" }, { c.iconEntries[1].kind, c.iconEntries[2].kind, c.iconEntries[3].kind })
    end)
    it("holds the rewards only: the reagents go to the Reagents cover", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      local raw = order({ orderType = 3, npcOrderRewards = { item_reward(2001, 2) } })
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.equal(1, #c.iconEntries); assert.equal(1, #shown(c.slots))
      assert.equal(14, c.icons:GetWidth())
      assert.same({ 901001 }, files_of(c.coverSlots))
    end)
    it("has no strip for an order without rewards", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      local raw = order()
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.same({}, c.iconEntries); assert.is_false(c.icons:IsShown())
    end)
    it("falls back to the question mark for a missing icon, never an error", function()
      boot()
      local raw = order({ orderType = 3, npcOrderRewards = { item_reward(9999, 1), { currencyType = 3999, count = 2 } } })
      show_board({ raw })
      assert.same({ { i = 1, file = QUESTION_MARK, count = nil }, { i = 2, file = QUESTION_MARK, count = "2" } },
        shown(cells_of(row_for(raw)).slots))
      assert.is_true(rows():IsEnabled())
    end)
    it("uses GetItemIcon when C_Item.GetItemIconByID is missing, and the question mark when neither answers", function()
      boot({ C_Item = { GetItemIconByID = P2.NIL }, GetItemIcon = function(id) if id == 2001 then return 555 end end })
      local raw = order({ orderType = 3, npcOrderRewards = { item_reward(2001, 1), item_reward(2002, 1) } })
      show_board({ raw })
      assert.same({ 555, QUESTION_MARK }, files_of(cells_of(row_for(raw)).slots))
      boot({ C_Item = { GetItemIconByID = P2.NIL } })
      show_board({ raw })
      assert.same({ QUESTION_MARK, QUESTION_MARK }, files_of(cells_of(row_for(raw)).slots))
    end)
  end)

  describe("fitting the reward icons beside the item name", function()
    -- Five rewards: five icons need 74 px (15 per icon less 1); a "+N" slot is 22 px wide.
    local function five(textWidth)
      boot()
      local rewards = {}
      for i = 1, 5 do rewards[i] = item_reward(2000 + i, 1) end
      local raw = order({ orderType = 3, npcOrderRewards = rewards })
      show_board({ raw })
      local row = row_for(raw, geometry(textWidth))
      return cells_of(row), row
    end
    local function state(c)
      return { c.fit, c.icons:IsShown(), #shown(c.slots), c.more:IsShown() and c.more:GetText() or nil }
    end

    it("shows every icon when they all fit", function()
      local c = five(50)   -- room 82
      assert.same({ "all", true, 5, nil }, state(c))
      assert.equal(74, c.icons:GetWidth())
    end)
    it("shows as many as fit and turns the last slot into +N", function()
      local c = five(80)   -- room 52: 2 icons and a 22 px "+3"
      assert.same({ "all", true, 2, "+3" }, state(c))
      assert.equal(52, c.icons:GetWidth())
      assert.same({ "LEFT", c.icons, "LEFT", 30, 0 }, { c.more:GetPoint(1) })
      assert.same({ "all", true, 3, "+2" }, state(five(60)))   -- room 72: 3 icons and "+2"
    end)
    it("gives +N a width of its own, so it cannot run into the cells", function()
      local c = five(80)
      assert.equal(22, c.more:GetWidth()); assert.is_false(c.more:GetWordWrap())
      assert.is_true(c.icons.clips)
    end)
    it("shows only +N when one slot fits, and hides the icons when none does", function()
      assert.same({ "noProfit", true, 1, "+4" }, state(five(140)))   -- no profit cell: room 38
      assert.same({ "noProfit", true, 0, "+5" }, state(five(150)))   -- room 28
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
      local raw = order({ orderType = 2, npcOrderRewards = { item_reward(2001, 1) } })
      show_board({ raw })
      local row = row_for(raw, geometry(50))
      local c = cells_of(row)
      assert.is_true(c.warnShown)
      assert.same({ "RIGHT", row, "RIGHT", -(460 + 6 + 132 + 16 + 4), 0 }, { c.icons:GetPoint(1) })
    end)
    it("shows everything on a row that cannot be measured", function()
      boot()
      local rewards = {}
      for i = 1, 7 do rewards[i] = item_reward(2000 + i, 1) end
      local raw = order({ orderType = 3, npcOrderRewards = rewards })
      show_board({ raw })
      local row = row_for(raw)
      local c = cells_of(row)
      assert.same({ "all", true, 7, nil }, state(c))
      assert.same({ "RIGHT", row, "RIGHT", -(470 + 6 + 132 + 4), 0 }, { c.icons:GetPoint(1) })
    end)
    it("re-fits the icons with the strip when Blizzard writes the name after our callback", function()
      boot()
      local raw = order({ orderType = 3, npcOrderRewards = { item_reward(2001, 1), item_reward(2002, 1), item_reward(2003, 1) } })
      show_board({ raw })
      local g = geometry(50)
      local row = form.newOrderRow(g)
      form.acquireOrderRow(row, form.orderElement(raw), true)
      local c = cells_of(row)
      assert.same({ 3, false }, { #shown(c.slots), c.more:IsShown() })   -- 3 icons: 44 <= room 82
      g.textWidth = 110   -- room 22: one slot, so only "+3"
      W.advance(0)
      assert.same({ 0, true, "+3" }, { #shown(c.slots), c.more:IsShown(), c.more:GetText() })
      g.textWidth = 50
      W.fire("GET_ITEM_INFO_RECEIVED", 1001, true)
      W.advance(0)
      assert.same({ 3, false }, { #shown(c.slots), c.more:IsShown() })
      assert.same({}, form.assignedFields)
    end)
  end)

  describe("the Reagents cover: which reagents", function()
    it("shows the reagents you must supply: the allocation summed by itemID minus what the customer provides", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 }, { itemID = 1002, quantity = 4 },
        { itemID = 1001, quantity = 2 }, { itemID = 1003, quantity = 5 })
      local raw = order({ reagents = { reagent(1001, 2), reagent(1003, 7) } })   -- 1003 fully provided (7 > 5)
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.equal("reagents", c.coverMode); assert.is_true(c.cover:IsShown())
      assert.same({ { i = 1, file = 901001, count = "3" }, { i = 2, file = 901002, count = "4" } }, shown(c.coverSlots))
      assert.same({ "reagent", "reagent" }, { c.reagentEntries[1].kind, c.reagentEntries[2].kind })
      assert.is_false(c.coverCheck:IsShown()); assert.is_false(c.coverQuestion:IsShown())
    end)
    it("draws the icons left-aligned with a small padding, 14 px with a 1 px gap", function()
      boot()
      evalResult = slots_needed(3)
      local raw = order()
      show_board({ raw })
      local c = cells_of(row_for(raw))
      local function x(i) local _, _, _, px = c.coverSlots[i].icon:GetPoint(1); return px end
      assert.same({ 4, 19, 34 }, { x(1), x(2), x(3) })
      assert.same({ "LEFT", c.cover, "LEFT", 4, 0 }, { c.coverSlots[1].icon:GetPoint(1) })
      assert.same({ 14, 14 }, { c.coverSlots[1].icon:GetSize() })
    end)
    it("colours a count red when you own less than it needs, white otherwise or when unknown", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 }, { itemID = 1002, quantity = 4 }, { itemID = 1003, quantity = 2 },
        { itemID = 1004, quantity = 1 })
      owned[1001], owned[1002], owned[1003] = 2, 4, 0   -- short, exactly enough, none at all; 1004 unknown (nil)
      local raw = order()
      show_board({ raw })
      local c = cells_of(row_for(raw))
      local s = c.coverSlots
      assert.same({ RED, WHITE, RED, WHITE }, { count_color(s[1]), count_color(s[2]), count_color(s[3]), count_color(s[4]) })
      assert.same({ 2, 4, 0 }, { c.reagentEntries[1].have, c.reagentEntries[2].have, c.reagentEntries[3].have })
      assert.is_nil(c.reagentEntries[4].have)
      -- the logged-in character's count from the game, the warband bank included
      assert.is_true(#ownedCalls > 0)
      for _, call in ipairs(ownedCalls) do assert.is_true(call[2]) end
    end)
    it("shows an owned count the game cannot give as unknown (white), not as the snapshot's 0", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      local raw = order()
      show_board({ raw })
      local c = cells_of(row_for(raw))   -- the fake GetOwnedCount would answer 0; GetLiveOwnedCount answers nil
      assert.is_nil(c.reagentEntries[1].have); assert.same(WHITE, count_color(c.coverSlots[1]))
    end)
    it("treats an unreadable owned count as unknown, and a missing Scanner too", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      ns.FS:GetModule("Scanner").GetLiveOwnedCount = function() error("boom") end
      local raw = order()
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.is_nil(c.reagentEntries[1].have); assert.same(WHITE, count_color(c.coverSlots[1]))
      assert.is_true(rows():IsEnabled())
      ns.FS:GetModule("Scanner").GetLiveOwnedCount = nil
      show_board({ raw })
      c = cells_of(row_for(raw))
      assert.is_nil(c.reagentEntries[1].have)
    end)
    it("shows +N in a slot of its own when the reagents do not fit the 90 px column", function()
      boot()
      evalResult = slots_needed(7)
      local raw = order()
      show_board({ raw })
      local c = cells_of(row_for(raw, geometry(50)))
      assert.equal(4, #shown(c.coverSlots))   -- room 82: 4 icons (59) and a 22 px "+3"
      assert.same({ true, "+3", 22 }, { c.coverMore:IsShown(), c.coverMore:GetText(), c.coverMore:GetWidth() })
      assert.same({ "LEFT", c.cover, "LEFT", 4 + 60, 0 }, { c.coverMore:GetPoint(1) })
      assert.is_true(c.cover.clips)
    end)
  end)

  describe("the Reagents cover: when there is one", function()
    it("shows a green check when the customer provides every reagent", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      local raw = order({ reagents = { reagent(1001, 3) } })
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.equal("provided", c.coverMode); assert.is_true(c.cover:IsShown())
      assert.same({ true, false, 0 }, { c.coverCheck:IsShown(), c.coverQuestion:IsShown(), #shown(c.coverSlots) })
      assert.same({}, c.reagentEntries)
    end)
    it("shows a check for a recipe that needs no reagents at all", function()
      boot()
      evalResult = allocation()
      local raw = order()
      show_board({ raw })
      assert.equal("provided", cells_of(row_for(raw)).coverMode)
    end)
    it("shows ? for a recraft", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      local raw = order({ isRecraft = true })
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.equal("unsure", c.coverMode); assert.is_true(c.cover:IsShown())
      assert.same({ false, true, "?" }, { c.coverCheck:IsShown(), c.coverQuestion:IsShown(), c.coverQuestion:GetText() })
    end)
    it("shows ? for an order without a result (the recipe is not known), and keeps its rewards", function()
      boot()
      evalResult = nil
      local raw = order({ orderType = 3, npcOrderRewards = { item_reward(2001, 1) } })
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.equal("unsure", c.coverMode)
      assert.equal(1, #c.iconEntries)
    end)
    it("has no cover on a row without an FS view: Blizzard's text stays", function()
      boot()
      local raw = order()
      local row = row_for(raw)   -- the board was never captured: no view
      assert.is_true(cells_of(row) == nil)
      show_board({ raw })
      assert.is_true(cells_of(row).cover:IsShown())
      ns.FS:SetModuleEnabled("Orders", false)   -- orders off: no views shown
      W.advance(1)
      form.acquireOrderRow(row, form.orderElement(raw), false)
      local c = cells_of(row)
      assert.is_false(c.frame:IsShown()); assert.is_false(c.cover:IsShown()); assert.is_false(c.icons:IsShown())
      ns.FS:SetModuleEnabled("Orders", true)
      local bucket = form.newOrderRow()
      form.acquireOrderRow(bucket, form.orderElement({ spellID = 4444, numAvailable = 3 }, "bucketed"))
      assert.is_true(cells_of(bucket) == nil)
    end)
    it("hides the cover with the cells when the order list shows buckets or the module turns off", function()
      boot()
      local raw = order()
      show_board({ raw })
      local c = cells_of(row_for(raw))
      form.ordersPage:ShowBuckets(0, false)
      assert.is_false(c.cover:IsShown())
      form.ordersPage:ShowOrders(0, false)
      assert.is_true(c.cover:IsShown())
      ns.FS:SetModuleEnabled("OrdersRowAddons", false)
      assert.is_false(c.cover:IsShown())
    end)
  end)

  describe("the Reagents cover: position", function()
    it("covers the row's Reagents cell, measured read-only", function()
      boot()
      local raw = order()
      show_board({ raw })
      local row = row_for(raw, geometry(50))
      local c = cells_of(row)
      assert.same({ { "TOPRIGHT", row, "TOPRIGHT", -60, 0 }, { "BOTTOMRIGHT", row, "BOTTOMRIGHT", -60, 0 }, 90 },
        { { c.cover:GetPoint(1) }, { c.cover:GetPoint(2) }, c.cover:GetWidth() })
      assert.same({}, form.assignedFields)
    end)
    it("takes the column header's span when the row's cell cannot be read", function()
      boot()
      local raw = order()
      show_board({ raw })
      local g = geometry(50)
      g.reagentsLeft = nil
      local header = function(left, right)
        return { GetLeft = function() return left end, GetRight = function() return right end }
      end
      local headers = { header(0, 1), header(1, 2), header(2, 3), header(720, 810), header(810, 860) }
      form.raw(form.orderList).HeaderContainer.GetChildren = function() return unpack(headers) end
      local row = row_for(raw, g)
      local c = cells_of(row)
      assert.same({ { "TOPRIGHT", row, "TOPRIGHT", -50, 0 }, { "BOTTOMRIGHT", row, "BOTTOMRIGHT", -50, 0 }, 90 },
        { { c.cover:GetPoint(1) }, { c.cover:GetPoint(2) }, c.cover:GetWidth() })
    end)
    it("falls back to the fixed layout: Reagents 90 px, then Expiration 60 px at the right edge", function()
      boot()
      local raw = order()
      show_board({ raw })
      local row = row_for(raw)   -- not laid out at all
      local c = cells_of(row)
      assert.same({ { "TOPRIGHT", row, "TOPRIGHT", -60, 0 }, { "BOTTOMRIGHT", row, "BOTTOMRIGHT", -60, 0 }, 90 },
        { { c.cover:GetPoint(1) }, { c.cover:GetPoint(2) }, c.cover:GetWidth() })
      -- a header or cell with nonsense geometry is no better
      local g = geometry(50)
      g.reagentsLeft, g.reagentsRight = 800, 710
      c = cells_of(row_for(raw, g))
      assert.equal(90, c.cover:GetWidth())
    end)
    it("is an opaque background of one named colour under the icons, in our own container", function()
      boot()
      local raw = order()
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.equal(c.frame, c.cover:GetParent())
      assert.equal(rows():GetContainer(), c.frame:GetParent())
      assert.is_true(c.coverBg:IsShown())
      assert.same(ns.UI.OrdersPanel.COVER_COLOR, c.coverBg.color)
      assert.equal(1, ns.UI.OrdersPanel.COVER_COLOR[4])   -- opaque
    end)
    it("re-measures when the row is re-fitted", function()
      boot()
      local raw = order()
      show_board({ raw })
      local g = geometry(50)
      local row = row_for(raw, g)
      local c = cells_of(row)
      g.reagentsLeft, g.reagentsRight = 720, 800
      W.advance(0)
      assert.equal(80, c.cover:GetWidth())
    end)
  end)

  describe("tooltips", function()
    it("shows the Rewards lines over the reward strip", function()
      boot()
      cached[2001] = "Sword"
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      local raw = order({ orderType = 3, npcOrderRewards = { item_reward(2001, 3), { currencyType = 3001, count = 1 } } })
      show_board({ raw })
      local c = cells_of(row_for(raw))
      c.icons:GetScript("OnEnter")(c.icons)
      assert.same({ "Rewards", "|T902001:14|t |Hitem:2001|h[Sword]|h x3", "|T700001:14|t Resonance Crystals x1" }, tooltip.lines)
      assert.is_true(tooltip.shown); assert.equal(c.icons, tooltip.owner)
      c.icons:GetScript("OnLeave")(c.icons)
      assert.is_false(tooltip.shown)
    end)
    it("shows the reagents to supply over the Reagents cover, with what you have", function()
      boot()
      cached[1001], cached[1002] = "Ore", "Silk"
      evalResult = allocation({ itemID = 1001, quantity = 3 }, { itemID = 1002, quantity = 4 })
      owned[1001] = 2
      local raw = order({ orderType = 3, npcOrderRewards = { item_reward(2001, 3) } })
      show_board({ raw })
      local c = cells_of(row_for(raw))
      c.cover:GetScript("OnEnter")(c.cover)
      assert.same({ "Reagents to supply", "|Hitem:1001|h[Ore]|h: need 3, have 2", "|Hitem:1002|h[Silk]|h: need 4" },
        tooltip.lines)
      assert.equal(c.cover, tooltip.owner)
      c.cover:GetScript("OnLeave")(c.cover)
      assert.is_false(tooltip.shown)
    end)
    it("lists the reagents the cover had no room for", function()
      boot()
      evalResult = slots_needed(7)
      local raw = order()
      show_board({ raw })
      local c = cells_of(row_for(raw, geometry(50)))
      c.cover:GetScript("OnEnter")(c.cover)
      assert.equal(8, #tooltip.lines)   -- the header and 7 reagents
    end)
    it("says why a check or a ? is there", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      local provided, recraft = order({ orderID = 10, reagents = { reagent(1001, 3) } }), order({ orderID = 11, isRecraft = true })
      show_board({ provided, recraft })
      local a, b = cells_of(row_for(provided)), cells_of(row_for(recraft))
      a.cover:GetScript("OnEnter")(a.cover)
      assert.same({ "The customer provides every reagent" }, tooltip.lines)
      b.cover:GetScript("OnEnter")(b.cover)
      assert.same({ "Reagents unknown for this order" }, tooltip.lines)
    end)
    it("shows an uncached item as item:<id>, asks for its data and refreshes when it arrives", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      local raw = order()
      show_board({ raw })
      local c = cells_of(row_for(raw))
      c.cover:GetScript("OnEnter")(c.cover)
      assert.same({ "Reagents to supply", "item:1001: need 3" }, tooltip.lines)
      assert.same({ 1001 }, requests)
      c.cover:GetScript("OnEnter")(c.cover)
      assert.same({ 1001 }, requests)   -- asked once
      cached[1001] = "Ore"
      W.fire("GET_ITEM_INFO_RECEIVED", 1001, true)
      W.advance(0)
      assert.same({ "Reagents to supply", "|Hitem:1001|h[Ore]|h: need 3" }, tooltip.lines)
      c.cover:GetScript("OnLeave")(c.cover)
      tooltip.lines = {}
      W.fire("GET_ITEM_INFO_RECEIVED", 1001, true)
      W.advance(0)
      assert.same({}, tooltip.lines)   -- not hovering: the tooltip is left alone
    end)
    it("stops following the pointer when the strip or the cover hides", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      local raw = order({ orderType = 3, npcOrderRewards = { item_reward(2001, 1) } })
      show_board({ raw })
      local g = geometry(50)
      local c = cells_of(row_for(raw, g))
      c.icons:GetScript("OnEnter")(c.icons)
      assert.truthy(c.tipping)
      g.textWidth = 200   -- the name takes the room: the strip hides
      W.advance(0)
      assert.is_false(c.icons:IsShown()); assert.falsy(c.tipping)
      g.textWidth = 50
      W.advance(0)
      c.cover:GetScript("OnEnter")(c.cover)
      assert.truthy(c.tipping)
      ns.FS:GetModule("Orders"):Settings().showRowIcons = false
      ns.FS:SendMessage("FS_ORDERS_CHANGED")
      assert.falsy(c.tipping)
      ns.FS:GetModule("Orders"):Settings().showRowIcons = true
      ns.FS:SendMessage("FS_ORDERS_CHANGED")
      c.icons:GetScript("OnEnter")(c.icons)
      assert.truthy(c.tipping)
      form.ordersPage:ShowBuckets(0, false)
      assert.falsy(c.tipping)
    end)
    it("turns off only OrdersRowAddons when a tooltip fails", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      local raw = order()
      show_board({ raw })
      local c = cells_of(row_for(raw))
      _G.GameTooltip = { SetOwner = function() error("boom") end, Hide = function() end }
      c.cover:GetScript("OnEnter")(c.cover)
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
    it("removes the cover and the strip on the rows on screen as soon as it is turned off, and brings them back", function()
      boot()
      local raw = rewards_order()
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.same({ true, true }, { c.icons:IsShown(), c.cover:IsShown() })
      options().set(nil, false)
      assert.is_false(ns.FS:GetModule("Orders"):Settings().showRowIcons)
      assert.same({ false, false }, { c.icons:IsShown(), c.cover:IsShown() })
      assert.same({ {}, {}, nil }, { c.iconEntries, c.reagentEntries, c.coverMode })
      assert.is_true(c.strip:IsShown())   -- the cells stay
      options().set(nil, true)
      assert.same({ true, true }, { c.icons:IsShown(), c.cover:IsShown() })
    end)
    it("keeps a new row's cover off while it is off", function()
      boot()
      local raw = rewards_order()
      ns.FS:GetModule("Orders"):Settings().showRowIcons = false
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.same({ false, false }, { c.icons:IsShown(), c.cover:IsShown() })
      assert.is_true(c.frame:IsShown())
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

  describe("bag changes", function()
    local function listening() return rows():IsEventRegistered("BAG_UPDATE_DELAYED") end

    it("refreshes the owned colours on BAG_UPDATE_DELAYED, but only while the list is shown", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      owned[1001] = 1
      local raw = order()
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.same(RED, count_color(c.coverSlots[1]))
      assert.is_true(listening())
      owned[1001] = 5
      W.fire("BAG_UPDATE_DELAYED")
      assert.same(RED, count_color(c.coverSlots[1]))   -- coalesced into the next frame
      W.advance(0)
      assert.same({ WHITE, 5 }, { count_color(c.coverSlots[1]), c.reagentEntries[1].have })
      -- the list hides: not listening, nothing recomputed
      local box = form.orderScrollBox
      form.raw(box):Hide(); box:GetScript("OnHide")(box)
      assert.is_false(listening())
      owned[1001] = 0
      W.fire("BAG_UPDATE_DELAYED"); W.advance(0)
      assert.same(WHITE, count_color(c.coverSlots[1]))
      form.raw(box):Show(); box:GetScript("OnShow")(box)
      assert.is_true(listening())
      ns.FS:SetModuleEnabled("OrdersRowAddons", false)
      assert.is_false(listening())
      assert.same({}, form.assignedFields)
    end)
    it("cancels a pending refresh with the module", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      owned[1001] = 1
      local raw = order()
      show_board({ raw })
      local c = cells_of(row_for(raw))
      owned[1001] = 5
      W.fire("BAG_UPDATE_DELAYED")
      ns.FS:SetModuleEnabled("OrdersRowAddons", false)
      W.advance(0)
      assert.same(RED, count_color(c.coverSlots[1]))
    end)
  end)

  describe("dimming and recycling", function()
    it("gives the reward strip the strip's alpha 0.6 and the cover its own dark overlay on a dimmed row", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      local raw = order({ expirationTime = 5100, orderType = 3, npcOrderRewards = { item_reward(2001, 1) } })
      local row = row_for(raw)
      show_board({ raw })
      local c = cells_of(row)
      assert.same({ 1, 1, 1, false }, { c.strip:GetAlpha(), c.icons:GetAlpha(), c.cover:GetAlpha(), c.coverDim:IsShown() })
      ns.FS:GetModule("Orders"):Settings().filters.hideRisks.expiringSoon = true
      ns.FS:SendMessage("FS_ORDERS_CHANGED")
      assert.is_true(c.dimmed)
      assert.same({ 0.6, 0.6, 1, true }, { c.strip:GetAlpha(), c.icons:GetAlpha(), c.cover:GetAlpha(), c.coverDim:IsShown() })
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
      assert.same({ 2, 1 }, { #shown(c.slots), #shown(c.coverSlots) })
      form.releaseOrderRow(row)
      assert.same({ false, false, false }, { c.frame:IsShown(), c.cover:IsShown(), c.icons:IsShown() })
      form.acquireOrderRow(row, form.orderElement(second), false)
      assert.same({ { i = 1, file = 700001, count = "4" } }, shown(c.slots))
      assert.same({ { i = 1, file = 901001, count = "3" } }, shown(c.coverSlots))
      assert.is_false(c.more:IsShown())
      -- a count shown for the last order is gone when the next one needs none
      local third = order({ orderID = 12, orderType = 3, npcOrderRewards = { item_reward(2002, 1) } })
      evalResult = allocation()
      show_board({ first, second, third })
      form.releaseOrderRow(row)
      form.acquireOrderRow(row, form.orderElement(third), false)
      assert.same({ { i = 1, file = 902002, count = nil } }, shown(c.slots))
      assert.same({ "provided", 0 }, { c.coverMode, #shown(c.coverSlots) })
      assert.same({}, form.assignedFields)
    end)
    it("pools the icon textures: a row reuses its slots", function()
      boot()
      local first = order({ orderID = 10, orderType = 3, npcOrderRewards = { item_reward(2001, 2), item_reward(2002, 1) } })
      local second = order({ orderID = 11, orderType = 3, npcOrderRewards = { item_reward(2001, 1) } })
      evalResult = slots_needed(3)
      show_board({ first, second })
      local row = row_for(first)
      local c = cells_of(row)
      local one, two, cover3 = c.slots[1].icon, c.slots[2].icon, c.coverSlots[3].icon
      form.releaseOrderRow(row)
      evalResult = slots_needed(1)
      show_board({ first, second })
      form.acquireOrderRow(row, form.orderElement(second), false)
      assert.same({ true, true, 2, 3 }, { c.slots[1].icon == one, c.slots[2].icon == two, #c.slots, #c.coverSlots })
      assert.same({ true, false, false }, { one:IsShown(), two:IsShown(), cover3:IsShown() })
    end)
  end)

  describe("pure helpers", function()
    it("RewardEntries and ReagentEntries need a table view with the right shapes", function()
      boot()
      local P = ns.UI.OrdersPanel
      assert.same({}, P.RewardEntries(nil)); assert.same({}, P.RewardEntries({})); assert.same({}, P.RewardEntries({ rewards = "x" }))
      assert.same({ { kind = "reward", itemID = 3, count = 2 } }, P.RewardEntries({ rewards = { { itemID = 3, count = 2 }, {} } }))
      assert.is_nil(P.ReagentEntries(nil)); assert.is_nil(P.ReagentEntries({}))
      assert.is_nil(P.ReagentEntries({ result = { allocation = "y" } }))
    end)
    it("ReagentEntries takes the customer-provided counts from the order input, not from view.provided", function()
      boot()
      local P = ns.UI.OrdersPanel
      local view = { result = { allocation = { { itemID = 5, quantity = 4 } } }, input = { provided = { [5] = 1 } },
        provided = { [5] = 4 } }
      assert.same({ { kind = "reagent", itemID = 5, count = 3, have = 9 } }, P.ReagentEntries(view, function() return 9 end))
    end)
    it("ReagentState tells reagents, provided and unknown apart", function()
      boot()
      local P = ns.UI.OrdersPanel
      local alloc = { { itemID = 5, quantity = 4 } }
      assert.equal("reagents", P.ReagentState({ result = { allocation = alloc }, input = {} }))
      assert.equal("provided", P.ReagentState({ result = { allocation = alloc }, input = { provided = { [5] = 4 } } }))
      assert.equal("provided", P.ReagentState({ result = { allocation = {} }, input = {} }))
      assert.equal("unsure", P.ReagentState({ result = { allocation = alloc }, input = { isRecraft = true } }))
      assert.equal("unsure", P.ReagentState({ result = { allocation = alloc }, flags = { recraft = true } }))
      assert.equal("unsure", P.ReagentState({ input = {} }))
      assert.is_nil(P.ReagentState(nil))
    end)
    it("IconLayout counts the slots that fit, with a 22 px +N slot", function()
      boot()
      local P = ns.UI.OrdersPanel
      local entries = { {}, {}, {}, {} }
      assert.same({ shown = 4, width = 59 }, P.IconLayout(entries, nil))
      assert.same({ shown = 4, width = 59 }, P.IconLayout(entries, 59))
      assert.same({ shown = 2, more = 2, width = 52 }, P.IconLayout(entries, 58))   -- 2 icons + "+2"
      assert.same({ shown = 0, more = 4, width = 22 }, P.IconLayout(entries, 22))
      assert.same({ shown = 0, width = 0 }, P.IconLayout(entries, 21))
      assert.same({ shown = 0, width = 0 }, P.IconLayout({}, 100))
    end)
  end)
end)
