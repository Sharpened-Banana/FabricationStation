# Task 17 report: Recipe-list profit labels

## Built
- `UI/RecipeListLabels.lua`: module `RecipeListLabels` (AceEvent, toggleable, not core). `ns.UI.RecipeListLabels.LabelText(result) -> text, colorKey`.
  - Labels are own FontStrings (`row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")`, RIGHT-anchored, right-justified) held in a weak-keyed table keyed by row; no field is ever written on a Blizzard frame.
  - `AttachIfReady` (from ADDON_LOADED("Blizzard_Professions") and OnEnable, guarded by `attached`) registers `ScrollBox:RegisterCallback(ScrollBoxListMixin.Event.OnInitializedFrame, fn, self)` and labels rows already on screen via `ForEachFrame`. Missing ScrollBox raises `"recipe list ScrollBox not found"` inside SafeCall -> module off, 1a's chat line.
  - Every callback runs in `SafeCall("RecipeListLabels")`. `FS_RECIPES_CHANGED` relabels via `ForEachFrame`.
  - Row recycling: each initialisation relabels the row; a row now holding a category header (no `recipeInfo`) or a recipe with no result (schematic not cached) has its label hidden, not left stale.
  - OnDisable unregisters the callback and hides every label from the weak table (superset of ForEachFrame: also pooled rows, which would otherwise show a stale label when reused while the module is off).
- `FabricationStation.toc`: `UI\RecipeListLabels.lua` after ProfessionPanel.
- `tests/helpers/professions_frame.lua`: `form.newRow()` (recorded proxy row, assignments recorded as `Row.<key>`; CreateFontString makes tracked font strings with IsShown/Hide/Show/SetTextColor/GetTextColor, `.template`, `.layer`) and `form.fontStringsOf(row)`; header docs updated.
- `.luacheckrc`: added read-only global `ScrollBoxListMixin`.
- `tests/helpers/crafting_world.lua`: no change needed (`professions = {}` and `fakeEvaluate` already cover it).

## Display decisions (brief silent or ambiguous)
- Compact label, not `ns.UI.FormatMoney`: FormatMoney yields "12g 0s 1c"/GetMoneyString output, which cannot produce the brief's verbatim "+12g"/"+45s". A local compact formatter is used; FormatMoney remains the full-width form elsewhere. Gold rounds DOWN (never overstate profit); <1g in silver; <1s in copper ("+50c").
- nil/NaN profit -> "?" grey, never 0g. Profit 0 -> "0g" grey.
- noPrice WITH a profit -> profit plus trailing "?" keeping the sign colour ("+12g?"), mirroring the panel's "some prices missing".
- Evaluate nil result (schematic not cached) -> label hidden (blank).
- Only FS_RECIPES_CHANGED triggers relabel (per brief). A price change normally reaches it via the PRICES_CHANGED -> rescan -> RECIPES_CHANGED chain; I did not add a PRICES_CHANGED listener.

## Tests (tests/ui/recipe_list_labels_spec.lua, 22 specs)
- RED: `busted tests/ui/recipe_list_labels_spec.lua` -> every spec errored "failed to load UI/RecipeListLabels.lua: cannot open ... No such file".
- GREEN: `busted tests/ui/recipe_list_labels_spec.lua` -> 22 successes / 0 failures / 0 errors.
- Full: `busted` -> 1010 successes / 0 failures / 0 errors. `luacheck .` -> 0 warnings / 0 errors in 87 files.
- Covers: LabelText values (brief's four + silver/copper/rounding/zero/nil/noPrice), no fields written on rows (`assignedFields == {}`), one font string per row across re-initialisation, colours, Evaluate args (CharKey, `{}`), category rows skipped and recycled-row hiding, unevaluable recipe hides, relabel on FS_RECIPES_CHANGED, rows already on screen at attach, module off/on (labels hidden/shown, callback unregistered/re-registered once, no labels while off), `attaches_when_professions_already_loaded`, not attached before load, `disables_when_scrollbox_missing` (ADDON_LOADED and at-enable), error in callback disables only this module, toggleable non-core module.

## Findings while implementing
- The 1a CreateFrame fake returns a no-op for any capitalised missing key, so `list.ScrollBox` on a frame without one is a function, not nil. AttachIfReady therefore type-checks each step (`type(x) == "table"`), as `schematic_form()` in ProfessionPanel does.
- `ForEachFrame` pooled-row caveat above (why OnDisable iterates the weak table).

## Not verifiable here
In-game checks (label placement against Blizzard's row text, fast scrolling, update after an Auctionator scan, Settings > Modules toggle) need the real client. Label anchor is `RIGHT, row, RIGHT, -4, 0`; may need an offset tweak in game if it collides with Blizzard's row text/icons.

## Files changed
UI/RecipeListLabels.lua (new), tests/ui/recipe_list_labels_spec.lua (new), tests/helpers/professions_frame.lua, FabricationStation.toc, .luacheckrc
