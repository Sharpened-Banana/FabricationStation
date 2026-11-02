# Task 14 report: Planner tab

Status: DONE_WITH_CONCERNS (all in-game steps are unverified: there is no WoW client here; see the T14 lines in ingame-checklist.md)
BASE 6dde7ef. Commit: 01d2ade feat: add Planner tab with knowledge, concentration, spec and recipe sections

## What I built

### `UI/Tabs/Planner.lua` (new)
- Core registrar module `PlannerTab` (`coreModule = true`) registers tab `"planner"` in `OnInitialize`: `{ label = "Planner", icon = "Interface\\Icons\\INV_Misc_Note_01", order = 80, phase = 3, build, refresh }` (preflight row 17).
- A row of section buttons picks one section: Knowledge, Concentration, Spec advice, Missing recipes. The shown section's button is `LockHighlight`ed. The choice is stored in `Planner:Settings().section`. That is a session-only copy while `dbIsNewer`, which a spec checks. An unknown stored value falls back to Knowledge.
- **Knowledge.** An ExpandGrid over `PlannerView.KNOWLEDGE_COLUMNS` and `KnowledgeCells`. A done category gets the ReadyCheck-Ready icon after its count. The row tooltip is `KnowledgeTooltipLines`. The detail comes from `Tab.KnowledgeDetailLines`: per source, the category, the item name (`C_Item.GetItemNameByID`, or `item:<id>` while uncached), `earned/total KP`, the state word and the hint, then the pending first crafts. An unknown state shows `?/total`, never 0.
  - The status line reads "Knowledge left: N KP", taken from `KnowledgeLines`.
  - The footer reads "Knowledge data: build <Planner:GameDataBuild()> · Weekly reset in <FormatDuration>". It says "not generated" in place of the build when GameData status `missing` is set, and the hover tooltip adds `FS:GameDataStatusText()` (preflight row 38).
  - While the data build is outdated, an "Old data" marker sits in its own fixed 70 px region at the start of the footer. This is the Task 13 marker rule, and it applies on Knowledge only.
- **Concentration.** Cap warnings come first as `Tab.WarningRow`: red "Capped: concentration is full", orange "Soon: full in <duration>". Schedule rows follow as `Tab.ScheduleRow`. The narrow cells use compact gain and gold per point; the full `FormatMoney` values are in the tooltip. "Caps in" shows `>14d` when there is no `fullAt`.
  - Each schedule row has a "Queue" button. A click calls `Queue:Add({ recipeID, quantity = crafts, charKey, useConcentration = true })`, and nothing is ever queued without a click.
  - The status line leads with its key word: "Queued: N × <recipe> for <charKey> (with concentration)", "Not queued: the saved data is from a newer version (read-only)", "Not queued: the Queue did not accept …" or "Not queued: the Queue is turned off". Otherwise it reads "Plan: N crafts · Capped: X · Soon: Y".
- **Spec advice and Missing recipes.** Two cycle buttons pick the character and the profession; this is the project's existing filter pattern, see deviation 2. The characters are the visible `Alts:GetOverview()` rows with a listed profession. One session-local pick is shared by both sections, and the buttons are hidden on the other two sections.
  - Spec advice goes through `PlannerView.SpecAdvice`. Unknown gains show "?". If no gain is known at all, the tab shows "Spec effect data not in this GameData build (<build>)". The footer shows "Estimate from your top N profitable recipes".
  - Missing recipes uses `PlannerView.SourceText` with the recipe item's name.
- **Lazy spec advice (Task 11 carry, preflight row 30).** `GetSpecAdvice` is called only from `refresh`, only while the Spec advice section is shown, and only for the picked pair. The message handlers only schedule the 0.5 s Debounce, wrapped through `Wrap`. Specs check that a message triggers no synchronous call and that other sections make no call.
- **Statuses.** Every getter status other than `"ok"` shows `PlannerView.StatusText`; `"ok"` without rows shows `EmptyText`. While the Planner module is off, the tab shows "Planner is turned off: turn it on in Settings > Modules to see the plan" instead of a section. While Alts is off, every section shows "Alts is turned off".
- **Refresh.**
  - `FS_ALTS_CHANGED` and `FS_RECIPES_CHANGED` trigger a 0.5 s Debounce (log-only source `"PlannerTab:Refresh"`), then `MainWindow:RefreshTab("planner")`.
  - A 60 s tick runs while the tab is refreshed and is cancelled on OnHide.
  - Uncached item names are requested once per session through `C_Item.RequestLoadItemDataByID` (feature-tested). The tab listens for `GET_ITEM_INFO_RECEIVED` only while one of those names is shown, and only reacts to those item IDs. It stops listening on hide.
  - `OnDisable` unregisters everything and cancels both debounces. Handlers log under `"Tab:planner"`.

### Task 13 minors folded in
- `CharactersView.MARKER_LABEL = "Old data"`, `DataMarker(status)` and `CurrentDataMarker()` hold the one marker wording, with the tooltip `{ "Game data build X is outdated", why }`. Both the Characters tab and the Planner tab use it, so "Outdated: … (outdated)" no longer repeats.
- In `Characters.lua`, the Alts-off branch now clears `notice`, so the last Hide/Show feedback no longer reappears when Alts comes back.

### Other files
- `FabricationStation.toc`: `UI\Tabs\Planner.lua` goes after `UI\Tabs\Characters.lua`.
- `tests/tooling/toc_spec.lua`: new order pairs PlannerView<Planner, Characters<Planner and Planner<Settings.
- `tests/ui/settings_spec.lua`: tab count 8 → 9 (preflight row 18).
- `tests/integration/load_all_spec.lua`: `PlannerTab` added to the module list.
- `tests/ui/characters_tab_spec.lua`: the full-load tab list now includes `planner`, plus the new marker wording and the cleared notice.
- `tests/helpers/phase3_fakes.lua`: an additive `opts.queue` that creates a fake Queue module.
- `tests/ui/views_spec.lua`: a `DataMarker` spec.
- Interface contract: a new `[phase 3 Task 14]` Planner tab entry, the CharactersView marker helpers, and the Characters marker wording plus the notice clearing.
- `ingame-checklist.md`: six T14 lines.

## Tests

- New `tests/ui/planner_tab_spec.lua` has 32 specs. They cover:
  - registration and the full load (9 tabs, slash `tab planner`, no diagnostics errors)
  - sections: highlight, remembered setting, the fallback for an unknown value, read-only
  - Knowledge: cells and check icon, tooltip, detail lines (item, hint, unknown, noData, uncached), item-name loading and listening, footer (build / not generated / no reset API), the Old data marker placement and tooltip at 516 px, the empty state
  - Concentration: warning colours and order, cells, Queue click and entry fields, every not-queued reason, feedback cleared on section change, empty states (Recipes off, Alts off)
  - Spec advice: lazy computation, debounced recompute, pickers and their tooltip, noSpec, the all-unknown note
  - Missing recipes: rows and sources, notScanned, the empty "knows every listed recipe" state, no pickers
  - lifecycle: debounced refresh, tick, cancel on disable, Planner off, Alts off, error source
  - layout at 516 px: anchors and widths of the section buttons, pickers, status line, grid and footer; flexible widths Knowledge 156, schedule 162 (Gold/conc, Profession and Caps in hidden), Path 170, Source 320; the schedule anchored from both edges; the Queue button anchored to its cell; hidden values kept in the tooltip
- Full suite: **2206 successes / 0 failures / 0 errors**. The baseline at 6dde7ef was 2173. `luacheck .`: **0 warnings / 0 errors in 155 files**.

## TDD evidence

- RED: `busted tests/ui/planner_tab_spec.lua` gave `0 successes / 1 failure / 30 errors`. The errors were "cannot open UI/Tabs/Planner.lua"; the failure was the full-load tab list missing `planner`.
- Characters minors, RED against the old code (`git stash` of Characters.lua/CharactersView.lua): `busted tests/ui/characters_tab_spec.lua` gave `28 successes / 3 failures`. The failures were line 450 (notice still shown after Alts came back), line 514 ("Outdated" label) and line 561 (no planner tab).
- GREEN after the implementation: `busted tests/ui/planner_tab_spec.lua` gave `30 successes / 1 failure` (only the TOC/full load was left), and after the TOC change the full suite gave `2205 successes / 0 failures`.
- Item-name loading, a refinement found in self-review: the new spec went RED with `31 successes / 1 failure` (`planner_tab_spec.lua:238`, the name was never requested), then GREEN with `32 successes / 0 failures`.
- Final: `busted` gave `2206 successes / 0 failures / 0 errors`, and `luacheck .` gave 0 warnings.
- One small out-of-order step: I wrote `CharactersView.DataMarker` just before its views_spec, though the Characters spec exercising it was RED first.

## Deviations from the plan text (brief, preflight and code win)

1. **Refresh ownership**: the `PlannerTab` registrar listens and calls `RefreshTab`, not the Planner module (preflight row 17 and the contract: "Planner listens to no message").
2. **"Dropdowns" are cycle buttons**, like the Recipes tab's character and profession filters. The test stubs have no dropdown API, and phase 1b's UI pattern is cycle buttons. Each click steps to the next option, and the tooltip names the full charKey and the option count.
3. **Narrow money cells**: Gain, Gold/conc and spec Gain/Per point use `ViewUtil.compactMoney` in the cell and full `FormatMoney` in the tooltip. This follows the phase-2 binding rule; the plan says `FormatMoney(expectedGain)`.
4. **Footer "not generated"**: this follows the plan's rule, `status.missing`. With the shipped data (the 1a generated tables are empty, so `missing = true`), the footer says "Knowledge data: not generated" even though the Knowledge anchor rows are stamped 70575 and the grid shows counts. This matches what Settings shows ("GameData not generated"), and the tooltip carries `GameDataStatusText()`. If you would rather the footer read the Knowledge table's own state, that is a one-line change in `Tab.KnowledgeFooter`.
5. The schedule has no "Profession" column at 516 px: it hides after Gold/conc so that the Recipe column keeps 162 px. Its value stays in the row tooltip.

## Self-review findings (fixed before the commit)

- Uncached item names would never have loaded, because nothing requested them. I added a once-per-session request plus a filtered `GET_ITEM_INFO_RECEIVED` listener that runs only while a name is pending, with a spec.
- Removed an unused `EM_DASH` local (lint) and rewrapped one Characters comment line that was over 120 characters.

## Concerns

- Nothing in game is verified (see the T14 checklist lines). The main visual unknowns are:
  - whether `LockHighlight` on UIPanelButtonTemplate reads clearly as the selected section
  - whether the 52 px Queue button and the 12 px icon render cleanly in the narrow cells
  - whether the "Old data" marker region fits in GameFontNormalSmall (70 px for 8 characters)
- The empty text under the concentration warnings is placed at a fixed offset of (rows × row height) below the grid header. That is fine for a handful of warnings, but if there are more warnings than fit in view, the message ends up below the visible area.
- Spec advice is recomputed on each refresh of the Spec section, including the 60 s tick. PlannerSpec memoises it by its inputs, so an unchanged state costs one memo lookup. Changed inputs (prices, data stamp) cost one full computation, and only for the picked pair.

---

# Fix round 1

Commit: aa2226f fix: read the Knowledge table's own build for the Planner footer and data marker (on top of 01d2ade).

## Changes, by review item

1. **(Important) The knowledge build comes from the Knowledge table itself.**
   - `Data/GameData.lua` has a new `GameData.TableBuild(name)`, returning the build a table was defined with, or nil. There is a new spec in `tests/gamedata/gamedata_spec.lua`.
   - `UI/Tabs/ViewUtil.lua` adds `U.knowledgeBuild()`, which returns `TableBuild("Knowledge")` only while `Get("Knowledge") ~= nil`. It also adds `U.clientBuild()`, the second return of `FS:GameDataStatus()`.
   - `Tab.KnowledgeFooter` now shows "Knowledge data: build <kb>" or "not generated". It no longer reads `status.missing`, `Planner:GameDataBuild()` or `GameDataStatusText()`. The tooltip's second line is knowledge-only: "Knowledge sources come from GameData build <kb>[ (this is game build <client>)]", or "No knowledge data in this GameData: knowledge counts show as ?".
   - `CharactersView.DataBuildNote(knowledgeBuild, clientBuild)` and `DataMarker(knowledgeBuild, clientBuild)` replace the `GameData.Status` signature. `CurrentDataNote()` and `CurrentDataMarker()` read `U.knowledgeBuild()` and `U.clientBuild()`.
     - I moved the **note** (header text, row tooltip, `KnowledgeLines` "(outdated)") onto the same rule as the marker. Without that, the header tooltip could say "data build X (outdated)" while no marker shows. Flag this if you only wanted the marker changed.
     - `Characters.lua` now calls `set_marker(V().CurrentDataMarker())`, the same rule as `header.note`.
     - The marker tooltip's second line now names both builds: "Knowledge sources and counts come from game build X; this is game build Y, so they may be wrong."
   - New `Tab.MissingFooter()`: while `TableBuild("RecipeSources")` is nil it reads "Recipe sources: not generated · Recipe lists fill in when you open the profession on any character". Its tooltip says: "Without generated recipe sources, only recipes a character has seen in the profession window are listed, and a source the game did not describe shows as Unknown". A stamped table gives the plain text, and the tooltip names the build.
   - Specs:
     - The old footer spec at :270-272 is rewritten. With status `missing` true and Knowledge at 70575, the footer shows "build 70575". The test asserts that `missing` is really true.
     - Added the "not generated" cases: a Knowledge table without a build, and also on client 70700, where no marker shows.
     - Added a marker case: six tables at 70500 plus an ungenerated RecipeSources make the GameData status outdated and missing, yet no marker shows. The views_spec has the same cases.
     - The existing marker spec now asserts the full tooltip and the footer's "(this is game build 70700)".
     - Added the Missing recipes footer for both an unstamped and a stamped RecipeSources.
   - Contract: the `TableBuild` line in the GameData section, the CharactersView note/marker signatures and rule, and the Planner tab footer, the missing footer and the tick.
2. **The tick runs only on Knowledge and Concentration.** Other sections cancel `plannerTab.tick`, and so does the Planner-off state. New spec: on Spec advice and Missing recipes, advancing 120 s triggers no refresh; on Concentration, a refresh comes at 60 s.
3. **The unregistration spec now checks the registration.** It uses `PlannerTab:IsEventRegistered("GET_ITEM_INFO_RECEIVED")`: registered while a name is pending, not registered once it has resolved, registered again when a name is pending, and not registered after OnHide.
4. **`KnowledgeDetailLines(row, names)` is pure.** The section builder resolves the item names and requests the uncached ones. New spec: with `C_Item.GetItemNameByID` and `RequestLoadItemDataByID` both raising errors, the model still returns "item:263455".
5. **New table-driven spec.** It renders noRecipes, noProfession and hidden for Spec advice, and noProfession, noData and hidden for Missing recipes, each through the tab. Each case checks the message, that it is shown, and that there are no rows. The getters are stubbed, because the overview pickers cannot reach some of these statuses with real data.
6. **Removed the unused `pickers = true` fields** from `Tab.SECTIONS`.
7. **A message under rows stays visible when the list overflows.** When there are rows and a message, the message takes its own 20 px line just above the footer: BOTTOMLEFT/BOTTOMRIGHT at 10 px and −10 px, 24 px up. The grid then ends 42 px above the bottom. Without rows, the message stays under the grid header (−82) and the grid ends at 22. The specs assert both anchor sets.

## Tests

- RED:
  - `busted tests/gamedata/gamedata_spec.lua` gave `12 successes / 0 failures / 1 error` (`TableBuild` is a nil value).
  - `busted tests/ui/views_spec.lua` gave `30 successes / 3 failures` (lines 194, 203, 219).
  - `busted tests/ui/planner_tab_spec.lua` gave `30 successes / 8 failures` (lines 235, 273, 289, 305, 321, 407, 523, 603). The new status-table spec and the registration spec passed on the old code, because that behaviour was already right; the review had flagged the proof, not the behaviour.
- GREEN:
  - gamedata 13/0.
  - views and characters 64/0, after updating one Characters assertion for the new tooltip line.
  - planner_tab 38/0.
- Full run: `busted` gave **2214 successes / 0 failures / 0 errors**, and `luacheck .` gave **0 warnings / 0 errors in 155 files**.
- I updated the T14 footer line in ingame-checklist.md for the new behaviour.

## Remaining concerns

- Nothing has been checked in game; see the T14 checklist lines.
- `DataBuildNote` changed signature (Status → builds). I updated every caller (CharactersView, PlannerView via `CurrentDataNote`, Characters) and the contract.
