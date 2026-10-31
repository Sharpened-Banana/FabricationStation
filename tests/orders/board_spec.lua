local P2 = require("tests.helpers.phase2")

describe("Orders board", function()
  local ns, O, W, claimed, claimCalls, board
  before_each(function()
    claimed, claimCalls, board = nil, {}, {}
    ns, W = P2.boot({
      C_CraftingOrders = { GetCrafterOrders = function() return board end,   -- what Blizzard's board holds at click time
        GetCraftingOrderTime = function() return 5000 end, GetClaimedOrder = function() return claimed end,
        GetOrderClaimInfo = function() return {claimsRemaining = 3} end, ClaimOrder = function(id, p) claimCalls[#claimCalls+1] = {id, p} end },
      C_TradeSkillUI = { GetChildProfessionInfo = function() return {profession = 7} end,
        GetItemCraftedQualityByItemInfo = function() return 3 end } })
    P2.fake_module(ns, "Recipes", { Evaluate = function() return {expectedQuality=3, reagentCost=200000, flags={}} end, GetRanked = function() return {} end })
    P2.fake_module(ns, "Customers", { IsBlocked = function(_, n) return n == "Bad-Silvermoon" end,
      NormalizeName = function(_, n) return n and (n:find("-") and n or n .. "-Silvermoon") end })
    P2.fake_module(ns, "Prices", { Get = function() return {} end })
    P2.fake_module(ns, "Scanner", { GetSchematic = function() return {skillLineID = 2900} end, ProjectConcentration = function() return 500, 1000 end })
    P2.load(ns, {"Data/OrderRewards.lua", "Modules/Orders.lua"}); O = ns.FS:GetModule("Orders")
  end)
  it("replaces only the shown order type in the snapshot", function()
    O:OnBoardShown(0, { P2.raw_order({orderID=1, orderType=0}), P2.raw_order({orderID=2, orderType=0}) })
    O:OnBoardShown(2, { P2.raw_order({orderID=3}) })
    assert.equal(3, #O:GetSnapshot().orders)
    O:OnBoardShown(0, {})
    assert.equal(1, #O:GetSnapshot().orders); assert.equal(1000, O:GetSnapshot().time)
    assert.equal("Me-Silvermoon", O:GetSnapshot().charKey)
  end)
  it("applies a late customer name and re-flags a blocked customer", function()
    O:OnBoardShown(2, { P2.raw_order({customerName = P2.NIL}) })
    assert.same({}, O:GetView(777).risks)
    O:OnCustomerNameUpdated("CRAFTINGORDERS_UPDATE_CUSTOMER_NAME", "Bad", 777)
    assert.equal("Bad-Silvermoon", O:GetView(777).customer); assert.same({"blockedCustomer"}, O:GetView(777).risks)
  end)
  it("rescoring uses the snapshot character and GetSnapshot drops expired orders", function()
    O:OnBoardShown(2, { P2.raw_order({orderID=1}), P2.raw_order({orderID=2, expirationTime=4000}) })  -- expiresAt 0
    ns.FS.CharKey = function() return "Alt-Silvermoon" end; local s = spy.on(O, "BuildContext")
    O:Rescore()
    assert.spy(s).was.called_with(O, "Me-Silvermoon")
    assert.equal(1, #O:GetSnapshot().orders)
  end)
  it("debounces rescoring on bus messages", function()
    local s = spy.on(O, "Rescore")
    ns.FS:SendMessage("FS_PRICES_CHANGED", 2); ns.FS:SendMessage("FS_CUSTOMERS_CHANGED", "Bob-Silvermoon")
    W.advance(0.4); assert.spy(s).was_not.called(); W.advance(0.2); assert.spy(s).was.called(1)
  end)
  it("claims the best order once and refuses while one is claimed", function()
    board = { P2.raw_order({orderID=10, tipAmount=900000}), P2.raw_order({orderID=11}) }
    O:OnBoardShown(2, board)
    assert.equal(10, O:ClaimBest().orderID); assert.same({{10, 7}}, claimCalls)
    claimed = P2.raw_order({orderID=10})
    assert.same({nil, "alreadyClaimed"}, {O:ClaimBest()}); assert.equal(1, #claimCalls)
  end)
  it("sends FS_ORDER_FULFILLED on a successful fulfil response", function()
    claimed = P2.raw_order({outputItemHyperlink = "|Hitem:211111::|h[Potion]|h"})
    spy.on(O, "SendMessage")
    O:OnFulfillClicked(777, "", 7)
    O:OnFulfillResponse("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 10, 777)   -- CannotFulfill: nothing sent
    assert.spy(O.SendMessage).was_not.called()
    O:OnFulfillResponse("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 0, 777)
    assert.spy(O.SendMessage).was.called_with(O, "FS_ORDER_FULFILLED", {orderID=777, orderType="personal", customer="Bob-Silvermoon",
      recipeID=4444, itemID=211111, quality=3, tip=500000, consortiumCut=50000, commission=450000, rewards={}, rewardsValue=0, time=1000, charKey="Me-Silvermoon"})
  end)
  it("marks a recraft order's FulfilledOrder with isRecraft", function()
    claimed = P2.raw_order({isRecraft = true})
    spy.on(O, "SendMessage")
    O:OnFulfillClicked(777, "", 7)
    O:OnFulfillResponse("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 0, 777)
    local sent
    for _, call in ipairs(O.SendMessage.calls) do
      if call.vals[2] == "FS_ORDER_FULFILLED" then sent = call.vals[3] end
    end
    assert.is_true(sent.isRecraft)
  end)
  it("detects personal order arrivals after a baseline", function()
    local t = {profession=7, professionName="Tailoring"}
    assert.same({}, O:UpdatePersonalCounts({P2.merge(t, {numPersonalOrders=1})}))   -- first sighting is the baseline
    assert.same({}, O:UpdatePersonalCounts({P2.merge(t, {numPersonalOrders=1})}))
    assert.same({}, O:UpdatePersonalCounts({P2.merge(t, {numPersonalOrders=0})}))
    assert.same({{profession=7, professionName="Tailoring", count=2, delta=2}}, O:UpdatePersonalCounts({P2.merge(t, {numPersonalOrders=2})}))
  end)

  ---------------------------------------------------------------------------
  -- Beyond the brief's examples
  ---------------------------------------------------------------------------

  local function messages(name)
    local out = {}
    for _, m in ipairs(W.messages) do
      if m[1] == name then out[#out + 1] = m end
    end
    return out
  end

  it("snapshot_stores_trimmed_copy", function()
    local shared = { expectedQuality = 3, reagentCost = 200000, expectedSale = 900000, profit = 700000,
      concentrationCost = 0, goldPerConcentration = 1234, flags = { estimated = true },
      allocation = { { itemID = 100, quantity = 2 } }, reagents = { 1, 2, 3 }, breakdown = "big" }
    ns.FS:GetModule("Recipes").Evaluate = function() return shared end
    O:OnBoardShown(2, { P2.raw_order() })
    local stored = ns.FS.db.global.ordersSnapshot.orders[777]
    assert.is_table(stored)
    assert.are_not.equal(shared, stored.result)
    assert.same({ expectedQuality = 3, reagentCost = 200000, expectedSale = 900000, profit = 700000,
      concentrationCost = 0, goldPerConcentration = 1234, flags = { estimated = true } }, stored.result)
    assert.are_not.equal(shared.flags, stored.result.flags)
    -- The live view keeps Recipes' result; the stored one is a separate deep copy.
    local liveView = O:GetLiveViews()[1]
    assert.equal(shared, liveView.result)
    assert.are_not.equal(liveView.input, stored.input); assert.same(liveView.input, stored.input)
    assert.are_not.equal(liveView.flags, stored.flags); assert.are_not.equal(liveView.risks, stored.risks)
    shared.flags.estimated = false
    assert.is_true(stored.result.flags.estimated)
    -- GetSnapshot lists the stored copies.
    assert.equal(stored, O:GetSnapshot().orders[1])
  end)

  it("scores each order once per board capture", function()
    local evaluations, s = 0, spy.on(O, "BuildContext")
    ns.FS:GetModule("Recipes").Evaluate = function() evaluations = evaluations + 1; return {expectedQuality=3, reagentCost=200000, flags={}} end
    O:OnBoardShown(3, { P2.raw_order({orderID=1, orderType=3, npcOrderRewards={{itemLink="|Hitem:88888::|h[X]|h", count=1}}}),
                        P2.raw_order({orderID=2, orderType=3}) })
    assert.spy(s).was.called(1); assert.equal(2, evaluations)
    assert.equal(1, ns.FS.db.global.ordersUnknownRewards["item:88888"].count)
    O:Rescore()
    assert.equal(1, ns.FS.db.global.ordersUnknownRewards["item:88888"].count)
    assert.is_nil(O:GetView(1).customer)   -- NPC orders have no customer
  end)

  it("sends FS_ORDERS_CHANGED for a board capture and lists live views by orderID", function()
    O:OnBoardShown(2, { P2.raw_order({orderID=12}), P2.raw_order({orderID=11}) })
    assert.equal(1, #messages("FS_ORDERS_CHANGED"))
    local live = O:GetLiveViews()
    assert.same({11, 12}, {live[1].orderID, live[2].orderID})
    assert.equal(12, O:GetView(12).orderID); assert.is_nil(O:GetView(99))
  end)

  it("keeps the snapshot after the live set is cleared, and GetView falls back to it", function()
    O:OnBoardShown(2, { P2.raw_order() })
    O:ClearLive()
    assert.same({}, O:GetLiveViews())
    assert.equal(777, O:GetView(777).orderID)
    assert.equal(ns.FS.db.global.ordersSnapshot.orders[777], O:GetView(777))
  end)

  it("starts a fresh snapshot when another character opens the board", function()
    O:OnBoardShown(0, { P2.raw_order({orderID=1, orderType=0}) })
    O:OnBoardShown(2, { P2.raw_order({orderID=2}) })
    ns.FS.CharKey = function() return "Alt-Silvermoon" end
    O:OnBoardShown(0, { P2.raw_order({orderID=3, orderType=0}) })
    local snap = O:GetSnapshot()
    assert.equal("Alt-Silvermoon", snap.charKey); assert.equal(1, #snap.orders); assert.equal(3, snap.orders[1].orderID)
  end)

  it("rescores stored views with the snapshot character and announces it", function()
    O:OnBoardShown(2, { P2.raw_order() })
    O:ClearLive()
    ns.FS:GetModule("Recipes").Evaluate = function() return {expectedQuality=3, reagentCost=100000, flags={}} end
    O:Rescore()
    assert.equal(350000, O:GetView(777).score)
    assert.equal("Me-Silvermoon", O:GetView(777).charKey)
    assert.equal(3, #messages("FS_ORDERS_CHANGED"))   -- capture, ClearLive, Rescore
  end)

  it("applies updated patron rewards to the live view and the snapshot", function()
    ns.FS:GetModule("Prices").Get = function(_, id) return { value = id == 210000 and 30000 or nil } end
    O:OnBoardShown(3, { P2.raw_order({orderType=3}) })
    assert.equal(0, O:GetView(777).rewardsValue)
    O:OnRewardsUpdated("CRAFTINGORDERS_UPDATE_REWARDS", { {itemLink="|Hitem:210000::|h[R]|h", count=2} }, 777)
    assert.equal(60000, O:GetView(777).rewardsValue)
    assert.equal(60000, ns.FS.db.global.ordersSnapshot.orders[777].rewardsValue)
    assert.same({ {itemID=210000, count=2} }, ns.FS.db.global.ordersSnapshot.orders[777].input.rewards)
  end)

  it("ignores name and reward updates for unknown orders and NPC customer names", function()
    O:OnCustomerNameUpdated("CRAFTINGORDERS_UPDATE_CUSTOMER_NAME", "Bad", 1)
    O:OnRewardsUpdated("CRAFTINGORDERS_UPDATE_REWARDS", {}, 1)
    assert.equal(0, #messages("FS_ORDERS_CHANGED"))
    O:OnBoardShown(3, { P2.raw_order({orderType=3, customerName=P2.NIL}) })
    O:OnCustomerNameUpdated("CRAFTINGORDERS_UPDATE_CUSTOMER_NAME", "Bad", 777)
    assert.is_nil(O:GetView(777).customer); assert.same({}, O:GetView(777).risks)
  end)

  describe("ClaimBest", function()
    it("needs an open profession and calls nothing without one", function()
      O:OnBoardShown(2, { P2.raw_order() })
      _G.C_TradeSkillUI.GetChildProfessionInfo = function() return nil end
      assert.same({nil, "noProfession"}, {O:ClaimBest()}); assert.same({}, claimCalls)
    end)
    it("claims only orders on the live board", function()
      O:OnBoardShown(2, { P2.raw_order() })
      O:ClearLive()
      assert.same({nil, "none"}, {O:ClaimBest()}); assert.same({}, claimCalls)
    end)
    it("does not claim a public order without claims left", function()
      _G.C_CraftingOrders.GetOrderClaimInfo = function() return {claimsRemaining = 0} end
      O:OnBoardShown(0, { P2.raw_order({orderType=0}) })
      assert.same({nil, "none"}, {O:ClaimBest()}); assert.same({}, claimCalls)
    end)
    it("does nothing while Orders is off", function()
      O:OnBoardShown(2, { P2.raw_order() })
      O:Disable()
      assert.same({nil, "disabled"}, {O:ClaimBest()}); assert.same({}, claimCalls)
    end)
    it("GetBestCandidate names the order ClaimBest would claim, without claiming it", function()
      board = { P2.raw_order({orderID=10, tipAmount=900000}), P2.raw_order({orderID=11}) }
      O:OnBoardShown(2, board)
      assert.equal(10, O:GetBestCandidate().orderID); assert.same({}, claimCalls)
      assert.equal(10, O:ClaimBest().orderID)
      claimed = P2.raw_order({orderID=10})
      assert.same({nil, "alreadyClaimed"}, {O:GetBestCandidate()})
    end)
    it("GetBestCandidate chooses from ClaimBest's candidates", function()
      O:OnBoardShown(2, { P2.raw_order() }, 8)   -- seen under another profession
      assert.same({nil, "none"}, {O:GetBestCandidate()})
      _G.C_TradeSkillUI.GetChildProfessionInfo = function() return nil end
      assert.same({nil, "noProfession"}, {O:GetBestCandidate()})
      _G.C_TradeSkillUI.GetChildProfessionInfo = function() return {profession = 7} end
      _G.C_CraftingOrders.GetOrderClaimInfo = function() return {claimsRemaining = 0} end
      O:OnBoardShown(0, { P2.raw_order({orderType=0}) })
      assert.same({nil, "none"}, {O:GetBestCandidate()})
      _G.C_CraftingOrders.GetOrderClaimInfo = function() return {claimsRemaining = 1} end
      assert.equal(777, O:GetBestCandidate().orderID)
      O:Disable(); assert.same({nil, "disabled"}, {O:GetBestCandidate()}); assert.same({}, claimCalls)
    end)
  end)

  describe("ClaimBest against the board on screen", function()
    it("considers only the open profession's views", function()
      board = { P2.raw_order() }
      O:OnBoardShown(2, board, 8)   -- seen under another profession
      assert.same({nil, "none"}, {O:ClaimBest()}); assert.same({}, claimCalls)
    end)
    it("skips views that have expired", function()
      O:Settings().claimBlockingRisks.expiringSoon = false   -- only the expiry itself may keep it out
      board = { P2.raw_order({expirationTime=5000}) }   -- expiresAt = now
      O:OnBoardShown(2, board)
      assert.same({nil, "none"}, {O:ClaimBest()}); assert.same({}, claimCalls)
    end)
    it("refuses a best view that is no longer on Blizzard's board and drops it", function()
      O:OnBoardShown(2, { P2.raw_order({orderID=10, tipAmount=900000}), P2.raw_order({orderID=11}) })
      board = { P2.raw_order({orderID=11}) }
      assert.same({nil, "stale"}, {O:ClaimBest()}); assert.same({}, claimCalls)
      assert.is_nil(O:GetLiveViews()[2]); assert.equal(11, O:GetLiveViews()[1].orderID)
      assert.equal(11, O:ClaimBest().orderID); assert.same({{11, 7}}, claimCalls)
    end)
  end)

  describe("claim responses", function()
    before_each(function()
      board = { P2.raw_order({orderID=10, tipAmount=900000}), P2.raw_order({orderID=11}) }
      O:OnBoardShown(2, board)
    end)
    it("is busy until the claim response arrives", function()
      assert.equal(10, O:ClaimBest().orderID)
      assert.same({nil, "busy"}, {O:ClaimBest()}); assert.equal(1, #claimCalls)
      W.fire("CRAFTINGORDERS_CLAIM_ORDER_RESPONSE", 0, 10)
      assert.equal(10, O:ClaimBest().orderID); assert.equal(2, #claimCalls)
    end)
    it("drops an order whose claim failed and announces it", function()
      O:ClaimBest()
      local before = #messages("FS_ORDERS_CHANGED")
      W.fire("CRAFTINGORDERS_CLAIM_ORDER_RESPONSE", 2, 10)   -- AlreadyClaimed
      assert.is_nil(O:GetLiveViews()[2]); assert.equal(11, O:GetLiveViews()[1].orderID)
      assert.equal(before + 1, #messages("FS_ORDERS_CHANGED"))
      assert.equal(11, O:ClaimBest().orderID); assert.same({{10, 7}, {11, 7}}, claimCalls)
    end)
    it("stops waiting after 10 seconds without a response", function()
      O:ClaimBest()
      W.advance(9); assert.same({nil, "busy"}, {O:ClaimBest()})
      W.advance(1); assert.equal(10, O:ClaimBest().orderID); assert.equal(2, #claimCalls)
    end)
    it("forgets a claim in flight when turned off", function()
      O:ClaimBest(); O:Disable(); O:Enable()
      O:OnBoardShown(2, board)
      assert.equal(10, O:ClaimBest().orderID)
    end)
  end)

  describe("board scope", function()
    it("replaces views per order type and profession, keeping other professions in the snapshot", function()
      O:OnBoardShown(2, { P2.raw_order({orderID=1}) }, 7)
      O:OnBoardShown(2, { P2.raw_order({orderID=2}) }, 8)
      assert.equal(2, #O:GetSnapshot().orders)
      assert.same({2}, {O:GetLiveViews()[1].orderID}); assert.equal(1, #O:GetLiveViews())   -- live: open profession only
      assert.equal(8, O:GetView(2).profession); assert.equal(7, O:GetView(1).profession)
      O:OnBoardShown(2, {}, 7)
      local snap = O:GetSnapshot()
      assert.equal(1, #snap.orders); assert.equal(2, snap.orders[1].orderID)
    end)
    it("uses the open profession by default and keeps it through rescoring", function()
      O:OnBoardShown(2, { P2.raw_order() })
      assert.equal(7, O:GetView(777).profession)
      O:Rescore()
      assert.equal(7, O:GetView(777).profession); assert.equal(7, ns.FS.db.global.ordersSnapshot.orders[777].profession)
      O:OnCustomerNameUpdated("CRAFTINGORDERS_UPDATE_CUSTOMER_NAME", "Bad", 777)
      assert.equal(7, O:GetView(777).profession)
    end)
    it("replaces saved views of that type that have no profession", function()
      ns.FS.db.global.ordersSnapshot.orders[5] = { orderID = 5, orderType = "personal", charKey = "Me-Silvermoon" }
      ns.FS.db.global.ordersSnapshot.orders[6] = { orderID = 6, orderType = "public", charKey = "Me-Silvermoon" }
      O:OnBoardShown(2, {}, 7)
      assert.same({6}, {O:GetSnapshot().orders[1].orderID}); assert.equal(1, #O:GetSnapshot().orders)
    end)
  end)

  describe("fulfilment", function()
    it("keeps the pending fulfilment after a failure and removes the order on success", function()
      O:OnBoardShown(2, { P2.raw_order() })
      claimed = P2.raw_order()
      O:OnFulfillClicked(777, "", 7)
      O:OnFulfillResponse("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 10, 777)
      assert.equal(0, #messages("FS_ORDER_FULFILLED")); assert.is_table(O:GetView(777))
      O:OnFulfillResponse("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 0, 777)
      local sent = messages("FS_ORDER_FULFILLED")
      assert.equal(1, #sent); assert.is_nil(sent[1][2].quality)   -- no output link: quality unknown
      assert.is_nil(O:GetView(777)); assert.is_nil(ns.FS.db.global.ordersSnapshot.orders[777])
      assert.same({}, O:GetLiveViews())
      O:OnFulfillResponse("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 0, 777)   -- no second message
      assert.equal(1, #messages("FS_ORDER_FULFILLED"))
    end)
    it("falls back to the board view when the claimed order is another one", function()
      O:OnBoardShown(3, { P2.raw_order({orderType=3, npcCustomerCreatureID=9, customerName=P2.NIL}) })
      O:OnFulfillClicked(777, "", 7)
      O:OnFulfillResponse("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 0, 777)
      local f = messages("FS_ORDER_FULFILLED")[1][2]
      assert.same({"npc", nil, 9, 450000}, {f.orderType, f.customer, f.npcCreatureID, f.commission})
    end)
    it("drops a pending fulfilment after an hour without a response", function()
      claimed = P2.raw_order()
      O:OnFulfillClicked(777, "", 7)
      W.advance(3601)
      O:OnFulfillResponse("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 0, 777)
      assert.equal(0, #messages("FS_ORDER_FULFILLED"))
    end)
    it("sends nothing for an order it knows nothing about", function()
      O:OnFulfillClicked(5, "", 7)
      O:OnFulfillResponse("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 0, 5)
      assert.equal(0, #messages("FS_ORDER_FULFILLED"))
    end)
    it("hooks C_CraftingOrders.FulfillOrder once and ignores it while off", function()
      claimed = P2.raw_order()
      O:Disable(); O:Enable()
      local hooks = 0
      for _, h in ipairs(W.hooks) do if h[2] == "FulfillOrder" then hooks = hooks + 1 end end
      assert.equal(1, hooks)
      C_CraftingOrders.FulfillOrder(777, "", 7)
      W.fire("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 0, 777)
      assert.equal(1, #messages("FS_ORDER_FULFILLED"))
      O:Disable()
      C_CraftingOrders.FulfillOrder(777, "", 7)
      O:Enable()
      W.fire("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 0, 777)
      assert.equal(1, #messages("FS_ORDER_FULFILLED"))
    end)
  end)

  describe("personal counts", function()
    it("persists counts per character and announces arrivals", function()
      local t = {profession=7, professionName="Tailoring"}
      O:UpdatePersonalCounts({P2.merge(t, {numPersonalOrders=1})})
      O:UpdatePersonalCounts({P2.merge(t, {numPersonalOrders=3})})
      assert.equal(3, ns.FS.db.global.ordersState["Me-Silvermoon"].personalCounts[7])
      assert.same({{"FS_PERSONAL_ORDER_ARRIVED", "Tailoring", 3, 2}}, messages("FS_PERSONAL_ORDER_ARRIVED"))
    end)
    it("ignores malformed entries", function()
      assert.same({}, O:UpdatePersonalCounts(nil))
      assert.same({}, O:UpdatePersonalCounts({ {profession=7}, "x", {numPersonalOrders=2} }))
    end)
  end)

  describe("events", function()
    local infos
    before_each(function()
      infos = { {profession=7, professionName="Tailoring", numPersonalOrders=1} }
      _G.C_CraftingOrders.GetPersonalOrdersInfo = function() return infos end
    end)
    it("reads personal counts on both count events, the order-count one for the Personal type only", function()
      local s = spy.on(O, "UpdatePersonalCounts")
      W.fire("CRAFTINGORDERS_UPDATE_ORDER_COUNT", 0, 4)
      assert.spy(s).was_not.called()
      W.fire("CRAFTINGORDERS_UPDATE_ORDER_COUNT", 2, 1)
      assert.spy(s).was.called_with(match.is_ref(O), match.is_ref(infos))
      W.fire("CRAFTINGORDERS_UPDATE_PERSONAL_ORDER_COUNTS")
      assert.spy(s).was.called(2)
    end)
    it("routes customer-name and reward events to the order", function()
      O:OnBoardShown(2, { P2.raw_order({customerName = P2.NIL}) })
      W.fire("CRAFTINGORDERS_UPDATE_CUSTOMER_NAME", "Bad", 777)
      assert.same({"blockedCustomer"}, O:GetView(777).risks)
      local s = spy.on(O, "OnRewardsUpdated")
      W.fire("CRAFTINGORDERS_UPDATE_REWARDS", {}, 777)
      assert.spy(s).was.called_with(O, "CRAFTINGORDERS_UPDATE_REWARDS", {}, 777)
    end)
    it("rescores on RECIPES_CHANGED and stops a pending rescore when turned off", function()
      local s = spy.on(O, "Rescore")
      ns.FS:SendMessage("FS_RECIPES_CHANGED")
      W.advance(0.6); assert.spy(s).was.called(1)
      ns.FS:SendMessage("FS_PRICES_CHANGED", 3)
      O:Disable()
      W.advance(1); assert.spy(s).was.called(1)
    end)
  end)

  describe("read-only saved data", function()
    it("writes nothing to saved data while it is newer, but still works for the session", function()
      ns.FS.dbIsNewer = true
      local before = ns.FS.db.global.ordersSnapshot
      O:OnBoardShown(2, { P2.raw_order() })
      O:UpdatePersonalCounts({ {profession=7, professionName="Tailoring", numPersonalOrders=1} })
      assert.same({}, before.orders); assert.is_nil(before.time); assert.is_nil(ns.FS.db.global.ordersState)
      assert.equal(1, #O:GetSnapshot().orders)
      assert.same({{profession=7, professionName="Tailoring", count=2, delta=1}},
        O:UpdatePersonalCounts({ {profession=7, professionName="Tailoring", numPersonalOrders=2} }))
    end)
  end)

  describe("board hook", function()
    local page, frame
    local function fake_frame()
      frame = CreateFrame("Frame")
      page = { orderType = 2, shown = 0, buckets = 0 }
      function page.ShowOrders(p) p.shown = p.shown + 1 end
      function page.ShowBuckets(p) p.buckets = p.buckets + 1 end
      frame.OrdersPage = page
      _G.ProfessionsFrame = frame
    end
    after_each(function()
      for _, name in ipairs({ "ProfessionsFrame", "ProfessionsRecipeSchematicFormMixin", "Professions", "ScrollBoxListMixin" }) do
        _G[name] = nil
      end
    end)

    it("captures the board after ShowOrders and clears the live views when the frame hides", function()
      fake_frame()
      _G.C_CraftingOrders.GetCrafterOrders = function() return { P2.raw_order({orderID=5}) } end
      W.fire("ADDON_LOADED", "Blizzard_Professions")
      assert.is_true(O.attached)
      page:ShowOrders(0, false)
      assert.equal(1, page.shown)
      assert.equal(5, O:GetLiveViews()[1].orderID); assert.equal(1, #O:GetSnapshot().orders)
      frame:GetScript("OnHide")(frame)
      assert.same({}, O:GetLiveViews()); assert.equal(1, #O:GetSnapshot().orders)
    end)
    it("installs once across ADDON_LOADED and re-enabling", function()
      fake_frame()
      _G.C_AddOns.IsAddOnLoaded = function(name) return name == "Blizzard_Professions" end
      O:Disable(); O:Enable()
      W.fire("ADDON_LOADED", "Blizzard_Professions")
      O:Disable(); O:Enable()
      local hooks = 0
      for _, h in ipairs(W.hooks) do if h[2] == "ShowOrders" then hooks = hooks + 1 end end
      assert.equal(1, hooks)
      assert.is_true(O:InstallBoardHook())
    end)
    it("ignores the board while Orders is off", function()
      fake_frame()
      _G.C_CraftingOrders.GetCrafterOrders = function() return { P2.raw_order({orderID=5}) } end
      W.fire("ADDON_LOADED", "Blizzard_Professions")
      O:Disable()
      page:ShowOrders(0, false)
      assert.same({}, O:GetLiveViews()); assert.equal(0, #O:GetSnapshot().orders)
    end)
    it("reports a missing hook target once and keeps the rest of Orders working", function()
      _G.ProfessionsFrame = CreateFrame("Frame")
      W.fire("ADDON_LOADED", "Blizzard_Professions")
      assert.is_false(O:InstallBoardHook())
      local errors = ns.FS.db.global.diagnostics.errors
      assert.equal("hook target missing: ProfessionsFrame.OrdersPage.ShowOrders", errors[#errors].err)
      assert.equal("Orders", errors[#errors].source)
      local lines = 0
      for _, line in ipairs(W.printed) do if line:find("ShowOrders", 1, true) or line:find("order board", 1, true) then lines = lines + 1 end end
      assert.equal(1, lines)
      assert.is_true(O:IsEnabled())
      O:OnBoardShown(2, { P2.raw_order() })
      assert.equal(1, #O:GetLiveViews())
    end)
    it("works on the shared fake Professions frame without writing Blizzard fields", function()
      local form = fake_professions_frame({ orderType = 0 })
      _G.C_CraftingOrders.GetCrafterOrders = function() return { P2.raw_order({orderID=5, orderType=0}) } end
      W.fire("ADDON_LOADED", "Blizzard_Professions")
      form.ordersPage:ShowOrders(0, false)
      assert.equal(1, form.showOrdersCalls)
      assert.same({5, "public"}, {O:GetLiveViews()[1].orderID, O:GetLiveViews()[1].orderType})
      form.hide()
      assert.same({}, O:GetLiveViews())
      assert.same({}, form.assignedFields)
    end)
    it("drops live public views when the public bucket list is shown", function()
      fake_frame()
      W.fire("ADDON_LOADED", "Blizzard_Professions")
      O:OnBoardShown(0, { P2.raw_order({orderID=1, orderType=0}) })
      O:OnBoardShown(2, { P2.raw_order({orderID=2}) })
      board = { P2.raw_order({orderID=1, orderType=0}), P2.raw_order({orderID=2}) }
      local before = #messages("FS_ORDERS_CHANGED")
      page:ShowBuckets(0, false)
      assert.equal(1, page.buckets)
      assert.same({2}, {O:GetLiveViews()[1].orderID}); assert.equal(1, #O:GetLiveViews())
      assert.equal(2, #O:GetSnapshot().orders)
      assert.equal(before + 1, #messages("FS_ORDERS_CHANGED"))
      assert.equal(2, O:ClaimBest().orderID)   -- the public order is not on screen
    end)
    it("ignores ShowBuckets while Orders is off", function()
      fake_frame()
      W.fire("ADDON_LOADED", "Blizzard_Professions")
      local s = spy.on(O, "OnBucketsShown")
      O:Disable(); page:ShowBuckets()
      assert.spy(s).was_not.called()
      O:Enable(); page:ShowBuckets()
      assert.spy(s).was.called(1)
    end)
    it("logs only when ShowBuckets is missing", function()
      fake_frame(); page.ShowBuckets = nil
      W.fire("ADDON_LOADED", "Blizzard_Professions")
      assert.is_true(O.attached)
      local errors = ns.FS.db.global.diagnostics.errors
      assert.equal("hook target missing: ProfessionsFrame.OrdersPage.ShowBuckets", errors[#errors].err)
      assert.is_true(O:IsEnabled())
    end)
    it("ignores ADDON_LOADED for other addons", function()
      fake_frame()
      W.fire("ADDON_LOADED", "Blizzard_AuctionHouseUI")
      assert.is_nil(O.attached)
    end)
  end)
end)

describe("Orders fulfilment with the real Customers module", function()
  local ns, claimed
  before_each(function()
    claimed = nil
    ns = P2.boot({
      C_CraftingOrders = { GetCraftingOrderTime = function() return 5000 end, GetClaimedOrder = function() return claimed end },
      C_TradeSkillUI = { GetItemCraftedQualityByItemInfo = function() return 2 end } })
    P2.fake_module(ns, "Recipes", { Evaluate = function() return {expectedQuality=3, reagentCost=200000, flags={}} end, GetRanked = function() return {} end })
    P2.fake_module(ns, "Prices", { Get = function() return {} end })
    P2.fake_module(ns, "Scanner", { GetSchematic = function() return {skillLineID = 2900} end })
    P2.load(ns, {"Modules/Customers.lua", "Data/OrderRewards.lua", "Modules/Orders.lua"})
  end)
  it("records the customer's order; NPC orders record no customer", function()
    local O, C = ns.FS:GetModule("Orders"), ns.FS:GetModule("Customers")
    claimed = P2.raw_order({outputItemHyperlink = "|Hitem:211111::|h[Potion]|h"})
    O:OnFulfillClicked(777, "", 7)
    O:OnFulfillResponse("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 0, 777)
    local r = C:Get("Bob-Silvermoon")
    assert.equal(1, #r.orders)
    assert.same({777, 2, 500000, 450000, "personal"}, {r.orders[1].orderID, r.orders[1].quality, r.orders[1].tip,
      r.orders[1].commission, r.orders[1].orderType})
    claimed = P2.raw_order({orderID=778, orderType=3, customerName="Patron Name", npcCustomerCreatureID=9})
    O:OnFulfillClicked(778, "", 7)
    O:OnFulfillResponse("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 0, 778)
    assert.is_nil(C:Get("Patron Name-Silvermoon"))
    assert.equal(1, #C:Get("Bob-Silvermoon").orders)
  end)
end)
