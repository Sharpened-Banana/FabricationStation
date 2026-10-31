### Task 13: Dashboard tab with RegisterWidget and phase-1 widgets

**Files:**
- Create: `UI/Tabs/Dashboard.lua`
- Modify: `FabricationStation.toc`
- Test: `tests/ui/dashboard_spec.lua`

**Interfaces:**
- Consumes: `MainWindow:RegisterTab("dashboard", { label = "Dashboard", icon, order = 10, phase = 1, build, refresh })`, `Recipes:GetRanked`, `Queue:GetEntries/GetEntryCost/GetMissingReagents`, `Scanner:GetCharacters/GetCharacter/ProjectConcentration`, `ns.UI.FormatMoney/FormatAge`; messages `FS_RECIPES_CHANGED`, `FS_QUEUE_CHANGED`, `FS_DATA_CHANGED`.
- Produces: module `"Dashboard"`; `Dashboard:RegisterWidget(id, def)` (contract; stores `def.id = id`; same id replaces); `Dashboard:GetWidgets() -> { def }` by `order`; `Dashboard:BuildAll(container) -> { [id] = frame }` (two-column grid; a widget whose `build`/`refresh` errors shows "widget failed" in `frame.errorText`, others still render); pure models `Dashboard.TopCraftsModel(results, n)`, `Dashboard.QueueSummaryModel(entries, costs, missing) -> { entries, crafts, totalCost|nil, missingItems }`, `Dashboard.ConcentrationModel(rows, now)` (rows `{ charKey, profession, value, max, regenPerSec }` → adds `fullAt = now + (max − value) / regenPerSec`, sorted by `fullAt`; the widget derives `regenPerSec` from `ProjectConcentration(c, s, now + 3600) − ProjectConcentration(c, s, now)` ÷ 3600, so no rate is hard-coded). Phase-1 widgets: `topCrafts` (order 10, top 10 by profit with price age), `queueSummary` (20), `concentration` (30). Refresh on the three messages, debounced 0.5 s.

- [ ] **Step 1: Write the failing test**

```lua
describe("Dashboard", function()
  local ns, D
  before_each(function() ns = make_world({ last = "UI/Tabs/Dashboard.lua" }); D = ns.FS:GetModule("Dashboard") end)
  it("orders widgets and replaces duplicates", function()
    D:RegisterWidget("b", { order = 50, title = "B", build = function() end, refresh = function() end })
    D:RegisterWidget("a", { order = 5, title = "A", build = function() end, refresh = function() end })
    D:RegisterWidget("b", { order = 1, title = "B2", build = function() end, refresh = function() end })
    local w = D:GetWidgets()
    assert.same({ "b", "a", "topCrafts", "queueSummary", "concentration" }, { w[1].id, w[2].id, w[3].id, w[4].id, w[5].id })
    assert.equals("B2", w[1].title)
  end)
  it("isolates a failing widget", function()
    D:RegisterWidget("bad", { order = 1, title = "Bad", build = function() error("boom") end, refresh = function() end })
    local frames = D:BuildAll(CreateFrame("Frame"))
    assert.equals("widget failed", frames.bad.errorText); assert.is_table(frames.topCrafts)
  end)
  it("concentration model sorts by full-at", function()
    local rows = D.ConcentrationModel({ { charKey = "A", value = 900, max = 1000, regenPerSec = 1/360 }, { charKey = "B", value = 990, max = 1000, regenPerSec = 1/360 } }, 0)
    assert.same({ "B", "A" }, { rows[1].charKey, rows[2].charKey }); assert.near(3600, rows[1].fullAt, 1e-6)
  end)
  it("queue summary leaves the total nil when any cost is unknown", function()
    assert.is_nil(D.QueueSummaryModel({ {id=1,quantity=2}, {id=2,quantity=1} }, { [1] = 1800 }, {}).totalCost)
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted tests/ui/dashboard_spec.lua`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement `UI/Tabs/Dashboard.lua`.**

- [ ] **Step 4: Run tests, then verify in game**

Run: `busted tests/ui/dashboard_spec.lua`
Expected: PASS. In game: `/fs` → Dashboard shows top crafts with price age, the queue summary and concentration rows for every alt.

- [ ] **Step 5: Commit**

```bash
git add UI/Tabs/Dashboard.lua tests/ui/dashboard_spec.lua FabricationStation.toc
git commit -m "feat: add Dashboard tab with widget registry and phase-1 widgets"
```

---

