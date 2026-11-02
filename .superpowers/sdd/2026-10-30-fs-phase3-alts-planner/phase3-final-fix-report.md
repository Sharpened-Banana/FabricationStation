# Phase 3 final fix wave: report

BASE 47b3a9f on feat/fabricationstation. Scope: M1-M7 plus every deferred minor the triage marks INCLUDE
(Task 0 contract line, Task 1 "non-regenerating -> nil" and the TimeToFull contract sentence, Task 8 contract note,
Task 12 ">14d" for an unknown rate, Task 15 WARN colour). KEEP DEFERRED items were not touched.

Final state: `busted` 2264 successes / 0 failures (baseline 2255; +9 new cases), `luacheck .` 0 warnings / 0 errors in
158 files. Nothing pushed.

## Commits

| SHA | Subject | Findings |
|---|---|---|
| db00b08 | docs: match the phase 3 checklist lines to what the code shows | M1 |
| 10c9ddd | fix: name the spec effect table's own build in the Spec advice message | M3 |
| 12d2bc0 | fix: colour the widget's outdated total orange and drop doubled parentheses | M7 (incl. Task 15 deferred) |
| 89578f4 | test: make the protected-call scan skip "--" inside strings | M4 |
| 414044f | fix: show an unknown concentration fill time as "?", not "not within 14 days" | M2 (incl. Task 1/Task 12 deferred) |
| 0c3f0e5 | test: cover the bursty game events behind the phase 3 message storms | M5 |
| 2c332fd | docs: contract touch-ups for the phase 3 final review | M6 (incl. Task 0/1/8 deferred), P3-7 note |
| 65683bc | docs: rewrap two phase 3 checklist paragraphs | formatting only |

## M1: checklist lines (docs/in-game-checklist.md, Phase 3 section)

I checked every P3 line (P3-1 to P3-34) against the code. These are the changes:

- **P3-2 (from the review).** Age is the time since the last login on that character, not since logout
  (Scanner.lua:830 writes `lastSeen` only in OnEnable; CharactersView.Row uses `FormatAge(dataAgeSeconds)`).
  The line now says that 30 minutes of play reads at least `30m`.
- **P3-15 (from the review, and M3).**
  - The noSpec message names `<Name>` alone. Planner.lua passes `{ char = alt.name }`.
  - New: the noRecipes message is spelled out. GetSpecAdvice returns "noRecipes" before any advice when the
    character has no profitable priced recipe, so without prices the user sees that message and not the
    spec-data one.
  - With M3, the spec-data text is now `(not generated)`.
- **P3-19 (from the review).** The text is now `full in <duration>`, for example `5h 12m` or `2d 4h`. This is
  `duration_text`, which uses `CharactersView.FormatDuration`.
- **P3-25 (from the review).**
  - The user now runs a 233-character `/run` (it fits the 255-character chat limit) that prints tab ID, spent and
    unspent for every spec tab.
  - Compare the snapshot's `spent` (raw ranks summed over every path of every tab, AltsCollector GetSpecSnapshot)
    with the per-tab sum, or with the shared value when every tab reports the same number.
  - The "differs by the number of unlocked paths" rule applies only then.
  - The user reports the numbers and does not change code.
- **P3-1.** "the spec points match the unspent points" now says the `(+N)` in the Spec cell (`spent/max (+unspent)`)
  equals Blizzard's unspent points. The cell shows spent/max first, which uses raw ranks.
- **P3-7.** The line said that hovering the status line shows a tooltip. On the plain grid the status line is empty
  (it holds text only during a search or after a Hide or Show click), and the hover area returns nil for empty text.
  The line now says this.
- **P3-9.** The line said Warband shows `not scanned` on an account whose warband bank was never opened. That is
  wrong in game:
  - `Alts.warband_count` uses `Scanner:GetWarbandCount` whenever the live `C_Item.GetItemCount` answers.
  - That function always returns a number. Its fallback is `.warband or 0`.
  - So the column shows a number (`0` when there is none). `not scanned` appears only when the game cannot count
    the warband bank and it was never opened. The line says this now and also says `+N` appears after three
    characters.
- **P3-11.** The line now has the exact texts:
  - Characters: `Alts is turned off: turn it on in Settings > Modules to see your characters`.
  - Planner: `Alts is turned off`. The Planner gives no "how to turn it on" hint for Alts.
- **P3-13.** The marker tooltip starts `Game data build 70575 is outdated`. It names the knowledge build, not the
  client build, so the old `<X>` was ambiguous.
- **P3-16.** The shipped RecipeSources table is empty (`bySkillLine = {}`), so every source kind is "unknown" and no
  entry can read `Recipe item: …`. The line now says this and gives the Unknown text. The Planner-off text is now
  written out in full.
- **P3-17.** The `Warband bank N` line appears only when the warband bank holds some. `N+` also marks an alt bank
  that was never scanned. "(warband not scanned)" appears only when the game cannot count the warband bank and it
  was never opened.
- **P3-20.** The line said the widget updates "within a second" of a quest turn-in. The real chain is:
  1. QUEST_TURNED_IN, QUEST_LOG_UPDATE or CURRENCY_DISPLAY_UPDATE starts a 2 s trailing debounce (`alts.flags`).
  2. The flags are written and FS_ALTS_CHANGED is sent.
  3. The widget waits 0.5 s (`altsWidgets.refresh`), then redraws.

  So the update comes about 3 s after the last of those events. The line says "a few seconds (about 3 s)".
- **P3-27.** The line now gives the printed format: `FabricationStation: <source id> <questID>=true|false ...`.
- **P3-28.** `sourceText` is `""` when the game gives no source text, which is usually the case for learned recipes.
- **P3-7, added in the M6 commit.** If a pool below max reads `fill time unknown (no regeneration data)` or `?`, the
  user should report it. This is the new M2 display.

The other lines (P3-3 to P3-6, P3-8, P3-10, P3-12, P3-14, P3-18, P3-21 to P3-24, P3-26, P3-29 to P3-34) were checked and
match the code. Examples:
- P3-5's `knowledgeWeekly.time = WeekStart() - 60` makes SourceProgress treat the weekly sources as "open" with 0
  earned. The status stays "ok", so `weeklyLeft == weeklyTotal`, and once-sources keep their flags.
- P3-14's Queued text uses `charKey` (`Name-Realm`), which is correct there.
- P3-21: Settings has four options.

No other P3 line needs a change.

Tests: none (docs). The only lines over 120 characters are code spans that were already long before this wave, plus
the new P3-25 `/run` line, which must stay on one line.

## M2: unknown regeneration rate (Task 1 and Task 12 deferred minors)

Changes:
- **Modules/Alts.lua**
  - The new `rate_known(S, charKey, sl)` reads `S:GetProfession(...).concentration.perCycle/cycleSeconds`.
  - `concentration()` returns `{ now, max, rateUnknown = true }` (no secondsToFull or fullAt) when value < max and
    the rate is not positive.
  - A full pool keeps `secondsToFull = 0` ("Full").
  - `GetPools` copies `rateUnknown`. It is `nil`, never `false`, so the existing exact-table pool asserts stay valid.
  - Scanner itself is untouched.
- **Modules/PlanCalc.lua.** `Schedule` copies `p.rateUnknown` onto its rows. This is a pure copy.
- **Views**
  - CharactersView cell: `400/1000 · ?`. Detail: `fill time unknown (no regeneration data)`. The pool is never
    urgent.
  - `PlannerView.ConcentrationLines` shows `?`.
  - `Tab.ScheduleRow` shows `?` in Caps in, with the tooltip `Full in: unknown`.
- **CapWarnings.** Unchanged. A pool below max without fullAt was already skipped.
- **Contract.** Pool, ScheduleRow, the AltProfession concentration and the GetPools text are updated. So are the
  ConcentrationLines and Caps in values.

Tests:
- overview_spec: the new case "an unknown regeneration rate gives rateUnknown and no fill time".
  - With `perCycle = 0`, `cycleSeconds = 0` or both nil, the result is `{ now = 400, max = 1000, rateUnknown = true }`.
  - The pool copies the flag.
  - No cap warning.
  - A full Bren pool with `perCycle = 0` stays `secondsToFull = 0, fullAt = NOW`.
- schedule_spec: "a row keeps its pool's rateUnknown".
- views_spec:
  - Row conc `"400/1000 · ?"`, not urgent with capWarnHours = 168, plus the detail line. A full pool without a rate
    is still "Full".
  - ConcentrationLines shows `?` and the line is not urgent.
- planner_tab_spec: "shows '?' in Caps in when the regeneration rate is unknown".
  - The grid cell and tooltip line.
  - Pure ScheduleRow checks for `?` and for `>14d`.
  - No soon warning row even with capWarnHours = 168.

RED:
```
$ busted tests/plancalc/schedule_spec.lua tests/ui/views_spec.lua tests/ui/planner_tab_spec.lua tests/alts/overview_spec.lua
161 successes / 5 failures / 0 errors / 0 pending
Failure -> tests/plancalc/schedule_spec.lua @ 58   (:65 expected true, got nil)
Failure -> tests/ui/views_spec.lua @ 79            (:85)
Failure -> tests/ui/views_spec.lua @ 287           (:292)
Failure -> tests/ui/planner_tab_spec.lua @ 386     (:394)
Failure -> tests/alts/overview_spec.lua @ 247      (:251 got { max = 1000, now = 400 }, expected + rateUnknown = true)
```
GREEN: same command gives 166 successes / 0 failures. Full suite 2260/0, luacheck 0/0.

## M3: Spec advice build

Changes:
- **The message.** `PlannerView.SpecAdvice` now defaults `build` to `ns.GameData.TableBuild("SpecEntryEffects")`.
  When that is nil it says "(not generated)". `ctx.build` still overrides, and `false` means none.
- **`Planner:GameDataBuild` is kept.** The ruling allowed dropping it if nothing else used it. Nothing calls it any
  more, but the contract lists it as public API (contract line 373) and knowledge_spec pins it, so I kept it and
  corrected its stale comment ("No view shows it"). The contract entry now says the same.
- **Contract.** The SpecAdvice entry is updated.
- **Checklist.** P3-15 now says `(not generated)`.

Tests:
- views_spec:
  - Shipped state with `GameData.Build() == 70575` gives "(not generated)".
  - The override `build = 70000` gives "(70000)".
  - After `Define("SpecEntryEffects", 70575, {})` it gives "(70575)".
- planner_tab_spec:526: changed to "(not generated)".

RED:
```
$ busted tests/ui/views_spec.lua tests/ui/planner_tab_spec.lua
71 successes / 2 failures
views_spec.lua:363 / planner_tab_spec.lua:526: got '... build (70575)', expected '... build (not generated)'
```
GREEN: the same specs plus tests/planner give 177 successes / 0 failures. Full suite 2255/0.

## M4: string-aware protected-call scan

Changes:
- `strip_comments` in tests/integration/phase3_spec.lua now copies these before treating `--` as a comment:
  - `"..."` and `'...'` strings, with backslash escapes, stopping at the closing quote or a newline;
  - `[[...]]` and `[=[...]=]` long strings.
- A comment after a string is still removed, and long comments are still blanked to newlines.

The self-test now also covers:
- `local q = x or "--"; C_TradeSkillUI.CraftRecipe(1)`
- `local s = "a -- CraftRecipe"`
- an escaped quote before `--`
- a `[==[ -- ]] ]==]` long string
- a comment after a string (`ClaimOrder` must not count)
- a `--[==[ ... ]==]` long comment followed by `"\"--"`

The expected count is `{ CraftRecipe = 7 }`. The whole-addon map still equals ALLOWED, so no allowlist change was
needed (as the review predicted).

RED:
```
$ busted tests/integration/phase3_spec.lua
18 successes / 1 failure
phase3_spec.lua:345: got { CraftRecipe = 2 }, expected { CraftRecipe = 7 }
```
GREEN: 19/0.

## M5: game-event storms (tests/integration/phase3_spec.lua, new "game event storms" block)

Four cases:
1. **Characters search.** A Characters search is active: the box's OnTextChanged runs with "ore", then the 0.3 s
   debounce. `GET_ITEM_INFO_RECEIVED` fires 50 times for different itemIDs. Result: `charactersTab.refresh` and
   `refreshes.characters` each once.
2. **Planner > Missing recipes.**
   - Setup:
     - Bren's 2912 record is marked scanned.
     - The test defines RecipeSources with 50 "item" sources whose names are not cached.
     - The section is "missing".
     - The picker resolves to Bren.
   - 50 `GET_ITEM_INFO_RECEIVED` for those items. Result: `plannerTab.refresh` and `refreshes.planner` each once.
3. **Quest and currency.** 50× `QUEST_LOG_UPDATE` plus 50× `CURRENCY_DISPLAY_UPDATE`. Result: one `alts.flags`
   run, one `CollectKnowledgeFlags` call, one `knowledgeWeekly` write (counted by table identity) and one
   FS_ALTS_CHANGED.
4. **Trade skill list.**
   - Setup: the profession is open (ProfessionsFrame shown, IsTradeSkillReady, a recipe on line 2907).
   - 50× `TRADE_SKILL_LIST_UPDATE`. Result: one `alts.prof` run and one `CollectOpenProfession` call, and the
     catalog entry is written.
   - Deviation from the suggested assert, explained:
     - The open profession also makes the real Scanner rescan and send FS_DATA_CHANGED. Alts relays that as a
       second FS_ALTS_CHANGED, more than 0.5 s after the first, so `altsWidgets.refresh` legitimately runs twice
       even for one event.
     - So this case compares the storm with a single event, as the existing logged-in FS_DATA_CHANGED case does:
       the `spy.fired` and refresh maps are identical.
     - It does not use the strict `assert_each_key_once`, which fails here for that reason only.

Every case ends with `assert_clean`. Cases 1 to 3 also use `assert_each_key_once`.

These are coverage additions, so they pass on correct code. RED evidence comes from mutations. Each debounce below was
replaced by a direct call, and each mutation was reverted afterwards:
- Characters `onItemInfo` calls `request_refresh()` directly: fails @209 (case 1).
- Planner `onItemInfo` calls `request_refresh()` directly: fails @227 (case 2).
- AltsCollector `flagsSoon` calls `collectFlags()` directly: fails @250 (case 3), and also the existing @169 cases.
- AltsCollector `professionSoon` calls `collectProfession()` directly: fails @277 (case 4).

GREEN: phase3_spec 23/0. Full suite 2264/0.

## M6: contract touch-ups (docs/superpowers/plans/2026-10-30-fs-interface-contract.md)

- **Core-module list (line 29).** Now names `PlannerTab` (Task 14) and `AltsTooltips` (Task 8, the commit that
  added it) as core registrars.
- **`FS_ORDERS_CHANGED` row (Task 0 deferred).** Now says it is also sent when Orders is turned on (Task 0) and
  when it is turned off. Orders.lua OnEnable and OnDisable both send it.
- **`TimeToFull` (Task 1 deferred).** A max <= 0 reads as full (0), so callers filter max <= 0 first, as Alts does.
- **Logged-in character on the snapshot fallback (Task 8 deferred).**
  - Its counts are Scanner's last scan: bags at login and on BAG_UPDATE_DELAYED, the bank only while it is open.
  - So they can be stale within the session.
  - `stale` follows staleDays, so this is not marked.
- **M2's `rateUnknown`.** Added in the M2 commit.

Tests: none (docs).

## M7: display nits (Task 15 deferred)

- `UI/AltsDashboard.lua`: WARN is now `|cffff8000`, the orange of the "Old data" marker.
- `CharactersView.TooltipLines`: `DOT .. note` instead of `" (" .. note .. ")"`.

Tests:
- dashboard_widgets_spec: the raw total line is `|cffff8000Total: 5 KP (outdated)|r`, and the tooltip reason line
  starts with orange.
- views_spec:
  - "Knowledge left this week: 2 · data build 70575 (outdated)" with no "((".
  - `TooltipLines(row, "data build 70575 (outdated)")` gives "...: 3 · data build 70575 (outdated)".
  - `TooltipLines(row, false)` gives the count alone.

RED:
```
$ busted tests/ui/views_spec.lua tests/ui/dashboard_widgets_spec.lua
48 successes / 2 failures
views_spec.lua:237 (nil); dashboard_widgets_spec.lua:133 got '|cffffd100Total: 5 KP (outdated)|r'
```
GREEN: 50/0.

## Files changed

- Modules: Alts.lua, PlanCalc.lua, Planner.lua (comment only)
- UI: AltsDashboard.lua, Tabs/CharactersView.lua, Tabs/Planner.lua, Tabs/PlannerView.lua
- tests:
  - alts/overview_spec.lua
  - plancalc/schedule_spec.lua
  - ui/views_spec.lua
  - ui/planner_tab_spec.lua
  - ui/dashboard_widgets_spec.lua
  - integration/phase3_spec.lua
- docs: in-game-checklist.md, superpowers/plans/2026-10-30-fs-interface-contract.md

## Self-review

- **Design rule 6.** M2 turns an unknown rate into "?". A full pool is still "Full". No 0 or false values were
  introduced (`rateUnknown` is true or nil).
- **PlanCalc purity.** PlanCalc still reads no WoW globals and no ns.FS. The Schedule change is a field copy.
- **No new event registrations or debounce keys.** The no-protected-calls map is unchanged.
- **Tests do not leak globals.** The M5 test restores `_G.ProfessionsFrame` with `finally`. C_TradeSkillUI is rebuilt
  by each `world()`.
- **Mutations reverted.** Every mutation from the M5 check was reverted with `git checkout`, and the tree is clean.

## Concerns

- **1b concentration widget (order 30).** It reads Scanner directly, so an unknown rate there still shows whatever
  1b shows. That is outside phase-3 scope, the same as ruling 36 on 1b surfaces.
- **Warband column.** After M1, P3-9 says Warband shows a number in game. If P3-17 finds that the live count does
  not cover an unopened warband bank, the column will read `0` instead of `not scanned`. That is the KEEP DEFERRED
  Task 8 gate, to be fixed after the user's session.
