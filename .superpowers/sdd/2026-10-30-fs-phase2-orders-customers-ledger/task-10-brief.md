### Task 10: Orders tab

**Files:**
- Create: `UI/Tabs/Orders.lua`
- Modify: `FabricationStation.toc` (`UI\Tabs\Orders.lua` after 1b's `UI\Tabs\Queue.lua`, before `UI\Tabs\Settings.lua`)
- Test: `tests/ui/orders_tab_spec.lua`

**Interfaces:**
- Consumes: 1a `MainWindow:RegisterTab(id, def)` (`def = {label, icon, order, build(container), refresh(container)?, phase}`; returns false on a duplicate id or missing `label`/`order`/`build`; `build` runs once and `refresh` on every select, both `pcall`ed by MainWindow), 1a `MainWindow:RefreshTab(id)` (no-op unless that tab is selected and the window shown); 1a `ns.UI.FormatAge`, `ns.UI.FormatMoney`; `Orders:GetSnapshot`, `Filter`, `Settings().filters`, `RISK_LABELS`; `ns.UI.OrdersPanel.RowModel` (Task 8; looked up at call time because `UI\OrdersPanel.lua` loads later in the TOC); `Customers:Get`; `Ledger:Benchmark`.
- Produces:
  - `ns.UI.OrdersTab.Model(snapshot, filters, now) -> {header = "Orders seen <FormatAge(now - snapshot.time)> ago on <charKey>"|"No orders seen yet", rows = { {orderID, type, item, customer, tip, net, score, risks, expiresIn} }}`. Rows are filtered and sorted by `Orders:Filter`.
  - Module `"OrdersTab"` with `coreModule = true` (like 1a's `SettingsTab`, so it is not listed as a user toggle). Its `OnInitialize` calls `ns.FS:GetModule("MainWindow"):RegisterTab("orders", {label = "Orders", icon = "Interface\\Icons\\INV_Misc_Note_06", order = 40, phase = 2, build, refresh})`. The tab id is lowercase (1a convention).
  - The tab UI: a filter checkbox row (the same `filters` table as the side panel) and a `WowScrollBoxList` with columns Type, Item, Customer, Tip, Net, Score, Risk, Expires, using `RowModel` highlight colours. A row tooltip shows `Ledger:Benchmark(recipeID, minQuality)` as `"Your tips: median <m> (p25 <a>, p75 <b>, n=<n>)"`. `OrdersTab:OnEnable` registers `ns.Msg.ORDERS_CHANGED` and `ns.Msg.CUSTOMERS_CHANGED` (wrapped with `ns.FS:Wrap("OrdersTab", ...)`) to call `MainWindow:RefreshTab("orders")`.

- [ ] **Step 1: Write the failing tests**

```lua
local P2 = require("tests.helpers.phase2")
describe("Orders tab", function()
  local ns, T, reg
  before_each(function()
    ns = P2.boot(); reg = {}
    P2.fake_module(ns, "MainWindow", { RegisterTab = function(_, id, def) reg[id] = def end })
    P2.load(ns, {"Modules/Customers.lua", "Data/OrderRewards.lua", "Modules/Orders.lua", "Modules/Ledger.lua", "UI/OrdersPanel.lua", "UI/Tabs/Orders.lua"})
    T = ns.UI.OrdersTab
  end)
  it("registers at order 40", function()
    assert.same({"Orders", 40, 2}, {reg.orders.label, reg.orders.order, reg.orders.phase})
  end)
  it("formats the snapshot age with 1a's FormatAge", function()
    assert.equal("Orders seen <1m ago on Me-Silvermoon", T.Model({time=970, charKey="Me-Silvermoon", orders={}}, {hideRisks={}, orderTypes={}}, 1000).header)
  end)
  it("builds header and filtered rows", function()
    local snap = {time=400, charKey="Me-Silvermoon", orders={
      {orderID=1, orderType="public", itemID=5, score=10, net=10, tip=20, risks={}, expiresAt=5000},
      {orderID=2, orderType="npc", itemID=6, score=50, net=50, tip=0, risks={"expiringSoon"}, expiresAt=1500}}}
    local m = T.Model(snap, {hideRisks={expiringSoon=true}, orderTypes={public=true, npc=true}}, 1000)
    assert.equal("Orders seen 10m ago on Me-Silvermoon", m.header)
    assert.equal(1, #m.rows); assert.same({1, "public", 4000}, {m.rows[1].orderID, m.rows[1].type, m.rows[1].expiresIn})
    assert.equal("No orders seen yet", T.Model({orders={}}, {hideRisks={}, orderTypes={}}, 1000).header)
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted tests/ui/orders_tab_spec.lua`
Expected: FAIL (`UI/Tabs/Orders.lua` not found)

- [ ] **Step 3: Implement `UI/Tabs/Orders.lua` (model functions, registration, `build`/`refresh` from the Interfaces block)**

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted tests/ui/orders_tab_spec.lua && luacheck .`
Expected: PASS

- [ ] **Step 5: In-game check**

On a character that has not opened the order board, `/fs` → Orders shows the last snapshot with its "seen … ago on …" header. Filters hide flagged rows.

- [ ] **Step 6: Commit**

```bash
git add UI/Tabs/Orders.lua tests/ui/orders_tab_spec.lua FabricationStation.toc
git commit -m "feat: add Orders tab showing the saved order board"
```


**Orchestrator notes (rulings and carry-forward; these win over the plan text above where they differ):**
- Ruling P1: each order row gets "Add to Queue". REUSE `ns.UI.OrdersPanel.QueueEntry(view)` (Task 8; nil → no button; it already encodes targetQuality/useConcentration/recraft/unknownRecipe rules) and the same add+duplicate-check path OrdersPanel uses (UI/OrdersPanel.lua ~378); look it up at call time like RowModel. Also reuse `ns.UI.OrdersPanel.ProfitText`. Do not copy them.
- Task 4 carry: show flags.unknownConcentrationValue as "concentration value unknown"/"conc?" and flags.recraft as "recraft" with "—" profit — never generic "no price", never "best". Reuse Task 8's ProfitText/compact formatting helpers where they fit (compact rounds losses away from zero).
- The tab must not offer claiming: ClaimOrder/ClaimBest stay only in OrdersPanel's OnClick (structural test counts exactly one ClaimBest caller).
- Display rules from implementer-common.md (nil money → "no price", estimated → "~").
- UI patterns: copy UI/Tabs/Queue.lua and UI/Tabs/Recipes.lua (pooled virtual list in a plain ScrollFrame, debounced refresh only when shown via MainWindow:RefreshTab, SafeCall source "Tab:<id>").
