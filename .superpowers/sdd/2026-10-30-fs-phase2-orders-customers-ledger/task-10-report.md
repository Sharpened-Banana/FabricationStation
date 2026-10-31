# Task 10 report: Orders tab

Status: DONE_WITH_CONCERNS (minor; see Concerns)
Commit: f6f2279 feat: add Orders tab showing the saved order board (BASE 00a4193)

## What was built

`UI/Tabs/Orders.lua` (new, in TOC after `UI\Tabs\Queue.lua`, before `UI\Tabs\Settings.lua`):
- Core module `OrdersTab` (`coreModule = true`). `OnInitialize` registers tab `"orders"` with MainWindow:
  label "Orders", icon `Interface\Icons\INV_Misc_Note_06`, order 40, phase 2, build, refresh.
- `OnEnable` registers `ns.Msg.ORDERS_CHANGED` and `ns.Msg.CUSTOMERS_CHANGED` with `ns.FS:Wrap("OrdersTab", ...)`, which
  debounces 0.5 s and then calls `MainWindow:RefreshTab("orders")`. A no-op unless the tab is shown. It also registers
  `GET_ITEM_INFO_RECEIVED`, which refreshes only for item IDs this tab requested. Each uncached item is requested once
  per session.
- `ns.UI.OrdersTab` pure models:
  - `Model(snapshot, filters, now) -> { header, total, rows }`. The header reads "Orders seen <FormatAge> ago on
    <charKey>", or "No orders seen yet" when there is no `time`. The rows come from `Orders:Filter`, filtered and
    sorted best first. Each row is `{orderID, type, item, customer, tip, net, score, risks, expiresIn, view}`.
  - `CellTexts(row)`: Type, Item, Customer, Tip, Net, Score, Risk and Expires.
    - Item: client name, else the schematic name, else `item:<id>`.
    - Customer: an NPC order shows "Patron"; no customer shows "--".
    - Tip: `FormatMoney`, with "--" for nil.
    - Net and Score reuse `OrdersPanel.ProfitText`/`ScoreText`. Their "?" becomes "no price" (Net always; Score when
      `flags.noPrice`). Recraft shows an em dash and "recraft". An unknown concentration value shows "conc?". Neither
      ever says "no price". Estimates get "~".
    - Expires: `FormatAge`, red when the order has the `expiringSoon` risk.
  - `BenchmarkText(b)` gives "Your tips: median <m> (p25 <a>, p75 <b>, n=<n>)", or "Your tips: no history yet".
  - `TooltipLines(row, benchmark)`: the item, then the risk labels (red), then `OrdersPanel.Notes` (grey), then the
    benchmark line.
- Frames, copied from the Recipes/Queue pattern (a pooled virtual list in a plain ScrollFrame, SafeCall source
  `"Tab:orders"` for widget handlers):
  - Header line and status line.
  - A filter checkbox row on the shared `Orders:Settings().filters`: one check per `Orders.RISKS` plus "Hide
    unscored", the same set as the side panel. A click flips the stored value, sends `FS_ORDERS_CHANGED` and
    refreshes at once.
  - A column header bar.
  - Rows tinted by `OrdersPanel.RowModel` highlight via `OrdersPanel.HIGHLIGHT_COLORS`.
  - A row tooltip with `Ledger:Benchmark(recipeID, minQuality)`. A `minQuality` of 1 or less is passed as nil, which
    means all qualities.
  - A per-row "Queue" button, shown only when `OrdersPanel.QueueEntry(view)` is non-nil and a Queue module exists.
  - An empty-state text that distinguishes "never seen", "board was empty" and "all hidden by filters".
- No claim path: the file contains no `ClaimOrder`/`ClaimBest` token, and a spec asserts this.

`UI/OrdersPanel.lua`: the reuse refactor required by ruling P1 (no copies):
- `M.AddToQueue(view) -> message, tone | nil` is extracted verbatim from the row cells' local `add_to_queue`
  (QueueEntry, duplicate-orderID check, `Queue:Add`, the same three messages). The row cells now call it. Behaviour is
  unchanged, and the existing orders_panel spec still passes.
- `M.HIGHLIGHT_COLORS = TINTS` is exposed read-only so the tab reuses the same highlight colours.

Contract: added a `[phase 2 Task 10]` line listing `OrdersPanel.AddToQueue`/`HIGHLIGHT_COLORS`, the `OrdersTab` module
and `ns.UI.OrdersTab`.

`tests/ui/settings_spec.lua`: the full-TOC tab count changes from 4 to 5, because the Orders tab is now registered.

## Tests

`tests/ui/orders_tab_spec.lua` has 23 specs:
- The 3 brief specs, verbatim.
- Models:
  - sort and row values
  - type and unscored filters
  - no price never 0, and "some prices missing" as `+25g?`
  - recraft and conc? never shown as no price
  - estimate `~`, type, customer, tip, risk and expiry texts
  - item name fallbacks
  - BenchmarkText
  - TooltipLines
- Frames:
  - core module and icon
  - header and rows
  - empty state
  - VIP tint
  - filter checks write the shared filters, send `FS_ORDERS_CHANGED` and hide rows
  - Add to Queue entry shape, then "Already in the queue"
  - no button for recraft or unknown recipe
  - tooltip benchmark with (recipeID, minQuality)
  - benchmark over all qualities for minQuality 0
  - debounced RefreshTab on orders/customers changes
  - item request once, plus refresh on its GET_ITEM_INFO_RECEIVED only
  - structural no-claim check

### TDD evidence

RED: `busted tests/ui/orders_tab_spec.lua`
```
Error -> tests/ui/orders_tab_spec.lua @ 147
Orders tab frames before_each
./tests/helpers/phase2.lua:74: failed to load UI/Tabs/Orders.lua: cannot open UI/Tabs/Orders.lua: No such file or directory
```
GREEN: `busted tests/ui/orders_tab_spec.lua`
```
23 successes / 0 failures / 0 errors / 0 pending
```
Full suite: `busted`, which before the settings_spec count fix showed 1 failure: `settings_spec.lua:74` expected 4 tabs
but found 5.
```
1546 successes / 0 failures / 0 errors / 0 pending : 12.19 seconds
```
Lint: `luacheck .` gives `Total: 0 warnings / 0 errors in 115 files`.

## Files changed
- UI/Tabs/Orders.lua (new)
- tests/ui/orders_tab_spec.lua (new)
- FabricationStation.toc
- UI/OrdersPanel.lua (AddToQueue extraction, HIGHLIGHT_COLORS)
- tests/ui/settings_spec.lua (tab count 4 to 5)
- docs/superpowers/plans/2026-10-30-fs-interface-contract.md (Task 10 line)

## Brief vs code/notes deviations
- Brief: `WowScrollBoxList`. Orchestrator notes: a pooled virtual list in a plain ScrollFrame. I followed the notes.
- Message handlers use `Wrap("OrdersTab", ...)` as the brief's Interfaces block says. Widget handlers (clicks, scroll,
  tooltip, item event) use `"Tab:orders"` per the notes' UI pattern. So a failing message handler turns the core
  module off, and it shows in Settings' "Stopped modules". A failing widget handler is only logged.
- The Model rows add `view` (the snapshot OrderView) and the model adds `total`. These extras feed the cell, tooltip
  and queue helpers and the empty-state text.
- `Ledger:Benchmark` gets `minQuality` only when it is above 1. A raw order uses `minQuality = 0` for "no minimum",
  and no ledger entry has quality 0, so passing it would always return nil.

## Self-review
- Diff reviewed. The OrdersPanel refactor is behaviour-preserving: the same messages and tones, and nil means no
  message, as before.
- Add to Queue re-reads `Orders:GetView(orderID)` at click time (live, else the saved view, unexpired), as the board
  does. A gone or expired order says "That order is gone or has expired".
- Nothing is written on Blizzard frames. The tab has no protected calls.

## Concerns
- In-game check (Step 5) not done here (no client). Not checked: column widths at the window's minimum width (550 px
  content leaves the flexible Item column about 15 px), and how `FormatMoney`'s coin-icon string fits the 84 px Tip
  column.
- The order-type filter (`filters.orderTypes`) is respected by the model but has no checkbox. Neither does the side
  panel, so the two stay alike.

---

# Fix round 1

Commit: cb34949 fix: lay out Orders tab columns from both edges, fit them to narrow windows and share the filter checks

## Changes, by review item

1. **Column layout (Important).** `place_cells` now anchors in three passes:
   - The columns before the flexible one go left to right from the parent's LEFT + PAD.
   - The columns after it go right to left from RIGHT - PAD.
   - Item's LEFT is anchored to the RIGHT of the last left-hand column + GAP, and its RIGHT to the LEFT of the first right-hand column - GAP.
   - Hidden columns are left out of the chain.
   - The fake font strings in `tests/helpers/wow_stubs.lua` now record `SetPoint`, `GetPoint`, `GetNumPoints`, `ClearAllPoints`, `SetWidth` and `GetWidth`. This is backward-compatible: `GetWidth` is nil until set, and nothing read it before. `wow_stubs_spec` covers it.
2. **Width budget (Important).**
   - Widths are now Type 48, Customer 90, Tip 60, Net 56, Score 56, Risk 32, Expires 44 and Action 52.
   - `Tab.Layout(width) -> {hidden, item}` keeps Item at 120 px or more: Customer is hidden first, then Type. `apply_layout` runs it on build, on every refresh and on the container's OnSizeChanged. It re-anchors the header bar and every pooled row when the hidden set changes. New rows use the current layout.
   - The tip uses the new `OrdersPanel.CompactMoney` ("1,234g", "45s", "7c"). It reuses `compact`: it drops the "+" and groups the gold digits.
   - Risk shows a red "!N".
   - The tooltip now adds "Customer: …", "Tip: <FormatMoney>" and "Net: <FormatMoney | no price | em dash; ~ for estimate>".
3. **Reuse.**
   - The risk count and the tooltip's risk lines come from `RowModel(...).riskCount` and `.riskText`. The notes come from `Notes`.
   - New `OrdersPanel.FilterChecks()` returns `{key, risk?, label, get, set}` descriptors. The side panel and the tab both build their checkboxes from it. The tab adds a "Hide orders with:" label, as the panel has.
4. **Filter lines.** The number of filter lines is `ceil(#checks / 3)`, and the header, scroll and empty-text tops are computed from it.
5. **Header and status lines.**
   - Both are single-line. On every layout the status gets 45% of the inner width, and the header gets the rest minus GAP.
   - The status is cleared on the first refresh 5 s or more after it was set. It is also cleared on the container's OnShow, which fires on reselect because `SelectTab` shows the container.
6. **`seen`.** `Model` returns `seen`, and the empty state uses it.
7. **30 s refresh.** Each refresh reschedules one `Debounce("ordersTab.tick", 30, …)`, which calls `MainWindow:RefreshTab`.
   - `RefreshTab` does nothing once the tab is hidden, so the chain ends by itself with at most one pending timer.
   - `OnDisable` cancels both the tick and the refresh debounce.
   - Expired orders drop out because `GetSnapshot` filters them by `Now()`.
8. **Small inconsistencies.**
   - Net and score are coloured through the new `OrdersPanel.Sign`, which the panel's own `sign_color` now uses, so a sub-copper "0g" is plain.
   - The benchmark line now reads "Your tips (Q3): …" or "Your tips (all qualities): …".
   - All three refresh triggers (ORDERS_CHANGED, CUSTOMERS_CHANGED, GET_ITEM_INFO_RECEIVED) and the tick use the Wrap source "OrdersTab". Widget handlers keep "Tab:orders".
9. **New tests.**
   - The read-only "Could not add to the queue (saved data is read-only)" path, in both the panel and the tab specs.
   - OnDisable: messages and the item event no longer refresh, and the pending debounce and tick are cancelled.

The contract's Task 10 line now also lists `CompactMoney`, `Sign`, `FilterChecks`, `Layout`, `seen` and the 30 s refresh.

## Tests

New or changed specs:
- `orders_tab_spec`, 33 specs (was 23):
  - Layout at 516, 600, 900 and 400 px.
  - Anchors in the header and the rows at 900 px.
  - Hide and restore on resize, 516 → 600 → 400 → 900.
  - Header and status widths.
  - Checkboxes match FilterChecks, with line count.
  - Compact tip and "!2" risk.
  - Sub-copper colour.
  - Benchmark scope text.
  - Tooltip with customer, full tip and net, including an estimate and a recraft.
  - Read-only path.
  - Status clearing after 5 s and on reselect.
  - 30 s refresh dropping an expired order.
  - OnDisable.
  - `seen`.
- `orders_panel_spec`: CompactMoney and Sign, FilterChecks, and the read-only path.
- `wow_stubs_spec`: font-string anchors and width.

RED for item 1: I ran the new anchor spec against the round-0 `UI/Tabs/Orders.lua` with `busted tests/ui/orders_tab_spec.lua --filter="lays Type out"`:
```
Failure -> tests/ui/orders_tab_spec.lua @ 319
... lays Type out from the left edge and Item between Type and Customer, in the header and the rows
tests/ui/orders_tab_spec.lua:324: Expected objects to be the same.
Passed in: { *[1] = 'RIGHT', ... }   Expected: { *[1] = 'LEFT', [3] = 'LEFT', ... }
0 successes / 1 failure
```
GREEN on the new file: `1 success / 0 failures`.

Results:
- `busted tests/ui/orders_tab_spec.lua`: 33 successes / 0 failures
- `busted tests/ui/orders_panel_spec.lua`: 42 successes / 0 failures
- `busted` (full suite): 1559 successes / 0 failures / 0 errors / 0 pending
- `luacheck .`: 0 warnings / 0 errors in 115 files

## Files changed in this round
- UI/Tabs/Orders.lua
- UI/OrdersPanel.lua (CompactMoney, Sign, FilterChecks; the side panel builds its checks from FilterChecks)
- tests/ui/orders_tab_spec.lua, tests/ui/orders_panel_spec.lua
- tests/helpers/wow_stubs.lua, tests/helpers/wow_stubs_spec.lua
- docs/superpowers/plans/2026-10-30-fs-interface-contract.md

## Remaining concerns
- Not checked in game:
  - The 516 px fit and the 45% status truncation.
  - That OnShow fires on the tab container when the tab is reselected or the window is reopened. That is standard WoW behaviour, so I expect it to work.
- At 516 px the three checkbox columns take 3 × 160 = 480 px of the 504 px inner width. "Not enough concentration" is the longest label and might clip at the right edge.
