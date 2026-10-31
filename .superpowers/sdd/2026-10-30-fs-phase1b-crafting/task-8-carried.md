# Task 8 — carried items (controller rulings and review carries; all in scope for this task)

A. Scanner guard (carried from phase 1a final review; Modules/Scanner.lua):
   - known_base_lines returns nil (treat as "incomplete, don't mark anything") when GetProfessions() yields no professions at all.
   - apply_profession_info stores parentProfessionID only when it is a positive number.
   - Tests for both.
B. Dropped professions: Recipes:WhoCanCraft and the per-character recipe sets used by Evaluate/FindRecipesForItem skip profession records with `dropped == true`. Test.
C. CraftingData (from Task 1 review): AllocationFromReagentInfo's slot lookup skips slots with a currencyID or an empty reagents list (ToCraftingReagentInfo only emits ModifiedReagent slots); BuildInput/ThresholdFractions guard a non-number maxQuality (no error). Tests.
D. Unsupported maxQuality (from Task 2 review): Quality.Predict returns 1,nil,0 when no thresholds exist; Recipes must check Quality.Thresholds(...) == nil and set flags.estimated (never present a fake quality as real). Test.
E. Math flags (from Task 6): Math returns flags.noPrice always boolean, unreachableTarget/unknownOptional only when true. RecipeResult.flags must always carry every contract flag as a boolean: noPrice, stalePrice, staleData, unknownRecipe, estimated, unreachableTarget (+ unknownOptional). Normalize in Recipes.
F. Optionals (from Task 6): EvaluateAllocation picks optionals from input.optionals by optionalItemIDs — BuildInput must put the stats of every candidate optional (all items of optional/finishing slots, via CraftingData.OptionalStats) into input.optionals so a selected optional is never treated as unknown.
G. Data stamps (from Task 7): subscribe to FS_DATA_CHANGED(charKey, kind) and bump via Recipes' local bump_stamp: every kind for that charKey, except "items" only when ownedReagentsFree, and "warband" (account-wide) bumps every character only when ownedReagentsFree. Also bump on FS_RECIPES_CHANGED? — no; follow the brief. GetDataStamp(charKey) = stamps[charKey] + settingsVersion (already so). Tests.
H. Calibrate returns nil when the schematic isn't cached yet — acceptable; Evaluate without calibration estimates (flags.estimated, flags.staleData) per the contract.
