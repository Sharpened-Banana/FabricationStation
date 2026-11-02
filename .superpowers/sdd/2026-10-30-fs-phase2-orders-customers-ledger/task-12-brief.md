### Task 12: Ledger tab and Dashboard widgets

**Files:**
- Create: `UI/Tabs/Ledger.lua`, `UI/OrdersWidgets.lua`
- Modify: `FabricationStation.toc` (`UI\Tabs\Ledger.lua` after `UI\Tabs\Customers.lua`; `UI\OrdersWidgets.lua` after `UI\OrderAlert.lua`, so after 1b's `UI\Tabs\Dashboard.lua`)
- Test: `tests/ui/ledger_tab_spec.lua`

**Interfaces:**
- Consumes: 1a `MainWindow:RegisterTab`, `MainWindow:RefreshTab(id)`, `ns.UI.FormatMoney/FormatAge`; 1b `Dashboard:RegisterWidget(id, def)` with `def = {order, title, build = function(frame) end, refresh = function(frame) end}` (1b stores `def.id = id`, same id replaces; 1b's `BuildAll` isolates a widget whose `build`/`refresh` errors, and 1b's phase-1 widgets use orders 10/20/30); `Ledger:Weekly`, `ByRecipe`, `Query`, `Benchmark`, `WeekStart`; `Orders:GetSnapshot`.
- Produces:
  - `ns.UI.LedgerTab.RecipeRows(byRecipe) -> { {recipeID, income, cost, profit, n, incomplete} }`, sorted by profit descending.
  - `ns.UI.LedgerTab.BenchmarkRows(entries) -> { {recipeID, quality, median, p25, p75, n} }`. Built from distinct `(recipeID, quality)` pairs of commission entries, calling `Ledger:Benchmark` for each and skipping nil results. Sorted by recipeID, then quality.
  - Module `"LedgerTab"` (`coreModule = true`) whose `OnInitialize` calls `MainWindow:RegisterTab("ledger", {label = "Ledger", order = 60, phase = 2, icon = "Interface\\Icons\\INV_Misc_Coin_02", build, refresh})`. The UI has three sections:
    - weekly summary for 8 weeks (income, cost, profit, plus `"<n> without cost basis"` when `incomplete > 0`)
    - the per-recipe table
    - an entries list (time, type, item, amount, customer) and the benchmark table
  - `LedgerTab:OnEnable` registers `ns.Msg.LEDGER_CHANGED` (wrapped) to call `MainWindow:RefreshTab("ledger")`.
  - `ns.UI.OrdersWidgets.OpenOrdersModel(snapshot, now) -> {total, personal, bestScore|nil, age|nil}`, where `age` is `now - snapshot.time` (the widget shows it with `ns.UI.FormatAge`).
  - `ns.UI.OrdersWidgets.GoldThisWeekModel(weekly) -> {profit, income, incomplete}`.
  - Module `"OrdersWidgets"` (`coreModule = true`) whose `OnInitialize` calls `ns.FS:GetModule("Dashboard"):RegisterWidget("openOrders", {order = 40, title = "Open orders", build, refresh})` and `RegisterWidget("goldThisWeek", {order = 50, title = "Gold this week", build, refresh})`. 1b's Dashboard only refreshes on its own three messages, so `OrdersWidgets:OnEnable` registers `ns.Msg.ORDERS_CHANGED` and `ns.Msg.LEDGER_CHANGED` (wrapped) to call `MainWindow:RefreshTab("dashboard")`, which re-runs every widget's `refresh` when the Dashboard is visible.

- [ ] **Step 1: Write the failing tests**

```lua
local P2 = require("tests.helpers.phase2")
describe("Ledger tab and widgets", function()
  local ns, reg, widgets
  before_each(function()
    ns = P2.boot({ C_DateAndTime = { GetSecondsUntilWeeklyReset = function() return 1 end } }); reg, widgets = {}, {}
    P2.fake_module(ns, "MainWindow", { RegisterTab = function(_, id, def) reg[id] = def end })
    P2.fake_module(ns, "Dashboard", { RegisterWidget = function(_, id, def) widgets[id] = def end })
    P2.load(ns, {"Modules/Customers.lua", "Data/OrderRewards.lua", "Modules/Orders.lua", "Modules/Ledger.lua", "UI/Tabs/Ledger.lua", "UI/OrdersWidgets.lua"})
  end)
  it("registers tab and widgets", function()
    assert.same({"Ledger", 60}, {reg.ledger.label, reg.ledger.order})
    assert.same({40, "Open orders", 50, "Gold this week"}, {widgets.openOrders.order, widgets.openOrders.title, widgets.goldThisWeek.order, widgets.goldThisWeek.title})
  end)
  it("sorts recipe rows by profit", function()
    local rows = ns.UI.LedgerTab.RecipeRows({ [1] = {income=5, cost=0, profit=5, n=1, incomplete=0}, [2] = {income=9, cost=1, profit=8, n=1, incomplete=0} })
    assert.same({2, 1}, {rows[1].recipeID, rows[2].recipeID})
  end)
  it("builds benchmark rows from commission history", function()
    local L = ns.FS:GetModule("Ledger")
    for _, t in ipairs({100, 200, 300}) do L:Add({type="commission", amount=t, tip=t, recipeID=4444, quality=3}) end
    L:Add({type="commission", amount=1, tip=1, recipeID=4444, quality=2})
    assert.same({ {recipeID=4444, quality=3, median=200, p25=150, p75=250, n=3} }, ns.UI.LedgerTab.BenchmarkRows(L:Query({type="commission"})))
  end)
  it("models the dashboard widgets", function()
    local W = ns.UI.OrdersWidgets
    assert.same({total=2, personal=1, bestScore=50, age=600},
      W.OpenOrdersModel({time=400, orders={ {orderType="personal", score=50}, {orderType="public", score=nil} }}, 1000))
    assert.same({total=0, personal=0}, W.OpenOrdersModel({orders={}}, 1000))
    assert.same({profit=7, income=9, incomplete=1}, W.GoldThisWeekModel({ {weekStart=0, income=9, cost=2, profit=7, incomplete=1} }))
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted tests/ui/ledger_tab_spec.lua`
Expected: FAIL (`UI/Tabs/Ledger.lua` not found)

- [ ] **Step 3: Implement `UI/Tabs/Ledger.lua` and `UI/OrdersWidgets.lua` as specified under Interfaces**

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted tests/ui/ledger_tab_spec.lua && luacheck .`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add UI/Tabs/Ledger.lua UI/OrdersWidgets.lua tests/ui/ledger_tab_spec.lua FabricationStation.toc
git commit -m "feat: add Ledger tab and open-orders / gold-this-week dashboard widgets"
```


**Orchestrator notes (rulings and carry-forward; these win over the plan text above where they differ):**
- Ledger semantics (Tasks 6/7): `incomplete` > 0 means the profit is partial → show "partial" / "≥" (at least), never present it as exact. Unknown cost is nil, not 0. Recraft commissions carry `recraft=true, cost=nil` (counted incomplete; label them "recraft"). Weekly skips rows with no numeric time. `Ledger:Query` returns live saved rows — never mutate them. `Ledger:Unattributed(filter)` exists for sales with no recipeID — include them (e.g. an "Unattributed" line) so totals add up.
- Task 4 carry: anywhere order scores/values appear, show unknownConcentrationValue / recraft markers, never generic "no price".
- Layout lessons (Tasks 10/11): MINIMUM content width is 516 px; flexible column keeps ≥ 120 px there; hide low-priority columns below that (OnSizeChanged); anchor from both edges when the flexible column is not first; anything truncated goes in a tooltip; status/notice lines lead with the key word and have a tooltip. Narrow money cells use `ns.UI.OrdersPanel.CompactMoney`; full FormatMoney in tooltips; sub-copper zero shown grey. Add anchor/width specs at 516 px (shared fake font strings record SetPoint/SetWidth).
- Dashboard widgets: use 1b's `Dashboard:RegisterWidget` / `SetLines` exactly as UI/Tabs/Dashboard (or wherever 1b put it) defines; widgets must handle an empty ledger ("No sales recorded yet") and dbIsNewer (read-only is fine for display).
- UI patterns: UI/Tabs/Orders.lua and UI/Tabs/Customers.lua (pooled list, debounced refresh only when shown via MainWindow:RefreshTab, LEDGER_CHANGED triggers wrapped with the module name, widgets "Tab:ledger", OnDisable cancels debounces/tickers, no leaked event registrations).
- Display rules: nil money → "no price"/"?", never 0g; estimated → "~".
