# Task 3 report: PlanCalc scheduler, cap warnings, spec ranking

Status: DONE. Base bf3f4d4, commit 8d5b0b5 `feat: add concentration scheduler, cap warnings and spec node ranking`.

## What was built (Modules/PlanCalc.lua, still pure: no WoW globals, no ns.FS)

- `PlanCalc.Schedule(pools, results, opts) -> { ScheduleRow }`: this follows the plan's algorithm, with the following changes:
  - **Preflight row 25 (binding):** `expectedGain = floor(crafts * gpc * expectedConcentrationCost)`. When `expectedConcentrationCost` is nil or not positive, the cost falls back to `concentrationCost`. `concentrationUsed` and the remaining pool still use the full `concentrationCost`, so every scheduled craft is affordable. Row 25 addresses only the gain, so I took the conservative choice for spending.
  - **Review focus 3:** a pool whose `value` is nil (projection unavailable) schedules nothing. The plan's `p.value or 0` is not used, so nil is never used in arithmetic. A capped pool schedules from its full value.
  - **Guards:** a result is used only if its `concentrationCost` is positive and its `goldPerConcentration` is positive and finite, so nil, NaN and inf are rejected by a type check rather than `or 0`. A result also needs a `charKey` and a `skillLineID`. A pool key that appears twice is scheduled once. With `opts`/`maxCraftsPerRecipe` nil or non-positive, there is no per-recipe cap (the plan's code would error on nil). A fractional cap is floored. Inputs are not mutated.
  - Rows sort by `fullAt` ascending with nil last, then gpc descending, `charKey`, `skillLineID` (added as a tie-break) and `recipeID`.
- `PlanCalc.CapWarnings(pools, now, withinSeconds)`: returns copies of the pools with `status` added.
  - Pools with a nil `value`, or a nil or non-positive `max`, are skipped. This matches preflight row 11, where `max <= 0` means unknown.
  - **Review focus 3:** a pool with `value >= max` is always listed as `"capped"`, even when `fullAt` is nil (the plan would have skipped it).
  - `"soon"` needs a numeric `fullAt` within `now + withinSeconds`. When `now` or `withinSeconds` is not a number, only capped pools are listed.
  - Sort order: capped first, then `fullAt` ascending, `charKey`, `skillLineID`. For valid data this matches the plan's order of `fullAt` then `charKey`, because capped pools have `fullAt <= now`.
- `PlanCalc.RankSpecNodes(candidates, gainFn, unspent)`: this follows the plan's rules (step to the next perk, otherwise +5, capped at `maxRank`), with the following changes:
  - **Review focus 3 / design rule 6:** an unknown gain (nil, NaN or inf) stays `gain = nil, gainPerPoint = nil` and the row is kept, sorted after the known gains. The plan used `gainFn(...) or 0` and dropped the row. Known gains `<= 0` are still dropped.
  - `affordable` is nil when `unspent` is not a number.
  - Candidates with a non-numeric `rank` or `maxRank` are skipped.
  - `perkRanks` may be nil or unsorted; the smallest perk rank above `rank` is used.
- Contract (`docs/superpowers/plans/2026-10-30-fs-interface-contract.md`, PlanCalc section): added the Pool/ScheduleRow/SpecAdviceRow shapes (`gain`, `gainPerPoint` and `affordable` may be nil) and the three functions, with the rules above.

## Tests

`tests/plancalc/schedule_spec.lua` has 34 specs. The plan's 5 specs are included verbatim in substance. The rest cover:
- the expected cost after ingenuity, and flooring
- a nil-value pool, and a capped pool
- skipped results (nil, 0, negative or NaN gpc; nil cost; unknownRecipe)
- matching results to pools by character and skill line
- tie-breaks, no cap, a fractional cap, and the leftover fit
- duplicate pools, no input mutation, and nil inputs
- for CapWarnings: copied fields, capped without `fullAt`, the skip rules, the window boundary, sorting, and a missing clock
- for RankSpecNodes: the arguments passed to `gainFn`, unsorted perks, a perk at the current rank or beyond `maxRank`, zero or negative gains dropped, unknown gain kept as nil, unknown `unspent`, unknown ranks, and pathID tie-breaks

### TDD evidence
- RED: `busted tests/plancalc/schedule_spec.lua` gave `0 successes / 0 failures / 32 errors`. Every error was "attempt to call field 'Schedule'/'CapWarnings'/'RankSpecNodes' (a nil value)".
- GREEN: `busted tests/plancalc/schedule_spec.lua` gave `32 successes / 0 failures / 0 errors`. Two specs were added after that (no clock, fractional cap): `busted tests/plancalc` gives `90 successes / 0 failures / 0 errors`.
- Full suite: `busted` gives `1793 successes / 0 failures / 0 errors / 0 pending`. `luacheck .` gives `0 warnings / 0 errors in 126 files`.

## Files changed
- Modules/PlanCalc.lua
- tests/plancalc/schedule_spec.lua (new)
- docs/superpowers/plans/2026-10-30-fs-interface-contract.md

## Self-review
- No nil reaches arithmetic: every numeric input goes through `isNumber`/`positive` (finite-number checks) before it is used, and comparator fallbacks are used only for ordering.
- No TOC or `.luacheckrc` change is needed, because PlanCalc is already listed (Task 1) and is linted as lua51.
- No in-game steps: the code is pure logic, so nothing was added to ingame-checklist.md.

## Concerns / deviations to confirm
1. RankSpecNodes keeps rows with an unknown gain (nil) instead of the plan's `or 0` followed by dropping them. This follows the dispatch's "unknown gain is nil, never 0" and design rule 6. Task 11's `gainFn` as planned never returns nil, so this only affects other callers. UIs need to show "?" for these rows.
2. Schedule deducts the full `concentrationCost` from the pool and uses the expected cost only for `expectedGain`. The alternative is to deduct the expected cost, which allows more crafts but may not be affordable in practice.
3. CapWarnings lists a capped pool that has no `fullAt`, and sorts capped pools before soon pools. Both go slightly beyond the plan text, to meet review focus 3.
