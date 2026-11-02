# Task 14 report: Recipes tab

## Built
- `UI/Tabs/Recipes.lua`: core module `RecipesTab` registering tab `recipes` ("Recipes", order 20, phase 1) with MainWindow; refresh only through `MainWindow:RefreshTab` (selected + visible tab), 0.5 s debounce on `FS_RECIPES_CHANGED`. Build/refresh run under MainWindow's `Tab:recipes` SafeCall; click handlers are `ns.FS:Wrap("RecipesTab:<what>")`.
- Pure models on `ns.UI.RecipesTab`: `BuildRows`, `FilterFromControls`, plus `QueueEntry`, `NextOption`, `CellTexts`.
- Filter bar: cycle buttons for profession (skill lines of all non-dropped professions), character, min quality (Any, 1+..5+); check boxes "Uses concentration" and "Only profitable". Header row: only Profit and Gold/conc. are clickable (the only sorts `GetRanked` has); active one shows " v". "Scanning…" at the top right while `IsScanning()`. Row button "Queue" -> `Queue:Add({ recipeID, quantity = 1, charKey, targetQuality = quality, useConcentration = state.usesConcentration })`, with a one-line status ("Queued X (Char)" / "Could not add to the queue").
- Display rules: nil profit -> "no price" (cost/sale too), never 0g; noPrice with profit -> profit + "some prices missing"; estimate/stale markers; price age via `ns.UI.FormatAge`; names from `Scanner:GetSchematic(id).name`, else `"recipe:<id>"`.
- `FabricationStation.toc`: `UI\Tabs\Recipes.lua` after Dashboard.
- `tests/ui/settings_spec.lua`: tab-count assertion 2 -> 3 (dashboard + recipes + settings), a necessary consequence of the new tab.

## Tests
- `tests/ui/recipes_tab_spec.lua`: 37 specs (models, flags order, no-price/missing-price display, filters, sorting, cycle buttons, queue add/refuse, pooling of 500 rows, scroll, refresh debounce, hidden-tab no-op, disable, failure isolation under `Tab:recipes`).
- RED: `busted tests/ui/recipes_tab_spec.lua` -> 2 errors, "failed to load UI/Tabs/Recipes.lua: cannot open ... No such file". GREEN: 37 successes / 0 failures.
- Full: `busted` 877 successes / 0 failures; `luacheck .` 0 warnings / 0 errors.

## Deviations and concerns
1. **No `WowScrollBoxList`.** The brief suggests it, but I cannot verify the ScrollBox factory/template API here (`SetElementInitializer` with a plain frame type vs. a registered XML template), and a wrong guess only fails in game. The list is instead a pooled virtual list in a plain `ScrollFrame` (Dashboard pattern, wheel scrolling, no scrollbar) using only APIs the stubs and Dashboard already exercise; rows in view are the only frames. Swapping to ScrollBox later touches only `create_row/update_rows`.
2. Dropdowns are cycle buttons (click = next option) for the same reason (no unverified `SetupMenu` API).
3. Position of "some prices missing" in `flagsText`: it takes the "no price" slot (first), since the brief's fixed order lists only the five other flags.
4. Only Profit and Gold/conc. headers sort, since `GetRanked` supports only those.
5. Not verified in game (no client here): visual layout of columns/widths, template names `UIPanelButtonTemplate`/`UICheckButtonTemplate` (both standard).
6. The "queued" status stays until the next filter change or queue click (not cleared by data refreshes).

## Fix round 1
Changes (`UI/Tabs/Recipes.lua`): Queue refusal while `ns.FS.dbIsNewer` shows "Saved data is from a newer version of FabricationStation; the queue is read-only." (generic message kept for other nil returns); a profit of exactly 0 is uncoloured (green > 0, red < 0). No stub change was needed: the specs override `GetHeight/GetVerticalScroll/SetVerticalScroll` on the scroll frame instance.
New specs (`tests/ui/recipes_tab_spec.lua`, 43 total): scroll clamp when the list shrinks while scrolled down (offset clamped to 30*22-220, visible rows 9021..9030 valid, no extra row shown); scroll back to 0 when the list fits; read-only message with `dbIsNewer = true` against the real Queue (no entry added, no generic text); all six filter keys combined; filter state (character, concentration, sort) persists across an FS_RECIPES_CHANGED refresh; zero profit has no colour code.
Mutation check: with the clamp disabled the clamp spec failed; restored.
Commands: `busted tests/ui/recipes_tab_spec.lua` -> 43 successes / 0 failures; `busted` -> 883 successes / 0 failures; `luacheck .` -> 0 warnings / 0 errors.
