# Task 6 report: Alts collector

Status: DONE_WITH_CONCERNS. The code is complete and tested. The in-game checks cannot be run here (preflight row 8), so they are in ingame-checklist.md.
Commit: `01d2921` feat: collect spec points, knowledge flags and recipe catalog per character (base 2c05af3).

## What I built

### `Modules/Alts.lua`
- The module `Alts`, created with `ns.FS:NewModule("Alts", "AceEvent-3.0")`. It is an ordinary module, so users can toggle it.
- `Alts:Settings()` reads through `ns.Util.SettingsAccessor("alts")` and uses Alts' own `fill` (preflight row 12):
  - Defaults are `{ tooltipHoldings = true, tooltipMaxChars = 8, staleDays = 7, hidden = {} }`.
  - A non-boolean toggle or a non-finite number gets its default.
  - Numbers are rounded and clamped to `Alts.SETTINGS_RANGES` (`tooltipMaxChars` 1..20, `staleDays` 1..60).
  - A `hidden` that is not a table becomes a fresh `{}`.
- `Alts.BuildOptions()` is registered at file load as option group `"alts"` (order 50, name "Characters"; preflight row 32).
  - It has one toggle and two ranges.
  - Every option is disabled while `dbIsNewer` is set.
  - Setters write through `Settings()` and send `FS_ALTS_CHANGED(CharKey())`.

### `Modules/AltsCollector.lua` (same module object)
- **`GetSpecSnapshot(charKey, sl)`** derives the snapshot from 1a's raw Scanner `spec` record, as the plan describes. Perks without a numeric `unlockRank` are skipped. The method only reads.
- **`CollectPathNames(sl)`** follows the plan's lookup chain and feature-tests `C_Spell`.
  - It returns nil, and keeps the stored names, in four cases: no spec record, config id nil or 0, no path resolves, or no character record.
  - It stores names only when they changed, and only then sends a message.
- **`CollectKnowledgeFlags()`** checks the quests of Knowledge sources whose skill line is one of the character's **non-dropped** profession records (preflight row 10).
  - Duplicate quest IDs are asked once.
  - `C_QuestLog` is feature-tested.
  - Nothing is written without Knowledge data, the API or a character record.
- **`CollectOpenProfession()`** runs only while `Scanner:IsProfessionOpen()` is true.
  - It feature-tests `GetAllRecipeIDs` and `GetRecipeSourceText` with `type(fn) == "function"` (preflight row 8) and files recipes with 1a's rule.
  - Only planned lines are handled: `Knowledge.variants`, or the open child line when there is no Knowledge data (preflight row 35).
  - Source text is capped at 200 characters ("..." at the end).
  - A learned recipe is removed from the catalog.
  - `planning[line] = { pathNames, firstCraftsPending, time }` is written for each planned line it sees.
  - It sends one message.
- **`GetRecipeCatalog(sl)`** returns the stored table, or `{}`.
- **`DebugKnowledge()`** prints with the "FabricationStation: " prefix.
- Every writer has a `writable()` guard (preflight row 13).
- **Events.** OnEnable only registers handlers (preflight row 14), and every handler is wrapped with `ns.FS:Wrap("Alts")`.

  | Trigger | Debounce | Action |
  |---|---|---|
  | `PLAYER_ENTERING_WORLD` | 2 s | flags, plus path names of every planned profession |
  | `QUEST_TURNED_IN`, `QUEST_LOG_UPDATE`, `CURRENCY_DISPLAY_UPDATE` | 2 s | flags |
  | `TRADE_SKILL_SHOW`, `TRADE_SKILL_LIST_UPDATE`, `NEW_RECIPE_LEARNED` | 1 s | open profession |
  | `FS_DATA_CHANGED` (any) | 0.5 s | relay as `FS_ALTS_CHANGED(charKey)` |
  | `FS_DATA_CHANGED`, logged-in character, `"recipes"`/`"spec"` | 0.5 s | path names (preflight row 34) |
  | `FS_DATA_CHANGED`, logged-in character, `"recipes"`/`"professions"` | 2 s | flags |

  OnDisable cancels all five debounce keys and unregisters.

### Test harness and wiring
- **`tests/helpers/phase3_fakes.lua`** returns `{ phase3_env, NOW, WS, default_wow, knowledge, characters }` (preflight row 16).
  - It is built on `P2.boot`, `P2.fake_module` and `P2.load` (required as `"tests.helpers.phase2"`) and does not patch GetModule.
  - Fakes are provided for Scanner (1a semantics and the step `ProjectConcentration`, preflight row 11), Recipes (`GetRanked` filters through `opts.recipeLines` or the schematic, preflight row 24), Tooltips, Dashboard (also `SetLines`) and MainWindow.
  - It includes the fixture Knowledge and characters from the brief. `opts.knowledge = false` leaves Knowledge undefined.
- **`tests/helpers/init.lua`** sets the globals `phase3_env`, `NOW` and `WS`.
- **`tests/helpers/wow_stubs.lua`** gets new defaults, with a spec in `wow_stubs_spec`: `C_QuestLog.IsQuestFlaggedCompleted` gives false, `C_Spell.GetSpellName` gives nil, `C_DateAndTime.GetCurrentCalendarTime` gives nil, and `GetCurrentRegion` gives 1. `canaccessvalue` stays absent.
- **`.luacheckrc`** adds `C_QuestLog`, `C_Spell`, `GetCurrentRegion` and `canaccessvalue`. `C_DateAndTime` was already there (preflight row 15).
- **`FabricationStation.toc`** lists `Modules\Alts.lua` and `Modules\AltsCollector.lua` after `Modules\PlanCalc.lua` (preflight rows 1 and 3).
- **`tests/integration/load_all_spec.lua`** adds `"Alts"` to the module list and `"alts"` to the option groups.
- **The interface contract** now covers:
  - the TOC line and the `alts` option group at order 50;
  - when `FS_ALTS_CHANGED` is sent;
  - the full Alts Task 6 API;
  - the DB keys `settings.alts`, `recipeCatalog`, `knowledgeWeekly` and `planning`;
  - `phase3_env` and the new stub defaults.

## Tests
`tests/alts/collector_spec.lua` has 43 specs, all of them new:
- every test from the plan, with the 2822 assertion changed (see the deviations below);
- dbIsNewer specs for each writer and for the options setters;
- dropped records;
- no Knowledge data;
- the fallbacks for the feature-tested functions;
- the source-text cap and learned-recipe removal;
- a lazily created `recipeCatalog`;
- every event path and debounce;
- a failing handler disabling Alts;
- disabling cancelling the pending work;
- DebugKnowledge output;
- settings fill and repair;
- the options group.

`wow_stubs_spec` has one new spec.

TDD evidence:
- RED: `busted tests/alts/collector_spec.lua` gave `0 successes / 0 failures / 43 errors`, with "failed to load Modules/Alts.lua: cannot open Modules/Alts.lua".
- GREEN: `busted tests/alts/collector_spec.lua` gave `43 successes / 0 failures / 0 errors / 0 pending`.
- Mutation check: I removed the `writable()` guard from CollectOpenProfession and made CollectKnowledgeFlags always send a message. That gave 2 failures (lines 165 and 264), and I then restored the code.
- Full suite: `busted` gave `1869 successes / 0 failures / 0 errors / 0 pending` (1825 + 44).
- Lint: `luacheck .` gave `0 warnings / 0 errors in 136 files`.

## Preflight rows applied
- 1 and 3: TOC placement.
- 8: feature tests and the checklist.
- 10: dropped records are skipped in CollectKnowledgeFlags.
- 11: the fake Scanner uses the step projection.
- 12: SettingsAccessor with a fill.
- 13: `writable()` guards and dbIsNewer specs.
- 14: stub defaults, no API calls in OnEnable, the load_all lists.
- 15: only the missing luacheck globals were added.
- 16: the phase3_fakes design.
- 24: the fake GetRanked filter.
- 32: option group order 50, plus the dbIsNewer setter spec.
- 34: path names are re-collected on "recipes"/"spec".
- 35: catalog only planned lines, and cap the source text.

## Deviations from the brief and plan (and why)
1. **Planned lines only (preflight row 35).** The plan's test asserted that `recipeCatalog[2822][104]` exists. 2822 is not a Knowledge variant, so the test now asserts that 2822 is neither cataloged nor planned. A separate test covers the no-Knowledge case, where the open child line 2822 is cataloged. I applied the same planned-lines filter to `planning` writes, so old expansions get no planning records.
2. **Messages only on change.** CollectKnowledgeFlags sends `FS_ALTS_CHANGED` only when the quest set changed or there was no snapshot before. The snapshot `time` is always refreshed. CollectPathNames also sends only on a change.
   - Why: QUEST_LOG_UPDATE and CURRENCY_DISPLAY_UPDATE are frequent, and the reset logic gives the same states whether or not the time is refreshed.
   - The plan's "sends FS_ALTS_CHANGED after collecting" test still passes, because Aria's flags change in it.
3. **Login is debounced.** PLAYER_ENTERING_WORLD is debounced by 2 s (key `alts.login`) instead of running inline.
4. **Unlearned recipes leave the catalog.** A recipe that has become learned is removed from the catalog. The plan did not say this, but it keeps the catalog accurate.
5. **Plan file list.** The plan listed `.luacheckrc` changes for `C_DateAndTime`, which was already present. It also did not list wow_stubs, wow_stubs_spec or load_all_spec, which preflight row 14 requires.

## Self-review findings
- **Path names.** CollectPathNames needs the logged-in character's Scanner spec record, because it walks the paths of that record. The first spec snapshot comes from Scanner's "recipes" scan, which is handled.
- **`firstCraftsPending`** counts only what the recipe list returns. With the `GetFilteredRecipeIDs` fallback, active filters could undercount. 1a's Scanner has the same limit, and this is on the checklist.
- **The relay** keeps only the last `charKey` within its 0.5 s window. In practice Scanner only ever sends the current character.

## Concerns
- **Nothing is verified in game.** The 7 T6 lines are appended to `ingame-checklist.md`:
  - DebugKnowledge flags;
  - `spent` against `GetTreeCurrencyInfo`;
  - display rank and perk rank scale;
  - path names against the UI;
  - `GetAllRecipeIDs`;
  - the config id at login;
  - the first-craft count and catalog text.
- **No message on enable/disable.** Alts sends no `FS_ALTS_CHANGED` when it is turned on or off. If the Task 13/15 tabs and widgets show "Alts is turned off", they will need to be told about the toggle themselves, or Alts will need to send a message then. The same lesson came up in phase 2 Task 0.

---

# Fix round 1 (review: Needs fixes)
Commit: `ab81837` fix: keep learned recipes in the account-wide catalog and announce Alts state

## Changes
1. **(Important) The catalog keeps learned recipes.** `CollectOpenProfession` now catalogs every recipe of a planned line, learned or not. It never removes an entry, and the planned-lines filter still applies.
   - Spec: the main test asserts that 101 and 102 (learned by Aria) are catalogued.
   - Spec: "keeps a recipe another character catalogued once this character has learned it" replaces the old removal test.
2. **Flag writes always announce.** `CollectKnowledgeFlags` sends `FS_ALTS_CHANGED` after every write.
   - Spec: "announces every write, also one that only refreshes the snapshot time".
3. **Enable and disable announce.** OnEnable schedules a 0 s debounce (`alts.enabled`), wrapped as "Alts", which sends `FS_ALTS_CHANGED(CharKey())`, so OnEnable itself calls no game API. OnDisable cancels that key along with the others and sends `FS_ALTS_CHANGED(CharKey())`.
   - Spec: the announce is sent on the first advance, not at enable; a second one is sent on disable; a third after re-enable plus an advance.
   - Spec: a disable before the first run cancels the pending enable announce.
4. **CollectOpenProfession announces only real changes.**
   - A catalog entry is rewritten, with a new `time`, only when it is new or its `name` or `sourceText` changed.
   - The message is sent only when a catalog entry was added or changed, **or** a planned line's `firstCraftsPending` or path names changed.
   - That last condition goes beyond the review text. Without it, a changed first-craft count would go unannounced and Task 7's knowledge summary would not redraw.
   - `planning[line].time` is still refreshed on every run.
   - Specs cover: unchanged entries keeping their time with no message, a changed sourceText re-stamped and announced, a changed first-craft count announced, and a nil/nil path-name comparison counting as unchanged (I mutation-checked this one).
5. **The UTF-8 cap backs off to a character boundary.** The cut moves back while the byte after it is a continuation byte (0x80-0xBF).
   - Spec cases: a 2-byte char across the cut gives 196 bytes plus "...", a 3-byte char across the cut gives 195 bytes plus "...", and a 2-byte char ending exactly at byte 197 is kept whole.
6. **The disable spec covers the paths debounce.** It now uses PATH_API (config id 55) with `alts.paths` and `alts.relay` pending, and asserts the path names are unchanged after disable. It also asserts the only message is the disable announcement.
7. **`hidden` is cleaned.** The `fill` keeps only `[charKey] = true` entries; the repair spec has false, "yes" and a numeric key.
8. **Contract.**
   - `FS_ALTS_CHANGED` triggers: every flags write, change-only collections, enable/disable, and the relay keeping only the last `charKey` of its 0.5 s window.
   - The catalog is "every listed recipe, learned or not".
   - Entries are re-stamped only on change, and the UTF-8-safe cap.
   - The `hidden` repair rule.
   - The `alts.enabled` key.

The in-game checklist T6 catalog line now says "every Midnight recipe of that line (learned or not)".

## Tests
- RED, after the spec edits and before the code: `busted tests/alts/collector_spec.lua` gave `39 successes / 8 failures / 1 error`.
- GREEN: `busted tests/alts/collector_spec.lua` gave `48 successes / 0 failures / 0 errors / 0 pending`.
- Mutation: I reverted the nil/nil path-name comparison, and the spec at line 223 failed. I then restored it.
- Full suite: `busted` gave `1874 successes / 0 failures / 0 errors / 0 pending`. The full TOC boots with the enable announcement and no spec regressed.
- Lint: `luacheck .` gave `0 warnings / 0 errors in 136 files`.
