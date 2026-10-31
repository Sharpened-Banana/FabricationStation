### Task 6: Ledger store, queries, weekly and per-recipe profit, benchmarks

**Files:**
- Create: `Modules/Ledger.lua`
- Modify: `FabricationStation.toc` (`Modules\Ledger.lua` after `Modules\Orders.lua`), `.luacheckrc` (`C_DateAndTime`)
- Test: `tests/ledger/ledger_spec.lua`

**Interfaces:**
- Consumes: `ns.FS:Now()`, `ns.FS:CharKey()`, `ns.Msg.LEDGER_CHANGED`; 1a default `db.global.ledger = { entries = {} }`; `C_DateAndTime.GetSecondsUntilWeeklyReset()`.
- Produces:
  - `Ledger:Settings()` with defaults `{benchmarkMinSamples = 3, keepDays = 365}` in `db.global.settings.ledger`.
  - `Ledger:Add(entry)` (contract; fills `time = Now()` and `charKey = CharKey()` when missing; rejects a `type` outside `craft|sale|commission` or a non-integer `amount` with `error`; sends `ns.Msg.LEDGER_CHANGED`).
  - `Ledger:Query(filter) -> {LedgerEntry}` (contract; `filter = {type?, since?, before?, recipeID?, charKey?, customer?}`; newest first).
  - `Ledger:Prune(now)`.
  - `Ledger:WeekStart(now) -> number`.
  - `Ledger:Weekly(now, weeks) -> { {weekStart, income, cost, profit, incomplete} }` (newest first).
  - `Ledger:ByRecipe(filter) -> { [recipeID] = {income, cost, profit, n, incomplete} }`.
  - `Ledger.Percentile(sorted, p) -> number`.
  - `Ledger:Benchmark(recipeID, quality) -> {median, p25, p75, n}|nil` (contract; `quality == nil` means all qualities).
- Profit rule: only `sale` and `commission` entries count. `income = amount`, `cost = entry.cost or 0`, and `incomplete` counts entries whose `cost == nil`. `craft` entries are cost-basis records and are excluded. NPC reward values are shown but are not gold income.
- `WeekStart(now) = now + GetSecondsUntilWeeklyReset() - 604800`.
- Percentile is linear interpolation on sorted values: `h = (n-1)p + 1`, and the result is rounded to an integer with `math.floor(x + 0.5)`. The benchmark uses the gross `tip` of commission entries and returns nil when `n < benchmarkMinSamples`.

- [ ] **Step 1: Write the failing tests**

```lua
local P2 = require("tests.helpers.phase2")
describe("Ledger store", function()
  local ns, L
  local W = 1495200   -- WeekStart(2000000) with 100000 s until reset
  before_each(function()
    ns = P2.boot({ C_DateAndTime = { GetSecondsUntilWeeklyReset = function() return 100000 end } })
    P2.load(ns, {"Modules/Ledger.lua"}); L = ns.FS:GetModule("Ledger")
  end)
  it("computes the weekly reset boundary", function() assert.equal(W, L:WeekStart(2000000)) end)
  it("aggregates weekly and per-recipe profit", function()
    L:Add({time=W+100, type="commission", amount=450000, cost=30000, recipeID=4444, tip=500000, quality=3})
    L:Add({time=W+200, type="sale", amount=950000, cost=150000, recipeID=4444, quantity=5})
    L:Add({time=W-100, type="sale", amount=100000, recipeID=5555, quantity=1})
    L:Add({time=W+300, type="craft", amount=-30000, recipeID=4444, quantity=2})
    assert.same({ {weekStart=W, income=1400000, cost=180000, profit=1220000, incomplete=0},
                  {weekStart=W-604800, income=100000, cost=0, profit=100000, incomplete=1} }, L:Weekly(2000000, 2))
    assert.same({ [4444] = {income=1400000, cost=180000, profit=1220000, n=2, incomplete=0},
                  [5555] = {income=100000, cost=0, profit=100000, n=1, incomplete=1} }, L:ByRecipe({}))
  end)
  it("queries newest first and rejects bad entries", function()
    L:Add({time=1, type="craft", amount=-1}); L:Add({time=2, type="sale", amount=5})
    assert.equal(2, L:Query({})[1].time); assert.equal(1, #L:Query({type="craft"}))
    assert.has_error(function() L:Add({type="loot", amount=1}) end)
    assert.has_error(function() L:Add({type="sale", amount=1.5}) end)
  end)
  it("benchmarks tips by percentile", function()
    for _, t in ipairs({300, 100, 400, 200}) do L:Add({type="commission", amount=t, tip=t, recipeID=4444, quality=3}) end
    assert.same({median=250, p25=175, p75=325, n=4}, L:Benchmark(4444, 3))
    assert.same({median=250, p25=175, p75=325, n=4}, L:Benchmark(4444, nil))
    assert.is_nil(L:Benchmark(4444, 2)); assert.is_nil(L:Benchmark(9999, 3))
  end)
  it("prunes entries older than keepDays", function()
    L:Add({time=2000000 - 366*86400, type="sale", amount=1}); L:Add({time=2000000 - 10, type="sale", amount=1})
    L:Prune(2000000); assert.equal(1, #L:Query({}))
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted tests/ledger/ledger_spec.lua`
Expected: FAIL (`Modules/Ledger.lua` not found)

- [ ] **Step 3: Implement the `Ledger` functions listed under Interfaces in `Modules/Ledger.lua`**

The store is `db.global.ledger = {entries = {}, costBasis = {}, nameIndex = {}}`: `entries` comes from 1a's defaults, `costBasis` and `nameIndex` are created lazily (guard `entries` with `or {}` too). `OnEnable` calls `Prune(Now())`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted tests/ledger && luacheck .`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Modules/Ledger.lua tests/ledger/ledger_spec.lua FabricationStation.toc .luacheckrc
git commit -m "feat: add Ledger store with weekly, per-recipe profit and tip benchmarks"
```

