# Task 18 report: Tooltips module, craft-cost and crafters lines

Commit: b642d09 feat: add Tooltips line providers with craft-cost and crafters lines

## Built
- `UI/Tooltips.lua`: module "Tooltips" (user-toggleable). `RegisterLineProvider(id, fn)` (same id replaces in place and clears a session failure), `CollectLines(itemID)` (registration order, each pcall'd; a raising provider is disabled for the session and logged `Tooltips:<id>`; non-table results / non-table entries ignored). Built-ins `craftCost` then `crafters`, both gated only by `Recipes:GetSetting("tooltipCraftCost")`.
- Craft cost = cheapest `Evaluate(recipeID, charKey, {targetQuality = quality}).reagentCost` over `FindRecipesForItem` x `WhoCanCraft`; ties: non-estimated first, then WhoCanCraft order. "no price" when nobody has a cost; nothing when nobody crafts it. Crafters: short names (text before "-"), cheapest first, cost-less last.
- Hook: `TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, ...)` registered once (can't be removed); body checks `IsEnabled()` then `SafeCall("Tooltips", ...)`; nothing added when `data.id` is not a number.
- Only the built-ins are cached (shared per-item analysis); registered providers run on every tooltip.
- `.luacheckrc`: `TooltipDataProcessor` added to read_globals. TOC: `UI\Tooltips.lua` appended.

## Tests (tests/ui/tooltips_spec.lua, 24 specs)
Brief's three plus: ordering/ties, quality passed as targetQuality, no price (+crafters still listed), cost-less crafters last, dropped profession skipped, replace in place / re-enable failed provider, malformed results, bad registration, cache until FS_RECIPES_CHANGED (Evaluate call count), recompute after price change, `registered_provider_not_cached`, `tooltipCraftCost_off_keeps_other_providers`, hook registered once (also across off/on), AddDoubleLine, non-number id, module off, failing hook body disables only Tooltips, failing provider keeps module on.

RED: `busted tests/ui/tooltips_spec.lua` -> "lastFile not found in FabricationStation.toc: UI/Tooltips.lua" (module missing).
GREEN: `busted tests/ui/tooltips_spec.lua` -> 24 successes / 0 failures.
Full: `busted` -> 1034 successes / 0 failures / 0 errors; `luacheck .` -> 0 warnings / 0 errors in 89 files.

## Files changed
UI/Tooltips.lua, tests/ui/tooltips_spec.lua, FabricationStation.toc, .luacheckrc, tests/helpers/crafting_world.lua, tests/helpers/wow_stubs.lua.

## Deviations / notes
- Because Tooltips enables in every full addon load, specs that use plain `install_wow_stubs` (settings, launcher, load_all) failed on the missing `TooltipDataProcessor`. I moved the `TooltipDataProcessor` fake (records `postCalls`) and `Enum.TooltipDataType.Item` from `make_world` into the base `wow_stubs.lua`, and removed the duplicate from `crafting_world.lua` (header comment updated). `crafting_world_spec` still passes.
- Cache invalidation is wider than the brief's "until FS_RECIPES_CHANGED": it also clears on FS_PRICES_CHANGED and FS_DATA_CHANGED (and on OnEnable), otherwise a price/item change would leave a stale cost until the next recipe scan. FS_RECIPES_CHANGED still clears it (tested).
- WhoCanCraft returns keys sorted, so with equal, equally-estimated costs "Alt" precedes "Main"; the brief's example gets "Main" first because Main is calibrated (non-estimated).
- Cost-less crafters keep WhoCanCraft order (no tie-break by estimated, since there is no cost to compare).
- Not verified in game (no client here).

## Fix round 1
Commit: see `git log` ("fix: validate Tooltips provider lines, stable crafter tie-break and more cache tests").

Changes (UI/Tooltips.lua unless noted):
1. `CollectLines` now runs each entry through `line_texts`: the left must be a string (else the line is skipped); right string kept, number -> `tostring`, nil -> "", anything else skips the line. So `{nil,"x"}` and `{5,6}` are dropped, `{"only-left"}` shows as left with "" (per the nil-right rule), `{"num",7}` shows "7". tests: the spec fake `AddDoubleLine` now raises on a non-string left like the client.
2. Crafters sort tie-break is `a < b` on charKey (the first-seen rank table is gone).
3. `hooked = true` is set only after `AddTooltipPostCall` returns.
4. New tests: cache cleared on FS_DATA_CHANGED, cache cleared on re-enable, two recipes producing one item (cheapest across recipes; charKey tie-break where first-seen order is Main, Alt but result is Alt, Main).
5. `local globals = {` re-indented in tests/helpers/wow_stubs.lua (my earlier edit dropped the indent); the long comment above `better` is wrapped.

New specs: skips lines without a string left text and normalises the right text; malformed provider lines are dropped and the module stays enabled (hook level); clears the cache on FS_DATA_CHANGED; clears the cache when the module is enabled again; breaks ties between crafters by character key; takes the cheapest over every recipe that makes the item.

Mutation checks (temporary, restored): tie-break returning false -> 1 failure; dropping the string-left check -> 2 failures.
Commands: `busted tests/ui/tooltips_spec.lua` -> 30 successes / 0 failures; `busted` -> 1040 successes / 0 failures / 0 errors; `luacheck .` -> 0 warnings / 0 errors in 89 files.
