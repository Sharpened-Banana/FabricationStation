### Task 10: Planner concentration schedule and cap warnings

**Files:**
- Modify: `Modules/Planner.lua`
- Test: `tests/planner/schedule_spec.lua`

**Interfaces:**
- Consumes: `Alts:GetPools(now)`, `Recipes:GetRanked({ usesConcentration = true, sortBy = "goldPerConcentration" })`, `Scanner:GetSchematic(recipeID).skillLineID`, `PlanCalc.Schedule`, `PlanCalc.CapWarnings`.
- Produces: `Planner:GetSchedule(now) -> { ScheduleRow }`; `Planner:GetCapWarnings(now) -> { Pool + status }`; `Planner:AnnounceCapWarnings(now)` (chat, once per session).

- [ ] **Step 1: Write the failing tests** (ranked: `{recipeID=1001, charKey="Aria-Silvermoon", concentrationCost=200, goldPerConcentration=80, profit=5000, flags={}}`, `{1004, Aria, cost 100, gpc 500, flags={noPrice=true}}`, `{1099, Aria, cost 100, gpc 70}` with no schematic; schematics 1001/1004 → 2907)

```lua
it("schedule uses projected concentration and skips unpriced / unmapped", function()
  local rows = PL:GetSchedule(NOW)
  assert.equal(1, #rows)
  assert.same({"Aria-Silvermoon", 1001, 2, 400, 32000}, {rows[1].charKey, rows[1].recipeID, rows[1].crafts,
    rows[1].concentrationUsed, rows[1].expectedGain})
end)
it("cap warnings within setting", function()
  local w = PL:GetCapWarnings(NOW)
  assert.equal(1, #w); assert.same({"Bren-Silvermoon", 2912, "capped"}, {w[1].charKey, w[1].skillLineID, w[1].status})
  PL:Settings().capWarnHours = 72
  w = PL:GetCapWarnings(NOW)
  assert.same({"Bren-Silvermoon", "Aria-Silvermoon"}, {w[1].charKey, w[2].charKey})
end)
it("announces once per session", function()
  local printed = {}; ns.FS.Print = function(_, msg) printed[#printed + 1] = msg end
  PL:AnnounceCapWarnings(NOW); PL:AnnounceCapWarnings(NOW)
  assert.same({"Bren-Silvermoon Herbalism: concentration is full"}, printed)
end)
```

- [ ] **Step 2: Run** — `busted tests/planner/schedule_spec.lua` → FAIL.

- [ ] **Step 3: Implement.** Annotate each `RecipeResult` copy with `skillLineID` from its schematic (skip if none); results for hidden characters are dropped. Chat text: capped → `"<charKey> <ProfessionName>: concentration is full"`; soon → `"<charKey> <ProfessionName>: concentration full in <FormatDuration(fullAt - now)>"` (use `ns.UI.CharactersView.FormatDuration` if loaded, else whole hours `"<n>h"`). `AnnounceCapWarnings` is called from `PLAYER_ENTERING_WORLD` (first time only, after a 10 s `C_Timer.After` so Scanner data is loaded) when `capWarnChat` is true.

- [ ] **Step 4: Run** — `busted tests/planner` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Modules/Planner.lua tests/planner/schedule_spec.lua
git commit -m "feat: add concentration scheduler and cap warnings to Planner"
```


**Orchestrator notes (binding; win over the plan text):**
- Apply every preflight.md row naming Task 10 (incl. row 25: Recipes RecipeResult field names — expectedConcentrationCost/concentrationCost/goldPerConcentration — and row 11: pools with max nil/<=0 are unknown).
- Pools come from Alts:GetPools() (hidden excluded; unknown-concentration pools carry value/max nil and must never reach arithmetic — PlanCalc already gates them). Getters return `rows, status` like Task 9 (status "ok" | "off" when Alts or Recipes is unavailable; document in the contract).
- Unknown gold values stay nil; cap warnings: capped first, then soon (Task 3 behaviour).
- Task 3 minors folded in (Modules/PlanCalc.lua): Schedule skips pools with max nil/<=0 like CapWarnings; greedy ranks recipes by gold per FULL concentration point spent (`goldPerConcentration * expectedCost / concentrationCost`, falling back to gpc when either cost is missing) and document it; add a cross-character test (vary charKey: a B result with only an A pool → nothing scheduled).
- Task 9 minor folded in (Modules/Planner.lua): split GetMissingRecipes status "noData" into "noData" (no recipe list exists for the line: "open this profession on any character") and "notScanned" (this character's record was never recipe-scanned: "open this profession on <char>"); check notScanned before the no-keys test; specs + contract.
- Planner caches nothing unless the plan requires it; if the schedule is expensive, cache with invalidation on FS_ALTS_CHANGED/FS_RECIPES_CHANGED/FS_PRICES_CHANGED and say so.
