### Task 6: Math.Profit — EvaluateCraft and EvaluateAllocation

**Files:**
- Create: `Math/Profit.lua`
- Modify: `FabricationStation.toc`
- Test: `tests/math/profit_spec.lua`

**Interfaces:**
- Consumes: Tasks 2–5.
- Produces: `ns.Math.Profit.AH_CUT = 0.95`; `Profit.ExpectedSale(qualityChances, outputPrices, expectedYield) -> number|nil`; `Profit.EvaluateCraft(input: RecipeInput) -> MathResult`; `Profit.EvaluateAllocation(input, allocation, optionalItemIDs|nil) -> MathResult` (no optimisation; live prediction, golden fixtures, self-check).

Rules (spec §6.1):
- Optionals via `Stats.ApplyOptionals`: `skill = baseSkill + skillBonus + reagentSkill`, `difficulty = baseDifficulty + difficultyBonus`; thresholds use `difficulty` and `thresholdFractions`; the `maxReagentSkill` default uses `baseDifficulty`.
- Plain plans: one per reachable quality `q` (`Optimizer.CheapestByQuality`). Concentration plans: for each reachable `q < maxQuality`, quality `q + 1` at `Concentration.Cost(curve, skill_q, difficulty, less)`.
- Per plan: `reagentCost = required + optional cost`; `resourcefulnessValue = Stats.ResourcefulnessSaving(requiredCost, ...)`; `expectedSale = ExpectedSale({[q]=1}, outputPrices, ExpectedYield(...))`; `profit = expectedSale − (reagentCost − resourcefulnessValue)`; `multicraftValue = price_q × (expectedYield − baseYield) × AH_CUT`, `baseYield = (min + max) / 2`.
- `targetQuality` set → that quality's plan (concentration plan when `useConcentration`); if that quality is unreachable, the plan for the highest reachable quality is returned with `flags.unreachableTarget = true` (never an error; test `unreachable_target_returns_best_with_flag`); else the max-profit plan of the requested kind. Plans with nil profit never beat priced plans.
- `missingPrice = true` when any reachable quality's output price is nil or a required slot had no priced option; `profit`/`expectedSale` are nil only when the chosen plan's own output price is nil.
- `goldPerConcentration = GoldPerPoint(best concentration-plan profit, best plain-plan profit, Expected(cost, ingenuity, 0.5 + ingenuityExtra))`; `concentrationCost`, `expectedConcentrationCost`, `ingenuityValue = cost × ingenuity × (0.5 + extra)` describe that concentration plan; 0/nil when there is none or `curve` is nil.
- `concentrationCostForAllocation = Concentration.Cost(curve, skill, difficulty, less)` at the returned allocation's skill (0 at max quality, nil without curve).
- Copper outputs pass through `Round`.

- [ ] **Step 1: Write the failing test**

```lua
local ns = load_files({}, { "Math/Quality.lua","Math/Concentration.lua","Math/Stats.lua","Math/Optimizer.lua","Math/Profit.lua" })
local P = ns.Math.Profit
local MID = { constant = { {0,200},{1000,200} }, curve = { {0,2.35},{0.6,2.2},{0.8,1.1},{0.9999,1.0},{1.0,0} } }
local function slot(i, q, w, prices) local items = {}
  for r, p in ipairs(prices) do items[r] = { itemID = i * 1000 + r, rank = r, price = p or nil, owned = 0, provided = 0 } end
  return { slotIndex = i, quantity = q, weight = w, items = items } end
local function scenario(over) local t = { maxQuality = 2, baseDifficulty = 700, baseSkill = 500, maxReagentSkill = 280,
  slots = { slot(1,10,48,{100,300}), slot(2,5,32,{200,300}), slot(3,2,0,{500}) }, optionals = {},
  stats = { multicraft = 0.2, resourcefulness = 0.25, ingenuity = 0.2 }, yield = { min = 1, max = 1 },
  outputPrices = { [1] = 60000, [2] = 100000 }, concentration = { curve = MID, lessFactors = {} } }
  for k, v in pairs(over or {}) do t[k] = v end; return t end
describe("Math.Profit", function()
  it("picks the most profitable plan without concentration", function()
    local r = P.EvaluateCraft(scenario())
    assert.equals(2, r.expectedQuality); assert.same({ [2] = 1 }, r.qualityChances)
    assert.equals(4800, r.reagentCost); assert.equals(124450, r.expectedSale)
    assert.equals(360, r.resourcefulnessValue); assert.equals(120010, r.profit)
    assert.equals(29450, r.multicraftValue); assert.near(1.31, r.expectedYield, 1e-9)
    assert.equals(71895, r.perQuality[1].profit)
  end)
  it("prices the concentration alternative", function()
    local r = P.EvaluateCraft(scenario())
    assert.equals(314, r.concentrationCost); assert.near(282.6, r.expectedConcentrationCost, 1e-9)
    assert.near(31.4, r.ingenuityValue, 1e-9); assert.equals(6, r.goldPerConcentration)    -- (121675 − 120010) / 282.6
  end)
  it("uses concentration when asked", function()
    local r = P.EvaluateCraft(scenario({ useConcentration = true }))
    assert.equals(2, r.expectedQuality); assert.equals(3000, r.reagentCost); assert.equals(121675, r.profit)
  end)
  it("honours targetQuality", function() assert.equals(71895, P.EvaluateCraft(scenario({ targetQuality = 1 })).profit) end)
  it("missing output price is flagged, never zero", function()
    local r = P.EvaluateCraft(scenario({ outputPrices = { [1] = 60000 } }))
    assert.equals(1, r.expectedQuality); assert.is_true(r.missingPrice)
    local r2 = P.EvaluateCraft(scenario({ outputPrices = {} }))
    assert.is_nil(r2.profit); assert.is_true(r2.missingPrice)
  end)
  it("EvaluateAllocation predicts a given allocation", function()
    local r = P.EvaluateAllocation(scenario(), { {slotIndex=1,itemID=1002,quantity=10}, {slotIndex=2,itemID=2002,quantity=5}, {slotIndex=3,itemID=3001,quantity=2} })
    assert.equals(780, r.skill); assert.equals(2, r.expectedQuality); assert.equals(5500, r.reagentCost)
    assert.equals(0, r.concentrationCostForAllocation)
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/math/profit_spec.lua`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement `Math/Profit.lua`** following the rules above.

- [ ] **Step 4: Run all math specs and the purity check**

Run: `busted tests/math && luacheck Math && grep -nE "C_[A-Za-z]+|ns\.FS|_G\b|GetServerTime" Math/*.lua`
Expected: PASS; 0 warnings; grep prints nothing.

- [ ] **Step 5: Commit**

```bash
git add Math/Profit.lua tests/math/profit_spec.lua FabricationStation.toc
git commit -m "feat: add Math.Profit expected profit and concentration evaluation"
```

---

