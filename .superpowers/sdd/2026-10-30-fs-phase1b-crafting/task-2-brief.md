### Task 2: Math.Quality

**Files:**
- Create: `Math/Quality.lua`
- Modify: `FabricationStation.toc`
- Test: `tests/math/quality_spec.lua`

**Interfaces:**
- Consumes: nothing.
- Produces: `ns.Math.Round(x) -> integer`; `ns.Math.Quality.THRESHOLD_FRACTIONS = { [1] = {}, [2] = {1.0}, [3] = {0.5, 1.0}, [5] = {0.2, 0.5, 0.8, 1.0} }`; `Quality.DEFAULT_REAGENT_SKILL_FACTOR = 0.40`; `Quality.Thresholds(maxQuality, difficulty, fractions|nil) -> {number}|nil` (skill needed for qualities 2..max; nil for an unsupported maxQuality without fractions); `Quality.Predict(skill, difficulty, maxQuality, fractions|nil) -> quality, nextThreshold|nil, lowerThreshold`; `Quality.RankFactor(rank, numRanks) -> number`; `Quality.ReagentSkill(slots, allocation, maxReagentSkill) -> number` (unrounded).

- [ ] **Step 1: Write the failing test**

```lua
local ns = load_files({}, { "Math/Quality.lua" })
local Q = ns.Math.Quality
local A  = { slotIndex = 1, quantity = 10, weight = 48, items = { {itemID=11,rank=1},{itemID=12,rank=2},{itemID=13,rank=3} } }
local B  = { slotIndex = 2, quantity = 5,  weight = 32, items = { {itemID=21,rank=1},{itemID=22,rank=2},{itemID=23,rank=3} } }
local A2 = { slotIndex = 1, quantity = 10, weight = 48, items = { {itemID=11,rank=1},{itemID=12,rank=2} } }
local B2 = { slotIndex = 2, quantity = 5,  weight = 32, items = { {itemID=21,rank=1},{itemID=22,rank=2} } }
describe("Math.Quality", function()
  it("thresholds", function()
    assert.same({100, 250, 400, 500}, Q.Thresholds(5, 500))
    assert.same({350, 700}, Q.Thresholds(3, 700))
    assert.same({400}, Q.Thresholds(2, 400))
    assert.same({}, Q.Thresholds(1, 100))
    assert.is_nil(Q.Thresholds(4, 100))
    assert.same({360}, Q.Thresholds(2, 400, {0.9}))                -- GameData fractions win
  end)
  it("predict", function()
    assert.same({1, 400, 0},   { Q.Predict(399, 400, 2) })
    assert.same({2, nil, 400}, { Q.Predict(400, 400, 2) })
    assert.same({3, 400, 250}, { Q.Predict(260, 500, 5) })
    assert.same({1, 100, 0},   { Q.Predict(0, 500, 5) })
  end)
  it("rank factors", function()
    assert.equals(0, Q.RankFactor(1, 2)); assert.equals(1, Q.RankFactor(2, 2))
    assert.equals(0.5, Q.RankFactor(2, 3)); assert.equals(1, Q.RankFactor(3, 3))
  end)
  it("reagent skill, 3-rank (CraftSim header example)", function()
    assert.equals(280, Q.ReagentSkill({A, B}, { {slotIndex=1,itemID=13,quantity=10}, {slotIndex=2,itemID=23,quantity=5} }, 280))
    assert.equals(157.5, Q.ReagentSkill({A, B}, { {slotIndex=1,itemID=13,quantity=5}, {slotIndex=1,itemID=12,quantity=5}, {slotIndex=2,itemID=21,quantity=5} }, 280))
  end)
  it("reagent skill, Midnight 2-rank", function()
    assert.equals(196, Q.ReagentSkill({A2, B2}, { {slotIndex=1,itemID=12,quantity=6}, {slotIndex=1,itemID=11,quantity=4}, {slotIndex=2,itemID=22,quantity=5} }, 280))
  end)
  it("all weights zero gives 0, not NaN", function()
    local z = { slotIndex = 1, quantity = 2, weight = 0, items = { {itemID=1,rank=1},{itemID=2,rank=2} } }
    assert.equals(0, Q.ReagentSkill({z}, { {slotIndex=1,itemID=2,quantity=2} }, 100))
  end)
  it("rounds half up", function() assert.equals(263, ns.Math.Round(262.5)); assert.equals(262, ns.Math.Round(262.49)) end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/math/quality_spec.lua`
Expected: FAIL — `Math/Quality.lua` not found.

- [ ] **Step 3: Implement `Math/Quality.lua`**

`Predict` counts thresholds with `skill >= t`; `lowerThreshold` is the reached quality's threshold (0 for quality 1). `ReagentSkill` uses `numRanks = #slot.items`, ignores allocation rows for unweighted slots, returns `maxReagentSkill × Σ w·f·n ÷ Σ w·quantity` (0 when the denominator is 0). CraftSim header comment.

- [ ] **Step 4: Run test to verify it passes**

Run: `busted tests/math/quality_spec.lua`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Math/Quality.lua tests/math/quality_spec.lua FabricationStation.toc
git commit -m "feat: add Math.Quality thresholds, prediction and reagent skill"
```

---

