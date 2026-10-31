# Task 0 report: phase 2 residuals

Status: DONE. Base 513552f. Preflight not applicable.

## What was built
1. `Modules/Orders.lua`: `Orders:OnEnable` ends with `self:SendMessage(ns.Msg.ORDERS_CHANGED)`. OrdersRowAddons (cells) and OrdersTab (off notice, via MainWindow:RefreshTab) already refresh on that message, so no UI change was needed.
2. `Modules/Queue.lua`: the removal body is now `remove_order_entries(orderID)`; `on_order_fulfilled` (FS_ORDER_FULFILLED) and the new `on_fulfill_response` (`CRAFTINGORDERS_FULFILL_ORDER_RESPONSE`, only when `result == Enum.CraftingOrderResult.Ok`, fallback 0) both call it. Both are wrapped with the log-only source "Queue:OrderFulfilled". `OnDisable` now also calls `UnregisterAllEvents()`. Idempotent: the second trigger finds no entries and sends nothing; the `store()` guard keeps dbIsNewer from writing.
3. Interface contract line (Queue/CraftNext, order-entry removal) now names both triggers.

## Tests
- tests/orders/board_spec.lua: "announces FS_ORDERS_CHANGED when turned back on". Because enabling Orders now announces at boot, that file's before_each strips the boot-time FS_ORDERS_CHANGED entries from W.messages (three existing count-based specs would otherwise be off by one).
- tests/ui/orders_panel_spec.lua: cells reappear on re-enable with no new board visit (no manual acquireOrderRow).
- tests/ui/orders_tab_spec.lua: after re-enable the tab is refreshed through MainWindow and the "Orders off" notice clears. The off-time refresh is drained first so the check is not vacuous.
- tests/queue/queue_spec.lua (7 new): Ok removes with one QUEUE_CHANGED; non-Ok (10, nil) does nothing; unknown order or nil orderID sends nothing; idempotent with FS_ORDER_FULFILLED in both orders; works without the Orders module (not loaded in this world, same as off); dbIsNewer writes nothing; Queue:Disable stops listening.

## TDD evidence
RED: with Modules/Queue.lua and Modules/Orders.lua stashed (tests kept), `busted tests/queue/queue_spec.lua tests/orders/board_spec.lua tests/ui/orders_panel_spec.lua tests/ui/orders_tab_spec.lua` gave `191 successes / 5 failures`: queue_spec @358 (Ok removes), queue_spec @391 (no Orders module), board_spec @129, orders_panel_spec @244, orders_tab_spec @348. The other new Queue specs pass on the old code by design (they assert "nothing happens").
GREEN: after restoring the implementation, `busted` full suite: `1703 successes / 0 failures / 0 errors`; `luacheck .`: `0 warnings / 0 errors in 122 files`. (Baseline was 1693 specs; +10 new.)

## Files changed
Modules/Orders.lua, Modules/Queue.lua, tests/orders/board_spec.lua, tests/queue/queue_spec.lua, tests/ui/orders_panel_spec.lua, tests/ui/orders_tab_spec.lua, docs/superpowers/plans/2026-10-30-fs-interface-contract.md.

## Self-review
- Diff is small; the only behavior change outside the brief is `UnregisterAllEvents()` in Queue:OnDisable, which the brief asked for ("if Queue has one"; it does).
- Orders now also sends ORDERS_CHANGED on first boot enable; listeners are guarded and it is harmless.
- The Queue spec for "Orders module disabled" asserts the module is not loaded rather than disabling it, since the queue test world does not load Orders; the behavior under test (response alone removes) is identical.

## Concerns
None.
