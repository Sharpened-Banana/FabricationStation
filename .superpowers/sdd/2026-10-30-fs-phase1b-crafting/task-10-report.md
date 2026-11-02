# Task 10 report: recipe scan (time-sliced) and GetRanked

## Built
`Modules/RecipeScan.lua` extends the Recipes module (loaded after Recipes.lua in the TOC):
- `Recipes:StartScan(charKey|nil)`, `IsScanning()`, `_ScanStep(budgetMs) -> done`, `GetRanked(filter)`.
- The pass is a coroutine. Budget is checked (`debugprofilestop() - stepStart >= budget`) after EVERY Evaluate and every Calibrate, so one step always completes at least one unit (even with budget 0) and never a whole character's recipes. A single slow Evaluate (stubbed +500 ms) makes the step yield right after it.
- Evaluate is called as `Recipes:Evaluate(id, charKey, {})`, so Recipes' cache is what makes a rescan cheap (spec: second pass runs 0 `EvaluateCraft` calls).
- Results are staged and committed atomically at pass end (GetRanked serves the last completed pass while one runs); a full pass replaces everything, a single-character pass replaces only that character. One `FS_RECIPES_CHANGED` per completed pass.
- A `StartScan` during a pass sets dirty (union of requested chars / "all"); one restart pass follows. `_ScanStep` returns false (not done) at the end of a pass that has a restart pending, true only when nothing is left. The restart is set up before the message is sent, so a listener calling StartScan from FS_RECIPES_CHANGED is also handled (and `_ScanStep` is not reported done while a pass is pending).
- Scanned recipes: every recipe each character knows in non-dropped professions (deduped across professions), whose schematic is cached (Evaluate nil = skipped).
- Calibration: when `Scanner:IsProfessionOpen()` and the character is the current one, each known recipe of the open profession is `Calibrate`d first in the same coroutine, with a budget check after each. Once per recipe per window opening (a `calibrated` set, cleared when the window is found closed at pass start and on non-item/warband FS_DATA_CHANGED for the current character), so repeated passes do not bump the stamp and invalidate the cache needlessly.
- Driver: `Recipes.scanFrame` (hidden; shown by a pass; OnUpdate -> `SafeCall("Recipes:Scan", _ScanStep(GetSetting("scanBudgetMs")))`; hides when done). Created in the wrapped `Recipes:OnEnable`.
- Triggers: `FS_PRICES_CHANGED` -> `StartScan(nil)`; `FS_DATA_CHANGED(charKey)` -> `StartScan(charKey)` through `FS:Debounce` 1 s (key per charKey; nil or "warband" = everyone). "items"/"warband" are ignored unless `costing.ownedReagentsFree` (they cannot change results otherwise).
- Failures: each Evaluate/Calibrate runs under xpcall; a failing recipe is logged once per session (`LogError("Recipes:Scan", ...)`) and skipped, so a bad schematic never stops the scan or turns off the core Recipes module. A coroutine-level error resets the scan state and rethrows (driver SafeCall logs it).
- GetRanked: filters skillLineID (the profession record key the recipe was scanned under), charKey, minQuality (expectedQuality >= n; nil excluded), usesConcentration (goldPerConcentration non-nil), onlyProfitable (not noPrice, profit > 0). Sort desc by `profit` (default; unknown sortBy -> profit) or `goldPerConcentration`; noPrice or nil key after all priced, by recipeID; ties by recipeID then charKey. Returns a fresh list of shared (read-only) results.
- `.luacheckrc`: added `debugprofilestop` to read_globals. `crafting_world.lua` needed no change (already stubs debugprofilestop since Task 8).

## Tests (tests/recipes/scan_spec.lua, 50 specs)
Brief's 3 specs verbatim + slicing (slow evaluation yields after itself, zero budget still does one, not a whole character, cache reuse, done semantics), driver frame (OnUpdate, scanBudgetMs, failing step logged once), which recipes (all/one char, dropped, uncached schematic, unknown, duplicates, removed char), GetRanked (order, ties, goldPerConcentration, nil keys, noPrice, onlyProfitable, every filter, fresh list), triggers (price change, debounce 1 s, bursts, items/warband gating, union restart, full restart, listener-requested scan, disable/enable), calibration (budgeted, before evaluating, only open/current/non-dropped, once per window opening, recalibrate after data change, one announcement).

## TDD evidence
RED: `busted tests/recipes/scan_spec.lua` -> every spec errors: `failed to load Modules/RecipeScan.lua: cannot open ... No such file` (module absent; StartScan undefined).
GREEN: `busted tests/recipes/scan_spec.lua` -> 50 successes / 0 failures.
Full: `busted` -> 710 successes / 0 failures / 0 errors; `luacheck .` -> 0 warnings / 0 errors in 72 files.
(Lua 5.1 bug found along the way: `xpcall(f, h, ...)` does not forward args; the first version silently evaluated nothing. Now closures.)

## Files
Modules/RecipeScan.lua (new), tests/recipes/scan_spec.lua (new), FabricationStation.toc, .luacheckrc.

## Self-review / concerns
- A `flags.noPrice` result can still carry a non-nil `profit`: when the best-quality output has no price Math picks a cheaper priced quality (observed: brief's 9003 case gives profit 74384 with noPrice true). Ranking follows the brief: the flag, not the profit, decides; noPrice is excluded from profit sorting and onlyProfitable. Consumers displaying profit must check the flag.
- RecipeScan reuses the Recipes module (wrapping OnEnable/OnDisable) rather than a new module. Recipes already holds the only FS_DATA_CHANGED registration on its object, and AceEvent keeps one handler per message per object, so the scan listens through a plain AceEvent-embedded helper object.
- No initial scan at login: results stay empty until a price change, data change or explicit StartScan (Scanner's login "professions" message normally triggers it). Not in the brief; a UI could call StartScan(nil) on first show.
- Contract text already matches (StartScan/IsScanning/_ScanStep/GetRanked); no contract change made.
- Commit made locally, not pushed.

## Fix round 1
Commit: see `git log -1` (fix: first scan after enable, rescan on setting changes, clean disable, shared owned-free accessor).

Changes
1. First scan: `Recipes:OnEnable` arms a one-shot `C_Timer.NewTimer(5, Wrap("Recipes:Scan", StartScan(nil)))`. Any earlier timer is cancelled first (armed once however often OnEnable runs); `OnDisable` cancels it.
2. `Recipes:IsOwnedReagentsFree()` (Recipes.lua) replaces the private `owned_free_setting()`; RecipeScan uses it too (its duplicate is gone).
3. `set_setting` in Recipes.lua now calls the optional hook `Recipes:OnCraftingSettingChanged(key)` (defined by RecipeScan) after bumping settingsVersion; it starts a debounced (1 s) full scan, except for `scanBudgetMs` (timing only). Unchanged values do not bump, so no rescan.
4. OnDisable cancels the data-change/settings debounce timers (new `FS:CancelDebounce(key)` in Core/Core.lua, spec in tests/core/core_spec.lua; RecipeScan remembers the keys it used) and clears `results`, so GetRanked returns {} while disabled and after re-enable until the next pass.
5. Specs: skillLineID filter now uses two professions (7777 vs 2906) and asserts exactly each one's recipes; disable/enable spec asserts exactly one announcement per pass after re-enable (also a second one for a data change), plus "pending data-change scan is dropped when disabled".

New specs (tests/recipes/scan_spec.lua): first scan (starts after ~5 s, one announcement, one-shot; disable before firing does nothing; armed once with repeated OnEnable; re-armed after disable/enable), setting changes (rescan after 1 s, burst debounced, results refreshed e.g. staleData flips, no rescan for unchanged value or scanBudgetMs), disable clears results, FS:CancelDebounce.

Verification: `busted` -> 722 successes / 0 failures / 0 errors; `luacheck .` -> 0 warnings / 0 errors in 72 files. (evaluate/calibration specs untouched and green.)

Note: storing a setting's default value for the first time (nil -> default) counts as a change in `set_setting`, so it triggers a rescan; harmless.
