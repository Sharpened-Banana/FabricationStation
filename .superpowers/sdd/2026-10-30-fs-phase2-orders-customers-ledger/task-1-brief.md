### Task 1: Phase-2 test helpers and Customers record store

**Files:**
- Create: `tests/helpers/phase2.lua`, `Modules/Customers.lua`
- Modify: `FabricationStation.toc`, `Core/Bus.lua` (1a-owned: add the two phase-2 `ns.Msg` constants), `tests/helpers/wow_stubs.lua` (1a-owned: phase-2 default fakes, below)
- Test: `tests/customers/customers_spec.lua`

**Interfaces:**
- Consumes (1a): `install_wow_stubs(overrides) -> W` (deep-merges `overrides`; `W.now` drives `GetServerTime`; `W.boot()` runs `OnInitialize` then `OnEnable` on the addon and every enabled module; `W.messages`, `W.printed`, `W.fire`, `W.advance`), `load_addon(ns, lastFile) -> ns`, `load_files(ns, paths) -> ns`, `read_toc(path)`; `ns.FS:Now()`, `ns.FS:CharKey()` (`UnitName("player") .. "-" .. GetNormalizedRealmName()`), `ns.FS:Wrap`, `ns.FS.db.global`, `ns.Msg`.
- Produces:
  - `Core/Bus.lua` additions: `ns.Msg.ORDER_FULFILLED = "FS_ORDER_FULFILLED"`, `ns.Msg.PERSONAL_ORDER_ARRIVED = "FS_PERSONAL_ORDER_ARRIVED"`.
  - `tests/helpers/wow_stubs.lua` additions to the default fakes, so 1a's whole-addon load test (`tests/integration/load_all_spec.lua`) keeps booting with phase-2 files in the TOC: `hooksecurefunc([tbl,] name, fn)` (wraps `tbl[name]` or `_G[name]` so `fn` runs after the original with the same arguments, appends `{tbl, name, fn}` to `W.hooks`, and errors like the real one when the target is not a function); `C_CraftingOrders` functions `GetCrafterOrders, GetClaimedOrder, GetPersonalOrdersInfo, GetOrderClaimInfo, ClaimOrder, FulfillOrder, GetCraftingOrderTime`; `C_TradeSkillUI.CraftRecipe`, `C_TradeSkillUI.GetItemCraftedQualityByItemInfo`; `C_DateAndTime.GetSecondsUntilWeeklyReset`; mail globals `GetInboxInvoiceInfo, GetInboxHeaderInfo, TakeInboxMoney, AutoLootMailItem`; `PlaySound`, `SOUNDKIT = {RAID_WARNING = 8959}`; `ScrollUtil.AddAcquiredFrameCallback/AddReleasedFrameCallback`; `C_AddOns.IsAddOnLoaded` (unless 1b's stubs already provide it). All return 1a's "safe empties".
  - `tests/helpers/phase2.lua` returns `P2`, a thin wrapper over 1a's harness (it adds no loader of its own):
    - `P2.boot(stubOverrides) -> ns, W`: sets `_G.FabricationStationDB = nil`; `W = install_wow_stubs(P2.merge(P2.GLOBALS, stubOverrides or {}))`; `W.now = 1000`; `ns = load_addon({}, "Data/GameData_Manual.lua")` (Core, `ns.Msg`, `ns.DBDefaults`, GameData runtime and 1a data files only); `load_files(ns, {"UI/Util.lua"})` (for `ns.UI.FormatMoney/FormatAge`). It does **not** boot, so tests can add fakes first.
    - `P2.fake_module(ns, name, methods) -> module`: `ns.FS:NewModule(name, "AceEvent-3.0")` with `methods` copied on. Used for 1a/1b modules (`Scanner`, `Prices`, `Recipes`, `MainWindow`, `Dashboard`) and for phase-2 modules a test does not load.
    - `P2.load(ns, paths)`: `load_files(ns, paths)`, then on its first call per `P2.boot` runs `W.boot()` (1a: `InitDB`, `ApplyModuleSettings`, every module's `OnInitialize`/`OnEnable`).
    - `P2.raw_order(overrides) -> CraftingOrderInfo`, `P2.merge(a, b) -> table` (deep merge, `b` wins).
  - `P2.GLOBALS` holds only test values that differ from 1a's defaults: the verified `Enum.CraftingOrderType/CraftingOrderReagentsType/CraftingOrderReagentSource/CraftingOrderResult` values above (deep-merged into 1a's `Enum`), `UnitName = function() return "Me" end` and `GetNormalizedRealmName = function() return "Silvermoon" end` (so `ns.FS:CharKey()` is `"Me-Silvermoon"`), and `date = os.date`.
  - `P2.raw_order` defaults: `{orderID=777, itemID=211111, spellID=4444, skillLineAbilityID=55, orderType=2, orderState=2, expirationTime=8600, claimEndTime=0, minQuality=0, tipAmount=500000, consortiumCut=50000, isRecraft=false, isFulfillable=true, reagentState=0, customerName="Bob", customerNotes="", reagents={}, npcOrderRewards={}, npcCraftingOrderSetID=0, npcTreasureID=0}`.
  - `Customers:NormalizeName(name) -> nameRealm|nil`, `Customers:Get(nameRealm) -> CustomerRecord|nil`, `Customers:RecordOrder(nameRealm, row) -> CustomerRecord`, `Customers:OnOrderFulfilled(event, fulfilled)`.

- [ ] **Step 1: Write the failing tests**

```lua
local P2 = require("tests.helpers.phase2")
describe("Customers store", function()
  local ns, C
  before_each(function()
    ns = P2.boot(); P2.load(ns, {"Modules/Customers.lua"}); C = ns.FS:GetModule("Customers")
  end)
  it("normalizes names to Name-Realm", function()
    assert.equal("Bob-Silvermoon", C:NormalizeName("Bob"))
    assert.equal("Bob-Area52", C:NormalizeName("Bob-Area52"))
    assert.is_nil(C:NormalizeName(nil)); assert.is_nil(C:NormalizeName(""))
  end)
  it("adds the phase-2 bus names", function()
    assert.equal("FS_ORDER_FULFILLED", ns.Msg.ORDER_FULFILLED)
    assert.equal("FS_PERSONAL_ORDER_ARRIVED", ns.Msg.PERSONAL_ORDER_ARRIVED)
    assert.equal("Me-Silvermoon", ns.FS:CharKey()); assert.equal(1000, ns.FS:Now())
  end)
  it("records a fulfilled order once and totals tips", function()
    spy.on(C, "SendMessage")
    local row = {time=1000, orderID=777, itemID=211111, recipeID=4444, quality=3, tip=500000, commission=450000, orderType="personal"}
    C:RecordOrder("Bob-Silvermoon", row); C:RecordOrder("Bob-Silvermoon", row)
    local r = C:Get("Bob-Silvermoon")
    assert.equal(1, #r.orders); assert.equal(500000, r.tipsTotal)
    assert.equal(1000, r.firstSeen); assert.equal(1000, r.lastSeen); assert.equal("", r.notes)
    assert.spy(C.SendMessage).was.called_with(C, "FS_CUSTOMERS_CHANGED", "Bob-Silvermoon")
  end)
  it("captures player orders on FS_ORDER_FULFILLED and skips NPC orders", function()
    local f = {orderID=1, orderType="public", customer="Ann-Silvermoon", recipeID=4444, itemID=211111, quality=2, tip=100000, consortiumCut=10000, commission=90000, rewards={}, rewardsValue=0, time=1000, charKey="Me-Silvermoon"}
    C:OnOrderFulfilled("FS_ORDER_FULFILLED", f)
    C:OnOrderFulfilled("FS_ORDER_FULFILLED", P2.merge(f, {orderID=2, orderType="npc", customer=nil, npcCreatureID=9}))
    assert.equal(1, #C:Get("Ann-Silvermoon").orders)
    assert.is_nil(C:Get(nil))
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted tests/customers/customers_spec.lua`
Expected: FAIL (`tests.helpers.phase2` / `Modules/Customers.lua` not found)

- [ ] **Step 3: Implement the helper and the `Customers` module (`Modules/Customers.lua`)**

Add the two `ns.Msg` constants to `Core/Bus.lua` and the default fakes listed under Interfaces to `tests/helpers/wow_stubs.lua`. `Customers` stores records in `ns.FS.db.global.customers` (1a default; still guard with `or {}`). `NormalizeName` appends the realm part of `ns.FS:CharKey()` to a bare name, so it uses 1a's realm normalization and fallback. `RecordOrder` keeps orders unique by `orderID`, sets `firstSeen` the first time and updates `lastSeen` each time. `OnOrderFulfilled` ignores `orderType == "npc"` and a nil `customer`. `OnEnable` registers `ns.Msg.ORDER_FULFILLED` with `ns.FS:Wrap("Customers", ...)`. Changes send `ns.Msg.CUSTOMERS_CHANGED`. Add `Modules\Customers.lua` to the TOC after `Modules\SelfCheck.lua`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted tests/customers/customers_spec.lua && busted && luacheck .`
Expected: PASS (including 1a's `tests/helpers/wow_stubs_spec.lua` and `tests/integration/load_all_spec.lua`), `0 warnings / 0 errors`

- [ ] **Step 5: Commit**

```bash
git add tests/helpers/phase2.lua tests/helpers/wow_stubs.lua Core/Bus.lua tests/customers/customers_spec.lua Modules/Customers.lua FabricationStation.toc
git commit -m "feat: add Customers record store and phase-2 test helpers"
```

