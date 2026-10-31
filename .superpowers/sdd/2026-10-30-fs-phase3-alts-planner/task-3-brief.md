### Task 3: PlanCalc scheduler, cap warnings, spec ranking

**Files:**
- Modify: `Modules/PlanCalc.lua`
- Test: `tests/plancalc/schedule_spec.lua`

**Interfaces:**
- Consumes: `RecipeResult` (contract) annotated with `skillLineID`; `Pool`.
- Produces: `PlanCalc.Schedule(pools, results, opts) -> { ScheduleRow }` (`opts = { maxCraftsPerRecipe }`); `PlanCalc.CapWarnings(pools, now, withinSeconds) -> { Pool + status = "capped"|"soon" }`; `PlanCalc.RankSpecNodes(candidates, gainFn, unspent) -> { SpecAdviceRow }` where `candidates = { { pathID, name, rank, maxRank, available, perkRanks } }`, `gainFn(pathID, fromRank, toRank) -> copper`.

- [ ] **Step 1: Write the failing tests**

```lua
local NOW = 1793361600
local function r(id, cost, gpc, flags) return {recipeID=id, charKey="A", skillLineID=2907,
  concentrationCost=cost, goldPerConcentration=gpc, profit=1, flags=flags or {}} end
it("greedy by gold/concentration with per-recipe cap", function()
  local rows = P.Schedule({{charKey="A", skillLineID=2907, value=1000, max=1000, fullAt=NOW}},
    {r(1,300,50), r(2,200,80), r(3,100,10), r(4,100,500,{noPrice=true}), r(5,0,90)}, {maxCraftsPerRecipe=3})
  assert.same({2,1,3}, {rows[1].recipeID, rows[2].recipeID, rows[3].recipeID})
  assert.same({3, 600, 48000}, {rows[1].crafts, rows[1].concentrationUsed, rows[1].expectedGain})
  assert.same({1, 300, 15000}, {rows[2].crafts, rows[2].concentrationUsed, rows[2].expectedGain})
  assert.same({1, 100, 1000}, {rows[3].crafts, rows[3].concentrationUsed, rows[3].expectedGain})
end)
it("most urgent pool first", function()
  local b = r(9,100,1); b.charKey = "B"
  local rows = P.Schedule({{charKey="A", skillLineID=2907, value=100, max=1000, fullAt=NOW+9000},
                           {charKey="B", skillLineID=2907, value=100, max=1000, fullAt=NOW+10}},
                          {r(1,100,99), b}, {maxCraftsPerRecipe=10})
  assert.same({"B","A"}, {rows[1].charKey, rows[2].charKey})
end)
it("CapWarnings", function()
  local w = P.CapWarnings({{charKey="C", value=500, max=1000, fullAt=NOW+2*86400},
    {charKey="S", value=900, max=1000, fullAt=NOW+3600}, {charKey="F", value=1000, max=1000, fullAt=NOW},
    {charKey="U", value=nil, max=nil}}, NOW, 86400)
  assert.equal(2, #w)
  assert.same({"F","capped"}, {w[1].charKey, w[1].status})
  assert.same({"S","soon"}, {w[2].charKey, w[2].status})
end)
it("RankSpecNodes steps to next perk, ranks per point", function()
  local gains = {[1] = 5000, [2] = 1000}
  local rows = P.RankSpecNodes({
    {pathID=1, name="Smelting", rank=10, maxRank=30, available=true, perkRanks={5,15,25}},
    {pathID=2, name="Weapons", rank=0, maxRank=20, available=true, perkRanks={}},
    {pathID=3, name="Locked", rank=0, maxRank=10, available=false, perkRanks={}},
    {pathID=4, name="Maxed", rank=10, maxRank=10, available=true, perkRanks={}},
  }, function(id, from, to) return gains[id] end, 5)
  assert.equal(2, #rows)
  assert.same({1, 5, 5000, 1000, true}, {rows[1].pathID, rows[1].points, rows[1].gain, rows[1].gainPerPoint, rows[1].affordable})
  assert.same({2, 5, 200, true}, {rows[2].pathID, rows[2].points, rows[2].gainPerPoint, rows[2].affordable})
end)
it("RankSpecNodes affordability", function()
  local rows = P.RankSpecNodes({{pathID=1, name="x", rank=0, maxRank=3, available=true, perkRanks={}}},
    function() return 30 end, 2)
  assert.same({3, 10, false}, {rows[1].points, rows[1].gainPerPoint, rows[1].affordable})
end)
```

- [ ] **Step 2: Run** — `busted tests/plancalc/schedule_spec.lua` → FAIL.

- [ ] **Step 3: Implement.** Scheduler algorithm (this is the decision; write it as below):

```lua
function P.Schedule(pools, results, opts)
  local byPool = {}
  for _, r in ipairs(results) do
    local f = r.flags or {}
    if (r.concentrationCost or 0) > 0 and (r.goldPerConcentration or 0) > 0 and not f.noPrice and not f.unknownRecipe then
      local k = r.charKey .. ":" .. r.skillLineID
      byPool[k] = byPool[k] or {}; table.insert(byPool[k], r)
    end
  end
  local rows = {}
  for _, p in ipairs(pools) do
    local list, left = byPool[p.charKey .. ":" .. p.skillLineID] or {}, p.value or 0
    table.sort(list, function(a, b)
      if a.goldPerConcentration ~= b.goldPerConcentration then return a.goldPerConcentration > b.goldPerConcentration end
      return a.recipeID < b.recipeID end)
    for _, r in ipairs(list) do
      local n = math.min(math.floor(left / r.concentrationCost), opts.maxCraftsPerRecipe)
      if n > 0 then
        local used = n * r.concentrationCost
        rows[#rows + 1] = { charKey = p.charKey, skillLineID = p.skillLineID, recipeID = r.recipeID, crafts = n,
          concentrationUsed = used, expectedGain = math.floor(used * r.goldPerConcentration),
          goldPerConcentration = r.goldPerConcentration, fullAt = p.fullAt }
        left = left - used
      end
    end
  end
  table.sort(rows, function(a, b)   -- soonest-capping pool first, then best gold/concentration
    local fa, fb = a.fullAt or math.huge, b.fullAt or math.huge
    if fa ~= fb then return fa < fb end
    if a.goldPerConcentration ~= b.goldPerConcentration then return a.goldPerConcentration > b.goldPerConcentration end
    if a.charKey ~= b.charKey then return a.charKey < b.charKey end
    return a.recipeID < b.recipeID
  end)
  return rows
end
```

  `CapWarnings`: skip pools with nil value/max/fullAt; include when `fullAt <= now + withinSeconds`; `status = value >= max and "capped" or "soon"`; sort by `fullAt` asc then charKey. `RankSpecNodes`: keep `available and rank < maxRank`; `toRank` = smallest perk rank `> rank`, else `min(maxRank, rank + 5)`; `points = toRank - rank`; `gain = gainFn(pathID, rank, toRank) or 0`; `gainPerPoint = floor(gain / points)`; `affordable = unspent >= points`; drop rows with `gain <= 0`; sort `gainPerPoint` desc then pathID asc.

- [ ] **Step 4: Run** — `busted tests/plancalc` → PASS; `luacheck Modules/PlanCalc.lua` clean.

- [ ] **Step 5: Commit**

```bash
git add Modules/PlanCalc.lua tests/plancalc/schedule_spec.lua
git commit -m "feat: add concentration scheduler, cap warnings and spec node ranking"
```


**Orchestrator notes:** apply the preflight.md rows that name Task 3 (binding). PlanCalc is pure: no WoW globals, no ns.FS.
