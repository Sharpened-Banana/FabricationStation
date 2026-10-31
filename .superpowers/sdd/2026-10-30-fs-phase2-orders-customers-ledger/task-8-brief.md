### Task 8: OrdersPanel — additions to Blizzard's crafting-orders list

**Files:**
- Create: `UI/OrdersPanel.lua`
- Modify: `FabricationStation.toc` (`UI\OrdersPanel.lua` after 1b's `UI\Tooltips.lua`), `.luacheckrc` (`ScrollUtil`; 1a already lists `CreateFrame`, `GameTooltip`, `UIParent`)
- Test: `tests/ui/orders_panel_spec.lua`

**Interfaces:**
- Consumes: `Orders:GetView`, `GetLiveViews`, `IsHidden`, `Settings`, `GetBestClaimable`, `ClaimBest`, `RISK_LABELS`; `Customers:Get`, `IsBlocked`; `Ledger:Benchmark`; 1a `ns.UI.FormatMoney` (`"--"` for nil); 1a `ns.FS:SafeCall` (disables the named module if enabled, logs, sends `FS_MODULE_FAILED`, prints once), `ns.FS:LogError`, `ns.FS.failedModules`; `ns.Msg`.
- Produces:
  - Shared table `ns.UI.OrdersPanel` (`ns.UI` is created by 1a's `UI/Util.lua`) with pure functions:
    - `RowModel(view, customer, filters) -> {profit, score, riskCount, riskText, highlight = "blocked"|"vip"|"repeat"|nil, dimmed, estimated}`. `profit = view.net` and `score` are copper or nil. `riskText` is the risk labels joined with `"\n"` for the tooltip. `dimmed = Orders:IsHidden(view, filters)`. `estimated = view.flags and view.flags.estimated or false` (1b's "no calibration" flag); the score cell then shows `~` before the money so an estimate never looks certain. Highlight precedence:
      1. `"blocked"`: `view.risks` contains `blockedCustomer`, which is group-aware, or `customer.tags.blocked`
      2. `"vip"`: `customer.tags.VIP`
      3. `"repeat"`: `#customer.orders >= 2`
    - `BestText(itemText, view, benchmark) -> string`, formatted `"<itemText> · net <FormatMoney(view.net)> · tip vs your median <+N%|-N%|n/a>"`, with `N = floor((tip/median - 1) * 100 + 0.5)`.
    - `Guard(moduleName, fn, ...)`, which calls `ns.FS:SafeCall(moduleName, fn, ...)` only while that module is enabled.
  - Three modules, each a normal toggleable module (1a's `settings.modules[<Name>]`, default on, listed in 1a's `"modules"` options group and in Task 13's group; changed only through `ns.FS:SetModuleEnabled`):
    - `OrdersRowAddons`: own overlay and cell frames, anchored to Blizzard rows and parented to an own container that clips children and is anchored over `OrderList.ScrollBox`.
    - `OrdersSidePanel`: own frame anchored `TOPLEFT` to `ProfessionsFrame` `TOPRIGHT` (+2, 0), width 220. It holds:
      - the header `"FabricationStation"`
      - one checkbox per risk (label `RISK_LABELS[risk]`, bound to `filters.hideRisks[risk]`) plus `"Hide unscored"`
      - the claims-remaining text
      - the `"Claim Best Order"` button, whose `SetScript("OnClick", ...)` is the only caller of `Orders:ClaimBest()`
      - the best-order line from `BestText`
      - the claim-result line from `CRAFTINGORDERS_CLAIM_ORDER_RESPONSE`: `"Claimed — open it from the order list"`, or `"Claim failed (<result>)"`.
    - `OrderViewWarning`: own fontstring frame anchored above `ProfessionsFrame.OrdersPage.OrderView`, showing `"Blocked customer: <name>"` in red or `"VIP customer · <n> previous orders"` in gold.
- Hooks, installed once per session per module through the late-attachment pattern in Global Constraints (they cannot be removed; while a module is disabled `Guard` makes its bodies no-ops), with every body run through `Guard`:
  - `hooksecurefunc(ProfessionsFrame.OrdersPage, "ShowOrders"|"ShowBuckets")`. Bucket view hides cells.
  - `ScrollUtil.AddAcquiredFrameCallback` / `AddReleasedFrameCallback` on the ScrollBox. Rows with no `elementData.option.orderID` get no cells.
  - `BrowseFrame:HookScript("OnShow"|"OnHide")` shows and hides the panel.
  - `hooksecurefunc(OrderView, "SetOrder")` for the warning.
  - Messages `ns.Msg.ORDERS_CHANGED` and `ns.Msg.CUSTOMERS_CHANGED` refresh the visible cells.
- A missing hook target means that module calls `ns.FS:LogError("<Module>", "hook target missing: <path>")`, prints `"FabricationStation: <module> disabled (Blizzard UI changed)"` once and calls `:Disable()` (not `SetModuleEnabled`, so the stored setting stays on and the hook is retried next session).
- Row colours: VIP overlay `(1, 0.82, 0, 0.18)`; blocked `(1, 0.1, 0.1, 0.25)` plus a warning icon; dimmed (filtered out) uses an own black overlay at alpha `0.55`.
- Cells, in this order: profit (net), score, and a risk icon showing `riskCount` with a `GameTooltip` of `riskText`.

- [ ] **Step 1: Write the failing tests**

```lua
local P2 = require("tests.helpers.phase2")
describe("OrdersPanel", function()
  local ns, P, W
  before_each(function()
    ns, W = P2.boot()
    P2.load(ns, {"Modules/Customers.lua", "Data/OrderRewards.lua", "Modules/Orders.lua", "Modules/Ledger.lua", "UI/OrdersPanel.lua"})
    P = ns.UI.OrdersPanel
  end)
  it("builds a row model with highlight and dimming", function()
    local v = {orderType="public", net=250000, score=200000, risks={"expiringSoon","blockedCustomer"}}
    local m = P.RowModel(v, {orders={{},{}}, tags={VIP=true}}, {hideRisks={expiringSoon=true}, orderTypes={public=true}})
    assert.same({250000, 200000, 2, "Expiring soon\nBlocked customer", "blocked", true},
      {m.profit, m.score, m.riskCount, m.riskText, m.highlight, m.dimmed})   -- blockedCustomer risk (group-aware) wins over VIP
    local ok = {orderType="public", net=1, score=1, risks={}}
    local f = {hideRisks={}, orderTypes={public=true}}
    assert.equal("vip", P.RowModel(ok, {orders={}, tags={VIP=true}}, f).highlight)
    assert.equal("repeat", P.RowModel(ok, {orders={{},{}}, tags={}}, f).highlight)
    assert.is_nil(P.RowModel(ok, nil, f).highlight); assert.is_false(P.RowModel(ok, nil, f).dimmed)
  end)
  it("disables only the failing addition", function()
    local rows, side = ns.FS:GetModule("OrdersRowAddons"), ns.FS:GetModule("OrdersSidePanel")
    P.Guard("OrdersRowAddons", function() error("boom") end)
    assert.is_false(rows:IsEnabled()); assert.is_true(side:IsEnabled())
    assert.is_truthy(ns.FS.failedModules.OrdersRowAddons)
    local errs = ns.FS.db.global.diagnostics.errors; assert.equal("OrdersRowAddons", errs[#errs].source)
    assert.same({"FS_MODULE_FAILED", "OrdersRowAddons"}, {W.messages[#W.messages][1], W.messages[#W.messages][2]})
    local called = false; P.Guard("OrdersRowAddons", function() called = true end)
    assert.is_false(called)
  end)
  it("formats the best-order line with the tip benchmark", function()
    local money = ns.UI.FormatMoney(250000)
    assert.equal("Potion · net " .. money .. " · tip vs your median +25%",
      P.BestText("Potion", {net=250000, tip=500000}, {median=400000, p25=1, p75=1, n=5}))
    assert.equal("Potion · net " .. money .. " · tip vs your median n/a", P.BestText("Potion", {net=250000, tip=500000}, nil))
  end)
end)
```

(The test relies on 1a's `SafeCall` disabling the named module on error, which needs the modules enabled; `P2.load` runs 1a's `W.boot()`. The caller passes `itemText`: the hyperlink when it is cached, otherwise `tostring(itemID)`.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted tests/ui/orders_panel_spec.lua`
Expected: FAIL (`UI/OrdersPanel.lua` not found)

- [ ] **Step 3: Implement `UI/OrdersPanel.lua` as specified under Interfaces**

Frames are created only in `OnEnable` or the first hook call, never at file load. Do not assign any field on a Blizzard frame. Keep `rowFrame → cells` in a weak-keyed own table.

- [ ] **Step 4: Run tests and lint**

Run: `busted tests/ui/orders_panel_spec.lua tests/orders/claim_click_only_spec.lua && luacheck .`
Expected: PASS (the click-only test now finds exactly one `ClaimBest(` caller, inside the button's `OnClick`).

- [ ] **Step 5: In-game check**

1. Open orders at a table with `/console taintLog 1` set.
2. Check that profit, score and risk cells line up with rows while scrolling.
3. Tag a customer VIP from `/run` and check that the row turns gold.
4. Toggle a filter and check that matching rows dim.
5. Click Claim Best Order, then Blizzard's Start Order and Craft buttons, and check that each still works.
6. Turn off each of the three modules in Settings › Modules (1a's group) and check that its addition disappears after `/reload`.
7. `Logs/taint.log` has no `FabricationStation` entries for Blizzard_Professions.

- [ ] **Step 6: Commit**

```bash
git add UI/OrdersPanel.lua tests/ui/orders_panel_spec.lua FabricationStation.toc .luacheckrc
git commit -m "feat: add score/profit/risk columns, customer highlight, filters and Claim Best Order to crafting orders"
```


**Orchestrator notes (rulings and carry-forward; these win over the plan text above where they differ):**
- Ruling P1 (author's choice): each order row gets an "Add to Queue" button that calls `Queue:Add` with the order's recipeID, `orderID`, `providedReagents` (the order's customer-supplied reagents) and `targetQuality = minQuality`. Read the actual `Queue:Add` signature in Modules/Queue.lua and use it; if orderID isn't accepted yet, add it to Queue as an optional pass-through field (tested). No protected call is involved. Test it.
- Task 5 ruling: the panel's "best order" display must come from `Orders:GetBestClaimable(Orders:GetLiveViews())`, so the Claim Best button claims exactly what the panel shows.
- Task 4 carry: show `flags.unknownConcentrationValue` as "concentration value unknown" and `flags.recraft` as "recraft — judge manually", never a generic "no price"; such orders are never shown as "best".
- `Orders:ClaimBest` may be called ONLY in the form `:ClaimBest(` inside the button's OnClick in UI/OrdersPanel.lua; a structural test enforces it (exact-token match, like craft_spec's CraftRecipe check).
- No taint: own frames only, anchored to Blizzard's frames; read-only hooks (hooksecurefunc/HookScript/EventRegistry); never write fields on Blizzard frames or call Blizzard layout methods.
- Display rules from implementer-common.md (nil money → "no price", estimated → "~", etc.) apply.
- Hotfix H1 added a "(game)/(estimate)" header on ProfessionPanel; don't regress it if you share code.
