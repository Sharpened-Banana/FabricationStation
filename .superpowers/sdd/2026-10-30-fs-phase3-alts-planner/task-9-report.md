# Task 9 report: Planner knowledge checklist and missing recipes

Status: DONE_WITH_CONCERNS (only the in-game checks, which cannot run here; added to ingame-checklist.md as T9)
Commit: f729c8c feat: add Planner knowledge checklist and missing recipe finder (BASE 412f87f)

## What was built

`Modules/Planner.lua` creates `NewModule("Planner", "AceEvent-3.0")`. It is an ordinary, toggleable module (not core).
- `Planner:Settings()` reads `settings.planner` through `ns.Util.SettingsAccessor("planner")(DEFAULTS, fill)` (preflight row 12).
  - Defaults: `{ capWarnHours = 24, capWarnChat = true, maxCraftsPerRecipe = 10, specTopRecipes = 20 }`.
  - `fill` repairs the boolean, then rounds and clamps the numbers to `SETTINGS_RANGES`: capWarnHours 1..168, maxCraftsPerRecipe 0..100 (0 means no cap, as in PlanCalc.Schedule), specTopRecipes 1..50.
  - It keeps `section` (for Task 14) only when it is a non-empty string.
  - While `dbIsNewer` is set, it returns a session-only copy.
- Options group `planner` uses order 60 and the name "Planner" (preflight row 32). It has a toggle and three sliders. All four are disabled while `dbIsNewer` is set and write through `Settings()`, and none of them sends a message ("announces nothing new").
- `Planner:GetKnowledgeChecklist(now)` builds one row per `Alts:GetOverview()` row (visible characters only) and per listed `AltProfession`. That listing already drops dropped records and older-expansion lines (preflight rows 9 and 10).
  - Each row carries `name` (the AltProfession name), `summary = Alts:GetKnowledgeSummary(charKey, sl, now)` and `states = Alts:GetKnowledgeState(charKey, sl, now)`.
  - Rows sort by `weeklyLeft` descending, but **only when the status is "ok"**. "noData" and "unknown" rows come after all "ok" rows and are never ranked by their number (Task 2 carry). The tie-breaks are charKey, then skillLineID.
  - It returns `{}` while Alts is missing or turned off.
- `Planner:GetMissingRecipes(charKey, sl)` returns (catalog keys ∪ RecipeSources keys, numbers only) minus the character's own `Scanner:GetProfession(charKey, sl).recipes`.
  - `kind` comes from RecipeSources when it is auto, item or unknown; anything else becomes "unknown". `itemID` is set only for kind "item" with a number. `text` is the catalog's non-empty `sourceText`.
  - `name` is the catalog name if there is one, else `C_Spell.GetSpellName` (feature-tested, pcall'd, `canaccessvalue`-guarded), else `"Recipe <id>"`.
  - Results sort by name, ignoring case, then by recipeID.
  - It returns `{}` for a hidden or unknown character, for a line with no record or only a dropped record, and while Alts is off.
  - A nil, empty or damaged RecipeSources table counts as no keys. The checked-in `--empty` table works.
- `Planner:GameDataBuild()` returns `ns.GameData.Build()`.

Other changes:
- TOC: `Modules\Planner.lua` goes after `Modules\AltsCollector.lua`. PlannerSpec is left for Task 11 (preflight row 2).
- `load_all_spec`: "Planner" is added to the module list and "planner" to the option groups (preflight row 14).
- The interface contract is updated: the TOC list, option group orders, the SavedVariables `settings.planner` line, and a new Planner (Task 9) section under the Alts sections.

## Deviations from the plan / brief (with reason)

- **No cache, so no message listeners.** The plan says to listen to ALTS_CHANGED and RECIPES_CHANGED "to clear cached results". The orchestrator note says "If Planner caches anything". I cache nothing, so every call reads current data and nothing can go stale (for example, a spell name that loads late). The cost per call is small: one overview build, or one pass over a line's catalog. Preflight row 17 has the Planner tab registrar listen to these messages itself. So OnEnable and OnDisable register nothing in this task. Task 10 adds its debounce and cancel.
- **Alts off gives `{}`.** The plan does not say what happens when Alts is disabled. Planner's reads go through Alts, and the views show "Alts is turned off" (as the Characters tab and the holdings provider do). This is recorded in the contract.
- **Missing recipes need the character's own record for the line.** Without a record, or with only a dropped one, the result is `{}`. Otherwise every catalog recipe would show as "missing" for a profession the character doesn't have. Hidden characters give `{}`, per the orchestrator note "Hidden characters excluded".
- **Range values for the sliders are my choice**, because the plan gives none. They are in the contract.

## Tests

`tests/planner/knowledge_spec.lua` has 32 specs:
- the brief's three tests, word for word
- names, summary and states equal what Alts returns
- older lines, dropped records, hidden characters and characters without professions are excluded
- the `now` argument is used (after the next reset the weekly flags no longer count), and the default is server time
- full sort order, including ties
- noData rows (a variant with no sources) and unknown-status rows sort last
- with Knowledge nil, the rows are noData
- Alts turned off
- missing recipes:
  - recipeIDs, and a catalog-only source
  - RecipeSources nil, empty or damaged
  - a known catalog recipe is excluded
  - the name fallback chain
  - unreadable or failing spell names, and C_Spell missing
  - damaged catalog and source entries, and unknown kinds
  - case-insensitive sort
  - character without the profession, dropped, hidden or unknown
  - a record without `recipes`
  - read-only (db unchanged)
  - Alts turned off
- GameDataBuild
- settings: lazy defaults, repair, the dbIsNewer session copy
- options group: order and name, and Planner listed in Settings > Modules; the setters send no message; with dbIsNewer every setter is disabled and leaves db.global untouched
- module disable/enable is clean

### TDD evidence
RED: `busted tests/planner/knowledge_spec.lua` gave `0 successes / 0 failures / 32 errors / 0 pending` with "failed to load Modules/Planner.lua: cannot open Modules/Planner.lua".

The first GREEN run gave 31/1. A non-string `kind` kept `itemID = 7`. I tightened the code so `itemID` is kept only for kind "item" and unknown kinds become "unknown", and added specs for both.

GREEN: `busted tests/planner` gave `32 successes / 0 failures / 0 errors / 0 pending`.

Full: `busted` gave `2005 successes / 0 failures / 0 errors / 0 pending`. `luacheck .` gave `0 warnings / 0 errors in 141 files`.

## Files changed
- Modules/Planner.lua (new)
- tests/planner/knowledge_spec.lua (new)
- FabricationStation.toc
- tests/integration/load_all_spec.lua
- docs/superpowers/plans/2026-10-30-fs-interface-contract.md
- (ignored by git) ingame-checklist.md: two T9 lines appended

## Self-review
- No WoW API calls at load or enable. C_Spell is feature-tested and pcall'd, and `canaccessvalue` is guarded.
- The only writer is Settings, through SettingsAccessor, and there is a dbIsNewer spec for it and for the options setters.
- No private Alts tables are read; it uses public Alts methods only (GetOverview, GetKnowledgeSummary, GetKnowledgeState, GetRecipeCatalog, Settings().hidden). The hidden set is read through `Alts:Settings()`, which is public, as the contract documents.
- Modules are looked up at call time with `GetModule(name, true)`.
- Lines are at most 120 characters, and lint is clean.

## Concerns
- In-game behaviour can't be verified here (no client). Two T9 lines were appended to ingame-checklist.md.
- The checklist calls `Alts:GetOverview()`, which also projects concentration for every profession, and then rebuilds the knowledge context for each row. This is fine for a handful of characters. If the Planner tab ever refreshes very often, an `Alts` method that returns only the listed lines would be cheaper.

---

## Fix round 1

Commit: be2d101 fix: report Planner getter status (off, hidden, noProfession, noData, ok)

### Changes
1. `GetMissingRecipes(charKey, sl)` now returns `rows, status`. The first return value is unchanged, so the brief's tests still pass as written. The status is decided in this order:
   - `"off"`: Alts is missing or turned off.
   - `"hidden"`: the character is hidden. This is checked before the record lookup, so it also covers a hidden character with no record or no saved data.
   - `"noProfession"`: there is no record, or only a dropped one. This includes an unknown character and a nil charKey.
   - `"noData"`: neither the catalog nor RecipeSources has a number key for the line, or the record was never recipe-scanned.
   - `"ok"`: the rows; they may be `{}`, meaning nothing is missing.

   Every status other than "ok" returns `{}`.

   **Signal for "never recipe-scanned":** `ProfessionRecord.time`. In 1a, `Modules/Scanner.lua:584` is the only writer of a profession record's `time`, inside `ScanProfession`, which is the recipe scan. A record created only by `ScanSpec` (via `profession_record`, Scanner.lua:620) has no `time`. So a record whose `time` is not a number counts as "noData". I did not use the fallback of an empty `recipes` table plus a catalog with keys.

   **Fixture change** (additive, in `tests/helpers/phase3_fakes.lua`): Aria's 2907 record gets `time = NOW - 60`, as a real scanned record would have. Bren's 2912 stays without `time`, i.e. never scanned. The full suite is unaffected, and the contract's fixture note is updated.
2. `GetKnowledgeChecklist(now)` now returns `rows, status`, with status `"ok"` (rows may be `{}`) or `"off"` with `{}`.
3. Contract: a new line says the getters ignore Planner's own enabled state, so the tab must check `Planner:IsEnabled()`, and that `"off"` refers to Alts. The code comments say the same, and a spec checks that both getters answer "ok" while Planner is disabled.
4. The read-only spec now compares the whole `db.global`. Before taking its snapshot it creates the Alts and Planner settings tables, the only lazy writes. The title is now "reads only: db.global is unchanged once the lazily created settings exist". It also covers the `noData` path (Bren).

The contract's Planner section is updated with both return signatures and the status order.

### Tests added or changed
- Checklist:
  - "ok" with rows, and "ok" with `{}` when every character is hidden.
  - The "off" spec, now asserting the status.
  - Planner disabled: both getters still answer "ok".
- Missing recipes:
  - The brief's first test now also checks `select(2, ...) == "ok"`.
  - The brief's "without any data" test now also checks `select(2, ...) == "noData"`.
  - A `status` describe block covering:
    - "ok" with `{}` when everything is known
    - "ok" when only one source lists the line
    - "off"
    - "hidden", including no record and no saved character
    - "noProfession": no record, unknown, nil, dropped
    - "noData": no keys, only non-number keys, or an empty RecipeSources line
    - "noData" for a never-scanned record (`time` nil or non-number), and back to "ok" once `time` is set
- The old "is empty for a character without that profession…" spec is kept unchanged.

### Commands and output
- RED (new specs against the round-0 module, using `git stash push Modules/Planner.lua`): `busted tests/planner` gave `29 successes / 12 failures / 0 errors / 0 pending`.
- GREEN: `busted tests/planner` gave `41 successes / 0 failures / 0 errors / 0 pending`. The first run had one failure, a wrong expectation in my new spec (RecipeSources also lists 103, so "Recipe 103" appears). I fixed the spec, not the code.
- Full: `busted` gave `2014 successes / 0 failures / 0 errors / 0 pending`. `luacheck .` gave `0 warnings / 0 errors in 141 files`.
