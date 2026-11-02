# SDD ledger — plan: docs/superpowers/plans/2026-10-30-fs-phase2-orders-customers-ledger.md
Spec: docs/superpowers/specs/2026-10-30-fabricationstation-design.md
Contract: docs/superpowers/plans/2026-10-30-fs-interface-contract.md
Branch: feat/fabricationstation at a86071d (phase 1b complete except Task 9). Earlier ledgers: .superpowers/sdd/shared/phase1a-ledger.md, phase1b-ledger.md

## Preflight scan
| Tasks | Shared file/interface | Finding |
|---|---|---|
| 1↔all | tests/helpers/phase2.lua (P2.boot/P2.load) | built on 1a harness; later tasks extend. OK |
| 1↔2 | Modules/Customers.lua | sequential. OK |
| 3↔4↔5 | Modules/Orders.lua | sequential. OK |
| 6↔7 | Modules/Ledger.lua | sequential. OK |
| 5↔8↔10 | Orders snapshot/board ↔ OrdersPanel ↔ Orders tab | contract OrderView. OK |
| 4 | concentration value for scoring | user's phase-2 answer: per-profession → Ruling P2 |
| 8/10 | add order to queue | user's phase-2 answer: button → Ruling P1 |
| 7 | recraft/enchant ledger | user's phase-2 answer: out of scope → Ruling P3 |
| — | phase 1b residuals (N1/I3/N2/N3) | → Task 0 (Ruling P0) |
| 5 | .luacheckrc C_AddOns | already added by 1b; skip |

## Rulings
- Ruling P0: Task 0 (before Task 1) fixes phase 1b residuals: N1 stale calibration after skill/tool change via "recipes" (reset `calibrated` per window opening or on profession skill/skillModifier/tools change); I3 churn (Scanner ScanCooldowns sends "professions" only when a cooldown changed, or its own kind "cooldowns" that Recipes/RecipeScan ignore); N2 owned-free evaluation in Craft Next must respect queueUseWarband; N3 sparks: no Auctionator tier for non-quality slots, fixed slot allocation never mixes items — cost if wrong: none
- Ruling P1 (user's phase-2 Q1, recommended default): add an "Add to Queue" action for an order (OrdersPanel row button and Orders tab) creating a Queue entry with orderID + providedReagents + targetQuality=minQuality — in Task 8 and Task 10.
- Ruling P2 (user's phase-2 Q2): order scoring values concentration at the best goldPerConcentration of the SAME profession (skill line), not across all professions — in Task 4.
- Ruling P3 (user's phase-2 Q3): recrafts and enchants on existing items are not tracked by the Ledger in phase 2 — note in Task 7.
- Ruling P4: Phase 2 default reward values stay the plan's guesses (50g/knowledge point, 2g/Moxie, 10g low-tip margin), editable in Settings.

## Tasks
Task 0: dispatched (BASE a86071d)
Task 0: complete (commits a86071d..eb2b2ee, review clean; contract wording fixed in docs commit)
Task 0: minor (phase 2 final wave): add spec craft → TRADE_SKILL_LIST_UPDATE with raised skill → recalibration; QueueCraft one_craft reads queueUseWarband twice (use opts.excludeWarband)
Task 0: checklist: confirm TRADE_SKILL_SHOW fires on every profession window opening (N1 reopen fix relies on it)
Task 1: dispatched (BASE e7110b6)
Task 1: carry to later tasks: P2.NIL sentinel to unset raw_order defaults (Task 3 spec customerName = P2.NIL); W.hooks entries {tbl,name,fn} (global hooks tbl nil); GetOrderClaimInfo returns nil by default; P2.load boots only on first call per P2.boot
Task 1: complete (commits e7110b6..eeb6cd2, review clean)
Task 1: Ruling: plan specs using `customerName = nil` changed to `customerName = P2.NIL` (nil in a table constructor can't unset a default) — docs commit
Task 1: minor (deferred): P2.load second call loads without booting (silent); P2.merge merges arrays index-wise; RecordOrder dedupe edge cases (nil orderID, damaged entries, repair on duplicate without message); NormalizeName case/trailing dash
Task 2: dispatched (BASE e0be997)
Task 2: complete (commits e0be997..2d37766, review clean)
Task 2: minor (final wave): Link doesn't flatten moved alt's alts (linkedTo comment false; Unlink drags them); Export date on absurd lastSeen throws; ';' in tags ambiguous; duplicate names in Export list
Task 2: carry to Tasks 3-5/8/10/11: "has ordered before" = #record.orders > 0 (not Get ~= nil); refresh whole customer list on FS_CUSTOMERS_CHANGED (blocking affects the group); use Customers:Root() not .linkedTo; IsBlocked is O(n) — cache root map if called per row/message
Task 3: dispatched (BASE 2d37766)
Task 3: implementer finished (d2031d2) before a container restart; report present; review dispatched
Task 3: review — Needs fixes (Important: dbIsNewer/no-DB/wrong-type Settings paths untested)
Task 3: Ruling: Normalize returns customer = nil for NPC orders (orderType "npc") — NPC patrons are not player customers; brief test updated accordingly — cost if wrong: none
Task 3: Ruling: ordersUnknownRewards counts each orderID once (dedupe by last seen orderID per reward key); Settings() coerces numeric strings with tonumber before replacing
Task 3: fix round 1/5 (4 addressed, 0 open; commits d2031d2..165465e)
Task 3: complete (commits 2d37766..165465e, review clean)
Task 3: carry to Task 4: pass input.orderID to ValueRewards; minQuality vs expectedQuality scale (map in Normalize if they differ); rewards total 0 with unpriced must not display as exact; nil orderType tolerated
Task 4: dispatched (BASE 165465e)
Task 4: Ruling: accept net = nil (not 0) when reagent cost unknown; missing schematic → unknownRecipe, no score; unknown orderType never hidden by type filter; extra concentrationCharge field
Task 4: checklist: do guild orders count against the public claim limit?
Task 4: review — Needs fixes (Important: unknown concentration rate charged at 0 → concentration looks free; recraft orders scored as fresh crafts)
Task 4: Ruling: unknown gold/point (no ranked rows for that profession yet, or only unpriced rows, or no Recipes) → best_gpc nil → concentration orders get score nil + flags.unknownConcentrationValue (never "best"); a known 0 stays 0. Plan text line 331 superseded.
Task 4: Ruling: recraft orders (input.isRecraft) get flags.recraft + flags.estimated and score nil (not claimable as best) until recraft evaluation exists — cost if wrong: recraft orders need manual judgement
Task 4: fix round 1/5 (5 addressed, 0 open; commits 763a9d5..3a2800f)
Task 4: complete (commits 165465e..3a2800f, review clean); contract note for new flags committed
Task 4: carry to Tasks 8/10/12: show unknownConcentrationValue and recraft markers (not generic "no price")
Task 5: dispatched (BASE df39d6f)
Task 5: Ruling: accept recording customers via FS_ORDER_FULFILLED (Customers already listens) rather than a direct RecordOrder call; ClaimBest name per brief; ClaimBest ignores display filters but GetBestClaimable applies the claim-blocking risk settings — Task 8 must show GetBestClaimable(GetLiveViews()) so the button claims what it shows
Task 5: checklist: snapshot count after Personal/Patron tabs; CRAFTINGORDERS_UPDATE_PERSONAL_ORDER_COUNTS at login; taint with the two secure hooks
Task 5: review — Needs fixes (Important: ClaimBest uses stale live views — other profession, expired, off-screen public bucket, failed claim; no CLAIM_ORDER_RESPONSE handling/in-flight guard; per-type replacement drops other professions' personal orders from snapshot)
Task 5: Ruling: scope view replacement by (orderType, profession); clear live public views on ShowBuckets (post-hook); ClaimBest only considers current-profession, unexpired views present in GetCrafterOrders(); in-flight guard + CRAFTINGORDERS_CLAIM_ORDER_RESPONSE handling; structural test requires :ClaimBest( call form and exact-token names
IN-GAME FEEDBACK (user, phase 1b build): 1,2,3,7 pass; 4 FAIL predicted quality stuck Q1 with top reagents (game says Q2), no per-quality list; 5 FAIL Craft Next/queue "missing" though reagents held; Auctionator FabricationStation list not visible; 6 labels overlap; 8 no SavedVariables file after /fs capture; Auctionator v1 API confirmed (incl. CreateShoppingList, ConvertToSearchString, GetAuctionAgeByItemID); GetAllRecipeIDs & GetProfessions exist; warband-bank reagents seem to craft.
Task 5: fix round 1/5 (5 addressed, 0 open; commits eac7d3d..e6c7643)
Task 5: complete (commits df39d6f..e6c7643, review clean)
Task 5: checklist: ShowBuckets is the public bucket-list entry; CRAFTINGORDERS_CLAIM_ORDER_RESPONSE arg order (result, orderID); GetCrafterOrders after bucket list
Task 5: minor (deferred): failed claim leaves snapshot copy until next capture; stale costs one extra click
Task 6: dispatched (BASE e6c7643)
Task 6: review — Needs fixes (Important: Add raises on cost/tip/time → would disable Ledger from Task 7 hooks)
Task 6: Ruling: Add keeps raising only for bad type/amount (plan-mandated tests); invalid optional cost/tip/time are dropped (cost nil + incomplete flag; time defaults to now) and logged once, never raised; Task 7 must round amount itself
Hotfix H1: root causes confirmed by investigation (see hotfix-ingame-brief.md); Ruling: dispatch after Task 6 fix round, before Task 7
Task 6: fix round 1/5 (5 addressed, 0 open; commits bc92245..de52e43); scoped re-review dispatched
Task 6: Ruling: negative tip is not a benchmark sample (Add still stores it); Weekly skips rows with no numeric time (Query shows them at time 0) — accepted
Hotfix H1: dispatched (BASE de52e43), report hotfix-h1-report.md; one commit per item group
Task 6: complete (commits e6c7643..de52e43, review clean)
Task 6: minor (deferred): Add accepts time = ±inf (never pruned, always current week) — clamp to now with a finite check; each_saved/Prune loop to max numeric key (hand-edited huge key = slow); each_saved extra O(n) pass
Task 6: carry to Task 7: round amount before Add; Query returns live saved rows — callers must not mutate
Hotfix H1: implementer DONE_WITH_CONCERNS (commits de52e43..8350180, 1410 specs green, luacheck 0 — verified by orchestrator); review dispatched
Hotfix H1: checklist: GetItemCount sees bank/warband before bank opened this session; panel header max-quality rule; shopping list retry if item-name event never arrives
Hotfix H1: review — Needs fixes (Important: shopping-list wait registered after RequestLoadItemDataByID; synchronous GET_ITEM_INFO_RECEIVED can be lost → list never appears)
Hotfix H1: Ruling: fix minors 1-4 too (invalid upper threshold below max → Math fallback; equal-weight fallback = mean of known basic weights else 1; non-ascending merged thresholds → ignore calibrated; Count width in label measurement)
Hotfix H1: minor (deferred): pass Blizzard's optional reagent infos straight through instead of re-deriving slots (Scanner optional_infos)
Hotfix H1: fix round 1/5 dispatched
Hotfix H1: fix round 1/5 (5 addressed, 0 open; commits 8350180..a0a533d; 1417 green verified); scoped re-review dispatched
Hotfix H1: complete (commits de52e43..a0a533d + checklist doc commit, review clean)
Hotfix H1: minor (deferred): RequestLoadItemDataByID throwing mid-loop leaves a stale wait until next export/OnDisable (pcall the loop or always clear `requesting`)
Hotfix H1: zip FabricationStation-hotfix1.zip (HEAD 4b0db11) sent to user for re-test
Task 7: dispatched (BASE 4b0db11)
Task 7: implementer DONE_WITH_CONCERNS (101f947; 1448 green, luacheck 0 verified); touched tests/queue/craft_spec.lua structural check (whole-word + Ledger hook allowance) — review dispatched with focus on it
Task 7: checklist: craft entry; one sale per Open All; multicraft result arrival; invoice readable in TakeInboxMoney hook; stack subject format
Task 7: review — Approved (minors only); deviations kept (provided any-rank covers missing slot; 'X (5)' subject quantity; recraft detection via RecraftRecipeForOrder hook)
Task 7: Ruling: recraft order commissions ARE recorded (recraft=true, cost=nil → incomplete; Benchmark skips recraft); FulfilledOrder gains isRecraft; recraft crafts/enchants/salvage still untracked (P3) — cost if wrong: weekly income includes recraft commissions
Task 7: fix round 1/5 dispatched (recraft commission; matcher count + unit spec; clear pendingCraft on cast stop; partial order cost → incomplete; CraftRecipe hook guard)
Task 7: minor (deferred): costBasis carries no estimated flag, so sales costed from estimated crafts look exact
Task 7: fix round 1/5 (5 addressed, 0 open; commits 101f947..21abf99; 1455 green verified); scoped re-review dispatched
Task 7: checklist: does UPDATE_TRADESKILL_CAST_STOPPED fire before the last TRADE_SKILL_ITEM_CRAFTED_RESULT of a batch?
Task 7: complete (commits 4b0db11..21abf99, review clean)
Task 7: minor (deferred): craft_spec doesn't prove the posthook's hook is bound to the guarded helper (assert 'local function hook(tbl, name, fn)' once); plan LedgerEntry shape lacks recraft?/estimated?; skippedOrderCrafts is session-only
Task 7: checklist: interrupt of cast N+1 vs late result of cast N; does a failed second click fire UNIT_SPELLCAST_INTERRUPTED?
Task 8: dispatched (BASE 21abf99)
Task 8: implementer DONE_WITH_CONCERNS (2b669e6; 1488 green, luacheck 0 verified); own cell frame parented to Blizzard order ScrollBox; Orders:GetBestCandidate added; review dispatched
Task 8: checklist: order-list cells layout + taint log with the orders tab open; long-name backing
Task 8: review — Needs fixes (Important: rows measured on OnAcquiredFrame before Blizzard fills them → stale layout while scrolling; long-name dark backing covers Blizzard item names)
Task 8: Ruling: accept GetBestCandidate (shared best_of_board with ClaimBest) instead of literal GetBestClaimable(GetLiveViews()); recraft orders get no Add to Queue; keep container parented to OrderList.ScrollBox
Task 8: Ruling: our cells give way (H1-6 precedent): no backing; drop profit cell first, then whole strip; warning icon never over the name
Task 8: fix round 1/5 dispatched (layout on OnInitializedFrame; give-way; P1 unreachable/unknownRecipe; recraft '—'; compact loss rounding; exact-one ClaimBest caller; warning refresh on re-enable; best line item-data refresh)
Task 8: checklist: '+' button and risk frame hover vs Blizzard row highlight/tooltip; OrderViewWarning placement vs title/tabs; does ShowOrders/SetupTable call SetView again
Task 8: fix round 1/5 (8 addressed; commits 2b669e6..81d513d; 1495 green verified); scoped re-review dispatched (incl. callback-order concern on first measurement)
Task 8: re-review — Needs fixes (Important: give-way measured against stale/empty name — unordered OnInitializedFrame callbacks + late item names; nothing re-measures)
Task 8: Ruling: coalesced next-frame fit-only pass via ns.FS:Debounce(…,0,…), also on ITEM_DATA_LOAD_RESULT/GET_ITEM_INFO_RECEIVED while visible; failed item loads remembered per session (no endless re-request); unmeasurable row fallback stays 'all' → checklist
Task 8: fix round 2/5 dispatched
Task 8: checklist: ScrollUtil.AddInitializedFrameCallback exists; OrderView.order field name; unmeasurable rows covering names
Task 8: fix round 2/5 (2 addressed; commits 81d513d..c83341a; 1498 green verified); scoped re-review dispatched
Task 8: complete (commits 21abf99..c83341a, review clean)
Task 8: minor (deferred): UI/OrdersPanel.lua:712 186-char comment line (reflow); failed item loads remembered for whole session (transient failure shows ID until /reload)
Task 8: checklist: give-way while scrolling; unmeasurable-row fallback; Step 5 taint log; ScrollBox OnHide when ancestor hides; item-info event frequency
Task 9: dispatched (BASE c83341a)
Task 9: implementer DONE_WITH_CONCERNS (97a8c84; 1512 green verified); review dispatched
Task 9: checklist: does the personal-order count event fire away from a crafting table?
Task 9: review — Needs fixes (Important: Settings writes while dbIsNewer and repairs nothing; disable spec can't fail on cancel)
Task 9: Ruling: fix minors too (delta<=0 guard; same-frame coalesce into one sound + one toast listing professions; EnableMouse(false); pcall PlaySound); toastSeconds valid range [1,60] else 8
Task 9: fix round 1/5 dispatched
Task 9: fix round 1/5 (6 addressed; commits 97a8c84..00a4193; 1523 green verified); scoped re-review dispatched
Task 9: complete (commits c83341a..00a4193, review clean)
Task 9: minor (deferred): NaN delta passes the guard (use not (delta > 0)); multi-profession toast omits counts; Settings helpers (copy/writable/fill/sessionSettings) duplicated across Orders and OrderAlert — share in ns.Util (consider in Task 13)
Task 10: dispatched (BASE 00a4193)
Task 10: implementer DONE_WITH_CONCERNS (f6f2279; 1546 green verified); OrdersPanel.AddToQueue extracted; review dispatched
Task 10: review — Needs fixes (Important: Type column laid out outside the row (place_cells assumes flexible column first); column widths overflow 516px minimum content width; Tip coin icons don't fit)
Task 10: Ruling: width budget Type48 Customer90 Net56 Score56 Expires44 Action52 Tip60(compact, no icons) Risk32('!N'); Item >=120 else hide Customer then Type; tooltip carries full customer/tip/net; shared OrdersPanel.FilterChecks(); 30s age ticker while shown; status width/clear; seen boolean
Task 10: fix round 1/5 dispatched
Task 10: fix round 1/5 (9 addressed; commits f6f2279..cb34949; 1559 green verified); scoped re-review dispatched
Task 10: complete (commits 00a4193..cb34949, review clean)
Task 10: minor (deferred): sub-copper "0g" plain not grey (sign_color → DIM); header gets 55% even with no status (full width when status nil); no spec that the 30s ticker stops when the tab is hidden
Task 11: dispatched (BASE cb34949)
Task 11: implementer DONE_WITH_CONCERNS (3a3f9c9; 1587 green verified); review dispatched
Task 11: review — Needs fixes (Important: history Item column 96px at 516 (<120); overflowing alt/tag chips hidden silently → alts unreachable/unlinkable)
Task 11: Ruling: accept Export mains+alts and LinkInput/Tab.Link split; history widths date %m-%d 34/Q 20/tip 44 CompactMoney/PAD gap; '+N' overflow chip with own-frame picker; history who rows select alt; blockedBy roll-up wording; persistent read-only mode; selected-root highlight; title/link tooltips; trim search
Task 11: minor (deferred): Groups keyed by record.nameRealm (damaged record without nameRealm skipped)
Task 11: fix round 1/5 dispatched
Task 11: fix round 1/5 (7 addressed; commits 3a3f9c9..119d391; 1596 green verified); scoped re-review dispatched
Task 11: re-review — Needs fixes (Important: read-only notice truncated before 'read-only' at 516, status line has no tooltip)
Task 11: Ruling: notice 'Read-only: saved data is from a newer addon version' + status tooltip; tag chips disabled read-only; menu persists across non-selection refresh; GLOBAL_MOUSE_DOWN outside-click close + UISpecialFrames; drop same realm in 'via'; chip.value cleanup
Task 11: fix round 2/5 dispatched
Task 11: checklist: chip widths (GetStringWidth vs GetUnboundedStringWidth); '|' in EditBox echo; pick menu placement at window bottom
Task 11: fix round 2/5 (6 addressed; commits 119d391..2ea67ab; 1601 green verified); scoped re-review dispatched
Task 11: complete (commits cb34949..2ea67ab, review clean)
Task 11: minor (deferred): OnDisable doesn't hide the pick menu and OnShow registers GLOBAL_MOUSE_DOWN on a disabled module; UISpecialFrames entry for the menu is redundant (Escape closes the whole window) — drop or document; notice comment overstates fit
Task 12: dispatched (BASE 2ea67ab)
Task 12: implementer DONE_WITH_CONCERNS (1b374a1; 1630 green verified); corrected my brief: missing cost ⇒ profit is an UPPER bound ('partial', never '≥'); review dispatched
Task 12: review — Needs fixes (Important: '~' on exact income in entries; widget drops '~' on estimated profit; recipe table all-time vs weekly 8 weeks — not reconcilable; tab copies Ledger week-bucketing; Ledger.lua:10-11 backwards-bound comment)
Task 12: Ruling: Ledger accumulate carries totals.estimated (nil when 0); recipe table + Unattributed filtered since oldest shown week ('last 8 reset weeks', fallback '(all recorded)'); benchmark nil-quality row for tierless recipes; widget 'N on the board' + best from Orders:Filter; 'missing or partial cost' wording
Task 12: minor (deferred): sticky column headers / entries cap on the one-page scroll; %m-%d dates ambiguous for EU
Task 12: fix round 1/5 dispatched
Task 12: fix round 1/5 (10 addressed; commits 1b374a1..8e21db2; 1635 green verified); scoped re-review dispatched
Task 12: re-review — Needs fixes (Important: mutation spec vacuous — P2.merge({}, live) keeps live rows); Minor: period boundary spec
Task 12: fix round 2/5 dispatched
Task 12: fix round 2/5 (spec-only; a0135a9; orchestrator verified diff + 1636 green; mutation RED evidence in report) — no further re-review needed
Task 12: complete (commits 2ea67ab..a0135a9, review clean)
Task 12: minor (deferred): sticky column headers / entries cap
Task 13: dispatched (BASE a0135a9)
Task 13: implementer DONE_WITH_CONCERNS (4141fc5 shared SettingsAccessor refactor, 95c31dc options; 1662 green verified; 27 modules boot); review dispatched
Task 13: complete (commits a0135a9..95c31dc, review clean); all 5 deviations accepted (IsEnabled getter; round gold→copper; window toggles session-only while dbIsNewer; block_<risk> keys; rescore via SafeCall, no prune on keepDays change)
Task 13: minor (deferred): dbIsNewer spec loops only 4 setters; misleading 'clear of other top-level keys' test name; slider drag rescores per step (debounce); toc_spec find cwd dependence; sound select blank without SOUNDKIT
PHASE 2 TASKS COMPLETE (0-13 + Hotfix H1). Next: whole-branch final review a86071d..95c31dc
Final review: dispatched (a86071d..95c31dc) → phase2-final-findings.md
Final review: complete — With fixes (I1 order queue entries outlive order + Craft Next unclaimed; I2 benchmark quality mismatch; I3 contract behind phase 2; I4 no Phase 2 checklist) + M1-M12, deferred-minor triage in phase2-final-findings.md
Final review: Ruling: one fix wave covers I1-I4, M1-M12 and triage INCLUDEs; KEEP DEFERRED stays deferred — cost if wrong: one more fix wave
Final fix wave: dispatched (BASE 95c31dc) → phase2-final-fix-report.md
Final fix wave: container restart killed implementer after I1-I4 commits (1ba4da7..15be112, tree clean, no report); resumed via SendMessage for minors + report
Final fix wave: DONE_WITH_CONCERNS (95c31dc..513552f; I1-I4 + M1-M12; 1693 green verified); re-review dispatched
Final fix wave: re-review — Ready (no Important); deviations accepted (Queue:OrderFulfilled source; expected quality clamped up to minQuality; Orders:ScheduleRescore; Orders tab relayout on status; current_profession/ok_result unshared; Orders-off fulfilment → "order" blocker)
Phase 2 residuals (carry to phase 3 Task 0): Orders:OnEnable should send ORDERS_CHANGED (cells/tab stay off-state after re-enable); optional Queue listener for CRAFTINGORDERS_FULFILL_ORDER_RESPONSE (Ok) to remove order entries independent of Orders module; KEEP DEFERRED rows in phase2-final-findings.md triage
PHASE 2 COMPLETE (a86071d..513552f)
