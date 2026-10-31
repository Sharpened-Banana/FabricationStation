# Task 8 report: Recipes:Evaluate, cache, WhoCanCraft, FindRecipesForItem

Status: DONE_WITH_CONCERNS (all green; the concerns are judgment calls listed below)

## Commits
- 8c283e2 fix: never mark professions dropped from an empty GetProfessions answer or a non-positive parent (carried A)
- cbc77bf feat: add CraftingData.BuildInput and guard reagent-info and threshold edge cases (BuildInput, carried C, F)
- 00dd32f feat: add Recipes:Evaluate with flags, caching, WhoCanCraft and item lookup (B, D, E, G, H)
- 0b53438 docs: record Evaluate flags, BuildInput optionals and item lookup in the interface contract

## What I built
- **Scanner (A)**: `known_base_lines` returns nil when `GetProfessions()` reports no profession at all, so nothing gets marked. `apply_profession_info` stores `parentSkillLineID` only when `parentProfessionID` is a positive number; otherwise it keeps the old value.
- **CraftingData.BuildInput(gd, args)** builds a RecipeInput as the brief describes:
  - With a calibration it uses the calibration's baseSkill, baseDifficulty (the schematic's when the calibration has none), maxReagentSkill and a copy of its stats. Without one it uses `professionSkill`, the schematic's difficulty, `maxReagentSkill = nil` and empty stats.
  - craftingDataID is the calibration's, else `CraftingDataIDFor`. The curve and threshold fractions come from it.
  - Only basic slots with non-empty `reagents` become slots. Each slot's weight is `ReagentWeight` of its first reagent, and its items carry rank, price, owned and provided.
  - It also fills yield, output prices, useConcentration and targetQuality.
  - A non-number maxQuality becomes nil.
  - **F**: when `optionalItemIDs` is given (a list, possibly empty), `optionals` lists every item of every optional and finishing slot. Each entry carries its `OptionalStats` (with the slot's kind) and a price. The price is 0 when owned plus provided cover the slot's quantity, and nil when some copies must be bought and the item has no price. Without `optionalItemIDs`, `optionals = {}`, because `EvaluateCraft` (which `prepare(input, nil)` feeds) applies every listed optional.
- **C**: `ThresholdFractions` returns nil for a non-number maxQuality (before, it raised "for limit must be a number"). `AllocationFromReagentInfo` skips slots that have a `currencyID` or an empty `reagents` table. A slot with `reagents` missing entirely is still mapped, because the existing 1b specs use such slots.
- **Recipes:Evaluate(recipeID, charKey, opts)**:
  - Returns nil when the schematic is not cached. `charKey` nil means the current character.
  - Prices every reagent and output through `Prices:Get`. Owned counts (`bags + bank + reagentBank + warband` from `GetItemCount(itemID, charKey)`) are passed only when owned reagents are free (`opts.ownedReagentsFree`, else the 1a setting). `providedReagents` are always free.
  - Runs `Math.Profit.EvaluateCraft` and adds `recipeID`, `charKey`, `priceAgeDays` and normalized flags.
  - **E**: all seven flags (`noPrice, stalePrice, staleData, unknownRecipe, estimated, unreachableTarget, unknownOptional`) are always booleans.
  - `stalePrice` and `priceAgeDays` cover only the prices the chosen plan uses: reagents it buys beyond owned plus provided, and its own output.
  - `staleData` is set when there is no calibration, or the calibration time or the character's `lastSeen` is older than `staleCalibrationDays`.
  - **D**: `estimated` is set when there is no calibration, or when `Quality.Thresholds(...) == nil`. It is also set when maxQuality > 1 and GameData has no thresholds for the recipe (see concerns).
  - Professional skill for estimates is `skill + skillModifier`.
- **H**: without a calibration, the evaluation is still computed and flagged `estimated` and `staleData`.
- **B**: `WhoCanCraft` and the per-character recipe lookup that Evaluate's `unknownRecipe` uses skip `dropped` profession records. The lookup checks the schematic's skill line first, then any other current profession.
- **Cache**:
  - Key is `recipeID|charKey|serialize(opts with defaults filled)`. `serialize` is recursive with keys sorted (by type, then value). Provided counts that are not positive are dropped, so `{}` and nil give the same key.
  - An entry is valid while `Prices:GetVersion()` and `GetDataStamp(charKey)` are unchanged. The whole cache is cleared when the price version moves.
  - Entries computed with owned reagents free also store an item stamp: the character's "items" counter plus a warband counter. So a call with `opts.ownedReagentsFree = true` while the setting is off still recomputes after item changes. Without this, such a call would serve stale owned counts.
- **G**: an `FS_DATA_CHANGED` handler (registered in `OnEnable`) uses `bump_stamp`.
  - Every kind bumps that character's stamp, except the two below.
  - `"items"` bumps it only while the setting is on.
  - `"warband"` bumps every character (the scanned ones plus any already stamped), only while the setting is on.
  - A nil charKey is ignored.
- **FindRecipesForItem** uses a reverse index over `db.global.schematics`, sorted by recipeID and then quality. It returns copies. The index is marked dirty on `FS_DATA_CHANGED(_, "recipes")` and `FS_RECIPES_CHANGED`, and rebuilt on the next lookup.
- **PredictLive** runs `EvaluateAllocation` for the current character, using the same input building as Evaluate (with optional candidates). **FromCraftingReagentInfo** wraps `AllocationFromReagentInfo` over `Scanner:GetSchematic`.
- Helper: added `world.priceValues()` to `tests/helpers/crafting_world.lua`, which returns `{[itemID] = copper}`.
- Contract updated for the flag set, BuildInput optionals, the `estimated` and `staleData` definitions, Evaluate's nil and default behaviour, and the FindRecipesForItem ordering and rebuild.

## Deviation from the brief
- The brief's first Evaluate test asserts `assert.same` on exactly five flags. Carried item E requires every contract flag as a boolean, so the test asserts all seven (`unreachableTarget = false, unknownOptional = false` added). Every other brief value is kept verbatim: 120010, 6, priceAgeDays 1, 703, 314, 2000, the caching, WhoCanCraft, FindRecipesForItem and the reagent-info mapping.

## Tests
- New: `tests/crafting/build_input_spec.lua` (10), `tests/recipes/evaluate_spec.lua` (42, including `cache_key_distinguishes_providedReagents`, the stamp tests, the dropped/unknown recipe tests, the unsupported-maxQuality test, optionals and currency slots).
- Extended: `tests/crafting/crafting_data_spec.lua` (+2 for C), `tests/modules/scanner_professions_spec.lua` (+2 for A).
- Full suite: `busted` → 655 successes, 0 failures, 0 errors. `luacheck .` → 0 warnings / 0 errors in 70 files.

## TDD evidence
- A RED: `busted tests/modules/scanner_professions_spec.lua` → `36 successes / 2 failures` ("stores parentSkillLineID only when …": expected 164, got 0; "marks nothing when GetProfessions yields no professions at all": expected nil, got true). GREEN → `38 successes / 0 failures`.
- BuildInput / Evaluate RED: `busted tests/recipes/evaluate_spec.lua tests/crafting/build_input_spec.lua` → every BuildInput spec errored with `attempt to call field 'BuildInput' (a nil value)`, and the Evaluate specs failed with `attempt to call method 'Evaluate' / 'FindRecipesForItem' / 'WhoCanCraft' / 'PredictLive' / 'FromCraftingReagentInfo' (a nil value)`. GREEN: `busted tests/recipes tests/crafting` → `103 successes / 0 failures`.
- C: I wrote the specs right after the code change. To confirm they cover it, I ran them against HEAD's CraftingData.lua: `19 successes / 1 failure / 1 error` (the failure is the currency-slot mapping, the error is the nil-maxQuality `for` limit). With the new code: `21 successes`.

## Self-review findings and concerns
1. **An extra `estimated` condition.** `estimated` is also true when maxQuality > 1 and GameData has no thresholds for the recipe's crafting data, so the default fractions stand in. Because the shipped GameData is empty today, every evaluation in the real addon is flagged estimated until GameData is generated. I think that is honest ("estimates flagged"), but it goes beyond the brief's definition. Easy to drop if the controller disagrees.
2. **B and FindRecipesForItem.** FindRecipesForItem uses no per-character set: it is the contract's index over cached schematics, known or not. So "skip dropped" applies to WhoCanCraft and Evaluate. A caller wanting "craftable by my characters" combines FindRecipesForItem with WhoCanCraft.
3. **Time-based flags in cached results.** `staleData` depends on `Now()`, so a cached result can keep `staleData = false` past the threshold until the price version or data stamp moves. The RecipeScan rescans should keep this short. Not handled here.
4. **The owned-free item stamp** is an addition beyond the brief's stamp rules. GetDataStamp still follows G exactly; only owned-free cache entries also check the item counters.
5. **Optional pricing on owned optionals** happens only when owned counts are passed (owned free). The optionals' `price` is the slot total for the copies bought (quantity × unit), since Math.Profit treats `opt.price` as the whole cost.
6. **`queueUseWarband`** is not applied to Evaluate's owned counts. The brief says owned includes warband; that setting is for the queue.

---

## Fix round 1 (commit 7b74d6c)

**Status:** DONE. One `fix:` commit covers all five review findings.

### Changes
1. **Schematic changes now invalidate the cache (Important).** `Evaluate` fetches `Scanner:GetSchematic(recipeID)` once per call and returns nil before any cache lookup when there is none. It passes that same schematic to `evaluate` and `build`. Each cache entry now also stores the schematic table and its `build` and `time`. A lookup is a miss when any of the three differ from the current schematic. This covers every character, because the schematic is shared and the check does not depend on any character's data stamp.
2. **Time-based fields no longer freeze (Minor).** Cache entries store `day = floor(Now() / 86400)`, and a different day is a miss. So `staleData` and the price-age fields are recomputed at least once a day.
3. **No-quality recipes are never estimated for missing thresholds (Ruling).** `noThresholds` and `defaultThresholds` apply only when `(maxQuality or 1) > 1`. A recipe with `maxQuality` nil, 0 or 1 is never flagged `estimated` for missing thresholds.
4. **Stamps test (Minor).** The "ignores a message without a character" test now also asserts that neither character's stamp moved.
5. **Optional pricing test (Minor).** New build_input case: optional slot quantity = 2 gives prices 2000 and 4000 (unit prices 1000 and 2000). With 1 owned it gives 1000, and with 2 provided it gives 0. This distinguishes slot-total pricing from unit pricing.
6. **Contract.** Updated with the extra cache invalidation rules and the no-quality ruling.

### Covering tests
New tests in `tests/recipes/evaluate_spec.lua`:
- "recomputes when the shared schematic is replaced, for every character" — the reviewer's exact scenario: Alt-Realm, the schematic replaced with `baseDifficulty = 1400`, then `FS_DATA_CHANGED("Main-Realm", "recipes")`. The next result is a new table with difficulty 1400.
- "recomputes when the same schematic table is re-stamped with a new build or time".
- "recomputes after a day boundary so time-based flags do not freeze" — `W.now + 86400` flips `staleData` to true.
- "never flags a no-quality recipe (maxQuality 0, 1 or nil) as estimated for missing thresholds".

Extended:
- `tests/recipes/evaluate_spec.lua`: "ignores a message without a character" now checks both stamps.
- `tests/crafting/build_input_spec.lua`: "prices an optional for the copies the slot still needs, not one unit".

### RED
Command: `busted tests/recipes/evaluate_spec.lua tests/crafting/build_input_spec.lua`

Output: `53 successes / 4 failures / 0 errors`

The four failures were evaluate_spec @116 (no-quality estimated), @188 (schematic replaced), @199 (re-stamped schematic) and @206 (day boundary).

The stamps-assert extension and the build_input quantity-2 case passed already. They add coverage and needed no code change.

### GREEN
- `busted tests/recipes tests/crafting` → `108 successes / 0 failures / 0 errors`
- `busted` → `660 successes / 0 failures / 0 errors`
- `luacheck .` → `0 warnings / 0 errors in 70 files`

### Concerns
Fix round 1 resolves concerns 3 (time-based flags) and 5's test gap from the first report.
