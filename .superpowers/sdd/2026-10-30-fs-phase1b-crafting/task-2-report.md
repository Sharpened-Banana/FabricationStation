# Task 2 report: Math.Quality

## Built
- `Math/Quality.lua`: `ns.Math.Round`, `Quality.THRESHOLD_FRACTIONS`, `DEFAULT_REAGENT_SKILL_FACTOR = 0.40`, `Thresholds`, `Predict`, `RankFactor`, `ReagentSkill`. Pure Lua 5.1, CraftSim "Formula reference" header lines (RecipeInfo.lua, ReagentOptimization.lua, ReagentData.lua).
- `tests/math/quality_spec.lua`: the brief's 7 specs verbatim.
- `FabricationStation.toc`: `Math\Quality.lua` after `Data\GameData_Manual.lua`.

## TDD
- RED: `busted tests/math/quality_spec.lua` -> `failed to load Math/Quality.lua: cannot open Math/Quality.lua: No such file or directory` (1 error).
- GREEN: same command -> `7 successes / 0 failures / 0 errors / 0 pending`.
- Full: `busted` -> 499 successes / 0 failures / 0 errors; `luacheck .` -> 0 warnings / 0 errors in 56 files.

## Decisions beyond the brief
- `Thresholds` cuts `difficulty * fraction` to 12 significant digits (`%.12g`), same trick CraftingData uses, so float noise cannot push a threshold just above an integer skill. Not rounded to integers (a fractional threshold like 66.6 stays 66.6).
- `Predict` with an unsupported maxQuality and no fractions returns `1, nil, 0` (no error).
- `RankFactor` returns 0 when numRanks <= 1 and clamps rank into [1, numRanks]; `ReagentSkill` uses each item's `rank` field (not list position) and ignores allocation rows whose slot/item is unknown.
- `ReagentSkill` excludes weight-0 slots from the denominator (brief: Σ w·quantity, so identical result).
- Brief and plan agree; no conflicts with 1a code found. Specs live in `tests/math/` (new dir), picked up by the default busted root.

## Self-review
Diff checked: no WoW globals, no ns.FS; luacheck `files["Math/"]` std lua51 passes. No concerns.
