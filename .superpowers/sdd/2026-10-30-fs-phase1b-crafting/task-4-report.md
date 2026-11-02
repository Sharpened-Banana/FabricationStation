# Task 4 report: Math.Stats

## Built
`Math/Stats.lua` (pure Lua 5.1, CraftSim attribution header) with `MULTICRAFT_CONSTANTS`, `RESOURCEFULNESS_SAVE_FACTOR`, `RATING_PER_UNIT`, `ExpectedYield`, `ResourcefulnessSaving`, `ParseBonusStats`, `ApplyOptionals`. TOC line `Math\Stats.lua` added after `Math\Concentration.lua`.

Design notes:
- `ApplyOptionals(stats, optionals)` takes any list of `{ stats = { skill, increasedifficulty, multicraft, resourcefulness, ingenuity, reduceconcentrationcost } }`, so phase 3's pseudo-optional `{ itemID = 0, price = 0, stats = opts.extraStats }` works unchanged. nil/empty inputs return `{}, 0, 0, {}`. Input stats table is copied, never mutated; non-rating fields such as `multicraftExtra` are carried over; unknown stat keys are ignored; entries without `stats` are skipped.
- `ExpectedYield` returns `baseYield, 0` for nil or non-positive chance.
- `ParseBonusStats` returns `{}` for nil inputs, skips entries with no name or `ratingPct` 0/absent.
- Verified against CraftSim `Util/Const.lua`: MULTICRAFT_CONSTANTS (DEFAULT 2.5, 1->2.1, 2->1.83, 5->1.875) and BASE_RESOURCEFULNESS_AVERAGE_SAVE_FACTOR 0.30. The attribution cites `Util/Const.lua` for the constants; the plan names the multicraft function as `CALC:GetExpectedItemAmountMulticraft` and I could not locate its file, so it is cited by name only.

## TDD
RED: `busted tests/math/stats_spec.lua` -> `failed to load Math/Stats.lua: cannot open Math/Stats.lua` (1 error).
GREEN: `busted tests/math/stats_spec.lua` -> `6 successes / 0 failures / 0 errors`. (4 brief tests plus 2 extra: nil/empty handling; create-absent/sum/no-mutation/extras.)
Full: `busted` -> 513 successes / 0 failures; `luacheck .` -> 0 warnings / 0 errors in 60 files.

## Files
Math/Stats.lua, tests/math/stats_spec.lua, FabricationStation.toc.

## Concerns
None. Float-exact `assert.same` values in the brief (1.31, 5.51875, 3.425) pass as written.
