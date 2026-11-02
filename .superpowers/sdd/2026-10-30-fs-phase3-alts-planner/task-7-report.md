# Task 7 report: Alts overview (AltRow) and knowledge state

Status: DONE_WITH_CONCERNS. The concerns are the in-game checks only. BASE ab81837.

## Commits
- 675268f fix: keep a known recipe source text when the client gives an empty one (the Task 6 minor)
- 0d322d1 feat: add Alts overview rows with knowledge, concentration and cooldowns

## What I built (Modules/Alts.lua)
- `Alts:GetOverview(opts)` returns the rows in this order: the logged-in character first, then `lastSeen` descending (a missing value sorts last), then `charKey`. Hidden characters appear only with `opts.includeHidden`.
- `Alts:GetAltRow(charKey, now)` returns an AltRow as the plan defines it, plus two additions:
  - `olderProfessions` counts the records that are not listed (preflight row 9).
  - `flags.knowledgePartial` is the carry from Task 2.
  - The row is nil when there is no saved record.
  - A hidden character still gets a row, with `hidden = true`.
- Which professions are listed (preflight rows 9 and 10):
  - Only records whose line is in `Knowledge.variants`.
  - Without Knowledge data, records that have a `concentration` or `spec` snapshot.
  - `dropped` records are skipped and counted nowhere.
- Name and realm are split on the first `-`. `dataAgeSeconds` is raw (preflight row 33). `stale` means the age is greater than `staleDays` days. A record with no `lastSeen` has `dataAgeSeconds = nil` and counts as stale.
- Concentration:
  - It comes from `Scanner:ProjectConcentration`.
  - It is nil when the projection is nil or `max` is nil or ≤ 0 (preflight row 11).
  - `secondsToFull` comes from `PlanCalc.TimeToFull`. It is 0 when the pool is capped, and then `fullAt = now`. It is nil beyond the 14-day horizon.
- `Alts:_moxie` and `Alts:_cooldowns` normalise the 1a shapes as the brief says. Cooldowns are sorted by `readyAt`, then by recipeID.
- Knowledge:
  - `GetKnowledgeState` and `GetKnowledgeSummary` use the snapshot only when it has a numeric `time`.
  - `ctx` = `{ WeekStart(now), DarkmoonWindow(now, cal) }`.
  - `cal` is nil when the calendar call is missing or errors, or when any of its fields fails `canaccessvalue` (feature-tested).
  - `firstCraftPoints` comes from Knowledge. When Knowledge is nil, every summary is `noData`.
- `knowledgeLeft` and `knowledgePartial`, the rule written into the contract:
  - `knowledgeLeft` = Σ `weeklyLeft` over listed professions with status `"ok"`.
  - It is nil when no listed profession is `"ok"`.
  - `knowledgePartial` is true when `knowledgeLeft` is a number and at least one listed profession is `noData` or `unknown`.
- `Alts:WeekStart(now)` uses `PlanCalc.WeekStart` with the API. When the API is missing, errors, or returns a non-number or secret value, it falls back to `FallbackWeekStart(now, GetCurrentRegion())`. A comment explains why this differs from `Ledger:WeekStart` (preflight row 31).
- `Alts:GetPools(now)` returns one Pool per visible character and listed profession whose record has a concentration snapshot. When the concentration is unknown, `value`, `max`, `fullAt` and `secondsToFull` are all nil. That matches the contract's Pool shape and design rule 6, and PlanCalc already skips such pools.
- `Alts:ProfessionName(sl)` tries, in order:
  1. the Knowledge variant name
  2. a saved record's name (inside an AltRow, the character's own record comes first)
  3. `GetProfessionInfoBySkillLineID`, called through pcall
  4. `"Skill <sl>"`
- `Alts:SetHidden(charKey, bool)`:
  - It writes `Settings().hidden[charKey] = true|nil`, so the change is session-only while `dbIsNewer` is set.
  - It sends `FS_ALTS_CHANGED(charKey)`.
  - It ignores a charKey that is not a string or is empty.
  - Per preflight row 36, hiding applies to phase-3 surfaces only. This is recorded in the contract.
- AltsCollector change (Task 6 minor): an empty new `sourceText` keeps a stored text that is not empty.
- Contract updated:
  - New Task 7 bullet: AltRow and AltProfession shapes, listing rules, the knowledge sum rule, WeekStart, Pools, ProfessionName, SetHidden and the hidden scope.
  - The `GetOverview` line.
  - A phase3_env fixture note.
  - The catalog `sourceText` rule.
- Fixture (`tests/helpers/phase3_fakes.lua`, additive): Aria now also carries an older-expansion record, `[2822]` "Khaz Algar Blacksmithing", with no concentration or spec (preflight row 9).
- The in-game checklist has three T7 lines: WeekStart against the real reset and the calendar field types, an AltRow sanity check, and an alt seen before the reset.

## Review Focus coverage (tests/alts/overview_spec.lua; each item has its own `describe`)
1. "Cato has no professions". A bare record (no professions table, gold or class) gives a row without errors or zeros. A character with only older records still has `noProfessions = true`.
2. "Bren weekly reset and capped concentration". Weekly sources become available again while one-time sources stay done; the same flags taken at WS count. A character with no snapshot reads `unknown` and `knowledgeLeft = nil`.
3. "unknown concentration projection":
   - A capped pool gives `{1000, 1000, 0, fullAt = NOW}`.
   - A `max` of 0 or nil gives nil.
   - Beyond the horizon, `fullAt` is nil.
   - GetPools passed to `PlanCalc.CapWarnings` gives "capped" for Bren. The unknown pool has nil value and max, and `PlanCalc.Schedule` schedules nothing from it.
4. "hidden", plus:
   - The flag is stored, the row is marked, the change is announced and it can be undone.
   - Hidden characters have no pools.
   - A non-string key is ignored.
   - While `dbIsNewer` is set, the hide is session-only and nothing is saved.
5. Review Focus 5:
   - With no Knowledge data, every summary is `noData` with nil counts (never 0), `knowledgeLeft` is nil and rows fall back to concentration/spec records.
   - A variant line with no sources is `noData`, and the row is `knowledgePartial` with `knowledgeLeft = 2`.
   - When no profession is "ok", `knowledgeLeft` is nil.

The other specs cover:
- ordering and ties
- the name and realm split
- unknown characters
- staleDays
- cooldown sorting
- missing moxie, spec and cooldowns
- no mutation of saved data
- source-state order
- the Darkmoon window, open or unknown (call errors, missing, `canaccessvalue`)
- WeekStart: from the API, the EU fallback, and the US fallback when the call errors, returns nil or returns a secret value
- GetPools: dropped records and records with no snapshot
- the ProfessionName chain
- a dbIsNewer read-only spec

## TDD evidence
- RED: `busted tests/alts/overview_spec.lua` gave `0 successes / 0 failures / 45 errors`, the first being `attempt to call method 'GetOverview' (a nil value)`.
- GREEN: `busted tests/alts/overview_spec.lua` gave `45 successes / 0 failures / 0 errors / 0 pending`.
- RED (collector minor): `busted tests/alts/collector_spec.lua` failed "keeps a known source text when the client now gives none". It expected `sourceText = 'Vendor: Smith'` and got `''`.
- GREEN: `busted tests/alts` gave `94 successes / 0 failures / 0 errors / 0 pending`.
- Full suite: `busted` gave `1920 successes / 0 failures / 0 errors / 0 pending`. `luacheck .` gave `0 warnings / 0 errors in 137 files`.

## Files changed
- Modules/Alts.lua
- Modules/AltsCollector.lua
- tests/alts/overview_spec.lua (new)
- tests/alts/collector_spec.lua
- tests/helpers/phase3_fakes.lua
- docs/superpowers/plans/2026-10-30-fs-interface-contract.md
- .superpowers/.../ingame-checklist.md (appended, not committed)

## Self-review findings and deviations
- The plan's AltRow never mentions `olderProfessions` or `flags.knowledgePartial`. They implement preflight row 9 and the Task 2 carry, and are documented in the contract.
- For Review Focus 5's "older than the client build", I read it as "the data has no source for this profession" (a profession newer than the data), which gives `noData`. A data build that merely differs from the client build does not make every summary `noData`; it would blank out data that is mostly still valid. The build is shown in the Planner header (Task 14).
- An unknown-concentration pool stays in GetPools with nil values instead of being dropped (design rule 6; the contract's Pool shape allows nil). The brief's fixture count (2) is unchanged.
- `Settings()` creates `settings.alts` lazily when the overview is read. This is the existing SettingsAccessor pattern, and it writes nothing while `dbIsNewer` is set (covered by a spec).
- A missing `lastSeen` counts as stale, because an unknown age is not shown as fresh.
- `GetOverview` and `GetAltRow` also return data while Alts is disabled. The views own the "Alts is turned off" state (Task 6 carry).
- The tests set `_G.canaccessvalue` directly, and the stubs do not track that global. An `after_each` clears it.

## Concerns
- These steps cannot run in this environment and are on the checklist:
  - the real reset time and calendar field types
  - whether `canaccessvalue` blocks calendar fields in Midnight
  - whether a real AltRow matches the profession UI
