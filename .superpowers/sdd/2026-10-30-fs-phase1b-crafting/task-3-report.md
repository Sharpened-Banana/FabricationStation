# Task 3 report: Math.Concentration (+ Task 2 review extras)

Status: DONE_WITH_CONCERNS (one brief value was wrong, see Concerns)

## Commits
- 63de78f test: cover Predict edges, RankFactor single rank and threshold float noise
- (next) feat: add Math.Concentration cost curve, ingenuity and gold per point

## Built
- Math/Concentration.lua: BASE_INGENUITY_REFUND = 0.5, Cost (bracket + lerp verbatim from brief), Expected, GoldPerPoint; CraftSim attribution header; pure Lua, uses ns.Math.Round.
- FabricationStation.toc: Math\Concentration.lua after Math\Quality.lua.
- tests/math/concentration_spec.lua: the brief's 5 tests plus a nil-curve / difficulty 0 test (6 specs).
- Task 2 extras (Math/Quality.lua comment, tests/math/quality_spec.lua): Predict at threshold (250,500,5 -> 3,400,250), below threshold (249 -> 2,250,100), max quality; RankFactor(1,1)==0; a float-noise Thresholds/Predict test (100*0.29 = 28.999999999999996 -> {29}); Thresholds comment now cites 3*0.2 = 0.6000000000000001 and 100*0.29 (0.8*500 is exact).

## TDD
- RED: `busted tests/math/concentration_spec.lua` -> `1 error`, "failed to load Math/Concentration.lua: cannot open Math/Concentration.lua".
- GREEN: same command -> `5 successes / 0 failures` (6 after the extra spec).
- Quality extras: first run failed on my wrong expectations (see Concerns), fixed, then `9 successes / 0 failures`.
- Full: `busted` -> 507 successes / 0 failures / 0 errors; `luacheck .` -> 0 warnings / 0 errors in 58 files.

## Self-review
Return order of Predict confirmed: quality, nextThreshold|nil, lowerThreshold. All Cost expectations from the brief pass unchanged (edges 399/400/450 and 499/500 included).

## Concerns
- The task message said Predict(500, 500, 5) -> 5, nil, 400. The code returns 5, nil, 500: the lower threshold of the reached quality is thresholds[4] = 500 (400 is where quality 4 starts). The code is right and consistent with the existing {2, nil, 400} for Predict(400,400,2); I asserted 500.
- Predict(249,500,5) lower threshold is 100 (quality 2 starts at 100), asserted {2, 250, 100}.
