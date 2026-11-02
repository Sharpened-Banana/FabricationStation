# SDD ledger — plan: docs/superpowers/plans/2026-10-30-fs-phase3-alts-planner.md
Spec: docs/superpowers/specs/2026-10-30-fabricationstation-design.md
Contract: docs/superpowers/plans/2026-10-30-fs-interface-contract.md
Branch: feat/fabricationstation at 513552f (phase 2 complete). Earlier ledgers: .superpowers/sdd/shared/phase1a-ledger.md, phase1b-ledger.md, .superpowers/sdd/2026-10-30-fs-phase2-orders-customers-ledger/progress.md
User: "Go ahead and start. I'll test tomorrow." (phase 2 build delivered as FabricationStation-phase2.zip; in-game results pending)

## Preflight
Preflight: 39 findings (18 I, 21 M) in preflight.md — Ruling Q-PF: every "Recommended ruling" in preflight.md is adopted as written and binding; each task applies the rows that name it

## Rulings
- Ruling Q0: Task 0 (before Task 1) fixes phase 2 residuals: Orders:OnEnable sends ORDERS_CHANGED (cells/tab leave off-state after re-enable); Queue also listens to CRAFTINGORDERS_FULFILL_ORDER_RESPONSE (result Ok) and removes order entries (idempotent with FS_ORDER_FULFILLED), so removal doesn't depend on the Orders module.

## Tasks
- Ruling Q5: Task 5 knowledge data — try reachable public sources (WebSearch snippets, warcraft.wiki.gg, raw.githubusercontent of licensed data) to author more than the 3 anchor rows; every row gets a `credit` naming its source, rows not confirmed by two sources are credited "unverified"; never copy WeeklyKnowledge/HandyNotes tables. Missing variants stay absent → KnowledgeSummary status "noData" ("?") per design rule 6. RecipeSources generated --empty (wago.tools blocked). All in-game verification steps go into the phase-3 checklist; tasks needing the client report DONE_WITH_CONCERNS, not BLOCKED.
Task 0: dispatched (BASE 513552f)
Task 0: implementer DONE (d16d253; 1703 green verified); review dispatched
Task 0: complete (commits 513552f..d16d253, review clean)
Task 0: minor (deferred): queue 'Orders disabled' spec asserts absence rather than loaded-then-disabled; no spec/comment pinning Orders' boot-time ORDERS_CHANGED; contract message table doesn't mention Orders announces on enable
Task 1: dispatched (BASE d16d253)
Task 1: implementer DONE_WITH_CONCERNS (2d7ee93; 1718 green verified); review dispatched
Task 1: complete (commits d16d253..2d7ee93, review clean)
Task 1: minor (final wave): concentration stand-in lacks Scanner's perCycle<=0/cycleSeconds<=0 guard + spec "non-regenerating → nil"; specs for over-max and max=0 + contract sentence (callers filter max<=0); startTime seconds/DST note; custom-horizon assert exact 3600000
Task 2: dispatched (BASE 2d7ee93)
Task 2: implementer DONE_WITH_CONCERNS (b2d5156; 1752 green verified); review dispatched
Task 2: review — Needs fixes (Important: StripCodes eats text after '||'; '|cn<name>:' not stripped)
Task 2: Ruling: accept 'unknown' one-time deviation; fix minors (min(limit,#quests), total-0 → unknown, dedupe quest IDs, boundary tests, |K|W, Task 1 startTime seconds); contract: consumers must check status before summing weeklyLeft
Task 2: carry to Tasks 7/15: never sum weeklyLeft/knowledgeLeft from status ~= 'ok' summaries without marking unknown; Summarize.darkmoon 'unknown' can mean 'no snapshot', not 'calendar unavailable'
Task 2: fix round 1/5 dispatched
Task 2: fix round 1/5 (6 addressed; commits b2d5156..bf3f4d4; 1759 green verified); scoped re-review dispatched
Task 2: complete (commits 2d7ee93..bf3f4d4, review clean)
Task 2: minor (final wave): limit=0 with quests reads done (treat limit<1 as unknown); monthly==Darkmoon without category check
Task 3: dispatched (BASE bf3f4d4)
Task 3: implementer DONE_WITH_CONCERNS (8d5b0b5; 1793 green verified); review dispatched
Task 3: complete (commits bf3f4d4..8d5b0b5, review clean); deviations accepted (unknown spec gain kept as nil sorted last; capped pools listed first even with nil fullAt)
Task 3: minor (final wave): test for cross-character pool matching (vary charKey); greedy ranks by gpc (per expected point) but spends full cost — sort by gpc·expectedCost/concentrationCost or document; Schedule should skip max<=0 pools like CapWarnings
Task 4: dispatched (BASE 8d5b0b5)
Task 4: implementer DONE_WITH_CONCERNS (c1d1dfb; 1814 green verified); review dispatched
Task 4: complete (commits 8d5b0b5..c1d1dfb, review clean); deviations accepted (--sources flag, render 5th arg, --build required with --empty, no write on warning, credit dropped at runtime)
Task 4: minor (final wave): AcquireMethod '~= 0' inline → named predicate; validate knowledge_sources header (optional cols); note-level line for itemIDs with no on-use/quest; num() pcall per cell slow on real export
Task 5: dispatched (BASE c1d1dfb)
Task 5: implementer DONE_WITH_CONCERNS (bf2e3cc; 160 rows: 126 two-source / 34 unverified; data from MIT-licensed addon datasets on GitHub; 1823 green verified); review dispatched
Task 5: review — Needs fixes (Important: MIT notices don't ship (.pkgmeta strips tools/docs) → THIRD_PARTY_NOTICES.md; 2 'verified' rows with conflicting points; 15 book rows rest only on DjinnisDataTexts (possible WeeklyKnowledge derivation))
Task 5: Ruling: root THIRD_PARTY_NOTICES.md (full SHAs, copyright lines, MIT text); relabel conflicting rows; templated guide wording isn't a second source; books corroborated from non-Djinni source or dropped (checklist line kept); 88 unique treasures + weekly rows kept
Task 5: note for user: repo has no LICENSE of its own — user's decision before any public release (phase 4)
Task 5: fix round 1/5 dispatched
Task 5: fix round 1/5 (8 addressed; 2c05af3; 127 verified / 33 unverified; books corroborated via ATT CharacterItemDB; 1825 green verified); scoped re-review dispatched
Task 5: complete (commits c1d1dfb..2c05af3, review clean); 127 verified / 33 unverified; THIRD_PARTY_NOTICES.md ships
Task 5: minor (final wave): .pkgmeta guard should treat glob entries; checklist Demystifyin' line can cite ATT CharacterItemDB 1048-1058 as the ID source (points still unknown)
Task 6: dispatched (BASE 2c05af3)
Task 6: implementer DONE_WITH_CONCERNS (01d2921; 1869 green verified); review dispatched
Task 6: review — Needs fixes (Important: removing learned recipes from the account-wide catalog hides them from other characters' missing lists)
Task 6: Ruling: catalog records every recipe of planned lines (learned or not); always send ALTS_CHANGED after flags write; ALTS_CHANGED on enable (first debounced run)/disable; catalog message only on change; UTF-8-safe cap; paths-debounce cancel spec; hidden fill; relay note
Task 6: carry to Tasks 13/15: Alts sends FS_ALTS_CHANGED on enable/disable — views show 'Alts is turned off' state
Task 6: fix round 1/5 dispatched
Task 6: fix round 1/5 (8 addressed; commits 01d2921..ab81837; 1874 green verified); scoped re-review dispatched
Task 6: complete (commits 2c05af3..ab81837, review clean); extension accepted (catalog message also on firstCraftsPending/path-name change)
Task 7: dispatched (BASE ab81837) — includes Task 6 minor (empty sourceText must not overwrite a known one)
Task 7: implementer DONE_WITH_CONCERNS (675268f, 0d322d1; 1920 green verified); review dispatched
Task 7: complete (commits ab81837..0d322d1, review clean); Focus-5 reading accepted (noData per profession, not blanket on build mismatch)
Task 7: carry to Tasks 12/13/15: Characters header knowledge sum and altsKnowledge widget show a "data build X (outdated)" marker/tooltip when GameData.Status is outdated/mismatched
Task 8: dispatched (BASE 0d322d1) — includes Task 7 minor (unknown-variant lines with concentration/spec listed as noData)
Task 8: implementer DONE_WITH_CONCERNS (ecbd54c; 1952 green verified); review dispatched
Task 8: review — Needs fixes (Important: snapshot counts ignore H1 live current-char/warband counts + 'not scanned' line noise on every hover; never-scanned character bank reads 0 and bank/warband ages hidden; Task 7 follow-up lists Khaz Algar lines as noData with pools)
Task 8: Ruling: live counts for current char + warband (GetOwnedCount/GetWarbandCount gated); unknown folded into Total '18+ (…)' (no warband line on tooltips); bank nil when itemsTime.bank missing; oldest-contributing-snapshot age + warbandAgeSeconds; non-variant line listed only when no listed variant shares its parentSkillLineID; per-hover waste cut; craftCost-off spec; FindItems request cap; short same-realm names
Task 8: fix round 1/5 dispatched
Task 8: fix round 1/5 (7 addressed; commits ecbd54c..412f87f; 1973 green verified); scoped re-review dispatched
Task 8: complete (commits 0d322d1..412f87f, review clean)
Task 8: minor (final wave): watertight warband/owned live gates (probe both GetItemCount flag sets before trusting live 0); contract: logged-in character on snapshot fallback can be stale
Task 9: dispatched (BASE 412f87f)
Task 9: implementer DONE_WITH_CONCERNS (f729c8c; 2005 green verified); review dispatched
Task 9: review — Needs fixes (Important: GetMissingRecipes/checklist return {} for both 'nothing missing' and 'unknown' — with --empty RecipeSources that is the normal case)
Task 9: Ruling: GetMissingRecipes -> rows, status (off|hidden|noProfession|noData|ok; never-scanned record → noData); checklist -> rows, status (ok|off); contract: getters ignore Planner:IsEnabled
Task 9: fix round 1/5 dispatched
Task 9: fix round 1/5 (4 addressed; commits f729c8c..be2d101; 2014 green verified); scoped re-review dispatched
Task 9: complete (commits 412f87f..be2d101, review clean); never-scanned signal = ProfessionRecord.time (only ScanProfession writes it)
Task 10: dispatched (BASE be2d101) — includes Task 3 minors (Schedule max<=0 skip, full-cost ranking, cross-char test) and Task 9 minor (noData vs notScanned)
Task 10: implementer DONE_WITH_CONCERNS (e75284d; 2051 green verified); review dispatched
Task 10: complete (commits be2d101..e75284d, review clean); no schedule cache (justified: per-pool GetRanked is O(known recipes))
Task 10: minor (final wave): re-enabling Planner within the 10 s window loses the announcement until next loading screen; "full in 1h" overstates <30 min (until FormatDuration)
Task 11: dispatched (BASE e75284d) — includes Task 10 minors (no announce on /reload, discriminating fallback test, Planner charKey guard spec)
Task 11: implementer DONE_WITH_CONCERNS (225a435, d5a0c6c; 2083 green verified); SpecEntryEffects empty → all gains unknown in the shipped build; review dispatched
Task 11: review — Needs fixes (Important: _nodeBonus merges label scopes across entries → under/overcount)
Task 11: Ruling: per-entry scopes (top-level unlabelled sums + scoped parts), per-recipe stats in gainFn; baseline from cached plain Evaluate; labelled-but-unlabelled-top → nil; real-adapter spec on empty tables; single stat-list constant
Task 11: carry to Task 14: compute spec advice lazily (section shown + selected char/line; debounced+Wrapped on messages; never loop all chars×lines); nil gain → '?', no FormatMoney(nil); all-nil → 'Spec effect data not in this GameData build (<build>)' note; one message per status; Task 16 smoke hitch check
Task 11: fix round 1/5 dispatched
Task 11: fix round 1/5 (5 addressed; commits d5a0c6c..10ca013; 2090 green verified); scoped re-review dispatched
Task 11: complete (commits e75284d..10ca013, review clean)
Task 11: minor (final wave): coverage-set RecipeLabels scan redundant (build from top recipes); scoped order from pairs() nondeterministic; nil what-if counts as no change (plan-mandated)
Task 12: dispatched (BASE 10ca013) — view models carry Task 6/7/9/11 status/marker rules
Task 12: implementer DONE_WITH_CONCERNS (1b3a8f4; 2135 green verified); review dispatched
Task 12: review — Needs fixes (Important: profession '+N' appended to a truncating 130px cell (cut at 516); detail rows not width-aware/clipped; ages via FormatDuration vs binding FormatAge)
Task 12: Ruling: right-anchored '+N' font string; detailHeight(row,width) + refresh on width change + clip; ages via FormatAge (plan tests adapted), FormatDuration only for durations; minors: clear detail text, capped<=max, 'next in X', CompactMoney gold + tooltips, shared view helpers, CurrentDataNote via Core
Task 12: minor (final wave): concentration with unknown regen rate shows '>14d' — separate signal upstream
Task 12: fix round 1/5 dispatched
Task 12: fix round 1/5 (8 addressed; commits 1b3a8f4..e9981b6; 2139 green verified); scoped re-review dispatched
Task 12: carry to Task 13: CellTexts returns cells, badges — tab renderer must call ExpandGrid.SetBadge or pass badges to the default renderer
Task 12: complete (commits 10ca013..e9981b6, review clean); new shared UI/Tabs/ViewUtil.lua and FS:GameDataStatus()
Task 12: minor (final wave): capped(max 1) drops Total line; ', next in' via string compare (use a flag)
Task 13: dispatched (BASE e9981b6) — includes Task 12 minors (WrappedHeight \n split + GetStringHeight, ViewUtil load-order spec)
Task 13: implementer DONE_WITH_CONCERNS (53208e6; 2168 green verified); review dispatched
Task 13: review — Needs fixes (Important: outdated-data marker at end of a single 336px header line → cut at 516)
Task 13: Ruling: CompactMoney header gold; marker in an untruncatable region (leading marker or own 'Outdated:' line with tooltip) + 516 spec on placement/width; minors: tick cancel on hide, item-info unregister on hide/Alts off, Alts-off clears statusText/count, search empty text honest re hidden, Show hidden label tooltip
Task 13: fix round 1/5 dispatched
Task 13: fix round 1/5 (6 addressed; commits 53208e6..6dde7ef; 2173 green verified); scoped re-review dispatched
Task 13: complete (commits e9981b6..6dde7ef, review clean)
Task 14: dispatched (BASE 6dde7ef) — includes Task 13 minors (marker wording 'Old data', clear notice on Alts off)
Task 14: implementer DONE_WITH_CONCERNS (01d2ade; 2206 green verified); review dispatched
Task 14: Ruling (pending review confirmation): knowledge footer must reflect the Knowledge table's own status, not 'not generated' because RecipeSources is missing; RecipeSources absence is shown only in the Missing recipes section
Task 14: review — Needs fixes (Important: Knowledge footer uses global GameData missing flag → always 'not generated'; RecipeSources absence not shown in Missing recipes)
Task 14: Ruling: GameData.TableBuild(name); footer + 'Old data' marker (both tabs) use Knowledge's own build; Missing recipes footer leads 'Recipe sources: not generated'; minors: tick only Knowledge/Concentration, real unregistration spec, pure KnowledgeDetailLines, status table spec, drop pickers field, schedule empty-text placement
Task 14: fix round 1/5 dispatched
Task 14: fix round 1/5 (7 addressed; commits 01d2ade..aa2226f; 2214 green verified); DataBuildNote signature change accepted (consistent header/marker rule); scoped re-review dispatched
Task 14: complete (commits 6dde7ef..aa2226f, review clean); GameData.TableBuild added; data marker/footer use Knowledge's own build on both tabs
Task 15: dispatched (BASE aa2226f) — includes Task 14 minors
Task 15: implementer DONE (396dda9, ab60f47; 2234 green verified); review dispatched
Task 15: complete (commits aa2226f..ab60f47, review clean)
Task 15: minor (final wave): WARN colour named "orange" is gold; OnInitialize registration spec only checks coreModule; nil status guard in widget; names sentinel per row only
Task 16: dispatched (BASE ab60f47)
Task 16: implementer DONE_WITH_CONCERNS (51942cd, 47b3a9f; 2254 green verified; no production change)
Task 16: Ruling: Task 16 is specs+docs only — its task review is folded into the phase-3 whole-branch final review (explicit scope item) to avoid a redundant pass
Final review: dispatched (513552f..47b3a9f)
Final review: complete — With fixes (0 Important, 7 Minor; M1 checklist lines P3-2/15/19/25 must be corrected before user's test)
Final review: Ruling: one fix wave covers M1-M7 + triage INCLUDEs; KEEP DEFERRED stays deferred
Final fix wave: dispatched (BASE 47b3a9f)
Final fix wave: DONE_WITH_CONCERNS (47b3a9f..65683bc; M1-M7; M1 corrected 14 checklist lines; 2264 green verified); re-review dispatched
Final fix wave: re-review — one remaining checklist issue (P3-1/P3-2 assumed both profession slots visible; grid shows only the first below ~1320 px) — fixed by orchestrator in docs commit d3ab22b
Final fix wave: complete; PHASE 3 COMPLETE (513552f..d3ab22b)
Phase 3 note for user: at default 900 px window the Characters grid shows one profession per character (second as '+1' badge + tooltip) — candidate UX change
Phase 3 residuals (carry): 1b concentration widget shows its own value for unknown regen rate; KEEP DEFERRED rows in phase3-final-findings.md
