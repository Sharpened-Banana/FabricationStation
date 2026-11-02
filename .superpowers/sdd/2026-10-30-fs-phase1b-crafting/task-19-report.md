# Task 19 report: In-game self-check

## What was built
- `Modules/SelfCheck.lua` (new, core module): `ns.SelfCheck.QUALITY_FIELD`, `ns.SelfCheck.Compare`, `SelfCheck:Run(recipeID)`, `SelfCheck:GetSessionCount()`.
  - `Compare(prediction, opInfo)`: fields in brief order (skill +-0.5 vs baseSkill+bonusSkill; difficulty; quality vs `opInfo[QUALITY_FIELD]`; lowerThreshold; nextThreshold only when the prediction has one; concentrationCost only when the game cost > 0 and the prediction has a cost). A number missing on either side is never a mismatch. Non-skill numeric fields use a 1e-6 tolerance (float noise only).
  - `Run`: reads Blizzard's transaction (read only: `ProfessionsFrame.CraftingPage.SchematicForm:GetTransaction()`, `CreateCraftingReagentInfoTbl`, `IsApplyingConcentration`), predicts with `Recipes:FromCraftingReagentInfo` + `PredictLive`, asks `Scanner:GetLiveOperationInfo` with the required allocation plus one `{slotIndex,itemID,quantity}` row per optional/finishing reagent in the transaction (slot found by dataSlotIndex, so the row's slot is exact), compares, logs new mismatches via `Diagnostics:LogMismatch` with `context = { calib, schematic, reagents (the transaction infos), operationInfo }`, and sets the panel status.
  - Dedupe: `(recipeID, field, expected, actual)` once per session (in-memory set); `Run` still returns every current mismatch.
  - Triggers: `EventRegistry` `ProfessionsRecipeListMixin.Event.OnRecipeSelected` and `Professions.TransactionUpdated`, plus the schematic form's `AllocationsModified` (same events/owner pattern as ProfessionPanel, no new frame hooks). All three go through one `ns.FS:Debounce("selfCheck.run", 0.2, ...)`. Attach follows the standard `AttachIfReady` pattern (ADDON_LOADED + OnEnable, `attached` flag, detach in OnDisable).
  - Safety: attach, schedule and the debounced run use SafeCall sources `"SelfCheck:Attach"`, `"SelfCheck:Schedule"`, `"SelfCheck:Compare"` (non-module, so log-only; the module is never turned off).
  - Status: `panel:SetStatus("Math check: OK", "good")` or `"Math check: N mismatches (see Settings > Diagnostics)"` with tone `"warn"` (the > is U+203A as in the brief), through `ns.FS:GetModule("ProfessionPanel", true)`; absent/disabled panel = no status, no error.
- `UI/ProfessionPanel.lua`: `Panel:SetStatus(text, tone)` gained an optional tone (default "plain"); one-arg callers unchanged.
- `FabricationStation.toc`: `Modules\SelfCheck.lua` after `Modules\QueueCraft.lua`.
- `tests/helpers/crafting_world.lua`: `world.liveReagents(infos, recipeID)` (the open transaction's reagent infos for recipeID, default 9001; builds the fake Professions frame if the world has none; returns it). Documented in the header.
- `tests/recipes/selfcheck_spec.lua`: the brief's 3 tests verbatim plus compare, run, callbacks and status-line specs (41 specs).

## Decisions
- Estimated predictions are NOT compared or logged. `check` skips (returns nil, `Run` returns `{}`, no status change) when: the selfCheck setting is off; the profession window is closed (`Scanner:IsProfessionOpen()`); no transaction or the transaction is for another recipe; no schematic or no calibration for the character; `Recipes:Evaluate(...).flags.estimated` (no GameData thresholds / default thresholds / no calibration); the prediction has `flags.unknownOptional`. Reason: with empty GameData (as checked in) every quality/threshold would differ and fill the capped mismatch log with noise that says nothing about the formulas; the exporter could not use such fixtures either. Once real GameData is generated the check runs by itself. Cost: one cached `Evaluate(recipeID, charKey, {})` per run for the flag.
- Skipped runs leave the status line alone (so "Added 1x ... to the queue" is not wiped when nothing was checked).

## TDD evidence
Order caveat: the spec was written together with the implementation; RED was produced afterwards by moving `Modules/SelfCheck.lua` away:
`busted tests/recipes/selfcheck_spec.lua` -> `0 successes / 0 failures / 41 errors` ("failed to load Modules/SelfCheck.lua: cannot open ... No such file or directory").
GREEN: `busted tests/recipes/selfcheck_spec.lua` -> `41 successes / 0 failures / 0 errors / 0 pending`.
Failures hit while iterating (all fixed): wrong expectation about the fixed slot 3 row in the allocation; world's fake `GetLiveOperationInfo` ignores `openLine` (fixed by an explicit `Scanner:IsProfessionOpen()` gate in SelfCheck, also cheaper and correct for a hidden frame); a spec counted live calls that Recipes' auto-calibration also makes; `SetModuleEnabled` cannot disable a core module (spec uses `S:Disable()`); attach-error spec saw `Recipes:Attach` first.

Full suite: `busted` -> `1081 successes / 0 failures / 0 errors / 0 pending`. `luacheck .` -> `0 warnings / 0 errors in 91 files`.

## Files changed
Modules/SelfCheck.lua (new), tests/recipes/selfcheck_spec.lua (new), UI/ProfessionPanel.lua, FabricationStation.toc, tests/helpers/crafting_world.lua.

## Self-review / concerns
- Concentration applied in the window: Math's `skill` describes the allocation, the game's `baseSkill+bonusSkill` with `applyConcentration=true` may include concentration's skill. If so, `skill`/threshold mismatches will appear in game whenever the concentration toggle is on (logged once each per distinct values). Needs the in-game check; if confirmed, compare with `applyConcentration=false` for skill/thresholds (one-line change in `check`). Brief says pass `applyConcentration`, so I did.
- The status line is shared with other panel messages; a self-check 0.2 s after an allocation change overwrites e.g. "Applied the Q2 reagents". Accepted per "use SetStatus"; a dedicated line would be a small panel layout change if wanted.
- Each logged mismatch deep-copies the schematic into SavedVariables (cap 200 entries by Diagnostics); fine for fixtures, but heavy if many distinct mismatches pile up.
- Thresholds compared at 1e-6: if the game rounds fractional thresholds, those will log (useful signal for Task 9, noisy otherwise).
- Not verified in game (no client here); the Step 4 in-game checks remain.

## Fix round 1
Changes:
1. Compare without concentration: `PredictLive(..., false)` and `GetLiveOperationInfo(..., false)`; the `IsApplyingConcentration` read is gone. Spec "asks the game for the transaction's reagents without concentration, even while Blizzard applies it" asserts false for both calls with `form.applyingConcentration = true`.
2. Own panel line: `Panel:SetCheckLine(text, tone)` (nil/"" hides) with a new `view.checkLine` FontString below the status line (status is anchored above it; craft/add buttons unchanged). SelfCheck uses it instead of `SetStatus`. Specs: "never overwrites the action status" ("Applied the Q2 reagents" survives), panel spec "SetCheckLine shows SelfCheck's own line and leaves the status line alone".
3. Skips clear the line (`SetCheckLine(nil)`): `check` now wraps an inner `compare` and shows the status for its result or clears it when nothing was compared; a setting-off `schedule` also clears. Specs: setting off, window closed, recipe A mismatches -> uncalibrated recipe B -> cleared and hidden.
4. Flood guard: at most 3 distinct logged mismatches per (recipeID, field); `logged`/per-field counts restart when `Diagnostics:GetMismatches()` is empty (cleared in Settings; checked in `log_new`, no hook on Diagnostics). "1 mismatch" singular (plural for >1, spec added). Spec: 5 distinct quality values log 3; after `ClearMismatches` the same value logs again once.
- Test infra: `tests/helpers/wow_stubs.lua` fake FontString gained Show/Hide/IsShown (shown at first) so specs can assert the line's visibility.

Command: `busted` -> `1087 successes / 0 failures / 0 errors / 0 pending`; `luacheck .` -> `0 warnings / 0 errors in 91 files`. Covering: `busted tests/recipes/selfcheck_spec.lua tests/ui/profession_panel_spec.lua` green.
