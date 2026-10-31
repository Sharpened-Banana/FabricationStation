# Task 1 report: CraftingData adapter over 1a GameData

## Built
- `Modules/CraftingData.lua` (`ns.CraftingData`, pure): `ReagentWeight`, `Curve`, `ThresholdFractions`, `CraftingDataIDFor`, `EFFECT_MAP`, `OptionalStats`, `AllocationFromReagentInfo`, all per the brief.
- TOC: added `Modules\CraftingData.lua` after `Modules\Diagnostics.lua`. `.luacheckrc`: added `files["Modules/CraftingData.lua"] = { std = "lua51" }` (verified: a `GetServerTime()` added to the file is flagged as an undefined variable).
- `tests/crafting/crafting_data_spec.lua`: the brief's 6 tests verbatim plus 13 more (19 total).

## Check against real 1a code
GameData.Define/Get and the generator shapes (`tools/gamedata/transforms.lua`: reagentQuality, reagentCategories, optionalReagents, craftingData, itemCraftingData, qualityThresholds, concentrationCurves) match the brief and the contract. No shape differences. `Get(name)` returns nil for an undefined name; checked-in tables are `Define(name, nil, {})`, so every access goes through a `tbl(gd, name)` helper that yields an empty table for a nil registry, a missing `Get`, a nil table, or an empty table. Nothing errors in those cases.

## Decisions where the brief was silent (please review)
1. Float noise: `99.99 / 100` is 0.99989999999999989999, not the literal 0.9999 the brief's test expects (RED showed the single mismatch). x/100 is rounded to 12 significant digits (`tonumber(string.format("%.12g", x/100))`) in both `Curve` and `ThresholdFractions`. Game data is decimal, so this loses nothing.
2. `Curve` returns nil when the skill curve has no points (the generator leaves out a difficulty only when both curves are empty, so one can be empty). An empty difficulty curve gives `constant = {}`. Points are copied, so GameData is never aliased or mutated.
3. `OptionalStats` finishing scale: effects scale by `reagentEffectPct / 100` only when the item has a positive percentage. A missing `ReagentQuality` row, or pct 0, leaves effects unscaled. Reason: scaling by a literal 0 would silently zero out a finishing reagent with no quality row. The brief's test (pct 50, so 30) is unaffected. `increasedifficulty` is not scaled.
4. `AllocationFromReagentInfo`: infos with an unknown `dataSlotIndex` or no `reagent.itemID` are skipped; any non-"basic" slot kind (optional, finishing) goes to `optionalItemIDs`, one entry per info regardless of quantity. Nil schematic/infos return two empty tables.
5. `CraftingDataIDFor`: a schematic's own `craftingDataID` wins even when GameData is empty; nil schematic or missing output item gives nil.
6. `ThresholdFractions(gd, id, 1)` returns `{}` (no tiers to cross); nil only when the crafting data, its threshold row or a tier in 2..maxQuality is missing.

## TDD evidence
- RED: `busted tests/crafting/crafting_data_spec.lua` before the file/TOC entry existed: `0 successes / 0 failures / 19 errors` ("lastFile not found in FabricationStation.toc: Modules/CraftingData.lua").
- Intermediate RED after the first implementation: one failure, the `Curve` deep-equal on `99.99/100` (see decision 1).
- GREEN: `busted tests/crafting/crafting_data_spec.lua` -> `19 successes / 0 failures / 0 errors / 0 pending`; `luacheck Modules/CraftingData.lua tests/crafting` -> 0 warnings.
- Full suite: `busted` -> `492 successes / 0 failures / 0 errors / 0 pending` (473 + 19). `luacheck .` -> `0 warnings / 0 errors in 54 files`.

## Files changed
- `Modules/CraftingData.lua` (new), `tests/crafting/crafting_data_spec.lua` (new), `FabricationStation.toc`, `.luacheckrc`.

## Self-review
Diff reviewed: no WoW globals, no `ns.FS`, no GameData mutation, no new globals. Brief's test count said "6 tests"; the spec has 19 because of the added edge/empty-data coverage.

## Concerns
None blocking. Decisions 2 and 3 are judgment calls later math tasks may want to revisit.
