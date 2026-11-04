local P2 = require("tests.helpers.phase2")

local FILES = { "Modules/Customers.lua", "Data/OrderRewards.lua", "Modules/Orders.lua", "Modules/Ledger.lua",
  "UI/OrdersPanel.lua", "UI/OrdersOptions.lua" }
local QUESTION_MARK = 134400
local RED, WHITE = { 1, 0.25, 0.25 }, { 1, 1, 1 }
-- The columns of the order list, as { left, right } on a row spanning 100..860: item name, Customer 145, Tip 160,
-- Reagents 90, Expiration 65. (Blizzard's own widths are 160 / 160 / 90 / 60; these differ, so a spec can tell what
-- was measured from the fixed layout.)
local NAME_COLUMN = { 100, 400 }
local COLUMNS = { { 400, 545 }, { 545, 705, 560 }, { 705, 795 }, { 795, 860 } }   -- Tip: Blizzard's money ends at 560
local function copy_columns(columns)
  local out = {}
  for i, c in ipairs(columns) do out[i] = { c[1], c[2], c[3] } end
  return out
end

-- Order rows (OrdersRowAddons): a strip of reward icons in the item-name column, and a cover over Blizzard's Reagents
-- cell that shows the reagents the crafter must supply (a check when the customer provides them all, "?" when they
-- are unknown). Which icons an order gets, where they sit, what the tooltips say, the setting that turns them off.
describe("OrdersPanel row icons", function()
  local ns, W, form, tooltip, owned, ownedCalls, evalResult, board, cached, requests, headers

  -- The icon geometry comes from the module (read at boot), so a size change is a one-line edit there: S = icon size,
  -- G = gap, MW = the "+N" slot's width.
  local S, G, MW
  local function strip_width(n) return n * (S + G) - G end        -- n icons side by side
  local function with_more(n) return n * (S + G) + MW end          -- n icons, then a "+N" slot
  local function slot_x(i) return (i - 1) * (S + G) end            -- the left edge of slot i
  local function fit_count(room)                                    -- icons drawn beside a "+N" in `room` px
    local n = 0
    while with_more(n + 1) <= room do n = n + 1 end
    return n
  end
  -- The layout's measures come from the module (LAYOUT, read at boot).
  local LY

  -- The list's column headers (read-only for the addon): the name column and `columns`, handed out in a scrambled
  -- creation order. texts[i] = the text of the i-th column (nil: the header has no text).
  local function set_headers(columns, texts)
    local all = { NAME_COLUMN }
    for _, c in ipairs(columns) do all[#all + 1] = c end
    headers = {}
    for i, c in ipairs(all) do
      headers[i] = { GetLeft = function() return c[1] end, GetRight = function() return c[2] end,
        GetText = function() return texts and texts[i] or nil end }
    end
    local scrambled = {}
    for n, i in ipairs({ 3, 1, 5, 2, 4, 6, 7 }) do scrambled[n] = headers[i] end
    for i = #scrambled, 1, -1 do if scrambled[i] == nil then table.remove(scrambled, i) end end
    form.raw(form.orderList).HeaderContainer.GetChildren = function() return unpack(scrambled) end
  end

  -- Order 10 as the rest of the specs build it: a personal order from Bob, 500000 tip, the customer provides no
  -- reagents (reagentState 2, "None"; raw_order's own default is 0, "All").
  local function order(overrides) return P2.raw_order(P2.merge({ orderID = 10, reagentState = 2 }, overrides or {})) end
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
      GetOwner = function() return tooltip.owner end,
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
    S, G, MW = ns.UI.OrdersPanel.ICON_SIZE, ns.UI.OrdersPanel.ICON_GAP, ns.UI.OrdersPanel.MORE_WIDTH
    LY = ns.UI.OrdersPanel.LAYOUT
    W.fire("ADDON_LOADED", "Blizzard_Professions")
    headers = nil
    set_headers(COLUMNS, nil)
  end

  local function rows() return ns.FS:GetModule("OrdersRowAddons") end
  local function show_board(orders)
    board = orders
    form.ordersPage:ShowOrders(0, false)
  end
  -- Row geometry as in orders_panel_spec: the row spans 100..860, the strip's right edge is 294 from the row's left,
  -- the name ends at 22 + textWidth. The other columns are COLUMNS.
  local function geometry(textWidth)
    return { left = 100, width = 760, itemRight = 400, textLeft = 122, textWidth = textWidth,
      columns = copy_columns(COLUMNS) }
  end
  -- A row laid out like the list (a short name unless given); `false`: a row that was not laid out at all.
  local function row_for(option, g)
    if g == nil then g = geometry(10) end
    local row = form.newOrderRow(g or nil)
    form.acquireOrderRow(row, form.orderElement(option), true)
    return row
  end
  local function cells_of(row) return rows():GetCells(row) end
  local function O_view(orderID) return ns.FS:GetModule("Orders"):GetView(orderID) end
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

  describe("reward icons in the Commission cover", function()
    it("shows the rewards in order with their counts: items and currencies", function()
      boot()
      local raw = order({ orderType = 3, npcOrderRewards = { item_reward(2001, 3), { currencyType = 3001, count = 1 },
        item_reward(2002, 1) } })
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.same({ { i = 1, file = 902001, count = "3" }, { i = 2, file = 700001, count = nil },
        { i = 3, file = 902002, count = nil } }, shown(c.tipSlots))
      assert.is_true(c.tipCover:IsShown()); assert.equal(c.tipContent, select(2, c.tipSlots[1].icon:GetPoint(1)))
      assert.same({ "reward", "reward", "reward" }, { c.iconEntries[1].kind, c.iconEntries[2].kind, c.iconEntries[3].kind })
    end)
    it("holds the amount and the rewards only: the reagents go to the Reagents cover", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      local raw = order({ orderType = 3, npcOrderRewards = { item_reward(2001, 2) } })
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.equal(1, #c.iconEntries); assert.equal(1, #shown(c.tipSlots))
      assert.same({ 901001 }, files_of(c.coverSlots))
    end)
    it("shows just the amount for an order without rewards", function()
      boot()
      local raw = order()
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.same({}, c.iconEntries)
      assert.same({ true, "45g", 0, false }, { c.tipCover:IsShown(), c.tipAmount:GetText(), #shown(c.tipSlots), c.tipMore:IsShown() })
    end)
    it("falls back to the question mark for a missing icon, never an error", function()
      boot()
      local raw = order({ orderType = 3, npcOrderRewards = { item_reward(9999, 1), { currencyType = 3999, count = 2 } } })
      show_board({ raw })
      assert.same({ { i = 1, file = QUESTION_MARK, count = nil }, { i = 2, file = QUESTION_MARK, count = "2" } },
        shown(cells_of(row_for(raw)).tipSlots))
      assert.is_true(rows():IsEnabled())
    end)
    it("uses GetItemIcon when C_Item.GetItemIconByID is missing, and the question mark when neither answers", function()
      boot({ C_Item = { GetItemIconByID = P2.NIL }, GetItemIcon = function(id) if id == 2001 then return 555 end end })
      local raw = order({ orderType = 3, npcOrderRewards = { item_reward(2001, 1), item_reward(2002, 1) } })
      show_board({ raw })
      assert.same({ 555, QUESTION_MARK }, files_of(cells_of(row_for(raw)).tipSlots))
      boot({ C_Item = { GetItemIconByID = P2.NIL } })
      show_board({ raw })
      assert.same({ QUESTION_MARK, QUESTION_MARK }, files_of(cells_of(row_for(raw)).tipSlots))
    end)
  end)

  describe("the Commission cover", function()
    local TIP_LEFT, TIP_RIGHT, ROW_RIGHT = 545, 705, 860
    local X0 = 4 + 44 + 4   -- COVER_PAD + the amount's width + GAP: where the first icon starts
    -- A row of n rewards (default geometry, a short name).
    local function rewards_row(n)
      boot()
      local rewards = {}
      for i = 1, n do rewards[i] = item_reward(2000 + i, 1) end
      local raw = order({ orderType = 3, npcOrderRewards = rewards })
      show_board({ raw })
      local row = row_for(raw)
      return cells_of(row), row, raw
    end
    local function state(c)
      return { #shown(c.tipSlots), c.tipMore:IsShown() and c.tipMore:GetText() or nil }
    end
    local function points(c) return { { c.tipCover:GetPoint(1) }, { c.tipCover:GetPoint(2) }, c.tipCover:GetWidth() } end

    it("sits over the Commission cell, in our own container, without touching Blizzard's cell", function()
      local c, row = rewards_row(2)
      assert.same({ { "TOPRIGHT", row, "TOPRIGHT", -(ROW_RIGHT - TIP_RIGHT), 0 },
        { "BOTTOMRIGHT", row, "BOTTOMRIGHT", -(ROW_RIGHT - TIP_RIGHT), 0 }, TIP_RIGHT - TIP_LEFT }, points(c))
      assert.equal(c.frame, c.tipCover:GetParent())
      assert.is_true(c.tipCover:IsShown()); assert.same(ns.UI.OrdersPanel.COVER_COLOR, c.tipBg.color)
      assert.equal(1, ns.UI.OrdersPanel.COVER_COLOR[4])   -- opaque: Blizzard's gold cannot show through
      assert.same({}, form.assignedFields)
    end)
    it("shows the compact commission and then the reward icons, left-aligned", function()
      local c = rewards_row(2)
      assert.same({ "45g", WHITE }, { c.tipAmount:GetText(), { c.tipAmount:GetTextColor() } })
      assert.same({ "LEFT", c.tipCover, "LEFT", 4, 0 }, { c.tipAmount:GetPoint(1) })
      assert.is_false(c.tipAmount:GetWordWrap())   -- a long amount stays on one line, off the icons
      local function x(i) local _, _, _, px = c.tipSlots[i].icon:GetPoint(1); return px end
      assert.same({ X0, X0 + slot_x(2) }, { x(1), x(2) })
      assert.same({ 2, nil }, { #shown(c.tipSlots), c.tipMore:IsShown() and 1 or nil })
    end)
    it("shows +N in a slot of its own, counting the rewards that do not fit", function()
      local c = rewards_row(9)
      local n = fit_count((TIP_RIGHT - TIP_LEFT) - X0 - 4)
      assert.is_true(n > 0 and n < 8)
      assert.same({ n, "+" .. (9 - n) }, state(c))
      assert.same({ "LEFT", c.tipContent, "LEFT", X0 + slot_x(n + 1), 0 }, { c.tipMore:GetPoint(1) })
      assert.same({ MW, false }, { c.tipMore:GetWidth(), c.tipMore:GetWordWrap() })
      assert.is_true(c.tipCover.clips)
    end)
    it("shows ? for an unknown commission", function()
      boot()
      local raw = order({ orderType = 3, tipAmount = false, npcOrderRewards = { item_reward(2001, 1) } })
      show_board({ raw })
      O_view(10).commission = nil
      ns.FS:SendMessage("FS_ORDERS_CHANGED")
      local c = cells_of(row_for(raw))
      assert.equal("?", c.tipAmount:GetText())
      assert.equal(1, #shown(c.tipSlots))
    end)
    it("has no cover where the Commission column cannot be identified, and the rewards stay in the info tooltip", function()
      boot()
      set_headers({ { 400, 560 }, { 560, 710 }, { 710, 860 } })   -- a four-column layout
      local raw = order({ orderType = 3, npcOrderRewards = { item_reward(2001, 2) } })
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.is_false(c.tipCover:IsShown()); assert.equal(1, #c.iconEntries)
      c.risk:GetScript("OnEnter")(c.risk)
      assert.equal("Rewards", tooltip.lines[#tooltip.lines - 1])
    end)
    it("finds the column by its header text, in any layout", function()
      boot()
      _G.PROFESSIONS_COLUMN_HEADER_TIP = "Commission"
      set_headers({ { 400, 520 }, { 520, 640 }, { 640, 860 } }, { "Item", "Customer", "Commission", "Reagents" })
      local raw = order({ orderType = 3, npcOrderRewards = { item_reward(2001, 2) } })
      show_board({ raw })
      local g = geometry(10)
      g.columns = { { 400, 520 }, { 520, 640 }, { 640, 860 } }
      local row = row_for(raw, g)
      local c = cells_of(row)
      assert.is_true(c.tipCover:IsShown())
      assert.same({ "TOPRIGHT", row, "TOPRIGHT", -(860 - 640), 0 }, { c.tipCover:GetPoint(1) })
      _G.PROFESSIONS_COLUMN_HEADER_TIP = nil
    end)
    it("has no cover on a row that is not laid out", function()
      boot()
      local raw = order({ orderType = 3, npcOrderRewards = { item_reward(2001, 2) } })
      show_board({ raw })
      assert.is_false(cells_of(row_for(raw, false)).tipCover:IsShown())
    end)
    it("re-measures on the next re-fit and goes when the layout is no longer known", function()
      local c, row = rewards_row(2)
      assert.is_true(c.tipCover:IsShown())
      set_headers({ { 400, 560 }, { 560, 710 }, { 710, 860 } })
      W.fire("GET_ITEM_INFO_RECEIVED", 1001, true); W.advance(0)
      assert.is_false(c.tipCover:IsShown())
      set_headers(COLUMNS)
      W.fire("GET_ITEM_INFO_RECEIVED", 1001, true); W.advance(0)
      assert.same({ true, TIP_RIGHT - TIP_LEFT }, { c.tipCover:IsShown(), c.tipCover:GetWidth() })
      assert.is_true(row ~= nil)
    end)
    it("does not change what the name column fits: the cells keep their tier whether or not there are rewards", function()
      boot()
      local plain = order({ orderID = 10 })
      local rich = order({ orderID = 11, orderType = 3, npcOrderRewards = { item_reward(2001, 2), item_reward(2002, 1) } })
      show_board({ plain, rich })
      local long = 268 - LY.CORE_WIDTH + 1 - 8
      local a, b = cells_of(row_for(plain, geometry(long))), cells_of(row_for(rich, geometry(long)))
      assert.same({ a.fit, a.strip:IsShown() }, { b.fit, b.strip:IsShown() })
      -- Without room for the core, the rich row keeps its info cell (which lists the rewards): the minimal tier.
      local c = cells_of(row_for(rich, geometry(268 - LY.CORE_WIDTH + 40)))
      assert.same({ "minimal", true, true }, { c.fit, c.strip:IsShown(), c.tipCover:IsShown() })
      local d = cells_of(row_for(rich, geometry(268 - LY.MINIMAL_WIDTH + 1)))
      assert.same({ "none", false, true }, { d.fit, d.strip:IsShown(), d.tipCover:IsShown() })
    end)

    describe("tooltip", function()
      local function lines_of(c)
        c.tipCover:GetScript("OnEnter")(c.tipCover)
        local out = tooltip.lines
        c.tipCover:GetScript("OnLeave")(c.tipCover)
        return out
      end
      it("gives the full commission, then the Rewards lines", function()
        boot()
        cached[2001] = "Sword"
        local raw = order({ orderType = 3, npcOrderRewards = { item_reward(2001, 3), { currencyType = 3001, count = 1 } } })
        show_board({ raw })
        local c = cells_of(row_for(raw))
        local money = ns.UI.FormatMoney
        assert.same({ "Tip: " .. money(500000), "Consortium cut: " .. money(50000), "Commission: " .. money(450000),
          "Rewards", "|T902001:14|t |Hitem:2001|h[Sword]|h x3", "|T700001:14|t Resonance Crystals x1" }, lines_of(c))
        assert.is_false(tooltip.shown)
      end)
      it("ends with what a patron order costs per knowledge point or Moxie", function()
        boot()
        local raw = order({ orderType = 3, npcOrderRewards = { item_reward(2001, 1) } })
        show_board({ raw })
        local view = O_view(10)
        view.costPerReward = { knowledge = 120000, moxie = 30000 }
        ns.FS:SendMessage("FS_ORDERS_CHANGED")
        local c = cells_of(row_for(raw))
        local lines = lines_of(c)
        assert.equal("Pays " .. ns.UI.FormatMoney(120000) .. " per knowledge point", lines[#lines - 1])
        assert.equal("Pays " .. ns.UI.FormatMoney(30000) .. " per Moxie", lines[#lines])
      end)
      it("leaves out what is unknown, and has no Rewards lines for an order without rewards", function()
        boot()
        local raw = order()
        show_board({ raw })
        local view = O_view(10)
        view.commission, view.consortiumCut = nil, nil
        ns.FS:SendMessage("FS_ORDERS_CHANGED")
        local c = cells_of(row_for(raw))
        assert.same({ "Tip: " .. ns.UI.FormatMoney(500000) }, lines_of(c))
      end)
      it("turns off only OrdersRowAddons when it fails", function()
        boot()
        local raw = order()
        show_board({ raw })
        local c = cells_of(row_for(raw))
        _G.GameTooltip = { SetOwner = function() error("boom") end, Hide = function() end }
        c.tipCover:GetScript("OnEnter")(c.tipCover)
        assert.is_false(rows():IsEnabled()); assert.is_true(ns.FS:GetModule("OrdersSidePanel"):IsEnabled())
      end)
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
    it("draws the icons left-aligned with a small padding, icon size apart by the gap", function()
      boot()
      evalResult = slots_needed(3)
      local raw = order()
      show_board({ raw })
      local c = cells_of(row_for(raw))
      local function x(i) local _, _, _, px = c.coverSlots[i].icon:GetPoint(1); return px end
      assert.same({ 4, 4 + slot_x(2), 4 + slot_x(3) }, { x(1), x(2), x(3) })
      assert.same({ "LEFT", c.coverContent, "LEFT", 4, 0 }, { c.coverSlots[1].icon:GetPoint(1) })
      assert.same({ S, S }, { c.coverSlots[1].icon:GetSize() })
    end)
    it("shows an icon only for a reagent you are short of or cannot be sure you have", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 }, { itemID = 1002, quantity = 4 }, { itemID = 1003, quantity = 2 },
        { itemID = 1004, quantity = 1 })
      owned[1001], owned[1002], owned[1004] = 2, 4, 9   -- short; exactly enough; plenty; 1003 unknown (nil)
      local raw = order()
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.equal("reagents", c.coverMode)
      assert.same({ 901001, 901003 }, files_of(c.coverSlots))   -- 1002 and 1004 are owned: no icon
      local s = c.coverSlots
      assert.same({ RED, WHITE }, { count_color(s[1]), count_color(s[2]) })   -- short: red; unknown: white
      assert.same({ 1001, 1003 }, { c.shortEntries[1].itemID, c.shortEntries[2].itemID })
      -- the tooltip still has all four, owned ones included
      assert.same({ 2, 4, nil, 9 }, { c.reagentEntries[1].have, c.reagentEntries[2].have, c.reagentEntries[3].have,
        c.reagentEntries[4].have })
      -- none at all is a known 0: short, red
      evalResult = allocation({ itemID = 1005, quantity = 2 })
      owned[1005] = 0
      show_board({ order({ orderID = 11 }) })
      c = cells_of(row_for(order({ orderID = 11 })))
      assert.same({ 0, RED }, { c.reagentEntries[1].have, count_color(c.coverSlots[1]) })
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
      local c = cells_of(row_for(raw, geometry(10)))
      local n = fit_count(90 - 2 * 4)   -- the 90 px column less its padding
      assert.is_true(n > 0 and n < 6)
      assert.equal(n, #shown(c.coverSlots))
      assert.same({ true, "+" .. (7 - n), MW }, { c.coverMore:IsShown(), c.coverMore:GetText(), c.coverMore:GetWidth() })
      assert.same({ "LEFT", c.coverContent, "LEFT", 4 + slot_x(n + 1), 0 }, { c.coverMore:GetPoint(1) })
      assert.is_true(c.cover.clips)
    end)
  end)

  describe("the Reagents cover: reagents you already have", function()
    it("hides a reagent you own enough of and shows one you are short of", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 }, { itemID = 1002, quantity = 4 })
      owned[1001], owned[1002] = 3, 3   -- exactly enough; one short
      local raw = order()
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.same({ { i = 1, file = 901002, count = "4" } }, shown(c.coverSlots))
    end)
    it("shows a reagent whose owned count is unknown", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      local raw = order()
      show_board({ raw })   -- owned[1001] is nil: the game gave no count
      local c = cells_of(row_for(raw))
      assert.same({ 901001 }, files_of(c.coverSlots)); assert.same(WHITE, count_color(c.coverSlots[1]))
    end)
    it("shows the green check when you own everything you must supply", function()
      boot()
      cached[1001], cached[1002] = "Ore", "Silk"
      evalResult = allocation({ itemID = 1001, quantity = 3 }, { itemID = 1002, quantity = 4 })
      owned[1001], owned[1002] = 3, 10
      local raw = order()
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.equal("stocked", c.coverMode); assert.is_true(c.cover:IsShown())
      assert.same({ true, false, 0 }, { c.coverCheck:IsShown(), c.coverQuestion:IsShown(), #shown(c.coverSlots) })
      c.cover:GetScript("OnEnter")(c.cover)
      assert.same({ "You have every reagent this order needs from you", "Reagents to supply",
        "|Hitem:1001|h[Ore]|h: need 3, have 3", "|Hitem:1002|h[Silk]|h: need 4, have 10" }, tooltip.lines)
    end)
    it("keeps the customer-provides line for the all-provided check", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      owned[1001] = 50
      local raw = order({ reagents = { reagent(1001, 3) } })
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.equal("provided", c.coverMode)
      c.cover:GetScript("OnEnter")(c.cover)
      assert.same({ "The customer provides every reagent" }, tooltip.lines)
    end)
    -- Blizzard's Reagents cell draws its own tooltip on OnEnter (the patron's reagents as a frame of icons, with no text).
    -- Passing the pointer's motion through let that replace ours, so the covers take the motion and let only clicks by.
    describe("the mouse on a cover", function()
      local calls
      local function setup_covers()
        boot()
        calls = {}
        local create = _G.CreateFrame
        _G.CreateFrame = function(...)
          local frame = create(...)
          for _, method in ipairs({ "SetMouseClickEnabled", "SetMouseMotionEnabled", "SetPropagateMouseMotion",
            "SetPropagateMouseClicks" }) do
            frame[method] = function(self, value)
              calls[self] = calls[self] or {}
              calls[self][method] = value
            end
          end
          return frame
        end
        local raw = order({ reagents = { reagent(1001, 3) } })
        evalResult = allocation({ itemID = 1001, quantity = 3 })
        show_board({ raw })
        return cells_of(row_for(raw))
      end
      it("keeps the motion from Blizzard's cell and lets clicks reach it", function()
        local c = setup_covers()
        for _, cover in ipairs({ c.cover, c.tipCover }) do
          local got = calls[cover] or {}
          assert.is_false(got.SetMouseClickEnabled)
          assert.is_true(got.SetMouseMotionEnabled)
          assert.is_nil(got.SetPropagateMouseMotion)
          assert.is_nil(got.SetPropagateMouseClicks)
        end
      end)
      it("lights the whole row while the pointer is on a cover, and only then", function()
        local c = setup_covers()
        assert.is_false(c.rowLit:IsShown())
        c.cover:GetScript("OnEnter")(c.cover)
        assert.is_true(c.rowLit:IsShown())
        c.cover:GetScript("OnLeave")(c.cover)
        assert.is_false(c.rowLit:IsShown())
        c.tipCover:GetScript("OnEnter")(c.tipCover)
        assert.is_true(c.rowLit:IsShown())
        c.tipCover:GetScript("OnLeave")(c.tipCover)
        assert.is_false(c.rowLit:IsShown())
      end)
    end)
    it("lists every reagent in the tooltip, owned ones included, short ones in red", function()
      boot()
      cached[1001], cached[1002] = "Ore", "Silk"
      evalResult = allocation({ itemID = 1001, quantity = 3 }, { itemID = 1002, quantity = 4 })
      owned[1001], owned[1002] = 8, 1
      local raw = order()
      show_board({ raw })
      local c = cells_of(row_for(raw))
      c.cover:GetScript("OnEnter")(c.cover)
      assert.same({ "Reagents to supply", "|Hitem:1001|h[Ore]|h: need 3, have 8", "|Hitem:1002|h[Silk]|h: need 4, have 1" },
        tooltip.lines)
    end)
    it("counts only the hidden short reagents in +N", function()
      boot()
      -- 7 reagents; the first four are owned. Three short ones fit as icons only if there is room for them all.
      evalResult = slots_needed(7)
      for i = 1, 4 do owned[1000 + i] = 5 end
      local raw = order()
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.equal(3, #c.shortEntries)
      assert.equal(3, #shown(c.coverSlots)); assert.is_false(c.coverMore:IsShown())   -- 3 icons fit: no "+N"
      -- a wider need: 7 short ones, 2 owned -> 5 short; "+N" counts those not drawn, never the owned ones
      boot()
      evalResult = slots_needed(7)
      for i = 1, 2 do owned[1000 + i] = 5 end
      raw = order()
      show_board({ raw })
      c = cells_of(row_for(raw))
      local n = fit_count(90 - 2 * 4)
      assert.equal(5, #c.shortEntries)
      assert.same({ n, true, "+" .. (5 - n) }, { #shown(c.coverSlots), c.coverMore:IsShown(), c.coverMore:GetText() })
    end)
    it("flips a row to the check when a bag change brings the missing reagent", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      owned[1001] = 1
      local raw = order()
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.same({ "reagents", true }, { c.coverMode, #shown(c.coverSlots) == 1 })
      owned[1001] = 3   -- bought
      W.fire("BAG_UPDATE_DELAYED"); W.advance(0)
      assert.same({ "stocked", true, 0 }, { c.coverMode, c.coverCheck:IsShown(), #shown(c.coverSlots) })
      owned[1001] = 0   -- and sold again
      W.fire("BAG_UPDATE_DELAYED"); W.advance(0)
      assert.same({ "reagents", false, 1 }, { c.coverMode, c.coverCheck:IsShown(), #shown(c.coverSlots) })
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
    it("shows the check when Blizzard's own reagent state says the customer provides all", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      local raw = order({ reagentState = 0 })   -- Enum.CraftingOrderReagentsType.All
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.equal("provided", c.coverMode)
      assert.is_true(c.coverCheck:IsShown())
      assert.same({}, c.reagentEntries)
      evalResult = nil   -- even where nothing could be evaluated
      show_board({ order({ orderID = 11, reagentState = 0 }) })
      assert.equal("provided", ns.UI.OrdersPanel.ReagentState({ input = { reagentState = "all" } }))
      assert.equal("unsure", ns.UI.OrdersPanel.ReagentState({ input = { reagentState = "all", isRecraft = true } }))
      assert.equal("reagents", ns.UI.OrdersPanel.ReagentState({ input = { reagentState = "some" },
        result = { allocation = { { itemID = 5, quantity = 1 } } } }))
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
      assert.is_false(c.frame:IsShown()); assert.is_false(c.cover:IsShown()); assert.is_false(c.tipCover:IsShown())
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
    local function points(c) return { { c.cover:GetPoint(1) }, { c.cover:GetPoint(2) }, c.cover:GetWidth() } end
    local function expect(row, offset, width)
      return { { "TOPRIGHT", row, "TOPRIGHT", -offset, 0 }, { "BOTTOMRIGHT", row, "BOTTOMRIGHT", -offset, 0 }, width }
    end
    local function one_order()
      boot()
      local raw = order()
      show_board({ raw })
      return raw
    end

    it("covers the Reagents column as the header measures it (not the fixed 60 px offset)", function()
      local raw = one_order()
      local row = row_for(raw)
      local c = cells_of(row)
      assert.is_true(c.cover:IsShown())
      assert.same(expect(row, 65, 90), points(c))   -- the row ends at 860, the column at 795
      assert.same({}, form.assignedFields)
    end)
    it("sorts the headers by their left edge, whatever order they were created in", function()
      local raw = one_order()
      set_headers({ { 400, 560 }, { 560, 700 }, { 700, 790 }, { 790, 860 } })   -- handed out scrambled by set_headers
      local row = row_for(raw)
      assert.same(expect(row, 70, 90), points(cells_of(row)))
    end)
    it("finds the Reagents header by its text, in any layout", function()
      local raw = one_order()
      _G.PROFESSIONS_COLUMN_HEADER_REAGENTS = "Reagents"
      -- Reagents is the third of four columns and 120 px wide: only its text says so.
      set_headers({ { 400, 520 }, { 520, 640 }, { 640, 860 } }, { "Item", "Customer", "Reagents", "Tip" })
      local row = row_for(raw)
      local c = cells_of(row)
      assert.is_true(c.cover:IsShown())
      assert.same(expect(row, 220, 120), points(c))
      _G.PROFESSIONS_COLUMN_HEADER_REAGENTS = nil
    end)
    it("falls back to the known five-column widths when no header carries the text", function()
      local raw = one_order()
      _G.PROFESSIONS_COLUMN_HEADER_REAGENTS = "Reagents"
      set_headers(COLUMNS, { "Item", "Customer", "Tip", "Cost", "Expiration" })   -- no header says "Reagents"
      local row = row_for(raw)
      assert.is_true(cells_of(row).cover:IsShown())   -- the width and the place fit the known layout
      _G.PROFESSIONS_COLUMN_HEADER_REAGENTS = nil
    end)
    it("covers nothing on a four-column layout", function()
      local raw = one_order()
      set_headers({ { 400, 560 }, { 560, 710 }, { 710, 860 } })   -- the name and three more
      local row = row_for(raw)
      local c = cells_of(row)
      assert.is_false(c.cover:IsShown())
      assert.is_true(c.frame:IsShown())   -- the rest of the row still works
    end)
    it("covers nothing on a three-column layout", function()
      local raw = one_order()
      form.raw(form.orderList).HeaderContainer.GetChildren = function() return end   -- no headers to read
      local g = geometry(10)
      g.columns = { { 400, 640 }, { 640, 860 } }
      local c = cells_of(row_for(raw, g))
      assert.is_false(c.cover:IsShown())
    end)
    it("covers nothing when the layout has five columns but the fourth is not 80 to 100 px wide", function()
      local raw = one_order()
      set_headers({ { 400, 540 }, { 540, 640 }, { 640, 800 }, { 800, 860 } })   -- the fourth, 160 px: Tip's width
      local row = row_for(raw)
      assert.is_false(cells_of(row).cover:IsShown())
      set_headers({ { 400, 545 }, { 545, 705 }, { 705, 770 }, { 770, 860 } })   -- 65 px
      assert.is_false(cells_of(row_for(raw)).cover:IsShown())
    end)
    it("covers nothing when the 90 px column is not the one before the last", function()
      local raw = one_order()
      set_headers({ { 400, 490 }, { 490, 650 }, { 650, 810 }, { 810, 860 } })   -- 90 px, but second: in a different order
      assert.is_false(cells_of(row_for(raw)).cover:IsShown())
    end)
    it("measures the row's own cells when the list has no header to read", function()
      local raw = one_order()
      form.raw(form.orderList).HeaderContainer.GetChildren = function() return end
      local g = geometry(10)
      g.columns = { { 400, 550 }, { 550, 700 }, { 700, 790 }, { 790, 860 } }
      local row = row_for(raw, g)
      assert.same(expect(row, 70, 90), points(cells_of(row)))
    end)
    it("covers nothing on a row whose cells are not the known layout either", function()
      local raw = one_order()
      form.raw(form.orderList).HeaderContainer.GetChildren = function() return end
      local g = geometry(10)
      g.columns = { { 400, 560 }, { 560, 720 }, { 720, 860 } }
      assert.is_false(cells_of(row_for(raw, g)).cover:IsShown())
      assert.is_false(cells_of(row_for(raw, false)).cover:IsShown())   -- not laid out, nothing to read
    end)
    it("has no fixed fallback: five headers whose edges cannot be read give no cover", function()
      local raw = one_order()
      local unread = {}
      for i = 1, 5 do unread[i] = { GetText = function() return nil end } end
      form.raw(form.orderList).HeaderContainer.GetChildren = function() return unpack(unread) end
      local row = row_for(raw, false)   -- the row is not laid out either
      assert.is_false(cells_of(row).cover:IsShown())
      assert.is_true(cells_of(row).frame:IsShown())
    end)
    it("has no cover for mixed headers: four readable ones in another order and one unreadable", function()
      local raw = one_order()
      local mixed = {
        { GetLeft = function() return 100 end, GetRight = function() return 400 end, GetText = function() return nil end },
        { GetLeft = function() return 400 end, GetRight = function() return 490 end, GetText = function() return nil end },
        { GetLeft = function() return 490 end, GetRight = function() return 650 end, GetText = function() return nil end },
        { GetLeft = function() return 650 end, GetRight = function() return 800 end, GetText = function() return nil end },
        { GetText = function() return nil end },   -- not laid out
      }
      form.raw(form.orderList).HeaderContainer.GetChildren = function() return unpack(mixed) end
      local row = row_for(raw)
      assert.is_false(cells_of(row).cover:IsShown())
    end)
    it("covers once the headers are laid out: none at init, the cover after the next re-fit", function()
      local raw = one_order()
      local laid = false
      local function edge(left, right)
        return { GetLeft = function() return laid and left or nil end, GetRight = function() return laid and right or nil end,
          GetText = function() return nil end }
      end
      local cols = { edge(100, 400), edge(400, 545), edge(545, 705), edge(705, 795), edge(795, 860) }
      form.raw(form.orderList).HeaderContainer.GetChildren = function() return unpack(cols) end
      local row = row_for(raw)
      local c = cells_of(row)
      assert.is_false(c.cover:IsShown())
      laid = true   -- Blizzard lays the headers out
      W.advance(0)
      assert.is_true(c.cover:IsShown())
      assert.same(expect(row, 65, 90), points(c))
    end)
    it("is an opaque background of one named colour under the icons, in our own container", function()
      local raw = one_order()
      local c = cells_of(row_for(raw))
      assert.equal(c.frame, c.cover:GetParent())
      assert.equal(rows():GetContainer(), c.frame:GetParent())
      assert.is_true(c.coverBg:IsShown())
      assert.same(ns.UI.OrdersPanel.COVER_COLOR, c.coverBg.color)
      assert.equal(1, ns.UI.OrdersPanel.COVER_COLOR[4])   -- opaque
    end)
    it("re-measures when the row is re-fitted", function()
      local raw = one_order()
      local row = row_for(raw)
      local c = cells_of(row)
      set_headers({ { 400, 545 }, { 545, 715 }, { 715, 795 }, { 795, 860 } })   -- Reagents 80 px now
      W.advance(0)
      assert.equal(80, c.cover:GetWidth())
    end)
    it("hides again when a re-fit finds a layout it does not know", function()
      local raw = one_order()
      local row = row_for(raw)
      local c = cells_of(row)
      assert.is_true(c.cover:IsShown())
      c.cover:GetScript("OnEnter")(c.cover)
      set_headers({ { 400, 560 }, { 560, 710 }, { 710, 860 } })
      W.advance(0)
      assert.is_false(c.cover:IsShown()); assert.falsy(c.tipping)
    end)
  end)

  describe("tooltips", function()
    it("lists the rewards in the row's info tooltip too, which an order with rewards always has", function()
      boot()
      cached[2001] = "Sword"
      local raw = order({ orderType = 3, npcOrderRewards = { item_reward(2001, 3), { currencyType = 3001, count = 1 } } })
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.same({ true, "i" }, { c.risk:IsShown(), c.riskCount:GetText() })
      local function tail(n) return { unpack(tooltip.lines, #tooltip.lines - n + 1) } end
      c.risk:GetScript("OnEnter")(c.risk)
      assert.same({ "Rewards", "|T902001:14|t |Hitem:2001|h[Sword]|h x3", "|T700001:14|t Resonance Crystals x1" }, tail(3))
      -- also with the icons off, and where the column could not be identified
      ns.FS:GetModule("Orders"):Settings().showRowIcons = false
      ns.FS:SendMessage("FS_ORDERS_CHANGED")
      assert.is_false(c.tipCover:IsShown())
      c.risk:GetScript("OnEnter")(c.risk)
      assert.equal("Rewards", tail(3)[1])
      ns.FS:GetModule("Orders"):Settings().showRowIcons = true
      set_headers({ { 400, 560 }, { 560, 710 }, { 710, 860 } })
      ns.FS:SendMessage("FS_ORDERS_CHANGED")
      assert.is_false(c.tipCover:IsShown())
      c.risk:GetScript("OnEnter")(c.risk)
      assert.equal("Rewards", tail(3)[1])
    end)
    it("keeps the risk lines first and the rewards after them", function()
      boot()
      local raw = order({ orderType = 3, expirationTime = 5100, npcOrderRewards = { item_reward(2001, 1) } })
      show_board({ raw })
      local c = cells_of(row_for(raw))
      c.risk:GetScript("OnEnter")(c.risk)
      local position = {}
      for i, line in ipairs(tooltip.lines) do position[line] = i end
      assert.equal(1, position["Expiring soon"])
      assert.is_true(position["Rewards"] > position["Expiring soon"])
    end)
    it("has no Rewards lines on the Reagents cover", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      local raw = order({ orderType = 3, npcOrderRewards = { item_reward(2001, 3) } })
      show_board({ raw })
      local c = cells_of(row_for(raw))
      c.cover:GetScript("OnEnter")(c.cover)
      assert.equal("Reagents to supply", tooltip.lines[1])
      assert.equal(2, #tooltip.lines)
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
      local c = cells_of(row_for(raw, geometry(10)))
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
    it("stops following the pointer when a cover hides", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      local raw = order({ orderType = 3, npcOrderRewards = { item_reward(2001, 1) } })
      show_board({ raw })
      local c = cells_of(row_for(raw))
      c.tipCover:GetScript("OnEnter")(c.tipCover)
      assert.truthy(c.tipping)
      set_headers({ { 400, 560 }, { 560, 710 }, { 710, 860 } })   -- the layout is no longer known: both covers go
      W.fire("GET_ITEM_INFO_RECEIVED", 1001, true); W.advance(0)
      assert.is_false(c.tipCover:IsShown()); assert.falsy(c.tipping)
      set_headers(COLUMNS)
      W.fire("GET_ITEM_INFO_RECEIVED", 1001, true); W.advance(0)
      c.cover:GetScript("OnEnter")(c.cover)
      assert.truthy(c.tipping)
      ns.FS:GetModule("Orders"):Settings().showRowIcons = false
      ns.FS:SendMessage("FS_ORDERS_CHANGED")
      assert.falsy(c.tipping)
      ns.FS:GetModule("Orders"):Settings().showRowIcons = true
      ns.FS:SendMessage("FS_ORDERS_CHANGED")
      c.tipCover:GetScript("OnEnter")(c.tipCover)
      assert.truthy(c.tipping)
      form.ordersPage:ShowBuckets(0, false)
      assert.falsy(c.tipping)
    end)
    it("hides the tooltip when it is ours and the strip or cover goes away, and leaves another owner's alone", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      local raw = order()
      show_board({ raw })
      local c = cells_of(row_for(raw))
      c.cover:GetScript("OnEnter")(c.cover)
      assert.is_true(tooltip.shown)
      ns.FS:GetModule("Orders"):Settings().showRowIcons = false
      ns.FS:SendMessage("FS_ORDERS_CHANGED")
      assert.is_false(tooltip.shown)
      ns.FS:GetModule("Orders"):Settings().showRowIcons = true
      ns.FS:SendMessage("FS_ORDERS_CHANGED")
      c.cover:GetScript("OnEnter")(c.cover)
      tooltip.owner = "some other frame"   -- another addon took the tooltip
      ns.FS:GetModule("Orders"):Settings().showRowIcons = false
      ns.FS:SendMessage("FS_ORDERS_CHANGED")
      assert.is_true(tooltip.shown)
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
      assert.same({ true, true }, { c.tipCover:IsShown(), c.cover:IsShown() })
      options().set(nil, false)
      assert.is_false(ns.FS:GetModule("Orders"):Settings().showRowIcons)
      assert.same({ false, false }, { c.tipCover:IsShown(), c.cover:IsShown() })
      assert.same({ {}, {}, nil }, { c.iconEntries, c.reagentEntries, c.coverMode })
      assert.is_true(c.strip:IsShown())   -- the cells stay
      options().set(nil, true)
      assert.same({ true, true }, { c.tipCover:IsShown(), c.cover:IsShown() })
    end)
    it("keeps a new row's cover off while it is off", function()
      boot()
      local raw = rewards_order()
      ns.FS:GetModule("Orders"):Settings().showRowIcons = false
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.same({ false, false }, { c.tipCover:IsShown(), c.cover:IsShown() })
      assert.is_true(c.frame:IsShown())
    end)
    it("is not written while the saved data is from a newer version", function()
      boot()
      ns.FS.dbIsNewer = true
      local snapshot = ns.Util.DeepCopy(ns.FS.db.global, 30)
      assert.is_true(options().disabled())
      options().set(nil, false)
      assert.are.same(snapshot, ns.Util.DeepCopy(ns.FS.db.global, 30))
      assert.is_false(ns.FS:GetModule("Orders"):Settings().showRowIcons)   -- the session-only copy took it
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

    it("refreshes the owned counts on BAG_UPDATE_DELAYED, but only while the list is shown", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      owned[1001] = 1
      local raw = order()
      show_board({ raw })
      local c = cells_of(row_for(raw))
      assert.same(RED, count_color(c.coverSlots[1]))
      assert.is_true(listening())
      owned[1001] = 2   -- still short, but the count changed
      W.fire("BAG_UPDATE_DELAYED")
      assert.equal(1, c.reagentEntries[1].have)   -- coalesced into the next frame
      W.advance(0)
      assert.same({ RED, 2 }, { count_color(c.coverSlots[1]), c.reagentEntries[1].have })
      -- the list hides: not listening, nothing recomputed
      local box = form.orderScrollBox
      form.raw(box):Hide(); box:GetScript("OnHide")(box)
      assert.is_false(listening())
      owned[1001] = 9
      W.fire("BAG_UPDATE_DELAYED"); W.advance(0)
      assert.same({ "reagents", 2 }, { c.coverMode, c.reagentEntries[1].have })   -- untouched
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
    it("gives both covers' content the strip's strength 0.6 over a dark overlay, and keeps the covers opaque", function()
      boot()
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      local raw = order({ expirationTime = 5100, orderType = 3, npcOrderRewards = { item_reward(2001, 1) } })
      local row = row_for(raw)
      show_board({ raw })
      local c = cells_of(row)
      assert.same({ 1, 1, 1, 1, 1, false, false }, { c.strip:GetAlpha(), c.tipCover:GetAlpha(), c.tipContent:GetAlpha(),
        c.cover:GetAlpha(), c.coverContent:GetAlpha(), c.coverDim:IsShown(), c.tipDim:IsShown() })
      ns.FS:GetModule("Orders"):Settings().filters.hideRisks.expiringSoon = true
      ns.FS:SendMessage("FS_ORDERS_CHANGED")
      assert.is_true(c.dimmed)
      -- the cover itself stays opaque (Blizzard's word must not show through); its icons are at 60% like the strip's
      assert.same({ 0.6, 1, 0.6, 1, 0.6, true, true }, { c.strip:GetAlpha(), c.tipCover:GetAlpha(), c.tipContent:GetAlpha(),
        c.cover:GetAlpha(), c.coverContent:GetAlpha(), c.coverDim:IsShown(), c.tipDim:IsShown() })
      assert.same({ 0, 0, 0 }, { c.coverDim.color[1], c.coverDim.color[2], c.coverDim.color[3] })
      assert.same({ 0, 0, 0 }, { c.tipDim.color[1], c.tipDim.color[2], c.tipDim.color[3] })
    end)
    it("shows a recycled row's new order's icons only", function()
      boot()
      local first = order({ orderID = 10, orderType = 3, npcOrderRewards = { item_reward(2001, 2), item_reward(2002, 1) } })
      local second = order({ orderID = 11, orderType = 3, npcOrderRewards = { { currencyType = 3001, count = 4 } } })
      evalResult = allocation({ itemID = 1001, quantity = 3 })
      show_board({ first, second })
      local row = form.newOrderRow(geometry(10))
      form.acquireOrderRow(row, form.orderElement(first), true)
      local c = cells_of(row)
      assert.same({ 2, 1 }, { #shown(c.tipSlots), #shown(c.coverSlots) })
      form.releaseOrderRow(row)
      assert.same({ false, false, false }, { c.frame:IsShown(), c.cover:IsShown(), c.tipCover:IsShown() })
      form.acquireOrderRow(row, form.orderElement(second), false)
      assert.same({ { i = 1, file = 700001, count = "4" } }, shown(c.tipSlots))
      assert.equal("45g", c.tipAmount:GetText())
      assert.same({ { i = 1, file = 901001, count = "3" } }, shown(c.coverSlots))
      assert.is_false(c.tipMore:IsShown())
      -- a count shown for the last order is gone when the next one needs none
      local third = order({ orderID = 12, orderType = 3, npcOrderRewards = { item_reward(2002, 1) } })
      evalResult = allocation()
      show_board({ first, second, third })
      form.releaseOrderRow(row)
      form.acquireOrderRow(row, form.orderElement(third), false)
      assert.same({ { i = 1, file = 902002, count = nil } }, shown(c.tipSlots))
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
      local one, two, cover3 = c.tipSlots[1].icon, c.tipSlots[2].icon, c.coverSlots[3].icon
      form.releaseOrderRow(row)
      evalResult = slots_needed(1)
      show_board({ first, second })
      form.acquireOrderRow(row, form.orderElement(second), false)
      assert.same({ true, true, 2, 3 }, { c.tipSlots[1].icon == one, c.tipSlots[2].icon == two, #c.tipSlots, #c.coverSlots })
      assert.same({ true, false, false }, { one:IsShown(), two:IsShown(), cover3:IsShown() })
    end)
  end)

  describe("the cover keeps the row's tint and hover highlight", function()
    local VIP, BLOCKED, REPEAT = { 1, 0.82, 0, 0.18 }, { 1, 0.1, 0.1, 0.25 }, { 0.3, 0.7, 1, 0.12 }
    local function setup()
      boot()
      local raw = order()
      show_board({ raw })
      return raw, cells_of(row_for(raw))
    end

    it("paints the row's tint on the cover too: VIP, blocked, repeat, and none", function()
      local _, c = setup()
      local C = ns.FS:GetModule("Customers")
      assert.is_false(c.coverTint:IsShown())
      C:SetTag("Bob-Silvermoon", "VIP", true)
      assert.same({ true, VIP }, { c.coverTint:IsShown(), c.coverTint.color })
      C:SetTag("Bob-Silvermoon", "VIP", false)
      C:RecordOrder("Bob-Silvermoon", { orderID = 1 }); C:RecordOrder("Bob-Silvermoon", { orderID = 2 })
      assert.same({ true, REPEAT }, { c.coverTint:IsShown(), c.coverTint.color })
      C:SetTag("Bob-Silvermoon", "blocked", true)
      assert.same({ true, BLOCKED }, { c.coverTint:IsShown(), c.coverTint.color })
      assert.same(c.tintColor, c.coverTint.color)
      C:SetTag("Bob-Silvermoon", "blocked", false)
      C:RecordOrder("Bob-Silvermoon", { orderID = 3 })   -- still a repeat customer
      C:SetTag("Bob-Silvermoon", "VIP", true); C:SetTag("Bob-Silvermoon", "VIP", false)
      assert.is_true(c.coverTint:IsShown())
    end)
    it("lights the cover while the row is hovered, and only then", function()
      local _, c = setup()
      local row = c.hoverRow
      assert.is_false(c.coverHover:IsShown())
      form.raw(row):GetScript("OnEnter")(row)
      assert.is_true(c.coverHover:IsShown())
      form.raw(row):GetScript("OnLeave")(row)
      assert.is_false(c.coverHover:IsShown())
    end)
    it("paints the tint and lights the Commission cover the same way", function()
      local _, c = setup()
      local C = ns.FS:GetModule("Customers")
      assert.is_false(c.tipTint:IsShown())
      C:SetTag("Bob-Silvermoon", "VIP", true)
      assert.same({ true, VIP }, { c.tipTint:IsShown(), c.tipTint.color })
      C:SetTag("Bob-Silvermoon", "VIP", false); C:SetTag("Bob-Silvermoon", "blocked", true)
      assert.same({ true, BLOCKED }, { c.tipTint:IsShown(), c.tipTint.color })
      C:SetTag("Bob-Silvermoon", "blocked", false)
      assert.is_false(c.tipTint:IsShown())
      local row = c.hoverRow
      form.raw(row):GetScript("OnEnter")(row)
      assert.same({ true, true }, { c.coverHover:IsShown(), c.tipHover:IsShown() })
      form.raw(row):GetScript("OnLeave")(row)
      assert.same({ false, false }, { c.coverHover:IsShown(), c.tipHover:IsShown() })
      c.tipCover:GetScript("OnEnter")(c.tipCover)   -- the pointer on this cover lights it, not the other one
      form.raw(row):GetScript("OnLeave")(row)
      assert.same({ false, true }, { c.coverHover:IsShown(), c.tipHover:IsShown() })
      c.tipCover:GetScript("OnLeave")(c.tipCover)
      assert.is_false(c.tipHover:IsShown())
    end)
    it("lights the cover while the pointer is on it, even when the row reports leaving", function()
      local _, c = setup()
      local row = c.hoverRow
      form.raw(row):GetScript("OnEnter")(row)
      c.cover:GetScript("OnEnter")(c.cover)
      form.raw(row):GetScript("OnLeave")(row)   -- the row loses the pointer to our cover
      assert.is_true(c.coverHover:IsShown())
      c.cover:GetScript("OnLeave")(c.cover)
      assert.is_false(c.coverHover:IsShown())
    end)
    it("hooks the row once per row frame, however often it is recycled, and writes nothing on it", function()
      boot()
      local raw = order()
      show_board({ raw })
      local row = form.newOrderRow(geometry(10))
      form.acquireOrderRow(row, form.orderElement(raw), true)
      form.releaseOrderRow(row)
      form.acquireOrderRow(row, form.orderElement(raw), false)
      local c = cells_of(row)
      local lit, show = 0, c.coverHover.Show
      c.coverHover.Show = function(self) lit = lit + 1; return show(self) end
      form.raw(row):GetScript("OnEnter")(row)
      assert.equal(1, lit)   -- one handler, not one per recycle
      assert.same({}, form.assignedFields)
    end)
    it("forgets a hover that ended while the row was recycled", function()
      local _, c = setup()
      local row = c.hoverRow
      form.raw(row):GetScript("OnEnter")(row)
      form.releaseOrderRow(row)
      assert.is_false(c.coverHover:IsShown())
    end)
    it("runs the strip's and the cover's leave handlers through the guard", function()
      local _, c = setup()
      _G.GameTooltip = { SetOwner = function() end, GetOwner = function() end, Hide = function() error("boom") end }
      c.tipCover:GetScript("OnLeave")(c.tipCover)
      assert.is_false(rows():IsEnabled())
      assert.is_true(ns.FS:GetModule("OrdersSidePanel"):IsEnabled())
    end)
    it("turns off only OrdersRowAddons when a hover handler fails", function()
      local _, c = setup()
      c.coverHover.Show = function() error("boom") end
      local row = c.hoverRow
      form.raw(row):GetScript("OnEnter")(row)
      assert.is_false(rows():IsEnabled())
      assert.is_true(ns.FS:GetModule("OrdersSidePanel"):IsEnabled())
    end)
  end)

  describe("leave handlers and raising game calls", function()
    local function failing_tooltip()
      _G.GameTooltip = { SetOwner = function() end, GetOwner = function() end, SetText = function() end,
        AddLine = function() end, Show = function() end, Hide = function() error("boom") end }
    end
    local function plain_cells()
      boot()
      local raw = order()
      show_board({ raw })
      return cells_of(row_for(raw))
    end

    it("runs the Add button's leave handler through the guard", function()
      local c = plain_cells()
      failing_tooltip()
      c.add:GetScript("OnLeave")(c.add)
      assert.is_false(rows():IsEnabled())
      assert.is_true(ns.FS:GetModule("OrdersSidePanel"):IsEnabled())
      assert.equal(1, #ns.FS.db.global.diagnostics.errors)
    end)
    it("runs the risk cell's leave handler through the guard", function()
      local c = plain_cells()
      failing_tooltip()
      c.risk:GetScript("OnLeave")(c.risk)
      assert.is_false(rows():IsEnabled())
      assert.equal(1, #ns.FS.db.global.diagnostics.errors)
    end)
    it("hides the tooltip on leave when nothing fails", function()
      local c = plain_cells()
      tooltip.shown = true
      c.add:GetScript("OnLeave")(c.add)
      assert.is_false(tooltip.shown)
      tooltip.shown = true
      c.risk:GetScript("OnLeave")(c.risk)
      assert.is_false(tooltip.shown)
      assert.is_true(rows():IsEnabled())
    end)

    -- A raising game call reads as no answer: for every pcall'd call the row's state when it raises equals its state
    -- when it returns nothing. mode "nil" | "raise"; hits counts how often the call was made, so a case cannot pass
    -- because the code never asked. arm(mode, row) runs once the row is shown and its concentration view is set;
    -- case.after (optional) runs once the call stops raising.
    local hits
    local function stub(mode, nilResult)
      return function()
        hits = hits + 1
        if mode == "raise" then error("boom") end
        return nilResult
      end
    end
    local function scanner() return ns.FS:GetModule("Scanner") end
    local function refresh()
      ns.FS:SendMessage("FS_ORDERS_CHANGED")
      W.fire("GET_ITEM_INFO_RECEIVED", 1001, true); W.advance(0)
    end
    local RAISING = {
      { name = "C_Item.GetItemIconByID", arm = function(mode) C_Item.GetItemIconByID = stub(mode) end },
      { name = "GetItemIcon", arm = function(mode)
          C_Item.GetItemIconByID = nil; _G.GetItemIcon = stub(mode)
        end },
      { name = "C_CurrencyInfo.GetCurrencyInfo", arm = function(mode)
          C_TradeSkillUI.GetConcentrationCurrencyID = function() return 3333 end
          C_CurrencyInfo.GetCurrencyInfo = stub(mode)
        end,
        after = function()
          C_CurrencyInfo.GetCurrencyInfo = function(id) if id == 3333 then return { iconFileID = 654321 } end end
        end, icon = 654321 },
      { name = "C_TradeSkillUI.GetConcentrationCurrencyID", arm = function(mode)
          C_TradeSkillUI.GetConcentrationCurrencyID = stub(mode, 0)
        end,
        after = function()
          C_TradeSkillUI.GetConcentrationCurrencyID = function() return 3333 end
          C_CurrencyInfo.GetCurrencyInfo = function(id) if id == 3333 then return { iconFileID = 654321 } end end
        end, icon = 654321 },
      { name = "Scanner:GetSchematic", arm = function(mode) scanner().GetSchematic = stub(mode) end },
      { name = "Orders:BuildContext", arm = function(mode)
          ns.FS:GetModule("Orders").BuildContext = stub(mode)
        end },
      { name = "SetMouseClickEnabled and SetMouseMotionEnabled", pre = function(mode)
          local create = _G.CreateFrame
          _G.CreateFrame = function(...)
            local frame = create(...)
            frame.SetMouseClickEnabled = stub(mode)
            frame.SetMouseMotionEnabled = stub(mode)
            return frame
          end
        end },
      { name = "the header container's GetChildren", arm = function(mode)
          form.raw(form.orderList).HeaderContainer.GetChildren = stub(mode)
        end },
      { name = "a header's GetText", arm = function(mode)
          -- the text is only read when the game names the header strings
          _G.PROFESSIONS_COLUMN_HEADER_REAGENTS, _G.PROFESSIONS_COLUMN_HEADER_TIP = "Reagents", "Commission"
          for _, header in ipairs(headers) do header.GetText = stub(mode) end
        end },
    }

    local function observed(c)
      local counts = {}
      for _, pool in ipairs({ c.tipSlots, c.coverSlots }) do
        for _, slot in ipairs(pool) do counts[#counts + 1] = slot.count:IsShown() and slot.count:GetText() or false end
      end
      local point, _, relPoint, x, y = c.cover:GetPoint(1)   -- not the frame: the two runs have their own
      local lines = {}
      for _, region in ipairs({ c.tipCover, c.cover }) do
        region:GetScript("OnEnter")(region)
        lines[#lines + 1] = tooltip.lines
        region:GetScript("OnLeave")(region)
      end
      return { files_of(c.tipSlots), files_of(c.coverSlots), counts, c.cover:IsShown(), { point, relPoint, x, y },
        c.tipCover:IsShown(), c.concIcon:GetTexture(), c.concText:GetText(), lines }
    end

    it("reads a raising game call as no answer", function()
      for _, case in ipairs(RAISING) do
        local states = {}
        for _, mode in ipairs({ "nil", "raise" }) do
          boot()
          hits = 0
          if case.pre then case.pre(mode) end
          evalResult = allocation({ itemID = 1001, quantity = 3 }, { itemID = 1002, quantity = 1 })
          local raw = order({ orderType = 3, npcOrderRewards = { item_reward(2001, 3), { currencyType = 3001, count = 2 } } })
          show_board({ raw })
          local row = row_for(raw)
          local view = ns.FS:GetModule("Orders"):GetView(10)
          view.usedConcentration, view.concentrationCost = true, 120
          if case.arm then case.arm(mode, row) end
          refresh()
          states[mode] = observed(cells_of(row))
          if mode == "raise" then
            assert.is_true(hits > 0, case.name .. " was never called")
            assert.same({}, ns.FS.db.global.diagnostics.errors, case.name)
            assert.is_true(rows():IsEnabled(), case.name)
          end
          if case.after and mode == "raise" then
            case.after()
            refresh()
            -- nothing was cached from the failed answers: the currency's own icon shows once it answers
            assert.equal(case.icon, cells_of(row).concIcon:GetTexture(), case.name)
          end
          _G.GetItemIcon, _G.PROFESSIONS_COLUMN_HEADER_REAGENTS, _G.PROFESSIONS_COLUMN_HEADER_TIP = nil, nil, nil
        end
        assert.are.same(states["nil"], states["raise"], case.name)
        -- the state compared is a real one: two reward icons, two reagent icons, the concentration cell filled in
        assert.same({ 2, 2, "120" }, { #states["nil"][1], #states["nil"][2], states["nil"][8] }, case.name)
      end
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
    it("IconLayout counts the slots that fit, with a +N slot of its own width", function()
      boot()
      local P = ns.UI.OrdersPanel
      local entries = { {}, {}, {}, {} }
      assert.same({ shown = 4, width = strip_width(4) }, P.IconLayout(entries, nil))
      assert.same({ shown = 4, width = strip_width(4) }, P.IconLayout(entries, strip_width(4)))
      assert.same({ shown = 2, more = 2, width = with_more(2) }, P.IconLayout(entries, strip_width(4) - 1))   -- 2 icons + "+2"
      assert.same({ shown = 0, more = 4, width = MW }, P.IconLayout(entries, MW))
      assert.same({ shown = 0, width = 0 }, P.IconLayout(entries, MW - 1))
      assert.same({ shown = 0, width = 0 }, P.IconLayout({}, 100))
    end)
  end)
end)
