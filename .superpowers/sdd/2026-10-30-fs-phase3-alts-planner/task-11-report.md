# Task 11 report: Planner specialization advice (+ Recipes opts.extraStats, Task 10 follow-ups)

Status: DONE_WITH_CONCERNS. The concerns are in-game verification and data-semantics items that cannot be checked here.
BASE e75284d. Commits:
- 225a435 feat: add specialization advice ranked by profit gain per point
- d5a0c6c fix: skip the cap warning on /reload and tighten Planner schedule tests

## What was built

### Recipes:Evaluate opts.extraStats (Modules/Recipes.lua; preflight row 27)
- `Recipes:Evaluate` reads `opts.extraStats` **before** `full_opts`. Only a non-empty table counts; an empty or non-table value is a plain cached call.
- With extraStats, Evaluate returns `evaluate(recipeID, charKey, o, schematic, extraStats)` straight away. That call happens before the price-version check and the cache lookup, so the cache is bypassed on both lookup and store.
- The local `evaluate` takes extraStats as a 5th argument. After `build`, it appends `{ itemID = 0, price = 0, stats = extraStats }` to `input.optionals`, then calls `Profit.EvaluateCraft`. Flags, priceAgeDays and the other opts behave as in a plain call. Math is unchanged.

### Modules/PlannerSpec.lua (new; same Planner module object; TOC after Modules\Planner.lua)
- `Planner:GetSpecAdvice(charKey, sl) -> rows (max 5), status`.
  - Statuses, checked in this order: `off` (Alts or Recipes missing or off), `hidden`, `noProfession` (no record, a dropped record, or an unknown character), `noSpec`, `noRecipes`, `ok`.
  - Candidates come from the `Alts:GetSpecSnapshot` paths.
  - `gainFn` sums `max(0, whatIf.profit or r.profit - r.profit)` over the top `specTopRecipes` results of `GetRanked({charKey, skillLineID, onlyProfitable=true, sortBy="profit"})` that the bonus covers. Results from another charKey are dropped.
  - A bonus with no non-zero skill, multicraft or resourcefulness gives an **unknown gain (nil)**. RankSpecNodes sorts these last, and the UI shows "?". This is the case with the checked-in empty SpecEntryEffects, so advice is never shown as a misleading 0.
  - The result is memoised per (charKey, sl) on a key built from: specTopRecipes, unspent, the snapshot paths, `Recipes:GetDataStamp(charKey)`, `Prices:GetVersion()`, the identity of the SpecEntryEffects and RecipeLabels tables, and the top results' identity and profit (preflight row 30). The memo keeps the top result tables alive so their addresses cannot be reused.
- `Planner:_nodeBonus(...)`:
  - The spend entry's effects count once per rank, times (to − from).
  - Each crossed perk counts once, when `from < unlockRank <= to`.
  - Effect types map through `EFFECT_MAP`; unmapped types are ignored.
  - `recipes` is nil unless some contributing entry has `#labels > 0` (preflight row 29).
  - Returns `{}` when the record, path or data is missing.
- `Planner:_evaluateWithBonus(...)` calls `Recipes:Evaluate(..., { extraStats = { skill, multicraft, resourcefulness } })`. **Ingenuity is left out** (orchestrator note; EFFECT_MAP has no ingenuity mapping because 1b Task 9 was deferred, preflight row 28).

### Task 10 follow-ups (Modules/Planner.lua, tests)
- The PLAYER_ENTERING_WORLD handler takes `(_, _, isReloadingUi)`. It still unregisters, then returns without scheduling the announcement on a /reload.
- `tests/plancalc/schedule_spec.lua`: the fallback-rank test now includes a third result `z` with a known expected cost and a lower rate.
  - Mutation check: replacing `expectedCostOf(r)` in `rateOf` with `(r.expectedConcentrationCost or 0)` makes the new test fail (@91). The old test passed under that mutation.
- `tests/planner/schedule_spec.lua`: new spec where Recipes ignores the charKey filter (it filters by line only) and Bren also has a 2907 pool and result, with maxCraftsPerRecipe = 1.
  - Mutation check: removing Planner's `r.charKey == pool.charKey` guard makes it fail (duplicated rows).
  - My first version did not discriminate, because PlanCalc's own key grouping hid the bug. I fixed it before committing.

### Contract (docs/superpowers/plans/2026-10-30-fs-interface-contract.md)
- Replaced the "Note for phase 3 Task 11" with an as-built description of extraStats. It now says full_opts has **five** keys including excludeWarband (preflight row 27).
- Added GetSpecAdvice, `_nodeBonus` and `_evaluateWithBonus`, with statuses and memo.
- Planner header now mentions PlannerSpec.lua and the spec-advice memo.
- Added the isReloadingUi note to AnnounceCapWarnings and PlannerSpec.lua to the TOC list.

## Tests
- `tests/recipes/extra_stats_spec.lua`: 8 specs. They cover the brief's test, that a what-if run first is not stored, that what-if never reads the cache, resourcefulness, flags and opts kept, empty or non-table extraStats is a plain cached call, caller tables not modified, and nil without a schematic.
- `tests/planner/spec_advice_spec.lua`: 21 specs. They cover the brief's 3 tests, statuses, the top-N limit, the GetRanked filter, the other-character guard, a nil what-if profit, an unknown gain sorting last, max 5 rows, `affordable` nil, the memo (hit, invalidation on each input, per slot), empty labels, a perk crossed at a boundary, missing or damaged data, unmapped and ingenuity types, `_evaluateWithBonus` args without ingenuity, and an end-to-end run through real adapters and GameData.
- `tests/planner/schedule_spec.lua`: +3 (charKey-guard, /reload, initial login). `tests/plancalc/schedule_spec.lua`: 1 test strengthened.

### TDD evidence
- RED `busted tests/recipes/extra_stats_spec.lua` → `4 successes / 4 failures / 0 errors` (the extraStats tests failed: no skill change, cache shared).
- GREEN after the Recipes hook → `8 successes / 0 failures / 0 errors`.
- RED `busted tests/planner/spec_advice_spec.lua` → `0 successes / 0 failures / 21 errors` (`cannot open Modules/PlannerSpec.lua`).
- GREEN after PlannerSpec.lua → `21 successes / 0 failures / 0 errors`.
- RED `busted tests/planner/schedule_spec.lua` → `32 successes / 1 failure` (the /reload spec printed the warning).
- GREEN after the isReloadingUi skip → `busted tests/planner tests/plancalc` → `191 successes / 0 failures`.
- Final: `busted` → `2083 successes / 0 failures / 0 errors / 0 pending` (base 2051). `luacheck .` → `0 warnings / 0 errors in 145 files`.

## Files changed
- Modules/PlannerSpec.lua (new), Modules/Recipes.lua, Modules/Planner.lua, FabricationStation.toc
- docs/superpowers/plans/2026-10-30-fs-interface-contract.md
- tests/recipes/extra_stats_spec.lua (new), tests/planner/spec_advice_spec.lua (new), tests/planner/schedule_spec.lua, tests/plancalc/schedule_spec.lua
- .superpowers/sdd/.../ingame-checklist.md (3 T11 lines appended; git-ignored)

## Self-review findings
- Deviation from the brief: a bonus with no modelled stat gives gain **nil**, not 0. The brief's formula would give 0, and the row would be silently dropped (design rule 6, plus the orchestrator note "unknown spec gains stay nil and sort last"). A known bonus that covers none of the top recipes still gives 0 and is dropped.
- Deviation from the brief: `_evaluateWithBonus` leaves out `ingenuity`, as the orchestrator note requires. The brief's code passed it through.
- Deviation from the brief: `GetSpecAdvice` returns a second value (status), following the Task 9/10 getter pattern.
- Ordering: hidden is checked before the record, the same order as GetMissingRecipes.
- The phase3 fake Recipes has no GetDataStamp and the env has no Prices module. Both memo inputs are feature-tested, and the memo spec adds them to cover invalidation.

## Concerns
1. **Per-rank semantics of the spend entry are unverified.** The amount is multiplied by (to − from), so if the DB2 amount is cumulative, gains are overstated. In-game checklist T11 has the check and the fix.
2. **Unit of multicraft/resourcefulness amounts is unverified.** extraStats treats them as ratings (÷1100/÷900), the same as optional reagents. If SpecEntryEffects stores percent, the gains are off by that factor (checklist T11).
3. **Mixed label case.** If one contributing entry has labels and another has none, the brief's rule restricts the whole bonus to the labelled recipes, which undercounts the unlabelled entry's effect. A single bonus table cannot express per-entry scopes; this looks rare in practice (perks share their path's labels).
4. **Ingenuity effects are ignored.** A path whose only crossed effect is ingenuity shows gain "?". A path that mixes ingenuity with other stats undercounts.
5. **Advice is always empty here.** The checked-in SpecEntryEffects/RecipeLabels are empty, so every gain is nil ("?") in this environment. Real behaviour needs generated GameData.
6. Display vs raw perk ranks: `_nodeBonus` compares `perk.unlockRank` with the display ranks RankSpecNodes passes, consistent with GetSpecSnapshot's perkRanks. If unlockRank turns out to be on the raw scale (existing checklist line T6), both need the same −1.

---

## Fix round 1 (commit 10ca013)

### Changes
1. **(Important) Label scope is now per entry.**
   - `_nodeBonus` returns:
     - the top-level `skill/multicraft/resourcefulness`, which are the sums of the contributing entries that have no labels (missing or empty `labels`);
     - `scoped`, with one `{ stats..., labels = {[id]=true} }` part per labelled entry;
     - `recipes` as a coverage set: nil when an unlabelled entry contributes (or none does), otherwise the union of recipes whose RecipeLabels share a label with a scoped part.
   - An entry "contributes" only when it has a non-zero modelled stat. Entries with only unmapped effects are ignored.
   - `gainFn`, for each top result inside the coverage set, starts from the top-level stats and adds every scoped part whose labels intersect `RecipeLabels[r.recipeID]`. It evaluates only when the result is non-zero. Only the top recipes' labels are looked up.
   - `_nodeBonus` still scans RecipeLabels once per call, to build the coverage set the contract keeps.
   - `has_stat` checks both the top-level sums and the scoped parts.
   - `_evaluateWithBonus(recipeID, charKey, stats)` now takes the per-recipe stats.
2. **(Minor) Baseline.** The baseline is the cached plain `R:Evaluate(r.recipeID, charKey, {})`, falling back to `r.profit`. A nil what-if still counts as no change, so the what-if profit falls back to that baseline.
3. **(Minor) Missing labels read as unknown.**
   - A labelled-only bonus (coverage non-nil, with scoped parts) where none of the top recipes has a RecipeLabels entry now gives nil.
   - Once any top recipe has labels, the gain is a known value. If those labels differ, the gain is 0 and the row is dropped.
4. **(Minor) Real-adapter spec on the shipped empty tables.** Rows have nil gains, the status is "ok", and `Recipes:Evaluate` is called 0 times.
5. **(Minor) One shared constant.** `STATS = { "skill", "multicraft", "resourcefulness" }` (plus its `IS_STAT` set) is used by `entry_parts`, `nonzero`/`has_stat`, `stats_for` and `_evaluateWithBonus`. Adding "ingenuity" to it is the only change ingenuity needs.
- **Contract:** the GetSpecAdvice, `_nodeBonus` and `_evaluateWithBonus` entries are rewritten with the new shape, the baseline and the unknown rules.

### Tests (tests/planner/spec_advice_spec.lua: 21 → 28)
- The brief's `_nodeBonus` test is updated to the new shape. Both entries are labelled 777, so both land in `scoped`, with `recipes = {1001}`.
- New specs:
  - mixed `_nodeBonus`: `{ skill = 5, scoped = { { multicraft = 30, labels = {777} } } }`, with recipes nil;
  - mixed through GetSpecAdvice: 1001 gets `{skill=5, multicraft=30}` and 1002 gets `{skill=5}`;
  - different labels: with 888 skill and 777 multicraft, 1001 gets `{multicraft=30}` and 1002 gets `{skill=5}`, and the coverage is `{1001, 1002}`;
  - a labelled-only bonus with no top-recipe labels gives nil gain with 0 evaluations, then a known 0 (row dropped) once a top recipe has other labels;
  - baseline from the plain evaluation (a gain of 200, not 4200);
  - a nil plain profit falls back to the ranked profit;
  - real adapters on the shipped empty tables: nil gains, "ok", 0 Evaluate calls.

### RED/GREEN
- RED: the new spec file run against the previous `Modules/PlannerSpec.lua` (HEAD d5a0c6c) gives `busted tests/planner/spec_advice_spec.lua` → `22 successes / 6 failures / 0 errors` (@218 shape, @229 mixed, @237 mixed via advice, @253 different labels, @273 labelled-only unknown, @291 baseline).
- GREEN: `busted tests/planner tests/recipes tests/plancalc` → `411 successes / 0 failures`. Full `busted` → `2090 successes / 0 failures / 0 errors / 0 pending`. `luacheck .` → `0 warnings / 0 errors in 145 files`.

### Concerns
- Report concerns 3 (mixed label case) and 4 (labels part) are resolved.
- Still open: per-rank amount semantics, the rating unit, ingenuity being unmodelled, and empty GameData in this environment.
