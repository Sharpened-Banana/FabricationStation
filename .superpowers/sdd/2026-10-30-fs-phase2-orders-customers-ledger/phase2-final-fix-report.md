# Phase 2 final fix wave: report

BASE 95c31dc (branch feat/fabricationstation). Baseline: `busted` 1662 green, `luacheck .` 0/0.
Work list: phase2-final-findings.md. KEEP DEFERRED items were left alone.
Note: the container restarted after the I4 commit; I1-I4 were committed before it (evidence below was captured at
the time). The minors were done after the restart.

## I1. Order entries outlive their order; Craft Next crafts them unclaimed (commit 1ba4da7)

What I did:
- (a) `Modules/Queue.lua`: `Queue:OnEnable` registers `ns.Msg.ORDER_FULFILLED`. The handler removes every stored
  entry whose `orderID == fulfilled.orderID` and sends one `FS_QUEUE_CHANGED`; nothing when no entry matches, the
  payload is malformed, or `dbIsNewer` (it goes through `store()`, which is nil while read-only).
  **Deviation:** the finding says `Wrap "Queue"`. `Queue` is a core module, and `SafeCall` with a module's own name
  disables that module on error. I used the source name `"Queue:OrderFulfilled"` (like the existing
  `"Queue:Recompute"`), which only logs, so an error cannot turn off the queue.
- (b) `Modules/QueueCraft.lua`: new blocker `{status = "order", entryID, charKey, skillLineID, orderID}` for an entry
  with `orderID` unless `C_CraftingOrders.GetClaimedOrder()` returns a table with that orderID (helper
  `order_claimed`, guarded for a missing API). Checked after "open" (another character / window closed: you cannot
  claim there either) and before "missing". Such an entry never reaches CraftRecipe; later entries are still tried.
- (c) `UI/Tabs/Queue.lua`: `StatusText` "order" -> `Start (claim) the order first: <recipe name>` (falls back to
  `order #<id>`); `BuildRows` copies `orderID`; `CellTexts` adds a dim `[order]` marker; new
  `Tab.RowTooltip(row) -> {"Crafting order #<id>"} | nil`, shown on row hover (`SetMouseMotionEnabled(true)` so the
  row takes hover only, not clicks or the wheel). ProfessionPanel's Craft Next shares `QueueTab.StatusText`, so it
  gets the text too.
- (d) Contract: CraftNextResult gains `"order"` and `orderID?`; the fulfilled-order removal is described.

Tests:
- tests/queue/queue_spec.lua "fulfilled crafting orders": removes only that order's entries with one
  FS_QUEUE_CHANGED; nothing for no match / malformed payload; nothing written while dbIsNewer; stops when disabled.
- tests/queue/craft_spec.lua: the existing orderID test now stubs `GetClaimedOrder` (claimed -> crafts with orderID
  42); unclaimed (and another order claimed) -> "order", `world.crafts` empty, and a plain entry behind it is crafted
  with no orderID; an unclaimed order is reported before a later entry's blocker.
- tests/ui/queue_tab_spec.lua: StatusText("order") with and without recipe name; `[order]` marker and RowTooltip.

RED: `busted tests/queue/queue_spec.lua tests/queue/craft_spec.lua tests/ui/queue_tab_spec.lua`
-> `154 successes / 5 failures` (queue_spec@314, craft_spec@144, @157, queue_tab_spec@13, @18).
GREEN: `busted tests/queue tests/ui/queue_tab_spec.lua` -> `172 successes / 0 failures`; full suite 1670 / 0,
luacheck 0.

## I2. Tip benchmark quality mismatch (commit 4526323)

What I did: `ns.UI.OrdersPanel.BenchmarkQuality(view)`; the side panel's best line
(`ledger:Benchmark(view.recipeID, M.BenchmarkQuality(view))`) and the Orders tab's `benchmark_quality` both use it,
so `BenchmarkText` labels the quality it used. Ledger:Benchmark's comment says the quality is the delivered (crafted)
one; the contract says so too (I3). No stored data changed.
**Deviation (refinement):** the finding's rule is "expectedQuality when > 1, else minQuality when > 1, else nil". When
the evaluation falls short of the minimum (unreachable even with concentration), an order is still only delivered at
its minimum or better, so I raise expectedQuality to minQuality: `q = expected > 1 and expected or nil; if min > 1
and (q == nil or q < min) then q = min`.

Tests:
- orders_panel_spec "benchmarks with the quality the order will be delivered at": 7 cases incl. expected 3/min 2 ->
  3, expected 2/min 3 -> 3, no result/min 3 -> 3, expected 1/min 0 -> nil, nil view -> nil.
- orders_panel_spec side panel: a spy on Ledger.Benchmark gets `(4444, 3)` for the best order (expectedQuality 3,
  min 2) = BenchmarkQuality(best).
- orders_tab_spec: tooltip asks `(4444, 4)` for `{minQuality = 2, result = {expectedQuality = 4}}` and labels Q4;
  `{minQuality = 0, result = {expectedQuality = 1}}` asks with nil.

RED: `busted tests/ui/orders_panel_spec.lua tests/ui/orders_tab_spec.lua` -> `76 successes / 2 failures / 1 error`
(panel@476 benchmark asked with nil, tab@289, panel@55 BenchmarkQuality missing).
GREEN: same command -> `79 successes / 0 failures`; full suite 1674 / 0, luacheck 0.

## I3. Interface contract behind phase 2 (commit 1e203a7)

docs/superpowers/plans/2026-10-30-fs-interface-contract.md, a "[phase 2]" layer:
- Fixed: line 56 (`hooksecurefunc` is now stubbed with W.hooks; plus C_CraftingOrders.*, C_DateAndTime,
  GetItemCraftedQualityByItemInfo, mail globals, PlaySound/SOUNDKIT, ScrollUtil); "owned by later plans" heading ->
  "Phase 2 (built; phases 3/4 may depend on it)"; TOC list now 1a + 1b + phase 2 with the 11 phase-2 files marked.
- Added: ns.Msg ORDER_FULFILLED / PERSONAL_ORDER_ARRIVED; Bus rows; `ns.Util.SettingsAccessor` with the
  session-copy rule; option group `orders` 40; `Dashboard.SetLines`, widgets openOrders 40 / goldThisWeek 50 and the
  ORDERS/LEDGER_CHANGED dashboard refresh; lazy SV keys (ledger.costBasis/nameIndex, ordersSnapshot with profession
  and SNAPSHOT_RESULT_KEYS, ordersState.personalCounts, ordersUnknownRewards {count, lastSeen, orders},
  settings.orders/alerts/ledger with defaults); OrderInput, full OrderView, CustomerRecord, LedgerEntry as built,
  Ledger totals + "incomplete > 0 means profit is an upper bound"; Orders / Customers (group-aware IsBlocked) /
  Ledger (Add raise rules, Query live rows, Benchmark skips recraft and negative tips, delivered quality) /
  OrderAlert APIs; ns.UI.OrdersOptions / OrdersWidgets / CustomersTab / LedgerTab; GameData "OrderRewards"; module
  names and which are core; tests/helpers/phase2.lua (boot/fake_module/load/raw_order/merge/NIL).
- Plan: an "As built" note on the plan's LedgerEntry (estimated?, recraft?, buyer?, deposit?, operationID?).
Test: none (docs). Grep check: a loop over every name in the finding (70+ names) found all of them in the contract.

## I4. In-game checklist Phase 2 section (commit 15be112)

docs/in-game-checklist.md: new "## Phase 2 (orders, customers, ledger)", P2-1..P2-29, each with steps and an
expected result:
- P2-1..P2-8: plan Task 13 Step 5 acceptance run (spec §7), in order.
- P2-9..P2-13: the plan's "Not verified from source" items (OrderRewards IDs from `/dump npcOrderRewards`,
  minQuality vs expectedQuality scale, SOUNDKIT.RAID_WARNING, claimed-order outputItemHyperlink +
  GetItemCraftedQualityByItemInfo, whether CraftRecipe's reagents include customer-provided slots).
- P2-14: the I1 reviewer question (Craft Next on a claimed order with provided reagents; plus the new "order"
  blocker text and that fulfilling removes the queue entry).
- P2-15..P2-29: every phase-2 "checklist:" line from progress.md (items 1-15 of the findings list); Task 8's
  long-name line in its post-ruling form ("cells give way ... no dark backing").
- H1-4b (item 16): the panel quality fallback case (game quality below max, no next threshold -> no "(game)").
- Title and intro updated to mention phase 2.
Test: none (docs); tests/tooling green.

## Minors

### M1. Unknown and zero money (commit 05dd7ad) — includes deferred T10 "sub-copper 0g plain"
- UI/Tabs/Orders.lua `sign_color` greys sign 0 (a "0g" cell); the tip cell shows grey "?" when unknown (was "--").
- UI/Tabs/Customers.lua `money_text`: unknown tip/tipsTotal is "?" (grey in compact cells), not "no price".
- Modules/Customers.lua `RecordOrder`: a non-number tip is stored as `tip = nil` and adds nothing to `tipsTotal`.
  Contract CustomerRecord notes it.
- Net/score cells keep "no price" when a reagent price is missing (they are price-derived, per the finding).
Tests: orders_tab_spec (0.4c net/score grey `|cff9d9d9d0g|r`; unknown tip `?`), customers_tab_spec (unknown tips
`?`), customers_spec (tip nil and a non-number tip stay nil, tipsTotal 0, then a real tip adds).
RED: `busted tests/ui/orders_tab_spec.lua tests/ui/customers_tab_spec.lua tests/customers/customers_spec.lua` ->
`89 successes / 4 failures`. GREEN: same -> `93 successes / 0 failures`; full 1675 / 0; luacheck 0.

### M2. Sales from estimated crafts (commit 1921a70) — deferred T7 "costBasis carries no estimated flag"
- Modules/Ledger.lua: `add_cost_basis(..., estimated)` keeps `estimatedQty` (nil while none); `add_extra` adds the
  multicraft extra to it when the last craft entry is estimated; `OnTakeMoney` sets `sale.estimated = true` when the
  sale has a cost and the row's `estimatedQty > 0`. Contract costBasis shape updated.
Tests: capture_spec "marks a sale costed from estimated crafts as estimated" (estimated craft + multicraft extra ->
totalQty 3, estimatedQty 3; sale estimated = true; Weekly row 1 estimated = 1); the exact-cost sale test asserts
`estimated` stays nil.
RED: `busted tests/ledger/capture_spec.lua` -> `35 successes / 1 failure` (@68). GREEN: `busted tests/ledger` ->
`75 / 0`; full 1676 / 0; luacheck 0.

### M3. Ledger rescans (commit 4afd4be) — also deferred T6 "each_saved extra O(n) pass"
- Modules/Ledger.lua: `each_saved(visit)` is one `pairs` pass with a callback (no wrapper table per row, no
  separate max-key pass; whole positive indices only, so holes still never hide later rows; Query keeps its
  time/index sort, so order is unchanged). New `Ledger:Benchmarks()` (one pass; `{[recipeID] = {[quality] = s,
  all = s}}`, same sample rules via shared `benchmark_sample`/`summarize`) and `Ledger:HasIncome()` (early exit).
- UI/Tabs/Ledger.lua BenchmarkRows uses Benchmarks (falls back to per-pair Benchmark for a Ledger without it);
  UI/OrdersWidgets.lua has_sales uses HasIncome. Contract lists both.
Tests: ledger_spec "Benchmarks ... one pass, by Benchmark's rules" (equals Benchmark for each pair and "all"; recraft
and negative tips skipped; minSamples), "HasIncome" (craft / damaged row / sale / no ledger); ledger_tab_spec
BenchmarkRows output unchanged with `L.Benchmark` replaced by a counting spy (0 calls); widget sales check with
`L.Query` raising. Existing BenchmarkRows fixtures unchanged and green.
RED: `busted tests/ledger tests/ui/ledger_tab_spec.lua` -> `109 successes / 1 failure / 3 errors`.
GREEN: same -> 113 / 0 (one test expectation of mine was miscomputed and fixed: tips 9,100,200,300 -> median 150);
full 1680 / 0; luacheck 0.
Probe (reviewer's scratch ledger_perf_spec.lua, 27,375 entries, 25 pairs): LedgerTab.Model 0.668 s -> 0.153 s;
GoldThisWeekLines 0.082 s -> 0.011 s.

### M4. IsBlocked per order (commit 6f60501)
- Modules/Customers.lua `Customers:BlockedNames()`: one pass (Root per record, then every name whose root has a
  blocked member). Modules/Orders.lua `BuildContext` adds `ctx.blockedNames()` (lazy, once per context);
  `blocked(input, ctx)` reads the set and falls back to `IsBlocked` for a context without it (tests' plain tables).
  OrdersPanel / OrderViewWarning keep IsBlocked. Contract lists BlockedNames and the ctx field.
Tests: tags_links_spec "BlockedNames" (main/alt/alt-of-alt chain + solo blocked + unblocked note record; agrees
with IsBlocked for every saved name; empty without a db); score_spec new describe with the real Customers module:
20 orders, one context, `GetGroup + BlockedNames` calls <= 1, the alt of a blocked main is the only one flagged.
RED: `busted tests/orders/score_spec.lua tests/customers` -> `90 successes / 1 failure / 1 error`.
GREEN: `busted tests/orders tests/customers tests/ui/orders_panel_spec.lua tests/ui/orders_tab_spec.lua` -> 252 / 0;
full 1682 / 0; luacheck 0. Probe (500 customers): 100 IsBlocked 0.114 s vs BlockedNames + 100 lookups 0.0025 s.

### M5. Read-only rule enforced in tests (commit 5efaadb) — also deferred T7 "posthook bound to guarded helper"
- tests/helpers/professions_frame.lua: ProfessionsFrame, OrdersPage, BrowseFrame, OrderList, the order ScrollBox and
  OrderView are `read_only` proxies: a call of a method in `form.MUTATING_METHODS` (SetScript, SetParent, Hide, Show,
  SetShown, SetPoint, ClearAllPoints, SetAllPoints, SetAlpha, SetFrameLevel, SetFrameStrata, SetSize/Width/Height,
  EnableMouse, EnableMouseWheel, SetMouseMotionEnabled, SetClipsChildren) is recorded as "<Object>:<method>" and then
  runs; field writes are recorded as before; HookScript / RegisterCallback / getters pass through. The form's drivers
  (show/hide/showBrowse/hideBrowse) and the new `form.raw(proxy)` go around the recorder. The recipe-list ScrollBox,
  CraftingPage and SchematicForm (1b objects) are unchanged (outside the finding's list).
- Three existing specs played Blizzard through the proxies (`box:Hide()`, `form.orderView:Hide()`,
  `form.frame:Hide()`); they now use `form.raw(...)`. No addon code changed: every existing
  `assert.same({}, form.assignedFields)` stayed green, so no regression was hiding.
- craft_spec: exactly one `local function hook(tbl, name, fn)` in Modules/Ledger.lua, its next code line is the
  hooksecurefunc-only helper line, and no other `hook =` / `function hook` / `local hook` binding.
Tests/evidence: orders_panel_spec self-test "fake frame: records state-changing calls ..." (HookScript, getters and
form.raw not recorded; SetScript/Hide/SetParent/SetPoint/EnableMouse/SetAlpha recorded in order).
RED: with the old helper (`git stash push tests/helpers/professions_frame.lua`), `busted tests/ui/orders_panel_spec.lua`
-> `42 successes / 3 errors`; the structural test with a mutated Ledger (`hook = function(t, n, f) t[n](f) end`
inserted, then restored) -> `55 successes / 1 failure` (craft_spec @558). GREEN: full 1684 / 0; luacheck 0.

### M6. Stale cells while Orders is off (commit 1965f9b)
- UI/OrdersPanel.lua `show_row`: no view (cells hidden) while the Orders module is disabled.
- UI/Tabs/Orders.lua: `off_text` -> "Orders off: the board is not captured" (WARN colour) on the status line when
  no action status is showing (refresh and clear_status).
Tests: orders_panel_spec "shows no cells while the Orders module is off" (shown, disable, re-acquire -> hidden,
enable -> shown); orders_tab_spec "says on the status line that Orders is off".
RED: `busted tests/ui/orders_panel_spec.lua tests/ui/orders_tab_spec.lua` -> `80 successes / 2 failures`.
GREEN: same -> 82 / 0; full 1686 / 0; luacheck 0.

### M7. Slider drag rescores at every step (commit 92c5e69) — deferred T13
- Modules/Orders.lua: new `Orders:ScheduleRescore()` = `ns.FS:Debounce("orders.rescore", 0.5, Wrap("Orders", fn))`
  where fn rescores only if Orders is still enabled; Orders' own PRICES/RECIPES/CUSTOMERS_CHANGED handlers use it
  too (same key, as before). UI/OrdersOptions.lua `rescore()` calls it (when Orders is on) instead of a synchronous
  `SafeCall("Orders", Rescore)`. Implemented as an Orders method rather than duplicating the key string in the
  options file, so the key cannot drift. Contract updated.
Tests (orders_options_spec, three existing tests reworked): three sets -> 0 rescores, `W.advance(0.5)` -> 1; a set
plus FS_PRICES_CHANGED coalesce into one; off at set time -> none; off by fire time -> none; a failing rescore inside
`W.advance` is caught and turns off only Orders.
RED: `busted tests/ui/orders_options_spec.lua` -> `17 successes / 2 failures`. GREEN: with tests/orders -> 138 / 0;
full 1686 / 0; luacheck 0.

### M8. QueueCraft cleanups (commit c52a96e) — deferred H1 "RequestLoadItemDataByID throw" and T0 "queueUseWarband twice"
- Modules/QueueCraft.lua: each `RequestLoadItemDataByID` is pcall'd; an error is logged (`Queue:ShoppingList`) and
  the item leaves the wait (skipped in the list), so `w.requesting = false` is always reached and the retry runs when
  the other names arrive. `one_craft` builds `CraftEvaluateOpts(entry)` once and uses `not opts.excludeWarband`.
Tests: shopping_retry_spec "survives a load request that errors" (request for 2001 throws: export returns ok,
loading; 1001 and 3001 arrive -> list of 2, onRetry `{true, {added = 2, skipped = 1}}`, error logged). The warband
change is covered by the existing craft_spec warband tests (no behaviour change).
RED: `busted tests/queue/shopping_retry_spec.lua` -> `10 successes / 1 failure`. GREEN: `busted tests/queue` ->
119 / 0; full 1687 / 0; luacheck 0.

### M9. One-liners (commit 329d3ce) — deferred T6 ±inf time, T9 NaN delta, T2 Export date / duplicates / comment
- Ledger:Add: a time that is not a finite number (NaN, ±inf) becomes now (logged).
- OrderAlert:OnArrived: `delta ~= delta or delta <= 0` is ignored (luacheck rejects `not (delta > 0)` with W581, so
  the NaN check is explicit).
- Customers:Export: `pcall(date, ...)` and a string result required, else lastSeen ""; a seen-set drops repeated
  names (after NormalizeName, so "Bob" and "Bob-Silvermoon" are one). Header comment: Root follows the chain.
Tests: ledger_spec (time = ±math.huge -> 1000), order_alert_spec (NaN delta: no sound, no toast),
tags_links_spec (lastSeen 1e300 -> empty field, no error; `date` that throws -> empty field; Export({"Bob",
"Bob-Silvermoon", "Bob"}) -> one row).
RED: `busted tests/ledger/ledger_spec.lua tests/ui/order_alert_spec.lua tests/customers/tags_links_spec.lua` ->
`102 successes / 2 failures / 1 error`. GREEN: same -> 105 / 0; full 1688 / 0; luacheck 0.

### M10. Tab polish (commit 676adb4) — deferred T10 header/tick, T11 menu/comment, T8 comment
- UI/Tabs/Orders.lua `apply_layout`: header = whole inner width with no status; status 45% only when it has text.
  **Addition beyond the finding:** `set_status`/`clear_status` now call `apply_layout` (forward-declared), because
  Add to Queue sets the status without a refresh; without this the new zero-width status would hide the message.
- UI/Tabs/Customers.lua: OnDisable hides the pick menu; the menu's OnShow registers GLOBAL_MOUSE_DOWN only while
  CustomersTab is enabled. READ_ONLY_NOTICE comment now says it can be cut at 516 px (~218 px status) and the status
  area's tooltip shows it in full (it is ~51 characters).
- UI/OrdersPanel.lua: the 186-character comment line reflowed.
Tests: orders_tab_spec "gives the header the whole line when there is no status" (0/728, then 327/397 after a
click, no refresh); the existing "keeps the header and status lines apart" test pinned the old always-split widths
and was updated to cover both cases at 740 and 516 px; "stops its 30 s tick once the tab is hidden" (test only;
passes before and after, as the finding expects: it guards the existing behaviour); customers_tab_spec "closes when the
tab module is turned off, and never listens for clicks while it is off".
RED: `busted tests/ui/orders_tab_spec.lua tests/ui/customers_tab_spec.lua` -> `79 successes / 2 failures` (header
width, menu). GREEN: 81 / 0 on those files; full 1691 / 0; luacheck 0.

### M11. Test gaps (commit e121ec2) — deferred T13 setter loop / test name, T0 end-to-end
- orders_options_spec: "every editable option's setter (ranges, toggles, the sound select) leaves db.global
  untouched" iterates the scoring/alerts/ledger groups and asserts exactly 16 setters ran (5 scoring ranges, 5 risk
  toggles, 2 alert toggles, the sound select, toast seconds, 2 ledger ranges); the old 4-setter test stays. The
  "clear of the other top-level keys" test is renamed "... registered as \"Orders & Ledger\" beside General and
  Modules".
- scan_spec "craft, skill-up and recalibration, end to end": real Scanner + Recipes + RecipeScan on the scanner
  fixture; TRADE_SKILL_SHOW + LIST_UPDATE calibrates 1001 at baseSkill 80; a TRADE_SKILL_ITEM_CRAFTED_RESULT, skill
  75 -> 76 and TRADE_SKILL_LIST_UPDATE recalibrate it at 81.
Evidence: test-only items, green on first run (they guard existing behaviour). Mutation check for the end-to-end
spec: freezing RecipeScan's `signature()` (`return "fixed"`) makes it fail (`68 successes / 4 failures`, the new
@744 among them); restored. Full 1693 / 0; luacheck 0.

### M12. Copies left behind (commit 513552f)
- Modules/Orders.lua and Modules/Ledger.lua: `local copy = ns.Util.DeepCopy` replaces the private recursive copy.
  Depth note: the finding says depth <= 4, but Orders also copies the whole stored snapshot for the read-only
  session copy (snapshot -> orders -> view -> input -> rewards -> reward, about 6-7 levels); DeepCopy's default limit
  is 10, so nothing is cut. DeepCopy also drops functions and odd key types; views, inputs and reagent tables hold
  neither.
- Each of the three `fill` functions (Orders, Ledger, OrderAlert) now says it is deliberately separate and how its
  rules differ.
- **Optional item skipped:** sharing `current_profession` / `ok_result` between Orders.lua and OrdersPanel.lua.
  OrdersPanel's copies keep the side panel working with the Orders module missing, and moving them would add a
  cross-module call path for no behaviour change; left as is.
Tests: existing snapshot / board / read-only specs (no behaviour change). Full 1693 / 0; luacheck 0.

## Summary

Commits (95c31dc..HEAD, oldest first):
- 1ba4da7 fix: drop fulfilled orders from the queue and craft order entries only while claimed
- 4526323 fix: ask the tip benchmark for the delivered quality on the board and in the Orders tab
- 1e203a7 docs: bring the interface contract up to phase 2 as built
- 15be112 docs: add the Phase 2 section to the in-game checklist
- 05dd7ad fix: show unknown money as "?" and sub-copper amounts grey across the order tabs
- 1921a70 fix: mark AH sales costed from estimated crafts as estimated
- 4afd4be perf: read the ledger once per benchmark table and stop early when checking for sales
- 6f60501 perf: look blocked customers up once per scoring context
- 5efaadb test: record state-changing calls on the fake Blizzard order objects, and pin the Ledger hook helper
- 1965f9b fix: hide the board's row cells while Orders is off, and say so in the Orders tab
- 92c5e69 fix: rescore once after a scoring slider drag instead of at every step
- c52a96e fix: keep the shopping-list wait alive when an item load request errors
- 329d3ce fix: guard Ledger times, alert deltas and Customers export against bad values
- 676adb4 fix: give the Orders tab header the full line without a status, and close the pick menu with its module
- e121ec2 test: cover every read-only options setter and the craft-to-recalibration path end to end
- 513552f refactor: use ns.Util.DeepCopy for the Orders and Ledger copies, and say why the fills differ

Final: `busted` 1693 successes / 0 failures (baseline 1662); `luacheck .` 0 warnings / 0 errors in 122 files.

Files changed:
- Modules/Customers.lua                              |  52 +++++--
- Modules/Ledger.lua                                 | 134 +++++++++++------
- Modules/Orders.lua                                 |  45 ++++--
- Modules/Queue.lua                                  |  22 ++-
- Modules/QueueCraft.lua                             |  36 ++++-
- UI/OrderAlert.lua                                  |   8 +-
- UI/OrdersOptions.lua                               |  13 +-
- UI/OrdersPanel.lua                                 |  22 ++-
- UI/OrdersWidgets.lua                               |   4 +-
- UI/Tabs/Customers.lua                              |  15 +-
- UI/Tabs/Ledger.lua                                 |  13 +-
- UI/Tabs/Orders.lua                                 |  51 +++++--
- UI/Tabs/Queue.lua                                  |  25 +++-
- docs/in-game-checklist.md                          | 163 ++++++++++++++++++++-
- .../plans/2026-10-30-fs-interface-contract.md      |  97 ++++++++++--
- ...2026-10-30-fs-phase2-orders-customers-ledger.md |   2 +-
- tests/customers/customers_spec.lua                 |   8 +
- tests/customers/tags_links_spec.lua                |  27 ++++
- tests/helpers/professions_frame.lua                |  58 ++++++--
- tests/ledger/capture_spec.lua                      |  15 ++
- tests/ledger/ledger_spec.lua                       |  33 +++++
- tests/orders/score_spec.lua                        |  30 ++++
- tests/queue/craft_spec.lua                         |  39 ++++-
- tests/queue/queue_spec.lua                         |  39 +++++
- tests/queue/shopping_retry_spec.lua                |  17 +++
- tests/recipes/scan_spec.lua                        |  49 +++++++
- tests/ui/customers_tab_spec.lua                    |  12 +-
- tests/ui/ledger_tab_spec.lua                       |  23 +++
- tests/ui/order_alert_spec.lua                      |   1 +
- tests/ui/orders_options_spec.lua                   |  47 +++++-
- tests/ui/orders_panel_spec.lua                     |  57 ++++++-
- tests/ui/orders_tab_spec.lua                       |  62 +++++++-
- tests/ui/profession_panel_spec.lua                 |   2 +-
- tests/ui/queue_tab_spec.lua                        |  14 ++

Deferred-minor triage: every INCLUDE row is done (T0 x2 -> M11/M8; T2 comment/date/duplicates -> M9; T6 ±inf -> M9,
each_saved -> M3; H1 request throw -> M8; T7 costBasis -> M2, posthook -> M5, plan LedgerEntry -> I3; T8 comment ->
M10; T9 NaN -> M9; T10 0g grey -> M1, header -> M10, ticker spec -> M10; T11 menu/GLOBAL_MOUSE_DOWN and comment ->
M10; T13 setter loop / test name -> M11, slider -> M7). KEEP DEFERRED rows were not touched.

## Deviations from the findings (code + judgement won)
- I1(a): Wrap source `"Queue:OrderFulfilled"`, not `"Queue"`: Queue is a core module and SafeCall would turn it off.
- I2: expectedQuality is raised to minQuality when it falls short (delivery is at minimum or better).
- M7: implemented as `Orders:ScheduleRescore()` (one owner of the debounce key) rather than duplicating the key.
- M10: status changes now re-run the Orders tab layout (needed once the header can take the full line).
- M12: optional current_profession / ok_result sharing skipped (reason above).

## Self-review
- Read the whole code diff (Modules/UI) after the last commit. Checked: no Blizzard frame writes added (the Queue row
  tooltip uses our own row frame; SetMouseMotionEnabled on our frame); every new saved-data write goes through
  `store()` / `store_for_write` (dbIsNewer-safe); new message handler wrapped; new debounce uses Orders' existing key
  cancelled in OnDisable; Query order unchanged by the pairs-based each_saved (sorted by time, then index).
- No long lines added over 120 characters in the changed code (one pre-existing 186-char line fixed).

## Concerns
- In-game unknowns stay unknown: P2-14 (does CraftRecipe accept a full allocation including customer-provided
  slots on a claimed order?) decides whether Craft Next must drop provided slots for order entries. Until then the
  "order" blocker only guarantees the order is claimed.
- The "order" status uses the recipe name for "<item>" (the Queue tab knows recipe names, not the order's item).
- Queue removal relies on FS_ORDER_FULFILLED, which Orders sends only for fulfilments whose click it saw (its
  FulfillOrder post-hook); a fulfilment made while Orders is off leaves the queue entry, which Craft Next now reports
  as "order" instead of casting (the player can remove it).
