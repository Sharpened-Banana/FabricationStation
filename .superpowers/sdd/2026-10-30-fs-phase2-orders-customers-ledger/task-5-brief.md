### Task 5: Order board capture, snapshot, live updates, Claim Best Order, fulfilment, personal counts

**Files:**
- Modify: `Modules/Orders.lua`, `.luacheckrc` (`C_AddOns`, unless 1b already added it; 1a already lists `ProfessionsFrame`, `hooksecurefunc`, `C_TradeSkillUI`, `C_CraftingOrders`)
- Test: `tests/orders/board_spec.lua`, `tests/orders/claim_click_only_spec.lua`

**Interfaces:**
- Consumes: Task 4 scoring; 1a `ns.FS:Debounce(key, seconds, fn)` (trailing, not error-isolated), `ns.FS:Wrap(moduleName, fn)`, `ns.FS:LogError(source, errText)`, `ns.Msg`; 1a `read_toc` (test only); `C_CraftingOrders.GetCrafterOrders/GetClaimedOrder/GetOrderClaimInfo/ClaimOrder/GetPersonalOrdersInfo`; `C_TradeSkillUI.GetChildProfessionInfo().profession`; `C_TradeSkillUI.GetItemCraftedQualityByItemInfo(link)`.
- Produces:
  - `Orders:OnBoardShown(orderTypeEnum, orders)` replaces that type's views in the live set and in `db.global.ordersSnapshot` (the snapshot stores a trimmed deep copy of each `OrderView`: `result` keeps only `expectedQuality, reagentCost, expectedSale, profit, concentrationCost, goldPerConcentration, flags`, never the shared cached table — test `snapshot_stores_trimmed_copy`), sets `snapshot.time = Now()` and `snapshot.charKey`, and sends `ns.Msg.ORDERS_CHANGED`.
  - `Orders:GetSnapshot() -> {time, charKey, orders}` (contract; leaves out views with `expiresAt < Now()`).
  - `Orders:GetLiveViews() -> {OrderView}` (current board only; empty after the Professions frame closes).
  - `Orders:GetView(orderID) -> OrderView|nil` (live first, then snapshot).
  - `Orders:Rescore()` (snapshot and live views from stored `input`, using `BuildContext(snapshot.charKey)`).
  - `Orders:OnCustomerNameUpdated(event, name, orderID)`, `Orders:OnRewardsUpdated(event, rewards, orderID)`.
  - `Orders:GetClaimedOrder() -> OrderInput|nil`.
  - `Orders:ClaimBest() -> view|nil, reason`: calls `ClaimOrder` at most once. Only `OrdersSidePanel`'s `OnClick` may call it.
  - `Orders:OnFulfillClicked(orderID, note, profession)` (post-hook on `C_CraftingOrders.FulfillOrder`), `Orders:OnFulfillResponse(event, result, orderID)`: sends `ns.Msg.ORDER_FULFILLED` and removes the order from the snapshot.
  - `Orders:UpdatePersonalCounts(infos) -> arrivals` with `{ {profession, professionName, count, delta} }`; sends `ns.Msg.PERSONAL_ORDER_ARRIVED(professionName, count, delta)` for each arrival.
  - `Orders:InstallBoardHook() -> bool`.
- `OnEnable` registers, each handler wrapped with `ns.FS:Wrap("Orders", ...)`:
  - game events: `CRAFTINGORDERS_UPDATE_CUSTOMER_NAME`, `CRAFTINGORDERS_UPDATE_REWARDS`, `CRAFTINGORDERS_FULFILL_ORDER_RESPONSE`, `CRAFTINGORDERS_UPDATE_PERSONAL_ORDER_COUNTS`, and `CRAFTINGORDERS_UPDATE_ORDER_COUNT` (Personal type only; both count events call `UpdatePersonalCounts(C_CraftingOrders.GetPersonalOrdersInfo())`)
  - messages `ns.Msg.PRICES_CHANGED`, `ns.Msg.RECIPES_CHANGED` and `ns.Msg.CUSTOMERS_CHANGED`, each calling `ns.FS:Debounce("orders.rescore", 0.5, ns.FS:Wrap("Orders", function() self:Rescore() end))`
  - `hooksecurefunc(C_CraftingOrders, "FulfillOrder", ...)`, installed once per session (guard `self.hooked`); its body returns early while `not self:IsEnabled()`
  - `InstallBoardHook` through the late-attachment pattern in Global Constraints (`ADDON_LOADED("Blizzard_Professions")` and `OnEnable`, `attached` flag)

  `InstallBoardHook` post-hooks `ProfessionsFrame.OrdersPage` `ShowOrders` and calls `OnBoardShown(page.orderType, C_CraftingOrders.GetCrafterOrders())`. If the target is missing it returns false, calls `ns.FS:LogError("Orders", "hook target missing: ProfessionsFrame.OrdersPage.ShowOrders")` and prints one chat line; the rest of Orders keeps working. It also hooks `ProfessionsFrame` `OnHide` (via `HookScript`) to clear the live views.

- [ ] **Step 1: Write the failing tests**

```lua
local P2 = require("tests.helpers.phase2")
describe("Orders board", function()
  local ns, O, W, claimed, claimCalls
  before_each(function()
    claimed, claimCalls = nil, {}
    ns, W = P2.boot({
      C_CraftingOrders = { GetCraftingOrderTime = function() return 5000 end, GetClaimedOrder = function() return claimed end,
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
    O:OnBoardShown(2, { P2.raw_order({orderID=10, tipAmount=900000}), P2.raw_order({orderID=11}) })
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
  it("detects personal order arrivals after a baseline", function()
    local t = {profession=7, professionName="Tailoring"}
    assert.same({}, O:UpdatePersonalCounts({P2.merge(t, {numPersonalOrders=1})}))   -- first sighting is the baseline
    assert.same({}, O:UpdatePersonalCounts({P2.merge(t, {numPersonalOrders=1})}))
    assert.same({}, O:UpdatePersonalCounts({P2.merge(t, {numPersonalOrders=0})}))
    assert.same({{profession=7, professionName="Tailoring", count=2, delta=2}}, O:UpdatePersonalCounts({P2.merge(t, {numPersonalOrders=2})}))
  end)
end)
```

`tests/orders/claim_click_only_spec.lua`: read every `.lua` file in 1a's `read_toc("FabricationStation.toc").files`. Then assert:
- `C_CraftingOrders.ClaimOrder(` occurs in exactly one file, `Modules/Orders.lua`, inside `function Orders:ClaimBest`.
- `:ClaimBest(` occurs outside `Modules/Orders.lua` only in `UI/OrdersPanel.lua`, on a line inside a `SetScript("OnClick"` block. Track the enclosing `SetScript("OnClick", function` … `end)` by line numbers.

Until Task 8 adds the button, the second assertion holds trivially: no caller exists yet.

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted tests/orders/board_spec.lua tests/orders/claim_click_only_spec.lua`
Expected: FAIL (`attempt to call method 'OnBoardShown' (a nil value)`)

- [ ] **Step 3: Implement the functions listed under Interfaces in `Modules/Orders.lua`**

The live set and the snapshot are keyed by `orderID`. The snapshot stores the full `OrderView` (plain tables only). `GetClaimedOrder` normalizes `C_CraftingOrders.GetClaimedOrder()`. `ClaimBest` builds `claim` from `GetOrderClaimInfo(profession).claimsRemaining` and `GetClaimedOrder() ~= nil`. `OnFulfillClicked` stores the pending fulfilment. Its quality is `GetItemCraftedQualityByItemInfo(outputItemHyperlink)`, or `nil` when there is no link. Personal counts persist in `db.global.ordersState[charKey].personalCounts`; a profession with no stored count records a baseline and produces no arrival.

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted tests/orders && luacheck .`
Expected: PASS

- [ ] **Step 5: In-game check**

`/reload`, open a profession at a crafting-orders table, and open the Personal and Patron tabs. Then `/dump #FabricationStationDB.global.ordersSnapshot.orders`: the count equals the number of orders seen. Also record whether `CRAFTINGORDERS_UPDATE_PERSONAL_ORDER_COUNTS` fired at login: `/etrace`, or a temporary print in the handler that you remove before committing.

- [ ] **Step 6: Commit**

```bash
git add Modules/Orders.lua tests/orders/board_spec.lua tests/orders/claim_click_only_spec.lua .luacheckrc
git commit -m "feat: capture order board, snapshot, claim best order, fulfilment and personal counts"
```

