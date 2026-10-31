# Phase 1b final review — fix wave findings (all in this one dispatch)
Full review text with file:line evidence is summarized here; scratch repros: /tmp/claude-0/-home-user-FabricationStation/8fbd541b-9883-5ada-b249-e0fbf0f6725a/scratchpad/{unreach_spec.lua,churn_spec.lua,perf.lua,conc.lua}

Important
I1. flags.unreachableTarget ignored by every consumer (set at Modules/Recipes.lua:~430). Tooltips craftCost (UI/Tooltips.lua ~110-117) shows the lower-quality cost for an unreachable quality; Queue restock (Modules/Queue.lua ~95-101) creates entries that craft a lower quality forever. Fix: tooltip craftCost and restock skip results with unreachableTarget (restock: no entry when no crafter can reach the quality); Panel, Queue tab and Recipes tab flag text gain an "unreachable" marker. Tests incl. the restock no-loop case.
I2. Required non-basic reagent slots (kind ~= "basic", required == true, e.g. sparks) are dropped: Modules/CraftingData.lua BuildInput (~156-173) only turns basic slots into Math slots → reagentCost/profit omit them, missing reagents/shopping list omit them, Craft Next sends CraftRecipe without them. Fix: in BuildInput turn required optional/finishing slots that have reagents into weight-0 fixed slots (cheapest item priced, included in allocation → ToCraftingReagentInfo, missing reagents, shopping list). Tests through Evaluate, Queue missing reagents and QueueCraft.
I3. Recalibration/re-evaluation churn: Recipes bumps the character stamp for every non-item FS_DATA_CHANGED kind incl. "concentration" (Evaluate never reads it) (Recipes.lua ~153-165); Calibrate always bumps even when values are unchanged (~229-230); RecipeScan clears `calibrated` on any non-item message for the current character (RecipeScan.lua ~263-265). Fix: no stamp bump for "concentration"; Calibrate bumps only when stored values change; clear `calibrated` only on "spec"/"professions" changes or newly learned recipes. Tests: a "concentration" message and an unchanged re-calibration keep cached results (same table) and cause no live re-calibration.
I4. Craft Next reports "missing" when held reagents would do after prices shift ranks (Modules/QueueCraft.lua ~138-161): one_craft evaluates with ownedReagentsFree = true so held reagents are used first. Test.
I5. Contract drift (docs/superpowers/plans/2026-10-30-fs-interface-contract.md): line ~241 says applyWritesBlizzardSlots = true (code: false); add ns.FS:CancelDebounce and ProfessionPanel:SetCheckLine; document that phase 3's opts.extraStats must be threaded through Recipes full_opts/evaluate (currently full_opts keeps only 4 keys) — note for phase 3 Task 11; document flags.unreachableTarget consumer behaviour and required non-basic slots handling.
I6. docs/in-game-checklist.md: add a "Phase 1b" section with the 15 checks listed below.

Minor (include)
M1. Missing markers: tooltip "Craft cost" gets "(estimate)" when estimated and price age; Queue tab cost gets an estimate/age marker; recipe-list labels get an estimate cue (e.g. "~" prefix) when estimated.
M2. A basic slot with ≥2 ranks but weight 0 (reagent not in GameData) → flag result estimated.
M3. Math/Concentration.lua Cost throws on an empty constant/difficulty point list — guard in CraftingData.Curve (return nil) and/or Cost (return nil → no concentration). Test.
M4. "1 items" → "1 item" in UI/Tabs/Queue.lua; restore the ProfessionsFrame nil guard in ProfessionPanel sync_visibility.
M5. Queue tab link-hook test: restore replaced globals in after_each and assert ChatFrameUtil.InsertLink identity unchanged.
M6. RecipeListLabels: ±inf profit → "?"; hide label when flags.unknownRecipe.

Phase 1b in-game checklist (for I6):
1 Apply taint check (/console taintLog 1, Apply Q2 row, Create, check taint.log; if clean, turn on Settings > Crafting > applyWritesBlizzardSlots; confirm Professions.CreateCraftingReagent or CreateCraftingReagentByItemID exists).
2 Taint with callbacks only (panel, labels, SelfCheck on, Apply off): select recipes, craft with Blizzard Create, enter combat — no ADDON_ACTION_BLOCKED, no taint.log lines naming FabricationStation.
3 Event names fire: ProfessionsRecipeListMixin.Event.OnRecipeSelected, Professions.TransactionUpdated (panel live prediction updates on rank changes).
4 Auctionator: ConvertToSearchString/CreateShoppingList exist with term fields searchString/isExact/quantity/tier; list "FabricationStation" has right ranks/quantities; uncached names → "N items skipped, try again".
5 Warband reagents: with queueUseWarband on and reagents only in the warband bank, does Craft Next succeed?
6 Required modifying (spark-type) slot recipe: Craft Next succeeds and profit includes the slot.
7 Craft Next failures (away from station / too little concentration): does UNIT_SPELLCAST_FAILED fire or does "busy" stay 30 s?
8 Craft Next decrements: multicraft takes exactly one; enchant decrements on its cast; interrupted cast clears "busy".
9 Recalibration CPU: ~300 recipes open, craft 10 items, watch frame rate while the scan runs.
10 Panel layout at 1920 and 2560: no overlap with all 5 quality rows + 9 breakdown lines; hidden check line spacing.
11 Labels: no overlap with long names or count/skill-up markers; relabel after scroll and category collapse/expand.
12 Tooltips: Auctionator lines unchanged; lines added once; no hitch on first hover of a multi-recipe item.
13 Self-check: game thresholds vs difficulty×fraction match at 1e-6 and concentrationCost is an integer; after real GameData, "Math check: OK" while changing ranks.
14 Empty GameData: every result shows "estimate"; no Lua errors on first open, first scan, first tooltip.
15 Read-only (dbIsNewer): queue buttons say read-only; Calibrate doesn't persist.
