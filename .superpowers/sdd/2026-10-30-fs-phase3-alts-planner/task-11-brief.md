### Task 11: Planner specialization advice

**Files:**
- Create: `Modules/PlannerSpec.lua`
- Modify: `Modules/Recipes.lua` (1b — the `opts.extraStats` hook, Step 4)
- Test: `tests/planner/spec_advice_spec.lua`, `tests/recipes/extra_stats_spec.lua`

**Interfaces:**
- Consumes: `Alts:GetSpecSnapshot` (Task 6; display ranks), `Scanner:GetProfession(charKey, sl).spec` (1a: `paths[pathID].spendEntryID`, `perks[perkID] = { entryID, unlockRank, pathID }`), `ns.GameData.Get("SpecEntryEffects")` (1a: `[traitNodeEntryID] = { effects = { { type, amount } }, labels = { labelID... } }`), `ns.GameData.Get("RecipeLabels")` (1a: `[recipeSpellID] = { labelID... }`), `ns.CraftingData.EFFECT_MAP` (1b: effect `type` → stat key; 1b Task 9 adds the Ingenuity `type<N>`), `Recipes:GetRanked({ charKey, skillLineID, onlyProfitable = true, sortBy = "profit" })`, `Recipes:Evaluate(recipeID, charKey, { extraStats = bonus })` (the hook this task adds), `PlanCalc.RankSpecNodes`.
- Produces: `Planner:GetSpecAdvice(charKey, skillLineID) -> { SpecAdviceRow }` (max 5 rows); private `Planner:_nodeBonus(charKey, skillLineID, pathID, fromRank, toRank) -> { skill?, multicraft?, resourcefulness?, ingenuity?, recipes = {[recipeID]=true}|nil }` (raw ProfessionEffect amounts; nil `recipes` = all recipes of the skill line); private `Planner:_evaluateWithBonus(recipeID, charKey, bonus) -> RecipeResult` (= `Recipes:Evaluate(recipeID, charKey, { extraStats = bonus })`); **1b addition**: `Recipes:Evaluate` `opts.extraStats` (Contract additions).

Why the hook: 1b's `Recipes:Evaluate` builds Math input from the character's calibration record (`baseSkill`/`stats` measured live, so current spec is already baked in) or the Scanner skill, and neither 1b's Math nor `CraftingData` reads spec GameData — there is no way to ask "what if this path had 5 more ranks". Rather than re-assembling Math inputs in phase 3, the bonus is passed to Evaluate and fed through 1b's own optional-reagent path (`Stats.ApplyOptionals` adds `skill` and converts ratings with `Stats.RATING_PER_UNIT`), so Math is unchanged.

- [ ] **Step 1: Write the failing tests** (Aria fixture: `GetSpecSnapshot` gives unspent 4, paths `1 = {name="Path 1", rank=10, maxRank=30, available=true, perkRanks={15}}`, `2 = {name="Path 2", rank=0, maxRank=20, available=true, perkRanks={}}`, `3 = {name="Path 3", rank=5, maxRank=10, available=false, perkRanks={}}`; ranked profitable `1001` profit 5000 and `1002` profit 1000; stubs on the module table:)

```lua
PL._nodeBonus = function(_, charKey, sl, pathID) return pathID == 1 and {skill = 5, recipes = {[1001] = true}} or {multicraft = 10} end
PL._evaluateWithBonus = function(_, recipeID, charKey, bonus)
  local base = ({[1001] = 5000, [1002] = 1000})[recipeID]
  return {recipeID = recipeID, charKey = charKey, profit = base + (bonus.skill and 2500 or 500), flags = {}}
end
it("ranks next nodes by profit gain per point", function()
  local rows = PL:GetSpecAdvice("Aria-Silvermoon", 2907)
  assert.same({1, "Path 1", 5, 2500, 500, false},  -- 5 points needed, 4 unspent {rows[1].pathID, rows[1].name, rows[1].points, rows[1].gain, rows[1].gainPerPoint, rows[1].affordable})
  assert.same({2, 5, 1000, 200}, {rows[2].pathID, rows[2].points, rows[2].gain, rows[2].gainPerPoint})
  assert.equal(2, #rows)
end)
it("no snapshot or no profitable recipes -> empty", function()
  assert.same({}, PL:GetSpecAdvice("Bren-Silvermoon", 2912))
end)
```

- [ ] **Step 2: Run** — `busted tests/planner/spec_advice_spec.lua` → FAIL.

- [ ] **Step 3: Implement `GetSpecAdvice`.** Candidates from the snapshot paths (`pathID` = key, `name` from the snapshot); `gainFn(pathID, from, to)`: `bonus = self:_nodeBonus(charKey, skillLineID, pathID, from, to)`; Σ over the top `specTopRecipes` profitable results for (charKey, skillLineID) that the bonus applies to (`bonus.recipes == nil or bonus.recipes[r.recipeID]`) of `max(0, (_evaluateWithBonus(r.recipeID, charKey, bonus).profit or r.profit) - r.profit)`; return `PlanCalc.RankSpecNodes(candidates, gainFn, snapshot.unspent)` truncated to 5.

- [ ] **Step 4: Add `opts.extraStats` to 1b's `Recipes:Evaluate` (`Modules/Recipes.lua`).** After `ns.CraftingData.BuildInput(...)` and before `ns.Math.Profit.EvaluateCraft(input)`, when `opts.extraStats` is a non-empty table, append `{ itemID = 0, price = 0, stats = opts.extraStats }` to `input.optionals` (a free pseudo-optional: `ApplyOptionals` adds `skill`, converts `multicraft/resourcefulness/ingenuity` ratings; price 0 adds no cost). Calls with `extraStats` neither read nor write the result cache; everything else (flags, `priceAgeDays`, cache key for normal calls) is unchanged. **Threading (1b final-fix note):** 1b's `full_opts(opts)` keeps only `targetQuality`, `useConcentration`, `providedReagents` and `ownedReagentsFree` and is what `evaluate`/`build` receive, so `extraStats` never reaches the evaluation on its own: read `opts.extraStats` in `Recipes:Evaluate` before `full_opts`, bypass the cache there, and pass it as an extra argument to the local `evaluate(recipeID, charKey, o, schematic)`, which appends the pseudo-optional to the `input` that `build` returns before `ns.Math.Profit.EvaluateCraft(input)`. Write `tests/recipes/extra_stats_spec.lua` on 1b's `make_world`:

```lua
describe("Recipes:Evaluate extraStats (phase 3 hook)", function()
  local ns, R
  before_each(function() ns = make_world({ last = "Modules/Recipes.lua", calibrate = { ["Main-Realm"] = { 9001 } } }); R = ns.FS:GetModule("Recipes") end)
  it("adds skill and stat ratings without cost or cache effects", function()
    local base = R:Evaluate(9001, "Main-Realm", { targetQuality = 1 })
    local more = R:Evaluate(9001, "Main-Realm", { targetQuality = 1, extraStats = { skill = 50, multicraft = 110 } })
    assert.equals(base.skill + 50, more.skill); assert.equals(base.reagentCost, more.reagentCost)
    assert.is_true(more.multicraftValue > base.multicraftValue)
    assert.equals(base, R:Evaluate(9001, "Main-Realm", { targetQuality = 1 }))      -- cached plain result untouched
  end)
end)
```

- [ ] **Step 5: Implement the adapters in `Modules/PlannerSpec.lua`.** `_evaluateWithBonus(recipeID, charKey, bonus)` = `ns.FS:GetModule("Recipes"):Evaluate(recipeID, charKey, { extraStats = { skill = bonus.skill, multicraft = bonus.multicraft, resourcefulness = bonus.resourcefulness, ingenuity = bonus.ingenuity } })`. `_nodeBonus(charKey, sl, pathID, fromRank, toRank)`: `spec = Scanner:GetProfession(charKey, sl).spec` (nil → `{}`); `E = ns.GameData.Get("SpecEntryEffects") or {}`; contributions = the path's `E[spec.paths[pathID].spendEntryID]` effects × `(toRank - fromRank)` (per-rank, **unverified**), plus, once each, `E[perk.entryID]` effects for every `spec.perks` entry with `perk.pathID == pathID` and `fromRank < perk.unlockRank <= toRank`. Each effect `type` maps through `ns.CraftingData.EFFECT_MAP` to `skill/multicraft/resourcefulness/ingenuity` (unmapped types ignored, as 1b does) and amounts are summed. `recipes`: nil when no contributing entry has `labels`; else the set of recipe IDs whose `ns.GameData.Get("RecipeLabels")[recipeID]` shares a label with them. Adapter test (add to `tests/planner/spec_advice_spec.lua`, env loads `Modules/CraftingData.lua` in `files`):

```lua
it("_nodeBonus reads 1a SpecEntryEffects for the path ranks and perks crossed", function()
  ns.GameData.Define("SpecEntryEffects", 70575, { [1000] = { effects = { { type = "skill", amount = 1 } }, labels = { 777 } },
    [9000] = { effects = { { type = "multicraft", amount = 30 }, { type = "type42", amount = 9 } }, labels = { 777 } } })
  ns.GameData.Define("RecipeLabels", 70575, { [1001] = { 777 }, [1002] = { 5 } })
  assert.same({ skill = 5, multicraft = 30, recipes = { [1001] = true } }, PL:_nodeBonus("Aria-Silvermoon", 2907, 1, 10, 15))
  assert.same({ skill = 4, recipes = { [1001] = true } }, PL:_nodeBonus("Aria-Silvermoon", 2907, 1, 10, 14))   -- perk at 15 not crossed
end)
```

  In game (Task 16 smoke): for one path, compare the next rank's tooltip bonus with `_nodeBonus(..., r, r + 1)`; if the spend entry's amount is already cumulative rather than per rank, use `amount(toRank) - amount(fromRank)` semantics instead and fix the test.

- [ ] **Step 6: Run** — `busted tests/planner tests/recipes` → PASS; `luacheck .` clean.

- [ ] **Step 7: Commit**

```bash
git add Modules/PlannerSpec.lua Modules/Recipes.lua tests/planner/spec_advice_spec.lua tests/recipes/extra_stats_spec.lua
git commit -m "feat: add specialization advice ranked by profit gain per point"
```


**Orchestrator notes (binding; win over the plan text):**
- Apply every preflight.md row naming Task 11 (row 27: Recipes `full_opts` has five keys incl. excludeWarband — read opts.extraStats before full_opts, bypass the cache on lookup AND store, pass as the 5th arg to evaluate, append after build; fix the contract note to 5 keys; TOC adds Modules\PlannerSpec.lua here).
- Unknown spec gains stay nil and sort last (Task 3 RankSpecNodes behaviour); the UI will show "?". Getters return `rows, status` like Tasks 9/10 (document statuses).
- `Recipes:Evaluate` with extraStats must not pollute the normal result cache — add a spec that a normal Evaluate after a what-if returns the cached non-what-if result.
- Ingenuity mapping is unavailable (phase 1b Task 9 deferred) — leave ingenuity stats out of the what-if and say so in the contract/report.
- Task 10 minors folded in (Modules/Planner.lua, tests): skip the cap-warning chat announcement when PLAYER_ENTERING_WORLD reports isReloadingUi (still unregister); make the PlanCalc fallback-rank test discriminate (expected-cost-0/nil result must win by gpc); add a spec where GetRanked ignores the charKey filter and returns another character's result → Planner's own guard drops it.
