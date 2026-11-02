# Task 8 report: OrdersPanel (additions to Blizzard's crafting-orders list)

Status: DONE_WITH_CONCERNS (all automated checks green; the in-game check in Step 5 cannot be run here)
Commit: 2b669e6 feat: add score/profit/risk columns, customer highlight, filters and Claim Best Order to crafting orders
BASE: 21abf99

## What I built

`UI/OrdersPanel.lua` (new; in the TOC after `UI\Tooltips.lua`):

- `ns.UI.OrdersPanel` with these pure functions:
  - `RowModel(view, customer, filters)` as specified. Highlight precedence is blocked (the `blockedCustomer` risk or the customer's own `tags.blocked`), then vip, then repeat (2 or more orders). `dimmed` comes from `Orders:IsHidden` (the saved filters when `filters` is nil). `riskText` is `""` when the order has no risks.
  - `BestText(itemText, view, benchmark)` as specified. An estimated net gets `~`. An unknown net reads `no price`, never `--` or 0.
  - `Guard(moduleName, fn, ...)` calls SafeCall only while the module exists and is enabled. Otherwise it returns false.
  - Extras: `ProfitText` and `ScoreText` produce compact cell text (`+25g`, `-3g`, `+45s`, `?` when unknown, a `~` prefix for estimates, a `?` suffix with noPrice). The score cell shows `recraft` for a recraft and `conc?` for an unknown concentration value. `Notes(view)` gives the full reasons for the tooltip, such as "Recraft — judge manually" and "Concentration value unknown", so these cases never show a generic "no price". `QueueEntry(view)` builds the Add to Queue entry.
- The three normal toggleable modules each have their own late attachment through `AttachIfReady` (run from `ADDON_LOADED` and `OnEnable`). Hooks are installed once per session, every hook body runs through `Guard`, and a missing hook target is handled with `LogError("<Module>", "hook target missing: <path>")`, a single print `FabricationStation: <Module> disabled (Blizzard UI changed)` and `:Disable()`.
  - **OrdersRowAddons** has its own container frame. It is a child of `OrderList.ScrollBox`, anchored over it, set to `SetClipsChildren(true)` and placed 20 frame levels above the box.
    - Each row gets its own overlay with a tint: VIP `(1, .82, 0, .18)`, blocked `(1, .1, .1, .25)` plus a warning icon, and repeat `(.3, .7, 1, .12)`, which is my addition. Rows hidden by the filters get a black dim at 0.55.
    - Each row also gets a strip with profit, score, a risk count (its GameTooltip lists the risk labels, then the notes) and a "+" Add to Queue button.
    - Hooks: `hooksecurefunc` on `ShowOrders` (refresh) and `ShowBuckets` (hide all cells), plus `ScrollUtil.AddAcquiredFrameCallback` and `AddReleasedFrameCallback`. `ORDERS_CHANGED` and `CUSTOMERS_CHANGED` also refresh.
    - Rows without `elementData.option.orderID` get no cells.
  - **OrdersSidePanel** is the frame `FabricationStationOrdersPanel`. It is anchored `TOPLEFT` to `ProfessionsFrame` `TOPRIGHT` (+2, 0), is 220 wide and is shown and hidden by `BrowseFrame:HookScript("OnShow"/"OnHide")`. It holds:
    - the header
    - one checkbox per `Orders.RISKS`, labelled with `RISK_LABELS` and bound to `filters.hideRisks[risk]`, plus "Hide unscored". Each click sends `ORDERS_CHANGED`, so the rows re-dim.
    - "Claims remaining: N"
    - the "Claim Best Order" button. `:ClaimBest(` is called directly inside its `SetScript("OnClick", ns.FS:Wrap(...function() ... end))`.
    - "Best: <BestText>", where the benchmark is `Ledger:Benchmark(recipeID, nil)` and the item text is the cached hyperlink, else `tostring(itemID)`
    - a result line. It shows "Claimed — open it from the order list" or "Claim failed (<Enum name>)". Only our own pending claim is reported; Blizzard's own Start Order claims are ignored. It also shows a reason line when nothing was claimed, and the Add to Queue result.
  - **OrderViewWarning** is its own frame, a child of `OrderView`, anchored `BOTTOMLEFT` to `OrderView` `TOPLEFT` (8, 2). It shows "Blocked customer: <name>" in red (`Customers:IsBlocked`, which is group-aware) or "VIP customer · <n> previous orders" in gold. It is hidden for NPC orders and other customers, and it refreshes on `CUSTOMERS_CHANGED`.

`Modules/Orders.lua`: new `Orders:GetBestCandidate()`, which returns a view, or nil plus `"disabled"`, `"noProfession"`, `"alreadyClaimed"` or `"none"`. It and `ClaimBest` now share one local, `best_of_board`, which is `GetBestClaimable` over the open profession's unexpired `GetLiveViews()` with that profession's claims remaining. This follows the Task 5 ruling: the panel's best order and the button's claim come from the same code. `ClaimBest`'s behaviour is unchanged, and so are its checks and their order.

Test infrastructure:
- `tests/helpers/professions_frame.lua` now builds `OrdersPage.BrowseFrame.OrderList.ScrollBox` (with RegisterCallback, ForEachFrame and GetFrameLevel) and `OrderView.SetOrder`. Writes to all of them are recorded, as the existing fakes do. It adds the options `withoutBrowseFrame`, `withoutOrderList` and `withoutOrderView`, and the helpers `orderElement`, `newOrderRow(geometry)`, `acquireOrderRow`, `releaseOrderRow`, `showBrowse` and `hideBrowse`.
- `tests/helpers/wow_stubs.lua`: `ScrollUtil.Add*FrameCallback` now registers on the box as Blizzard's `ScrollUtil.lua` does. A plain table is still a no-op, so the existing stub spec passes. I added a stub spec for the new behaviour.
- `.luacheckrc`: `ScrollUtil` added to read_globals.
- Contract: added a `[phase 2 Task 8]` bullet listing `GetBestCandidate`, the `ns.UI.OrdersPanel` functions and the module APIs.

## Rulings and notes applied

- **P1 (Add to Queue):** `Queue:Add` already accepts `orderID` as a pass-through. It is stored by Queue:Add and covered by the existing `tests/queue/queue_spec.lua:63`, so Queue needed no change. The entry is `{recipeID, quantity = 1, charKey = view.charKey, orderID, providedReagents (the order's customer reagents; omitted when empty), targetQuality, useConcentration}`. Two deviations:
  - `targetQuality = minQuality` only when it is above 1. This matches Orders' scoring, where quality 1 or 0 means "no target".
  - `useConcentration = true` is added when the score assumed concentration, so the queued craft reaches the quality the score was based on.
  - Recraft orders get no button, because Craft Next cannot recraft. A second click on the same order says "Already in the queue".
- **Task 5:** the best line comes from `Orders:GetBestCandidate()`, which is `GetBestClaimable(GetLiveViews())` filtered exactly as `ClaimBest` filters. The brief's literal `GetBestClaimable(GetLiveViews())` without claim info or a profession filter would exclude every public order (claims unknown counts as none) and could show another profession's order, so the panel would differ from what the button claims.
- **Task 4 carry:** recraft and unknown-concentration orders show "recraft" / "conc?" in the score cell, with the full phrases in the tooltip. Their score is nil, so they are never "best".
- **No taint:** only own frames; anchoring to Blizzard frames; reads (`row.cells[1]`, GetRight/GetLeft/GetStringWidth/GetFrameLevel/IsVisible) and post-hooks. Tests assert `form.assignedFields == {}` for the rows, the side panel and the warning.

## Tests and results

New: `tests/ui/orders_panel_spec.lua` has 30 specs: the brief's 3, 8 for the pure helpers, and 19 against the fake Professions frame.
- Row cells: placement, the tooltip, the tints and refreshing on customer changes, dimming by filters, buckets and released rows, Add to Queue, zero-touch layout (measured and fallback, and the backing for long names), the container parent, anchors and clipping, hooks installed once and doing nothing while off, and a missing order list.
- Side panel: docking and visibility, the filter checkboxes, the best line equal to `GetBestCandidate` and the claim it triggers, the claim response lines, turning it off on its own, and a missing BrowseFrame.
- Warning: blocked, VIP, refresh, NPC, the anchor, and a missing SetOrder.

Also: 2 `GetBestCandidate` specs in `tests/orders/board_spec.lua` and 1 ScrollUtil stub spec.

RED, before the implementation (`busted tests/ui/orders_panel_spec.lua tests/orders/board_spec.lua`):
```
51 successes / 0 failures / 32 errors / 0 pending
... failed to load UI/OrdersPanel.lua: cannot open UI/OrdersPanel.lua: No such file or directory
tests/orders/board_spec.lua:214: attempt to call method 'GetBestCandidate' (a nil value)
```
GREEN: `busted tests/ui/orders_panel_spec.lua tests/orders/claim_click_only_spec.lua && luacheck .`
```
37 successes / 0 failures / 0 errors / 0 pending
Total: 0 warnings / 0 errors in 111 files
```
Full suite: `busted` gives `1488 successes / 0 failures / 0 errors / 0 pending`. `luacheck .` reports 0 warnings.

Mutation check: I wrapped the OnClick's `O2:ClaimBest()` in an inline closure. `claim_click_only_spec` then failed with "UI/OrdersPanel.lua:710 references ClaimBest other than as a :ClaimBest( call directly in an OnClick handler". The change was reverted.

## Files changed

- `UI/OrdersPanel.lua` (new)
- `tests/ui/orders_panel_spec.lua` (new)
- `Modules/Orders.lua`
- `tests/orders/board_spec.lua`
- `tests/helpers/professions_frame.lua`
- `tests/helpers/wow_stubs.lua`
- `tests/helpers/wow_stubs_spec.lua`
- `FabricationStation.toc`
- `.luacheckrc`
- `docs/superpowers/plans/2026-10-30-fs-interface-contract.md`

## Self-review findings (fixed before commit)

- A re-attach branch in the side panel read `IsVisible` through a number-only getter. It is now a boolean `is_visible` helper.
- One spec acquired a row with no scored order and expected cells. The test now shows the board first.
- I checked that `OnDisable` of the row module sends no message, so the brief's Guard test sees `FS_MODULE_FAILED` as the last message.
- I checked that the only `ClaimBest` / `ClaimOrder` tokens in OrdersPanel outside comments are the one OnClick call.

## Concerns

1. **In-game check (Step 5) has not been run**, including the taint log. Layout values come from the 12.1.5 Blizzard source in wow-ui-source: the table is 777 wide with fixed columns totalling 470, and `row.cells[1].Text` is the item-name font string. The strip is 140 px at the right of the item-name column. Long item names get a dark backing behind the strip rather than hiding it, because the score is the point of the feature; this differs from the H1 rule, where the label yields to the name. Please check alignment while scrolling, and that the "+" and risk-icon hit areas (the only mouse-enabled parts) do not get in the way of clicking rows.
2. The container is a child of Blizzard's ScrollBox, so it is shown and hidden with the box (for example during the loading spinner). That means an own frame is parented to a Blizzard frame, which is not a field write and is the same kind of change as RecipeListLabels' `row:CreateFontString`. If review prefers no Blizzard parent at all, the fallback is a UIParent child plus `ScrollBox:HookScript("OnShow"/"OnHide")`.
3. Shared test infrastructure changed: the ScrollUtil stub now registers on boxes that have `RegisterCallback`, and the fake frame has the orders list. The full suite is green.
4. The "repeat" tint colour and the Add to Queue `useConcentration` / `targetQuality > 1` rule are my own choices (see Rulings).

---

# Fix round 1

Commit: 81d513d fix: lay out order-row cells after Blizzard fills the row and let them give way to the item name

## Changes, by review item

1. **Measure after Blizzard fills the row.**
   - Rows are now shown and laid out from `ScrollUtil.AddInitializedFrameCallback` (OnInitializedFrame, after Blizzard's initializer). The acquire callback is gone, and Released still hides. A missing `AddInitializedFrameCallback` or `AddReleasedFrameCallback` is a missing hook target.
   - The fake `acquireOrderRow(row, elementData, new, fill)` now plays Blizzard's order: OnAcquiredFrame callbacks, then `fill` (the initializer), then OnInitializedFrame callbacks.
   - The stub `ScrollUtil` gained `AddInitializedFrameCallback`, and its stub spec covers it.
   - New spec: a recycled row goes from a short name to a long one written by the initializer (strip hidden), then back (strip shown).
2. **Give way to the name (H1-6), no backing.** `fit()` returns `"all"`, `"noProfit"` or `"none"`.
   - The strip, right to left, is `[profit][warning][score][risk][+]`. Score, risk and + (86 px) always stay together; the profit cell needs 46 more and the warning icon 16 more.
   - The profit cell goes first, then the whole strip. The row's tint and dim overlay stay.
   - The blocked warning icon now sits inside the strip, so it follows the same rule.
   - A row that cannot be measured keeps everything.
   - Specs: short / medium / long names, the blocked variant (including a name width where the icon costs the profit cell), and `assignedFields == {}` in each.
3. **Add to Queue.**
   - With an `unreachableQuality` risk, `useConcentration` stays off.
   - Views with `unknownRecipe` get no entry, so no button.
4. **Recraft profit cell:** shows "—".
5. **`compact`:** profits round toward zero and losses away from it. -3.9g shows "-4g", -45.01s shows "-46s", and a loss just under 1g shows "-1g", never "-100s". The comment and `sign_color` were updated to match.
6. **`claim_click_only_spec`:** new test asserting exactly one `:ClaimBest(` call in the code base, in `UI/OrdersPanel.lua`.
7. **OrderViewWarning on re-enable:**
   - `OnDisable` clears the remembered order.
   - Every attach, including re-enable, rebuilds the warning from `OrderView.order` (a read; Blizzard's SetOrder keeps it there) while OrderView is visible, and otherwise clears it.
   - `AttachIfReady` of all three modules now also runs when already attached, so re-enabling refreshes even without `IsAddOnLoaded`.
   - The fake's `SetOrder` keeps `order` like Blizzard's (rawset, not recorded).
8. **Best line waits for item data.**
   - It follows H1's pattern: register `GET_ITEM_INFO_RECEIVED` first, then `RequestLoadItemDataByID`.
   - If the data arrives inside the request, the refresh in progress reads the link itself.
   - One item is awaited at a time, and it is not requested again while the wait lasts.
   - The event is unregistered when the data arrives (success or failure), when a cached or different best order appears, when there is no best order, when the panel hides, and when the module turns off.

## Tests

RED: the new specs run against the round-0 `UI/OrdersPanel.lua` (stashed) with `busted tests/ui/orders_panel_spec.lua tests/orders/claim_click_only_spec.lua`:
```
33 successes / 10 failures / 1 error / 0 pending
```
- Failing: the cell texts (compact, em dash), the queue entry, the recraft row, placement, give-way, the warning icon in the strip, the recycled row, both item-data waits, and the warning re-enable.
- Error: the hooks-once spec, which now expects an OnInitializedFrame callback.
- The new exactly-one-caller spec passes on both versions, as expected.

GREEN:
```
busted tests/ui/orders_panel_spec.lua tests/orders/claim_click_only_spec.lua  -> 44 successes / 0 failures / 0 errors
busted                                                                         -> 1495 successes / 0 failures / 0 errors / 0 pending
luacheck .                                                                     -> Total: 0 warnings / 0 errors in 111 files
```

## Files changed

- `UI/OrdersPanel.lua`
- `tests/ui/orders_panel_spec.lua`
- `tests/orders/claim_click_only_spec.lua`
- `tests/helpers/professions_frame.lua`
- `tests/helpers/wow_stubs.lua`
- `tests/helpers/wow_stubs_spec.lua`
- `docs/superpowers/plans/2026-10-30-fs-interface-contract.md` (the Task 8 bullet now covers the queue rules and the give-way layout)

## Concerns

- **Remaining timing risk in game.** Blizzard's table builder fills the item-name cell from its own OnInitializedFrame callback (`ScrollUtil.RegisterTableBuilder`), and CallbackRegistry does not promise an order between owners. The item name is also set asynchronously (`ContinueOnItemLoad`) for uncached items. So our first measurement of a row can still see the old text.
  - The ShowOrders post-hook and every ORDERS_CHANGED / CUSTOMERS_CHANGED re-measure every row on screen.
  - If the in-game check shows wrong give-way decisions while scrolling, the robust follow-up is to measure the name with our own hidden FontString in Blizzard's font (Number14FontWhite) from the order's item name. That needs no Blizzard text at all.
- The in-game Step 5 check (including the taint log) is still outstanding.

---

# Fix round 2

Commit: c83341a fix: re-fit order-row cells on the next frame and remember item data that failed to load

## Changes

- **Coalesced re-fit pass (ruling).**
  - `show_row` still runs on OnInitializedFrame, so values and tint appear at once. It now also calls `schedule_refit()`, which is `ns.FS:Debounce("ordersRowAddons.refit", 0, refitPass)`.
  - `refitPass` is `ns.FS:Wrap("OrdersRowAddons", fn)`, and `fn` returns unless the module is enabled. The pass walks `rowsBox:ForEachFrame` (the current frames only, so it needs no released-row guard) and runs `apply_fit` only on shown cell sets.
  - `apply_fit` is the fit part split out of `show_row`. It sets `c.fit`, the warning icon, the profit anchor and visibility, and the strip visibility.
  - There is no bare `C_Timer.After`.
- **Item-data triggers.**
  - `ITEM_DATA_LOAD_RESULT` and `GET_ITEM_INFO_RECEIVED` schedule the same pass. They are registered on `OrdersRowAddons` only while it is attached, enabled and the ScrollBox is visible.
  - `listen_for_items(on)` is driven by the ScrollBox's `HookScript("OnShow"/"OnHide")` and by attach and re-attach (`is_visible(box)`). `OnDisable` unregisters them.
  - The OnHide hook and `OnDisable` both cancel the pending pass with `CancelDebounce`.
  - The ScrollBox must now have `HookScript`, or it is reported as a missing hook target. `is_visible` moved to the shared helpers.
- **Failed item loads.** `on_item_info(_, itemID, success)` records `success == false` in a session table `failedItems`. `best_item_text` shows such an ID without requesting it again and without registering the event.
- The unmeasurable-row fallback (`"all"`) is unchanged, as ruled, and goes on the in-game checklist.

## Tests

New specs in `tests/ui/orders_panel_spec.lua`:
1. "re-fits on the next frame when Blizzard writes the name after our callback": the name is widened after the Initialized callbacks. The fit stays `"all"` until `W.advance(0)`, then becomes `"none"`, the strip is hidden, the score text is untouched, and no Blizzard field is written.
2. "re-fits when item data arrives while the list is on screen, and listens only then":
   - `ITEM_DATA_LOAD_RESULT` gives `"all"`, then `"noProfit"` after the next frame. Two `GET_ITEM_INFO_RECEIVED` events are coalesced and give `"all"`.
   - The events are unregistered on the ScrollBox's OnHide and registered again on OnShow.
   - Turning the module off unregisters them and cancels the pending pass. A list shown while the module is off does not register them. Turning the module on registers them again.
3. "shows an item whose data failed to load as its ID and does not ask again": `GET_ITEM_INFO_RECEIVED(222222, false)` gives "Best: 222222 …" with the event unregistered. Later refreshes and a hide/show of the list make no new request.

RED, with the round-1 `UI/OrdersPanel.lua` stashed: `busted tests/ui/orders_panel_spec.lua` gives
```
36 successes / 3 failures / 0 errors / 0 pending   (exactly the three new specs)
```
GREEN:
```
busted tests/ui/orders_panel_spec.lua -> 39 successes / 0 failures / 0 errors
busted                                -> 1498 successes / 0 failures / 0 errors / 0 pending
luacheck .                            -> Total: 0 warnings / 0 errors in 111 files
```

## Files changed

- `UI/OrdersPanel.lua`
- `tests/ui/orders_panel_spec.lua`

## Concerns

- `GET_ITEM_INFO_RECEIVED` fires often while the list is open (other addons' tooltips, for example). Each burst costs one coalesced fit pass per frame over the visible rows; each pass only reads geometry. This is cheap, but worth watching in the in-game check.
- In-game check items still open:
  - Step 5, including the taint log.
  - Rows that cannot be measured (fallback `"all"`).
  - The cells giving way to long names while scrolling.
