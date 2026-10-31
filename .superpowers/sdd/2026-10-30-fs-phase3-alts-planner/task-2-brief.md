### Task 2: PlanCalc knowledge progress

**Files:**
- Modify: `Modules/PlanCalc.lua`
- Test: `tests/plancalc/knowledge_spec.lua`

**Interfaces:**
- Consumes: `KnowledgeSource` (contract additions).
- Produces: `PlanCalc.SourceProgress(source, snapshot, ctx) -> SourceState` where `snapshot = { time, quests = {[id]=true} } | nil`, `ctx = { weekStart, darkmoon = { isOpen, startTime } }`; `PlanCalc.Summarize(states, firstCraftsPending, firstCraftPoints) -> KnowledgeSummary`; `PlanCalc.StripCodes(text) -> string`.

- [ ] **Step 1: Write the failing tests** (`WS = 1793113200`, ctx `{weekStart = WS, darkmoon = {isOpen = true, startTime = WS - 86400}}`)

```lua
local BS_WEEKLY = {id="2907:weeklyQuest:93691", skillLineID=2907, category="weeklyQuest", reset="weekly", quests={93691}, points=2}
local HERB = {id="h", skillLineID=2912, category="weeklyQuest", reset="weekly", quests={93700,93701,93702,93703,93704}, limit=1, points=3}
local DE = {id="d", skillLineID=2909, category="drop", reset="weekly", quests={95048,95049,95050,95051,95052}, points=1}
local DMF = {id="m", skillLineID=2907, category="darkmoon", reset="monthly", quests={29508}, points=3}
local UNIQUE = {id="u", skillLineID=2907, category="unique", reset="once", quests={89999}, points=3}
it("weekly done this week", function()
  local s = P.SourceProgress(BS_WEEKLY, {time = WS + 10, quests = {[93691]=true}}, ctx)
  assert.same({2, 2, true, "done"}, {s.earned, s.total, s.done, s.status})
end)
it("weekly snapshot older than reset counts as open", function()
  local s = P.SourceProgress(BS_WEEKLY, {time = WS - 10, quests = {[93691]=true}}, ctx)
  assert.same({0, 2, false, "open"}, {s.earned, s.total, s.done, s.status})
end)
it("limit = any one of several quests", function()
  local s = P.SourceProgress(HERB, {time = WS + 1, quests = {[93702]=true}}, ctx)
  assert.same({3, 3, true}, {s.earned, s.total, s.done})
end)
it("no limit = each quest worth points", function()
  local s = P.SourceProgress(DE, {time = WS + 1, quests = {[95048]=true, [95050]=true}}, ctx)
  assert.same({2, 5, false}, {s.earned, s.total, s.done})
end)
it("darkmoon closed / done before faire start", function()
  local closed = {weekStart = WS, darkmoon = {isOpen = false}}
  assert.equal("closed", P.SourceProgress(DMF, {time = WS, quests = {}}, closed).status)
  assert.equal(0, P.SourceProgress(DMF, {time = WS - 2*86400, quests = {[29508]=true}}, ctx).earned)
  assert.equal("unknown", P.SourceProgress(DMF, {time = WS, quests = {}}, {weekStart = WS, darkmoon = {}}).status)
end)
it("once never resets", function()
  assert.is_true(P.SourceProgress(UNIQUE, {time = WS - 999999, quests = {[89999]=true}}, ctx).done)
end)
it("no snapshot -> unknown", function()
  assert.equal("unknown", P.SourceProgress(BS_WEEKLY, nil, ctx).status)
  assert.equal("unknown", P.SourceProgress(BS_WEEKLY, {}, ctx).status)   -- 1a's empty knowledgeWeekly default
end)
it("Summarize", function()
  local snap = {time = WS + 1, quests = {[93691]=true}}
  local states = { P.SourceProgress(BS_WEEKLY, snap, ctx), P.SourceProgress(DMF, snap, ctx), P.SourceProgress(UNIQUE, snap, ctx) }
  local s = P.Summarize(states, 2, 1)
  assert.same({"ok", 0, 2, 3, 5, 2, "open"},          -- oneTimeLeft = unique 3 + 2 first crafts
    {s.status, s.weeklyLeft, s.weeklyTotal, s.monthlyLeft, s.oneTimeLeft, s.firstCraftsPending, s.darkmoon})
end)
it("Summarize noData / unknown", function()
  assert.equal("noData", P.Summarize({}, nil, 1).status)
  assert.equal("unknown", P.Summarize({P.SourceProgress(BS_WEEKLY, nil, ctx)}, nil, 1).status)
end)
it("StripCodes", function()
  assert.equal("Vendor: Smith Cost: 5", P.StripCodes("|cFFFFD200Vendor:|r Smith|nCost: 5|TInterface\\x:0|t"))
end)
```

- [ ] **Step 2: Run** — `busted tests/plancalc/knowledge_spec.lua` → FAIL (`SourceProgress` nil).

- [ ] **Step 3: Implement.** `SourceProgress`: `cap = source.limit or #source.quests`; `total = points * cap`. Status order: no snapshot (nil, or a table without `time` — 1a creates `knowledgeWeekly = {}`) → `"unknown"` (earned 0); monthly with `darkmoon.isOpen == nil` → `"unknown"`, `== false` → `"closed"`; completed set is empty when (weekly and `snapshot.time < ctx.weekStart`) or (monthly and `snapshot.time < darkmoon.startTime`); `earned = points * min(countCompleted, cap)`; `done = earned >= total`; status `"done"`/`"open"`. `Summarize`: empty list → `noData`; any `"unknown"` weekly state → `status = "unknown"`; `weeklyLeft/Total` over weekly sources, `monthlyLeft` over open monthly, `oneTimeLeft` over once, plus `(firstCraftsPending or 0) * firstCraftPoints` added to `oneTimeLeft`; `darkmoon` = status of the first monthly state mapped `done|open → "open"`, else `"closed"`/`"unknown"` (`"unknown"` when none). `StripCodes`: remove `|c%x%x%x%x%x%x%x%x`, `|r`, `|T.-|t`; `|n` → space; trim.

- [ ] **Step 4: Run** — `busted tests/plancalc` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Modules/PlanCalc.lua tests/plancalc/knowledge_spec.lua
git commit -m "feat: add PlanCalc knowledge source progress and summaries"
```


**Orchestrator notes:** apply the preflight.md rows that name Task 2 (binding). PlanCalc is pure: no WoW globals, no ns.FS.
