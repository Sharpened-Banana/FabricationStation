### Task 5: Math.Optimizer

**Files:**
- Create: `Math/Optimizer.lua`
- Modify: `FabricationStation.toc`
- Test: `tests/math/optimizer_spec.lua`

**Interfaces:**
- Consumes: `Quality.Thresholds`, `Quality.RankFactor`, `Quality.DEFAULT_REAGENT_SKILL_FACTOR`.
- Produces: `ns.Math.Optimizer.Compositions(slot) -> { [units] = { cost, counts = {[rank] = n} } }` (units = `Σ 2·f(rank)·n` before weighting; cost `Σ max(0, n_rank − owned_rank − provided_rank) × price_rank`; an item with nil price is usable only up to `owned + provided`); `Optimizer.CheapestByQuality(input: RecipeInput) -> perQuality: { [q] = { allocation, reagentCost, skill } }, missingPrice: bool` (required slots only; unreachable qualities absent); `Optimizer.AllocationCost(slots, allocation) -> copper|nil`.

- [ ] **Step 1: Write the failing test**

```lua
local ns = load_files({}, { "Math/Quality.lua", "Math/Optimizer.lua" })
local O = ns.Math.Optimizer
local function slot(i, q, w, prices) local items = {}
  for r, p in ipairs(prices) do items[r] = { itemID = i * 1000 + r, rank = r, price = p or nil, owned = 0, provided = 0 } end  -- false = no price
  return { slotIndex = i, quantity = q, weight = w, items = items } end
local function input(baseSkill, slots) return { maxQuality = 2, baseDifficulty = 700, baseSkill = baseSkill, maxReagentSkill = 280, slots = slots } end
describe("Math.Optimizer", function()
  it("2-rank compositions", function()
    local c = O.Compositions(slot(1, 10, 48, {100, 300}))
    assert.equals(1000, c[0].cost); assert.equals(1400, c[4].cost); assert.equals(3000, c[20].cost)
  end)
  it("3-rank composition keeps the cheapest mix per unit count", function()
    local c = O.Compositions(slot(1, 4, 10, {10, 30, 45}))
    assert.equals(130, c[5].cost); assert.same({ [1]=1, [2]=1, [3]=2 }, c[5].counts)
  end)
  it("owned reagents are free up to their count", function()
    local s = slot(1, 10, 48, {100, 300}); s.items[2].owned = 5
    assert.equals(500, O.Compositions(s)[10].cost)
  end)
  it("cheapest allocation per reachable quality", function()
    local per = O.CheapestByQuality(input(500, { slot(1, 10, 48, {100, 300}), slot(2, 5, 32, {200, 300}) }))
    assert.equals(2000, per[1].reagentCost)
    assert.equals(3800, per[2].reagentCost); assert.equals(703, per[2].skill)
    assert.same({ {slotIndex=1,itemID=1001,quantity=3}, {slotIndex=1,itemID=1002,quantity=7},
                  {slotIndex=2,itemID=2001,quantity=1}, {slotIndex=2,itemID=2002,quantity=4} }, per[2].allocation)
  end)
  it("unreachable quality is absent", function()
    assert.is_nil(O.CheapestByQuality(input(400, { slot(1, 10, 48, {100, 300}), slot(2, 5, 32, {200, 300}) }))[2])
  end)
  it("unweighted_slot_fixed", function()
    assert.equals(100, O.CheapestByQuality(input(700, { slot(1, 2, 0, {500, 50}) }))[2].reagentCost)
  end)
  it("missing_rank_price", function()
    local per, missing = O.CheapestByQuality(input(500, { slot(1, 10, 48, {100, false}), slot(2, 5, 32, {200, 300}) }))
    assert.is_false(missing); assert.is_nil(per[2])           -- only 20 of 80 units left, 58 needed
    local _, missing2 = O.CheapestByQuality(input(500, { slot(1, 10, 48, {false, false}) }))
    assert.is_true(missing2)
  end)
  it("mixed_rank_slots", function()
    local per = O.CheapestByQuality(input(500, { slot(1, 10, 48, {100, 300}), slot(2, 4, 32, {10, 30, 45}) }))
    assert.is_table(per[2]); assert.is_true(per[2].skill >= 700)
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/math/optimizer_spec.lua`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement `Math/Optimizer.lua`**

Compositions enumerate rank counts summing to `quantity` (2 ranks: `quantity + 1` options; 3 ranks: `O(q²)`), keeping the cheapest per unit value. A slot with one item or weight 0 gets one composition (cheapest usable rank) at 0 units. Provided reagents (orders) fix their counts. Knapsack over weighted slots (weights ÷ their GCD; GCD 0 → 1):

```lua
-- Umax = Σ quantity_s * 2 * (weight_s / g); a composition's weighted units = cu * (weight_s / g)
local best, choice = { [0] = 0 }, {}
for s, sl in ipairs(weighted) do
  local nb, pick = {}, {}
  for u, c in pairs(best) do
    for cu, comp in pairs(sl.comps) do
      local nu, nc = u + cu * sl.w, c + comp.cost
      if nb[nu] == nil or nc < nb[nu] then nb[nu], pick[nu] = nc, { prev = u, comp = comp } end
    end
  end
  best, choice[s] = nb, pick
end
for q = 1, maxQuality do
  local need = (q == 1) and 0 or (thresholds[q - 1] - baseSkill)
  local uNeed = need <= 0 and 0 or (Umax > 0 and math.ceil(need * Umax / maxReagentSkill - 1e-9) or math.huge)
  -- answer = min cost over u >= uNeed in best; ties prefer larger u (more skill → cheaper concentration)
  -- rebuild counts by walking choice[] backwards from u; skill = baseSkill + maxReagentSkill * u / Umax
end
```

`maxReagentSkill` nil → `DEFAULT_REAGENT_SKILL_FACTOR × baseDifficulty`. Allocation rows in slot order then rank order, zero counts omitted; fixed slots included with their cost. CraftSim header comment (`Modules/ReagentOptimization/ReagentOptimization.lua`).

- [ ] **Step 4: Run test to verify it passes**

Run: `busted tests/math/optimizer_spec.lua`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add Math/Optimizer.lua tests/math/optimizer_spec.lua FabricationStation.toc
git commit -m "feat: add Math.Optimizer cheapest reagent allocation per quality"
```

---

