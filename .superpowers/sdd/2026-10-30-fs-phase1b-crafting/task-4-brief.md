### Task 4: Math.Stats

**Files:**
- Create: `Math/Stats.lua`
- Modify: `FabricationStation.toc`
- Test: `tests/math/stats_spec.lua`

**Interfaces:**
- Consumes: nothing.
- Produces: `ns.Math.Stats.MULTICRAFT_CONSTANTS = { default = 2.5, [1] = 2.1, [2] = 1.83, [5] = 1.875 }`; `Stats.RESOURCEFULNESS_SAVE_FACTOR = 0.30`; `Stats.RATING_PER_UNIT = { multicraft = 1100, resourcefulness = 900, ingenuity = 1000 }`; `Stats.ExpectedYield(baseYield, mcChance|nil, mcExtra|nil) -> expected, extraOnProc`; `Stats.ResourcefulnessSaving(requiredCost, resChance|nil, resExtra|nil) -> number`; `Stats.ParseBonusStats(bonusStats, names) -> { multicraft?, resourcefulness?, ingenuity? }` (fractions; `ratingPct` 0 or absent → nil = unsupported); `Stats.ApplyOptionals(stats, optionals) -> newStats, skillBonus, difficultyBonus, lessConcentrationFactors`.

- [ ] **Step 1: Write the failing test**

```lua
local S = load_files({}, { "Math/Stats.lua" }).Math.Stats
describe("Math.Stats", function()
  it("multicraft expected yield", function()
    assert.same({1.31, 1.55}, { S.ExpectedYield(1, 0.2, 0) })
    assert.same({5.51875, 5.1875}, { S.ExpectedYield(5, 0.1, 0) })
    assert.same({3.425, 4.25}, { S.ExpectedYield(3, 0.1, 0) })        -- default constant 2.5
    assert.near(1.415, (S.ExpectedYield(1, 0.2, 0.5)), 1e-9)
    assert.same({1, 0}, { S.ExpectedYield(1, nil) })
  end)
  it("resourcefulness saving", function()
    assert.equals(3000, S.ResourcefulnessSaving(40000, 0.25, 0))
    assert.near(3300, S.ResourcefulnessSaving(40000, 0.25, 0.1), 1e-9)
    assert.equals(0, S.ResourcefulnessSaving(40000, nil))
  end)
  it("parses bonus stats by localized name", function()
    local names = { multicraft = "Multicraft", resourcefulness = "Resourcefulness", ingenuity = "Ingenuity" }
    assert.same({ multicraft = 0.125, resourcefulness = 0.2, ingenuity = 0.08 }, S.ParseBonusStats({
      { bonusStatName = "Multicraft", ratingPct = 12.5 }, { bonusStatName = "Resourcefulness", ratingPct = 20 },
      { bonusStatName = "Ingenuity", ratingPct = 8 }, { bonusStatName = "Crafting Speed", ratingPct = 30 } }, names))
    assert.same({}, S.ParseBonusStats({ { bonusStatName = "Multicraft", ratingPct = 0 } }, names))
  end)
  it("applies optional reagent effects", function()
    local stats, skill, diff, less = S.ApplyOptionals({ multicraft = 0.2 },
      { { stats = { skill = 10, increasedifficulty = 35, multicraft = 110, reduceconcentrationcost = 10 } } })
    assert.equals(10, skill); assert.equals(35, diff); assert.near(0.3, stats.multicraft, 1e-9); assert.same({0.1}, less)
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/math/stats_spec.lua`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement `Math/Stats.lua`**

`ExpectedYield`: `C = MULTICRAFT_CONSTANTS[baseYield] or default`; `maxExtra = C × baseYield × (1 + extra)`; `extraOnProc = (1 + maxExtra) / 2`; `expected = baseYield + chance × extraOnProc`. `ApplyOptionals` copies `stats`, adds rating ÷ `RATING_PER_UNIT` (creating the stat if absent), sums `skill` and `increasedifficulty`, turns each `reduceconcentrationcost` amount into `amount / 100`. CraftSim header comment.

- [ ] **Step 4: Run test to verify it passes**

Run: `busted tests/math/stats_spec.lua`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Math/Stats.lua tests/math/stats_spec.lua FabricationStation.toc
git commit -m "feat: add Math.Stats multicraft, resourcefulness and optional reagent effects"
```

---

