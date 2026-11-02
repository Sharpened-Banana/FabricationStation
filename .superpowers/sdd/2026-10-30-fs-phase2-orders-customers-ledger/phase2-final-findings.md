# Phase 2 final review: fix wave findings (all in this one dispatch)
Range a86071d..95c31dc (44 commits, Tasks 0-13 + Hotfix H1). Baseline at review: `busted` 1662 green, `luacheck .` 0/0.
Verdict: With fixes (4 Important, 12 Minor).
Scratch probes (not in the repo): /tmp/claude-0/-home-user-FabricationStation/8fbd541b-9883-5ada-b249-e0fbf0f6725a/scratchpad/p2/{ledger_perf_spec.lua,blocked_perf_spec.lua}
(run with `busted <path>` from the repo root; they print timings to stderr).

What was checked and holds: ClaimOrder is reached only from the Claim Best button's OnClick, and CraftRecipe only from
Queue:CraftNext, which is reached only from OnClick handlers (both enforced by tests/orders/claim_click_only_spec.lua
and tests/queue/craft_spec.lua). Every Blizzard touch in Modules/Orders.lua, Modules/Ledger.lua and UI/OrdersPanel.lua
is hooksecurefunc, HookScript, ScrollUtil.Add*FrameCallback (accepted in Task 8 and 1b) or a read. No SetScript, field
write or state-changing method call on a Blizzard object was found. Every saved-data write checks dbIsNewer: Orders
snapshot and state, note_unknown, Ledger Add/Prune/costBasis/nameIndex/add_extra, Customers setters, Queue:Add,
SettingsAccessor, and 1a SetModuleEnabled. Debounce keys are cancelled in OnDisable and AceEvent drops registrations.
FulfilledOrder.isRecraft and the `incomplete`/`estimated` totals agree between producers and consumers (Ledger tab,
widget). The 516 px layouts give Orders Item 128 px, Customers Name 194 / history Item 124, and Ledger flex columns at
least 176 px.

## Important

I1. Order entries in the queue outlive their order, and Craft Next crafts them unclaimed.
    - Ruling P1 adds an order to the queue with its `orderID` (UI/OrdersPanel.lua:252-283). Nothing ever removes that
      entry except Craft Next's own decrement. Queue:OnEnable (Modules/Queue.lua:377-380) listens only to
      RECIPES_CHANGED and DATA_CHANGED.
    - Queue:CraftNext (Modules/QueueCraft.lua:278-310) calls `C_TradeSkillUI.CraftRecipe(..., e.orderID, ...)` without
      checking that this character has claimed that order.
    - The usual order flow is: claim, then craft with Blizzard's own Create button in the order view, then fulfil. After
      it, the entry stays queued. Its reagents stay in the missing list and the Auctionator shopping list, and every
      Craft Next click sends CraftRecipe for a fulfilled order. That cast fails, leaves Craft Next "busy" for up to
      30 s and jams the queue on that entry. An order queued before it is claimed (any public order from the board)
      behaves the same.
    - The Queue tab never shows that an entry belongs to an order (UI/Tabs/Queue.lua has no orderID use).
    Fix:
    (a) Queue:OnEnable registers `ns.Msg.ORDER_FULFILLED` (Wrap "Queue"). It removes every real entry whose `orderID`
        equals `fulfilled.orderID` and sends QUEUE_CHANGED once. While dbIsNewer it writes nothing.
    (b) CraftNext gives an order entry (`e.orderID ~= nil`) a new blocker status "order" (`{status="order", entryID,
        charKey, orderID}`) unless `C_CraftingOrders.GetClaimedOrder()` returns a table with that orderID. Such an entry
        never calls CraftRecipe, and later entries are still tried, as for the other blockers.
    (c) Queue tab StatusText for "order": "Start (claim) the order first: <item>". BuildRows marks order entries (e.g.
        "order" in the flags/name cell, tooltip "Crafting order #<id>").
    (d) Contract: add "order" to CraftNextResult and describe the fulfilled-order removal.
    Tests:
    - queue_spec: an order entry and a plain entry. FS_ORDER_FULFILLED with that orderID removes only the order entry.
      The same message while dbIsNewer leaves the saved queue untouched.
    - craft_spec: an unclaimed order entry returns status "order" with `world.crafts` empty, and a plain entry behind
      it is still crafted. A claimed order (GetClaimedOrder stub with that orderID) crafts with orderID passed.
    - queue_tab_spec: StatusText("order") and the order marker.
    In-game question for the checklist (reviewer-proposed, not from the ledger): on a claimed order with
    customer-provided reagents, does Craft Next's CraftRecipe accept an allocation that also lists the provided slots
    (ToCraftingReagentInfo of the full allocation)? Blizzard's own UI leaves them out (Modules/Ledger.lua:434-435). If
    the game rejects it, leave the provided slots out for order entries.

I2. The tip benchmark is stored by one quality and asked for by another, and the board and the tab disagree.
    - Commission entries store the CRAFTED quality: Modules/Orders.lua:953 sets `quality =
      crafted_quality(outputItemHyperlink)`, and Modules/Ledger.lua:641-647 stores it. Ledger:Benchmark filters on it
      (Ledger.lua:318-319).
    - The Orders tab asks with the order's MINIMUM quality (UI/Tabs/Orders.lua:231-233, 272-277).
    - The board's best line asks for all qualities (UI/OrdersPanel.lua:806).
    - So the "tip vs your median" and the tab tooltip compare a min-Q2 order with your Q2 deliveries only. Q2 orders
      you crafted at Q3 (common with concentration) are filed under Q3. The same order also gets a different
      benchmark on the board than in the tab.
    Fix (no change to stored data):
    - Add `ns.UI.OrdersPanel.BenchmarkQuality(view) -> q|nil`. It returns the quality this order will be delivered at,
      matching what the Ledger stores: `view.result.expectedQuality` when > 1 (the snapshot keeps expectedQuality),
      else `view.minQuality` when > 1, else nil (all qualities).
    - Use it at OrdersPanel.lua:806 and in Orders tab `benchmark_quality`/`benchmark_for`, so BenchmarkText labels the
      quality it used.
    - Document in the contract that Benchmark's quality is the delivered (crafted) quality.
    Tests:
    - orders_panel_spec: the side panel calls Benchmark with the view's expected quality (spy on a fake Ledger).
    - orders_tab_spec: the tooltip uses the same quality for the same view.
    - A recipe without qualities (expectedQuality nil or 1, minQuality 0) asks with nil.

I3. The interface contract is behind phase 2. Phase 3/4 depend on it, and some lines are now wrong. The file is
    docs/superpowers/plans/2026-10-30-fs-interface-contract.md. Only Task 4/7/8/10 notes were added (lines 281-285).
    Fix: add a "[phase 2]" layer.
    Wrong now:
    - Line 56 says `hooksecurefunc` is "NOT stubbed by default". Phase 2 stubs it (with W.hooks), together with
      C_CraftingOrders.*, C_DateAndTime, mail globals, PlaySound/SOUNDKIT and ScrollUtil.
    - Line 279 heading "owned by later plans": phase 2 is now built.
    - The TOC list (lines 32-42) still says "final 1a + 1b order". Add the phase-2 files (Data\OrderRewards.lua,
      Modules\Customers/Orders/Ledger, UI\Tabs\Orders/Customers/Ledger, UI\OrdersPanel/OrderAlert/OrdersWidgets/
      OrdersOptions).
    Missing:
    - ns.Msg: ORDER_FULFILLED and PERSONAL_ORDER_ARRIVED (line 79).
    - Bus table: rows FS_ORDER_FULFILLED (FulfilledOrder, Orders) and FS_PERSONAL_ORDER_ARRIVED (professionName,
      count, delta; Orders).
    - Core: `ns.Util.SettingsAccessor(key) -> get(defaults, fill)`, with its session-copy-while-read-only rule.
    - Option group key `orders` order 40.
    - Dashboard: `Dashboard.SetLines(frame, lines)` (used cross-phase), widgets `openOrders` 40 and `goldThisWeek` 50,
      and that FS_ORDERS_CHANGED and FS_LEDGER_CHANGED refresh the dashboard (via OrdersWidgets).
    - SavedVariables lazy keys:
      - ledger.costBasis {[itemID]={totalCost,totalQty,recipeID}} and ledger.nameIndex.
      - ordersSnapshot {time, charKey, orders keyed by orderID, views carry `profession`, result trimmed to
        SNAPSHOT_RESULT_KEYS}.
      - ordersState[charKey].personalCounts.
      - ordersUnknownRewards[key] {count, lastSeen, orders}.
      - settings.orders, settings.alerts, settings.ledger with their defaults.
    - Shapes: OrderInput; full OrderView fields (itemID, consortiumCut, commission, rewardsValue, usedConcentration,
      concentrationCost, concentrationCharge, net, goldPerConcentration, flags incl. unpricedReward/estimated/stalePrice,
      charKey, profession, input); CustomerRecord.
    - LedgerEntry as built: + estimated?, recraft?, buyer?, deposit?, source?, operationID?, itemName?, ambiguous?.
      The plan's LedgerEntry (plan line 72) also lacks recraft?/estimated? (ledger Task 7 note); add an "as built"
      note there too.
    - Ledger totals `{income, cost, profit, n, incomplete, estimated?}`, with the rule that incomplete > 0 means the
      cost is missing or partial, so profit is an UPPER bound ("partial").
    - API:
      - Orders: Normalize, ValueRewards, BuildContext, ScoreInput, IsHidden, Filter, GetBestClaimable, GetLiveViews,
        GetView, Rescore, ClaimBest + reasons, GetClaimedOrder, UpdatePersonalCounts, Settings, RISKS/RISK_LABELS,
        SETTINGS_DEFAULTS.
      - Customers: NormalizeName, RecordOrder, SetNote, SetTag, Root, GetGroup, Link/Unlink + reasons, Export. Also
        note that IsBlocked is group-aware.
      - Ledger: Add raises only for type/amount and returns nil read-only; Query (live rows, read-only), Prune,
        WeekStart, Weekly, ByRecipe, Unattributed; Benchmark skips recraft and negative tips (plus I2's quality
        meaning); Percentile, CostOfCraft, ResolveItemName, ItemNameFromLink.
      - OrderAlert: Settings, ToastText.
      - ns.UI.OrdersOptions.Build; ns.UI.CustomersTab / LedgerTab / OrdersWidgets model functions; OrdersPanel.FilterChecks
        etc. are already listed.
    - GameData table "OrderRewards". Module names, and which modules are core.
    - Test harness: tests/helpers/phase2.lua (P2.boot/load/fake_module/raw_order/merge/NIL).
    Test: none (docs). Grep the contract for each name above.

I4. docs/in-game-checklist.md has no Phase 2 section. It stops at "Hotfix H1 re-checks" (lines 251-279), so every
    phase-2 "checklist:" line in the progress ledger is missing (list below). Fix: add "## Phase 2 (orders, customers,
    ledger)" with numbered checks (P2-1...). Each check needs steps and an expected result, in the style of the 1b
    section. Turn the Task 8 "long-name backing" line into its post-ruling form ("cells give way to long names; no dark
    backing"). Also put the plan's Task 13 Step 5 acceptance run (8 checks, spec §7) at the top of the section, and the
    plan's "Not verified from source" items:
    - OrderRewards item/currency IDs from `/dump` of npcOrderRewards;
    - minQuality vs expectedQuality scale;
    - SOUNDKIT.RAID_WARNING;
    - claimed-order outputItemHyperlink + GetItemCraftedQualityByItemInfo;
    - whether CraftRecipe's reagents include customer-provided slots.
    Add I1's question there too.
    Test: none (docs).

## Minor (include)

M1. Unknown and zero money read differently across tabs (shared-rule drift).
    - UI/Tabs/Orders.lua:165-170 leaves a "0g" cell plain, while the board (OrdersPanel.lua:188-192) and the Ledger
      tab (Ledger.lua:384) grey it. This is deferred Task 10.
    - An unknown tip reads "--" in the Orders tab (Orders.lua:222), "no price" in the Customers tab
      (Customers.lua:117-123) and "?" in the Ledger tab and on the board.
    - Customers:RecordOrder stores an unknown tip as 0 and adds it to tipsTotal (Modules/Customers.lua:107), which
      breaks "unknown money is never 0".
    Fix:
    - Orders-tab sign_color greys sign 0.
    - Compact cells show "?" for unknown money (tip included). "no price" is only for price-derived values.
    - RecordOrder stores `tip = nil` when not a number and leaves tipsTotal unchanged. The Customers UI already shows
      non-money as unknown; switch its text to "?".
    Tests: orders_tab_spec CellTexts for net 0.4c is grey; customers_spec RecordOrder with tip nil keeps tip nil and
    tipsTotal 0; customers_tab_spec unknown tip "?".

M2. Sales costed from estimated crafts look exact. This is deferred Task 7.
    - Modules/Ledger.lua:537-549 costBasis has no estimate flag. OnTakeMoney (Ledger.lua:696-705) never sets
      `sale.estimated`, so Weekly/ByRecipe/tab/widget never mark them with "~".
    - Fix: add_cost_basis keeps `estimatedQty` (the quantity fed by estimated crafts; add_extra adds to it when
      lastCraft's entry is estimated). A sale whose row has estimatedQty > 0 gets `estimated = true`.
    - Test: capture_spec: an estimated craft, then its sale. The sale has estimated = true, and Weekly row 1 has
      estimated = 1.

M3. The Ledger tab and the "Gold this week" widget rescan the whole ledger many times per refresh.
    - LedgerTab.Model (UI/Tabs/Ledger.lua:249-282) runs Query, Weekly, ByRecipe→Query, Unattributed→Query, then
      Benchmark once per (recipe, quality) pair. Each of these is a full each_saved pass, and each_saved allocates a
      wrapper per row (Ledger.lua:73-84).
    - Probe: 27,375 entries (a year at 50 crafts/day) and 25 benchmark pairs take 0.54 s per refresh on PUC Lua 5.1.
      The widget takes 0.075 s, because has_sales sorts the whole ledger (OrdersWidgets.lua:166-171).
    - Both refresh on every LEDGER_CHANGED (every craft) while shown.
    - Fix (also covers deferred Task 6 "each_saved extra O(n) pass"):
      - Add `Ledger:Benchmarks()`, one pass returning `{[recipeID] = {[quality|"all"] = {median,p25,p75,n}}}` under
        the same rules. BenchmarkRows uses it.
      - Add `Ledger:HasIncome()`, an unsorted early-exit scan, for has_sales.
      - each_saved iterates without per-row wrapper tables where the index is not needed.
    - Tests: BenchmarkRows output unchanged on the existing fixtures; a spy shows Ledger:Benchmark is not called per
      pair; HasIncome true/false.

M4. Customers:IsBlocked costs O(customers) per order. Orders scoring calls it for every order (Orders.lua:372-376), and
    Rescore runs after every scan pass, i.e. after every craft.
    - Probe: 100 IsBlocked calls over 500 customers take 0.098 s. The Task 2 carry note asked for a cached root map.
    - Fix: `Customers:BlockedNames() -> { [nameRealm] = true }` (every member of a group with a blocked member), built
      once per call. BuildContext memoises it lazily in `ctx`, and `blocked(input)` reads it.
      OrdersPanel/OrderViewWarning may keep IsBlocked.
    - Test: score_spec: scoring N orders with one ctx calls Customers:GetGroup/BlockedNames at most once; a
      blocked-via-alt customer is still flagged.

M5. The read-only rule for Blizzard objects is not enforced by tests.
    - The fake order-page objects (tests/helpers/professions_frame.lua:117-126, 217-234) record only field
      assignments. Method calls fall through to the CreateFrame target, so a `browse:SetScript("OnShow", ...)`,
      `box:Hide()` or `orderView:SetParent(...)` regression passes every `assert.same({}, form.assignedFields)`.
    - Separately, deferred Task 7: craft_spec does not prove that the posthook's `hook` is the guarded local helper.
    - Fix:
      - Wrap ProfessionsFrame, OrdersPage, BrowseFrame, OrderList, ScrollBox and OrderView so that mutating methods
        (SetScript, SetParent, Hide, Show, SetPoint, ClearAllPoints, SetAlpha, SetFrameLevel, SetSize/SetWidth/SetHeight,
        EnableMouse, SetShown) are recorded as "<Name>:<method>" in assignedFields. HookScript, RegisterCallback, getters,
        ForEachFrame and the test's own driver calls go around the recorder.
      - craft_spec asserts exactly one `local function hook(tbl, name, fn)` line in Modules/Ledger.lua and no other
        `hook =` assignment.
    - Test: a helper self-test showing that `form.browseFrame:SetScript("OnShow", f)` is recorded and HookScript is
      not; existing panel/board specs stay green.

M6. While the Orders module is off, the row cells show saved scores from the snapshot.
    - UI/OrdersPanel.lua:582-593 show_row uses Orders:GetView, which falls back to the stored snapshot. While Orders is
      disabled nothing captures or rescores, so the cells show stale scores.
    - The Orders tab does not say Orders is off.
    - Fix: show_row hides the cells when Orders is not enabled. The Orders tab status line says "Orders off: the board
      is not captured" (as the Ledger tab does).
    - Test: orders_panel_spec: with Orders disabled, ShowOrders shows no cells. orders_tab_spec: the status line.

M7. Dragging a scoring slider rescores at every step. This is deferred Task 13.
    - UI/OrdersOptions.lua:59-65 runs a full Orders:Rescore on each AceConfig set. With M4 unfixed that is about 1 ms
      per order at 500 customers.
    - Fix: `ns.FS:Debounce("orders.rescore", 0.5, ns.FS:Wrap("Orders", ...))`, sharing Orders' RESCORE_KEY so it
      coalesces with message-driven rescores. Keep the "Orders off" check at fire time.
    - Test: orders_options_spec: three sets give one Rescore after W.advance(0.5).

M8. QueueCraft cleanups (deferred H1 and Task 0).
    - Modules/QueueCraft.lua:131: a throwing RequestLoadItemDataByID leaves `w.requesting = true`, so the wait never
      completes. pcall each request, as UI/OrdersPanel.lua:784 does, and always set `w.requesting = false`.
    - QueueCraft.lua:224 reads queueUseWarband again instead of using `not opts.excludeWarband` from
      Queue:CraftEvaluateOpts.
    - Test: shopping_retry_spec: a request that errors for one item still exports and later retries.

M9. One-liners from the deferred list:
    - Ledger:Add treats ±inf `time` as now (Ledger.lua:133: add a finite check).
    - OrderAlert ignores a NaN delta (OrderAlert.lua:186: `not (delta > 0)`).
    - Customers:Export guards `date()` against an out-of-range lastSeen (Customers.lua:344: pcall, fall back to "")
      and drops duplicate names in its list.
    - The Customers.lua:9 comment "linkedTo always holds the root" becomes "Root follows the chain".
    - Tests: one assertion each in ledger_spec, order_alert_spec and tags_links_spec.

M10. Tab polish from the deferred list:
    - Orders tab header takes the full width when there is no status (UI/Tabs/Orders.lua:421-426, as Ledger.lua:789-801
      does).
    - A spec shows the 30 s tick stops once the tab is hidden.
    - CustomersTab:OnDisable hides the pick menu. The menu's OnShow registers GLOBAL_MOUSE_DOWN only while CustomersTab
      is enabled (Customers.lua:819, 1497-1501).
    - Reflow the 186-char comment at UI/OrdersPanel.lua:758. Correct the "fits" comment at UI/Tabs/Customers.lua:54.

M11. Test gaps from the deferred list:
    - orders_options_spec "while read-only" loops over every editable option's setter: all ranges, toggles and the
      select, not 4.
    - Rename the test "clear of the other top-level keys" (orders_options_spec.lua:36) to what it checks.
    - Task 0: an end-to-end spec in which a craft is followed by TRADE_SKILL_LIST_UPDATE with a raised skill, and
      that triggers a recalibration of the open profession.

M12. Copies left behind after the shared helpers.
    - Modules/Orders.lua:55-60 and Modules/Ledger.lua:47-52 keep private `copy`. Use ns.Util.DeepCopy: depth is ≤ 4
      and there are no functions.
    - The three `fill` functions are intentionally different (Orders coerces numeric strings, Ledger rejects NaN,
      OrderAlert range-checks toastSeconds). Say so in each comment so nobody "merges" them.
    - Optional: `current_profession` and `ok_result` are duplicated in Orders.lua:673-677/900-903 and
      OrdersPanel.lua:351-355/736-739; expose them once from Orders.
    - Test: existing snapshot specs.

Noted, not included:
- An unpriced patron reward makes `net` a lower bound with no cell marker; only the "i" tooltip says so.
- `rewardsValue` is stored on commissions but shown nowhere in the Ledger tab.
- SettingsAccessor's session copy is made once. If a Settings() call ever ran before InitDB and the DB then loads
  read-only, the stored values would be missed. No caller does this today.

## Deferred-minor triage (every "minor (deferred)" / "minor (final wave)" line in progress.md)
| Ledger line | Decision | Reason |
|---|---|---|
| T0 spec craft → TRADE_SKILL_LIST_UPDATE → recalibration | INCLUDE (M11) | marked for this wave; cheap end-to-end guard of the N1 fix |
| T0 one_craft reads queueUseWarband twice | INCLUDE (M8) | one-line consistency with CraftEvaluateOpts |
| T1 P2.load second call silent | KEEP DEFERRED | test helper only, no user effect |
| T1 P2.merge arrays index-wise | KEEP DEFERRED | test helper only; P2.NIL covers the real need |
| T1 RecordOrder dedupe edge cases | KEEP DEFERRED | FulfilledOrder always has an orderID; damaged rows only |
| T1 NormalizeName case / trailing dash | KEEP DEFERRED | names come from Blizzard events, already well formed |
| T2 Link doesn't flatten / comment false | INCLUDE comment only (M9) | chain still resolves via Root; behaviour acceptable, comment misleads |
| T2 Export date throws on absurd lastSeen | INCLUDE (M9) | user click path; one pcall |
| T2 ';' in tags ambiguous | KEEP DEFERRED | export is plain text, no importer reads it back |
| T2 duplicate names in Export list | INCLUDE (M9) | one seen-set |
| T5 failed claim leaves snapshot copy | KEEP DEFERRED | snapshot is "what was seen"; next capture replaces it |
| T5 stale costs one extra click | KEEP DEFERRED | by design ("stale" message, next click claims) |
| T6 Add accepts time = ±inf | INCLUDE (M9) | one finite check, matches to_copper |
| T6 each_saved/Prune loop to max numeric key | KEEP DEFERRED | only hand-edited saved data |
| T6 each_saved extra O(n) pass | INCLUDE (M3) | measured 0.54 s tab refresh at a year of entries |
| H1 pass optional reagent infos straight through | KEEP DEFERRED | refactor that needs in-game evidence first |
| H1 RequestLoadItemDataByID throw leaves stale wait | INCLUDE (M8) | wait never completes; pcall pattern already exists |
| T7 costBasis carries no estimated flag | INCLUDE (M2) | breaks the "~" marker rule for sales |
| T7 craft_spec posthook bound to guarded helper | INCLUDE (M5) | structural-test robustness is a focus of this review |
| T7 plan LedgerEntry lacks recraft?/estimated? | INCLUDE (I3) | contract/plan drift |
| T7 skippedOrderCrafts session-only | KEEP DEFERRED | after /reload the order has no craft row, so cost is nil → incomplete anyway |
| T8 186-char comment line | INCLUDE (M10) | trivial |
| T8 failed item loads remembered for session | KEEP DEFERRED | rare transient; /reload clears |
| T9 NaN delta passes guard | INCLUDE (M9) | one-liner |
| T9 multi-profession toast omits counts | KEEP DEFERRED | cosmetic |
| T9 Settings helpers duplicated | RESOLVED (4141fc5) | SettingsAccessor; remaining copies in M12 |
| T10 sub-copper "0g" plain not grey | INCLUDE (M1) | marker drift vs board and Ledger tab |
| T10 header 55% with no status | INCLUDE (M10) | header truncates at 516 px; Ledger tab already fixed this |
| T10 no spec that the 30 s ticker stops | INCLUDE (M10) | leaked-timer focus; test only |
| T11 Groups keyed by record.nameRealm | KEEP DEFERRED | damaged records only |
| T11 OnDisable doesn't hide pick menu / GLOBAL_MOUSE_DOWN on disabled module | INCLUDE (M10) | event-registration hygiene |
| T11 UISpecialFrames entry redundant | KEEP DEFERRED | harmless |
| T11 notice comment overstates fit | INCLUDE (M10) | trivial comment |
| T12 sticky column headers | KEEP DEFERRED | feature, not a defect |
| T12 entries cap | KEEP DEFERRED | perf handled by M3; cap is a product choice |
| T12 %m-%d dates ambiguous for EU | KEEP DEFERRED | tooltips carry the full date |
| T13 dbIsNewer spec loops only 4 setters | INCLUDE (M11) | dbIsNewer is a focus rule; test only |
| T13 misleading 'clear of other top-level keys' test name | INCLUDE (M11) | trivial |
| T13 slider drag rescores per step | INCLUDE (M7) | visible stutter with many customers |
| T13 toc_spec find cwd dependence | KEEP DEFERRED | busted always runs from repo root |
| T13 sound select blank without SOUNDKIT | KEEP DEFERRED | SOUNDKIT always exists in game |

## Missing in docs/in-game-checklist.md (for I4)
Every phase-2 "checklist:" line in progress.md is missing (no Phase 2 section exists):
1. T0: TRADE_SKILL_SHOW fires on every profession-window opening (the N1 reopen recalibration relies on it).
2. T4: do guild orders count against the public claim limit?
3. T5: snapshot count after visiting the Personal and Patron tabs.
4. T5: CRAFTINGORDERS_UPDATE_PERSONAL_ORDER_COUNTS fires at login.
5. T5: taint log clean with the two secure hooks (OrdersPage:ShowOrders, C_CraftingOrders.FulfillOrder).
6. T5: ShowBuckets is the public bucket-list entry; CRAFTINGORDERS_CLAIM_ORDER_RESPONSE arg order (result, orderID);
   GetCrafterOrders after the bucket list (no flat public orders).
7. T7: a craft records one "craft" entry with cost; one sale per Open All; multicraft extra result arrival (same
   operationID); invoice still readable inside the TakeInboxMoney post-hook; "Auction successful: X (5)" stack subject
   format.
8. T7: does UPDATE_TRADESKILL_CAST_STOPPED fire before the last TRADE_SKILL_ITEM_CRAFTED_RESULT of a batch?
9. T7: interrupt of cast N+1 vs late result of cast N; does a failed second click fire UNIT_SPELLCAST_INTERRUPTED?
10. T8: order-list cell layout and taint log with the Orders page open; long names (post-ruling: cells give way, no
    backing).
11. T8: '+' button and risk-frame hover vs Blizzard's row highlight/tooltip; OrderViewWarning placement vs title/tabs;
    does ShowOrders/SetupTable call SetView again.
12. T8: ScrollUtil.AddInitializedFrameCallback exists; OrderView.order field name; unmeasurable rows covering names.
13. T8: give-way while scrolling; unmeasurable-row fallback ("all"); plan Step 5 taint log; ScrollBox OnHide when an
    ancestor hides; ITEM_DATA_LOAD_RESULT / GET_ITEM_INFO_RECEIVED frequency while the list is open.
14. T9: does the personal-order count event fire away from a crafting table?
15. T11: chip widths (GetStringWidth vs GetUnboundedStringWidth); '|' in the EditBox echo; pick-menu placement at the
    window bottom.
Partly covered:
16. H1 "panel header max-quality rule": H1-4 checks only the "(game)" case. Add the fallback case: when the game reports
    a quality below max with no next threshold, the header uses Math, so there is no "(game)".
Covered (no action): H1 "GetItemCount sees bank/warband before bank opened" (H1-5), H1 "shopping list retry if the
item-name event never arrives" (H1-5b).
Also expected (from the plan, not "checklist:" lines): plan Task 13 Step 5 acceptance (8 checks); plan "Not verified
from source" items (see I4); I1's provided-reagents question.
