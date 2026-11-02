-- MerchantBuy (phase 7 Task 17): the queue's missing vendor reagents, one batch per click.
-- Main-Realm is the logged-in character, Alt-Realm the other one. The merchant is a small model: `listings[index]`
-- (itemID, price per purchase, stack = items per purchase, available = numAvailable, purchasable, extended, maxStack)
-- behind GetMerchantNumItems / GetMerchantItemID / C_MerchantFrame.GetItemInfo / GetMerchantItemMaxStack. The wow_stubs
-- BuyMerchantItem records every call in W.bought; this spec wraps it so the items reach the bags (world.items) once
-- `deliver` is on, as the game does before the next bag update.
describe("MerchantBuy", function()
  local ns, W, world, MB, Q
  local ME, ALT = "Main-Realm", "Alt-Realm"
  local listings, gold, deliver, requiredItems, pending, tooltip, bags

  local function install_merchant()
    listings, gold, deliver, bags = {}, 1000000, true, {}
    -- The game's own count: the bags below (not world.items, which the Scanner's bag scan rewrites from the empty
    -- containers) plus the warband bank when asked.
    C_Item.GetItemCount = function(itemID, _, _, _, includeAccountBank)
      return (bags[itemID] or 0) + (includeAccountBank and (world.warband[itemID] or 0) or 0)
    end
    _G.GetMerchantNumItems = function() return #listings end
    _G.GetMerchantItemID = function(index) return listings[index] and listings[index].itemID end
    C_MerchantFrame.GetItemInfo = function(index)
      local l = listings[index]
      if not l then return nil end
      return { name = "Listing " .. index, price = l.price, stackCount = l.stack or 1,
        numAvailable = l.available or -1, isPurchasable = l.purchasable ~= false, hasExtendedCost = l.extended or false }
    end
    _G.GetMerchantItemMaxStack = function(index) return listings[index] and listings[index].maxStack or 20 end
    _G.GetMoney = function() return gold end
    local record = _G.BuyMerchantItem
    _G.BuyMerchantItem = function(index, quantity)
      record(index, quantity)
      local l = listings[index]
      if deliver and l then bags[l.itemID] = (bags[l.itemID] or 0) + quantity end
    end
  end

  -- A listing at the next merchant index.
  local function sell(itemID, price, opts)
    local l = opts or {}
    l.itemID, l.price = itemID, price
    listings[#listings + 1] = l
    return #listings
  end

  -- The queue needs n more of itemID for Main-Realm (one entry of recipe 9001, whose evaluation is faked).
  local function required(itemID, n)
    requiredItems[#requiredItems + 1] = { slotIndex = #requiredItems + 1, itemID = itemID, quantity = n }
    world.fakeEvaluate(9001, { allocation = requiredItems, reagentCost = 100, flags = {} })
    if #Q:GetEntries() == 0 then Q:Add({ recipeID = 9001, quantity = 1, charKey = ME }) end
  end
  local function held(itemID, n) bags[itemID] = n end
  local function bought_total(itemID)
    local n = 0
    for _, call in ipairs(W.bought) do
      if listings[call.index].itemID == itemID then n = n + call.quantity end
    end
    return n
  end

  local function view() return MB.view end
  local function open() W.fire("MERCHANT_SHOW") end
  local function click() view().button:GetScript("OnClick")() end

  -- The pending Debounce keys (installed after the boot: MerchantBuy's own keys come later).
  local function spy_debounces()
    pending = {}
    local debounce, cancel = ns.FS.Debounce, ns.FS.CancelDebounce
    ns.FS.Debounce = function(self, key, seconds, fn)
      pending[key] = true
      return debounce(self, key, seconds, function(...) pending[key] = nil; return fn(...) end)
    end
    ns.FS.CancelDebounce = function(self, key) pending[key] = nil; return cancel(self, key) end
  end

  before_each(function()
    ns, W, world = make_world({ last = "UI/MerchantBuy.lua" })
    MB, Q = ns.FS:GetModule("MerchantBuy"), ns.FS:GetModule("Queue")
    requiredItems = {}
    install_merchant()
    spy_debounces()
    tooltip = nil
    _G.GameTooltip = { SetOwner = function() end, SetText = function(_, text) tooltip = text end,
      Show = function() end, Hide = function() tooltip = nil end }
  end)

  after_each(function() _G.GameTooltip = nil end)

  it("is a toggleable module", function()
    assert.is_truthy(MB); assert.is_falsy(MB.coreModule); assert.is_true(MB:IsEnabled())
  end)

  describe("Plan", function()
    it("rounds up to the merchant's stack size", function()
      required(1001, 7); local index = sell(1001, 500, { stack = 5 })
      local plan = MB:Plan()
      assert.same({ { index = index, itemID = 1001, need = 7, buy = 10, unitPrice = 100, cost = 1000 } }, plan.rows)
      assert.equals(1000, plan.total); assert.is_true(plan.affordable)
    end)

    it("lists rows by merchant index and totals them", function()
      required(1001, 3); required(2002, 2)
      sell(9999, 10); sell(2002, 40); sell(1001, 7)
      local plan = MB:Plan()
      assert.same({ 2, 3 }, { plan.rows[1].index, plan.rows[2].index })
      assert.same({ 2002, 1001 }, { plan.rows[1].itemID, plan.rows[2].itemID })
      assert.equals(2 * 40 + 3 * 7, plan.total)
    end)

    it("takes the shortfall from the Queue's missing reagents", function()
      required(1001, 6); required(2002, 4); required(3001, 2)
      held(1001, 2); held(2002, 4); sell(1001, 5); sell(2002, 5); sell(3001, 5)
      local missing = Q:GetMissingReagents(ME)
      local plan = MB:Plan()
      assert.same({ 1001, 3001 }, { plan.rows[1].itemID, plan.rows[2].itemID })
      for _, row in ipairs(plan.rows) do assert.equals(missing[row.itemID], row.need) end
      assert.equals(4, plan.rows[1].need); assert.equals(2, plan.rows[2].need)
    end)

    it("buys only this character's missing reagents", function()
      required(1001, 3)
      Q:Add({ recipeID = 9001, quantity = 1, charKey = ALT })       -- the same recipe for the alt: the same reagents
      assert.equals(2, #Q:GetEntries())
      sell(1001, 5); sell(7777, 5)
      world.fakeEvaluate(9001, function(charKey)
        if charKey == ALT then return { allocation = { { slotIndex = 1, itemID = 7777, quantity = 4 } }, reagentCost = 1, flags = {} } end
        return { allocation = requiredItems, reagentCost = 100, flags = {} }
      end)
      local plan = MB:Plan()
      assert.equals(1, #plan.rows); assert.equals(1001, plan.rows[1].itemID); assert.equals(3, plan.rows[1].buy)
      open(); click()
      assert.equals(3, bought_total(1001)); assert.equals(0, bought_total(7777))
    end)

    it("leaves out what the character already holds, the warband bank included", function()
      required(1001, 5); required(2002, 5); sell(1001, 5); sell(2002, 5)
      held(1001, 5); world.warband[2002] = 5
      assert.same({}, MB:Plan().rows)
    end)

    it("skips extended-cost, sold-out, unpurchasable and free listings", function()
      for _, id in ipairs({ 1001, 1002, 2001, 2002, 3001 }) do required(id, 2) end
      sell(1001, 5, { extended = true }); sell(1002, 5, { available = 0 }); sell(2001, 5, { purchasable = false })
      sell(2002, 0); local ok = sell(3001, 5)
      local plan = MB:Plan()
      assert.same({ ok }, { plan.rows[1].index }); assert.equals(1, #plan.rows)
    end)

    it("takes a later listing of an item whose first listing is skipped, and buys an item once", function()
      required(1001, 3)
      sell(1001, 5, { extended = true }); local second = sell(1001, 6); sell(1001, 4)
      local plan = MB:Plan()
      assert.equals(1, #plan.rows); assert.equals(second, plan.rows[1].index)
    end)

    it("caps the buy at what the vendor has, in stacks", function()
      required(1001, 30); required(2002, 30)
      sell(1001, 5, { available = 4 }); sell(2002, 5, { stack = 5, available = 2 })
      local plan = MB:Plan()
      assert.equals(4, plan.rows[1].buy); assert.equals(10, plan.rows[2].buy)
      assert.equals(4 * 5 + 2 * 5, plan.total)
    end)

    it("treats a numAvailable of -1 as unlimited", function()
      required(1001, 30); sell(1001, 5, { available = -1 })
      assert.equals(30, MB:Plan().rows[1].buy)
    end)

    it("leaves out an item the game cannot count", function()
      required(1001, 3); required(2002, 3); sell(1001, 5); sell(2002, 5)
      local count = C_Item.GetItemCount
      C_Item.GetItemCount = function(itemID, ...) if itemID == 1001 then return nil end return count(itemID, ...) end
      local plan = MB:Plan()
      assert.equals(1, #plan.rows); assert.equals(2002, plan.rows[1].itemID)
    end)

    it("is not affordable with too little gold, or with gold the game cannot tell", function()
      required(1001, 4); sell(1001, 500)
      gold = 1999; assert.is_false(MB:Plan().affordable)
      gold = 2000; assert.is_true(MB:Plan().affordable)
      _G.GetMoney = function() return nil end
      assert.is_false(MB:Plan().affordable)
      listings = {}; assert.is_true(MB:Plan().affordable)
    end)

    it("falls back to GetMerchantItemInfo", function()
      required(1001, 7); required(2002, 3); required(3001, 3)
      sell(1001, 500, { stack = 5, available = 3 }); sell(2002, 9, { extended = true }); sell(3001, 7, { available = 0 })
      _G.C_MerchantFrame = nil
      _G.GetMerchantItemInfo = function(index)
        local l = listings[index]
        return "name", "texture", l.price, l.stack or 1, l.available or -1, l.purchasable ~= false, true, l.extended or false
      end
      local plan = MB:Plan()
      assert.equals(1, #plan.rows)
      assert.same({ itemID = 1001, need = 7, buy = 10, unitPrice = 100, cost = 1000 },
        { itemID = plan.rows[1].itemID, need = plan.rows[1].need, buy = plan.rows[1].buy,
          unitPrice = plan.rows[1].unitPrice, cost = plan.rows[1].cost })
    end)

    -- Never assume gold-only or a stack of 1: a listing whose info lacks either is not bought.
    local function info_of(fields)
      return function(index)
        local l = listings[index]
        if not l then return nil end
        local info = { price = l.price, stackCount = l.stack or 1, numAvailable = l.available or -1,
          isPurchasable = true, hasExtendedCost = false }
        for k, v in pairs(fields) do
          if v == "nil" then info[k] = nil else info[k] = v end
        end
        return info
      end
    end

    it("skips a listing whose hasExtendedCost is missing or true", function()
      required(1001, 3); sell(1001, 5)
      C_MerchantFrame.GetItemInfo = info_of({ hasExtendedCost = "nil" })
      assert.same({}, MB:Plan().rows)
      C_MerchantFrame.GetItemInfo = info_of({ hasExtendedCost = true })
      assert.same({}, MB:Plan().rows)
      C_MerchantFrame.GetItemInfo = info_of({ hasExtendedCost = false })
      assert.equals(1, #MB:Plan().rows)
      open()
      C_MerchantFrame.GetItemInfo = info_of({ hasExtendedCost = "nil" })
      assert.same({ status = "nothing" }, MB:Buy())
      assert.same({}, W.bought)
    end)

    it("skips a listing whose stackCount is not a positive whole number", function()
      required(1001, 3); sell(1001, 5)
      for _, bad in ipairs({ "nil", 0, -1, 2.5, "5", 0 / 0 }) do
        C_MerchantFrame.GetItemInfo = info_of({ stackCount = bad })
        assert.same({}, MB:Plan().rows, tostring(bad))
      end
      C_MerchantFrame.GetItemInfo = info_of({ stackCount = 1 })
      assert.equals(1, #MB:Plan().rows)
      open()
      C_MerchantFrame.GetItemInfo = info_of({ stackCount = "nil" })
      assert.same({ status = "nothing" }, MB:Buy())
      assert.same({}, W.bought)
    end)

    it("skips a GetMerchantItemInfo listing whose extended-cost or quantity return is missing", function()
      required(1001, 3); sell(1001, 5)
      _G.C_MerchantFrame = nil
      local ext, qty = false, 1
      _G.GetMerchantItemInfo = function() return "name", "texture", 5, qty, -1, true, true, ext end
      assert.equals(1, #MB:Plan().rows)
      ext = nil; assert.same({}, MB:Plan().rows)
      ext, qty = false, nil; assert.same({}, MB:Plan().rows)
      ext, qty = true, 1; assert.same({}, MB:Plan().rows)
    end)

    it("never buys the not-required socket slot", function()
      ns, W, world = make_world({ last = "UI/MerchantBuy.lua", intermediates = true, calibrate = { [ME] = { 9100 } } })
      MB, Q, requiredItems = ns.FS:GetModule("MerchantBuy"), ns.FS:GetModule("Queue"), {}
      install_merchant(); spy_debounces()
      local slot = world.schematics[9100].reagentSlots[1]
      world.schematics[9100].reagentSlots[2] = { slotIndex = 2, required = false, automatic = true, quantity = 1,
        reagents = { 4001 }, kind = "basic", dataSlotIndex = 22, dataSlotType = 1, hidden = false }
      assert.equals(1101, slot.reagents[1])
      ns.FS:SendMessage("FS_RECIPES_CHANGED")
      Q:Add({ recipeID = 9100, quantity = 3, charKey = ME })
      sell(4001, 5); local ok = sell(1101, 7)
      local plan = MB:Plan()
      assert.equals(1, #plan.rows); assert.equals(ok, plan.rows[1].index); assert.equals(6, plan.rows[1].need)
      open(); MB:Buy()
      assert.equals(0, bought_total(4001)); assert.equals(6, bought_total(1101))
    end)

    it("is empty without the merchant listing calls", function()
      required(1001, 3); sell(1001, 5)
      _G.GetMerchantItemID = nil
      assert.same({ rows = {}, total = 0, affordable = true }, MB:Plan())
    end)
  end)

  describe("Buy", function()
    it("rounds up to the merchant's stack size", function()
      required(1001, 7); sell(1001, 500, { stack = 5 })
      open()
      assert.same({ status = "bought", count = 10, cost = 1000 }, MB:Buy())
      assert.same({ { index = 1, quantity = 10 } }, W.bought)
    end)

    it("buys nothing when the gold on hand is short", function()
      required(1001, 4); sell(1001, 500); gold = 1999
      open()
      assert.same({ status = "poor" }, MB:Buy())
      assert.same({}, W.bought)
    end)

    it("splits a buy into max-stack calls", function()
      required(1001, 45); sell(1001, 2, { maxStack = 20 })
      required(2002, 40); sell(2002, 10, { stack = 5, maxStack = 18 })    -- 18 rounds down to 15: 15 + 15 + 10
      open()
      assert.same({ status = "bought", count = 45 + 40, cost = 45 * 2 + 8 * 10 }, MB:Buy())
      assert.same({ { index = 1, quantity = 20 }, { index = 1, quantity = 20 }, { index = 1, quantity = 5 },
        { index = 2, quantity = 15 }, { index = 2, quantity = 15 }, { index = 2, quantity = 10 } }, W.bought)
    end)

    it("buys at least one stack per call when the max stack is smaller", function()
      required(1001, 10); sell(1001, 10, { stack = 5, maxStack = 3 })
      open(); MB:Buy()
      assert.same({ { index = 1, quantity = 5 }, { index = 1, quantity = 5 } }, W.bought)
    end)

    it("makes at most 20 calls per click and finishes on the next", function()
      required(1001, 30); sell(1001, 2, { maxStack = 1 })
      open()
      assert.same({ status = "bought", count = 20, cost = 40 }, MB:Buy())
      assert.equals(20, #W.bought)
      W.fire("BAG_UPDATE_DELAYED")
      assert.same({ status = "bought", count = 10, cost = 20 }, MB:Buy())
      assert.equals(30, #W.bought); assert.equals(30, bought_total(1001))
      W.fire("BAG_UPDATE_DELAYED")
      assert.same({ status = "nothing" }, MB:Buy())
    end)

    it("shows what arrived once the lock is released, by bag update or by timeout", function()
      required(1001, 6); sell(1001, 10, { maxStack = 3 }); deliver = false
      open(); click()
      held(1001, 3); W.fire("BAG_UPDATE_DELAYED")
      assert.is_false(view().buttonEnabled)            -- still locked
      held(1001, 6); W.fire("BAG_UPDATE_DELAYED")
      assert.equals("Bought 6 reagents for " .. ns.UI.FormatMoney(60), view().status:GetText())
    end)

    it("buys only the shortfall, over repeated clicks", function()
      required(1001, 12); held(1001, 4); sell(1001, 3, { maxStack = 5 })
      open()
      MB:Buy(); W.fire("BAG_UPDATE_DELAYED"); MB:Buy(); W.fire("BAG_UPDATE_DELAYED")
      assert.equals(8, bought_total(1001))
      assert.same({ status = "nothing" }, MB:Buy())
    end)

    it("buys nothing on MERCHANT_SHOW", function()
      required(1001, 7); sell(1001, 500, { stack = 5 })
      open(); W.advance(1)
      assert.same({}, W.bought)
      assert.is_true(view().frame:IsShown())
      assert.is_true(view().buttonEnabled)
    end)

    it("buys nothing on a merchant or bag update, a queue change or combat ending", function()
      required(1001, 7); sell(1001, 500, { stack = 5 })
      open()
      W.fire("MERCHANT_UPDATE"); W.fire("BAG_UPDATE_DELAYED"); W.fire("PLAYER_REGEN_ENABLED"); W.fire("PLAYER_REGEN_DISABLED")
      ns.FS:SendMessage(ns.Msg.QUEUE_CHANGED); W.advance(5)
      assert.same({}, W.bought)
    end)

    it("refuses a second click before the bags update", function()
      required(1001, 7); sell(1001, 5); deliver = false
      open()
      assert.equals("bought", MB:Buy().status)
      assert.same({ status = "inFlight" }, MB:Buy())
      assert.equals(1, #W.bought)
      assert.is_true(pending["merchantBuy.flight"])
      held(1001, 7)                                   -- everything asked for has arrived
      W.fire("BAG_UPDATE_DELAYED")
      assert.is_nil(pending["merchantBuy.flight"])
      assert.same({ status = "nothing" }, MB:Buy())    -- and the shortfall is met
    end)

    it("keeps the lock while the bags update without the items asked for", function()
      required(1001, 7); sell(1001, 5); deliver = false
      open(); MB:Buy()
      W.fire("BAG_UPDATE_DELAYED")                     -- some other bag change
      assert.same({ status = "inFlight" }, MB:Buy())
      assert.equals(1, #W.bought)
    end)

    it("keeps the lock until purchases that arrive across two bag updates have both landed", function()
      required(1001, 10); sell(1001, 5, { maxStack = 5 }); required(2002, 4); sell(2002, 5); deliver = false
      open()
      assert.same({ status = "bought", count = 14, cost = 70 }, MB:Buy())
      assert.equals(3, #W.bought)
      held(1001, 5)
      W.fire("BAG_UPDATE_DELAYED")                     -- the first call has landed
      assert.same({ status = "inFlight" }, MB:Buy())
      held(1001, 10)
      W.fire("BAG_UPDATE_DELAYED")                     -- the second call, but not the other reagent
      assert.same({ status = "inFlight" }, MB:Buy())
      held(2002, 4)
      W.fire("BAG_UPDATE_DELAYED")                     -- all of it
      assert.is_nil(pending["merchantBuy.flight"])
      assert.equals(3, #W.bought)
      assert.same({ status = "nothing" }, MB:Buy())
      assert.equals(3, #W.bought)
    end)

    it("never buys what is still arriving a second time", function()
      required(1001, 10); sell(1001, 5, { maxStack = 5 }); deliver = false
      open(); click()
      held(1001, 5); W.fire("BAG_UPDATE_DELAYED")
      click()
      assert.equals(2, #W.bought)
      assert.equals(10, bought_total(1001))
    end)

    it("leaves the in-flight state after 3 s, even when nothing arrived", function()
      required(1001, 7); sell(1001, 5); deliver = false
      open(); MB:Buy()
      W.advance(2.9); assert.equals("inFlight", MB:Buy().status)
      W.advance(0.2); assert.equals("bought", MB:Buy().status)
    end)

    it("releases the lock at 3 s after a partial arrival", function()
      required(1001, 10); sell(1001, 5, { maxStack = 5 }); deliver = false
      open(); MB:Buy()
      held(1001, 5); W.fire("BAG_UPDATE_DELAYED")
      assert.equals("inFlight", MB:Buy().status)
      W.advance(3.1)
      assert.is_nil(pending["merchantBuy.flight"])
      assert.equals("bought", MB:Buy().status)         -- the shortfall is now 5
      assert.equals(5, W.bought[#W.bought].quantity)
    end)

    it("is closed without a merchant", function()
      required(1001, 7); sell(1001, 5)
      assert.same({ status = "closed" }, MB:Buy())
      open(); W.fire("MERCHANT_CLOSED")
      assert.same({ status = "closed" }, MB:Buy())
      assert.same({}, W.bought)
    end)

    it("is closed without the calls a buy needs", function()
      required(1001, 7); sell(1001, 5); open()
      for _, name in ipairs({ "BuyMerchantItem", "GetMerchantItemMaxStack", "GetMerchantNumItems", "GetMerchantItemID" }) do
        local saved = _G[name]; _G[name] = nil
        assert.same({ status = "closed" }, MB:Buy(), name)
        _G[name] = saved
      end
      assert.same({}, W.bought)
    end)

    it("refuses in combat", function()
      required(1001, 7); sell(1001, 5); open()
      _G.InCombatLockdown = function() return true end
      assert.same({ status = "combat" }, MB:Buy())
      assert.same({}, W.bought)
    end)

    it("says nothing when the merchant sells nothing the queue needs", function()
      required(1001, 7); sell(2002, 5); open()
      assert.same({ status = "nothing" }, MB:Buy())
      assert.same({}, W.bought)
    end)

    it("stops at a call that raises, and counts only the calls that went through", function()
      required(1001, 45); sell(1001, 2, { maxStack = 20 })
      local record = _G.BuyMerchantItem
      _G.BuyMerchantItem = function(index, quantity)
        if #W.bought >= 1 then error("the vendor said no") end
        record(index, quantity)
      end
      open()
      assert.same({ status = "bought", count = 20, cost = 40 }, MB:Buy())
      assert.equals(1, #W.bought)
    end)

    it("treats a count that was unknown at the buy as not arrived, without raising", function()
      required(1001, 7); sell(1001, 5); deliver = false
      local count, unknown = C_Item.GetItemCount, false
      C_Item.GetItemCount = function(itemID, ...)
        if unknown and itemID == 1001 then return nil end
        return count(itemID, ...)
      end
      _G.GetMerchantItemMaxStack = function() unknown = true; return 20 end   -- after the plan, before the count read
      open()
      assert.equals("bought", MB:Buy().status)
      unknown = false; held(1001, 7)
      W.fire("BAG_UPDATE_DELAYED")
      assert.same({ status = "inFlight" }, MB:Buy())     -- not confirmed: held until the timeout
      W.advance(3.1)
      assert.same({}, W.errors); assert.is_true(MB:IsEnabled())
      assert.equals("No reagents have arrived in your bags yet", view().status:GetText())
    end)

    it("buys nothing and leaves no lock when the first call raises", function()
      required(1001, 7); sell(1001, 5)
      local real = _G.BuyMerchantItem
      _G.BuyMerchantItem = function() error("no") end
      open()
      assert.same({ status = "nothing" }, MB:Buy())
      _G.BuyMerchantItem = real
      assert.equals("bought", MB:Buy().status)
    end)

    it("changes no saved data", function()
      required(1001, 7); sell(1001, 5); deliver = false
      local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
      open(); click(); W.fire("BAG_UPDATE_DELAYED"); W.fire("MERCHANT_CLOSED")
      assert.same(before, ns.Util.DeepCopy(ns.FS.db.global, 30))
    end)
  end)

  describe("panel", function()
    it("is shown on MERCHANT_SHOW only when the merchant sells something the queue needs", function()
      required(1001, 7); sell(2002, 5)
      open()
      assert.is_nil(view())
      sell(1001, 5); W.fire("MERCHANT_UPDATE"); W.advance(0.3)
      assert.is_true(view().frame:IsShown())
    end)

    it("lists up to six lines and the button with the total", function()
      for id = 1001, 1008 do required(id, 2); sell(id, 100) end
      world.names[1001] = "Iron"
      open()
      assert.equals(6, #view().lines)
      assert.equals("Iron: 2 for " .. ns.UI.FormatMoney(200), view().lines[1]:GetText())
      assert.equals("item:1002: 2 for " .. ns.UI.FormatMoney(200), view().lines[2]:GetText())
      assert.equals("Buy 16 reagents for " .. ns.UI.FormatMoney(1600), view().buttonText)
      assert.is_true(view().buttonEnabled)
    end)

    it("anchors outside MerchantFrame's top right, else to the top of the screen", function()
      required(1001, 7); sell(1001, 5)
      _G.MerchantFrame = CreateFrame("Frame", "MerchantFrame", UIParent)
      open()
      local point, rel, relPoint = view().frame:GetPoint(1)
      assert.same({ "TOPLEFT", _G.MerchantFrame, "TOPRIGHT" }, { point, rel, relPoint })
      _G.MerchantFrame = nil
      W.fire("MERCHANT_CLOSED"); open()
      point, rel, relPoint = view().frame:GetPoint(1)
      assert.same({ "TOP", UIParent, "TOP" }, { point, rel, relPoint })
    end)

    it("disables the button when the gold is short and says so in the tooltip", function()
      required(1001, 4); sell(1001, 500); gold = 100
      open()
      assert.is_false(view().buttonEnabled)
      view().button:GetScript("OnEnter")(view().button)
      assert.equals("Not enough gold", tooltip)
      view().button:GetScript("OnLeave")(view().button)
      assert.is_nil(tooltip)
      gold = 1000000; W.fire("BAG_UPDATE_DELAYED"); W.advance(0.3)
      assert.is_true(view().buttonEnabled)
      view().button:GetScript("OnEnter")(view().button)
      assert.is_nil(tooltip)
    end)

    it("disables the button in combat and while a buy is in flight", function()
      required(1001, 20); sell(1001, 5, { maxStack = 5 }); deliver = false
      open()
      _G.InCombatLockdown = function() return true end
      W.fire("PLAYER_REGEN_DISABLED"); assert.is_false(view().buttonEnabled)
      _G.InCombatLockdown = function() return false end
      W.fire("PLAYER_REGEN_ENABLED"); assert.is_true(view().buttonEnabled)
      click()
      assert.is_false(view().buttonEnabled)
      W.advance(3.1); assert.is_true(view().buttonEnabled)
    end)

    it("buys through the button, and says what arrived rather than what was asked", function()
      required(1001, 7); sell(1001, 500, { stack = 5 })
      open()
      click()
      assert.same({ { index = 1, quantity = 10 } }, W.bought)
      assert.equals("Buying 10 reagents for " .. ns.UI.FormatMoney(1000), view().status:GetText())
      assert.equals("Buying 10 reagents for " .. ns.UI.FormatMoney(1000), view().status:GetText())
      W.fire("BAG_UPDATE_DELAYED")
      assert.equals("Bought 10 reagents for " .. ns.UI.FormatMoney(1000), view().status:GetText())
      W.advance(0.3)
      assert.is_false(view().buttonEnabled)         -- nothing is left to buy
    end)

    it("says one reagent in the singular (review M2)", function()
      required(1001, 1); sell(1001, 500)
      open()
      assert.equals("Buy 1 reagent for " .. ns.UI.FormatMoney(500), view().buttonText)
      click()
      assert.equals("Buying 1 reagent for " .. ns.UI.FormatMoney(500), view().status:GetText())
      W.fire("BAG_UPDATE_DELAYED")
      assert.equals("Bought 1 reagent for " .. ns.UI.FormatMoney(500), view().status:GetText())
    end)

    it("does not say bought when nothing reached the bags", function()
      required(1001, 7); sell(1001, 500, { stack = 5 }); deliver = false
      open(); click()
      W.fire("BAG_UPDATE_DELAYED")
      assert.equals("Buying 10 reagents for " .. ns.UI.FormatMoney(1000), view().status:GetText())   -- still waiting
      W.advance(3.1)
      assert.equals("No reagents have arrived in your bags yet", view().status:GetText())
    end)

    it("counts only what arrived when a buy lands in part", function()
      required(1001, 10); sell(1001, 10, { stack = 1, maxStack = 5 }); deliver = false
      open(); click()
      held(1001, 5)
      W.fire("BAG_UPDATE_DELAYED")
      assert.equals("Buying 10 reagents for " .. ns.UI.FormatMoney(100), view().status:GetText())   -- 5 still to come
      W.advance(3.1)
      assert.equals("Bought 5 reagents for " .. ns.UI.FormatMoney(50), view().status:GetText())
    end)

    it("shows why nothing was bought", function()
      required(1001, 7); sell(1001, 5)
      open()
      _G.InCombatLockdown = function() return true end
      view().button:GetScript("OnClick")()
      assert.equals("Not in combat", view().status:GetText())
    end)

    it("redraws 0.2 s after a burst of merchant and bag updates", function()
      required(1001, 7); sell(1001, 5)
      open()
      sell(2002, 5); required(2002, 1)
      W.fire("MERCHANT_UPDATE"); W.fire("BAG_UPDATE_DELAYED"); W.fire("MERCHANT_UPDATE")
      assert.equals(1, #view().lines)
      assert.is_true(pending["merchantBuy.refresh"])
      W.advance(0.3)
      assert.equals(2, #view().lines)
    end)

    it("hides on MERCHANT_CLOSED, and a visit with nothing in flight starts fresh", function()
      required(1001, 7); sell(1001, 5)
      open()
      W.fire("MERCHANT_CLOSED")
      assert.is_false(view().frame:IsShown())
      assert.is_nil(pending["merchantBuy.refresh"])
      open()
      assert.is_true(view().frame:IsShown()); assert.equals("", view().status:GetText())
      assert.equals("bought", MB:Buy().status)
    end)

    it("keeps the lock across a close and a reopen while the items are still arriving", function()
      required(1001, 7); sell(1001, 5); deliver = false
      open(); click()
      W.fire("MERCHANT_CLOSED")
      assert.is_false(view().frame:IsShown())
      assert.is_true(pending["merchantBuy.flight"])      -- the lock's timer runs on
      open()
      assert.is_false(view().buttonEnabled)
      click()
      assert.same({ status = "closed" }, (function() W.fire("MERCHANT_CLOSED"); return MB:Buy() end)())
      open()
      assert.same({ status = "inFlight" }, MB:Buy())
      assert.equals(1, #W.bought)
    end)

    it("ends the lock by arrival while the merchant is closed", function()
      required(1001, 7); sell(1001, 5); deliver = false
      open(); click()
      W.fire("MERCHANT_CLOSED")
      held(1001, 7); W.fire("BAG_UPDATE_DELAYED")
      assert.is_nil(pending["merchantBuy.flight"])
      open()
      assert.same({ status = "nothing" }, MB:Buy())
      assert.equals(1, #W.bought)
    end)

    it("ends the lock at 3 s even when the merchant was closed and reopened", function()
      required(1001, 7); sell(1001, 5); deliver = false
      open(); click()
      W.advance(1); W.fire("MERCHANT_CLOSED"); W.advance(1); open()
      assert.same({ status = "inFlight" }, MB:Buy())
      W.advance(1.1)
      assert.equals("bought", MB:Buy().status)
    end)

    it("cancels its debounce keys, hides and drops its state on disable", function()
      required(1001, 70); sell(1001, 5, { maxStack = 5 }); deliver = false
      open(); click(); W.fire("MERCHANT_UPDATE")
      assert.is_true(pending["merchantBuy.flight"]); assert.is_true(pending["merchantBuy.refresh"])
      ns.FS:SetModuleEnabled("MerchantBuy", false)
      for key in pairs(pending) do assert.is_nil(key:match("^merchantBuy%."), key) end
      assert.is_false(view().frame:IsShown())
      assert.same({ status = "closed" }, MB:Buy())
      ns.FS:SetModuleEnabled("MerchantBuy", true)
      assert.same({ status = "closed" }, MB:Buy())    -- the open merchant was forgotten with the module
      open()
      assert.equals("bought", MB:Buy().status)        -- and so was the lock
    end)

    it("does nothing from the button once the module is off", function()
      required(1001, 7); sell(1001, 5); open()
      local onclick = view().button:GetScript("OnClick")
      ns.FS:SetModuleEnabled("MerchantBuy", false)
      onclick()
      assert.same({}, W.bought)
    end)
  end)
end)
