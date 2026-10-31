# Task 1 report: PlanCalc time rules

Status: DONE_WITH_CONCERNS (only the in-game checks, preflight row 8)
Commit: 2d7ee93 feat: add PlanCalc weekly reset, Darkmoon window and time-to-full (on BASE d16d253)

## What was built

`Modules/PlanCalc.lua` (new, pure Lua 5.1, no WoW globals, no `ns.FS`): `ns.PlanCalc = ns.PlanCalc or {}` with
- `WeekStart(now, secondsUntilReset)` = `now + secondsUntilReset - 604800`.
- `FallbackWeekStart(now, regionID)`: US anchor 486000 (Tue 1970-01-06 15:00 UTC), EU anchor 532800 (Wed 1970-01-07 04:00 UTC), `anchor + floor((now - anchor)/604800)*604800`. Only regionID 3 uses EU. It carries the required comment "Used only when C_DateAndTime.GetSecondsUntilWeeklyReset is missing; US/EU times unverified against Blizzard docs."
- `DarkmoonWindow(now, cal)`: `firstSunday = ((monthDay - weekday) % 7) + 1`; open when firstSunday <= monthDay <= firstSunday + 6; `startTime = now - ((monthDay - firstSunday)*86400 + hour*3600 + minute*60)`. Returns `{isOpen = nil}` (unknown) when `cal` is nil, not a table, or lacks a numeric monthDay/weekday. hour/minute default to 0.
- `TimeToFull(project, now, horizon)`: default horizon 14 days; nil when `project(now)` returns a nil value **or nil max** (preflight row 11); 0 when value >= max; nil when not full at `now + horizon`; otherwise binary search on [0, horizon] until `hi - lo <= 60`, returns `hi` (never early). A nil value/max inside the search counts as "not full".

Other files:
- `.luacheckrc`: `files["Modules/PlanCalc.lua"] = { std = "lua51" }` (purity lint). Checked that it bites: piping PlanCalc plus `GetServerTime()` through `luacheck --filename Modules/PlanCalc.lua -` gives "accessing undefined variable GetServerTime".
- `FabricationStation.toc`: `Modules\PlanCalc.lua` after `Modules\Ledger.lua` (preflight row 1, so toc_spec stays green; Task 6 adds only Alts and AltsCollector).
- Interface contract: PlanCalc added to the purity sentence, to TOC group 6 (marked phase 3 Task 1), and a new "PlanCalc (phase 3, pure)" section with the four Task 1 signatures and their nil/0 rules.
- `ingame-checklist.md`: three T1 lines (weekday 1 = Sunday; US/EU fallback reset vs the API; Darkmoon opening/closing). That directory is git-ignored, so this change is on disk only, not in the commit.

## Preflight rows applied

- Row 1: TOC entry added in this task.
- Row 8: in-game steps go to ingame-checklist.md; status DONE_WITH_CONCERNS rather than BLOCKED. (The brief's "Task 6 step 6" is really Task 6 Step 5; the checklist lines stand on their own.)
- Row 11: the test fake uses Scanner's real step formula (`value + floor((t - time)/cycleSeconds)*perCycle`, capped only when max > 0) instead of the plan's linear fake. 1 point per 360 s gives the same 216000 s. TimeToFull returns nil when max is nil (tested).
- Row 15: `.luacheckrc` gets only the PlanCalc `files[...]` line. Task 1 reads no new WoW globals.
- Row 39: TOC, `.luacheckrc` and the contract were re-read before editing.

## Tests

`tests/plancalc/time_spec.lua`: 15 specs. They cover all of the plan's cases, plus: regionID 2 and nil fall back to US; the second before a reset maps to the previous week; Darkmoon boundaries (3rd closed, 4th 00:00 open with startTime = now, 10th 23:59 open, 11th closed); a month that starts on a Sunday; a calendar with no weekday or no monthDay counts as unknown; a nil max gives nil; a custom horizon works both ways (too short gives nil, an exact-horizon fill gives 3600000).

TDD evidence:
- RED: `busted tests/plancalc/time_spec.lua` → `0 successes / 0 failures / 1 error` — "failed to load Modules/PlanCalc.lua: cannot open Modules/PlanCalc.lua: No such file or directory".
- GREEN: `busted tests/plancalc/time_spec.lua` → `15 successes / 0 failures / 0 errors / 0 pending`.
- Full suite: `busted` → `1718 successes / 0 failures / 0 errors / 0 pending` (was 1703 + 15 new).
- Lint: `luacheck .` → `0 warnings / 0 errors in 124 files`; `luacheck Modules/PlanCalc.lua` → 0 / 0.

## Self-review

- PlanCalc touches only `math.floor`, `type` and its own locals. `ADDON_NAME` is unused, which the repo-wide ignore `211/ADDON_NAME` allows.
- `DarkmoonWindow` uses `cal` only for the date and `now` only to anchor startTime, which matches the plan. Darkmoon is assumed to start at 00:00 server time on the first Sunday; that is unverified and is on the checklist.
- `TimeToFull` assumes `project` is monotone, as the plan states. Scanner's projection is. When max is 0, value >= 0 returns 0, but Alts treats max <= 0 as "no concentration" before it calls TimeToFull (preflight row 11, Task 6/7).
- Files changed: Modules/PlanCalc.lua (new), tests/plancalc/time_spec.lua (new), .luacheckrc, FabricationStation.toc, docs/superpowers/plans/2026-10-30-fs-interface-contract.md; plus ingame-checklist.md (ignored, not committed).

## Concerns

- The US/EU fallback reset times, the Sunday = 1 weekday numbering and the Darkmoon 00:00 Sunday start are unverified without a client. They are listed in ingame-checklist.md.
