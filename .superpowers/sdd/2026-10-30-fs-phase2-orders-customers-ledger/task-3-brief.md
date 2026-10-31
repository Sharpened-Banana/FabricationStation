### Task 3: Orders normalization and reward valuation

**Files:**
- Create: `Data/OrderRewards.lua`, `Modules/Orders.lua`
- Modify: `FabricationStation.toc` (`Data\OrderRewards.lua` after `Data\GameData_Manual.lua`; `Modules\Orders.lua` after `Modules\Customers.lua`). `.luacheckrc` needs no change (1a already lists `C_CraftingOrders`, `C_CurrencyInfo`, `Enum`; `Data/` is linted as pure `lua51` and `Data/OrderRewards.lua` uses only `ns`).
- Test: `tests/orders/normalize_spec.lua`

**Interfaces:**
- Consumes: `Customers:NormalizeName` (Task 1); 1a `Prices:Get(itemID) -> {value = copper|nil, source, ageDays}` (never `value = 0` for unknown); 1a `ns.GameData.Define/Get`, 1a GameData table `"MoxieCurrency"` (`[skillLineID] = currencyID`); `C_CraftingOrders.GetCraftingOrderTime()`; `C_CurrencyInfo.GetCurrencyInfo(id).name`.
- Produces: GameData table `"OrderRewards"` (shape and build rule under Contract additions; `Data/OrderRewards.lua` is `local ADDON_NAME, ns = ...` then `ns.GameData.Define("OrderRewards", 70575, { items = {}, currencies = {} })` with a comment explaining how to fill it from an in-game `/dump C_CraftingOrders.GetCrafterOrders()[n].npcOrderRewards`), `Orders.ORDER_TYPES = {[0]="public",[1]="guild",[2]="personal",[3]="npc"}`, `Orders.REAGENT_STATES = {[0]="all",[1]="some",[2]="none"}`, `Orders:Settings() -> table` (fills defaults into `db.global.settings.orders`), `Orders:Normalize(orderInfo) -> OrderInput`, `Orders:ValueRewards(rewards) -> total, valued, unpriced`.
- `Orders:Settings()` defaults: `{lowTipMargin = 100000, expiringSoonSeconds = 3600, knowledgePointValue = 500000, moxieValue = 20000, moxieNamePattern = "Moxie", rewardOverrides = {}, claimMinScore = 0, claimBlockingRisks = {noMatsLowTip=true, unreachableQuality=true, noConcentration=true, expiringSoon=true, blockedCustomer=true}, filters = {hideRisks = {}, orderTypes = {public=true, guild=true, personal=true, npc=true}, minScore = nil, hideUnscored = false}}`.

- [ ] **Step 1: Write the failing tests**

```lua
local P2 = require("tests.helpers.phase2")
describe("Orders:Normalize / ValueRewards", function()
  local ns, O, prices
  before_each(function()
    ns = P2.boot({ C_CraftingOrders = { GetCraftingOrderTime = function() return 5000 end },
                   C_CurrencyInfo = { GetCurrencyInfo = function(id) return { name = id == 4000 and "Artisan's Moxie" or "Other" } end } })
    prices = { [210000] = 30000 }
    P2.fake_module(ns, "Prices", { Get = function(_, id) return { value = prices[id], source = prices[id] and "auction" } end })
    P2.load(ns, {"Modules/Customers.lua", "Data/OrderRewards.lua", "Modules/Orders.lua"})
    ns.GameData.Define("OrderRewards", 70575, { items = { [99001] = {kind="knowledge", points=1} }, currencies = { [3256] = {kind="moxie"} } })
    O = ns.FS:GetModule("Orders")
  end)
  it("normalizes a raw order", function()
    local i = O:Normalize(P2.raw_order({ orderType=3, reagentState=2,
      reagents = { {reagentInfo={reagent={itemID=100}, quantity=3, dataSlotIndex=1}, slotIndex=1, source=1, isBasicReagent=true},
                   {reagentInfo={reagent={itemID=101}, quantity=2, dataSlotIndex=2}, slotIndex=2, source=1, isBasicReagent=true},
                   {reagentInfo={reagent={currencyID=3008}, quantity=5, dataSlotIndex=4}, slotIndex=4, source=1, isBasicReagent=true},
                   {reagentInfo={reagent={itemID=200}, quantity=1, dataSlotIndex=3}, slotIndex=3, source=2, isBasicReagent=true} },
      npcOrderRewards = { {itemLink="|cff0070dd|Hitem:12345::::|h[X]|h|r", count=2}, {currencyType=3056, count=10} } }))
    assert.equal("npc", i.orderType); assert.equal("none", i.reagentState); assert.equal(4444, i.recipeID)
    assert.same({[100]=3, [101]=2}, i.provided)
    assert.same({ {itemID=12345, count=2}, {currencyID=3056, count=10} }, i.rewards)
    assert.equal(4600, i.expiresAt)              -- Now 1000 + (8600 - 5000)
    assert.equal("Bob-Silvermoon", i.customer)
  end)
  it("normalizes a nil customer name", function()
    assert.is_nil(O:Normalize(P2.raw_order({ customerName = P2.NIL })).customer)
  end)
  it("values knowledge, moxie, priced items and flags unpriced rewards", function()
    local total, valued, unpriced = O:ValueRewards({ {itemID=99001,count=2}, {currencyID=3256,count=10}, {itemID=210000,count=5}, {itemID=88888,count=1} })
    assert.equal(1350000, total); assert.is_true(unpriced)
    assert.same({"knowledge","moxie","reagent","unknown"}, {valued[1].kind, valued[2].kind, valued[3].kind, valued[4].kind})
    assert.is_nil(valued[4].value)
    assert.equal(1, ns.FS.db.global.ordersUnknownRewards["item:88888"].count)
  end)
  it("uses the Moxie name fallback and per-reward overrides", function()
    O:Settings().rewardOverrides["item:88888"] = 70000
    local total, _, unpriced = O:ValueRewards({ {currencyID=4000,count=3}, {itemID=88888,count=1} })
    assert.equal(130000, total); assert.is_false(unpriced)
  end)
  it("treats 1a's MoxieCurrency ids as Moxie", function()
    ns.GameData.Define("MoxieCurrency", 70575, { [2871] = 3300 })
    local total, valued = O:ValueRewards({ {currencyID=3300,count=2} })
    assert.equal(40000, total); assert.equal("moxie", valued[1].kind)
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted tests/orders/normalize_spec.lua`
Expected: FAIL (`Modules/Orders.lua` not found)

- [ ] **Step 3: Implement `Data/OrderRewards.lua` and `Orders:Settings/Normalize/ValueRewards` in `Modules/Orders.lua`**

`Normalize`:
- `provided` sums customer-source (`1`) reagents. The itemID is `reagentInfo.reagent.itemID` (1a's verified Midnight `CraftingReagentInfo` shape, `{reagent = {itemID?, currencyID?}, dataSlotIndex, quantity}`); entries with only a `currencyID` are skipped.
- `expiresAt = ns.FS:Now() + (expirationTime - C_CraftingOrders.GetCraftingOrderTime())`.
- The reward itemID comes from `itemLink:match("item:(%d+)")`.

`ValueRewards` checks these sources in order, per unit, and uses the first that gives a value:
1. `rewardOverrides["item:<id>"|"currency:<id>"]`
2. `ns.GameData.Get("OrderRewards")`: `knowledge` → `points × knowledgePointValue`; `moxie` → `moxieValue`
3. for currencies, an id that is a value in 1a's `ns.GameData.Get("MoxieCurrency")` (kind `"moxie"`, `moxieValue`)
4. for items, `Prices:Get(itemID).value` when non-nil (kind `"reagent"`)
5. for currencies, a name containing `moxieNamePattern` (kind `"moxie"`)
6. otherwise kind `"unknown"`, `value = nil`, `unpriced = true`, and a count is added to `db.global.ordersUnknownRewards[key]` with `lastSeen = Now()`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted tests/orders && luacheck .`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Data/OrderRewards.lua Modules/Orders.lua tests/orders/normalize_spec.lua FabricationStation.toc
git commit -m "feat: normalize crafting orders and value patron rewards"
```

