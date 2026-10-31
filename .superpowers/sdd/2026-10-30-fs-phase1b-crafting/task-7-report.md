# Task 7 report: Recipes, settings and calibration

Status: DONE_WITH_CONCERNS (the concerns are minor: one contract deviation and some design choices to note)
Commit: 2f373d4 feat: add Recipes settings and per-character calibration from live operation info (BASE 4eda661)

## What I built

### Modules/Recipes.lua (core module, `"Recipes"`, AceEvent-3.0)
- `Recipes.DEFAULTS` (the exact values from the brief) and `Recipes:GetSetting(key)`, which reads `db.global.settings.crafting[key]` (a stored `false` is kept) and falls back to DEFAULTS.
- Options group `"crafting"` (order 30, name "Crafting") with one control per key: ranges for `staleCalibrationDays` (1–60) and `scanBudgetMs` (1–16), toggles for the other four. Setters create `settings.crafting` lazily and write nothing when `ns.FS.dbIsNewer` is set. 1a's `costing.ownedReagentsFree` and `prices.staleAfterDays` are not duplicated here.
- `Recipes.STAT_NAMES`: the enUS map, with a comment that marks it as the one place to add other locales.
- `Recipes:Calibrate(recipeID)`:
  1. Gets the schematic with `Scanner:GetSchematic`; returns nil when there is none.
  2. Makes an empty-allocation live call. It returns nil when that call gives nil or has no numeric `baseSkill`.
  3. Builds a top-rank allocation and makes a second live call with it. Both calls pass `applyConcentration = false`.
  4. Computes `baseSkill = baseSkill + (bonusSkill or 0)` from the empty call, and `maxReagentSkill = top skill − baseSkill`, which is nil when no slot qualifies.
  5. Stores `{ time, baseSkill, baseDifficulty, maxReagentSkill, craftingDataID (op info, else the schematic's), stats = ParseBonusStats(empty.bonusStats, STAT_NAMES) }` in `db.global.recipeCalib[charKey][recipeID]` (created lazily) and bumps the character's stamp.
  6. When `dbIsNewer` is set, it returns the record without storing it or bumping the stamp.
- `Recipes:GetCalibration(charKey, recipeID)`, and `Recipes:GetDataStamp(charKey)`, which returns an integer that starts at 0.
- Auto-calibration has one `Recipes:AttachIfReady()`, guarded by an `attached` flag. It registers `EventRegistry:RegisterCallback("ProfessionsRecipeListMixin.Event.OnRecipeSelected", fn, Recipes)`. It is called from:
  - `ADDON_LOADED("Blizzard_Professions")`, which is registered in OnEnable and wrapped in SafeCall;
  - OnEnable, when `C_AddOns.IsAddOnLoaded("Blizzard_Professions") and ProfessionsFrame`.

  The callback does nothing while the module is disabled. It skips missing info and `learned == false`, and runs `Calibrate` through `ns.FS:SafeCall("Recipes", ...)`.

### tests/helpers/crafting_world.lua (`make_world(opts) -> ns, W, world`)
- It follows the brief:
  - Stubs: `UnitName`/`GetNormalizedRealmName` set to `"Main-Realm"`, plus fakes for `EventRegistry` (`RegisterCallback`, `UnregisterCallback`, `TriggerEvent`; registrations kept in `EventRegistry.callbacks[event]`, duplicates included), `TooltipDataProcessor.AddTooltipPostCall` (calls kept in `.postCalls`), `Enum.TooltipDataType.Item` and `debugprofilestop`. `opts.stubs` is deep-merged over these.
  - Load and boot: `load_addon({}, opts.last)`, then the sample GameData, then `W.boot()`.
  - Seeding: recipe 9001 per the brief, both characters at skill 500, base prices (auction, ageDays 1), `opts.calibrate` (a list or `"all"`) and `opts.recipes` clones.
  - Overrides: Scanner `GetCharacters/GetCharacter/GetProfession/IsProfessionOpen/GetSchematic/CacheSchematics(no-op)/GetLiveOperationInfo/GetItemCount` and Prices `Get/GetVersion/HasSource/GetLastUpdate` are replaced with functions backed by `world`. `ToCraftingReagentInfo`, `ProjectConcentration` and `Prices:IsStale` stay real; they work on top of the overridden reads.
  - Helpers: `world.bumpPriceVersion()`, `world.outputOf(id)` and `world.messages(name)`.
- Design choice: `world.schematics`, `world.chars` and `world.warband` are the actual `db.global.schematics/characters/warband.items` tables, and `world.items[charKey]` is the character's `items` table. Scanner overrides and code that reads the db directly therefore see the same data. Task 8's `FindRecipesForItem` indexes `db.global.schematics`, so this is needed there.
- Other fields: `world.counts[itemID]` overrides only `GetItemCount(itemID, nil).total`. `world.live[recipeID] = function(allocation, applyConcentration)`, and leaving it out means no live data. `world.openLine` drives `IsProfessionOpen` and is closed by default; Task 19's `openProfession` can set it.
- Clone k (recipe 9000+k) has outputs `5000+2k-1` and `5000+2k`, with output prices raised by (k−1)×1000 (q1) and (k−1)×5000 (q2). Clone 1 is 9001 with 5001/5002 and the base prices.

### Other changes
- `FabricationStation.toc`: `Modules\Recipes.lua` goes after `Modules\CraftingData.lua`.
- `tests/helpers/init.lua` exposes `make_world`.
- `tests/helpers/wow_stubs.lua` gets a default `C_AddOns = { IsAddOnLoaded = retFalse }`.
- `.luacheckrc`: `C_AddOns` added to `read_globals`; test `globals` now include `make_world` and `fake_professions_frame`.
- `tests/integration/load_all_spec.lua`: Recipes added to the enabled-module check and `crafting` to the option groups check.

## Tests
- `tests/recipes/calibration_spec.lua`, 28 specs:
  - The brief's 4 tests, verbatim.
  - Calibration: the call shapes (empty + top-rank, both without concentration), time and current character only, no quality slots (nil maxReagentSkill, one live call), optional slots kept out of the top allocation, a failing top call (nil, nothing stored, stamp unchanged), no schematic, the craftingDataID fallback with missing bonus fields, dbIsNewer (record returned, nothing written), stamps starting at 0, STAT_NAMES, coreModule.
  - Settings: the defaults, a stored false, the options group (order 30, one control per key), the lazy write through the options, a setting change moving every stamp (an unchanged value moves nothing), no write when dbIsNewer.
  - Auto-calibration: attaches on ADDON_LOADED of Blizzard_Professions only and only once, **`attaches_when_professions_already_loaded`**, no attach at enable without ProfessionsFrame, a single attach across Disable/Enable, the selected learned recipe gets calibrated, unlearned/nil/disabled are skipped, a failing calibration is contained by SafeCall (module turned off, listed in failedModules).
- `tests/helpers/crafting_world_spec.lua`, 7 specs: CharKey and the seeded characters, the schematic and GameData (weights 48/32/0, thresholds {1.0}, curve point {0.6, 2.2}), Prices backing and version bump, item counts with warband and counts override, live info, calibrate and clones (distinct outputs and prices), extra fakes and the opts.stubs merge.

### TDD evidence
RED: `busted tests/recipes/calibration_spec.lua`
```
Error -> tests/recipes/calibration_spec.lua @ 199
Recipes auto-calibration contains a failing calibration through SafeCall
tests/recipes/calibration_spec.lua:200: attempt to call global 'make_world' (a nil value)
```
(every spec failed the same way: `make_world` was undefined)

GREEN: `busted tests/recipes/calibration_spec.lua tests/helpers/crafting_world_spec.lua`
```
35 successes / 0 failures / 0 errors / 0 pending : 0.182374 seconds
```
Full: `busted` gives `597 successes / 0 failures / 0 errors / 0 pending`. `luacheck .` gives `Total: 0 warnings / 0 errors in 68 files`.

## Files changed
- Created: `Modules/Recipes.lua`, `tests/helpers/crafting_world.lua`, `tests/helpers/crafting_world_spec.lua`, `tests/recipes/calibration_spec.lua`
- Modified: `FabricationStation.toc`, `tests/helpers/init.lua`, `tests/helpers/wow_stubs.lua`, `.luacheckrc`, `tests/integration/load_all_spec.lua`

## Self-review findings and decisions
- **Contract deviation:** the contract's testing-harness section says `C_AddOns` is "NOT stubbed by default". Following the dispatch, I added it to the default stubs (`IsAddOnLoaded` returns false). Without it, the whole-addon load spec, which uses default stubs, would error in Recipes:OnEnable. The contract line should be updated to say so.
- The top-rank allocation includes only `kind == "basic"` slots with ≥ 2 reagents. The brief says "every slot with ≥ 2 reagents", but optional/finishing slots also list several items, and allocating them would add optional bonuses to the measured reagent skill. A test covers this.
- When the empty call succeeds but the top-rank call fails, Calibrate returns nil and stores nothing. A partial record would claim a calibration with an unknown reagent skill.
- When `dbIsNewer` is set, Calibrate returns the computed record but neither stores it nor bumps the stamp ("no db writes").
- `GetDataStamp` = per-character counter + a session settings version. A change to any crafting setting moves every stamp, so Task 8's Evaluate cache picks up `staleCalibrationDays` changes. Stamps live only in memory (they key the session cache). A stored calibration always bumps the stamp, even when the values are unchanged, because a new `time` can clear `staleData`.
- No message is sent on calibration or on a setting change. The brief asks only for the stamp bump; Task 10 can decide whether a rescan should follow.
- `AttachIfReady` returns without attaching when `EventRegistry` is missing; it never errors. The callback is never unregistered. Instead it checks `IsEnabled()`, so after a SafeCall shutdown and a re-enable it is still registered only once.

## Concerns
1. The contract's "not stubbed by default" list needs `C_AddOns` removed (see above).
2. Recipes is a core module, but the auto-calibration callback runs through `SafeCall("Recipes", ...)`, as the global constraint for hook bodies requires. A thrown error there turns the core Recipes module off until "Turn on again". The live call is already pcall'd in the real Scanner, so this is unlikely, but please confirm this is acceptable for a core module.

## Fix round 1

The controller ruled that auto-calibration hook errors must only be logged and must never disable the core Recipes module.
Commit: `fix: log auto-calibration and attach errors without disabling the core Recipes module` (on top of 2f373d4).

### Changes
1. `Modules/Recipes.lua`:
   - The recipe-selection callback now runs through `ns.FS:SafeCall("Recipes:AutoCalibrate", ...)`.
   - Both attach paths run through `ns.FS:SafeCall("Recipes:Attach", self.AttachIfReady, self)`: the `ADDON_LOADED("Blizzard_Professions")` handler and the OnEnable path (when `IsAddOnLoaded and ProfessionsFrame`).

   These are non-module sources, so errors are logged and the module stays enabled. I added a comment at each call site. The OnEnable path was a direct call before, so an attach error there would have escaped OnEnable; now it is logged too.
2. `tests/recipes/calibration_spec.lua`:
   - The former "contains a failing calibration through SafeCall" spec now asserts the opposite: after a hook error, `diagnostics.errors` has one entry with source `"Recipes:AutoCalibrate"` and the error text, `failedModules.Recipes` is nil and `R:IsEnabled()` is true. A later recipe selection still calibrates (`maxReagentSkill == 280`).
   - New: "logs a failing attach and keeps the core module enabled" covers the ADDON_LOADED path with source `"Recipes:Attach"`.
   - New: "logs a failing attach at enable and keeps the core module enabled" covers the OnEnable path.
3. Removed the vacuous `assert.is_truthy(ns)` and the unused local (`local _, W = make_world(...)`).
4. Added a comment where Calibrate returns its record under `dbIsNewer`: the record is not stored, so GetCalibration will not return it.

### Tests
RED, after the spec changes and before the code change: `busted tests/recipes/calibration_spec.lua`
```
Failure -> tests/recipes/calibration_spec.lua @ 212
Recipes auto-calibration logs a failing attach and keeps the core module enabled
Expected objects to be equal.  Passed in: 'Recipes'  Expected: 'Recipes:Attach'
```
(the AutoCalibrate spec failed the same way: 'Recipes' instead of 'Recipes:AutoCalibrate')

GREEN:
- `busted tests/recipes/calibration_spec.lua`: `30 successes / 0 failures / 0 errors / 0 pending`
- `busted`: `599 successes / 0 failures / 0 errors / 0 pending`
- `luacheck .`: `Total: 0 warnings / 0 errors in 68 files`
