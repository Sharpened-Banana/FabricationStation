# Task 10 report: Planner concentration schedule and cap warnings

Status: DONE_WITH_CONCERNS (the only concern is the in-game checks, which cannot be run here; see preflight row 8)
Base: be2d101. Commit: e75284d feat: add concentration scheduler and cap warnings to Planner

## What I built

### Modules/Planner.lua
- `Planner:GetSchedule(now = Now()) -> rows, status`. It reads `Alts:GetPools(now)`. Hidden characters and dropped or older records are already left out there. A pool whose value is unknown or whose max is nil or <= 0 is skipped without asking Recipes. For every other pool, `Recipes:GetRanked({ charKey, skillLineID, usesConcentration = true, sortBy = "goldPerConcentration" })` is called once (preflight row 24: no `Scanner:GetSchematic`). Results that belong to another charKey are ignored. Each result is shallow-copied, because Recipes' results are shared and read-only, and the copy gets the pool's `skillLineID`. The rows come from `PlanCalc.Schedule(pools, results, { maxCraftsPerRecipe = Settings().maxCraftsPerRecipe })`. The status is "ok", or "off" with `{}` while Alts **or Recipes** is missing or disabled.
- `Planner:GetCapWarnings(now) -> rows, status`. It returns `PlanCalc.CapWarnings(Alts:GetPools(now), now, capWarnHours * 3600)`: capped pools first, then those that will be full soon. The status is "off" only while Alts is missing or off, because Recipes is not needed here.
- `Planner:AnnounceCapWarnings(now)`. It prints `print("FabricationStation: <charKey> <Alts:ProfessionName(sl)>: concentration is full")` for a capped pool, or `"... concentration full in <dur>"` for one that will be full soon (preflight row 26: the prefix goes through the global print into `W.printed`). `<dur>` comes from `ns.UI.CharactersView.FormatDuration` when that is loaded. Otherwise it is whole hours rounded to the nearest hour, with a minimum of "1h". It runs once per session: the first call with status "ok" uses up the announcement, even when it finds no warnings. The announcement is not used up while `capWarnChat` is off or Alts is off.
- `OnEnable` registers only `PLAYER_ENTERING_WORLD`. Its handler unregisters itself, so later loading screens neither restart nor repeat the announcement, and then calls `ns.FS:Debounce("planner.capwarn", 10, ns.FS:Wrap("Planner", ...))` (a cancellable timer, not `C_Timer.After`, per preflight row 26). `OnDisable` cancels that debounce and unregisters all events. OnEnable makes no API calls.
- Task 9 follow-up: `GetMissingRecipes` now returns a separate "notScanned" status, for a record that has no numeric `time`. This is checked after hidden and noProfession and before the no-keys "noData" test. "noData" now means only that nothing lists the line's recipes.
- Caching: none. GetRanked only filters the results of its last pass, so a cache with invalidation was not needed.

### Modules/PlanCalc.lua (Task 3 follow-ups)
- `Schedule` now skips pools whose `max` is nil or <= 0, the same way `CapWarnings` does.
- The greedy schedule ranks recipes by gold per FULL concentration point spent: `gpc * expectedCost / concentrationCost`, or plain `gpc` when the expected cost is nil or <= 0. The final row sort uses the same rank as its second key, after `fullAt`. `ScheduleRow.goldPerConcentration` still holds the result's own value. This is documented in the code and in the contract.

### Contract
- In PlanCalc.Schedule: the max rule, the rank formula and the row sort.
- In Planner: the OnEnable/OnDisable lines are updated; GetSchedule, GetCapWarnings and AnnounceCapWarnings are added; the GetMissingRecipes status list now includes "notScanned".

### Tests
- New `tests/planner/schedule_spec.lua` (30 specs). It covers:
  - the brief's three specs, adapted: 1099 sits on another line (row 24), and the chat assertion is on `W.printed` with the prefix (row 26);
  - projection to a given `now`, the default now, `expectedConcentrationCost` (row 25) and the maxCrafts setting, including 0 meaning no limit;
  - the GetRanked filter arguments, with one call per pool;
  - a capped pool being scheduled first, no cross-character results, hidden characters, and unknown-concentration pools (where Recipes is not asked);
  - Recipes' results not being modified, the "off" status for Alts and for Recipes, and answers while Planner itself is disabled;
  - cap-warning fields, status and hidden characters;
  - chat: the "soon" text, the FormatDuration hook, the 1h minimum, nothing printed when there are no warnings and no retry after that, capWarnChat off, Alts off;
  - PLAYER_ENTERING_WORLD: the 10 s delay, a single announcement, a later loading screen not restarting the wait, Disable cancelling it, and an error disabling Planner instead of escaping.
- `tests/plancalc/schedule_spec.lua` has 4 new specs: max nil/0/negative, cross-character, rank per full point (greedy order and row order), and the fallback with no expected cost.
- In `tests/planner/knowledge_spec.lua`, two existing assertions changed from noData to notScanned, and there are 2 new specs for the notScanned order.
- `tests/integration/load_all_spec.lua` gets one smoke test: a full load, then PLAYER_ENTERING_WORLD, then advancing 15 s. It checks that there are no failed modules and no diagnostics errors.

## TDD evidence
- PlanCalc RED: `busted tests/plancalc/schedule_spec.lua` gave `36 successes / 2 failures` (the max-skip and per-full-point rank specs). GREEN: `busted tests/plancalc` gave `94 successes / 0 failures`.
- Planner schedule RED, without the implementation: `busted tests/planner/schedule_spec.lua` gave `1 success / 3 failures / 26 errors`. GREEN gave `30 successes / 0 failures / 0 errors`.
- notScanned RED, on the old Planner.lua: `busted tests/planner/knowledge_spec.lua` gave `40 successes / 3 failures`. GREEN: `busted tests/planner` gave `73 successes / 0 failures`.
- Full run: `busted` gave `2051 successes / 0 failures / 0 errors / 0 pending`. `luacheck .` gave `0 warnings / 0 errors in 142 files`.

## Files changed
- Modules/Planner.lua, Modules/PlanCalc.lua
- docs/superpowers/plans/2026-10-30-fs-interface-contract.md
- tests/planner/schedule_spec.lua (new), tests/planner/knowledge_spec.lua, tests/plancalc/schedule_spec.lua, tests/integration/load_all_spec.lua
- I appended two T10 lines to ingame-checklist.md. That file is not tracked.

## Where the code differs from the plan
- I followed preflight rows 24, 25 and 26 and the orchestrator notes instead of the plan text: GetRanked with a per-pool filter instead of GetSchematic; expectedGain from expectedConcentrationCost; Debounce plus the `FabricationStation: ` print instead of C_Timer.After and `ns.FS.Print`.
- The profession name comes from `Alts:ProfessionName(sl)`, which uses the Knowledge variant name, so it reads "Herbalism" rather than the record's "Midnight Herbalism".
- When AnnounceCapWarnings is called directly, it checks `capWarnChat` itself, so the PLAYER_ENTERING_WORLD handler does not need to.

## Self-review
- Unknown gold is never shown as a number: unpriced and unknown recipes are filtered out in PlanCalc. Unknown concentration never reaches arithmetic: Planner skips those pools before calling Recipes, and PlanCalc checks `positive(max)`.
- No saved-data writes were added, so no dbIsNewer spec is needed. Every event handler and timer body is Wrap'd. OnDisable leaks nothing.
- `announced` is a file-local flag, so it lasts for the session, and a /reload resets it. If Planner is disabled and then re-enabled mid-session, it registers PLAYER_ENTERING_WORLD again, but the once-per-session flag still prevents a second announcement.

## Concerns
- In-game behaviour is unverified: the chat timing after login, real GetRanked output and the profession names. The steps are in ingame-checklist.md (T10).
