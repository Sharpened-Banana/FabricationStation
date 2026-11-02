# Task 5 report: order board capture, snapshot, live updates, Claim Best Order, fulfilment, personal counts

Status: DONE_WITH_CONCERNS (the concerns are small; see the end)
Commit: eac7d3d feat: capture order board, snapshot, claim best order, fulfilment and personal counts

## What was built (Modules/Orders.lua, appended after Task 4's scoring)

- **Live set and snapshot.** Both are keyed by orderID. The live set is a file-local table that is emptied when the Professions frame hides or Orders is turned off. The snapshot is `db.global.ordersSnapshot = {time, charKey, orders = {[orderID] = view}}`. While `ns.FS.dbIsNewer` is set, the snapshot and the personal counts live in session-only copies, so nothing is written.
- `OnBoardShown(orderTypeEnum, orders)`:
  - Drops every live and stored view of that type.
  - Builds **one** context with `BuildContext(CharKey())` and calls `ScoreInput` once per order. That passes `input.orderID` to ValueRewards, so an unknown reward is counted once per order.
  - Stores a trimmed deep copy of each view (`stored_copy`): `result` keeps only `expectedQuality, reagentCost, expectedSale, profit, concentrationCost, goldPerConcentration, flags`.
  - Prunes expired stored views, sets `time`/`charKey` and sends ORDERS_CHANGED.
  - A snapshot that belongs to another character is started afresh, because its personal orders are not this character's.
- `GetSnapshot()` returns `{time, charKey, orders = list}`, sorted by orderID, leaving out views with `expiresAt < Now()`.
- `GetLiveViews()` returns the live views sorted by orderID.
- `GetView(id)` returns the live view first, then the stored one (unless expired).
- `ClearLive()` empties the live set and sends ORDERS_CHANGED.
- `Rescore()` uses one context for `BuildContext(snapshot.charKey)`. It rescores the live views and the stored-only views from their stored `input`, and refreshes stored copies.
- `OnCustomerNameUpdated` / `OnRewardsUpdated` change the order's input (NPC orders keep no customer) and score the order once. The new view goes to both the live set and the snapshot.
- `GetClaimedOrder()` returns `Normalize(C_CraftingOrders.GetClaimedOrder())`.
- `ClaimBest()`:
  - Returns `nil, "disabled"` while off and `nil, "noProfession"` when `GetChildProfessionInfo()` has no profession.
  - Otherwise builds `claim = {claimsRemaining = GetOrderClaimInfo(p).claimsRemaining, hasClaimed = GetClaimedOrder() ~= nil}`.
  - Calls `GetBestClaimable(GetLiveViews(), claim)`, then calls `C_CraftingOrders.ClaimOrder(view.orderID, profession)` at most once.
- **Fulfilment.**
  - `OnFulfillClicked(orderID, note, profession)` runs as a post-hook on `C_CraftingOrders.FulfillOrder`. It takes the claimed order (or falls back to the board view), works out quality with `GetItemCraftedQualityByItemInfo(outputItemHyperlink)` (nil without a link), values the rewards and stores a pending FulfilledOrder.
  - `OnFulfillResponse(event, result, orderID)` acts only on `Enum.CraftingOrderResult.Ok`. It adds `time`/`charKey`, sends `ns.Msg.ORDER_FULFILLED` and removes the order from the live set and the snapshot.
  - Any other result keeps the pending entry, so a retry still works.
  - The customer is recorded by the existing `Customers:OnOrderFulfilled` → `RecordOrder` handler on that message (Task 1's contract). Orders does not call `RecordOrder` directly, because that would record twice. NPC orders send `customer = nil`. An integration spec with the real Customers module confirms both cases.
- `UpdatePersonalCounts(infos)`:
  - Counts are stored per character in `db.global.ordersState[charKey].personalCounts[profession]`.
  - The first count seen for a profession is a baseline. A rise counts as an arrival, and each arrival sends `PERSONAL_ORDER_ARRIVED(professionName, count, delta)`.
- `InstallBoardHook()`:
  - Uses `hooksecurefunc(ProfessionsFrame.OrdersPage, "ShowOrders", …)` → `OnBoardShown(page.orderType, C_CraftingOrders.GetCrafterOrders())`, plus `ProfessionsFrame:HookScript("OnHide", …)` → `ClearLive`.
  - Hook bodies are wrapped with `ns.FS:Wrap("Orders")` and return early while Orders is off. The `self.attached` flag makes them install once.
  - If the target is missing it returns false and calls `LogError("Orders", "hook target missing: ProfessionsFrame.OrdersPage.ShowOrders")` plus one chat line (once per session). The rest of Orders keeps working.
- `OnEnable`:
  - Registers ADDON_LOADED("Blizzard_Professions") → `InstallBoardHook`, and calls it directly when the addon is already loaded and ProfessionsFrame exists.
  - Registers the 5 CRAFTINGORDERS events. UPDATE_ORDER_COUNT acts only for the Personal type, and both count events read `GetPersonalOrdersInfo()`.
  - Registers PRICES/RECIPES/CUSTOMERS_CHANGED → `Debounce("orders.rescore", 0.5, Wrap(Rescore))`.
  - Installs the FulfillOrder hook once (`self.hooked`). Every handler is `ns.FS:Wrap("Orders", …)`.
- `OnDisable` cancels the pending rescore, drops the live set and pending fulfilments, and sends ORDERS_CHANGED.

## Tests

- `tests/orders/board_spec.lua`: the brief's 7 examples verbatim, plus 30 more:
  - `snapshot_stores_trimmed_copy`, and scoring once per capture (BuildContext once, Evaluate once per order, unknown reward counted once even after Rescore).
  - Messages and ordering, ClearLive / GetView fallback, a fresh snapshot for another character, stored-only rescore.
  - Reward updates, ignored updates.
  - ClaimBest: noProfession, live board only, public order with no claims left, disabled.
  - Fulfilment: pending kept after a failure, order removed on success, nil quality without a link, NPC fallback with `npcCreatureID`, unknown order, FulfillOrder hook installed once and ignored while off.
  - Personal counts persisted and announced, malformed input.
  - Event routing, RECIPES_CHANGED rescore, pending rescore cancelled on disable.
  - dbIsNewer makes no writes but still works for the session.
  - Board hook: capture plus OnHide, single install across ADDON_LOADED and re-enable, ignored while off, missing target logged and printed once, works on the shared fake frame with `assignedFields == {}`, other addons ignored.
  - Real-Customers integration.
- `tests/orders/claim_click_only_spec.lua`:
  - Scans every `.lua` file in `read_toc("FabricationStation.toc").files` together with `find Core Data Math Modules UI`.
  - Uses a whole-file tokenizer that handles `--`, `--[[ ]]`, `--[==[ ]==]`, long strings and quoted strings, and tracks line numbers. It tracks blocks (function/do/if/repeat … end/until) and parentheses.
  - Any `ClaimOrder` name **or string** (calls, `pcall(C_CraftingOrders.ClaimOrder, …)`, aliases, `["ClaimOrder"]`) must sit with `function Orders:ClaimBest` as its innermost function, in Modules/Orders.lua, exactly once.
  - Any `ClaimBest` reference (`ClaimBestOrder` included) other than its definition must be in UI/OrdersPanel.lua, with the innermost function being the first function inside `SetScript("OnClick", …)`. That covers `Wrap(…, function() … end)`. A timer or closure nested inside the handler fails, and so does a pass-through `Wrap(name, Orders.ClaimBest)`.
  - Self-tests: the tokenizer, an accepted case, and a flagged case covering timer / OnEnter / pcall / alias / string key / nested ClaimOrder / handler-less SetScript / comments. Every file's block depth must return to 0, which guards the scanner.
  - Until Task 8 there is no caller, so the second assertion holds trivially.

### TDD evidence
RED, `busted tests/orders/board_spec.lua tests/orders/claim_click_only_spec.lua` before the implementation:
```
5 successes / 8 failures / 28 errors / 0 pending
... attempt to call method 'OnBoardShown' (a nil value)
claim_click_only_spec.lua:179: expected exactly one ClaimOrder reference, got:   (0 vs 1)
claim_click_only_spec.lua:194: Expected to be truthy (no function Orders:ClaimBest)
```
GREEN: `busted tests/orders` → `99 successes / 0 failures / 0 errors / 0 pending`.
Full: `busted` → `1315 successes / 0 failures / 0 errors / 0 pending`; `luacheck .` → `0 warnings / 0 errors in 102 files`.

## Files changed
- `Modules/Orders.lua` (+395)
- `tests/orders/board_spec.lua` (new), `tests/orders/claim_click_only_spec.lua` (new)
- `tests/helpers/professions_frame.lua` (1b helper): the fake ProfessionsFrame now has an `OrdersPage`, a recorded proxy with `ShowOrders` and `orderType` (`opts.orderType`), plus `form.ordersPage` / `form.showOrdersCalls`. Without it, Orders' missing-target log broke three ProfessionPanel specs that assert `diagnostics.errors[1].source` / `#errors == 0`. The real Blizzard_Professions always has OrdersPage.
- `tests/helpers/wow_stubs.lua` (1a stub): `hooksecurefunc` now installs its wrapper with `rawset`. A secure hook is the sanctioned mechanism, not an addon field write, so the recording proxies (`assignedFields`) still catch real writes. The existing wow_stubs specs still pass.
- `.luacheckrc` unchanged (C_AddOns was already there).

## Deviations from the brief / dispatch
- The dispatch said "Orders:ClaimBestOrder"; the brief and its tests use `Orders:ClaimBest`, so that name is used. The structural test catches `ClaimBestOrder` too.
- Dispatch: "On fulfilment call Customers:RecordOrder". This is done through the bus, because Customers already records on `ns.Msg.ORDER_FULFILLED` (Task 1). A direct call would duplicate it. The integration spec proves the record is made.
- Additions beyond the brief:
  - `Orders:ClearLive()` (public, used by the OnHide hook).
  - The ClaimBest reasons `"disabled"` and `"noProfession"`.
  - A snapshot is restarted when a different character shows the board.
  - `GetView` hides expired stored views, to match GetSnapshot.
  - Worth noting in the interface contract (I did not edit the contract docs).

## Self-review findings (fixed before commit)
- The fake frame's metatable returns stub functions for unknown fields, so `ProfessionsFrame.OrdersPage` needed `type(...) == "table"` guards.
- busted's `called_with` deep-copies arguments. A spec comparing the module object failed because saved data changed after the call, so it now uses `match.is_ref`.
- OnDisable now also sends ORDERS_CHANGED, so UIs drop the cleared live views.

## Concerns
1. **In-game check (Step 5) was not run.** No client is available. Still unverified: the snapshot count after opening the Personal/Patron tabs, and whether `CRAFTINGORDERS_UPDATE_PERSONAL_ORDER_COUNTS` fires at login.
2. On the Public tab, drilling into one bucket calls `ShowOrders` with only that item's orders. Following the brief ("replaces that type's views"), the public views are then just that bucket. The snapshot also holds only the last profession's board per type.
3. ClaimBest picks from all live views. It ignores the user's display filters (`IsHidden`) and applies only `GetBestClaimable`'s own rules (claimMinScore, claimBlockingRisks, claims left). Task 8's side panel should show the order chosen by `GetBestClaimable(GetLiveViews(), …)` so that what the button shows matches what it claims.
4. `hooksecurefunc(C_CraftingOrders, "FulfillOrder")` and `hooksecurefunc(OrdersPage, "ShowOrders")` follow the global constraints (allowed post-hooks). Their taint behaviour has not been checked in game.

---

# Fix round 1

Commit: e6c7643 fix: claim only orders on screen, track claim responses, scope the board by profession.
Files changed: Modules/Orders.lua, tests/orders/board_spec.lua, tests/orders/claim_click_only_spec.lua, tests/helpers/professions_frame.lua (the fake OrdersPage gains ShowBuckets and `form.showBucketsCalls`).

## Changes
1. **No claims on stale views.**
   - Every captured view carries `profession`, the open profession from `C_TradeSkillUI.GetChildProfessionInfo().profession`. `OnBoardShown(type, orders, profession?)` takes it, and the ShowOrders hook passes it. It is kept in `input.profession` too, so Rescore and the name/reward updates keep it.
   - `ClaimBest` considers only live views of the open profession whose `expiresAt > now`. It then checks the best view against `C_CraftingOrders.GetCrafterOrders()` at click time.
   - If the best view is not on Blizzard's board, it returns `nil, "stale"`, drops that view from the live set, sends ORDERS_CHANGED and does not call ClaimOrder.
2. **Claim responses.**
   - `CRAFTINGORDERS_CLAIM_ORDER_RESPONSE` is registered (wrapped) and handled by `Orders:OnClaimOrderResponse(event, result, orderID)`.
   - `ClaimBest` records a claim in flight. A click while it waits returns `nil, "busy"` and makes no second ClaimOrder call.
   - The response clears the claim in flight. A result other than Ok drops that order from the live set and sends ORDERS_CHANGED.
   - Timeout: a claim in flight counts as cleared after 10 s, checked at the next click against `ns.FS:Now()`, so no timer is involved. OnDisable clears it as well.
   - Reason order: disabled → noProfession → alreadyClaimed → busy → none/stale. alreadyClaimed is checked before busy because the brief's spec claims and then sets `claimed` with no response.
3. **Board scope.**
   - A capture replaces stored views per (orderType, profession). Stored views without a profession (saved before this fix) match any profession, so they are replaced once.
   - The live set keeps only the open profession's views.
   - A new `ShowBuckets` post-hook, installed in InstallBoardHook with the same pattern and returning early while Orders is off, calls `Orders:OnBucketsShown()`. That drops the live public views (the snapshot keeps them) and sends ORDERS_CHANGED.
   - A missing ShowBuckets is only logged (`hook target missing: ProfessionsFrame.OrdersPage.ShowBuckets`). The board hook is still installed.
4. **Structural spec.**
   - Identifiers match as exact tokens (`OnClaimOrderResponse`, `ClaimBestOrder` are other names). String contents still match as substrings.
   - A ClaimBest reference is accepted only as a `:ClaimBest(` call whose innermost function is the OnClick handler, in UI/OrdersPanel.lua.
   - New self-tests: values passed inside OnClick (`local f = Orders.ClaimBest`, `C_Timer.After(0, Orders.ClaimBest)`, `Orders["ClaimBest"](Orders)`) are flagged, and the exact-token matching is checked.
5. GetSnapshot/GetLiveViews/GetView are documented as returning read-only tables. Pending fulfilments are stored as `{fulfilled, at}` and pruned after 1 hour, at the next fulfil click or response.

The brief's claim example now sets `board` (what `GetCrafterOrders` returns at click time) before `OnBoardShown`. Without it, the click-time board check would find the order stale.

## Tests
New specs:
- ClaimBest: open profession only; expired skipped (with the expiringSoon blocking turned off, so only the expiry keeps it out); stale refused and dropped, next click claims the next order.
- Claim responses: busy until the response; a failed claim drops the order and announces it; 10 s timeout; disable forgets the claim in flight.
- Board scope: the other profession is kept in the snapshot and dropped from the live set; the default profession is kept through Rescore and name updates; legacy views without a profession are replaced.
- ShowBuckets: drops live public views (snapshot kept, ORDERS_CHANGED sent, ClaimBest then picks the personal order); ignored while off; missing ShowBuckets only logged.
- A pending fulfilment is dropped after an hour.
- Scanner self-tests as described in item 4.

RED: `busted tests/orders/board_spec.lua` before the implementation → `39 successes / 10 failures / 1 error` (new claim, scope, bucket and pending specs).
GREEN: `busted tests/orders` → `114 successes / 0 failures`. Full `busted` → `1330 successes / 0 failures / 0 errors / 0 pending`; `luacheck .` → `0 warnings / 0 errors in 102 files`.

## Remaining concern
Still not checked in game:
- Whether `GetCrafterOrders()` still returns the earlier flat orders after the bucket list is shown. The ShowBuckets hook covers this case either way.
- The claim response timing.
