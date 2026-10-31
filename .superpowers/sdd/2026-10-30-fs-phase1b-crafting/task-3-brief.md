### Task 3: Math.Concentration

**Files:**
- Create: `Math/Concentration.lua`
- Modify: `FabricationStation.toc`
- Test: `tests/math/concentration_spec.lua`

**Interfaces:**
- Consumes: `ns.Math.Round`.
- Produces: `ns.Math.Concentration.BASE_INGENUITY_REFUND = 0.5`; `Concentration.Cost(curve|nil, skill, difficulty, lessFactors|nil) -> integer` (0 for nil curve); `Concentration.Expected(cost, ingenuityChance|nil, refundFraction) -> number`; `Concentration.GoldPerPoint(profitWith, profitWithout, expectedCost) -> integer|nil`.

- [ ] **Step 1: Write the failing test**

```lua
local ns = load_files({}, { "Math/Quality.lua", "Math/Concentration.lua" })
local C = ns.Math.Concentration
local MID = { constant = { {0,200},{1000,200} }, curve = { {0,2.35},{0.6,2.2},{0.8,1.1},{0.9999,1.0},{1.0,0} } }
local Q5  = { constant = { {0,150},{1000,150} }, curve = { {0,1.0},{0.1999,0.3},{0.2,1.75},{0.4999,0.7},{0.5,2.5},{0.7999,1.2},{0.8,3.25},{0.9999,1.7},{1.0,0} } }
describe("Math.Concentration", function()
  it("Midnight 2-quality curve, difficulty 400", function()
    for skill, cost in pairs({ [0]=470, [120]=455, [240]=440, [280]=330, [360]=210, [399]=200, [400]=0, [450]=0 }) do
      assert.equals(cost, C.Cost(MID, skill, 400), "skill " .. skill)
    end
  end)
  it("5-quality curve, difficulty 500", function()
    for skill, cost in pairs({ [50]=97, [175]=184, [250]=375, [300]=310, [400]=488, [499]=257, [500]=0 }) do
      assert.equals(cost, C.Cost(Q5, skill, 500), "skill " .. skill)
    end
  end)
  it("subtracts less-concentration factors before rounding", function() assert.equals(297, C.Cost(MID, 280, 400, {0.1})) end)
  it("ingenuity expectation", function() assert.equals(270, C.Expected(300, 0.2, 0.5)); assert.equals(300, C.Expected(300, nil, 0.5)) end)
  it("gold per point", function() assert.equals(333, C.GoldPerPoint(120000, 30000, 270)); assert.is_nil(C.GoldPerPoint(1, 0, 0)) end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/math/concentration_spec.lua`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement `Math/Concentration.lua`**

The bracket search and interpolation decide the edge values, so they are pinned here (CraftSim `FindBracketData` + `CalculateConcentrationCost`):

```lua
local function bracket(x, pts)                        -- pts sorted ascending by x
  for i = 1, #pts do
    if x >= pts[i][1] then
      local nxt = pts[i + 1]
      if not nxt then return pts[i], nil end
      if x <= nxt[1] then return pts[i], nxt end
    end
  end
end
local function lerp(p0, p1, x)
  if not p1 or p1[1] == p0[1] then return p0[2] end
  return p0[2] + (p1[2] - p0[2]) * (x - p0[1]) / (p1[1] - p0[1])
end
function Concentration.Cost(curve, skill, difficulty, lessFactors)
  if not curve or difficulty <= 0 then return 0 end
  skill = math.min(skill, difficulty)
  local s, e = bracket(skill / difficulty, curve.curve)
  s, e = s or { 0, 0 }, e or { 1, 1 }
  local c0, c1 = bracket(difficulty, curve.constant)
  local k = lerp(c0 or curve.constant[1], c1, difficulty)
  local value = lerp({ difficulty * s[1], s[2] }, { difficulty * e[1], e[2] }, skill)
  local cost = value * k
  local less = 0
  for _, f in ipairs(lessFactors or {}) do less = less + cost * f end
  return ns.Math.Round(cost - less)
end
```

`GoldPerPoint = Round((profitWith - profitWithout) / expectedCost)`, nil when `expectedCost <= 0`. CraftSim header comment.

- [ ] **Step 4: Run test to verify it passes**

Run: `busted tests/math/concentration_spec.lua`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Math/Concentration.lua tests/math/concentration_spec.lua FabricationStation.toc
git commit -m "feat: add Math.Concentration cost curve, ingenuity and gold per point"
```

---

