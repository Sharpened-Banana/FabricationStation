# Phase 3 final review: fix wave findings (all in this one dispatch)
Range 513552f..47b3a9f (30 commits, Tasks 0-16). Baseline at review: `busted` 2255 green, `luacheck .` 0/0 in 158 files.
Verdict: With fixes (0 Important, 7 Minor). Nothing blocks the merge. M1 should land before the user's in-game
session, because its wrong expectations would produce false failure reports.
Scratch probe (not in the repo): /tmp/claude-0/-home-user-FabricationStation/8fbd541b-9883-5ada-b249-e0fbf0f6725a/scratchpad/p3/strip_probe.lua
(run with `lua <path>`; it shows the M4 blind spot).

## What was checked and holds

### End-to-end data flow
Every producer/consumer pair was traced field by field, including nil versus 0 and the status strings. No shape
mismatch was found.
- Scanner records feed Alts:
  - Alts reads `ProjectConcentration` (value and max), `spec.paths/perks`, `moxie.value`, the `cooldowns` map,
    `GetItemCount` parts, `GetOwnedCount` and `GetWarbandCount`.
- Alts produces `AltRow`, `AltProfession`, `SpecSnapshot`, `KnowledgeSummary`, `SourceState`, `Pool` and
  `ItemLocationRow`. Their consumers are:
  - PlanCalc: `Schedule` and `CapWarnings` read `value/max/fullAt`; `RankSpecNodes` reads display ranks and `perkRanks`.
  - Planner getters: checklist `{charKey, skillLineID, name, summary, states}`, missing-recipe `source{kind,itemID,text}`,
    `ScheduleRow`, `Pool+status` and `SpecAdviceRow`.
  - CharactersView (`Row`, `CellTexts`, `TooltipLines`, `DetailLines`, `Header`) and PlannerView (`KnowledgeCells`,
    `KnowledgeLines`, `SpecAdvice`, `SourceText`, `StatusText`).
  - The Characters and Planner tabs and the `altsKnowledge` widget.
- `FindItems` and `HoldingsLines` feed `Tab.ResultRow` and the `holdings` provider. The fields used are
  `bags/bank|nil/reagentBank/total/stale/dataAgeSeconds`, plus `partial`, `warband|nil`, `warbandStale` and
  `warbandAgeSeconds`.
- The knowledge count follows one rule everywhere: it is shown only when the status is "ok", and a partial sum is
  shown as "N+?". This holds on the Characters header, the Planner status line, the widget total, and the KP and
  Left cells.

### Shared rules
- **Unknown is never 0.** Concentration "—", knowledge "?", gold "--", bank "?" with "+", warband "not scanned",
  spec gain "?". No `FormatMoney(nil)` is shown as a value. One exception is M2.
- **Every getter status has a message.** The statuses are off, plannerOff, hidden, noProfession, notScanned, noData,
  noSpec, noRecipes and ok-empty.
- **Hidden characters** are left out of the overview, pools, schedule, cap warnings and the chat announcement,
  holdings and `FindItems`, the checklist and widget, and the pickers. `GetMissingRecipes` and `GetSpecAdvice` return
  "hidden" for them. The 1b surfaces are excluded by ruling 36.
- **No writes while dbIsNewer.** This covers every collector writer, `SetHidden`, the Planner section and every option
  setter.
- **Wrapping.** Every handler and debounced body is Wrapped. The only exceptions are the trivial `OnLeave`
  tooltip-hide handlers, which follow the phase-2 precedent.
- **Debounce keys and registrations.**
  - Every debounce key is cancelled in its OnDisable: `alts.*` ×6, `planner.capwarn`, `charactersTab.*` ×3,
    `plannerTab.*` ×2 and `altsWidgets.refresh`.
  - No key collides with a 1b/2 key.
  - `GET_ITEM_INFO_RECEIVED` is registered only while needed and is dropped on hide and on off.
- **516 px layouts.** The flexible column keeps at least 120 px in every phase-3 table:

  | Table | Flexible column at 516 px |
  |---|---|
  | Characters | 128 |
  | Search results | 172 |
  | Knowledge | 156 |
  | Schedule | 162 |
  | Spec | 170 |
  | Missing | 320 |

  - The section buttons (448 px) and the pickers plus status (284 + 208 px) fit in the 504 px bar.
  - The "Old data" marker sits in its own fixed region on both tabs.
- **The data marker.** The marker, the Characters header note, the Planner footer, the widget total and the tooltips
  all read `GameData.TableBuild("Knowledge")`.
  - With knowledge stamped 70575, the marker shows on every client build other than 70575. That is the accepted
    design (preflight row 6, Task 7 carry), and P3-13 tells the user to expect it.

### Phase 1b/2 regressions
- **Recipes.** `extraStats` is read before `full_opts`. It skips the cache on both lookup and store, and the empty
  table goes through the plain cached path.
- **Queue and Orders.** Their Task 0 edits are safe. The new `CRAFTINGORDERS_FULFILL_ORDER_RESPONSE` handler is
  Wrapped under a log-only source and unregistered in OnDisable. Scanner and QueueCraft are untouched.
- **Specs.** The click-only specs pass. `settings_spec` counts 9 tabs, and `load_all_spec` lists the phase-3 modules
  and the `alts` and `planner` groups.
- **No new protected calls.** The whole-addon reference map equals the phase 1-2 allowlist.

### Data and licensing
- `THIRD_PARTY_NOTICES.md` is at the repo root, and `.pkgmeta` does not ignore it. `gamedata_phase3_spec.lua:92-103`
  guards this.
- Every CSV credit names a project with a notice section: DjinnisDataTexts, choretracker or AllTheThings.
- "WeeklyKnowledge" and "HandyNotes" appear only as names, in the plan, `reports/`, `research_notes/` and the
  generator README's "do not take data from" line.
- The checklist's quest and item IDs are the committed CSV values. The Demystifyin' line asks for the user's own
  in-game reading.
- All 11 variants have rows in every weekly category, so no profession shows a falsely low "ok" count.

### Task 16
- **Integration specs.**
  - The whole-TOC boot, the three message storms, the two-cycle disable and re-enable registration check, and the
    registrar-off check are all real.
  - The mutations recorded in the report make them fail.
  - The protected-call spec has one blind spot (M4).
- **Checklist.** All 51 archived task lines map to P3-1 to P3-34, and the /dump paths and labels match the code.
  The exceptions are listed in M1.
- **Contract.** The status line is accurate.

## Important

None.

## Minor (include)

M1. Four P3 checklist lines (Task 16 had no task review) state an expectation the code does not meet. The user tests
    tomorrow, so fix these first.
    - **P3-2** (docs/in-game-checklist.md:468-471) says character 2's Age is "the time since you logged out of it".
      - Scanner writes `lastSeen` only at login (Modules/Scanner.lua:830, preflight row 33), and CharactersView shows
        `FormatAge(now - lastSeen)` (UI/Tabs/CharactersView.lua:145).
      - So after playing the alt for 30 minutes, its Age reads at least "30m", and the user would report a failure.
      - Fix: "its Age is the time since you logged in on it (the addon records a login, not a logout)".
    - **P3-15** (docs/in-game-checklist.md:536-537) quotes the message as
      "`Open this profession's specializations on <Name-Realm> ...`".
      - The tab passes the short name (`{ char = alt.name }`, UI/Tabs/Planner.lua:531).
      - Fix: write `<Name>` (character name only).
    - **P3-19** (docs/in-game-checklist.md:559) says "... concentration full in <N>h".
      - `duration_text` uses `CharactersView.FormatDuration` (Modules/Planner.lua:265-269), which gives "5h 12m" or
        "2d 4h".
      - Fix: "full in <duration>, for example `5h 12m`".
    - **P3-25** (docs/in-game-checklist.md:598-601) compares `spent` from the snapshot (summed over every path of every
      tab) with `GetTreeCurrencyInfo(..., GetSpecTabIDsForSkillLine(<id>)[1], ...)`, which reads the first tab only.
      - If that API's `spent` is per tree, the two numbers differ for a reason unrelated to the unlock point.
      - The line then tells the user to change `spent` in code.
      - Fix: have the user print every tab:
        `/run local id=<id> local c=C_ProfSpecs.GetConfigIDForSkillLine(id) for _,t in ipairs(C_ProfSpecs.GetSpecTabIDsForSkillLine(id)) do local i=(C_Traits.GetTreeCurrencyInfo(c,t,false) or {})[1] print(t, i and i.spent, i and i.quantity) end`
      - Then compare the snapshot's `spent` with the per-tab sum, or with the common value when every tab reports the
        same number. Only then apply the "differs by the number of unlocked paths" rule.
    Test: none (docs).

M2. An unknown concentration regeneration rate shows as ">14d", "not full within 14 days" (deferred Task 12 minor;
    design rule 6).
    - **Cause.**
      - Scanner stores `perCycle = info.rechargingAmountPerCycle or 0` and the cycle the same way
        (Modules/Scanner.lua:272).
      - `ProjectConcentration` then returns the stored value unchanged (Scanner.lua:439-440).
      - So `TimeToFull` returns nil, and the views claim a known fact ("not within 14 days") about an unknown rate:
        - CharactersView.lua:83-94 (cell) and :208-217 (detail);
        - UI/Tabs/Planner.lua:292-293 (Caps in);
        - PlannerView.lua:104-105.
      - Concentration always regenerates, so `perCycle`/`cycleSeconds` ≤ 0 or nil always means "unknown".
    - **Fix, in phase-3 files only (Scanner stays untouched).**
      - In `Alts` `concentration()` (Modules/Alts.lua:137-144), read the record's `concentration.perCycle` and
        `cycleSeconds` through `S:GetProfession`. When `value < max` and either is not positive, return
        `{ now, max, secondsToFull = nil, fullAt = nil, rateUnknown = true }`.
      - `GetPools` copies `rateUnknown`.
      - `PlanCalc.Schedule` passes `p.rateUnknown` through to its rows (a pure copy).
      - Views:
        - The Characters cell becomes "400/1000 · ?".
        - The detail says "fill time unknown (no regeneration data)".
        - ScheduleRow shows "?" with the tooltip "Full in: unknown".
        - ConcentrationLines shows "?".
      - CapWarnings needs no change: a capped pool is still capped, and a pool below max without `fullAt` is already
        skipped.
      - Add the field to the contract (AltProfession.concentration, Pool, ScheduleRow).
    - **Tests.**
      - overview_spec: a record with value 400, max 1000 and `perCycle = 0` gives `rateUnknown = true` and
        `secondsToFull = nil`, while a full pool with `perCycle = 0` stays `secondsToFull = 0` ("Full").
      - views_spec: `Row(...).profs[1].conc == "400/1000 · ?"`.
      - planner_tab_spec: `ScheduleRow` caps "?".
      - schedule_spec: a row keeps `rateUnknown`.
    - This also covers the Task 1 minor "non-regenerating → nil" end to end.

M3. The Spec advice "no data" message names the wrong build.
    - `PlannerView.SpecAdvice` defaults `build` to `Planner:GameDataBuild()`, which is `GameData.Build()`, the
      most-common build (UI/Tabs/PlannerView.lua:210-216; Modules/Planner.lua:58-61).
    - With the shipped data it reads "Spec effect data not in this GameData build (70575)", although SpecEntryEffects
      is simply not generated.
    - That is the same mistake the Task 14 ruling fixed for knowledge (each table's own build). The
      `Planner:GameDataBuild` comment ("shown in the Planner header") is stale too.
    - Fix:
      - Default to `ns.GameData.TableBuild("SpecEntryEffects")`, with nil giving "(not generated)". `ctx.build` stays
        an override.
      - Fix the comment, or drop `GameDataBuild` if nothing else uses it (no caller outside PlannerView).
      - Update P3-15's expected text to match.
    - Tests:
      - views_spec:360 and planner_tab_spec:526 change to "(not generated)" for the shipped state.
      - Add a case with `Define("SpecEntryEffects", 70575, {})` that gives "(70575)".

M4. The Task 16 protected-call scan has a blind spot. Its `strip_comments` (tests/integration/phase3_spec.lua:289-307)
    treats any `--` as a comment start, including inside a string.
    - Everything after a `"--"` string on the same line is therefore never scanned.
    - The probe shows `local q = x or "--"; C_TradeSkillUI.CraftRecipe(1)` counting 0 references.
    - Such lines exist today, for example UI/Tabs/Queue.lua:146, Customers.lua:344/352/362 and Orders.lua:213-222.
    - So the spec's claim that "any new caller anywhere fails here" does not hold.
    - Fix: make the stripper string-aware:
      - skip `"..."` and `'...'` with backslash escapes;
      - skip `[[...]]` and `[=[...]=]` long strings;
      - only then treat `--` as a comment start.
    - Tests:
      - Extend the self-test ("counts whole-token references outside comments") with
        `local q = x or "--"; C_TradeSkillUI.CraftRecipe(1)` (counts 1) and `local s = "a -- CraftRecipe"` (counts 1:
        strings still count).
      - The whole-addon map must still equal ALLOWED. The lines after `"--"` strings were checked and hold no
        protected names, so no allowlist change is expected.

M5. The storm specs cover the three bus messages but none of the bursty game events behind them. Those events are
    `GET_ITEM_INFO_RECEIVED` (up to 50 name loads after one `FindItems`), `QUEST_LOG_UPDATE` and
    `CURRENCY_DISPLAY_UPDATE` (alts.flags), and `TRADE_SKILL_LIST_UPDATE` (alts.prof).
    - Fix: add four cases to tests/integration/phase3_spec.lua "message storms":
      - **Item names.** With a Characters search active (`searchText` set, so `GET_ITEM_INFO_RECEIVED` is
        registered), fire `GET_ITEM_INFO_RECEIVED` 50× for different itemIDs. Expect `charactersTab.refresh` to fire
        exactly once.
      - **Planner names.** On Planner > Missing recipes with a pending item name, the same storm fires
        `plannerTab.refresh` once.
      - **Quest and currency events.** 50× `QUEST_LOG_UPDATE` plus 50× `CURRENCY_DISPLAY_UPDATE` give one `alts.flags`
        run, one `knowledgeWeekly` write and one `FS_ALTS_CHANGED`.
      - **Trade skill list.** 50× `TRADE_SKILL_LIST_UPDATE` with the profession open gives one `alts.prof` run.
    - Every case also uses `assert_each_key_once` and `assert_clean`.

M6. Contract touch-ups (docs/superpowers/plans/2026-10-30-fs-interface-contract.md). This includes three deferred
    lines.
    - Line 29: the core-module list names `CharactersTab` and `AltsWidgets` but not `PlannerTab` or `AltsTooltips`.
      Both set `coreModule = true`, and the line-5 status line already names them.
    - Line 130: the `FS_ORDERS_CHANGED` row should say "also sent when Orders is turned on (Task 0)" (Task 0 deferred
      minor).
    - Line 312: add to `TimeToFull` that a max ≤ 0 reads as full (0), so callers filter max ≤ 0 first, as `Alts` does
      (Task 1 deferred minor).
    - Lines 359-361: note that a logged-in character on the snapshot fallback (live bags call missing) shows the login
      snapshot, which can be stale within the session (Task 8 deferred minor).
    - Add M2's `rateUnknown` there.
    Test: none (docs).

M7. Display nits.
    - **Widget colour.** `UI/AltsDashboard.lua:31` names `WARN = "|cffffd100"` (gold), while the comment at :54 says
      the outdated total is "orange". Both tabs draw the "Old data" marker in orange `|cffff8000`. Use the orange
      code, so the widget's outdated total matches the marker (deferred Task 15 minor).
    - **Double parentheses.** `CharactersView.TooltipLines` (UI/Tabs/CharactersView.lua:365) wraps the note in
      parentheses, but the note already ends in "(outdated)". The result is
      "Knowledge left this week: 3 (data build 70575 (outdated))". Use `DOT .. note` instead.
    - Tests:
      - dashboard_widgets_spec: an outdated total line starts with `|cffff8000`.
      - views_spec: `TooltipLines(row, "data build 70575 (outdated)")` contains
        "Knowledge left this week: 3 · data build 70575 (outdated)".

## Deferred-minor triage

Task 0 (minor, deferred):
- The queue "Orders disabled" spec asserts absence rather than "loaded, then disabled". **KEEP DEFERRED**: a disabled
  Orders sends nothing, which is the same as not loaded, and the Blizzard-event path itself is covered
  (queue_spec "still removes without the Orders module").
- No spec or comment pins Orders' boot-time ORDERS_CHANGED. **KEEP DEFERRED**: board_spec.lua:19-22 now comments on
  and strips it, and board_spec.lua:133 pins the re-enable announcement.
- The contract message table does not say that Orders announces on enable. **INCLUDE** (M6).

Task 1 (minor, final wave):
- The concentration stand-in lacks Scanner's perCycle/cycleSeconds ≤ 0 guard, and there is no "non-regenerating →
  nil" spec. **INCLUDE via M2**: the shared fake already has the guard (tests/helpers/phase3_fakes.lua:185-186), and
  M2's overview spec covers the non-regenerating case end to end.
- Specs for over-max and max = 0, plus a contract sentence. **Contract sentence INCLUDE (M6); specs KEEP
  DEFERRED**: Scanner caps the value at max, and Alts filters max ≤ 0 before TimeToFull, so no caller reaches either
  case.
- The startTime seconds and DST note. **KEEP DEFERRED (resolved)**: PlanCalc.lua:33-34 and contract line 312
  document the seconds, and P3-23 checks DST in game.
- The custom-horizon assert should be exactly 3600000. **KEEP DEFERRED**: it is a test-precision nit, and the bound
  already proves "never early".

Task 2 (minor, final wave):
- limit = 0 with quests reads as done. **KEEP DEFERRED**: the generator rejects limit < 1
  (`optionalPosInt`, tools/gamedata/phase3_gen.lua:114), so shipped data cannot reach it.
- monthly == Darkmoon without a category check. **KEEP DEFERRED**: the generator maps only `darkmoon` to monthly
  (phase3_gen.lua:22).

Task 3 (minor, final wave): cross-character pool test, full-cost ranking, and Schedule skipping max ≤ 0. **KEEP
DEFERRED (resolved)**: all three were folded into Task 10 and are done.
- `rateOf`: PlanCalc.lua:196-198.
- The max ≤ 0 skip: PlanCalc.lua:223.
- The cross-character test: schedule_spec.lua:70 and :121.

Task 4 (minor, final wave): the AcquireMethod `~= 0` predicate, validating the knowledge_sources header, a note-level
line for itemIDs without an on-use or quest effect, and the per-cell `num()` pcall cost. **KEEP DEFERRED** (all four):
this is offline tooling that does not ship and cannot run here (wago.tools is blocked). Revisit at the first real
generator run (P3-34).

Task 5 (minor, final wave):
- The .pkgmeta guard should handle glob entries. **KEEP DEFERRED**: .pkgmeta has no glob entries, and the exact-entry
  guard holds.
- The checklist's Demystifyin' line should cite ATT CharacterItemDB. **KEEP DEFERRED (resolved in Task 16)**: P3-33
  cites it as a source of candidate IDs only.

Task 8 (minor, final wave):
- Make the warband and owned live gates watertight (probe both GetItemCount flag sets before trusting a live 0).
  **KEEP DEFERRED**: the right gate depends on P3-17's answer (does the account-bank count answer before the warband
  bank is opened?), so fix it after the user's session.
- Contract: a logged-in character on the snapshot fallback can be stale. **INCLUDE** (M6).

Task 10 (minor, final wave):
- Re-enabling Planner within the 10 s window loses the announcement until the next loading screen. **KEEP DEFERRED**:
  it needs a module toggle in the first 10 s after login, and the next login announces as usual.
- "full in 1h" overstates times under 30 minutes. **KEEP DEFERRED (resolved)**: `duration_text` now uses
  `CharactersView.FormatDuration` (Modules/Planner.lua:265-269), which is always loaded by the TOC ("<1m", "45m").

Task 11 (minor, final wave):
- The coverage-set RecipeLabels scan is redundant. **KEEP DEFERRED**: it is a performance cost only with a generated
  SpecEntryEffects table (the shipped table is empty), and the advice is memoised.
- The scoped-part order comes from pairs() and is nondeterministic. **KEEP DEFERRED**: the parts are summed per
  recipe, so the order cannot change a result.
- A nil what-if counts as no change. **KEEP DEFERRED**: the plan mandates it.

Task 12 (minor, final wave):
- Concentration with an unknown regeneration rate shows ">14d". **INCLUDE** (M2).
- `capped(max 1)` drops the Total line. **KEEP DEFERRED**: the only caller with a cap passes 6 (the widget).
- ", next in" relies on a string compare instead of a flag. **KEEP DEFERRED**: the output is correct, and this is
  code style only.

Task 15 (minor, final wave):
- The WARN colour named "orange" is gold. **INCLUDE** (M7).
- The OnInitialize registration spec only checks coreModule. **KEEP DEFERRED**: phase3_spec.lua:72-86 now proves
  widget 65 is registered on a whole-TOC boot.
- No nil status guard in the widget. **KEEP DEFERRED**: CurrentModel always passes a status, and nil still produces
  a message ("No data (nil)").
- The names sentinel is per row only. **KEEP DEFERRED**: load requests are already de-duplicated per session
  (`requestedNames`), so only an extra GetItemNameByID call per repeated item remains.
