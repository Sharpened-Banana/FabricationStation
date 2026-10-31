# Task 11 report: Queue core

## Built
- `Modules/Queue.lua` (coreModule, AceEvent): Add/Remove/GetEntries/SetQuantity/Clear, SetRestock/GetRestockTargets, GetMissingReagents, GetEntryMissing, GetEntryCost. Storage `db.global.queue = { entries, restock, nextID }` (nextID lazy; derived from max existing id when absent). No writes when `ns.FS.dbIsNewer` (Add returns nil).
- FS_QUEUE_CHANGED after every actual change (no-ops such as removing an unknown id or clearing an empty queue send nothing). FS_RECIPES_CHANGED and FS_DATA_CHANGED (any kind) schedule one trailing 0.5 s debounce (`ns.FS:Debounce`) that sends one FS_QUEUE_CHANGED; handler/callback wrapped as log-only source `Queue:Recompute`; OnDisable unregisters and cancels the debounce.
- Test helper: `world.fakeEvaluate(recipeID, result|fn(charKey,opts,recipeID)|nil)` (wraps `Recipes.Evaluate` on first use; other recipes and nil go to the real one) and `world.evaluated` call log `{recipeID, charKey, opts}`. Spec added in `tests/helpers/crafting_world_spec.lua`.
- TOC: `Modules\Queue.lua` after `Modules\RecipeScan.lua`.

## Rules as implemented
- Per-craft requirement: `Recipes:Evaluate(recipeID, charKey, {targetQuality, useConcentration, providedReagents}).allocation`, all from the entry.
- Missing: per character, requirements aggregated over that character's entries, `max(0, required - (bags+bank+reagentBank))` (explicit fields, NOT `.total`, which already contains the warband); sums across characters; when `queueUseWarband`, `GetItemCount(itemID, nil).warband` subtracted once per item, clamped at 0, zero items omitted.
- Restock: held = `GetItemCount(itemID,nil).total`; first of FindRecipesForItem; crafter = WhoCanCraft member with highest Evaluate profit (nil profit loses to any number; ties and all-nil -> first); `crafts = ceil((target-held)/yield) - queued real quantity of same recipe+quality (any character)`; listed only when > 0. Missing/<=0 yield treated as 1. Restock entries are included in GetMissingReagents/GetEntryMissing/GetEntryCost.
- Cost: `reagentCost * quantity`; nil when reagentCost is nil or Evaluate returns nil (never 0).

## TDD
- RED: `busted tests/queue/queue_spec.lua` -> `lastFile not found in FabricationStation.toc: Modules/Queue.lua` (module missing).
- GREEN: `busted tests/queue` -> `35 successes / 0 failures / 0 errors`.
- Full: `busted` -> `758 successes / 0 failures / 0 errors / 0 pending`; `luacheck .` -> `0 warnings / 0 errors in 74 files`.

## Files
Modules/Queue.lua, tests/queue/queue_spec.lua, FabricationStation.toc, tests/helpers/crafting_world.lua, tests/helpers/crafting_world_spec.lua. Commit: see git log ("feat: add Queue entries, restock targets and missing reagents").

## Self-review / judgement calls
1. `providedReagents` is subtracted from the per-craft requirement in missing-reagent math (customer-provided mats are not the crafter's to buy). The brief says requirement = allocation; Evaluate's allocation covers the whole slot including provided items, so without this an order entry would ask the player to buy provided mats. Evaluate itself already prices provided items at 0. Tell me if you want the literal allocation instead.
2. An entry whose recipe schematic is not cached (Evaluate nil) contributes nothing to missing reagents and has cost nil.
3. `GetEntries` returns copies (including a copied providedReagents); mutating them changes nothing. `Add` copies providedReagents too.
4. Recompute debounce fires for every DATA_CHANGED kind and even with an empty queue (literal reading of the brief); cheap, UI-only refresh.
5. FS_PRICES_CHANGED is not listened to (per brief): costs refresh via RecipeScan's FS_RECIPES_CHANGED after its pass.
6. `Add` does not merge identical entries; quantity is floored and must be >= 1; `SetRestock` floors target, < 1 removes.
7. With dbIsNewer, Add/Remove/SetQuantity/Clear/SetRestock are no-ops (reads still work).

## Concerns
None blocking. The contract needs no change except optionally noting the provided-reagents subtraction (item 1).
