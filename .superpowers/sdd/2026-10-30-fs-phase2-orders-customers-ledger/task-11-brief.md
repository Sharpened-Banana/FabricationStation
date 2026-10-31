### Task 11: Customers tab

**Files:**
- Create: `UI/Tabs/Customers.lua`
- Modify: `FabricationStation.toc` (`UI\Tabs\Customers.lua` after `UI\Tabs\Orders.lua`)
- Test: `tests/ui/customers_tab_spec.lua`

**Interfaces:**
- Consumes: 1a `MainWindow:RegisterTab`, `MainWindow:RefreshTab`, `ns.UI.FormatMoney`; `Customers:Search`, `Get`, `GetGroup`, `SetNote`, `SetTag`, `Link`, `Unlink`, `Export`, `NormalizeName`.
- Produces:
  - `ns.UI.CustomersTab.ListModel(records) -> { {nameRealm, orders = n, tipsTotal, lastSeen, tagsText, linkedTo} }`, where `tagsText` is the sorted tags joined with `", "`.
  - `ns.UI.CustomersTab.LinkInput(text) -> nameRealm|nil, err`, which normalizes through `Customers:NormalizeName`, returns `err = "empty"` for blank input, and passes `Link` errors through.
  - Module `"CustomersTab"` (`coreModule = true`) whose `OnInitialize` calls `MainWindow:RegisterTab("customers", {label = "Customers", order = 50, phase = 2, icon = "Interface\\Icons\\INV_Misc_GroupNeedMore", build, refresh})`.
  - The tab UI:
    - a search box that calls `Search` on text change
    - a list with columns Name, Orders, Tips, Last seen, Tags
    - a detail pane with the order history (date, item, quality, tip), a notes multi-line edit box saved on focus lost, VIP and Blocked check buttons, a custom tag add field with removable tag chips, a "Linked to" edit box with Link/Unlink buttons, and the linked alts list from `GetGroup`
    - an "Export" button that opens an own dialog with a read-only, pre-selected edit box containing `Export(visible names)`
  - `CustomersTab:OnEnable` registers `ns.Msg.CUSTOMERS_CHANGED` (wrapped with `ns.FS:Wrap("CustomersTab", ...)`) to call `MainWindow:RefreshTab("customers")`.

- [ ] **Step 1: Write the failing tests**

```lua
local P2 = require("tests.helpers.phase2")
describe("Customers tab", function()
  local ns, T, reg
  before_each(function()
    ns = P2.boot(); reg = {}
    P2.fake_module(ns, "MainWindow", { RegisterTab = function(_, id, def) reg[id] = def end })
    P2.load(ns, {"Modules/Customers.lua", "UI/Tabs/Customers.lua"}); T = ns.UI.CustomersTab
  end)
  it("registers at order 50", function() assert.same({"Customers", 50}, {reg.customers.label, reg.customers.order}) end)
  it("builds list rows", function()
    local rows = T.ListModel({ {nameRealm="Bob-Silvermoon", orders={{},{}}, tipsTotal=7, lastSeen=9, tags={blocked=true, VIP=true}} })
    assert.same({nameRealm="Bob-Silvermoon", orders=2, tipsTotal=7, lastSeen=9, tagsText="VIP, blocked"}, rows[1])
  end)
  it("normalizes link input", function()
    assert.equal("Bob-Silvermoon", (T.LinkInput(" Bob ")))
    assert.same({nil, "empty"}, {T.LinkInput("  ")})
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted tests/ui/customers_tab_spec.lua`
Expected: FAIL (`UI/Tabs/Customers.lua` not found)

- [ ] **Step 3: Implement `UI/Tabs/Customers.lua` as specified under Interfaces**

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted tests/ui/customers_tab_spec.lua && luacheck .`
Expected: PASS

- [ ] **Step 5: In-game check**

1. Fulfil one order; the customer appears with the item, quality and tip.
2. Tag the customer Blocked and link an alt. Back at the order board, an order from the alt shows the red highlight and the OrderView warning.
3. Export produces CSV text you can copy.

- [ ] **Step 6: Commit**

```bash
git add UI/Tabs/Customers.lua tests/ui/customers_tab_spec.lua FabricationStation.toc
git commit -m "feat: add Customers tab with search, notes, tags, alt links and export"
```


**Orchestrator notes (rulings and carry-forward; these win over the plan text above where they differ):**
- Earlier ruling for this tab: list from `Customers:Root()`-resolved records (alts linked to their main show once, under the main), only customers with `#orders > 0`; on CUSTOMERS_CHANGED refresh the whole list (debounced), not single rows.
- Layout lessons from Task 10 (apply them here): the main window's MINIMUM content width is 516 px (MainWindow 700 − 12 − 150 − 10 − 12). Budget column widths so the flexible column keeps ≥ 120 px at 516 px, hide low-priority columns below that (recompute in OnSizeChanged), put anything truncated in the row tooltip. If the flexible column is not the first, anchor columns from both edges (see place_cells in UI/Tabs/Orders.lua). Money in narrow cells uses `ns.UI.OrdersPanel.CompactMoney`; full FormatMoney in tooltips. Shared fake font strings in tests/helpers/wow_stubs.lua now record SetPoint/SetWidth — add an anchor spec.
- Text inputs (notes, tags, search): own EditBoxes; trim and length-limit; never write while dbIsNewer (Customers' own setters already guard — use them, don't write records directly).
- UI patterns: UI/Tabs/Queue.lua, UI/Tabs/Orders.lua (pooled list, debounced refresh only when shown, OnDisable cancels debounces/tickers, SafeCall sources "Tab:customers" for widgets and the module name for message triggers).
- Display rules: nil money → "no price", never 0g.
