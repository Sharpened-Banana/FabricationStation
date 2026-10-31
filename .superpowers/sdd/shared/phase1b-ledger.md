# SDD ledger — plan: docs/superpowers/plans/2026-10-30-fs-phase1b-crafting.md
Spec: docs/superpowers/specs/2026-10-30-fabricationstation-design.md
Contract: docs/superpowers/plans/2026-10-30-fs-interface-contract.md (v2 + 1a updates)
Branch: feat/fabricationstation, starts at f69c3e2 (phase 1a complete). Phase 1a ledger: .superpowers/sdd/shared/phase1a-ledger.md

## Preflight scan
| Tasks | Shared file/interface | Finding |
|---|---|---|
| 1↔8,9 | Modules/CraftingData.lua (adapter, BuildInput, EFFECT_MAP) | sequential; T9 only edits where fixtures disagree. OK |
| 2-6 ↔ 8,9 | Math/* pure | T9 may edit Math constants; later tasks consume via Recipes. OK |
| 7↔8↔10↔11..19 | tests/helpers/crafting_world.lua (make_world) | each task extends; sequential. OK |
| 7↔8 | Modules/Recipes.lua | sequential. OK |
| 11↔12↔15↔16 | Queue / QueueCraft / Queue tab / panel Craft Next | QueueCraft consumes Queue entries + Scanner:ToCraftingReagentInfo. OK |
| 13↔later phases | Dashboard:RegisterWidget | contract. OK |
| 16↔19 | UI/ProfessionPanel.lua status line | T19 modifies T16's file. OK |
| 18 | Tooltips | 1b plan already fixed: tooltipCraftCost gates only built-ins; only built-ins cached. OK |
| 9 | golden fixtures from /fs capture | NEEDS the author's in-game captures + real GameData → Ruling 1 |
| 8 | WhoCanCraft vs Scanner `dropped` (added in 1a fix wave, not in 1b plan) | → Ruling 2 |
| all | empty checked-in GameData | → Ruling 3 |

## Rulings
- Ruling 1: Task 9 (golden fixtures) is deferred until the author supplies /fs captures and real GameData; execution continues with Tasks 10-19 after Task 8 (no later task consumes Task 9 output; Task 9 only edits Math/CraftingData where fixtures disagree) — cost if wrong: math constants unverified until Task 9 runs.
- Ruling 2: Task 8 also (a) adds the carried 1a guard: Scanner known_base_lines returns nil when GetProfessions yields no professions, and parentProfessionID must be a positive number; (b) WhoCanCraft/GetRanked skip professions with dropped == true — cost if wrong: alts with dropped professions listed as crafters.
- Ruling 3: every 1b module must work with empty GameData tables (results flagged estimated, never errors) — spec "show uncertainty" — cost if wrong: none.

## Tasks
Task 1: dispatched (BASE f69c3e2)
Task 1: complete (commits f69c3e2..0efc6ee, review clean)
Task 1: minor (carry to Task 8, which modifies CraftingData): AllocationFromReagentInfo slot lookup should skip slots with currencyID/empty reagents (ToCraftingReagentInfo emits ModifiedReagent only); guard non-number maxQuality
Task 1: minor (carry to Task 9): confirm finishing-reagent reagentEffectPct==0 fallback (unscaled) against fixtures
Task 2: dispatched (BASE 0efc6ee)
Task 2: complete (commits 0efc6ee..24249e4, review clean)
Task 2: minor (carry to Task 3): add Predict equality tests (250,500,5 → 3; 500,500,5 → 5,nil; threshold-1); fix Thresholds comment example (use 0.2*3); test RankFactor(x,1)=0
Task 2: minor (carry to Task 5/8): ReagentSkill doesn't clamp over-allocation — optimizer/transaction reader must bound quantities; Predict returns 1,nil,0 for unsupported maxQuality — Task 8 must check Thresholds()==nil and flag; route unknown itemIDs to Diagnostics:LogMismatch
Task 3: dispatched (BASE 24249e4)
Task 3: complete (commits 24249e4..6d6fe00, review clean; controller's suggested Predict(500,500,5) lower=400 was wrong, 500 correct)
Task 3: minor (carry to Task 5/6): Concentration.Cost returns 0 for nil curve AND real zero cost — Profit/optimizer must check curve==nil itself (concentrationCostForAllocation nil without curve); GoldPerPoint throws on nil profit — guard before calling
Task 3: minor (deferred): Cost fallback for out-of-range ratio/empty constant; no test for difficulty outside constant range, multiple lessFactors, non-0.5 refund
Task 4: dispatched (BASE 6d6fe00)
Task 4: complete (commits 6d6fe00..5fbd1e9, review clean)
Task 4: note: ParseBonusStats matches caller-supplied localized names (Recipes.STAT_NAMES enUS) — non-English clients get no bonus stats (known plan risk)
Task 4: minor (deferred): no chance clamp to 1.0 after ApplyOptionals; "localized name" test uses English; no break after match; reduceconcentrationcost 0 appends no-op
Task 5: dispatched (BASE 5fbd1e9)
Task 5: Ruling: accept optimizer plans landing EXACTLY on quality q (not ≥q) — keeps price-per-quality and concentration q→q+1 consistent; a dominated lower-quality plan is never chosen by max-profit selection — cost if wrong: explicit targetQuality may show a costlier plan than a cheaper higher-quality one
Task 5: Ruling: accept "slot with no priced option → plans with reagentCost=nil, missingPrice=true" — spec: no price never treated as free — cost if wrong: none; Task 6 must handle reagentCost==nil
Task 5: complete (commits 5fbd1e9..4b36ca1, review clean; brute-force verified on 400 random + adversarial case)
Task 5: minor (carry to Task 6): Optimizer — round slot weights to integers before GCD (non-integer weights → 4.4s single call)
Task 5: minor (carry to Task 10): coprime integer weights can take 27-373ms per CheapestByQuality call — scan must budget per call / rely on Recipes cache
Task 5: minor (deferred): same itemID in two slots double-subtracts owned; AllocationCost duplicates costAndUnits
Task 6: dispatched (BASE 4b36ca1)
Task 6: minor (carry to Task 8): Math flags: noPrice always boolean, unreachableTarget only when true — Recipes must normalize flags; EvaluateAllocation's optionalItemIDs pick from input.optionals — BuildInput must put candidate optional stats there
Task 6: review — Needs fixes (Important: unknown optionalItemIDs silently priced at 0 → profit overstated, no noPrice)
Task 6: Ruling: accept missingPrice scope narrowed to qualities reachable without concentration + chosen plan's quality — no case makes an unprofitable recipe look profitable — cost if wrong: a better unpriced concentration target goes unflagged
Task 6: Ruling: with targetQuality set, goldPerConcentration compares against plain[target] when it exists (else best plain) — targeted results should describe what concentration buys at that target — cost if wrong: different number shown for targeted evaluations
Task 6: minor (deferred): concBest picked by profit not gold/point (UX later)
Task 6: fix round 1/5 (4 addressed, 0 open; commits 987ed47..4eda661)
Task 6: complete (commits 4b36ca1..4eda661, review clean)
Task 6: minor (deferred): duplicate optional itemIDs applied once; comment wrap at Profit.lua ~137
Task 7: dispatched (BASE 4eda661)
Task 7: Ruling: auto-calibration hook errors must be log-only (SafeCall with a non-module source, e.g. "Recipes:AutoCalibrate"), not disable core Recipes — a calibration hiccup must not kill every profit feature — cost if wrong: a broken hook keeps erroring (logged once per source)
Task 7: Ruling: accept calibration top-rank call filling only basic slots with ≥2 reagents (optional slots would pollute measured reagent skill)
Task 7: review — Needs fixes (Important: ruling 1 not met — hook errors disable core Recipes; spec asserted it)
Task 7: minor (carry to Task 8): Task 8 must add FS_DATA_CHANGED stamp bumps via Recipes' local bump_stamp; GetDataStamp = stamps[charKey] + settingsVersion (record in contract); Calibrate nil when schematic not cached (no retry until reselect)
Task 7: fix round 1/5 (4 addressed, 0 open; commits cf8c285..1dd231a)
Task 7: complete (commits 4eda661..1dd231a, review clean)
Task 8: dispatched (BASE 1dd231a)
Task 8: Ruling: accept flags.estimated when GameData has no thresholds for a multi-quality recipe (every live eval estimated until real data) — spec "show uncertainty"
Task 8: Ruling: accept BuildInput listing optionals only for the passed optionalItemIDs (EvaluateCraft applies every listed optional) — carried item F intent met for EvaluateAllocation callers who pass IDs
Task 8: review — Needs fixes (Important: cached Evaluate survives a shared schematic change — confirmed by scratch test)
Task 8: Ruling: recipes with maxQuality <= 1 (incl. 0/nil) are no-quality recipes — never flagged estimated for missing thresholds — cost if wrong: none
Task 8: minor (deferred): Evaluate returns shared mutable cache entries (brief-mandated identity; read-only per contract); lazily stored schematic sends no message (itemIndex may lag)
Task 8: fix round 1/5 (5 addressed, 0 open; commits 0b53438..7b74d6c)
Task 8: complete (commits 1dd231a..7b74d6c, review clean)
Task 8: minor (deferred): incomplete schematic re-fetched each Evaluate while profession open (perf only); contract line 179 cache sentence not updated
Task 9: DEFERRED per Ruling 1 (needs author's /fs captures + real GameData)
Task 10: dispatched (BASE 7b74d6c)
Task 10: Ruling: start one scan shortly after login/enable (deferred, time-sliced) so GetRanked/Dashboard aren't empty until the first price/data change — spec §6.3 ranks every known recipe; cost if wrong: a little login work
Task 10: review — Needs fixes (Important: initial deferred scan missing); minors 1-5 included (owned_free accessor, rescan on setting change, clear results on disable, discriminating specs)
Task 10: contract note (todo after fix): flags.noPrice can be true while profit is non-nil (a reachable quality lacks a price but the chosen plan is priced) — UI must show profit + "some prices missing", not hide profit
Task 10: fix round 1/5 (5 addressed, 0 open; commits 7c66fe2..be490ac)
Task 10: complete (commits 7b74d6c..be490ac, review clean); contract note on noPrice+profit committed
Task 10: minor (deferred): disable clears results without FS_RECIPES_CHANGED; first store of a default setting triggers a rescan
Task 11: dispatched (BASE 71300e3)
Task 11: Ruling: accept subtracting providedReagents from per-craft requirement in missing reagents (allocation covers whole slot; otherwise order entries would ask the player to buy customer mats) — cost if wrong: none
Task 11: complete (commits 71300e3..4da9dbb, review clean)
Task 11: minor (carry to Task 12): Queue store() repairs/reassigns tables on read paths even under dbIsNewer; find_entry evaluates all restock targets per lookup; add tests: two entries same character share stock, dbIsNewer for Remove/SetQuantity/Clear
Task 11: minor (deferred): trailing debounce can starve under sustained traffic; fractional SetQuantity floors to 0 (removes); providedReagents per-craft comment; stale nextID below existing id not repaired
Task 12: dispatched (BASE 4da9dbb)
Task 12: in-game checks to add to docs/in-game-checklist.md at phase end: Auctionator ConvertToSearchString/CreateShoppingList term fields; whether crafting uses warband-bank reagents (Craft Next counts them when queueUseWarband)
Task 12: review — Needs fixes (Important: Craft Next stops at first blocker; stale pending craft can credit wrong entry; no-output recipes never decrement)
Task 12: Ruling: only one pending craft at a time — CraftNext returns status "busy" while a craft is pending; pending cleared on the craft result, on UNIT_SPELLCAST_INTERRUPTED/FAILED (player), or after a 30 s timeout; a pending item whose entry was removed is dropped — cost if wrong: a click during a long cast is refused
Task 12: Ruling: recipes with no output item (e.g. enchants) decrement on UNIT_SPELLCAST_SUCCEEDED for the player where spellID == recipeID — cost if wrong: enchant entries need manual removal
Task 12: fix round 1/5 (4 addressed, 0 open; commits 3b1dd9a..118c68e)
Task 12: complete (commits 4da9dbb..118c68e, review clean)
Task 12: minor (carry to Tasks 15/16): UI must handle CraftNext status "busy"
Task 12: minor (deferred): UNIT_SPELLCAST_* handlers wrap before the cheap pending check; nil operationID results not deduped; strip_comments treats -- in strings as comments
Task 13: dispatched (BASE 118c68e)
Task 13: Ruling: Dashboard 'Top crafts' uses onlyProfitable (spec §5.1 'Top profitable crafts now'); empty state says why (no scan yet / nothing profitable) — cost if wrong: loss-makers hidden from dashboard (still in Recipes tab)
Task 13: review — Needs fixes (Important: onlyProfitable ruling missing; concentration full-in wrong within an hour of full)
Task 13: minor (deferred): replaced widget frames hidden not reused; widgets own their frame height (note for phases 2/3)
Task 13: fix round 1/5 (4 addressed, 0 open; commits 0ae2867..166ce91)
Task 13: complete (commits 118c68e..166ce91, review clean)
Task 14: dispatched (BASE 166ce91)
Task 14: Ruling: accept pooled virtual list in a plain ScrollFrame (no WowScrollBoxList) and cycle buttons instead of dropdowns — ScrollBox/dropdown template APIs unverifiable here; swappable later; in-game check — cost if wrong: less polished UI until swapped
Task 14: review — Needs fixes (Important: scroll clamp branch never exercised; read-only queue refusal generic + untested)
Task 14: minor (deferred): "Scanning…" not refreshed when a pass starts (no start message)
Task 14: fix round 1/5 (4 addressed, 0 open; commits f353b3d..8379ca9)
Task 14: complete (commits 166ce91..8379ca9, review clean)
Task 14: minor (deferred): filter-persistence spec doesn't assert the refresh fired; pool[11] assertion weak
Task 15: dispatched (BASE 8379ca9)
Task 15: complete (commits 8379ca9..4abef55, review clean; taint check clean — hooksecurefunc post-hook only)
Task 15: minor (final fix wave): "1 items" pluralization; link hook fills non-item links; handler should check module enabled; link-hook test should restore globals in after_each and assert InsertLink identity unchanged; "Crafting X…" persists after interrupted craft
Task 16: dispatched (BASE 4abef55)
Task 16: Ruling: Recipes DEFAULTS.applyWritesBlizzardSlots = false until the in-game taint check passes (checklist item tells the author to turn it on and verify); Apply shows a hint when off — cost if wrong: Apply off by default for a while
Task 16: Ruling: the panel shows only while the crafting page (ProfessionsFrame.CraftingPage) is shown, not on Specializations/Orders pages — cost if wrong: none
Task 16: Ruling: accept panel's Calibrate-before-Evaluate with same-second dedupe
Task 16: review — Needs fixes (Critical: applyWritesBlizzardSlots still defaults true; Important: panel on all pages, Apply has no recipe-fit validation/refusal text, live prediction can read the previous recipe's transaction)
Task 16: minor (deferred): failed attach can leave callbacks registered (no-ops); Blizzard handler errors from TriggerEvent are logged as ProfessionPanel errors
Task 16: checklist: Apply taint check (/console taintLog 1, Apply quality-2 row, Create, check taint.log), then enable applyWritesBlizzardSlots
Task 16: Ruling: accept per-quality 'some prices missing' only from the entry's own missingPrice/noPrice (rows with nil profit already show 'no price')
Task 16: fix round 1/5 (5 addressed, 0 open; commits 4eb3068..ad0a08e)
Task 16: complete (commits 4abef55..ad0a08e, review clean; no Blizzard field writes)
Task 16: minor (final fix wave): sync_visibility lost ProfessionsFrame nil guard; "Apply is off" note doesn't refresh on setting toggle; reword "after the in-game check" for players
Task 17: dispatched (BASE ad0a08e)
Task 17: Ruling: accept compact label formatter (+12g / +45s / +50c), trailing '?' for noPrice-with-profit, grey '?' for nil profit — brief requires compact text FormatMoney can't produce
Task 17: complete (commits ad0a08e..8ae765a, review clean; taint check clean)
Task 17: minor (final fix wave): ±inf profit formats garbage → "?"; attach-time relabel_all from ADDON_LOADED can disable module (skip/guard); "never overstate" wording wrong for losses; hide label when flags.unknownRecipe (unlearned/linked); test filler asserts
Task 17: minor (deferred): labels refresh only on FS_RECIPES_CHANGED; no abbreviation for huge values (in-game)
Task 18: dispatched (BASE 8ae765a)
Task 18: review — Needs fixes (Important: malformed provider lines can disable whole Tooltips module)
Task 18: minor (deferred): first-hover cost unbounded across many recipes×crafters; analysisCache unbounded; costing-setting change or day rollover with no message may leave a stale tooltip line
Task 18: fix round 1/5 (5 addressed, 0 open; commits b642d09..c07e82b)
Task 18: complete (commits 8ae765a..c07e82b, review clean)
Task 19: dispatched (BASE c07e82b)
Task 19: Ruling: estimated predictions (no calibration / empty GameData / unknownOptional) are not compared or logged — avoids filling the log with noise — cost if wrong: no self-check until calibration+GameData exist
Task 19: Ruling: the comparison calls live operation info with applyConcentration=false and compares against the non-concentration prediction (concentration cost compared separately if the brief does) — avoids spurious skill mismatches
Task 19: Ruling: self-check uses its own panel line, never overwrites the action status line (e.g. "Applied the Q2 reagents")
Task 19: review — Needs fixes (rulings b and c not met — they were made after the implementer finished; stale mismatch line after skipped checks)
Task 19: checklist: verify game threshold values vs difficulty×fraction at 1e-6 and integer concentrationCost (else self-check floods)
Task 19: fix round 1/5 (4 addressed, 0 open; commits eb20876..d7833a7)
Task 19: complete (commits c07e82b..d7833a7, review clean)
Task 19: minor (deferred): check line reserves space when hidden (in-game layout check); disabled SelfCheck module doesn't clear a stale line
All tasks except Task 9 (deferred, Ruling 1) complete. Final review dispatched.
Final review: complete — With fixes (I1 unreachableTarget ignored; I2 required non-basic slots dropped; I3 stamp/calibration churn; I4 Craft Next ignores held reagents; I5 contract drift; I6 no 1b checklist) + minors M1-M6
Final review: Ruling: one fix wave covers I1-I6 and M1-M6 (final-fix-findings.md); other deferred minors stay deferred per reviewer triage — cost if wrong: one more fix wave
Final fix wave: re-review — I1,I2,I4,I5,I6,M1-M6 addressed; I3 partially (concentration fixed; ScanCooldowns still sends "professions" after every craft → churn); N1 regression: calibrations go stale after skill/tool change arriving as "recipes" (incl. window reopen); N2 warband counted as owned for Craft Next when queueUseWarband off; N3 sparks hit quality-reagent code (Auctionator tier, mixed-item fixed slot); N4 Apply writes spark rows (Apply off)
Final: Ruling: no second fix wave (per process); residuals N1 + I3 churn (ScanCooldowns should send "professions" only on real cooldown change or its own kind; reset `calibrated` per window opening or on skill/skillModifier/tools change) + N2 + N3 are carried as a pre-task (Task 0) at the start of phase 2, before anything consumes calibrations — cost if wrong: stale quality predictions after a skill/tool change until fixed
Phase 1b: COMPLETE except Task 9 (deferred, needs author's in-game captures + real GameData)
